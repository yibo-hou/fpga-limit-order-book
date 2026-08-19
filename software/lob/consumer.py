"""Golden reference consumer (subscriber side).

The exchange simulator (``lob.simulator``) produces a message stream that is
also what the FPGA DUT consumes. This consumer replays the same stream through
the reference ``OrderBook`` and in a single pass:

* reproduces the exchange's book state exactly (same matching algorithm),
* validates every matched-fill EXECUTE_ORDER message against its own derived
  fills -- a UVM-scoreboard style assertion,
* applies external executions (FLAG_EXTERNAL) to the book,
* flags UDP sequence gaps.

The consumer therefore double-checks both the DUT's book updates and its
trade/execution output from one feed.
"""

import argparse
import socket
from collections import deque

from .orderbook import Order, OrderBook, Side
from .protocol import (
    MSG_ADD,
    MSG_CANCEL,
    MSG_MODIFY,
    MSG_EXECUTE,
    FLAG_EXTERNAL,
    SIDE_BUY,
    decode_message,
)


class ExecutionMismatchError(AssertionError):
    """A matched-fill EXECUTE_ORDER report did not match the derived fill."""


class GoldenReference:
    """Replays a message stream through the reference OrderBook."""

    def __init__(self, book=None):
        self.book = book if book is not None else OrderBook()
        self._expected_fills = deque()  # (order_id, Side, price, qty, ts)
        self.derived_trades = []        # every trade the reference produced
        self.matched_fills = 0          # validated matched-fill reports
        self.external_fills = 0         # applied external executions
        self.received = 0
        self.gaps = 0                   # UDP sequence gaps observed
        self.last_seq = 0

    def process_message(self, msg):
        """Apply one message; return the list of trades it produced (empty
        for matched-fill EXECUTE reports, which are validated instead)."""
        self.received += 1
        if msg.seq_num:
            if self.last_seq and msg.seq_num != self.last_seq + 1:
                self.gaps += 1
            self.last_seq = msg.seq_num

        if msg.msg_type == MSG_ADD:
            order = Order(msg.order_id, _to_side(msg.side), msg.price,
                          msg.quantity, msg.timestamp_ns)
            trades = self.book.add_order(order)
            return self._record_fills(trades)
        if msg.msg_type == MSG_CANCEL:
            self.book.cancel_order(msg.order_id)
            return []
        if msg.msg_type == MSG_MODIFY:
            trades = self.book.modify_order(
                msg.order_id, msg.quantity, msg.price, msg.timestamp_ns)
            return self._record_fills(trades)
        if msg.msg_type == MSG_EXECUTE:
            if msg.flags & FLAG_EXTERNAL:
                trade = self.book.execute_order(
                    msg.order_id, msg.quantity, msg.timestamp_ns)
                self.external_fills += 1
                self.derived_trades.append(trade)
                return [trade]
            self._validate_fill(msg)
            return []
        raise ValueError(f"unsupported msg_type 0x{msg.msg_type:02x}")

    def process_payload(self, payload):
        """Decode one 32-byte payload and process it."""
        return self.process_message(decode_message(payload))

    def check_invariants(self):
        self.book.check_invariants()

    def snapshot(self):
        return self.book.snapshot()

    # ------------------------------------------------------------- internals

    def _record_fills(self, trades):
        """Queue the execution reports the generator will emit for ``trades``
        (buy report, then sell report) and log the trades."""
        for trade in trades:
            self._expected_fills.append(
                (trade.buy_order_id, Side.BUY, trade.price, trade.quantity,
                 trade.timestamp_ns))
            self._expected_fills.append(
                (trade.sell_order_id, Side.SELL, trade.price, trade.quantity,
                 trade.timestamp_ns))
        self.derived_trades.extend(trades)
        return trades

    def _validate_fill(self, msg):
        if not self._expected_fills:
            raise ExecutionMismatchError(
                f"unexpected matched EXECUTE seq={msg.seq_num} "
                f"order={msg.order_id} price={msg.price} qty={msg.quantity}")
        order_id, side, price, quantity, ts = self._expected_fills.popleft()
        expected = (order_id, side.value, price, quantity, ts)
        got = (msg.order_id, msg.side, msg.price, msg.quantity, msg.timestamp_ns)
        if expected != got:
            raise ExecutionMismatchError(
                f"execution mismatch seq={msg.seq_num}: expected "
                f"(order={expected[0]} side={expected[1]:02x} price={expected[2]} "
                f"qty={expected[3]} ts={expected[4]}), got "
                f"(order={got[0]} side={got[1]:02x} price={got[2]} "
                f"qty={got[3]} ts={got[4]})")
        self.matched_fills += 1


def _to_side(wire_side):
    return Side.BUY if wire_side == SIDE_BUY else Side.SELL


class UDPServer:
    """Receives 32-byte UDP payloads and feeds them to a GoldenReference."""

    def __init__(self, host="127.0.0.1", port=0, reference=None):
        self.reference = reference if reference is not None else GoldenReference()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((host, port))
        self.addr = self.sock.getsockname()
        self.closed = False

    def receive_once(self, timeout=None):
        """Receive one datagram and process it; returns the trades produced."""
        self.sock.settimeout(timeout)
        data, _ = self.sock.recvfrom(4096)
        return self.reference.process_payload(data)

    def close(self):
        if not self.closed:
            self.sock.close()
            self.closed = True


def main():
    parser = argparse.ArgumentParser(
        description="LOB golden reference (UDP receiver)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--count", type=int, default=0,
                        help="messages to receive (0 = forever)")
    parser.add_argument("--timeout", type=float, default=30.0,
                        help="seconds of silence before giving up")
    args = parser.parse_args()

    reference = GoldenReference()
    server = UDPServer(args.host, args.port, reference=reference)
    print(f"listening on {server.addr}")
    try:
        while args.count == 0 or reference.received < args.count:
            trades = server.receive_once(timeout=args.timeout)
            for trade in trades:
                print(f"TRADE buy={trade.buy_order_id} sell={trade.sell_order_id} "
                      f"px={trade.price} qty={trade.quantity} ts={trade.timestamp_ns}")
    except socket.timeout:
        print("timeout waiting for traffic")
    finally:
        server.close()
        reference.book.check_invariants()
        print(f"received {reference.received} messages, "
              f"{reference.matched_fills} matched fills validated, "
              f"{reference.external_fills} external fills applied, "
              f"{reference.gaps} seq gaps")
        print(f"book: best_bid={reference.book.get_best_bid()} "
              f"best_ask={reference.book.get_best_ask()} "
              f"orders={len(reference.book)}")


if __name__ == "__main__":
    main()
