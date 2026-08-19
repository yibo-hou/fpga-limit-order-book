#!/usr/bin/env python3
"""Send two crossing orders to the DaVinci Pro LOB and print UDP replies."""

from __future__ import annotations

import argparse
import socket
import struct
import time


WIRE = struct.Struct("!BBBBIQIIQ")


def order(msg_type: int, side: int, seq: int, oid: int,
          price: int, qty: int, timestamp: int) -> bytes:
    return WIRE.pack(1, msg_type, side, 0, seq, oid, price, qty, timestamp)


def describe(data: bytes) -> str:
    if len(data) != 32:
        return f"unexpected {len(data)}-byte payload: {data.hex()}"
    version, kind, code, flags = data[:4]
    if kind == 0x80:
        oid = int.from_bytes(data[8:16], "big")
        remaining = int.from_bytes(data[16:20], "big")
        best_bid = int.from_bytes(data[20:24], "big")
        best_ask = int.from_bytes(data[24:28], "big")
        count = int.from_bytes(data[28:32], "big")
        return (f"ACK v={version} status={code} oid={oid} remaining={remaining} "
                f"best_bid={best_bid} best_ask={best_ask} orders={count}")
    if kind == 4:
        seq = int.from_bytes(data[4:8], "big")
        oid = int.from_bytes(data[8:16], "big")
        price = int.from_bytes(data[16:20], "big")
        qty = int.from_bytes(data[20:24], "big")
        ts = int.from_bytes(data[24:32], "big")
        return (f"REPORT v={version} side={code} flags={flags} seq={seq} "
                f"oid={oid} price={price} qty={qty} ts={ts}")
    return f"unknown type=0x{kind:02x}: {data.hex()}"


def receive_until_ack(sock: socket.socket, timeout: float) -> list[bytes]:
    replies: list[bytes] = []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sock.settimeout(max(0.01, deadline - time.monotonic()))
        try:
            payload, peer = sock.recvfrom(2048)
        except TimeoutError:
            break
        print(f"RX {peer[0]}:{peer[1]} {describe(payload)}")
        replies.append(payload)
        if len(payload) == 32 and payload[1] == 0x80:
            # Reports can follow the acknowledgement, so leave a short drain
            # window rather than returning immediately.
            deadline = min(deadline, time.monotonic() + 0.15)
    return replies


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind-ip", default="192.168.1.100")
    parser.add_argument("--bind-port", type=int, default=5000)
    parser.add_argument("--board-ip", default="192.168.1.10")
    parser.add_argument("--board-port", type=int, default=5001)
    parser.add_argument("--timeout", type=float, default=1.0)
    args = parser.parse_args()

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((args.bind_ip, args.bind_port))
        target = (args.board_ip, args.board_port)
        messages = [
            order(1, 0, 1, 0x1001, 100, 10, 1),
            order(1, 1, 2, 0x1002, 99, 10, 2),
        ]
        total = 0
        for index, message in enumerate(messages, 1):
            print(f"TX order {index}: {message.hex()}")
            sock.sendto(message, target)
            replies = receive_until_ack(sock, args.timeout)
            total += len(replies)
            if not any(len(p) == 32 and p[1] == 0x80 for p in replies):
                print("FAIL: acknowledgement timeout")
                return 1

    print(f"PASS: board returned {total} UDP payloads")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
