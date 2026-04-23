"""
execution_trackers.py

Software mirror of ExecutionTracker/execution_trackers.sv.

This module accepts the packed Order_Generator payload format, keeps the same
oldest-first live quote FIFOs per side as the Verilog, compares market execute
events against those live quotes, and exposes a live state snapshot that can be
forwarded to other Python code for formatting / transport.
"""

from __future__ import annotations

import csv
from dataclasses import asdict, dataclass
from pathlib import Path


MSG_ENTER = 0x4F
MSG_REPLACE = 0x55

LOBSTER_ADD = 1
LOBSTER_CANCEL = 2
LOBSTER_DELETE = 3
LOBSTER_EXECUTE = 4
LOBSTER_HIDDEN_EXECUTE = 5

LOBSTER_BUY = 1
LOBSTER_SELL = -1

MARKET_BUY = 0
MARKET_SELL = 1

QUOTE_BID = 0
QUOTE_ASK = 1


@dataclass
class LiveQuote:
    active: bool = False
    order_id: int = 0
    price: int = 0
    quantity: int = 0


@dataclass
class MarketOrder:
    order_id: int
    side: int
    price: int
    quantity: int


@dataclass
class QuoteExecution:
    valid: bool = False
    side: int = 0
    price: int = 0
    quantity: int = 0
    order_id: int = 0
    stock_id: str = ""
    timestamp_seconds: float | None = None
    market_price: int = 0
    market_quantity: int = 0


