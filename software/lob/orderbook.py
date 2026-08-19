"""Core limit order book and matching engine.

This is the golden reference for the FPGA matching accelerator. The data
model mirrors the hardware 1:1: two price structures (bids sorted high-to-low,
asks sorted low-to-high), each price level holding a FIFO queue of orders.

Conventions (must be matched bit-exactly by the RTL):

* Matching is **price-time priority**: better price first, then earlier
  arrival time.
* The **resting (passive) order always trades at its own limit price** -- the
  aggressive (incoming) order receives price improvement.
* ``add_order`` inserts, then drains any cross; the remainder of the incoming
  order rests at its limit price, behind orders already at that price.
* ``modify_order``: a quantity-only change keeps the queue position; a price
  change is treated as cancel + re-add (time priority reset) and re-matches.
* Orders are never left with zero or negative quantity; fully filled orders
  are removed from the book.
"""

import enum
import heapq
import time
from collections import deque
from dataclasses import dataclass


class Side(enum.Enum):
    """Order side. Values match the frozen wire encoding (0 = BUY, 1 = SELL)."""

    BUY = 0x00
    SELL = 0x01

    def opposite(self):
        return Side.SELL if self is Side.BUY else Side.BUY


@dataclass
class Order:
    """A single resting or incoming order."""

    order_id: int
    side: Side
    price: int            # fixed point, e.g. 10025 == $100.25
    quantity: int
    timestamp_ns: int     # arrival time, drives time priority


@dataclass
class Trade:
    """A matched execution. The counterparty id is 0 for external fills."""

    buy_order_id: int
    sell_order_id: int
    price: int
    quantity: int
    timestamp_ns: int


class OrderBookError(Exception):
    """Base class for order book errors."""


class DuplicateOrderError(OrderBookError):
    pass


class OrderNotFoundError(OrderBookError):
    pass


class PriceLevel:
    """One price level: a FIFO queue of orders (time priority).

    Hardware mapping: a per-price FIFO. ``remove`` is a linear scan here; the
    RTL removes by order_id using indexed / content-addressable storage.
    """

    __slots__ = ("price", "side", "orders")

    def __init__(self, price, side):
        self.price = price
        self.side = side
        self.orders = deque()  # insertion order == time priority

    def is_empty(self):
        return not self.orders

    def head(self):
        """Earliest-arriving (most senior) order at this level."""
        return self.orders[0]

    def append(self, order):
        self.orders.append(order)

    def pop_head(self):
        return self.orders.popleft()

    def remove(self, order_id):
        for index, order in enumerate(self.orders):
            if order.order_id == order_id:
                del self.orders[index]
                return order
        raise OrderNotFoundError(
            f"order {order_id} not found at price {self.price}"
        )

    def total_quantity(self):
        return sum(order.quantity for order in self.orders)

    def __iter__(self):
        return iter(self.orders)

    def __len__(self):
        return len(self.orders)


