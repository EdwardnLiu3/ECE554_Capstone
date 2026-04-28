import unittest

from software_execution_tracker import (
    BUY,
    SELL,
    SoftwareExecutionTracker,
    build_both_enter_payload,
    build_both_replace_payload,
)


class TestSoftwareExecutionTracker(unittest.TestCase):
    def test_crossing_trades_fill_quotes(self):
        tracker = SoftwareExecutionTracker(starting_position=100)
        tracker.process_order_generator_payload(
            build_both_enter_payload(10, 100, 50, 11, 110, 40)
        )

        self.assertEqual(tracker.live_bid_qty, 50)
        self.assertEqual(tracker.live_ask_qty, 40)

        bid_fill = tracker.process_market_execution(SELL, 99, 20)
        self.assertIsNotNone(bid_fill)
        self.assertEqual(bid_fill.side, BUY)
        self.assertEqual(bid_fill.price, 100)
        self.assertEqual(bid_fill.quantity, 20)
        self.assertEqual(bid_fill.order_id, 10)
        self.assertEqual(tracker.live_bid_qty, 30)
        self.assertEqual(tracker.position, 120)
        self.assertEqual(tracker.day_pnl, -2000)

        ask_fill = tracker.process_market_execution(BUY, 111, 15)
        self.assertIsNotNone(ask_fill)
        self.assertEqual(ask_fill.side, SELL)
        self.assertEqual(ask_fill.price, 110)
        self.assertEqual(ask_fill.quantity, 15)
        self.assertEqual(ask_fill.order_id, 11)
        self.assertEqual(tracker.live_ask_qty, 25)
        self.assertEqual(tracker.position, 105)
        self.assertEqual(tracker.day_pnl, -350)

    def test_non_crossing_trades_do_not_fill(self):
        tracker = SoftwareExecutionTracker()
        tracker.process_order_generator_payload(
            build_both_enter_payload(20, 100, 50, 21, 110, 40)
        )

        self.assertIsNone(tracker.process_market_execution(SELL, 101, 10))
        self.assertEqual(tracker.live_bid_qty, 50)

        self.assertIsNone(tracker.process_market_execution(BUY, 109, 10))
        self.assertEqual(tracker.live_ask_qty, 40)
        self.assertEqual(tracker.position, 100)
        self.assertEqual(tracker.day_pnl, 0)

    def test_replace_logic_only_keeps_replacement_prices(self):
        tracker = SoftwareExecutionTracker()
        tracker.process_order_generator_payload(
            build_both_enter_payload(20, 100, 50, 21, 110, 40)
        )
        tracker.process_order_generator_payload(
            build_both_replace_payload(20, 30, 98, 50, 21, 31, 112, 40)
        )

        self.assertIsNone(tracker.process_market_execution(SELL, 99, 10))
        bid_fill = tracker.process_market_execution(SELL, 98, 10)
        self.assertIsNotNone(bid_fill)
        self.assertEqual(bid_fill.order_id, 30)
        self.assertEqual(bid_fill.price, 98)

        self.assertIsNone(tracker.process_market_execution(BUY, 111, 10))
        ask_fill = tracker.process_market_execution(BUY, 112, 10)
        self.assertIsNotNone(ask_fill)
        self.assertEqual(ask_fill.order_id, 31)
        self.assertEqual(ask_fill.price, 112)


if __name__ == "__main__":
    unittest.main()
