"""
fpga_simulator.py

Loopback test harness for hft_dashboard.py. Pretends to be the FPGA on the
wire so the dashboard can be exercised end-to-end without real hardware.

- Listens on TCP for a single dashboard connection.
- Decodes incoming SoupBinTCP-framed ITCH messages and prints them.
- Tracks the latest Add Order price per ticker.
- Periodically sends back 94-byte OUCH/Order_Generator payloads quoted
  around the current mark price (bid = mark - spread, ask = mark + spread)
  so the dashboard renders bid/ask scatter overlays. Enter ('O') is the
  default; --enable-replace switches to Replace ('U') after N Enters per
  ticker so the Replace decode path is exercised too.

Usage:
    # Terminal A - start the simulator
    python fpga_simulator.py --port 7000

    # Terminal B - point the dashboard at it
    python hft_dashboard.py --fpga-ip 127.0.0.1 --port 7000

Notes:
  * The dashboard filters bid/ask scatter to price > $200 (see Dashboard /
    fpga_payload). AAPL, AMZN, GOOG will plot; INTC ($27) and MSFT ($30)
    will be received but not drawn.
  * Replace messages don't carry a symbol field, so the dashboard attributes
    them via its --ticker fallback. For clean per-ticker visuals, leave
    Replace disabled (the default).
"""

from __future__ import annotations

import argparse
import socket
import struct
import threading
import time
from collections import defaultdict
from dataclasses import dataclass


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 7000

OUCH_PAYLOAD_BYTES = 94      # 752 bits = two 376-bit messages
MSG_ENTER = 0x4F             # 'O'
MSG_REPLACE = 0x55           # 'U'
# Match pythonExecution/execution_trackers.py
QUOTE_BID = 0
QUOTE_ASK = 1


# ---------------------------------------------------------------------------
# ITCH 5.0 decode (mirror of lobster_to_itch.encode_*)
# ---------------------------------------------------------------------------

def decode_itch(body: bytes) -> dict | None:
    if not body:
        return None
    msg_type = chr(body[0])
    if msg_type == "A" and len(body) >= 36:
        return {
            "msg": "A",
            "ts_ns": int.from_bytes(body[5:11], "big"),
            "oid": struct.unpack(">Q", body[11:19])[0],
            "side": chr(body[19]),
            "shares": struct.unpack(">I", body[20:24])[0],
            "ticker": body[24:32].decode("ascii", errors="replace").strip(),
            "price": struct.unpack(">I", body[32:36])[0],
        }
    if msg_type == "X" and len(body) >= 23:
        return {
            "msg": "X",
            "oid": struct.unpack(">Q", body[11:19])[0],
            "cancelled": struct.unpack(">I", body[19:23])[0],
        }
    if msg_type == "D" and len(body) >= 19:
        return {"msg": "D", "oid": struct.unpack(">Q", body[11:19])[0]}
    if msg_type == "E" and len(body) >= 31:
        return {
            "msg": "E",
            "oid": struct.unpack(">Q", body[11:19])[0],
            "executed": struct.unpack(">I", body[19:23])[0],
            "match": struct.unpack(">Q", body[23:31])[0],
        }
    if msg_type == "P" and len(body) >= 44:
        return {
            "msg": "P",
            "oid": struct.unpack(">Q", body[11:19])[0],
            "side": chr(body[19]),
            "shares": struct.unpack(">I", body[20:24])[0],
            "ticker": body[24:32].decode("ascii", errors="replace").strip(),
            "price": struct.unpack(">I", body[32:36])[0],
            "match": struct.unpack(">Q", body[36:44])[0],
        }
    if msg_type == "H" and len(body) >= 25:
        return {
            "msg": "H",
            "ticker": body[11:19].decode("ascii", errors="replace").strip(),
            "state": chr(body[19]),
        }
    return {"msg": msg_type, "len": len(body)}


# ---------------------------------------------------------------------------
# OUCH / Order_Generator payload build (mirror of execution_trackers.build_*)
# ---------------------------------------------------------------------------

def build_enter_message(order_id: int, side: int, price_cents: int,
                        quantity: int, ticker: str) -> int:
    """One 376-bit Enter message (matches execution_trackers.build_enter_message)."""
    symbol = ticker[:8].ljust(8).encode("ascii")
    value = 0
    value = (value << 8)  | MSG_ENTER
    value = (value << 32) | (order_id & 0xFFFFFFFF)
    value = (value << 8)  | (0x42 if side == QUOTE_BID else 0x53)   # 'B' / 'S'
    value = (value << 32) | (quantity & 0xFFFFFFFF)
    value = (value << 64) | int.from_bytes(symbol, "big")
    value = (value << 64) | (price_cents & ((1 << 64) - 1))
    value = (value << 168)
    return value


