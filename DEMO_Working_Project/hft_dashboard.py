"""
hft_dashboard.py

Integrated HFT capstone software side. Wires together:
  - send_itch_client.py     (LOBSTER -> ITCH sender, TCP)
  - tcp_duplex_client.py    (TCP receive loop)
  - pythonExecution/execution_trackers.py  (per-stock state machine)
  - animated_graph_ctk-V1.py style live CustomTkinter dashboard

Data flow:
  Merged LOBSTER CSV (with stock_id column)
        ->  TcpDuplex.send_loop  ->  ITCH packet over TCP  ->  FPGA
              (one packet per row, ticker resolved from stock_id)
                       |
                       +--> TrackerHub.market_event(ticker, row)
                            (each row routed to its ticker's tracker to advance
                             market price and detect fills against our quotes)

  FPGA  ->  TCP echo  ->  TcpDuplex.recv_loop  ->  decoded ITCH 'A' (quote)
                       |
                       +--> TrackerHub.fpga_payload(...)
                            (tracker.process_order_payload to register live quote;
                             ticker resolved from the Enter-message symbol, with
                             --ticker as the fallback for Replace-only payloads)

  Dashboard.tick()  ->  TrackerHub.snapshot(ticker)
                    ->  ax.plot mark price + bid/ask/fill scatter overlays.

Usage:
  # Live, with FPGA on the wire (sends ITCH for ALL stocks in the merged CSV)
  python hft_dashboard.py --fpga-ip 192.168.1.101 --port 7000

  # Offline / demo without FPGA - replay the merged CSV for all tickers
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

import customtkinter as ctk
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.animation import FuncAnimation
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg

HERE = Path(__file__).parent
sys.path.append(str(HERE / "ITCH_Translator"))
sys.path.append(str(HERE / "pythonExecution"))

from lobster_to_itch import translate_row  # noqa: E402
from execution_trackers import (  # noqa: E402
    ExecutionTrackers,
    MSG_ENTER,
    MSG_REPLACE,
    QUOTE_ASK,
    QUOTE_BID,
)


# OUCH / Order_Generator wire payload size: two 376-bit messages = 94 bytes.
OUCH_PAYLOAD_BYTES = 94
OUCH_PAYLOAD_BITS = OUCH_PAYLOAD_BYTES * 8


DEFAULT_FPGA_IP = "192.168.1.101"
DEFAULT_PORT = 7000
LOBSTER_DIR = HERE / "ITCH_Translator" / "LOBSTER_SampleFile_AMZN_2012-06-21_1"

# Merged multi-stock LOBSTER replay. Columns:
#   time, type, order_id, size, price, direction, stock_id
# stock_id is a 1-based index into STOCK_ID_TO_TICKER (see metadata file).
MERGED_CSV = LOBSTER_DIR / "two_stock_style_hour_message_clean_merged.csv"
STOCK_ID_TO_TICKER: dict[int, str] = {
    1: "AAPL",
    2: "AMZN",
}

DEFAULT_TICKERS = ["AAPL", "AMZN"]
TICKER_CSV: dict[str, Path] = {
    "AMZN": LOBSTER_DIR / "amzn_style_hour_message_clean.csv",
    "AAPL": LOBSTER_DIR / "aapl_style_hour_message_clean.csv",
}

PRICE_DIVISOR = 100        # tracker stores prices in cents (LOBSTER raw / 100)
EMPTY_OFFSETS = np.empty((0, 2))


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

    def fpga_payload(self, payload: bytes, fallback_ticker: str | None = None) -> None:
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

        # Resolve the ticker from the first event that carries a symbol (Enters
        # do; Replaces don't), then fall back to the CLI --ticker argument.
        ticker = fallback_ticker or ""
        for _side, _price, _qty, _oid, sym in events:
            if sym:
                ticker = sym.strip()
                break

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
                #if price_dollars > 200:
                target.append((t, price_dollars))

    def snapshot(self, ticker: str) -> dict:
        stock = self.stocks.get(ticker)
        if stock is None:
            return {}
        with stock.lock:
            return stock.tracker.get_outputs()


def lobster_replay(
    hub: TrackerHub,
    ticker: str,
    csv_path: Path,
    speed: float,
    orders: int,
    stop: threading.Event,
    on_send=None,
) -> None:
    """Stream LOBSTER rows into the hub at scaled wall-clock speed."""
    sent = 0
    last_ts: float | None = None
    with open(csv_path, newline="") as csv_file:
        for row in csv.reader(csv_file):
            if stop.is_set():
                break
            if len(row) != 6:
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
                    print(f"[REPLAY {ticker}] on_send error: {exc}")
                    break
            hub.market_event(ticker, row)
            sent += 1
            if orders > 0 and sent >= orders:
                break


def merged_lobster_replay(
    hub: TrackerHub,
    csv_path: Path,
    speed: float,
    orders: int,
    stop: threading.Event,
    on_send=None,
) -> None:
    """
    Stream a merged multi-stock LOBSTER CSV into the hub.

    Each row carries a 7th column (stock_id, 1-based) used to resolve the
    ticker via STOCK_ID_TO_TICKER. The 6 LOBSTER columns are forwarded to the
    matching tracker (and to the optional on_send callback for ITCH framing).

    on_send signature: on_send(ticker, six_col_row) -> None.
    """
    sent = 0
    last_ts: float | None = None
    with open(csv_path, newline="") as csv_file:
        for row in csv.reader(csv_file):
            if stop.is_set():
                break
            if len(row) != 7:
                continue
            try:
                stock_idx = int(row[6])
            except ValueError:
                continue
            ticker = STOCK_ID_TO_TICKER.get(stock_idx)
            if ticker is None or ticker not in hub.stocks:
                continue
            ts = float(row[0])
            if last_ts is not None and ts > last_ts:
                time.sleep(min((ts - last_ts) / speed, 5.0))

            while hub.paused.is_set():
                if stop.is_set():
                    break
                time.sleep(0.1)

            last_ts = ts
            six_col = row[:6]
            if on_send is not None:
                try:
                    on_send(ticker, six_col)
                except Exception as exc:
                    print(f"[REPLAY {ticker}] on_send error: {exc}")
                    break
            hub.market_event(ticker, six_col)
            sent += 1
            if orders > 0 and sent >= orders:
                break


class TcpDuplex:
    """TCP send + receive driver. Streams the merged multi-stock CSV to the FPGA."""

    def __init__(
        self,
        hub: TrackerHub,
        ip: str,
        port: int,
        merged_csv: Path,
        orders: int,
        speed: float,
        fallback_ticker: str | None = None,
    ) -> None:
        self.hub = hub
        self.ip = ip
        self.port = port
        self.merged_csv = merged_csv
        self.orders = orders
        self.speed = speed
        self.fallback_ticker = fallback_ticker
        self.sock: socket.socket | None = None
        self.stop = threading.Event()
        self._recv_buf = bytearray()
        self._match_counter = [0]
        self._order_id_maps: dict[str, dict[int, int]] = {}

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
        print(f"[TCP] connected {self.ip}:{self.port}, streaming merged {self.merged_csv.name}")
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

    def _send_one(self, ticker: str, row: list[str]) -> None:
        order_id_map = self._order_id_maps.setdefault(ticker, {})
        packet = translate_row(row, ticker, self._match_counter, order_id_map)
        if packet is None or self.sock is None:
            return
        self.sock.sendall(packet)

    def _send_loop(self) -> None:
        try:
            merged_lobster_replay(
                self.hub,
                self.merged_csv,
                self.speed,
                self.orders,
                self.stop,
                on_send=self._send_one,
            )
            print("[TCP] finished sending merged stream")
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
        """Pull fixed-size OUCH/Order_Generator payloads off the byte stream."""
        while len(self._recv_buf) >= OUCH_PAYLOAD_BYTES:
            payload = bytes(self._recv_buf[:OUCH_PAYLOAD_BYTES])
            del self._recv_buf[:OUCH_PAYLOAD_BYTES]
            self.hub.fpga_payload(payload, fallback_ticker=self.fallback_ticker)


class Dashboard:
    """Two-tab CustomTkinter dashboard rendering each stock's tracker state."""

    PALETTE = {
        "bg": "#1c1c1c",
        "axes": "#2b2b2b",
        "grid": "#444444",
        "line": "#1f9aff",
        "bid": "#81b29a",
        "ask": "#e07a5f",
        "fill": "#f2cc8f",
    }
    STAT_FIELDS = (
        "Ticker", "Mark", "Position", "Inventory Value",
        "Day P&L", "Total P&L", "Bid Qty", "Ask Qty",
    )
    WINDOW_SECONDS = 10.0

    def __init__(self, hub: TrackerHub, tickers: list[str]) -> None:
        self.hub = hub
        self.tickers = tickers
        self.active_ticker = tickers[0]
        self.running = True
        self.window_mode = "all"  # "10s" = sliding window, "all" = full history

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
        self.ax.tick_params(colors="white", labelsize=14)
        self.ax.xaxis.label.set_color("white")
        self.ax.yaxis.label.set_color("white")
        self.ax.title.set_color("white")
        for spine in self.ax.spines.values():
            spine.set_edgecolor("#555")
        self.ax.grid(True, color=self.PALETTE["grid"], alpha=0.3)
        self.ax.set_xlabel("Seconds since start", fontsize=15)
        self.ax.set_ylabel("Price ($)", fontsize=15)
        self.ax.set_title(f"{self.active_ticker} - Market Price + FPGA Orders", fontsize=17)

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
            loc="upper left", facecolor="#222", edgecolor="#555", labelcolor="white",
            fontsize=13,
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
            cell.pack(side="left", padx=12, pady=10)
            ctk.CTkLabel(cell, text=label, text_color="#aaa", font=("Segoe UI", 15)).pack()
            value = ctk.CTkLabel(cell, text="-", text_color="white", font=("Segoe UI", 22, "bold"))
            value.pack()
            self.stat_labels[label] = value
        self.btn_toggle = ctk.CTkButton(
            frame, text="Pause", width=130, height=40,
            font=("Segoe UI", 15, "bold"), command=self._toggle,
        )
        self.btn_toggle.pack(side="right", padx=8)
        self.btn_window = ctk.CTkButton(
            frame, text="Window: All", width=160, height=40,
            font=("Segoe UI", 15, "bold"), command=self._toggle_window,
        )
        self.btn_window.pack(side="right", padx=8)

    def _select(self, ticker: str) -> None:
        self.active_ticker = ticker
        self._highlight_active(ticker)
        self.ax.set_title(f"{ticker} - Market Price + FPGA Orders", fontsize=17)
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

    def _toggle_window(self) -> None:
        self.window_mode = "all" if self.window_mode == "10s" else "10s"
        label = f"Window: {int(self.WINDOW_SECONDS)}s" if self.window_mode == "10s" else "Window: All"
        self.btn_window.configure(text=label)
        self.canvas.draw_idle()

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

        # Pick the x-axis range. In "10s" mode we anchor the right edge to the
        # latest event time and slide the left edge back by WINDOW_SECONDS so
        # the plot reads as a live tail; in "all" mode we span the full buffer.
        all_x = xs + [b[0] for b in bids] + [a[0] for a in asks] + [f[0] for f in fills]
        if all_x:
            x_max = max(all_x)
            if self.window_mode == "10s":
                x_hi = x_max
                x_lo = x_hi - self.WINDOW_SECONDS
            else:
                x_lo, x_hi = min(all_x), x_max
                if x_hi - x_lo < 1.0:
                    x_hi = x_lo + 1.0
            self.ax.set_xlim(x_lo, x_hi)

            # Clamp y-range to data points within the visible x window so the
            # axis tightens to recent price action in sliding mode.
            ys_in = [p for t, p in zip(xs, ys) if x_lo <= t <= x_hi]
            bids_in = [p for t, p in bids if x_lo <= t <= x_hi]
            asks_in = [p for t, p in asks if x_lo <= t <= x_hi]
            if ys_in:
                lo, hi = min(ys_in), max(ys_in)
                if bids_in:
                    lo = min(lo, min(bids_in))
                    hi = max(hi, max(bids_in))
                if asks_in:
                    lo = min(lo, min(asks_in))
                    hi = max(hi, max(asks_in))
                margin = max(0.05, (hi - lo) * 0.15)
                self.ax.set_ylim(lo - margin, hi + margin)

        self.stat_labels["Ticker"].configure(text=self.active_ticker)
        self.stat_labels["Mark"].configure(
            text=f"${midpoint_cents / 100:.2f}" if midpoint_cents else "-"
        )
        self.stat_labels["Position"].configure(text=str(snap.get("position", 0)))
        self.stat_labels["Inventory Value"].configure(
            text=f"${snap.get('inventory_value', 0) / 100:,.2f}"
        )
        self.stat_labels["Day P&L"].configure(text=f"${snap.get('day_pnl', 0) / 100:,.2f}")
        self.stat_labels["Total P&L"].configure(text=f"${snap.get('total_pnl', 0) / 100:,.2f}")
        self.stat_labels["Bid Qty"].configure(text=str(snap.get("live_bid_qty", 0)))
        self.stat_labels["Ask Qty"].configure(text=str(snap.get("live_ask_qty", 0)))

        self.canvas.draw_idle()
        return ()

    def mainloop(self) -> None:
        self.app.mainloop()


