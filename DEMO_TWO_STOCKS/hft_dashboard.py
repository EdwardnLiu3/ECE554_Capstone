"""
hft_dashboard.py

Integrated HFT capstone software side. Wires together:
  - merged or single-stock LOBSTER CSV replay
  - lobster_to_itch.py      (LOBSTER -> ITCH sender, TCP)
  - pythonExecution/execution_trackers.py  (per-stock state machine)
  - live CustomTkinter / matplotlib dashboard

Data flow:
  LOBSTER CSV  ->  TcpDuplex.send_loop  ->  ITCH packet over TCP  ->  FPGA
                       |
                       +--> TrackerHub.market_event(per-row ticker, row)
                            (tracker.process_lobster_row to advance market price
                             and to detect fills against our quotes)

  FPGA  ->  TCP return stream  ->  TcpDuplex.recv_loop  ->  raw OUCH payloads
                       |
                       +--> TrackerHub.fpga_payload(ticker-tagged payload)
                            (tracker.process_order_payload to register live quote)

  Dashboard.tick()  ->  TrackerHub.snapshot(ticker)
                    ->  ax.plot mark price + bid/ask/fill scatter overlays.

Usage:
  # Live, with FPGA on the wire (stream merged two-stock replay to FPGA)
  python hft_dashboard.py --fpga-ip 192.168.1.101 --port 7000 --speed 1

  # Offline / demo without FPGA - replay the same merged file locally
  python hft_dashboard.py --offline --speed 50
"""

from __future__ import annotations

import argparse
import csv
import socket
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

GUI_IMPORT_ERROR: ModuleNotFoundError | None = None
try:
    import customtkinter as ctk
    import matplotlib.pyplot as plt
    import numpy as np
    from matplotlib.animation import FuncAnimation
    from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
except ModuleNotFoundError as exc:
    GUI_IMPORT_ERROR = exc
    ctk = None
    plt = None
    np = None
    FuncAnimation = None
    FigureCanvasTkAgg = None

HERE = Path(__file__).parent
sys.path.append(str(HERE / "ITCH_Translator"))
sys.path.append(str(HERE / "pythonExecution"))

from lobster_to_itch import STOCK_ID_TO_TICKER, translate_row  # noqa: E402
from execution_trackers import (  # noqa: E402
    ExecutionTrackers,
    MSG_ENTER,
    MSG_REPLACE,
    QUOTE_ASK,
    QUOTE_BID,
)


# OUCH / Order_Generator wire payload size: two 376-bit messages = 94 bytes.
OUCH_PAYLOAD_BYTES = 94
TAGGED_OUCH_FRAME_BYTES = OUCH_PAYLOAD_BYTES + 2


DEFAULT_FPGA_IP = "192.168.1.101"
DEFAULT_PORT = 7000
LOBSTER_DIR = HERE / "ITCH_Translator" / "LOBSTER_SampleFile_AMZN_2012-06-21_1"
DEFAULT_CSV = LOBSTER_DIR / "two_stock_style_hour_message_clean_merged.csv"

DEFAULT_TICKERS = ["INTC", "MSFT"]
TICKER_CSV: dict[str, Path] = {
    "INTC": LOBSTER_DIR / "intc_style_hour_message_clean.csv",
    "MSFT": LOBSTER_DIR / "msft_style_hour_message_clean.csv",
}
PRICE_DIVISOR = 100        # tracker stores prices in cents (LOBSTER raw / 100)
EMPTY_OFFSETS = np.empty((0, 2)) if np is not None else ()


@dataclass
class StockState:
    """
    Per-stock state.

    Buffers are unbounded so an hour-long demo never drops history. They are
    sized for roughly 400_000 samples per stock - enough headroom for fast
    replay or FPGA echo bursts above the LOBSTER row rate. Python lists grow
    on demand, so this is a soft target rather than a hard cap.
    """
    ticker: str
    csv_path: Path | None
    tracker: ExecutionTrackers
    lock: threading.Lock = field(default_factory=threading.Lock)
    times: list[float] = field(default_factory=list)
    prices: list[float] = field(default_factory=list)
    bid_events: list[tuple[float, float]] = field(default_factory=list)
    ask_events: list[tuple[float, float]] = field(default_factory=list)
    fill_events: list[tuple[float, float, int]] = field(default_factory=list)
    last_midpoint_cents: float | None = None


