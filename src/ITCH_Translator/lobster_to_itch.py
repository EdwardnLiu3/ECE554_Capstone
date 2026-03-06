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
    python lobster_to_itch.py <message_csv> <output_bin> [--ticker AMZN]

    python lobster_to_itch.py \\
        AMZN_2012-06-21_34200000_57600000_message_1.csv \\
        amzn_itch.bin \\
        --ticker AMZN
"""

import struct
import csv
import argparse
from pathlib import Path


# ---------------------------------------------------------------------------
# ITCH 5.0 encoder functions
# Each returns raw bytes for the ITCH message body (no length prefix).
# ---------------------------------------------------------------------------

STOCK_LOCATE  = 1     # Arbitrary; would be assigned by exchange
TRACKING_NUM  = 0     # Arbitrary


def _pack_timestamp(ts_seconds: float) -> bytes:
    """Convert seconds-since-midnight (float) to 6-byte big-endian nanoseconds."""
    ns = int(ts_seconds * 1_000_000_000)
    # Pack as 8-byte uint64 then slice the last 6 bytes (big-endian)
    return struct.pack(">Q", ns)[2:]


def _pack_stock(ticker: str) -> bytes:
    """8-byte left-justified, space-padded ASCII stock symbol."""
    return ticker[:8].ljust(8).encode("ascii")


def encode_add_order(ts: float, order_id: int, side: int,
                     shares: int, price: int, ticker: str) -> bytes:
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
        + struct.pack(">HH", STOCK_LOCATE, TRACKING_NUM)
        + _pack_timestamp(ts)
        + struct.pack(">Q", order_id)
        + buy_sell
        + struct.pack(">I", shares)
        + _pack_stock(ticker)
        + struct.pack(">I", price)
    )
    assert len(body) == 36, f"Add Order length mismatch: {len(body)}"
    return body


def encode_order_cancel(ts: float, order_id: int, cancelled_shares: int) -> bytes:
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
        + struct.pack(">HH", STOCK_LOCATE, TRACKING_NUM)
        + _pack_timestamp(ts)
        + struct.pack(">Q", order_id)
        + struct.pack(">I", cancelled_shares)
    )
    assert len(body) == 23, f"Order Cancel length mismatch: {len(body)}"
    return body


def encode_order_delete(ts: float, order_id: int) -> bytes:
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
        + struct.pack(">HH", STOCK_LOCATE, TRACKING_NUM)
        + _pack_timestamp(ts)
        + struct.pack(">Q", order_id)
    )
    assert len(body) == 19, f"Order Delete length mismatch: {len(body)}"
    return body


def encode_order_executed(ts: float, order_id: int,
                           executed_shares: int, match_number: int) -> bytes:
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
        + struct.pack(">HH", STOCK_LOCATE, TRACKING_NUM)
        + _pack_timestamp(ts)
        + struct.pack(">Q", order_id)
        + struct.pack(">I", executed_shares)
        + struct.pack(">Q", match_number)
    )
    assert len(body) == 31, f"Order Executed length mismatch: {len(body)}"
    return body


def encode_trade(ts: float, order_id: int, side: int,
                 shares: int, price: int, ticker: str, match_number: int) -> bytes:
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
        + struct.pack(">HH", STOCK_LOCATE, TRACKING_NUM)
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


def encode_trading_action(ts: float, price: int, ticker: str) -> bytes:
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
        + struct.pack(">HH", STOCK_LOCATE, TRACKING_NUM)
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

def translate_row(row: list[str], ticker: str, match_counter: list[int]) -> bytes | None:
    """
    Translate one LOBSTER message CSV row into a framed ITCH binary message.

    LOBSTER columns (0-indexed):
      0: time      (float, seconds since midnight)
      1: type      (int, 1-7)
      2: order_id  (int)
      3: size      (int, shares)
      4: price     (int, dollar * 10000)
      5: direction (int, 1=buy, -1=sell)

    Returns framed bytes, or None if the row is skipped.
    """
    ts        = float(row[0])
    msg_type  = int(row[1])
    order_id  = int(row[2])
    size      = int(row[3])
    price     = int(row[4])
    direction = int(row[5])

    if msg_type == 1:
        # New limit order -> Add Order
        body = encode_add_order(ts, order_id, direction, size, price, ticker)

    elif msg_type == 2:
        # Partial cancel -> Order Cancel
        body = encode_order_cancel(ts, order_id, size)

    elif msg_type == 3:
        # Full delete -> Order Delete
        body = encode_order_delete(ts, order_id)

    elif msg_type == 4:
        # Visible execution -> Order Executed
        match_counter[0] += 1
        body = encode_order_executed(ts, order_id, size, match_counter[0])

    elif msg_type == 5:
        # Hidden execution -> Non-Cross Trade (order_id=0 in LOBSTER)
        match_counter[0] += 1
        body = encode_trade(ts, 0, direction, size, price, ticker, match_counter[0])

    elif msg_type == 7:
        # Trading halt/resume -> Stock Trading Action
        body = encode_trading_action(ts, price, ticker)

    else:
        return None  # Unknown type, skip

    return frame_message(body)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def translate_file(message_csv: Path, output_bin: Path, ticker: str) -> None:
    match_counter = [0]  # mutable counter passed by reference
    total_rows = 0
    skipped = 0

    with open(message_csv, newline="") as csv_file, \
         open(output_bin, "wb") as out_file:

        reader = csv.reader(csv_file)
        for row in reader:
            if len(row) != 6:
                skipped += 1
                continue
            packet = translate_row(row, ticker, match_counter)
            if packet is None:
                skipped += 1
                continue
            out_file.write(packet)
            total_rows += 1

    print(f"Translated {total_rows} messages -> {output_bin}")
    if skipped:
        print(f"Skipped {skipped} rows (unknown type or malformed)")


def main():
    parser = argparse.ArgumentParser(description="LOBSTER CSV -> ITCH 5.0 binary translator")
    parser.add_argument("message_csv", type=Path, help="LOBSTER message CSV file")
    parser.add_argument("output_bin",  type=Path, help="Output binary file")
    parser.add_argument("--ticker", default="AMZN", help="Stock ticker symbol (default: AMZN)")
    args = parser.parse_args()

    translate_file(args.message_csv, args.output_bin, args.ticker)


if __name__ == "__main__":
    main()
