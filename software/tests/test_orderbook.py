"""Unit tests for the matching engine (Order, Trade, PriceLevel, OrderBook)."""

import unittest

from lob.orderbook import (
    Order,
    Trade,
    Side,
    OrderBook,
    DuplicateOrderError,
    OrderNotFoundError,
)


def buy(order_id, price, qty, ts=0):
    return Order(order_id, Side.BUY, price, qty, ts)


def sell(order_id, price, qty, ts=0):
    return Order(order_id, Side.SELL, price, qty, ts)


class TestAddOrder(unittest.TestCase):
    def test_add_single_order(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 50, ts=1))
        self.assertEqual(book.get_best_bid(), 100)
        self.assertIsNone(book.get_best_ask())
        self.assertEqual(len(book), 1)
        book.check_invariants()

    def test_add_both_sides(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 50, ts=1))
        book.add_order(sell(2, 101, 30, ts=2))
        self.assertEqual(book.get_best_bid(), 100)
        self.assertEqual(book.get_best_ask(), 101)
        self.assertLess(book.get_best_bid(), book.get_best_ask())
        book.check_invariants()

    def test_add_duplicate_order_id_rejected(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 50, ts=1))
        with self.assertRaises(DuplicateOrderError):
            book.add_order(buy(1, 99, 10, ts=2))

    def test_add_invalid_order_rejected(self):
        book = OrderBook()
        with self.assertRaises(ValueError):
            book.add_order(buy(1, 0, 10, ts=1))       # zero price
        with self.assertRaises(ValueError):
            book.add_order(buy(1, 100, 0, ts=1))      # zero quantity

    def test_orders_at_same_price_keep_fifo(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        book.add_order(buy(2, 100, 20, ts=2))
        level = book._levels[Side.BUY][100]
        self.assertEqual([o.order_id for o in level], [1, 2])
        self.assertEqual(level.head().order_id, 1)
        book.check_invariants()


class TestBasicMatching(unittest.TestCase):
    def test_spec_basic_matching(self):
        """BUY 100 qty50, SELL 100 qty20 -> one trade qty20."""
        book = OrderBook()
        book.add_order(buy(1, 100, 50, ts=1))
        trades = book.add_order(sell(2, 100, 20, ts=2))
        self.assertEqual(trades, [Trade(1, 2, 100, 20, timestamp_ns=2)])
        self.assertEqual(len(book), 1)                 # seller fully filled
        self.assertEqual(book.get_order(1).quantity, 30)
        self.assertEqual(book.get_best_bid(), 100)
        self.assertIsNone(book.get_best_ask())
        book.check_invariants()


class TestPricePriority(unittest.TestCase):
    def test_higher_bid_matched_first(self):
        book = OrderBook()
        book.add_order(buy(1, 99, 10, ts=1))
        book.add_order(buy(2, 100, 10, ts=2))
        self.assertEqual(book.get_best_bid(), 100)      # 100 > 99
        trades = book.add_order(sell(3, 99, 15, ts=3))
        self.assertEqual(trades, [
            Trade(2, 3, 100, 10, timestamp_ns=3),   # best bid first, resting price
            Trade(1, 3, 99, 5, timestamp_ns=3),
        ])
        book.check_invariants()

    def test_lower_ask_matched_first(self):
        book = OrderBook()
        book.add_order(sell(1, 101, 10, ts=1))
        book.add_order(sell(2, 100, 10, ts=2))
        self.assertEqual(book.get_best_ask(), 100)      # 100 < 101
        trades = book.add_order(buy(3, 101, 12, ts=3))  # aggressive bid reaches both asks
        self.assertEqual(trades, [
            Trade(3, 2, 100, 10, timestamp_ns=3),   # best ask first, resting price
            Trade(3, 1, 101, 2, timestamp_ns=3),
        ])
        book.check_invariants()

    def test_non_crossing_level_not_matched(self):
        """A SELL at 100 only fills bids >= 100, not the 99 bid."""
        book = OrderBook()
        book.add_order(buy(1, 99, 10, ts=1))
        book.add_order(buy(2, 100, 10, ts=2))
        trades = book.add_order(sell(3, 100, 12, ts=3))
        self.assertEqual(trades, [Trade(2, 3, 100, 10, timestamp_ns=3)])
        # seller rests with 2 @100, buyer@99 untouched
        self.assertEqual(book.get_order(3).quantity, 2)
        self.assertEqual(book.get_best_bid(), 99)
        self.assertEqual(book.get_best_ask(), 100)
        book.check_invariants()


class TestTimePriority(unittest.TestCase):
    def test_spec_time_priority_example(self):
        """Spec example: two BUYs at 100, one incoming SELL at 100 qty60.

        Trade 1: buyer_id=1, qty=50; Trade 2: buyer_id=2, qty=10.
        """
        book = OrderBook()
        book.add_order(buy(1, 100, 50, ts=1))
        book.add_order(buy(2, 100, 30, ts=2))
        trades = book.add_order(sell(3, 100, 60, ts=3))
        self.assertEqual(trades, [
            Trade(1, 3, 100, 50, timestamp_ns=3),
            Trade(2, 3, 100, 10, timestamp_ns=3),
        ])
        self.assertEqual(book.get_order(2).quantity, 20)
        self.assertIsNone(book.get_order(3))
        self.assertEqual(book.get_best_bid(), 100)
        book.check_invariants()

    def test_fifo_breaks_equal_price(self):
        book = OrderBook()
        book.add_order(sell(1, 100, 5, ts=1))
        book.add_order(sell(2, 100, 5, ts=2))
        trades = book.add_order(buy(3, 100, 8, ts=3))
        self.assertEqual(trades, [
            Trade(3, 1, 100, 5, timestamp_ns=3),   # earlier seller first
            Trade(3, 2, 100, 3, timestamp_ns=3),
        ])
        book.check_invariants()


class TestCancel(unittest.TestCase):
    def test_cancel_order(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        book.add_order(buy(2, 100, 20, ts=2))
        book.cancel_order(1)
        self.assertIsNone(book.get_order(1))
        self.assertEqual([o.order_id for o in book._levels[Side.BUY][100]], [2])
        self.assertEqual(book.get_best_bid(), 100)
        book.check_invariants()

    def test_cancel_last_order_empties_book(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        book.cancel_order(1)
        self.assertIsNone(book.get_best_bid())
        self.assertEqual(len(book), 0)
        book.check_invariants()

    def test_cancel_missing_order_raises(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        with self.assertRaises(OrderNotFoundError):
            book.cancel_order(999)


class TestModify(unittest.TestCase):
    def test_quantity_only_keeps_time_priority(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        book.add_order(buy(2, 100, 20, ts=2))
        # reduce order 1 to 5, same price: stays at the head of the FIFO
        book.modify_order(1, new_quantity=5, new_price=100)
        self.assertEqual(book._levels[Side.BUY][100].head().order_id, 1)
        trades = book.add_order(sell(3, 100, 6, ts=3))
        self.assertEqual(trades, [
            Trade(1, 3, 100, 5, timestamp_ns=3),   # order 1 still first despite modify
            Trade(2, 3, 100, 1, timestamp_ns=3),
        ])
        book.check_invariants()

    def test_price_change_resets_time_priority(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        book.add_order(buy(2, 100, 20, ts=2))
        # move order 1 down to 99: it must no longer sit at the 100 level
        book.modify_order(1, new_quantity=10, new_price=99, timestamp_ns=3)
        self.assertEqual([o.order_id for o in book._levels[Side.BUY][100]], [2])
        self.assertEqual([o.order_id for o in book._levels[Side.BUY][99]], [1])
        trades = book.add_order(sell(3, 100, 6, ts=4))
        self.assertEqual(trades, [Trade(2, 3, 100, 6, timestamp_ns=4)])
        book.check_invariants()

    def test_modify_price_crosses_and_matches(self):
        book = OrderBook()
        book.add_order(sell(1, 100, 10, ts=1))
        book.add_order(buy(2, 99, 10, ts=2))
        # move the bid from 99 to 101 -> now crosses the resting ask @100
        trades = book.modify_order(2, new_quantity=10, new_price=101,
                                   timestamp_ns=3)
        self.assertEqual(trades, [Trade(2, 1, 100, 10, timestamp_ns=3)])
        self.assertIsNone(book.get_order(2))   # fully filled
        self.assertIsNone(book.get_order(1))
        book.check_invariants()

    def test_modify_missing_order_raises(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        with self.assertRaises(OrderNotFoundError):
            book.modify_order(999, new_quantity=5, new_price=100)

    def test_modify_invalid_args_rejected(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        with self.assertRaises(ValueError):
            book.modify_order(1, new_quantity=0, new_price=100)
        with self.assertRaises(ValueError):
            book.modify_order(1, new_quantity=5, new_price=0)


class TestExecuteExternal(unittest.TestCase):
    def test_partial_external_fill(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        trade = book.execute_order(1, 6, timestamp_ns=2)
        self.assertEqual(trade, Trade(1, 0, 100, 6, 2))
        self.assertEqual(book.get_order(1).quantity, 4)
        book.check_invariants()

    def test_full_external_fill_removes_order(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        book.execute_order(1, 10, timestamp_ns=2)
        self.assertIsNone(book.get_order(1))
        self.assertIsNone(book.get_best_bid())
        book.check_invariants()

    def test_external_fill_over_remaining_rejected(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        with self.assertRaises(ValueError):
            book.execute_order(1, 11, timestamp_ns=2)
        with self.assertRaises(ValueError):
            book.execute_order(1, 0, timestamp_ns=2)

    def test_external_fill_missing_order_raises(self):
        book = OrderBook()
        with self.assertRaises(OrderNotFoundError):
            book.execute_order(42, 1)


class TestMatchOrdersStandalone(unittest.TestCase):
    def test_uncrossed_book_is_noop(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        book.add_order(sell(2, 101, 10, ts=2))
        self.assertEqual(book.match_orders(), [])
        book.check_invariants()

    def test_cross_resolution_uses_resting_price(self):
        """Force a crossed book by inserting heads directly (bypassing the
        automatic drain), then drain it with a standalone match_orders."""
        book = OrderBook()
        book._insert(buy(1, 100, 10, ts=1))    # bid @100
        book._insert(sell(2, 99, 6, ts=2))     # ask @99  -> crossed state
        trades = book.match_orders()
        self.assertEqual(trades, [Trade(1, 2, 100, 6, timestamp_ns=2)])  # trades at bid
        self.assertEqual(book.get_order(1).quantity, 4)
        self.assertIsNone(book.get_order(2))
        book.check_invariants()


class TestSnapshot(unittest.TestCase):
    def test_snapshot_reflects_state(self):
        book = OrderBook()
        book.add_order(buy(1, 100, 10, ts=1))
        book.add_order(buy(2, 99, 5, ts=2))
        book.add_order(sell(3, 101, 7, ts=3))
        snap = book.snapshot()
        self.assertEqual(snap["best_bid"], 100)
        self.assertEqual(snap["best_ask"], 101)
        self.assertEqual(snap["num_orders"], 3)
        self.assertEqual(len(snap["bids"]), 2)
        self.assertEqual(len(snap["asks"]), 1)

    def test_two_identical_books_have_identical_snapshots(self):
        b1 = OrderBook()
        b2 = OrderBook()
        for order in [
            buy(1, 100, 10, ts=1), buy(2, 99, 5, ts=2), sell(3, 101, 7, ts=3),
        ]:
            b1.add_order(order)
            b2.add_order(Order(order.order_id, order.side, order.price,
                               order.quantity, order.timestamp_ns))
        self.assertEqual(b1.snapshot(), b2.snapshot())


if __name__ == "__main__":
    unittest.main()