def _ticker_for_row(row: list[str], fallback_ticker: str) -> str:
    if len(row) >= 7:
        try:
            return STOCK_ID_TO_TICKER.get(int(row[6]), fallback_ticker)
        except ValueError:
            return fallback_ticker
    return fallback_ticker


def _is_ouch_message_type(value: int) -> bool:
    return value in (MSG_ENTER, MSG_REPLACE)


def _bits(value: int, msb: int, lsb: int) -> int:
    width = msb - lsb + 1
    return (value >> lsb) & ((1 << width) - 1)


def decode_ouch_enters(value: int) -> list[tuple[int, int, int, int, str]]:
    """
    Decode OUCH 'O' (Enter Order) and 'U' (Replace Order) messages packed in
    an Order_Generator payload.

    Mirrors the bit layout used by execution_trackers._apply_order_payload but
    returns the parsed fields instead of mutating tracker state.  Replace
    messages are included now so that the bid/ask scatter points continue to
    be recorded after the FPGA switches from Enter to Replace mode.

    Returns a list of (side, price_cents, quantity, order_id, symbol).
    The symbol field is empty string for Replace messages (no symbol field in
    the Replace format).
    """
    events: list[tuple[int, int, int, int, str]] = []

    lower_is_enter = _bits(value, 375, 368) == MSG_ENTER
    lower_is_replace = _bits(value, 375, 368) == MSG_REPLACE
    
    if lower_is_enter:
        events.append(_decode_enter_at(value, 0))
    elif lower_is_replace:
        events.append(_decode_replace_at(value, 0, QUOTE_ASK))

    upper_base = 376

    upper_is_enter = _bits(value, upper_base + 375, upper_base + 368) == MSG_ENTER
    upper_is_replace = _bits(value, upper_base + 375, upper_base + 368) == MSG_REPLACE

    if upper_is_enter:
        events.append(_decode_enter_at(value, upper_base))
    elif upper_is_replace:
        events.append(_decode_replace_at(value, upper_base, QUOTE_BID))

    return events


def _decode_enter_at(value: int, base: int) -> tuple[int, int, int, int, str]:
    order_id = _bits(value, base + 367, base + 336)
    side_byte = _bits(value, base + 335, base + 328)
    quantity = _bits(value, base + 327, base + 296)
    symbol_raw = _bits(value, base + 295, base + 232)
    price_cents = _bits(value, base + 231, base + 168)
    side = QUOTE_BID if side_byte == 0x42 else QUOTE_ASK
    symbol = symbol_raw.to_bytes(8, "big").decode("ascii", errors="ignore").strip()
    return side, price_cents, quantity, order_id, symbol


def _decode_replace_at(value: int, base: int, side: int) -> tuple[int, int, int, int, str]:
    """Extract (side, price_cents, quantity, new_order_id, '') from a 376-bit Replace slot."""
    new_id   = _bits(value, base + 335, base + 304)
    quantity = _bits(value, base + 303, base + 272)
    price    = _bits(value, base + 271, base + 208)
    return side, price, quantity, new_id, ""


def _midpoint_cents(tracker: ExecutionTrackers) -> float | None:
    """Best-bid / best-ask midpoint computed from the tracker's resting book."""
    best_bid = None
    best_ask = None
    for order in tracker.market_orders.values():
        if order.quantity <= 0:
            continue
        if order.side == 1:  # LOBSTER_BUY
            if best_bid is None or order.price > best_bid:
                best_bid = order.price
        elif order.side == -1:  # LOBSTER_SELL
            if best_ask is None or order.price < best_ask:
                best_ask = order.price
    if best_bid is None or best_ask is None or best_ask < best_bid:
        return None
    return (best_bid + best_ask) / 2.0


