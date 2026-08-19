"""Tests for the 32-byte wire protocol (encode / decode)."""

import struct
import unittest

from lob.protocol import (
    Message,
    MSG_SIZE,
    VERSION,
    MSG_ADD,
    MSG_CANCEL,
    MSG_MODIFY,
    MSG_EXECUTE,
    SIDE_BUY,
    SIDE_SELL,
    FLAG_EXTERNAL,
    OFF_VERSION,
    OFF_MSG_TYPE,
    OFF_SIDE,
    OFF_FLAGS,
    OFF_SEQ_NUM,
    OFF_ORDER_ID,
    OFF_PRICE,
    OFF_QUANTITY,
    OFF_TIMESTAMP,
    encode_message,
    decode_message,
    build_message,
)


def sample_message():
    return Message(
        version=1,
        msg_type=MSG_ADD,
        side=SIDE_BUY,
        flags=0,
        seq_num=0x01020304,
        order_id=0x0102030405060708,
        price=10025,
        quantity=500,
        timestamp_ns=0x1122334455667788,
    )


class TestEncodeDecode(unittest.TestCase):
    def test_encode_is_exactly_32_bytes(self):
        for msg_type in (MSG_ADD, MSG_CANCEL, MSG_MODIFY, MSG_EXECUTE):
            payload = encode_message(build_message(msg_type))
            self.assertEqual(len(payload), MSG_SIZE)

    def test_round_trip(self):
        msg = sample_message()
        self.assertEqual(decode_message(encode_message(msg)), msg)

    def test_round_trip_minimal(self):
        msg = build_message(MSG_CANCEL, side=SIDE_SELL, order_id=42, price=1234,
                            quantity=7, seq_num=9, timestamp_ns=999)
        self.assertEqual(decode_message(encode_message(msg)), msg)

    def test_message_encode_method(self):
        msg = sample_message()
        self.assertEqual(msg.encode(), encode_message(msg))
        self.assertEqual(len(msg.encode()), MSG_SIZE)

    def test_message_decode_classmethod(self):
        payload = encode_message(sample_message())
        self.assertEqual(Message.decode(payload), sample_message())

    def test_exact_byte_layout(self):
        """Verify the wire bytes match the offset table exactly."""
        msg = sample_message()
        payload = encode_message(msg)
        expected = struct.pack(
            ">BBBBIQIIQ",
            msg.version, msg.msg_type, msg.side, msg.flags, msg.seq_num,
            msg.order_id, msg.price, msg.quantity, msg.timestamp_ns)
        self.assertEqual(payload, expected)

    def test_big_endian(self):
        """seq_num is stored MSB first at bytes 4..7."""
        payload = encode_message(build_message(MSG_ADD, seq_num=0x01020304))
        self.assertEqual(payload[OFF_SEQ_NUM:OFF_SEQ_NUM + 4],
                         bytes([0x01, 0x02, 0x03, 0x04]))

    def test_offset_constants_match_layout(self):
        payload = encode_message(sample_message())
        self.assertEqual(payload[OFF_VERSION], VERSION)
        self.assertEqual(payload[OFF_MSG_TYPE], MSG_ADD)
        self.assertEqual(payload[OFF_SIDE], SIDE_BUY)
        self.assertEqual(payload[OFF_FLAGS], 0)
        self.assertEqual(struct.unpack_from(">I", payload, OFF_SEQ_NUM)[0],
                         0x01020304)
        self.assertEqual(struct.unpack_from(">Q", payload, OFF_ORDER_ID)[0],
                         0x0102030405060708)
        self.assertEqual(struct.unpack_from(">I", payload, OFF_PRICE)[0], 10025)
        self.assertEqual(struct.unpack_from(">I", payload, OFF_QUANTITY)[0], 500)
        self.assertEqual(struct.unpack_from(">Q", payload, OFF_TIMESTAMP)[0],
                         0x1122334455667788)

    def test_message_type_and_side_encodings(self):
        self.assertEqual(MSG_ADD, 0x01)
        self.assertEqual(MSG_CANCEL, 0x02)
        self.assertEqual(MSG_MODIFY, 0x03)
        self.assertEqual(MSG_EXECUTE, 0x04)
        self.assertEqual(SIDE_BUY, 0x00)
        self.assertEqual(SIDE_SELL, 0x01)

    def test_flags_round_trip(self):
        msg = build_message(MSG_EXECUTE, flags=FLAG_EXTERNAL)
        self.assertEqual(decode_message(encode_message(msg)).flags, FLAG_EXTERNAL)

    def test_max_uint_values_round_trip(self):
        msg = Message(
            version=VERSION, msg_type=MSG_ADD, side=SIDE_SELL, flags=0xFF,
            seq_num=0xFFFFFFFF, order_id=0xFFFFFFFFFFFFFFFF,
            price=0xFFFFFFFF, quantity=0xFFFFFFFF, timestamp_ns=0xFFFFFFFFFFFFFFFF)
        self.assertEqual(decode_message(encode_message(msg)), msg)

    def test_decode_rejects_wrong_length(self):
        with self.assertRaises(ValueError):
            decode_message(b"\x00" * (MSG_SIZE - 1))
        with self.assertRaises(ValueError):
            decode_message(b"\x00" * (MSG_SIZE + 1))
        with self.assertRaises(ValueError):
            decode_message(b"\x00" * 0)

    def test_decode_rejects_bad_version(self):
        # Build the payload manually (encode_message would also reject 0xFF).
        payload = struct.pack(">BBBBIQIIQ", 0xFF, MSG_ADD, SIDE_BUY, 0,
                              0, 0, 0, 0, 0)
        with self.assertRaises(ValueError):
            decode_message(payload)

    def test_decode_rejects_bad_msg_type(self):
        payload = struct.pack(">BBBBIQIIQ", VERSION, 0x99, SIDE_BUY, 0,
                              0, 0, 0, 0, 0)
        with self.assertRaises(ValueError):
            decode_message(payload)

    def test_decode_rejects_bad_side(self):
        payload = struct.pack(">BBBBIQIIQ", VERSION, MSG_ADD, 0x58, 0,
                              0, 0, 0, 0, 0)
        with self.assertRaises(ValueError):
            decode_message(payload)

    def test_encode_rejects_overflow(self):
        msg = build_message(MSG_ADD, price=0x100000000)   # > uint32
        with self.assertRaises(ValueError):
            encode_message(msg)
        msg = build_message(MSG_ADD, order_id=0x10000000000000000)  # > uint64
        with self.assertRaises(ValueError):
            encode_message(msg)
        msg = build_message(MSG_ADD, timestamp_ns=2 ** 64)  # > uint64
        with self.assertRaises(ValueError):
            encode_message(msg)

    def test_encode_rejects_invalid_type_and_side(self):
        with self.assertRaises(ValueError):
            encode_message(build_message(0x00))
        with self.assertRaises(ValueError):
            encode_message(build_message(MSG_ADD, side=0x41))  # not B or S

    def test_decode_accepts_bytearray(self):
        payload = bytearray(encode_message(sample_message()))
        self.assertEqual(decode_message(payload), sample_message())


if __name__ == "__main__":
    unittest.main()
