"""Market data simulator (exchange side).

Generates a random but internally consistent order flow and emits it as UDP
payloads -- exactly the stimulus the FPGA DUT and the golden reference both
consume.

The generator owns a mirror ``OrderBook`` (the "exchange" book) which it uses
to know which order ids are live and to compute fills. Every fill produced by
a crossing ADD / price-changing MODIFY is emitted as an EXECUTE_ORDER
execution report immediately after the order event that caused it. The
generator may also emit random external executions (FLAG_EXTERNAL), which it
applies to its own mirror book so the stream stays self-consistent.

Because the mirror book uses the same ``OrderBook`` algorithm as the golden
reference consumer, replaying the stream through the consumer reproduces the
exchange's book state exactly and validates every execution report.
"""

import argparse
import random
import socket

from .orderbook import Order, OrderBook, Side
from .protocol import (
    VERSION,
    Message,
    MSG_ADD,
    MSG_CANCEL,
    MSG_MODIFY,
    MSG_EXECUTE,
    SIDE_BUY,
    SIDE_SELL,
    FLAG_EXTERNAL,
    encode_message,
)


class OrderFlowGenerator:
    """Random but internally consistent order flow generator.

    Deterministic for a given ``seed``: the same seed yields the same stream
    of encoded messages, which is what makes this usable as a UVM stimulus
    and expected-output source.
    """

    def __init__(
        self,
        seed=None,
        book=None,
        price_min=1000,
        price_max=10000,
        max_quantity=1000,
        p_add=0.50,
        p_cancel=0.18,
        p_modify=0.17,
        p_external=0.15,
        p_cross=0.10,
    ):
        self.rng = random.Random(seed)
        self.book = book if book is not None else OrderBook()
        self.price_min = price_min
        self.price_max = price_max
        self.max_quantity = max_quantity
        self.p_add = p_add
        self.p_cancel = p_cancel
        self.p_modify = p_modify
        self.p_external = p_external
        self.p_cross = p_cross

        self.seq = 0              # wire sequence counter
        self.next_order_id = 1
        self.live = set()         # order ids currently resting in self.book
        self.ts = 0               # simulated nanosecond clock (monotonic)
        self._pending_fills = []
        self.stats = {
            "add": 0, "cancel": 0, "modify": 0, "external": 0,
            "execute": 0, "trades": 0, "messages": 0,
        }

    # ------------------------------------------------------------ generator

    def next_batch(self):
        """Return the next list of wire Messages: one order event followed by
        any EXECUTE_ORDER reports it produced (buy report, then sell report,
        per fill)."""
        self.ts += self.rng.randint(1, 2000)  # monotonic simulated clock
        action = self._choose_action()
        if action == MSG_ADD:
            msg, fills = self._gen_add()
        elif action == MSG_CANCEL:
            msg, fills = self._gen_cancel()
        elif action == MSG_MODIFY:
            msg, fills = self._gen_modify()
        else:
            msg, fills = self._gen_external()
        batch = [msg]
        for trade in fills:
            self.stats["trades"] += 1
            batch.append(self._exec_msg(trade.buy_order_id, Side.BUY, trade))
            batch.append(self._exec_msg(trade.sell_order_id, Side.SELL, trade))
        # Matching may have removed resting orders other than the one this
        # batch acted on; resync the live set from the mirror book.
        self.live = self.book.order_ids()
        self.stats["messages"] += len(batch)
        return batch

    def run(self, count, callback=None):
        """Generate ``count`` batches, calling ``callback(batch)`` if given.
        Returns the list of batches."""
        batches = []
        for _ in range(count):
            batch = self.next_batch()
            if callback is not None:
                callback(batch)
            batches.append(batch)
        return batches

    def run_payloads(self, count):
        """Generate ``count`` batches and return the encoded 32-byte payloads
        (a stimulus file for UVM / the DUT)."""
        payloads = []
        for _ in range(count):
            for msg in self.next_batch():
                payloads.append(encode_message(msg))
        return payloads

    def write_stimulus(self, path, count):
        """Write ``count`` batches of encoded messages to ``path`` as one
        contiguous binary stimulus file (32 bytes per message)."""
        with open(path, "wb") as handle:
            for payload in self.run_payloads(count):
                handle.write(payload)
        return self.stats["messages"]

    # --------------------------------------------------------------- actions

    def _choose_action(self):
        if not self.live:
            return MSG_ADD
        r = self.rng.random()
        if r < self.p_add:
            return MSG_ADD
        if r < self.p_add + self.p_cancel:
            return MSG_CANCEL
        if r < self.p_add + self.p_cancel + self.p_modify:
            return MSG_MODIFY
        return MSG_EXECUTE

    def _gen_add(self):
        self.stats["add"] += 1
        side = self.rng.choice((Side.BUY, Side.SELL))
        price = self._pick_price(
            side, crossing=self.rng.random() < self.p_cross)
        order_id = self.next_order_id
        self.next_order_id += 1
        quantity = self.rng.randint(1, self.max_quantity)
        order = Order(order_id, side, price, quantity, self.ts)
        fills = self.book.add_order(order)
        msg = self._action_msg(MSG_ADD, side, order_id, price, quantity)
        return msg, fills

    def _gen_cancel(self):
        self.stats["cancel"] += 1
        order_id = self.rng.choice(tuple(self.live))
        order = self.book.get_order(order_id)
        self.book.cancel_order(order_id)
        msg = self._action_msg(
            MSG_CANCEL, order.side, order_id, order.price, order.quantity)
        return msg, []

    def _gen_modify(self):
        self.stats["modify"] += 1
        order_id = self.rng.choice(tuple(self.live))
        order = self.book.get_order(order_id)
        new_quantity = self.rng.randint(1, self.max_quantity)
        if self.rng.random() < 0.4:
            new_price = order.price       # quantity-only: keep priority
        else:
            new_price = self._pick_price(order.side)
        fills = self.book.modify_order(
            order_id, new_quantity, new_price, timestamp_ns=self.ts)
        msg = self._action_msg(
            MSG_MODIFY, order.side, order_id, new_price, new_quantity)
        return msg, fills

    def _gen_external(self):
        self.stats["external"] += 1
        order_id = self.rng.choice(tuple(self.live))
        order = self.book.get_order(order_id)
        quantity = self.rng.randint(1, order.quantity)
        self.book.execute_order(order_id, quantity, timestamp_ns=self.ts)
        msg = self._action_msg(
            MSG_EXECUTE, order.side, order_id, order.price, quantity)
        msg.flags = FLAG_EXTERNAL
        return msg, []

    # -------------------------------------------------------------- helpers

    def _pick_price(self, side, crossing=False):
        """Pick an integer price, optionally forced to cross the book."""
        if crossing:
            best = (self.book.get_best_ask() if side is Side.BUY
                    else self.book.get_best_bid())
            if best is not None:
                if side is Side.BUY:
                    return min(best + self.rng.randint(1, 5), self.price_max)
                return max(best - self.rng.randint(1, 5), self.price_min)
        mid = (self.price_min + self.price_max) // 2
        half = (self.price_max - self.price_min) // 4
        noise = self.rng.randint(0, half)
        price = mid + (noise if side is Side.SELL else -noise)
        return max(self.price_min, min(price, self.price_max))

    def _action_msg(self, msg_type, side, order_id, price, quantity):
        return Message(
            VERSION, msg_type, side.value, 0, self._next_seq(), order_id,
            price, quantity, self.ts)

    def _exec_msg(self, order_id, side, trade):
        self.stats["execute"] += 1
        return Message(
            VERSION, MSG_EXECUTE, side.value, 0, self._next_seq(), order_id,
            trade.price, trade.quantity, trade.timestamp_ns)

    def _next_seq(self):
        self.seq += 1
        return self.seq


class UDPSender:
    """Thin UDP datagram sender for the market data simulator."""

    def __init__(self, host="127.0.0.1", port=9000):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.addr = (host, port)
        self.sent = 0

    def send_message(self, msg):
        self.sock.sendto(encode_message(msg), self.addr)
        self.sent += 1

    def send_payload(self, payload):
        self.sock.sendto(payload, self.addr)
        self.sent += 1

    def close(self):
        self.sock.close()


def main():
    parser = argparse.ArgumentParser(
        description="LOB market data simulator (UDP sender)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--count", type=int, default=1000,
                        help="number of order-event batches to generate")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--stimulus", default=None, metavar="FILE",
                        help="also write the stream to a binary stimulus file")
    args = parser.parse_args()

    generator = OrderFlowGenerator(seed=args.seed)
    sender = UDPSender(args.host, args.port)
    try:
        for _ in range(args.count):
            for msg in generator.next_batch():
                sender.send_message(msg)
        if args.stimulus:
            generator.write_stimulus(args.stimulus, args.count)
    finally:
        sender.close()
    print(f"sent {sender.sent} messages to {sender.addr}")
    print("stats:", generator.stats)


if __name__ == "__main__":
    main()