class TrackerHub:
    """Owns one ExecutionTrackers and its plot buffers per ticker."""

    def __init__(self, tickers: list[str]) -> None:
        self.start_wall = time.monotonic()
        self.paused = threading.Event()
        self.stocks: dict[str, StockState] = {}
        for ticker in tickers:
            self.stocks[ticker] = StockState(
                ticker=ticker,
                csv_path=TICKER_CSV.get(ticker),
                tracker=ExecutionTrackers(stock_id=ticker, price_divisor=PRICE_DIVISOR),
            )

    def market_event(self, ticker: str, row: list[str]) -> None:
        """Advance the tracker with a LOBSTER row and record the midpoint."""
        stock = self.stocks.get(ticker)
        if stock is None:
            return
        with stock.lock:
            execution = stock.tracker.process_lobster_row(row)
            t = time.monotonic() - self.start_wall
            mid_cents = _midpoint_cents(stock.tracker)
            if mid_cents is not None and mid_cents > 0:
                stock.last_midpoint_cents = mid_cents
                stock.times.append(t)
                stock.prices.append(mid_cents / 100.0)
            if execution.valid:
                stock.fill_events.append((t, execution.price / 100.0, execution.side))

    def fpga_payload(
        self,
        payload: bytes,
        fallback_ticker: str | None = None,
        tagged_ticker: str | None = None,
    ) -> None:
        """
        Consume one raw OUCH/Order_Generator payload from the FPGA.

        The tracker decodes and applies the payload itself; this method also
        decodes the contained Enter *and* Replace messages so it can append
        bid/ask scatter points and route the payload to the right per-ticker
        tracker.  Replace messages carry an updated price/quantity for each
        side and must be visualised just like Enter messages.
        """
        if len(payload) < OUCH_PAYLOAD_BYTES:
            return
        value = int.from_bytes(payload[:OUCH_PAYLOAD_BYTES], "big")
        events = decode_ouch_enters(value)   # returns Enter AND Replace events

        # Prefer the stock tag supplied by the board. When running against an
        # older bridge that sends only the raw 94-byte payload, fall back to a
        # symbol-carrying Enter or the CLI fallback ticker.
        ticker = tagged_ticker or ""
        for _side, _price, _qty, _oid, sym in events:
            if sym:
                ticker = sym.strip()
                break
        if not ticker:
            ticker = fallback_ticker or ""

        stock = self.stocks.get(ticker)
        if stock is None and fallback_ticker is not None:
            stock = self.stocks.get(fallback_ticker)
        if stock is None:
            return

        with stock.lock:
            stock.tracker.process_order_payload(value)
            t = time.monotonic() - self.start_wall
            for side, price_cents, _qty, _oid, _sym in events:
                price_dollars = price_cents / 100.0
                target = stock.bid_events if side == QUOTE_BID else stock.ask_events
                if price_dollars > 0:
                    target.append((t, price_dollars))

    def snapshot(self, ticker: str) -> dict:
        stock = self.stocks.get(ticker)
        if stock is None:
            return {}
        with stock.lock:
            return stock.tracker.get_outputs()


def lobster_replay(
    hub: TrackerHub,
    csv_path: Path,
    speed: float,
    orders: int,
    stop: threading.Event,
    fallback_ticker: str,
    on_send=None,
) -> None:
    """Stream one CSV into the hub at scaled wall-clock speed."""
    sent = 0
    last_ts: float | None = None
    with open(csv_path, newline="") as csv_file:
        for row in csv.reader(csv_file):
            if stop.is_set():
                break
            if len(row) not in (6, 7):
                continue
            ts = float(row[0])
            if last_ts is not None and ts > last_ts:
                time.sleep(min((ts - last_ts) / speed, 5.0))
            
            while hub.paused.is_set():
                if stop.is_set():
                    break
                time.sleep(0.1)
                
            last_ts = ts
            if on_send is not None:
                try:
                    on_send(row)
                except Exception as exc:
                    print(f"[REPLAY] on_send error: {exc}")
                    break
            hub.market_event(_ticker_for_row(row, fallback_ticker), row)
            sent += 1
            if orders > 0 and sent >= orders:
                break


