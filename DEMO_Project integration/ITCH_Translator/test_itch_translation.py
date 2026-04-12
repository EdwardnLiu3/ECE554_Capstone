"""
test_itch_translation.py

Verifies that amzn_itch.bin was correctly translated from the LOBSTER CSV.

For every row in the LOBSTER message CSV this script:
  1. Decodes the corresponding ITCH message from the .bin file
  2. Checks message type, framing length, timestamp, order_id, shares, price,
     side, and stock ticker against what the encoder should have produced.

Usage:
    py test_itch_translation.py
"""

import struct
import csv
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
DATA_DIR   = Path(__file__).parent / "LOBSTER_SampleFile_AMZN_2012-06-21_1"
CSV_FILE   = DATA_DIR / "AMZN_2012-06-21_34200000_57600000_message_1.csv"
BIN_FILE   = DATA_DIR / "amzn_itch.bin"
TICKER     = "AMZN"

# Expected ITCH message lengths (body only, excluding framing)
MSG_LENGTHS = {'A': 36, 'X': 23, 'D': 19, 'E': 31, 'P': 44, 'H': 25}

# LOBSTER type -> expected ITCH type char
LOBSTER_TO_ITCH = {1: 'A', 2: 'X', 3: 'D', 4: 'E', 5: 'P', 7: 'H'}

STOCK_LOCATE = 1
TRACKING_NUM = 0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def unpack_timestamp(ts_bytes: bytes) -> int:
    """6-byte big-endian uint48 -> nanoseconds."""
    return struct.unpack(">Q", b'\x00\x00' + ts_bytes)[0]

def ts_to_ns(seconds: float) -> int:
    return int(seconds * 1_000_000_000)

def unpack_stock(stock_bytes: bytes) -> str:
    return stock_bytes.decode("ascii").rstrip()

# ---------------------------------------------------------------------------
# ITCH binary parser
# ---------------------------------------------------------------------------

def parse_itch_messages(bin_path: Path) -> list[dict]:
    """
    Read the SoupBinTCP-framed binary file and return a list of decoded dicts,
    one per message.
    """
    messages = []
    data = bin_path.read_bytes()
    offset = 0

    while offset < len(data):
        if offset + 2 > len(data):
            raise ValueError(f"Truncated length field at offset {offset}")

        frame_len = struct.unpack_from(">H", data, offset)[0]
        offset += 2

        if offset + frame_len > len(data):
            raise ValueError(f"Truncated frame body at offset {offset}")

        pkt_type = chr(data[offset])
        body     = data[offset + 1 : offset + frame_len]  # ITCH body (excludes 'S' byte)
        offset  += frame_len

        msg = _decode_body(pkt_type, body, frame_len)
        messages.append(msg)

    return messages


def _decode_body(pkt_type: str, body: bytes, frame_len: int) -> dict:
    if pkt_type != 'S':
        return {"error": f"unexpected packet type {pkt_type!r}"}

    msg_type = chr(body[0])
    d = {"itch_type": msg_type, "frame_len": frame_len, "body_len": len(body)}

    if msg_type not in MSG_LENGTHS:
        return {**d, "error": f"unknown ITCH type {msg_type!r}"}

    # All messages share the same header layout after the type byte
    # [0]     msg_type  1 byte
    # [1:3]   locate    2 bytes
    # [3:5]   tracking  2 bytes
    # [5:11]  timestamp 6 bytes
    d["stock_locate"]  = struct.unpack_from(">H", body, 1)[0]
    d["tracking_num"]  = struct.unpack_from(">H", body, 3)[0]
    d["timestamp_ns"]  = unpack_timestamp(body[5:11])

    if msg_type == 'A':    # Add Order
        d["order_id"] = struct.unpack_from(">Q", body, 11)[0]
        d["side"]     = chr(body[19])           # 'B' or 'S'
        d["shares"]   = struct.unpack_from(">I", body, 20)[0]
        d["stock"]    = unpack_stock(body[24:32])
        d["price"]    = struct.unpack_from(">I", body, 32)[0]

    elif msg_type == 'X':  # Order Cancel
        d["order_id"]         = struct.unpack_from(">Q", body, 11)[0]
        d["cancelled_shares"] = struct.unpack_from(">I", body, 19)[0]

    elif msg_type == 'D':  # Order Delete
        d["order_id"] = struct.unpack_from(">Q", body, 11)[0]

    elif msg_type == 'E':  # Order Executed
        d["order_id"]        = struct.unpack_from(">Q", body, 11)[0]
        d["executed_shares"] = struct.unpack_from(">I", body, 19)[0]
        d["match_number"]    = struct.unpack_from(">Q", body, 23)[0]

    elif msg_type == 'P':  # Non-Cross Trade
        d["order_id"]     = struct.unpack_from(">Q", body, 11)[0]
        d["side"]         = chr(body[19])
        d["shares"]       = struct.unpack_from(">I", body, 20)[0]
        d["stock"]        = unpack_stock(body[24:32])
        d["price"]        = struct.unpack_from(">I", body, 32)[0]
        d["match_number"] = struct.unpack_from(">Q", body, 36)[0]

    elif msg_type == 'H':  # Stock Trading Action
        d["stock"]         = unpack_stock(body[11:19])
        d["trading_state"] = chr(body[19])

    return d

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