def build_replace_message(old_id: int, new_id: int, price_cents: int,
                          quantity: int) -> int:
    """One 376-bit Replace message."""
    value = 0
    value = (value << 8)  | MSG_REPLACE
    value = (value << 32) | (old_id & 0xFFFFFFFF)
    value = (value << 32) | (new_id & 0xFFFFFFFF)
    value = (value << 32) | (quantity & 0xFFFFFFFF)
    value = (value << 64) | (price_cents & ((1 << 64) - 1))
    value = (value << 208)
    return value


def pack_payload(upper: int, lower: int) -> bytes:
    """Combine two 376-bit messages into one 94-byte big-endian frame."""
    value = (upper << 376) | lower
    return value.to_bytes(OUCH_PAYLOAD_BYTES, "big")


# ---------------------------------------------------------------------------
# Per-ticker state
# ---------------------------------------------------------------------------

@dataclass
class TickerState:
    last_price_dollar10k: int = 0   # ITCH 'A' price scale (dollars * 10000)
    last_bid_id: int = 0
    last_ask_id: int = 0
    enters_sent: int = 0


# ---------------------------------------------------------------------------
# Simulator
# ---------------------------------------------------------------------------

class Simulator:
    def __init__(self, host: str, port: int, quote_interval: float,
                 spread_cents: int, quote_qty: int,
                 enable_replace: bool, replace_after: int) -> None:
        self.host = host
        self.port = port
        self.quote_interval = quote_interval
        self.spread_cents = spread_cents
        self.quote_qty = quote_qty
        self.enable_replace = enable_replace
        self.replace_after = replace_after

        self.lock = threading.Lock()
        self.states: dict[str, TickerState] = defaultdict(TickerState)
        self.next_oid = 1
        self.session_stop = threading.Event()

    def serve_forever(self) -> None:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((self.host, self.port))
        srv.listen(1)
        srv.settimeout(1.0)
        print(f"[SIM] listening on {self.host}:{self.port}")
        try:
            while True:
                try:
                    conn, addr = srv.accept()
                except socket.timeout:
                    continue
                conn.settimeout(None)
                print(f"[SIM] dashboard connected from {addr}")
                self._serve_session(conn)
                print("[SIM] dashboard disconnected, waiting for next connection")
        finally:
            srv.close()

    def _serve_session(self, conn: socket.socket) -> None:
        self.session_stop = threading.Event()
        with self.lock:
            self.states.clear()
            self.next_oid = 1

        recv_thread = threading.Thread(
            target=self._recv_loop, args=(conn,), name="sim-recv", daemon=True
        )
        send_thread = threading.Thread(
            target=self._send_loop, args=(conn,), name="sim-send", daemon=True
        )
        recv_thread.start()
        send_thread.start()
        recv_thread.join()
        self.session_stop.set()
        send_thread.join(timeout=2.0)
        try:
            conn.close()
        except OSError:
            pass

    def _recv_loop(self, conn: socket.socket) -> None:
        buf = bytearray()
        while not self.session_stop.is_set():
            try:
                chunk = conn.recv(4096)
            except OSError:
                break
            if not chunk:
                break
            buf.extend(chunk)
            self._drain_frames(buf)

    def _drain_frames(self, buf: bytearray) -> None:
        while True:
            if len(buf) < 2:
                return
            plen = struct.unpack(">H", bytes(buf[:2]))[0]
            if len(buf) < 2 + plen:
                return
            payload = bytes(buf[2:2 + plen])
            del buf[:2 + plen]
            if not payload:
                continue
            pkt_type = chr(payload[0])
            body = payload[1:]
            self._observe(pkt_type, decode_itch(body))

    def _observe(self, pkt_type: str, msg: dict | None) -> None:
        if msg is None:
            return
        if msg.get("msg") == "A":
            with self.lock:
                self.states[msg["ticker"]].last_price_dollar10k = msg["price"]
            print(f"[ITCH {pkt_type}] A oid={msg['oid']:>6} {msg['side']} "
                  f"shares={msg['shares']:>5} {msg['ticker']:<5} "
                  f"${msg['price'] / 10000:>9.2f}")
        elif msg.get("msg") == "X":
            print(f"[ITCH {pkt_type}] X oid={msg['oid']:>6} cancelled={msg['cancelled']}")
        elif msg.get("msg") == "D":
            print(f"[ITCH {pkt_type}] D oid={msg['oid']:>6}")
        elif msg.get("msg") == "E":
            print(f"[ITCH {pkt_type}] E oid={msg['oid']:>6} exec={msg['executed']:>5} "
                  f"match={msg['match']}")
        elif msg.get("msg") == "P":
            print(f"[ITCH {pkt_type}] P {msg['side']} shares={msg['shares']:>5} "
                  f"{msg['ticker']:<5} ${msg['price'] / 10000:>9.2f} match={msg['match']}")
        elif msg.get("msg") == "H":
            print(f"[ITCH {pkt_type}] H {msg['ticker']:<5} state={msg['state']}")
        else:
            print(f"[ITCH {pkt_type}] {msg}")

    def _send_loop(self, conn: socket.socket) -> None:
        while not self.session_stop.is_set():
            time.sleep(self.quote_interval)
            with self.lock:
                snapshot = [
                    (ticker, state.last_price_dollar10k)
                    for ticker, state in self.states.items()
                    if state.last_price_dollar10k > 0
                ]
            for ticker, _price in snapshot:
                payload = self._build_quote(ticker)
                if payload is None:
                    continue
                try:
                    conn.sendall(payload)
                except OSError:
                    return

    def _take_oid(self) -> int:
        oid = self.next_oid
        self.next_oid += 1
        return oid

    def _build_quote(self, ticker: str) -> bytes | None:
        with self.lock:
            state = self.states[ticker]
            price_cents = state.last_price_dollar10k // 100
            if price_cents <= 0:
                return None

            bid_price = max(1, price_cents - self.spread_cents)
            ask_price = price_cents + self.spread_cents

            use_replace = (
                self.enable_replace
                and state.enters_sent >= self.replace_after
                and state.last_bid_id != 0
                and state.last_ask_id != 0
            )

            if use_replace:
                old_bid, old_ask = state.last_bid_id, state.last_ask_id
                new_bid = self._take_oid()
                new_ask = self._take_oid()
                state.last_bid_id, state.last_ask_id = new_bid, new_ask
                # Decoder side mapping: upper=BID, lower=ASK
                upper = build_replace_message(old_bid, new_bid, bid_price, self.quote_qty)
                lower = build_replace_message(old_ask, new_ask, ask_price, self.quote_qty)
                kind = "U"
            else:
                bid_id = self._take_oid()
                ask_id = self._take_oid()
                state.last_bid_id, state.last_ask_id = bid_id, ask_id
                state.enters_sent += 1
                upper = build_enter_message(bid_id, QUOTE_BID, bid_price,
                                            self.quote_qty, ticker)
                lower = build_enter_message(ask_id, QUOTE_ASK, ask_price,
                                            self.quote_qty, ticker)
                kind = "O"

        print(f"[OUCH {kind}] {ticker:<5} bid=${bid_price/100:>7.2f} "
              f"ask=${ask_price/100:>7.2f} qty={self.quote_qty}")
        return pack_payload(upper, lower)


def main() -> None:
    parser = argparse.ArgumentParser(description="Loopback FPGA simulator for hft_dashboard.py")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"Listen address (default: {DEFAULT_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--interval", type=float, default=0.5,
                        help="Seconds between OUCH payloads per ticker (default: 0.5)")
    parser.add_argument("--spread", type=int, default=5,
                        help="Bid/ask spread in cents around the mark price (default: 5)")
    parser.add_argument("--qty", type=int, default=100,
                        help="Quoted size per side (default: 100)")
    parser.add_argument("--enable-replace", action="store_true",
                        help="After --replace-after Enters per ticker, switch to Replace messages")
    parser.add_argument("--replace-after", type=int, default=3,
                        help="Number of Enter payloads per ticker before switching to Replace (default: 3)")
    args = parser.parse_args()

    sim = Simulator(
        host=args.host,
        port=args.port,
        quote_interval=args.interval,
        spread_cents=args.spread,
        quote_qty=args.qty,
        enable_replace=args.enable_replace,
        replace_after=args.replace_after,
    )
    try:
        sim.serve_forever()
    except KeyboardInterrupt:
        print("\n[SIM] shutting down")


if __name__ == "__main__":
    main()