class TcpDuplex:
    """TCP send + receive driver for the live merged replay path."""

    def __init__(
        self,
        hub: TrackerHub,
        ip: str,
        port: int,
        ticker: str,
        csv_path: Path,
        orders: int,
        speed: float,
    ) -> None:
        self.hub = hub
        self.ip = ip
        self.port = port
        self.ticker = ticker
        self.csv_path = csv_path
        self.orders = orders
        self.speed = speed
        self.sock: socket.socket | None = None
        self.stop = threading.Event()
        self._recv_buf = bytearray()
        self._match_counter = [0]
        self._order_id_map: dict[tuple[int, int], int] = {}

    def start(self) -> bool:
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5.0)
            sock.connect((self.ip, self.port))
            sock.settimeout(None)
        except Exception as exc:
            print(f"[TCP] connect to {self.ip}:{self.port} failed: {exc}")
            return False
        self.sock = sock
        print(f"[TCP] connected {self.ip}:{self.port}, streaming {self.csv_path.name}")
        threading.Thread(target=self._recv_loop, name="tcp-recv", daemon=True).start()
        threading.Thread(target=self._send_loop, name="tcp-send", daemon=True).start()
        return True

    def shutdown(self) -> None:
        self.stop.set()
        if self.sock is not None:
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                self.sock.close()
            except Exception:
                pass

    def _send_one(self, row: list[str]) -> None:
        packet = translate_row(row, self.ticker, self._match_counter, self._order_id_map)
        if packet is None or self.sock is None:
            return
        self.sock.sendall(packet)

    def _send_loop(self) -> None:
        try:
            lobster_replay(
                self.hub,
                self.csv_path,
                self.speed,
                self.orders,
                self.stop,
                self.ticker,
                on_send=self._send_one,
            )
            print(f"[TCP] finished sending {self.csv_path.name}")
        except Exception as exc:
            print(f"[TCP] send loop error: {exc}")

    def _recv_loop(self) -> None:
        while not self.stop.is_set():
            try:
                chunk = self.sock.recv(4096)  # type: ignore[union-attr]
            except OSError:
                break
            if not chunk:
                print("[TCP] peer closed connection")
                break
            self._recv_buf.extend(chunk)
            self._drain_payloads()

    def _drain_payloads(self) -> None:
        """Pull tagged or legacy raw OUCH payloads off the byte stream."""
        while True:
            if len(self._recv_buf) >= TAGGED_OUCH_FRAME_BYTES:
                stock_id = int.from_bytes(self._recv_buf[:2], "big")
                first_type = self._recv_buf[2]
                second_type = self._recv_buf[49]
                if stock_id in STOCK_ID_TO_TICKER and _is_ouch_message_type(first_type) and _is_ouch_message_type(second_type):
                    payload = bytes(self._recv_buf[2:TAGGED_OUCH_FRAME_BYTES])
                    del self._recv_buf[:TAGGED_OUCH_FRAME_BYTES]
                    self.hub.fpga_payload(
                        payload,
                        fallback_ticker=self.ticker,
                        tagged_ticker=STOCK_ID_TO_TICKER[stock_id],
                    )
                    continue

            if len(self._recv_buf) >= OUCH_PAYLOAD_BYTES:
                first_type = self._recv_buf[0]
                second_type = self._recv_buf[47]
                if _is_ouch_message_type(first_type) and _is_ouch_message_type(second_type):
                    payload = bytes(self._recv_buf[:OUCH_PAYLOAD_BYTES])
                    del self._recv_buf[:OUCH_PAYLOAD_BYTES]
                    self.hub.fpga_payload(payload, fallback_ticker=self.ticker)
                    continue

            break