def spawn_offline_merged(
    hub: TrackerHub, csv_path: Path, speed: float, orders: int, stop: threading.Event
) -> None:
    if not csv_path.exists():
        print(f"[OFFLINE] merged CSV not found: {csv_path}")
        return
    threading.Thread(
        target=merged_lobster_replay,
        args=(hub, csv_path, speed, orders, stop),
        name="replay-merged",
        daemon=True,
    ).start()
    print(f"[OFFLINE] replaying merged stream from {csv_path.name}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Integrated HFT capstone dashboard.")
    parser.add_argument("--fpga-ip", default=DEFAULT_FPGA_IP)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument(
        "--ticker",
        default="AMZN",
        help="Fallback ticker for FPGA Replace-message decoding (no symbol field)",
    )
    parser.add_argument("--orders", type=int, default=-1, help="Max merged rows replayed (-1 = all)")
    parser.add_argument("--speed", type=float, default=10.0, help="Replay speed multiplier")
    parser.add_argument("--offline", action="store_true", help="Skip the FPGA, replay merged CSV locally")
    parser.add_argument(
        "--csv",
        type=Path,
        default=MERGED_CSV,
        help=f"Merged multi-stock LOBSTER CSV (default: {MERGED_CSV.name})",
    )
    parser.add_argument(
        "--tickers",
        nargs="+",
        default=DEFAULT_TICKERS,
        help=f"Ticker tabs to display (default: {' '.join(DEFAULT_TICKERS)})",
    )
    args = parser.parse_args()

    if not args.csv.exists():
        print(f"[ERROR] merged CSV not found: {args.csv}")
        sys.exit(1)

    hub = TrackerHub(args.tickers)
    stop = threading.Event()
    tcp_client: TcpDuplex | None = None

    if args.offline:
        spawn_offline_merged(hub, args.csv, args.speed, args.orders, stop)
    else:
        tcp_client = TcpDuplex(
            hub, args.fpga_ip, args.port, args.csv, args.orders, args.speed,
            fallback_ticker=args.ticker,
        )
        if not tcp_client.start():
            print("[INFO] FPGA unavailable, falling back to offline merged replay")
            tcp_client = None
            spawn_offline_merged(hub, args.csv, args.speed, args.orders, stop)

    dashboard = Dashboard(hub, args.tickers)
    try:
        dashboard.mainloop()
    finally:
        stop.set()
        if tcp_client is not None:
            tcp_client.shutdown()


if __name__ == "__main__":
    main()
