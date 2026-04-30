"""
software_execution_tracker.py

Small software-side mirror of execution_tracker.sv for demos.

It tracks our live bid/ask quotes, handles enter/replace messages from the
Order_Generator payload format, compares market executions against our quotes,
and updates a simple inventory plus cash P/L in cents.

Side convention used here:
    0 = buy / bid
    1 = sell / ask
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


BUY = 0
SELL = 1

MSG_ENTER = 0x4F
MSG_REPLACE = 0x55
ACTION_EXECUTE = 0b10


@dataclass
class Quote:
    order_id: int
    side: int
    price: int
    quantity: int


@dataclass
class Fill:
    order_id: int
    side: int
    price: int
    quantity: int
    market_price: int


class SoftwareExecutionTracker:
    """Software model of the FPGA execution tracker."""

    def __init__(self, starting_position: int = 100, max_quotes: int = 8) -> None:
        self.starting_position = starting_position
        self.max_quotes = max_quotes
        self.bids: dict[int, Quote] = {}
        self.asks: dict[int, Quote] = {}
        self.position = starting_position
        self.day_pnl = 0  # cents; buy spends cash, sell receives cash
        self.fills: list[Fill] = []

    def reset(self) -> None:
        """Clear quotes and reset inventory/PnL for a new replay run."""
        self.bids.clear()
        self.asks.clear()
        self.position = self.starting_position
        self.day_pnl = 0
        self.fills.clear()

    @property
    def live_bid_qty(self) -> int:
        return sum(q.quantity for q in self.bids.values())

    @property
    def live_ask_qty(self) -> int:
        return sum(q.quantity for q in self.asks.values())

    def process_order_generator_payload(self, payload: int | bytes | str) -> None:
        """
        Decode one 752-bit Order_Generator payload.

        The current SystemVerilog Order_Generator packs the buy-side message in
        the upper message and sell-side message in the lower message. If replace
        messages are used, the payload is shorter and zero-extended on the left;
        this mirrors the decoder in execution_tracker.sv.
        """
        value = self._payload_to_int(payload)

        lower_is_enter = self._bits(value, 375, 368) == MSG_ENTER
        lower_is_replace = self._bits(value, 319, 312) == MSG_REPLACE
        if lower_is_enter:
            upper_base = 376
        elif lower_is_replace:
            upper_base = 320
        else:
            upper_base = 376

        upper_is_enter = self._bits(value, upper_base + 375, upper_base + 368) == MSG_ENTER
        upper_is_replace = self._bits(value, upper_base + 319, upper_base + 312) == MSG_REPLACE

        if upper_is_enter:
            quote = self._decode_enter(value, upper_base, BUY)
            self.upsert_quote(quote)
        elif upper_is_replace:
            old_id, quote = self._decode_replace(value, upper_base, BUY)
            self.replace_quote(BUY, old_id, quote)

        if lower_is_enter:
            quote = self._decode_enter(value, 0, SELL)
            self.upsert_quote(quote)
        elif lower_is_replace:
            old_id, quote = self._decode_replace(value, 0, SELL)
            self.replace_quote(SELL, old_id, quote)

    def upsert_quote(self, quote: Quote) -> None:
        """Add a new live quote, or overwrite an existing quote with same ID."""
        book = self.bids if quote.side == BUY else self.asks
        if quote.order_id not in book and len(book) >= self.max_quotes:
            raise RuntimeError(f"quote book full for side {quote.side}")
        book[quote.order_id] = quote

    def replace_quote(self, side: int, old_order_id: int, new_quote: Quote) -> None:
        """Replace old quote ID with a new quote, matching the OUCH replace idea."""
        book = self.bids if side == BUY else self.asks
        book.pop(old_order_id, None)
        self.upsert_quote(new_quote)

    def cancel_quote(self, side: int, order_id: int) -> None:
        """Cancel a live quote by side and order ID."""
        book = self.bids if side == BUY else self.asks
        book.pop(order_id, None)

    def process_market_execution(
        self,
        market_side: int,
        price: int,
        quantity: int,
        action: int = ACTION_EXECUTE,
    ) -> Fill | None:
        """
        Compare one market execution against our live quotes.

        A market sell can fill our bid if it trades at or below our bid.
        A market buy can fill our ask if it trades at or above our ask.
        """
        if action != ACTION_EXECUTE or quantity <= 0:
            return None

        if market_side == SELL:
            quote = self._best_crossing_bid(price)
        else:
            quote = self._best_crossing_ask(price)

        if quote is None:
            return None

        fill_qty = min(quantity, quote.quantity)
        fill = Fill(
            order_id=quote.order_id,
            side=quote.side,
            price=quote.price,
            quantity=fill_qty,
            market_price=price,
        )

        self._apply_fill(fill)
        return fill

    def process_lobster_csv(self, csv_path: str | Path, price_divisor: int = 1) -> list[Fill]:
        """
        Process a LOBSTER message CSV and return fills of our quotes.

        This expects the normal LOBSTER message columns:
            time,type,order_id,size,price,direction

        price_divisor defaults to 1, meaning the CSV price is already in cents.
        If the LOBSTER file uses price * 10000, pass price_divisor=100 to
        convert it into cents before comparing against our quotes.

        For LOBSTER visible executions, direction is the side of the resting
        order that got executed. A buy resting order being executed implies a
        market sell, and a sell resting order being executed implies a market buy.
        """
        fills: list[Fill] = []
        with open(csv_path, newline="") as csv_file:
            for row in csv.reader(csv_file):
                if len(row) != 6:
                    continue

                msg_type = int(row[1])
                if msg_type not in (4, 5):
                    continue

                size = int(row[3])
                price = int(row[4]) // price_divisor
                direction = int(row[5])
                market_side = SELL if direction == 1 else BUY

                fill = self.process_market_execution(market_side, price, size)
                if fill is not None:
                    fills.append(fill)

        return fills

    def _apply_fill(self, fill: Fill) -> None:
        """Update quote book, position, and cash P/L for one inferred fill."""
        book = self.bids if fill.side == BUY else self.asks
        quote = book[fill.order_id]
        quote.quantity -= fill.quantity
        if quote.quantity <= 0:
            del book[fill.order_id]

        if fill.side == BUY:
            self.position += fill.quantity
            self.day_pnl -= fill.price * fill.quantity
        else:
            self.position -= fill.quantity
            self.day_pnl += fill.price * fill.quantity

        self.fills.append(fill)

    def _best_crossing_bid(self, market_price: int) -> Quote | None:
        crossing = [q for q in self.bids.values() if q.quantity > 0 and market_price <= q.price]
        if not crossing:
            return None
        return max(crossing, key=lambda q: q.price)

    def _best_crossing_ask(self, market_price: int) -> Quote | None:
        crossing = [q for q in self.asks.values() if q.quantity > 0 and market_price >= q.price]
        if not crossing:
            return None
        return min(crossing, key=lambda q: q.price)

    def _decode_enter(self, value: int, base: int, side: int) -> Quote:
        order_id = self._bits(value, base + 367, base + 336)
        quantity = self._bits(value, base + 327, base + 296)
        price = self._bits(value, base + 231, base + 168)
        return Quote(order_id=order_id, side=side, price=price, quantity=quantity)

    def _decode_replace(self, value: int, base: int, side: int) -> tuple[int, Quote]:
        old_id = self._bits(value, base + 311, base + 280)
        new_id = self._bits(value, base + 279, base + 248)
        quantity = self._bits(value, base + 247, base + 216)
        price = self._bits(value, base + 215, base + 152)
        quote = Quote(order_id=new_id, side=side, price=price, quantity=quantity)
        return old_id, quote

    @staticmethod
    def _bits(value: int, msb: int, lsb: int) -> int:
        width = msb - lsb + 1
        return (value >> lsb) & ((1 << width) - 1)

    @staticmethod
    def _payload_to_int(payload: int | bytes | str) -> int:
        if isinstance(payload, int):
            return payload
        if isinstance(payload, bytes):
            return int.from_bytes(payload, byteorder="big")
        if isinstance(payload, str):
            cleaned = payload.strip().replace("_", "")
            if cleaned.startswith("0x"):
                cleaned = cleaned[2:]
            return int(cleaned, 16)
        raise TypeError(f"unsupported payload type: {type(payload)!r}")


def build_enter_message(order_id: int, side: int, price: int, quantity: int) -> int:
    """Build one 376-bit Enter Order message for demos/tests."""
    symbol = int.from_bytes(b"AMZN    ", byteorder="big")
    value = 0
    value = (value << 8) | MSG_ENTER
    value = (value << 32) | order_id
    value = (value << 8) | (0x42 if side == BUY else 0x53)
    value = (value << 32) | quantity
    value = (value << 64) | symbol
    value = (value << 64) | price
    value = (value << 168)
    return value


def build_replace_message(old_id: int, new_id: int, price: int, quantity: int) -> int:
    """Build one 320-bit Replace Order message for demos/tests."""
    value = 0
    value = (value << 8) | MSG_REPLACE
    value = (value << 32) | old_id
    value = (value << 32) | new_id
    value = (value << 32) | quantity
    value = (value << 64) | price
    value = (value << 152)
    return value


def build_both_enter_payload(
    bid_id: int,
    bid_price: int,
    bid_qty: int,
    ask_id: int,
    ask_price: int,
    ask_qty: int,
) -> int:
    """Build a 752-bit payload matching Order_Generator's two-enter case."""
    return (
        build_enter_message(bid_id, BUY, bid_price, bid_qty) << 376
    ) | build_enter_message(ask_id, SELL, ask_price, ask_qty)


