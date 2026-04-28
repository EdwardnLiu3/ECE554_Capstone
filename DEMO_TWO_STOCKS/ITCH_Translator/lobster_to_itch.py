"""
lobster_to_itch.py

Translates LOBSTER message CSV files into NASDAQ ITCH 5.0 binary messages.
Each output message is framed with a 2-byte big-endian length prefix (SoupBinTCP style),
followed by a 1-byte packet type ('S') and the raw ITCH message body.

LOBSTER message types -> ITCH 5.0 message types:
  1 (new limit order)     -> 'A'  Add Order (No MPID)
  2 (partial cancel)      -> 'X'  Order Cancel
  3 (full delete)         -> 'D'  Order Delete
  4 (visible execution)   -> 'E'  Order Executed
  5 (hidden execution)    -> 'P'  Non-Cross Trade
  7 (trading halt)        -> 'H'  Stock Trading Action

Usage:
    python lobster_to_itch.py <message_csv> <output_bin> [--ticker INTC]

    python lobster_to_itch.py \\
        two_stock_style_hour_message_clean_merged.csv \\
        two_stock_itch.bin \\
        --ticker INTC
"""

import struct
import csv
import argparse
from pathlib import Path


# ---------------------------------------------------------------------------
# ITCH 5.0 encoder functions
# Each returns raw bytes for the ITCH message body (no length prefix).
# ---------------------------------------------------------------------------
#Todo: hashtable for orderID  key: Order ID, value: numerical numbers (1,2,3,4....)
DEFAULT_STOCK_LOCATE = 1
TRACKING_NUM  = 0     # Arbitrary
STOCK_ID_TO_TICKER = {
    1: "INTC",
    2: "MSFT",
}
MAX_MAPPED_ORDER_ID = (1 << 14) - 1


def _ensure_allocator_state(order_id_state: dict) -> dict:
    if "raw_to_mapped" not in order_id_state:
        order_id_state["raw_to_mapped"] = {}
        order_id_state["remaining_qty"] = {}
        order_id_state["free_ids"] = {}
        order_id_state["next_id"] = {}
        order_id_state["peak_active"] = {}
        order_id_state["max_assigned"] = {}
    return order_id_state


def _allocator_active_count(order_id_state: dict, stock_locate: int) -> int:
    state = _ensure_allocator_state(order_id_state)
    return sum(1 for key in state["raw_to_mapped"] if key[0] == stock_locate)


def _allocator_alloc(order_id_state: dict, stock_locate: int, raw_oid: int, size: int) -> int:
    state = _ensure_allocator_state(order_id_state)
    raw_to_mapped = state["raw_to_mapped"]
    remaining_qty = state["remaining_qty"]
    free_ids = state["free_ids"].setdefault(stock_locate, [])
    next_id = state["next_id"].get(stock_locate, 1)
    order_key = (stock_locate, raw_oid)

    if order_key in raw_to_mapped:
        mapped_oid = raw_to_mapped[order_key]
    elif free_ids:
        mapped_oid = free_ids.pop()
        raw_to_mapped[order_key] = mapped_oid
    else:
        mapped_oid = next_id
        if mapped_oid > MAX_MAPPED_ORDER_ID:
            raise ValueError(
                f"Ran out of mapped order IDs for stock_id={stock_locate}; "
                f"peak active orders exceed {MAX_MAPPED_ORDER_ID}."
            )
        raw_to_mapped[order_key] = mapped_oid
        state["next_id"][stock_locate] = mapped_oid + 1
        state["max_assigned"][stock_locate] = max(mapped_oid, state["max_assigned"].get(stock_locate, 0))

    remaining_qty[order_key] = size
    state["peak_active"][stock_locate] = max(
        _allocator_active_count(state, stock_locate),
        state["peak_active"].get(stock_locate, 0),
    )
    return mapped_oid


def _allocator_lookup(order_id_state: dict, stock_locate: int, raw_oid: int) -> int:
    state = _ensure_allocator_state(order_id_state)
    return state["raw_to_mapped"].get((stock_locate, raw_oid), 0)