def run_tests(csv_path: Path, messages: list[dict], ticker: str) -> None:
    passed = 0
    failed = 0
    match_counter = 0
    order_id_map  = {}    # mirrors the hashtable in the translator
    errors = []

    with open(csv_path, newline="") as f:
        reader = csv.reader(f)
        for row_num, row in enumerate(reader, start=1):
            if len(row) != 6:
                continue

            ts        = float(row[0])
            lob_type  = int(row[1])
            raw_oid   = int(row[2])
            size      = int(row[3])
            price     = int(row[4])
            direction = int(row[5])

            if lob_type not in LOBSTER_TO_ITCH:
                continue  # skipped by translator

            # Mirror the translator's hashtable logic to get the expected mapped ID
            if lob_type == 1:
                mapped_oid = len(order_id_map) + 1
                order_id_map[raw_oid] = mapped_oid
            elif lob_type in (5, 7):
                mapped_oid = 0
            else:
                if raw_oid not in order_id_map:
                    order_id_map[raw_oid] = len(order_id_map) + 1
                mapped_oid = order_id_map[raw_oid]

            msg_idx = passed + failed
            if msg_idx >= len(messages):
                errors.append(f"Row {row_num}: ran out of ITCH messages")
                failed += 1
                continue

            m = messages[msg_idx]
            expected_type = LOBSTER_TO_ITCH[lob_type]
            expected_ns   = ts_to_ns(ts)
            row_errors    = []

            # --- framing length ---
            expected_frame_len = 1 + MSG_LENGTHS[expected_type]  # 'S' byte + body
            if m["frame_len"] != expected_frame_len:
                row_errors.append(
                    f"frame_len {m['frame_len']} != {expected_frame_len}"
                )

            # --- ITCH message type ---
            if m.get("itch_type") != expected_type:
                row_errors.append(
                    f"itch_type {m.get('itch_type')!r} != {expected_type!r}"
                )

            # --- header fields ---
            if m.get("stock_locate") != STOCK_LOCATE:
                row_errors.append(f"stock_locate {m.get('stock_locate')} != {STOCK_LOCATE}")
            if m.get("tracking_num") != TRACKING_NUM:
                row_errors.append(f"tracking_num {m.get('tracking_num')} != {TRACKING_NUM}")

            # --- timestamp (allow ±1 ns for float rounding) ---
            actual_ns = m.get("timestamp_ns", -1)
            if abs(actual_ns - expected_ns) > 1:
                row_errors.append(f"timestamp {actual_ns} != {expected_ns}")

            # --- type-specific fields ---
            if expected_type == 'A':
                if m.get("order_id") != mapped_oid:
                    row_errors.append(f"order_id {m.get('order_id')} != {mapped_oid} (raw={raw_oid})")
                expected_side = 'B' if direction == 1 else 'S'
                if m.get("side") != expected_side:
                    row_errors.append(f"side {m.get('side')!r} != {expected_side!r}")
                if m.get("shares") != size:
                    row_errors.append(f"shares {m.get('shares')} != {size}")
                if m.get("stock") != ticker:
                    row_errors.append(f"stock {m.get('stock')!r} != {ticker!r}")
                if m.get("price") != price:
                    row_errors.append(f"price {m.get('price')} != {price}")

            elif expected_type == 'X':
                if m.get("order_id") != mapped_oid:
                    row_errors.append(f"order_id {m.get('order_id')} != {mapped_oid} (raw={raw_oid})")
                if m.get("cancelled_shares") != size:
                    row_errors.append(f"cancelled_shares {m.get('cancelled_shares')} != {size}")

            elif expected_type == 'D':
                if m.get("order_id") != mapped_oid:
                    row_errors.append(f"order_id {m.get('order_id')} != {mapped_oid} (raw={raw_oid})")

            elif expected_type == 'E':
                match_counter += 1
                if m.get("order_id") != mapped_oid:
                    row_errors.append(f"order_id {m.get('order_id')} != {mapped_oid} (raw={raw_oid})")
                if m.get("executed_shares") != size:
                    row_errors.append(f"executed_shares {m.get('executed_shares')} != {size}")
                if m.get("match_number") != match_counter:
                    row_errors.append(f"match_number {m.get('match_number')} != {match_counter}")

            elif expected_type == 'P':
                match_counter += 1
                if m.get("order_id") != 0:
                    row_errors.append(f"order_id {m.get('order_id')} != 0 (hidden)")
                expected_side = 'B' if direction == 1 else 'S'
                if m.get("side") != expected_side:
                    row_errors.append(f"side {m.get('side')!r} != {expected_side!r}")
                if m.get("shares") != size:
                    row_errors.append(f"shares {m.get('shares')} != {size}")
                if m.get("stock") != ticker:
                    row_errors.append(f"stock {m.get('stock')!r} != {ticker!r}")
                if m.get("price") != price:
                    row_errors.append(f"price {m.get('price')} != {price}")
                if m.get("match_number") != match_counter:
                    row_errors.append(f"match_number {m.get('match_number')} != {match_counter}")

            elif expected_type == 'H':
                if lob_type == 7:
                    if price == -1:
                        exp_state = 'H'
                    elif price == 0:
                        exp_state = 'Q'
                    else:
                        exp_state = 'T'
                    if m.get("trading_state") != exp_state:
                        row_errors.append(
                            f"trading_state {m.get('trading_state')!r} != {exp_state!r}"
                        )
                    if m.get("stock") != ticker:
                        row_errors.append(f"stock {m.get('stock')!r} != {ticker!r}")

            if row_errors:
                failed += 1
                errors.append(f"Row {row_num} (LOBSTER type {lob_type}): " + "; ".join(row_errors))
            else:
                passed += 1

    # --- Summary ---
    total = passed + failed
    print(f"\n{'='*55}")
    print(f"  ITCH Translation Verification")
    print(f"{'='*55}")
    print(f"  Messages checked : {total}")
    print(f"  PASSED           : {passed}")
    print(f"  FAILED           : {failed}")
    print(f"{'='*55}")

    if errors:
        print(f"\nFirst 20 failures:")
        for e in errors[:20]:
            print(f"  FAIL  {e}")
    else:
        print("\n  All checks passed.")


# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

TYPE_NAMES = {
    'A': 'Add Order',
    'X': 'Order Cancel',
    'D': 'Order Delete',
    'E': 'Order Executed',
    'P': 'Non-Cross Trade',
    'H': 'Trading Action',
}

def display_messages(messages: list[dict], n: int = 20) -> None:
    print(f"\n{'#':<5} {'Type':<17} {'Timestamp (s)':<22} {'OrderID':<14} {'Shares':<8} {'Price ($)':<12} {'Side':<5} {'Stock':<6} {'Extra'}")
    print('-' * 105)
    for i, m in enumerate(messages[:n], start=1):
        t   = m.get("itch_type", "?")
        ts  = m.get("timestamp_ns", 0) / 1e9
        oid = m.get("order_id", "")
        sh  = m.get("shares") or m.get("executed_shares") or m.get("cancelled_shares") or ""
        px  = f"{m['price'] / 10000:.4f}" if "price" in m else ""
        side = m.get("side", "")
        stock = m.get("stock", "")
        extra = ""

        if t == 'E':
            extra = f"match#{m.get('match_number', '')}"
        elif t == 'P':
            extra = f"match#{m.get('match_number', '')}  (hidden)"
        elif t == 'H':
            state_str = {'H': 'HALT', 'Q': 'QUOTING', 'T': 'TRADING'}.get(m.get('trading_state', ''), '?')
            extra = f"state={state_str}"
            stock = m.get("stock", "")

        print(f"{i:<5} {TYPE_NAMES.get(t, t):<17} {ts:<22.9f} {str(oid):<14} {str(sh):<8} {px:<12} {side:<5} {stock:<6} {extra}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    print(f"Parsing {BIN_FILE.name} ...")
    messages = parse_itch_messages(BIN_FILE)
    print(f"Loaded {len(messages)} ITCH messages.")

    display_messages(messages, n=20)

    print(f"\nVerifying against {CSV_FILE.name} ...")
    run_tests(CSV_FILE, messages, TICKER)
