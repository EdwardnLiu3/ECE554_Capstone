"""
lobster_execution_trackers_tester.py

Small tester for execution_trackers.py using the historical LOBSTER sample
file already in this workspace.

This does not run the whole file. It just reads the first few rows one at a
time and checks that the software execution tracker behaves the way we expect.
"""

from __future__ import annotations

import csv
from pathlib import Path

from execution_trackers import (
    ExecutionTrackers,
    QUOTE_ASK,
    QUOTE_BID,
    build_both_enter_payload,
)


SAMPLE_FILE = Path(
    "ITCH_Translator/LOBSTER_SampleFile_AMZN_2012-06-21_1/"
    "AMZN_2012-06-21_34200000_57600000_message_1.csv"
)


def read_first_rows(csv_path: Path, num_rows: int) -> list[list[str]]:
    """Read just the first few rows from the historical LOBSTER file."""
    rows: list[list[str]] = []
    with open(csv_path, newline="", encoding="utf-8") as csv_file:
        reader = csv.reader(csv_file)
        for row in reader:
            if len(row) != 6:
                continue
            rows.append(row)
            if len(rows) >= num_rows:
                break
    return rows


def check(condition: bool, message: str) -> None:
    """Simple pass/fail helper to keep this tester small."""
    if not condition:
        raise AssertionError(message)
    print(f"PASS: {message}")


def main() -> None:
    print("Running small LOBSTER replay test for execution_trackers.py")

    rows = read_first_rows(SAMPLE_FILE, 4)
    check(len(rows) == 4, "loaded the first 4 historical LOBSTER rows")

    tracker = ExecutionTrackers(starting_position=0, stock_id="AMZN", price_divisor=100)

    # Put one live bid and one live ask into the tracker.
    # These are picked to line up with the first few rows in the AMZN sample.
    tracker.process_order_payload(
        build_both_enter_payload(
            bid_id=10,
            bid_price=22381,
            bid_quantity=21,
            ask_id=11,
            ask_price=22382,
            ask_quantity=1,
            stock_id="AMZN",
        )
    )

    check(tracker.live_bid.active, "starting bid quote is live")
    check(tracker.live_ask.active, "starting ask quote is live")

    print("")
    print("Processing first few LOBSTER rows one at a time")

    row1_exec = tracker.process_lobster_row(rows[0])
    print(f"row 1: {rows[0]}")
    check(row1_exec.valid, "row 1 creates an execution of our quote")
    check(row1_exec.side == QUOTE_ASK, "row 1 fills our ask side")
    check(row1_exec.price == 22382, "row 1 ask fill uses our ask price")
    check(row1_exec.quantity == 1, "row 1 ask fill uses the expected quantity")
    check(row1_exec.order_id == 11, "row 1 ask fill uses our ask order id")
    check(not tracker.live_ask.active, "row 1 fully removes our live ask")

    row2_exec = tracker.process_lobster_row(rows[1])
    print(f"row 2: {rows[1]}")
    check(not row2_exec.valid, "row 2 add row does not directly fill our quote")
    check(11885113 in tracker.market_orders, "row 2 stores the market order id for later execute")

    row3_exec = tracker.process_lobster_row(rows[2])
    print(f"row 3: {rows[2]}")
    check(row3_exec.valid, "row 3 creates an execution of our quote")
    check(row3_exec.side == QUOTE_BID, "row 3 fills our bid side")
    check(row3_exec.price == 22381, "row 3 bid fill uses our bid price")
    check(row3_exec.quantity == 21, "row 3 bid fill uses the executed quantity")
    check(row3_exec.order_id == 10, "row 3 bid fill uses our bid order id")
    check(not tracker.live_bid.active, "row 3 fully removes our live bid")

    row4_exec = tracker.process_lobster_row(rows[3])
    print(f"row 4: {rows[3]}")
    check(not row4_exec.valid, "row 4 does not fill us when no matching live quote exists")

    print("")
    check(tracker.position == 20, "final position matches one ask fill and one bid fill")
    check(tracker.day_pnl == -447619, "final day pnl matches the two early fills")
    check(len(tracker.execution_history) == 2, "exactly two fills were detected in this short replay")

    print("")
    print("Small historical LOBSTER replay test passed.")


if __name__ == "__main__":
    main()
