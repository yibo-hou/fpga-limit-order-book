"""Tests for the real-board video demo packet formatting."""

import struct
import unittest

from lob.protocol import (
    MSG_ADD,
    MSG_CANCEL,
    MSG_EXECUTE,
    MSG_MODIFY,
    SIDE_BUY,
    SIDE_SELL,
    build_message,
    encode_message,
)
from video_demo import (
    FpgaAck,
    decode_fpga_response,
    parse_interactive_command,
)


class TestFpgaResponses(unittest.TestCase):
    def test_decode_ack(self):
        payload = bytearray(32)
        payload[0] = 1
        payload[1] = 0x80
        payload[2] = 0
        struct.pack_into(">QIIII", payload, 8, 5678, 30, 105, 0, 1)

        response = decode_fpga_response(bytes(payload))

        self.assertIsInstance(response, FpgaAck)
        self.assertEqual(response.status_name, "ACCEPTED")
        self.assertEqual(response.order_id, 5678)
        self.assertEqual(response.remaining_qty, 30)
        self.assertEqual(response.best_bid, 105)
        self.assertIsNone(response.best_ask)
        self.assertEqual(response.num_orders, 1)

    def test_decode_execution_report(self):
        payload = encode_message(
            build_message(
                MSG_EXECUTE,
                side=SIDE_BUY,
                seq_num=1,
                order_id=5678,
                price=100,
                quantity=50,
                timestamp_ns=2,
            )
        )

        response = decode_fpga_response(payload)

        self.assertEqual(response.msg_type, MSG_EXECUTE)
        self.assertEqual(response.side, SIDE_BUY)
        self.assertEqual(response.order_id, 5678)
        self.assertEqual(response.price, 100)
        self.assertEqual(response.quantity, 50)

    def test_ack_best_prices_use_zero_as_empty(self):
        payload = bytearray(32)
        payload[0] = 1
        payload[1] = 0x80
        payload[2] = 0
        struct.pack_into(">QIIII", payload, 8, 1234, 50, 0, 100, 1)

        response = decode_fpga_response(bytes(payload))

        self.assertIsNone(response.best_bid)
        self.assertEqual(response.best_ask, 100)


class TestInteractiveCommands(unittest.TestCase):
    def test_add(self):
        command = parse_interactive_command("ADD SELL 1234 100 50")
        self.assertEqual(command.msg_type, MSG_ADD)
        self.assertEqual(command.side, SIDE_SELL)
        self.assertEqual(command.order_id, 1234)
        self.assertEqual(command.price, 100)
        self.assertEqual(command.quantity, 50)

    def test_cancel(self):
        command = parse_interactive_command("cancel 5678")
        self.assertEqual(command.msg_type, MSG_CANCEL)
        self.assertEqual(command.order_id, 5678)

    def test_modify_and_execute(self):
        modify = parse_interactive_command("MODIFY BUY 9 105 30")
        execute = parse_interactive_command("EXECUTE BUY 9 10")
        self.assertEqual(modify.msg_type, MSG_MODIFY)
        self.assertEqual(modify.quantity, 30)
        self.assertEqual(execute.msg_type, MSG_EXECUTE)
        self.assertEqual(execute.quantity, 10)

    def test_invalid_command(self):
        with self.assertRaises(ValueError):
            parse_interactive_command("ADD MAYBE 1 100 10")
        with self.assertRaises(ValueError):
            parse_interactive_command("CANCEL")


if __name__ == "__main__":
    unittest.main()