def _allocator_release(order_id_state: dict, stock_locate: int, raw_oid: int) -> None:
    state = _ensure_allocator_state(order_id_state)
    order_key = (stock_locate, raw_oid)
    mapped_oid = state["raw_to_mapped"].pop(order_key, None)
    state["remaining_qty"].pop(order_key, None)
    if mapped_oid is not None:
        state["free_ids"].setdefault(stock_locate, []).append(mapped_oid)


def _allocator_reduce(order_id_state: dict, stock_locate: int, raw_oid: int, delta_qty: int) -> int:
    state = _ensure_allocator_state(order_id_state)
    order_key = (stock_locate, raw_oid)
    mapped_oid = state["raw_to_mapped"].get(order_key, 0)
    if mapped_oid == 0:
        return 0

    current_qty = state["remaining_qty"].get(order_key, 0)
    new_qty = current_qty - delta_qty
    if new_qty <= 0:
        _allocator_release(state, stock_locate, raw_oid)
    else:
        state["remaining_qty"][order_key] = new_qty
    return mapped_oid


def _pack_timestamp(ts_seconds: float) -> bytes:
    """Convert seconds-since-midnight (float) to 6-byte big-endian nanoseconds."""
    ns = int(ts_seconds * 1_000_000_000)
    # Pack as 8-byte uint64 then slice the last 6 bytes (big-endian)
    return struct.pack(">Q", ns)[2:]


def _pack_stock(ticker: str) -> bytes:
    """8-byte left-justified, space-padded ASCII stock symbol."""
    return ticker[:8].ljust(8).encode("ascii")


def encode_add_order(ts: float, order_id: int, side: int,
                     shares: int, price: int, ticker: str,
                     stock_locate: int = DEFAULT_STOCK_LOCATE) -> bytes:
    """
    ITCH 'A' - Add Order (No MPID Attribution)
    Total: 36 bytes
      1  Message Type       char
      2  Stock Locate       uint16
      2  Tracking Number    uint16
      6  Timestamp          uint48 (ns)
      8  Order Ref Number   uint64
      1  Buy/Sell           char  'B'=buy, 'S'=sell
      4  Shares             uint32
      8  Stock              alpha8
      4  Price              uint32 (price * 10000 already in LOBSTER)
    """
    buy_sell = b'B' if side == 1 else b'S'
    body = (
        b'A'
        + struct.pack(">HH", stock_locate, TRACKING_NUM)
        + _pack_timestamp(ts)
        + struct.pack(">Q", order_id)
        + buy_sell
        + struct.pack(">I", shares)
        + _pack_stock(ticker)
        + struct.pack(">I", price)
    )
    assert len(body) == 36, f"Add Order length mismatch: {len(body)}"
    return body


def encode_order_cancel(ts: float, order_id: int, cancelled_shares: int,
                        stock_locate: int = DEFAULT_STOCK_LOCATE) -> bytes:
    """
    ITCH 'X' - Order Cancel
    Total: 23 bytes
      1  Message Type       char
      2  Stock Locate       uint16
      2  Tracking Number    uint16
      6  Timestamp          uint48 (ns)
      8  Order Ref Number   uint64
      4  Cancelled Shares   uint32
    """
    body = (
        b'X'
        + struct.pack(">HH", stock_locate, TRACKING_NUM)
        + _pack_timestamp(ts)
        + struct.pack(">Q", order_id)
        + struct.pack(">I", cancelled_shares)
    )
    assert len(body) == 23, f"Order Cancel length mismatch: {len(body)}"
    return body


def encode_order_delete(ts: float, order_id: int,
                        stock_locate: int = DEFAULT_STOCK_LOCATE) -> bytes:
    """
    ITCH 'D' - Order Delete
    Total: 19 bytes
      1  Message Type       char
      2  Stock Locate       uint16
      2  Tracking Number    uint16
      6  Timestamp          uint48 (ns)
      8  Order Ref Number   uint64
    """
    body = (
        b'D'
        + struct.pack(">HH", stock_locate, TRACKING_NUM)
        + _pack_timestamp(ts)
        + struct.pack(">Q", order_id)
    )
    assert len(body) == 19, f"Order Delete length mismatch: {len(body)}"
    return body