class Dashboard:
    """CustomTkinter dashboard rendering each stock's tracker state."""

    PALETTE = {
        "bg": "#1c1c1c",
        "axes": "#2b2b2b",
        "grid": "#444444",
        "line": "#1f9aff",
        "bid": "#81b29a",
        "ask": "#e07a5f",
        "fill": "#f2cc8f",
    }
    STAT_FIELDS = ("Ticker", "Mark", "Position", "Day P&L", "Total P&L", "Bid Qty", "Ask Qty")

    def __init__(self, hub: TrackerHub, tickers: list[str]) -> None:
        if GUI_IMPORT_ERROR is not None:
            missing_name = getattr(GUI_IMPORT_ERROR, "name", "GUI dependency")
            raise RuntimeError(
                f"Missing dependency '{missing_name}'. Install the packages in requirements-dashboard.txt to run hft_dashboard.py."
            ) from GUI_IMPORT_ERROR
        self.hub = hub
        self.tickers = tickers
        self.active_ticker = tickers[0]
        self.running = True

        ctk.set_appearance_mode("dark")
        ctk.set_default_color_theme("blue")
        self.app = ctk.CTk()
        self.app.title("HFT Dashboard")
        self.app.geometry("1100x720")
        self.app.resizable(True, True)

        self._build_tabs()
        self._build_figure()
        self._build_stats()

        self.anim = FuncAnimation(
            self.fig, self._tick, interval=200, blit=False, cache_frame_data=False
        )

    def _build_tabs(self) -> None:
        frame = ctk.CTkFrame(self.app, corner_radius=10)
        frame.pack(fill="x", padx=20, pady=(20, 5))
        self.tab_buttons: dict[str, ctk.CTkButton] = {}
        for ticker in self.tickers:
            btn = ctk.CTkButton(
                frame,
                text=ticker,
                width=140,
                fg_color="#444",
                hover_color="#666",
                command=lambda t=ticker: self._select(t),
            )
            btn.pack(side="left", padx=6, pady=10)
            self.tab_buttons[ticker] = btn
        self._highlight_active(self.active_ticker)

    def _build_figure(self) -> None:
        self.fig, self.ax = plt.subplots(figsize=(10, 5))
        self.fig.patch.set_facecolor(self.PALETTE["bg"])
        self.ax.set_facecolor(self.PALETTE["axes"])
        self.ax.tick_params(colors="white")
        self.ax.xaxis.label.set_color("white")
        self.ax.yaxis.label.set_color("white")
        self.ax.title.set_color("white")
        for spine in self.ax.spines.values():
            spine.set_edgecolor("#555")
        self.ax.grid(True, color=self.PALETTE["grid"], alpha=0.3)
        self.ax.set_xlabel("Seconds since start")
        self.ax.set_ylabel("Price ($)")
        self.ax.set_title(f"{self.active_ticker} - Market Price + FPGA Orders")

        (self.price_line,) = self.ax.plot(
            [], [], color=self.PALETTE["line"], linewidth=1.8, label="Midpoint"
        )
        self.bid_scatter = self.ax.scatter(
            [], [], color=self.PALETTE["bid"], marker="^", s=42, label="FPGA bid"
        )
        self.ask_scatter = self.ax.scatter(
            [], [], color=self.PALETTE["ask"], marker="v", s=42, label="FPGA ask"
        )
        self.fill_scatter = self.ax.scatter(
            [], [], color=self.PALETTE["fill"], marker="*", s=110, label="Our fill"
        )
        self.ax.legend(
            loc="upper left", facecolor="#222", edgecolor="#555", labelcolor="white"
        )
        self.fig.tight_layout()

        graph_frame = ctk.CTkFrame(self.app, corner_radius=10)
        graph_frame.pack(fill="both", expand=True, padx=20, pady=(5, 5))
        self.canvas = FigureCanvasTkAgg(self.fig, master=graph_frame)
        self.canvas.get_tk_widget().pack(fill="both", expand=True)

    def _build_stats(self) -> None:
        frame = ctk.CTkFrame(self.app, corner_radius=10)
        frame.pack(fill="x", padx=20, pady=(5, 20))
        self.stat_labels: dict[str, ctk.CTkLabel] = {}
        for label in self.STAT_FIELDS:
            cell = ctk.CTkFrame(frame, fg_color="transparent")
            cell.pack(side="left", padx=12, pady=8)
            ctk.CTkLabel(cell, text=label, text_color="#888", font=("Segoe UI", 11)).pack()
            value = ctk.CTkLabel(cell, text="-", text_color="white", font=("Segoe UI", 16, "bold"))
            value.pack()
            self.stat_labels[label] = value
        self.btn_toggle = ctk.CTkButton(frame, text="Pause", width=110, command=self._toggle)
        self.btn_toggle.pack(side="right", padx=8)

    def _select(self, ticker: str) -> None:
        self.active_ticker = ticker
        self._highlight_active(ticker)
        self.ax.set_title(f"{ticker} - Market Price + FPGA Orders")
        self.canvas.draw_idle()

    def _highlight_active(self, ticker: str) -> None:
        for name, btn in self.tab_buttons.items():
            if name == ticker:
                btn.configure(fg_color="#1f9aff", hover_color="#2b6dc0")
            else:
                btn.configure(fg_color="#444", hover_color="#666")

    def _toggle(self) -> None:
        self.running = not self.running
        self.btn_toggle.configure(text="Resume" if not self.running else "Pause")
        if self.running:
            self.hub.paused.clear()
        else:
            self.hub.paused.set()

    def _tick(self, _frame):
        if not self.running:
            return ()
        stock = self.hub.stocks[self.active_ticker]
        with stock.lock:
            xs = list(stock.times)
            ys = list(stock.prices)
            bids = list(stock.bid_events)
            asks = list(stock.ask_events)
            fills = list(stock.fill_events)
            snap = stock.tracker.get_outputs()
            midpoint_cents = stock.last_midpoint_cents

        self.price_line.set_data(xs, ys)
        self.bid_scatter.set_offsets(np.array(bids) if bids else EMPTY_OFFSETS)
        self.ask_scatter.set_offsets(np.array(asks) if asks else EMPTY_OFFSETS)
        if fills:
            self.fill_scatter.set_offsets(np.array([(t, p) for t, p, _side in fills]))
        else:
            self.fill_scatter.set_offsets(EMPTY_OFFSETS)

        # Span the actual buffered range so the line fills the canvas after the
        # rolling window starts dropping the oldest events.
        all_x = xs + [b[0] for b in bids] + [a[0] for a in asks] + [f[0] for f in fills]
        if all_x:
            x_lo, x_hi = min(all_x), max(all_x)
            if x_hi - x_lo < 1.0:
                x_hi = x_lo + 1.0
            self.ax.set_xlim(x_lo, x_hi)
        # Keep the y-range tied to the midpoint trace so a bad FPGA quote
        # marker cannot flatten the market-price line into a near-horizontal
        # band at the bottom of the chart.
        if ys:
            lo, hi = min(ys), max(ys)
            if fills:
                fill_prices = [p for _t, p, _side in fills]
                lo = min(lo, min(fill_prices))
                hi = max(hi, max(fill_prices))
            margin = max(0.05, (hi - lo) * 0.15)
            self.ax.set_ylim(lo - margin, hi + margin)

        self.stat_labels["Ticker"].configure(text=self.active_ticker)
        self.stat_labels["Mark"].configure(
            text=f"${midpoint_cents / 100:.2f}" if midpoint_cents else "-"
        )
        self.stat_labels["Position"].configure(text=str(snap.get("position", 0)))
        self.stat_labels["Day P&L"].configure(text=f"${snap.get('day_pnl', 0) / 100:,.2f}")
        self.stat_labels["Total P&L"].configure(text=f"${snap.get('total_pnl', 0) / 100:,.2f}")
        self.stat_labels["Bid Qty"].configure(text=str(snap.get("live_bid_qty", 0)))
        self.stat_labels["Ask Qty"].configure(text=str(snap.get("live_ask_qty", 0)))

        self.canvas.draw_idle()
        return ()

    def mainloop(self) -> None:
        self.app.mainloop()