class ExecutionTrackers:
    """
    Software tracker aligned to execution_trackers.sv.

    Important matched behavior:
    - FIFO of live quotes per side, oldest quote at index 0
    - market execution check happens before quote updates in the same cycle
    - only the first matching quote in FIFO order can fill on a market execute
    - when the FIFO is full, a new quote shifts out the oldest quote
    """

    def __init__(
        self,
        starting_position: int = 0,
        stock_id: str = "AMZN",
        price_divisor: int = 100,
        fifo_depth: int = 10,
    ) -> None:
        self.starting_position = starting_position
        self.default_stock_id = stock_id
        self.price_divisor = price_divisor
        self.fifo_depth = fifo_depth
        self.reset()

    def reset(self) -> None:
        """Reset live quotes, market order map, inventory, and outputs."""
        self.bid_quotes: list[LiveQuote] = []
        self.ask_quotes: list[LiveQuote] = []
        self.market_orders: dict[int, MarketOrder] = {}
        self.position = self.starting_position
        self.day_pnl = 0
        self.stock_id = self.default_stock_id
        self.last_execution = QuoteExecution(stock_id=self.stock_id)
        self.execution_history: list[QuoteExecution] = []
        self.last_market_timestamp: float | None = None
        self.last_market_price = 0
        self.last_market_quantity = 0
        self.last_market_side: int | None = None

    @property
    def live_bid(self) -> LiveQuote:
        """Compatibility view of the oldest live bid quote."""
        if self.bid_quotes:
            return self._copy_quote(self.bid_quotes[0])
        return LiveQuote()

    @property
    def live_ask(self) -> LiveQuote:
        """Compatibility view of the oldest live ask quote."""
        if self.ask_quotes:
            return self._copy_quote(self.ask_quotes[0])
        return LiveQuote()

    @property
    def live_bid_qty(self) -> int:
        return sum(quote.quantity for quote in self.bid_quotes if quote.active)

    @property
    def live_ask_qty(self) -> int:
        return sum(quote.quantity for quote in self.ask_quotes if quote.active)

    @property
    def live_bid_active(self) -> bool:
        return len(self.bid_quotes) == self.fifo_depth and bool(self.bid_quotes)

    @property
    def live_ask_active(self) -> bool:
        return len(self.ask_quotes) == self.fifo_depth and bool(self.ask_quotes)

    @property
    def live_bid_order_id(self) -> int:
        return self.bid_quotes[0].order_id if self.bid_quotes else 0

    @property
    def live_ask_order_id(self) -> int:
        return self.ask_quotes[0].order_id if self.ask_quotes else 0

    @property
    def mark_price(self) -> int:
        return self.last_market_price

    @property
    def total_pnl(self) -> int:
        if self.mark_price == 0:
            return self.day_pnl
        return self.day_pnl + (self.position * self.mark_price)

    def process_cycle(
        self,
        order_payload: int | bytes | str | None = None,
        lobster_row: list[str] | tuple[str, ...] | None = None,
    ) -> QuoteExecution:
        """
        Process one software "cycle".

        Ordering matches the RTL:
        1. compare a market execute event against current live quotes
        2. apply the quote payload update after the fill check
        """
        execution = QuoteExecution(stock_id=self.stock_id)

        if lobster_row is not None:
            market_exec = self._market_exec_from_lobster_row(lobster_row)
            if market_exec is not None:
                execution = self._compare_market_execution(*market_exec)

        if order_payload is not None:
            self._apply_order_payload(order_payload)

        self.last_execution = execution
        return execution

    def process_order_payload(self, order_payload: int | bytes | str) -> None:
        """Process just one packed Order_Generator payload."""
        self.process_cycle(order_payload=order_payload)

    def process_ethernet_payload(self, payload: int | bytes | str) -> dict:
        """
        Convenience wrapper for the live Ethernet path.

        The returned dict is intentionally easy for another Python formatter to
        consume immediately after a payload arrives.
        """
        self.process_order_payload(payload)
        return self.get_outputs()

    def process_market_execution_event(
        self,
        market_exec_valid: bool,
        market_exec_side: int,
        market_exec_price: int,
        market_exec_quantity: int,
        timestamp_seconds: float | None = None,
    ) -> QuoteExecution:
        """
        Process one already-decoded market execute event.

        This mirrors the Verilog tracker interface more directly than the
        LOBSTER-row helper.
        """
        if timestamp_seconds is not None:
            self.last_market_timestamp = timestamp_seconds
        self.last_market_side = market_exec_side
        self.last_market_price = market_exec_price
        self.last_market_quantity = market_exec_quantity

        if not market_exec_valid:
            execution = QuoteExecution(stock_id=self.stock_id, timestamp_seconds=timestamp_seconds)
            self.last_execution = execution
            return execution

        execution = self._compare_market_execution(
            market_exec_side,
            market_exec_price,
            market_exec_quantity,
            timestamp_seconds=timestamp_seconds,
        )
        self.last_execution = execution
        return execution

    def process_lobster_row(self, lobster_row: list[str] | tuple[str, ...]) -> QuoteExecution:
        """Process one LOBSTER-style row."""
        return self.process_cycle(lobster_row=lobster_row)

    def process_lobster_file(self, csv_path: str | Path) -> list[QuoteExecution]:
        """Replay a LOBSTER message CSV and return the fills of our quotes."""
        fills: list[QuoteExecution] = []
        with open(csv_path, newline="", encoding="utf-8") as csv_file:
            for row in csv.reader(csv_file):
                if len(row) != 6:
                    continue
                execution = self.process_lobster_row(row)
                if execution.valid:
                    fills.append(execution)
        return fills

    def get_outputs(self) -> dict:
        """
        Return a live software snapshot for the teammate's formatter / transport.

        Quotes are oldest-first per side to match the RTL FIFO ordering.
        """
        return {
            "stock_id": self.stock_id,
            "position": self.position,
            "day_pnl": self.day_pnl,
            "mark_price": self.mark_price,
            "total_pnl": self.total_pnl,
            "inventory_value": self.total_pnl - self.day_pnl,
            "last_market_timestamp": self.last_market_timestamp,
            "last_market_price": self.last_market_price,
            "last_market_quantity": self.last_market_quantity,
            "last_market_side": self.last_market_side,
            "live_bid_active": self.live_bid_active,
            "live_ask_active": self.live_ask_active,
            "live_bid_order_id": self.live_bid_order_id,
            "live_ask_order_id": self.live_ask_order_id,
            "live_bid_qty": self.live_bid_qty,
            "live_ask_qty": self.live_ask_qty,
            "live_bid": asdict(self.live_bid),
            "live_ask": asdict(self.live_ask),
            "bid_quotes": [asdict(self._copy_quote(quote)) for quote in self.bid_quotes],
            "ask_quotes": [asdict(self._copy_quote(quote)) for quote in self.ask_quotes],
            "last_execution": asdict(self.last_execution),
            "execution_history": [asdict(execution) for execution in self.execution_history],
            "execution_count": len(self.execution_history),
        }

    def _apply_order_payload(self, payload: int | bytes | str) -> None:
        """Decode the packed Order_Generator payload and update live quote FIFOs."""
        value = self._payload_to_int(payload)

        lower_is_enter = self._bits(value, 375, 368) == MSG_ENTER
        lower_is_replace = self._bits(value, 319, 312) == MSG_REPLACE
        upper_base = 376 if lower_is_enter else 320 if lower_is_replace else 376

        upper_is_enter = self._bits(value, upper_base + 375, upper_base + 368) == MSG_ENTER
        upper_is_replace = self._bits(value, upper_base + 319, upper_base + 312) == MSG_REPLACE

        if upper_is_enter:
            side, quote, symbol = self._decode_enter(value, upper_base)
            if symbol:
                self.stock_id = symbol
            self._append_quote(side, quote)
        elif upper_is_replace:
            _, quote = self._decode_replace(value, upper_base, QUOTE_BID)
            self._append_quote(QUOTE_BID, quote)

        if lower_is_enter:
            side, quote, symbol = self._decode_enter(value, 0)
            if symbol:
                self.stock_id = symbol
            self._append_quote(side, quote)
        elif lower_is_replace:
            _, quote = self._decode_replace(value, 0, QUOTE_ASK)
            self._append_quote(QUOTE_ASK, quote)

    def _append_quote(self, side: int, quote: LiveQuote) -> None:
        """
        Append a quote to the side FIFO, matching the RTL behavior.

        execution_trackers.sv does not use old_id to mutate an in-book quote. It
        simply appends the new quote and shifts out the oldest quote if the FIFO
        is already full.
        """
        if not quote.active or quote.quantity <= 0:
            return

        book = self.bid_quotes if side == QUOTE_BID else self.ask_quotes
        quote_copy = self._copy_quote(quote)

        if len(book) < self.fifo_depth:
            book.append(quote_copy)
        else:
            book.pop(0)
            book.append(quote_copy)

    def _market_exec_from_lobster_row(
        self,
        row: list[str] | tuple[str, ...],
    ) -> tuple[int, int, int, float | None] | None:
        """
        Read one LOBSTER row and turn it into a market execute event when needed.

        Visible add/cancel/delete rows only update the resting-order map. Visible
        execute rows derive the aggressive trade side from the resting order side,
        which is what the RTL path receives after the orderbook.
        """
        timestamp_seconds = float(row[0])
        msg_type = int(row[1])
        order_id = int(row[2])
        quantity = int(row[3])
        price = int(row[4]) // self.price_divisor
        direction = int(row[5])

        self.last_market_timestamp = timestamp_seconds
        self.last_market_price = price
        self.last_market_quantity = quantity

        if msg_type == LOBSTER_ADD:
            self.market_orders[order_id] = MarketOrder(
                order_id=order_id,
                side=direction,
                price=price,
                quantity=quantity,
            )
            self.last_market_side = None
            return None

        if msg_type == LOBSTER_CANCEL:
            market_order = self.market_orders.get(order_id)
            if market_order is not None:
                market_order.quantity = max(0, market_order.quantity - quantity)
                if market_order.quantity == 0:
                    self.market_orders.pop(order_id, None)
            self.last_market_side = None
            return None

        if msg_type == LOBSTER_DELETE:
            self.market_orders.pop(order_id, None)
            self.last_market_side = None
            return None

        if msg_type == LOBSTER_EXECUTE:
            market_order = self.market_orders.get(order_id)
            if market_order is None or market_order.quantity == 0:
                self.last_market_side = None
                return None

            exec_quantity = min(quantity, market_order.quantity)
            market_order.quantity -= exec_quantity
            if market_order.quantity == 0:
                self.market_orders.pop(order_id, None)

            market_side = MARKET_SELL if market_order.side == LOBSTER_BUY else MARKET_BUY
            self.last_market_side = market_side
            return market_side, market_order.price, exec_quantity, timestamp_seconds

        # The current SV replay path skips type-5 rows, so keep the Python path
        # aligned with that behavior.
        if msg_type == LOBSTER_HIDDEN_EXECUTE:
            self.last_market_side = None
            return None

        self.last_market_side = None
        return None

    def _compare_market_execution(
        self,
        market_side: int,
        market_price: int,
        market_quantity: int,
        timestamp_seconds: float | None = None,
    ) -> QuoteExecution:
        """Compare one market execution against our current live quote FIFOs."""
        if market_quantity <= 0:
            return QuoteExecution(stock_id=self.stock_id, timestamp_seconds=timestamp_seconds)

        if market_side == MARKET_SELL:
            for index, quote in enumerate(self.bid_quotes):
                if quote.active and quote.quantity > 0 and market_price <= quote.price:
                    return self._fill_quote(
                        side=QUOTE_BID,
                        book=self.bid_quotes,
                        index=index,
                        market_price=market_price,
                        market_quantity=market_quantity,
                        timestamp_seconds=timestamp_seconds,
                    )
        else:
            for index, quote in enumerate(self.ask_quotes):
                if quote.active and quote.quantity > 0 and market_price >= quote.price:
                    return self._fill_quote(
                        side=QUOTE_ASK,
                        book=self.ask_quotes,
                        index=index,
                        market_price=market_price,
                        market_quantity=market_quantity,
                        timestamp_seconds=timestamp_seconds,
                    )

        return QuoteExecution(
            stock_id=self.stock_id,
            timestamp_seconds=timestamp_seconds,
            market_price=market_price,
            market_quantity=market_quantity,
        )

    def _fill_quote(
        self,
        side: int,
        book: list[LiveQuote],
        index: int,
        market_price: int,
        market_quantity: int,
        timestamp_seconds: float | None,
    ) -> QuoteExecution:
        """Fill one quote exactly the way the RTL updates its FIFO state."""
        quote = book[index]
        fill_quantity = min(market_quantity, quote.quantity)
        execution = QuoteExecution(
            valid=True,
            side=side,
            price=quote.price,
            quantity=fill_quantity,
            order_id=quote.order_id,
            stock_id=self.stock_id,
            timestamp_seconds=timestamp_seconds,
            market_price=market_price,
            market_quantity=market_quantity,
        )

        quote.quantity -= fill_quantity
        if quote.quantity == 0:
            book.pop(index)

        if side == QUOTE_BID:
            self.position += fill_quantity
            self.day_pnl -= execution.price * fill_quantity
        else:
            self.position -= fill_quantity
            self.day_pnl += execution.price * fill_quantity

        self.execution_history.append(execution)
        return execution

    def _decode_enter(self, value: int, base: int) -> tuple[int, LiveQuote, str]:
        """Decode one 376-bit OUCH enter message from the payload."""
        order_id = self._bits(value, base + 367, base + 336)
        side_byte = self._bits(value, base + 335, base + 328)
        quantity = self._bits(value, base + 327, base + 296)
        symbol_value = self._bits(value, base + 295, base + 232)
        price = self._bits(value, base + 231, base + 168)

        side = QUOTE_BID if side_byte == 0x42 else QUOTE_ASK
        symbol = symbol_value.to_bytes(8, byteorder="big").decode("ascii", errors="ignore").strip()
        quote = LiveQuote(active=True, order_id=order_id, price=price, quantity=quantity)
        return side, quote, symbol

    def _decode_replace(self, value: int, base: int, side: int) -> tuple[int, LiveQuote]:
        """Decode one 320-bit OUCH replace message from the payload."""
        old_id = self._bits(value, base + 311, base + 280)
        new_id = self._bits(value, base + 279, base + 248)
        quantity = self._bits(value, base + 247, base + 216)
        price = self._bits(value, base + 215, base + 152)
        quote = LiveQuote(active=True, order_id=new_id, price=price, quantity=quantity)
        return old_id, quote

    @staticmethod
    def _copy_quote(quote: LiveQuote) -> LiveQuote:
        return LiveQuote(
            active=quote.active,
            order_id=quote.order_id,
            price=quote.price,
            quantity=quote.quantity,
        )

    @staticmethod
    def _bits(value: int, msb: int, lsb: int) -> int:
        """Slice bits from an integer like the SystemVerilog payload indexing."""
        width = msb - lsb + 1
        return (value >> lsb) & ((1 << width) - 1)

    @staticmethod
    def _payload_to_int(payload: int | bytes | str) -> int:
        """Accept integer, bytes, or hex string payload input."""
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


