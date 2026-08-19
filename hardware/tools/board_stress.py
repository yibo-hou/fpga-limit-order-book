#!/usr/bin/env python3
"""Deterministic UDP stress test for the DaVinci Pro LOB bitstream."""

from __future__ import annotations

import argparse
import os
import socket
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..",
                                "software"))

from lob.consumer import GoldenReference
from lob.protocol import (FLAG_EXTERNAL, MSG_ADD, MSG_EXECUTE, MSG_MODIFY,
                          SIDE_BUY, SIDE_SELL, Message, encode_message)
from lob.simulator import OrderFlowGenerator

MAX_ORDERS = 8192


def integer(text: str) -> int:
    return int(text, 0)


def make_report(side: int, flags: int, seq: int, oid: int, price: int,
                qty: int, timestamp: int) -> bytes:
    value = ((1 << 248) | (MSG_EXECUTE << 240) | (side << 232)
             | (flags << 224) | (seq << 192) | (oid << 128)
             | (price << 96) | (qty << 64) | timestamp)
    return value.to_bytes(32, "big")


def expected_reports(trades, first_seq: int) -> tuple[list[bytes], int]:
    reports: list[bytes] = []
    seq = first_seq
    for trade in trades:
        if trade.buy_order_id and trade.sell_order_id:
            reports.append(make_report(SIDE_BUY, 0, seq,
                                       trade.buy_order_id, trade.price,
                                       trade.quantity, trade.timestamp_ns))
            seq += 1
            reports.append(make_report(SIDE_SELL, 0, seq,
                                       trade.sell_order_id, trade.price,
                                       trade.quantity, trade.timestamp_ns))
            seq += 1
        else:
            side = SIDE_BUY if trade.buy_order_id else SIDE_SELL
            oid = trade.buy_order_id or trade.sell_order_id
            reports.append(make_report(side, FLAG_EXTERNAL, seq, oid,
                                       trade.price, trade.quantity,
                                       trade.timestamp_ns))
            seq += 1
    return reports, seq


def ack_fields(payload: bytes) -> tuple[int, int, int, int, int, int]:
    return (
        payload[2],
        int.from_bytes(payload[8:16], "big"),
        int.from_bytes(payload[16:20], "big"),
        int.from_bytes(payload[20:24], "big"),
        int.from_bytes(payload[24:28], "big"),
        int.from_bytes(payload[28:32], "big"),
    )