def encode_order_executed(ts: float, order_id: int,
                           executed_shares: int, match_number: int,
                           stock_locate: int = DEFAULT_STOCK_LOCATE) -> bytes:
    """
    ITCH 'E' - Order Executed
    Total: 31 bytes
      1  Message Type       char
      2  Stock Locate       uint16
      2  Tracking Number    uint16
      6  Timestamp          uint48 (ns)
      8  Order Ref Number   uint64
      4  Executed Shares    uint32
      8  Match Number       uint64
    """
    body = (
        b'E'
        + struct.pack(">HH", stock_locate, TRACKING_NUM)
        + _pack_timestamp(ts)
        + struct.pack(">Q", order_id)
        + struct.pack(">I", executed_shares)
        + struct.pack(">Q", match_number)
    )
    assert len(body) == 31, f"Order Executed length mismatch: {len(body)}"
    return body


def encode_trade(ts: float, order_id: int, side: int,
                 shares: int, price: int, ticker: str, match_number: int,
                 stock_locate: int = DEFAULT_STOCK_LOCATE) -> bytes:
    """
    ITCH 'P' - Non-Cross Trade (used for hidden order executions, LOBSTER type 5)
    Total: 44 bytes
      1  Message Type       char
      2  Stock Locate       uint16
      2  Tracking Number    uint16
      6  Timestamp          uint48 (ns)
      8  Order Ref Number   uint64  (0 for hidden)
      1  Buy/Sell           char
      4  Shares             uint32
      8  Stock              alpha8
      4  Price              uint32
      8  Match Number       uint64
    """
    buy_sell = b'B' if side == 1 else b'S'
    body = (
        b'P'
        + struct.pack(">HH", stock_locate, TRACKING_NUM)
        + _pack_timestamp(ts)
        + struct.pack(">Q", order_id)
        + buy_sell
        + struct.pack(">I", shares)
        + _pack_stock(ticker)
        + struct.pack(">I", price)
        + struct.pack(">Q", match_number)
    )
    assert len(body) == 44, f"Trade length mismatch: {len(body)}"
    return body


def encode_trading_action(ts: float, price: int, ticker: str,
                          stock_locate: int = DEFAULT_STOCK_LOCATE) -> bytes:
    """
    ITCH 'H' - Stock Trading Action (LOBSTER type 7)
    Total: 25 bytes
      1  Message Type       char
      2  Stock Locate       uint16
      2  Tracking Number    uint16
      6  Timestamp          uint48 (ns)
      8  Stock              alpha8
      1  Trading State      char  'H'=halted, 'Q'=quoting, 'T'=trading
      1  Reserved           char
      4  Reason             alpha4

    LOBSTER encodes halt state in the price field:
      price = -1 -> halt
      price =  0 -> quoting (resume quoting)
      price =  1 -> trading (resume trading)
    """
    if price == -1:
        state = b'H'
    elif price == 0:
        state = b'Q'
    else:
        state = b'T'

    body = (
        b'H'
        + struct.pack(">HH", stock_locate, TRACKING_NUM)
        + _pack_timestamp(ts)
        + _pack_stock(ticker)
        + state
        + b' '          # Reserved
        + b'    '       # Reason (4 bytes, blank = unspecified)
    )
    assert len(body) == 25, f"Trading Action length mismatch: {len(body)}"
    return body


# ---------------------------------------------------------------------------
# SoupBinTCP framing
# ---------------------------------------------------------------------------

def frame_message(itch_body: bytes) -> bytes:
    """
    Wrap an ITCH body in SoupBinTCP framing:
      2 bytes: big-endian length of (packet_type + body)
      1 byte:  packet type = 'S' (Sequenced Data)
      N bytes: ITCH message body
    """
    payload = b'S' + itch_body
    return struct.pack(">H", len(payload)) + payload


# ---------------------------------------------------------------------------
# LOBSTER row -> ITCH message
# ---------------------------------------------------------------------------