def build_enter_message(
    order_id: int,
    side: int,
    price: int,
    quantity: int,
    stock_id: str = "AMZN",
) -> int:
    """Build one enter message in the same packed style as Order_Generator."""
    symbol = stock_id[:8].ljust(8).encode("ascii")
    value = 0
    value = (value << 8) | MSG_ENTER
    value = (value << 32) | order_id
    value = (value << 8) | (0x42 if side == QUOTE_BID else 0x53)
    value = (value << 32) | quantity
    value = (value << 64) | int.from_bytes(symbol, byteorder="big")
    value = (value << 64) | price
    value = (value << 168)
    return value


def build_replace_message(old_id: int, new_id: int, price: int, quantity: int) -> int:
    """Build one replace message in the same packed style as Order_Generator."""
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
    bid_quantity: int,
    ask_id: int,
    ask_price: int,
    ask_quantity: int,
    stock_id: str = "AMZN",
) -> int:
    """Build the two-enter 752-bit payload."""
    upper = build_enter_message(bid_id, QUOTE_BID, bid_price, bid_quantity, stock_id)
    lower = build_enter_message(ask_id, QUOTE_ASK, ask_price, ask_quantity, stock_id)
    return (upper << 376) | lower


def build_both_replace_payload(
    old_bid_id: int,
    new_bid_id: int,
    bid_price: int,
    bid_quantity: int,
    old_ask_id: int,
    new_ask_id: int,
    ask_price: int,
    ask_quantity: int,
) -> int:
    """Build the two-replace payload with the same zero-extension style."""
    upper = build_replace_message(old_bid_id, new_bid_id, bid_price, bid_quantity)
    lower = build_replace_message(old_ask_id, new_ask_id, ask_price, ask_quantity)
    return (upper << 320) | lower
