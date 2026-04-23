"""
Generate a "preloaded" LOBSTER message CSV by prepending synthetic add events
derived from the first row of a matching LOBSTER orderbook snapshot.

This is useful when a downstream replay starts from an empty book but needs a
non-empty starting state before consuming the real message stream.

Important limitation:
    The LOBSTER orderbook snapshot is aggregated by price level and does not
    include the real resting order IDs. This script therefore invents
    synthetic order IDs and emits one synthetic add per occupied price level.
    That means the output is an approximation of the visible starting book,
    not a perfect order-level reconstruction.

Important LOBSTER alignment detail:
    LOBSTER orderbook row N reflects the visible book *after* message row N.
    When seeding from orderbook row 1, replay must therefore continue from
    message row 2 onward. Otherwise the first real message gets applied twice.

Usage:
    python prepend_lobster_snapshot.py <message_csv> <orderbook_csv> [output_csv]

Example:
    python prepend_lobster_snapshot.py ^
        ITCH_Translator\\LOBSTER_SampleFile_AMZN_2012-06-21_1\\AAPL_2012-06-21_34200000_57600000_message_10.csv ^
        ITCH_Translator\\LOBSTER_SampleFile_AMZN_2012-06-21_1\\AAPL_2012-06-21_34200000_57600000_orderbook_10.csv
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from decimal import Decimal, ROUND_DOWN
from pathlib import Path


NANOSECOND = Decimal("0.000000001")
EMPTY_ASK_PRICE = 9_999_999_999
EMPTY_BID_PRICE = -9_999_999_999


@dataclass(frozen=True)
class Level:
    side: int      # -1 ask, +1 bid
    price: int
    size: int
    level: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("message_csv", type=Path, help="LOBSTER message CSV")
    parser.add_argument("orderbook_csv", type=Path, help="Matching LOBSTER orderbook CSV")
    parser.add_argument(
        "output_csv",
        type=Path,
        nargs="?",
        help="Output CSV path. Defaults to <message_stem>_preloaded.csv",
    )
    return parser.parse_args()


def default_output_path(message_csv: Path) -> Path:
    return message_csv.with_name(f"{message_csv.stem}_preloaded.csv")


def read_message_metadata(message_csv: Path) -> tuple[Decimal, int, list[list[str]]]:
    rows: list[list[str]] = []
    first_ts: Decimal | None = None
    max_order_id = 0

    with message_csv.open(newline="") as handle:
        reader = csv.reader(handle)
        for row in reader:
            if len(row) != 6:
                continue
            rows.append(row)
            if first_ts is None:
                first_ts = Decimal(row[0])
            order_id = int(row[2])
            if order_id > max_order_id:
                max_order_id = order_id

    if first_ts is None:
        raise ValueError(f"No valid 6-column rows found in {message_csv}")

    return first_ts, max_order_id, rows


def read_first_snapshot(orderbook_csv: Path) -> list[Level]:
    with orderbook_csv.open(newline="") as handle:
        reader = csv.reader(handle)
        first_row = next(reader, None)

    if first_row is None:
        raise ValueError(f"{orderbook_csv} is empty")
    if len(first_row) % 4 != 0:
        raise ValueError(
            f"{orderbook_csv} first row has {len(first_row)} columns, expected a multiple of 4"
        )

    asks: list[Level] = []
    bids: list[Level] = []

    for idx in range(0, len(first_row), 4):
        level_num = idx // 4 + 1
        ask_price = int(first_row[idx + 0])
        ask_size = int(first_row[idx + 1])
        bid_price = int(first_row[idx + 2])
        bid_size = int(first_row[idx + 3])

        if ask_size > 0 and ask_price != EMPTY_ASK_PRICE:
            asks.append(Level(side=-1, price=ask_price, size=ask_size, level=level_num))
        if bid_size > 0 and bid_price != EMPTY_BID_PRICE:
            bids.append(Level(side=1, price=bid_price, size=bid_size, level=level_num))

    # Keep the synthetic preload deterministic and readable:
    # asks from best to farthest, then bids from best to farthest.
    asks.sort(key=lambda level: (level.price, level.level))
    bids.sort(key=lambda level: (-level.price, level.level))
    return asks + bids


def build_preload_rows(levels: list[Level], first_ts: Decimal, starting_order_id: int) -> list[list[str]]:
    preload_rows: list[list[str]] = []
    preload_count = len(levels)

    if preload_count == 0:
        return preload_rows

    earliest_ts = first_ts - (NANOSECOND * preload_count)
    if earliest_ts < 0:
        earliest_ts = Decimal("0")

    for idx, level in enumerate(levels):
        ts = earliest_ts + (NANOSECOND * idx)
        order_id = starting_order_id + idx
        preload_rows.append(
            [
                format_timestamp(ts),
                "1",
                str(order_id),
                str(level.size),
                str(level.price),
                str(level.side),
            ]
        )

    return preload_rows


def format_timestamp(ts: Decimal) -> str:
    # Keep nanosecond resolution and avoid scientific notation.
    quantized = ts.quantize(NANOSECOND, rounding=ROUND_DOWN)
    text = format(quantized, "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


def write_output(output_csv: Path, preload_rows: list[list[str]], message_rows: list[list[str]]) -> None:
    with output_csv.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerows(preload_rows)
        writer.writerows(message_rows[1:])


def main() -> None:
    args = parse_args()
    message_csv = args.message_csv
    orderbook_csv = args.orderbook_csv
    output_csv = args.output_csv or default_output_path(message_csv)

    first_ts, max_order_id, message_rows = read_message_metadata(message_csv)
    levels = read_first_snapshot(orderbook_csv)
    preload_rows = build_preload_rows(levels, first_ts, max_order_id + 1)
    write_output(output_csv, preload_rows, message_rows)

    print(f"Input message file : {message_csv}")
    print(f"Input orderbook    : {orderbook_csv}")
    print(f"Output file        : {output_csv}")
    print(f"Prepended rows     : {len(preload_rows)}")
    if preload_rows:
        print(f"First preload time : {preload_rows[0][0]}")
        print(f"Last preload time  : {preload_rows[-1][0]}")
        print(f"First synthetic ID : {preload_rows[0][2]}")
        print(f"Last synthetic ID  : {preload_rows[-1][2]}")


if __name__ == "__main__":
    main()