class OrderBook:
    """Limit order book with price-time priority matching."""

    def __init__(self):
        self._orders = {}                              # order_id -> Order
        self._levels = {Side.BUY: {}, Side.SELL: {}}   # side -> {price: PriceLevel}
        self._bid_heap = []                            # (-price, price), lazy
        self._ask_heap = []                            # (price,), lazy
        self.trade_log = []  # every Trade in generation order (UVM scoreboard)

    # ------------------------------------------------------------------ API

    def add_order(self, order):
        """Insert ``order`` and match it against the opposite book.

        Returns the list of Trades produced. If the incoming order is fully
        filled it does not rest; otherwise the remainder rests at its limit
        price with time priority behind any orders already there.
        """
        self._validate_order(order)
        if order.order_id in self._orders:
            raise DuplicateOrderError(
                f"order_id {order.order_id} is already live")
        self._insert(order)
        return self.match_orders()

    def cancel_order(self, order_id):
        """Remove a live order; raises OrderNotFoundError if absent."""
        order = self._orders.get(order_id)
        if order is None:
            raise OrderNotFoundError(f"order {order_id} is not live")
        level = self._levels[order.side][order.price]
        level.remove(order_id)
        if level.is_empty():
            del self._levels[order.side][order.price]
        del self._orders[order_id]
        return order

    def modify_order(self, order_id, new_quantity, new_price, timestamp_ns=None):
        """Change the quantity and/or price of a live order.

        * Same price: queue position (time priority) is preserved.
        * New price: the order is re-prioritized like a fresh incoming order
          (time priority resets to ``timestamp_ns``, or a monotonic clock if
          not given) and re-matched against the opposite book.

        Returns the list of Trades produced (possibly empty).
        """
        order = self._orders.get(order_id)
        if order is None:
            raise OrderNotFoundError(f"order {order_id} is not live")
        if new_quantity <= 0 or new_price <= 0:
            raise ValueError("quantity and price must be positive")
        if new_price == order.price:
            order.quantity = new_quantity
            return []
        # Price change: leave the old level, re-prioritize as a fresh order.
        level = self._levels[order.side][order.price]
        level.remove(order_id)
        if level.is_empty():
            del self._levels[order.side][order.price]
        if timestamp_ns is None:
            timestamp_ns = time.monotonic_ns()
        order.price = new_price
        order.quantity = new_quantity
        order.timestamp_ns = timestamp_ns
        self._insert(order)
        return self.match_orders()

    def match_orders(self):
        """Drain any crossed state and return the trades produced.

        Called automatically by add/modify. When both sides are crossed, the
        resting (earlier-arriving) head order trades at its own limit price;
        on a timestamp tie the bid is treated as passive. In a well-formed
        continuous book a standalone call is a no-op.
        """
        trades = []
        while True:
            bid_price = self._best_price(Side.BUY)
            ask_price = self._best_price(Side.SELL)
            if bid_price is None or ask_price is None or bid_price < ask_price:
                break
            bid_level = self._levels[Side.BUY][bid_price]
            ask_level = self._levels[Side.SELL][ask_price]
            bid_head = bid_level.head()
            ask_head = ask_level.head()
            if bid_head.timestamp_ns <= ask_head.timestamp_ns:
                trade_price = bid_price    # bid resting -> trades at bid
            else:
                trade_price = ask_price    # ask resting -> trades at ask
            quantity = min(bid_head.quantity, ask_head.quantity)
            timestamp_ns = max(bid_head.timestamp_ns, ask_head.timestamp_ns)
            trade = Trade(bid_head.order_id, ask_head.order_id, trade_price,
                          quantity, timestamp_ns)
            trades.append(trade)
            self.trade_log.append(trade)
            bid_head.quantity -= quantity
            ask_head.quantity -= quantity
            if bid_head.quantity == 0:
                bid_level.pop_head()
                if bid_level.is_empty():
                    del self._levels[Side.BUY][bid_price]
                del self._orders[bid_head.order_id]
            if ask_head.quantity == 0:
                ask_level.pop_head()
                if ask_level.is_empty():
                    del self._levels[Side.SELL][ask_price]
                del self._orders[ask_head.order_id]
        return trades

    def execute_order(self, order_id, quantity, timestamp_ns=None):
        """Apply an external execution to a live order (EXECUTE_ORDER with
        FLAG_EXTERNAL set): reduce its quantity, removing it if fully filled.

        The counterparty is unknown, so the returned Trade carries 0 for it.
        """
        order = self._orders.get(order_id)
        if order is None:
            raise OrderNotFoundError(f"order {order_id} is not live")
        if quantity <= 0:
            raise ValueError("execution quantity must be positive")
        if quantity > order.quantity:
            raise ValueError(
                f"execution quantity {quantity} exceeds remaining "
                f"{order.quantity}")
        if timestamp_ns is None:
            timestamp_ns = time.monotonic_ns()
        trade = Trade(
            buy_order_id=order.order_id if order.side is Side.BUY else 0,
            sell_order_id=order.order_id if order.side is Side.SELL else 0,
            price=order.price,
            quantity=quantity,
            timestamp_ns=timestamp_ns,
        )
        order.quantity -= quantity
        if order.quantity == 0:
            self.cancel_order(order_id)
        self.trade_log.append(trade)
        return trade

    def get_best_bid(self):
        """Highest priced live bid, or None."""
        return self._best_price(Side.BUY)

    def get_best_ask(self):
        """Lowest priced live ask, or None."""
        return self._best_price(Side.SELL)

    def get_order(self, order_id):
        return self._orders.get(order_id)

    def order_ids(self):
        return set(self._orders)

    def __len__(self):
        return len(self._orders)

    # ------------------------------------------------------------- internals

    def _insert(self, order):
        level = self._levels[order.side].get(order.price)
        if level is None:
            level = PriceLevel(order.price, order.side)
            self._levels[order.side][order.price] = level
            if order.side is Side.BUY:
                heapq.heappush(self._bid_heap, (-order.price, order.price))
            else:
                heapq.heappush(self._ask_heap, (order.price,))
        level.append(order)
        self._orders[order.order_id] = order

    def _best_price(self, side):
        """Best price for ``side``, lazily discarding stale heap entries."""
        heap = self._bid_heap if side is Side.BUY else self._ask_heap
        levels = self._levels[side]
        while heap:
            price = heap[0][1] if side is Side.BUY else heap[0][0]
            level = levels.get(price)
            if level is not None and not level.is_empty():
                return price
            heapq.heappop(heap)  # stale entry: level was removed / emptied
        return None

    @staticmethod
    def _validate_order(order):
        if order.side not in (Side.BUY, Side.SELL):
            raise ValueError("order.side must be Side.BUY or Side.SELL")
        if order.price <= 0:
            raise ValueError("order price must be positive")
        if order.quantity <= 0:
            raise ValueError("order quantity must be positive")

    # ----------------------------------------------------- verification tools

    def check_invariants(self):
        """Raise AssertionError on any structural inconsistency.

        This is the UVM-scoreboard style self check: the order index agrees
        with the price levels, no duplicated or zero-quantity orders, and the
        book is never left crossed.
        """
        seen = set()
        for side in (Side.BUY, Side.SELL):
            for price, level in self._levels[side].items():
                assert level.price == price and level.side is side
                assert not level.is_empty(), (
                    f"empty level @{price} left in book")
                for order in level:
                    assert order.order_id in self._orders, (
                        f"orphan order {order.order_id}")
                    assert order.order_id not in seen, (
                        f"duplicate order {order.order_id}")
                    seen.add(order.order_id)
                    assert order.side is side, "order in wrong book"
                    assert order.price == price, "order in wrong level"
                    assert order.quantity > 0, (
                        f"non-positive quantity {order.quantity}")
        assert seen == set(self._orders), "order index diverges from book"
        bid = self.get_best_bid()
        ask = self.get_best_ask()
        if bid is not None and ask is not None:
            assert bid < ask, f"book is crossed: bid {bid} >= ask {ask}"

    def snapshot(self):
        """Deterministic state dump for comparing two books (reference vs DUT)."""
        def side_snapshot(side):
            return [
                [price,
                 [[order.order_id, order.quantity, order.timestamp_ns]
                  for order in level]]
                for price, level in sorted(self._levels[side].items())
            ]

        return {
            "bids": side_snapshot(Side.BUY),
            "asks": side_snapshot(Side.SELL),
            "best_bid": self.get_best_bid(),
            "best_ask": self.get_best_ask(),
            "num_orders": len(self._orders),
        }