def spawn_offline(
    hub: TrackerHub,
    csv_path: Path,
    speed: float,
    orders: int,
    stop: threading.Event,
    fallback_ticker: str,
) -> bool:
    if not csv_path.exists():
        print(f"[OFFLINE] replay file not found: {csv_path}")
        return False
    threading.Thread(
        target=lobster_replay,
        args=(hub, csv_path, speed, orders, stop, fallback_ticker),
        name="replay-csv",
        daemon=True,
    ).start()
    print(f"[OFFLINE] replaying {csv_path.name}")
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description="Integrated HFT capstone dashboard.")
    parser.add_argument("--fpga-ip", default=DEFAULT_FPGA_IP)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument(
        "--ticker",
        default="INTC",
        help="Fallback ticker for legacy 6-column CSVs or untagged raw FPGA payloads",
    )
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV, help=f"Replay CSV (default: {DEFAULT_CSV})")
    parser.add_argument("--orders", type=int, default=-1, help="Max replay rows (-1 = all)")
    parser.add_argument("--speed", type=float, default=1.0, help="Replay speed multiplier")
    parser.add_argument("--offline", action="store_true", help="Skip the FPGA and replay locally")
    parser.add_argument(
        "--tickers",
        nargs="+",
        default=DEFAULT_TICKERS,
        help=f"Ticker tabs to display (default: {' '.join(DEFAULT_TICKERS)})",
    )
    args = parser.parse_args()

    hub = TrackerHub(args.tickers)
    stop = threading.Event()
    tcp_client: TcpDuplex | None = None

    if args.offline:
        spawn_offline(hub, args.csv, args.speed, args.orders, stop, args.ticker)
    else:
        if not args.csv.exists():
            print(f"[ERROR] replay CSV not found: {args.csv}")
            sys.exit(1)
        tcp_client = TcpDuplex(
            hub, args.fpga_ip, args.port, args.ticker, args.csv, args.orders, args.speed
        )
        if not tcp_client.start():
            print("[INFO] FPGA unavailable, falling back to offline replay")
            tcp_client = None
            spawn_offline(hub, args.csv, args.speed, args.orders, stop, args.ticker)

    dashboard = Dashboard(hub, args.tickers)
    try:
        dashboard.mainloop()
    finally:
        stop.set()
        if tcp_client is not None:
            tcp_client.shutdown()


if __name__ == "__main__":
    main()
