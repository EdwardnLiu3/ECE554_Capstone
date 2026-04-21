import unittest

from execution_trackers import (
    ExecutionTrackers,
    QUOTE_BID,
    QUOTE_ASK,
    build_both_enter_payload,
    build_both_replace_payload,
)


class TestExecutionTrackers(unittest.TestCase):
    def test_enter_payload_sets_live_quotes(self):
        tracker = ExecutionTrackers(starting_position=0, stock_id="TEST", price_divisor=1)

        tracker.process_order_payload(
            build_both_enter_payload(
                bid_id=10,
                bid_price=100,
                bid_quantity=20,
                ask_id=11,
                ask_price=110,
                ask_quantity=25,
                stock_id="AMZN",
            )
        )

        self.assertEqual(tracker.stock_id, "AMZN")
        self.assertTrue(tracker.live_bid.active)
        self.assertEqual(tracker.live_bid.order_id, 10)
        self.assertEqual(tracker.live_bid.price, 100)
        self.assertEqual(tracker.live_bid.quantity, 20)
        self.assertTrue(tracker.live_ask.active)
        self.assertEqual(tracker.live_ask.order_id, 11)
        self.assertEqual(tracker.live_ask.price, 110)
        self.assertEqual(tracker.live_ask.quantity, 25)

    def test_visible_market_executes_fill_our_quotes(self):
        tracker = ExecutionTrackers(starting_position=0, stock_id="AMZN", price_divisor=1)

        tracker.process_order_payload(
            build_both_enter_payload(10, 100, 20, 11, 110, 20, stock_id="AMZN")
        )

        tracker.process_lobster_row(["0.0", "1", "500", "20", "100", "1"])
        bid_fill = tracker.process_lobster_row(["0.1", "4", "500", "20", "100", "1"])

        self.assertTrue(bid_fill.valid)
        self.assertEqual(bid_fill.side, QUOTE_BID)
        self.assertEqual(bid_fill.order_id, 10)
        self.assertEqual(bid_fill.price, 100)
        self.assertEqual(bid_fill.quantity, 20)
        self.assertEqual(tracker.position, 20)
        self.assertEqual(tracker.day_pnl, -2000)
        self.assertFalse(tracker.live_bid.active)

        tracker.process_lobster_row(["0.2", "1", "600", "20", "110", "-1"])
        ask_fill = tracker.process_lobster_row(["0.3", "4", "600", "20", "110", "-1"])

        self.assertTrue(ask_fill.valid)
        self.assertEqual(ask_fill.side, QUOTE_ASK)
        self.assertEqual(ask_fill.order_id, 11)
        self.assertEqual(ask_fill.price, 110)
        self.assertEqual(ask_fill.quantity, 20)
        self.assertEqual(tracker.position, 0)
        self.assertEqual(tracker.day_pnl, 200)
        self.assertFalse(tracker.live_ask.active)

    def test_non_crossing_market_executes_do_not_fill(self):
        tracker = ExecutionTrackers(starting_position=0, stock_id="AMZN", price_divisor=1)

        tracker.process_order_payload(
            build_both_enter_payload(20, 100, 20, 21, 110, 20, stock_id="AMZN")
        )

        tracker.process_lobster_row(["0.0", "1", "700", "20", "101", "1"])
        no_bid_fill = tracker.process_lobster_row(["0.1", "4", "700", "20", "101", "1"])
        self.assertFalse(no_bid_fill.valid)
        self.assertTrue(tracker.live_bid.active)
        self.assertEqual(tracker.position, 0)
        self.assertEqual(tracker.day_pnl, 0)

        tracker.process_lobster_row(["0.2", "1", "701", "20", "109", "-1"])
        no_ask_fill = tracker.process_lobster_row(["0.3", "4", "701", "20", "109", "-1"])
        self.assertFalse(no_ask_fill.valid)
        self.assertTrue(tracker.live_ask.active)
        self.assertEqual(tracker.position, 0)
        self.assertEqual(tracker.day_pnl, 0)

    def test_same_cycle_fill_happens_before_replace(self):
        tracker = ExecutionTrackers(starting_position=0, stock_id="AMZN", price_divisor=1)

        tracker.process_order_payload(
            build_both_enter_payload(50, 100, 20, 51, 110, 20, stock_id="AMZN")
        )
        tracker.process_lobster_row(["0.0", "1", "800", "20", "100", "1"])

        execution = tracker.process_cycle(
            order_payload=build_both_replace_payload(50, 60, 99, 30, 51, 61, 111, 30),
            lobster_row=["0.1", "4", "800", "20", "100", "1"],
        )

        self.assertTrue(execution.valid)
        self.assertEqual(execution.side, QUOTE_BID)
        self.assertEqual(execution.order_id, 50)
        self.assertEqual(execution.price, 100)
        self.assertEqual(execution.quantity, 20)
        self.assertTrue(tracker.live_bid.active)
        self.assertEqual(tracker.live_bid.order_id, 60)
        self.assertEqual(tracker.live_bid.price, 99)
        self.assertEqual(tracker.live_bid.quantity, 30)


if __name__ == "__main__":
    unittest.main()