def translate_row(row: list[str], ticker: str, match_counter: list[int],
                  order_id_state: dict) -> bytes | None:
    """
    Translate one LOBSTER message CSV row into a framed ITCH binary message.

    LOBSTER columns (0-indexed):
      0: time      (float, seconds since midnight)
      1: type      (int, 1-7)
      2: order_id  (int)
      3: size      (int, shares)
      4: price     (int, dollar * 10000)
      5: direction (int, 1=buy, -1=sell)
      6: stock_id  (optional int, defaults to 1 when omitted)

    order_id_state: allocator state that maps visible order IDs into a bounded
                    reusable integer space. IDs are recycled after delete or
                    after cancel/execute drives remaining visible quantity to 0.

    Returns framed bytes, or None if the row is skipped.
    """
    ts         = float(row[0])
    msg_type   = int(row[1])
    raw_oid    = int(row[2])
    size       = int(row[3])
    price      = int(row[4])
    direction  = int(row[5])
    stock_locate = int(row[6]) if len(row) >= 7 else DEFAULT_STOCK_LOCATE
    row_ticker = STOCK_ID_TO_TICKER.get(stock_locate, ticker)
    if msg_type == 1:
        mapped_oid = _allocator_alloc(order_id_state, stock_locate, raw_oid, size)
    elif msg_type == 5:
        mapped_oid = 0
    elif msg_type == 7:
        mapped_oid = 0
    elif msg_type == 2 or msg_type == 4:
        mapped_oid = _allocator_reduce(order_id_state, stock_locate, raw_oid, size)
    elif msg_type == 3:
        mapped_oid = _allocator_lookup(order_id_state, stock_locate, raw_oid)
        if mapped_oid != 0:
            _allocator_release(order_id_state, stock_locate, raw_oid)
    else:
        mapped_oid = _allocator_lookup(order_id_state, stock_locate, raw_oid)

    if msg_type == 1:
        body = encode_add_order(ts, mapped_oid, direction, size, price, row_ticker, stock_locate)

    elif msg_type == 2:
        body = encode_order_cancel(ts, mapped_oid, size, stock_locate)

    elif msg_type == 3:
        body = encode_order_delete(ts, mapped_oid, stock_locate)

    elif msg_type == 4:
        match_counter[0] += 1
        body = encode_order_executed(ts, mapped_oid, size, match_counter[0], stock_locate)

    elif msg_type == 5:
        match_counter[0] += 1
        body = encode_trade(ts, 0, direction, size, price, row_ticker, match_counter[0], stock_locate)

    elif msg_type == 7:
        body = encode_trading_action(ts, price, row_ticker, stock_locate)

    else:
        return None  # Unknown type, skip

    return frame_message(body)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def translate_file(message_csv: Path, output_bin: Path, ticker: str) -> None:
    match_counter = [0]   # mutable counter passed by reference
    order_id_state = {}
    total_rows = 0
    skipped = 0

    with open(message_csv, newline="") as csv_file, \
         open(output_bin, "wb") as out_file:

        reader = csv.reader(csv_file)
        for row in reader:
            if len(row) not in (6, 7):
                skipped += 1
                continue
            packet = translate_row(row, ticker, match_counter, order_id_state)
            if packet is None:
                skipped += 1
                continue
            out_file.write(packet)
            total_rows += 1

    print(f"Translated {total_rows} messages -> {output_bin}")
    state = _ensure_allocator_state(order_id_state)
    print(f"Peak active mapped IDs: {state['peak_active']}")
    print(f"Max mapped ID assigned: {state['max_assigned']}")
    if skipped:
        print(f"Skipped {skipped} rows (unknown type or malformed)")


def main():
    parser = argparse.ArgumentParser(description="LOBSTER CSV -> ITCH 5.0 binary translator")
    parser.add_argument("message_csv", type=Path, help="LOBSTER message CSV file")
    parser.add_argument("output_bin",  type=Path, help="Output binary file")
    parser.add_argument("--ticker", default="INTC", help="Stock ticker symbol (default: INTC)")
    args = parser.parse_args()

    translate_file(args.message_csv, args.output_bin, args.ticker)


if __name__ == "__main__":
    main()