def build_both_replace_payload(
    old_bid_id: int,
    new_bid_id: int,
    bid_price: int,
    bid_qty: int,
    old_ask_id: int,
    new_ask_id: int,
    ask_price: int,
    ask_qty: int,
) -> int:
    """Build a zero-extended 752-bit payload for two compact replace messages."""
    return (
        build_replace_message(old_bid_id, new_bid_id, bid_price, bid_qty) << 320
    ) | build_replace_message(old_ask_id, new_ask_id, ask_price, ask_qty)


def _format_cents(cents: int) -> str:
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return f"{sign}${cents // 100}.{cents % 100:02d}"


def run_demo(csv_path: Path | None, price_divisor: int) -> None:
    tracker = SoftwareExecutionTracker(starting_position=100)
    tracker.process_order_generator_payload(
        build_both_enter_payload(
            bid_id=10,
            bid_price=10_000,
            bid_qty=100,
            ask_id=11,
            ask_price=10_100,
            ask_qty=100,
        )
    )

    if csv_path is None:
        fills = [
            tracker.process_market_execution(SELL, 9_995, 25),
            tracker.process_market_execution(BUY, 10_105, 10),
        ]
        fills = [fill for fill in fills if fill is not None]
    else:
        fills = tracker.process_lobster_csv(csv_path, price_divisor=price_divisor)

    print("Software execution tracker demo")
    print(f"fills detected: {len(fills)}")
    print(f"position: {tracker.position}")
    print(f"cash pnl: {_format_cents(tracker.day_pnl)}")
    print(f"live bid qty: {tracker.live_bid_qty}")
    print(f"live ask qty: {tracker.live_ask_qty}")


def main(argv: Iterable[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Software mirror of the FPGA execution tracker")
    parser.add_argument("--lobster-csv", type=Path, help="Optional LOBSTER message CSV to replay")
    parser.add_argument(
        "--price-divisor",
        type=int,
        default=1,
        help="Divide CSV execution prices by this before comparing; use 100 for LOBSTER price*10000 -> cents",
    )
    args = parser.parse_args(argv)
    run_demo(args.lobster_csv, args.price_divisor)


if __name__ == "__main__":
    main()
