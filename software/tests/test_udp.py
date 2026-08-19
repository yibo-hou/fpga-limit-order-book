"""End-to-end UDP test: simulator -> UDP loopback -> golden reference.

Verifies the full wire path the FPGA will use: the market-data simulator
encodes messages and sends them as UDP datagrams; the reference consumer
decodes each payload and must end up with the exchange's exact book state.

Skipped automatically if UDP loopback is unavailable in the environment.
"""

import threading
import unittest

from lob.simulator import OrderFlowGenerator, UDPSender
from lob.consumer import UDPServer

NUM_MESSAGES = 300


class TestUDPRoundTrip(unittest.TestCase):
    def test_loopback_round_trip(self):
        try:
            server = UDPServer(host="127.0.0.1", port=0)
        except OSError as exc:  # pragma: no cover - environment dependent
            self.skipTest(f"UDP loopback unavailable: {exc}")

        generator = OrderFlowGenerator(seed=2024)
        errors = []

        def worker():
            try:
                for _ in range(NUM_MESSAGES):
                    server.receive_once(timeout=10.0)
            except Exception as exc:  # noqa: BLE001 - surface in main thread
                errors.append(exc)
            finally:
                server.close()

        thread = threading.Thread(target=worker)
        thread.start()

        sender = UDPSender(host="127.0.0.1", port=server.addr[1])
        try:
            sent = 0
            while sent < NUM_MESSAGES:
                for msg in generator.next_batch():
                    sender.send_message(msg)
                    sent += 1
        finally:
            sender.close()

        thread.join(timeout=15.0)
        self.assertFalse(thread.is_alive(), "receiver thread hung")
        self.assertEqual(errors, [])

        reference = server.reference
        self.assertEqual(reference.received, NUM_MESSAGES)
        self.assertEqual(reference.gaps, 0)
        # the consumer reproduced the exchange's book over the wire
        self.assertEqual(reference.snapshot(), generator.book.snapshot())
        reference.book.check_invariants()


if __name__ == "__main__":
    unittest.main()
