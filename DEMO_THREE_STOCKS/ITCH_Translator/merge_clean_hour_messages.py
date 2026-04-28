#!/usr/bin/env python3
import csv
from dataclasses import dataclass
from pathlib import Path


DATA_DIR = Path("ITCH_Translator/LOBSTER_SampleFile_AMZN_2012-06-21_1")
EPSILON_SECONDS = 1e-9


@dataclass(frozen=True)
class StockSource:
    ticker: str
    stock_id: int
    path: Path


SOURCES = [
    StockSource("INTC", 1, DATA_DIR / "intc_style_hour_message_clean.csv"),
    StockSource("MSFT", 2, DATA_DIR / "msft_style_hour_message_clean.csv"),
]

OUT_CSV = DATA_DIR / "two_stock_style_hour_message_clean_merged.csv"
OUT_META = DATA_DIR / "two_stock_style_hour_message_clean_merged_metadata.txt"


def load_rows(source: StockSource):
    rows = []
    with source.path.open("r", newline="") as handle:
        reader = csv.reader(handle)
        for row_idx, row in enumerate(reader):
            if len(row) < 6:
                continue
            rows.append(
                {
                    "time": float(row[0]),
                    "type": row[1],
                    "order_id": row[2],
                    "size": row[3],
                    "price": row[4],
                    "direction": row[5],
                    "stock_id": str(source.stock_id),
                    "ticker": source.ticker,
                    "row_idx": row_idx,
                }
            )
    return rows


def merge_rows():
    merged = []
    for source in SOURCES:
        merged.extend(load_rows(source))

    merged.sort(key=lambda r: (r["time"], r["stock_id"], r["row_idx"]))

    adjusted = []
    prev_time = None
    for row in merged:
        t = row["time"]
        if prev_time is not None and t <= prev_time:
            t = prev_time + EPSILON_SECONDS
        prev_time = t
        adjusted.append(
            [
                f"{t:.9f}",
                row["type"],
                row["order_id"],
                row["size"],
                row["price"],
                row["direction"],
                row["stock_id"],
            ]
        )
    return adjusted


def write_metadata(rows_written: int):
    first_time = None
    last_time = None
    with OUT_CSV.open("r", newline="") as handle:
        reader = csv.reader(handle)
        for row in reader:
            if len(row) < 7:
                continue
            if first_time is None:
                first_time = row[0]
            last_time = row[0]

    with OUT_META.open("w", newline="") as handle:
        handle.write("Merged two-stock clean hour replay\n")
        handle.write(f"rows={rows_written}\n")
        handle.write(f"start_time={first_time}\n")
        handle.write(f"end_time={last_time}\n")
        handle.write("columns=time,type,order_id,size,price,direction,stock_id\n")
        for source in SOURCES:
            handle.write(f"stock_id_{source.stock_id}={source.ticker}\n")
        handle.write(f"timestamp_epsilon_seconds={EPSILON_SECONDS:.9f}\n")


def main():
    merged_rows = merge_rows()
    with OUT_CSV.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerows(merged_rows)
    write_metadata(len(merged_rows))
    print(f"Wrote {OUT_CSV}")
    print(f"Wrote {OUT_META}")


if __name__ == "__main__":
    main()