def receive_response(sock: socket.socket, board_ip: str, report_count: int,
                     timeout: float) -> tuple[bytes, list[bytes]]:
    ack = None
    reports: list[bytes] = []
    deadline = time.monotonic() + timeout
    while ack is None or len(reports) < report_count:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                f"response timeout: ack={ack is not None}, "
                f"reports={len(reports)}/{report_count}")
        sock.settimeout(remaining)
        try:
            payload, peer = sock.recvfrom(2048)
        except socket.timeout as exc:
            raise TimeoutError(
                f"response timeout: ack={ack is not None}, "
                f"reports={len(reports)}/{report_count}") from exc
        if peer[0] != board_ip:
            continue
        if len(payload) != 32 or payload[0] != 1:
            raise RuntimeError(f"invalid payload: {payload.hex()}")
        if payload[1] == 0x80:
            if ack is not None:
                raise RuntimeError("duplicate acknowledgement")
            ack = payload
        elif payload[1] == MSG_EXECUTE:
            reports.append(payload)
        else:
            raise RuntimeError(f"unexpected output type 0x{payload[1]:02x}")
        if len(reports) > report_count:
            raise RuntimeError(
                f"extra report: got {len(reports)}, expected {report_count}")
    return ack, reports


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=1000,
                        help="number of command batches")
    parser.add_argument("--scenario",
                        choices=("random", "capacity", "fastpath",
                                 "parallel-read"),
                        default="random")
    parser.add_argument("--seed", type=integer, default=0x1234)
    parser.add_argument("--bind-ip", default="192.168.1.100")
    parser.add_argument("--bind-port", type=int, default=5000)
    parser.add_argument("--board-ip", default="192.168.1.10")
    parser.add_argument("--board-port", type=int, default=5001)
    parser.add_argument("--timeout", type=float, default=1.0)
    parser.add_argument("--progress", type=int, default=100)
    parser.add_argument("--interval", type=float, default=0.0,
                        help="delay between commands in seconds")
    parser.add_argument("--prime", action="store_true",
                        help="send a non-mutating bad-version packet first")
    args = parser.parse_args()

    commands = []
    rejected = {}
    if args.scenario == "random":
        generator = OrderFlowGenerator(seed=args.seed, price_min=100,
                                       price_max=3900, max_quantity=100)
        for _ in range(args.count):
            for message in generator.next_batch():
                # Ordinary matched-fill EXECUTEs are expected DUT outputs. An
                # external EXECUTE remains a command input.
                if (message.msg_type == MSG_EXECUTE
                        and not (message.flags & FLAG_EXTERNAL)):
                    continue
                commands.append(message)
    elif args.scenario == "capacity":
        commands = [Message(msg_type=MSG_ADD, side=SIDE_BUY, seq_num=index,
                            order_id=index, price=100, quantity=1,
                            timestamp_ns=index)
                    for index in range(1, MAX_ORDERS + 1)]
        rejected[MAX_ORDERS] = 4           # ACK_REJECT_FULL
    elif args.scenario == "fastpath":
        def add(seq, oid, price, quantity, side):
            return Message(msg_type=MSG_ADD, side=side, seq_num=seq,
                           order_id=oid, price=price, quantity=quantity,
                           timestamp_ns=seq)

        commands = [
            add(1, 1, 100, 10, SIDE_SELL),
            add(2, 2, 101, 20, SIDE_SELL),
            add(3, 3, 103, 50, SIDE_SELL),
            add(4, 10, 102, 25, SIDE_BUY),
            add(5, 11, 103, 60, SIDE_BUY),
            add(6, 12, 102, 2, SIDE_SELL),
            add(7, 13, 103, 10, SIDE_SELL),
        ]
    else:
        commands = [
            Message(msg_type=MSG_ADD, side=SIDE_SELL, seq_num=1,
                    order_id=1, price=100, quantity=10, timestamp_ns=1),
            Message(msg_type=MSG_ADD, side=SIDE_BUY, seq_num=2,
                    order_id=2, price=90, quantity=10, timestamp_ns=2),
            Message(msg_type=MSG_MODIFY, side=SIDE_BUY, seq_num=3,
                    order_id=2, price=101, quantity=10, timestamp_ns=3),
        ]

    reference = GoldenReference()
    report_seq = 1
    total_reports = 0
    peak_orders = 0
    started = time.monotonic()

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        sock.bind((args.bind_ip, args.bind_port))
        target = (args.board_ip, args.board_port)

        if args.prime:
            prime = bytearray(32)
            prime[1] = MSG_ADD
            sock.sendto(prime, target)
            try:
                receive_response(sock, args.board_ip, 0, 0.25)
            except TimeoutError:
                pass
            time.sleep(0.05)

        for index, message in enumerate(commands, 1):
            if args.interval:
                time.sleep(args.interval)
            trade_start = len(reference.derived_trades)
            if index not in rejected:
                reference.process_message(message)
            trades = reference.derived_trades[trade_start:]
            reports_expected, report_seq = expected_reports(trades, report_seq)

            live = reference.book.get_order(message.order_id)
            best_bid = reference.book.get_best_bid()
            best_ask = reference.book.get_best_ask()
            ack_expected = (
                rejected.get(index, 0),
                message.order_id,
                live.quantity if live else 0,
                best_bid if best_bid is not None else 0,
                best_ask if best_ask is not None else 0,
                len(reference.book),
            )
            peak_orders = max(peak_orders, len(reference.book))

            sock.sendto(encode_message(message), target)
            try:
                ack, reports = receive_response(
                    sock, args.board_ip, len(reports_expected), args.timeout)
            except (TimeoutError, RuntimeError) as exc:
                print(f"FAIL command {index}/{len(commands)}: {exc}")
                print(f"  input={encode_message(message).hex()}")
                return 1

            actual_ack = ack_fields(ack)
            if actual_ack != ack_expected:
                print(f"FAIL command {index}: ACK mismatch")
                print(f"  actual  ={actual_ack}")
                print(f"  expected={ack_expected}")
                return 1
            if reports != reports_expected:
                print(f"FAIL command {index}: REPORT mismatch")
                for report_index, (actual, expected) in enumerate(
                        zip(reports, reports_expected), 1):
                    if actual != expected:
                        print(f"  report {report_index} actual  ={actual.hex()}")
                        print(f"  report {report_index} expected={expected.hex()}")
                        break
                return 1

            total_reports += len(reports)
            if args.progress and index % args.progress == 0:
                elapsed = time.monotonic() - started
                print(f"PASS {index}/{len(commands)} commands, "
                      f"reports={total_reports}, live={len(reference.book)}, "
                      f"rate={index / elapsed:.1f} cmd/s")

    elapsed = time.monotonic() - started
    print(f"PASS: {len(commands)} commands, {total_reports} reports, "
          f"peak_live={peak_orders}, final_live={len(reference.book)}, "
          f"elapsed={elapsed:.3f}s, rate={len(commands) / elapsed:.1f} cmd/s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
