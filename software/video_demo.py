"""Fixed two-order live demo for the FPGA limit-order-book board.

The script sends two real UDP commands to the board and formats the board's
ACK and EXECUTE report packets for a video recording::

    SELL 100 x 50  -> resting order
    BUY  105 x 80  -> fills the sell, leaves BUY 105 x 30

The board sends one ACK for each command and two EXECUTE reports for a
matched trade (one report per counterparty).  This client pairs those reports
into one human-readable TRADE line.

Board defaults come from ``hardware/board/README.md``:

    FPGA: 192.168.1.10:5001
    Host: 0.0.0.0:5000
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time
from dataclasses import dataclass

from lob.protocol import (
    FLAG_EXTERNAL,
    MSG_ADD,
    MSG_CANCEL,
    MSG_EXECUTE,
    MSG_MODIFY,
    SIDE_BUY,
    SIDE_SELL,
    Message,
    build_message,
    decode_message,
    encode_message,
)


ACK_TYPE = 0x80
MSG_TYPE_NAMES = {
    MSG_ADD: "ADD",
    MSG_CANCEL: "CANCEL",
    MSG_MODIFY: "MODIFY",
    MSG_EXECUTE: "EXECUTE",
}
ACK_STATUS_NAMES = {
    0: "ACCEPTED",
    1: "REJECT_BAD_VERSION",
    2: "REJECT_BAD_FIELD",
    3: "REJECT_NOT_LIVE",
    4: "REJECT_FULL",
    5: "REJECT_INTERNAL",
}


@dataclass(frozen=True)
class FpgaAck:
    status: int
    order_id: int
    remaining_qty: int
    best_bid: int | None
    best_ask: int | None
    num_orders: int

    @property
    def status_name(self) -> str:
        return ACK_STATUS_NAMES.get(self.status, f"UNKNOWN_{self.status}")


@dataclass(frozen=True)
class InteractiveCommand:
    msg_type: int
    side: int
    order_id: int
    price: int
    quantity: int


def _u32(payload: bytes, offset: int) -> int:
    return struct.unpack_from(">I", payload, offset)[0]


def _u64(payload: bytes, offset: int) -> int:
    return struct.unpack_from(">Q", payload, offset)[0]


def decode_fpga_response(payload: bytes) -> FpgaAck | Message:
    """Decode one 32-byte board ACK or EXECUTE report."""
    if len(payload) != 32:
        raise ValueError(f"FPGA response must be 32 bytes, got {len(payload)}")
    if payload[0] != 0x01:
        raise ValueError(f"unsupported FPGA response version 0x{payload[0]:02x}")

    if payload[1] == ACK_TYPE:
        status = payload[2] & 0x07
        best_bid = _u32(payload, 20)
        best_ask = _u32(payload, 24)
        return FpgaAck(
            status=status,
            order_id=_u64(payload, 8),
            remaining_qty=_u32(payload, 16),
            best_bid=best_bid or None,
            best_ask=best_ask or None,
            num_orders=_u32(payload, 28),
        )

    # The board uses the frozen normal EXECUTE_ORDER wire format for reports.
    return decode_message(payload)


def side_name(side: int) -> str:
    if side == SIDE_BUY:
        return "BUY"
    if side == SIDE_SELL:
        return "SELL"
    return f"SIDE_{side}"


def parse_interactive_command(line: str) -> InteractiveCommand:
    """Parse one human-readable command entered at the ``lob>`` prompt."""
    tokens = line.split()
    if not tokens:
        raise ValueError("empty command")

    operation = tokens[0].upper()

    def parse_side(value: str) -> int:
        value = value.upper()
        if value == "BUY":
            return SIDE_BUY
        if value == "SELL":
            return SIDE_SELL
        raise ValueError("side must be BUY or SELL")

    def parse_uint(value: str, field: str) -> int:
        try:
            number = int(value, 0)
        except ValueError as exc:
            raise ValueError(f"{field} must be an integer") from exc
        if number < 0:
            raise ValueError(f"{field} must not be negative")
        return number

    if operation in ("ADD", "MODIFY"):
        if len(tokens) != 5:
            raise ValueError(
                f"usage: {operation} BUY|SELL ORDER_ID PRICE QUANTITY"
            )
        command = InteractiveCommand(
            MSG_ADD if operation == "ADD" else MSG_MODIFY,
            parse_side(tokens[1]),
            parse_uint(tokens[2], "order_id"),
            parse_uint(tokens[3], "price"),
            parse_uint(tokens[4], "quantity"),
        )
        if command.order_id == 0 or command.price == 0 or command.quantity == 0:
            raise ValueError("order_id, price and quantity must be greater than zero")
        return command

    if operation == "CANCEL":
        if len(tokens) != 2:
            raise ValueError("usage: CANCEL ORDER_ID")
        order_id = parse_uint(tokens[1], "order_id")
        if order_id == 0:
            raise ValueError("order_id must be greater than zero")
        # CANCEL is keyed by order ID in the RTL; side/price/qty are ignored.
        return InteractiveCommand(MSG_CANCEL, SIDE_BUY, order_id, 0, 0)

    if operation == "EXECUTE":
        if len(tokens) != 4:
            raise ValueError("usage: EXECUTE BUY|SELL ORDER_ID QUANTITY")
        order_id = parse_uint(tokens[2], "order_id")
        quantity = parse_uint(tokens[3], "quantity")
        if order_id == 0 or quantity == 0:
            raise ValueError("order_id and quantity must be greater than zero")
        return InteractiveCommand(
            MSG_EXECUTE, parse_side(tokens[1]), order_id, 0, quantity
        )

    raise ValueError(f"unknown command {operation!r}; type HELP for syntax")


def print_ack(ack: FpgaAck) -> None:
    print("\n<<< FPGA ACK")
    print(f"  Status:      {ack.status_name}")
    print(f"  Order ID:    {ack.order_id}")
    print(f"  Remaining:   {ack.remaining_qty}")
    print(f"  Best Bid:    {ack.best_bid if ack.best_bid is not None else '-'}")
    print(f"  Best Ask:    {ack.best_ask if ack.best_ask is not None else '-'}")
    print(f"  Live Orders: {ack.num_orders}")


def print_trade(reports: list[Message]) -> None:
    if len(reports) != 2:
        print(f"\n!!! FPGA returned {len(reports)} execution reports; expected 2")
        for report in reports:
            print(
                f"  {side_name(report.side)} id={report.order_id} "
                f"px={report.price} qty={report.quantity}"
            )
        return

    buyers = [report for report in reports if report.side == SIDE_BUY]
    sellers = [report for report in reports if report.side == SIDE_SELL]
    if len(buyers) != 1 or len(sellers) != 1:
        print("\n!!! Could not pair FPGA execution reports into BUY/SELL")
        return

    buy = buyers[0]
    sell = sellers[0]
    print("\n<<< FPGA TRADE")
    print(f"  Price:       {buy.price}")
    print(f"  Quantity:    {buy.quantity}")
    print(f"  Sell ID:     {sell.order_id}")
    print(f"  Buy ID:      {buy.order_id}")
    print(f"  Report Seq:  {buy.seq_num}, {sell.seq_num}")


def print_execution_reports(reports: list[Message]) -> None:
    """Display any number of matched pairs or external execution reports."""
    index = 0
    while index < len(reports):
        report = reports[index]
        if report.flags & FLAG_EXTERNAL:
            print("\n<<< FPGA EXTERNAL EXECUTION")
            print(f"  Side:        {side_name(report.side)}")
            print(f"  Order ID:    {report.order_id}")
            print(f"  Price:       {report.price}")
            print(f"  Quantity:    {report.quantity}")
            index += 1
            continue

        if index + 1 < len(reports):
            print_trade(reports[index:index + 2])
            index += 2
            continue

        print("\n<<< FPGA EXECUTE REPORT")
        print(f"  Side:        {side_name(report.side)}")
        print(f"  Order ID:    {report.order_id}")
        print(f"  Price:       {report.price}")
        print(f"  Quantity:    {report.quantity}")
        index += 1


class FpgaDemoClient:
    def __init__(
        self,
        target: tuple[str, int],
        bind: tuple[str, int],
        timeout: float,
    ) -> None:
        self.target = target
        self.timeout = timeout
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(bind)
        self.seq = 0

    def close(self) -> None:
        self.sock.close()

    def send_command(self, command: InteractiveCommand) -> None:
        self.seq += 1
        message = build_message(
            command.msg_type,
            side=command.side,
            seq_num=self.seq,
            order_id=command.order_id,
            price=command.price,
            quantity=command.quantity,
            timestamp_ns=time.time_ns(),
        )
        print("\n>>> SEND TO FPGA")
        print(f"  Command:     {MSG_TYPE_NAMES[command.msg_type]}")
        if command.msg_type != MSG_CANCEL:
            print(f"  Side:        {side_name(command.side)}")
        print(f"  Order ID:    {command.order_id}")
        if command.msg_type in (MSG_ADD, MSG_MODIFY):
            print(f"  Price:       {command.price}")
        if command.msg_type != MSG_CANCEL:
            print(f"  Quantity:    {command.quantity}")
        print(f"  UDP Target:  {self.target[0]}:{self.target[1]}")
        self.sock.sendto(encode_message(message), self.target)

    def send_order(self, side: int, order_id: int, price: int, quantity: int) -> None:
        self.send_command(
            InteractiveCommand(MSG_ADD, side, order_id, price, quantity)
        )

    def receive_transaction(
        self, order_id: int, expected_reports: int | None
    ) -> tuple[FpgaAck, list[Message]]:
        ack: FpgaAck | None = None
        reports: list[Message] = []
        deadline = time.monotonic() + self.timeout
        quiet_deadline: float | None = None

        while time.monotonic() < deadline:
            receive_deadline = deadline
            if quiet_deadline is not None:
                receive_deadline = min(receive_deadline, quiet_deadline)
            self.sock.settimeout(max(0.01, receive_deadline - time.monotonic()))
            try:
                payload, source = self.sock.recvfrom(4096)
            except TimeoutError:
                if ack is not None and expected_reports is None:
                    return ack, reports
                raise
            response = decode_fpga_response(payload)
            if isinstance(response, FpgaAck):
                if response.order_id == order_id:
                    ack = response
                    print(f"  Received ACK from {source[0]}:{source[1]}")
                    if expected_reports is None:
                        quiet_deadline = time.monotonic() + 0.20
            else:
                reports.append(response)
                print(
                    f"  Received EXECUTE report: {side_name(response.side)} "
                    f"id={response.order_id} px={response.price} "
                    f"qty={response.quantity}"
                )

                if quiet_deadline is not None:
                    quiet_deadline = time.monotonic() + 0.20

            if (ack is not None and expected_reports is not None and
                    len(reports) >= expected_reports):
                return ack, reports

        raise TimeoutError(
            f"timed out waiting for FPGA response: order={order_id}, "
            f"ack={ack is not None}, reports={len(reports)}/{expected_reports}"
        )


INTERACTIVE_HELP = """Commands:
  ADD BUY|SELL ORDER_ID PRICE QUANTITY
  CANCEL ORDER_ID
  MODIFY BUY|SELL ORDER_ID NEW_PRICE NEW_QUANTITY
  EXECUTE BUY|SELL ORDER_ID QUANTITY
  HELP
  QUIT

Examples:
  ADD SELL 1234 100 50
  ADD BUY 5678 105 80
  CANCEL 5678
"""


def run_interactive(args: argparse.Namespace) -> None:
    client = FpgaDemoClient(
        target=(args.fpga_host, args.fpga_port),
        bind=(args.bind_host, args.bind_port),
        timeout=args.timeout,
    )
    try:
        print("=" * 64)
        print("INTERACTIVE FPGA LIMIT ORDER BOOK")
        print("Each command is sent by UDP to the real FPGA board")
        print("=" * 64)
        print(f"Local UDP: {args.bind_host}:{args.bind_port}")
        print(f"FPGA UDP:  {args.fpga_host}:{args.fpga_port}")
        print()
        print(INTERACTIVE_HELP)

        while True:
            try:
                line = input("lob> ").strip()
            except EOFError:
                print()
                break
            if not line:
                continue
            if line.upper() in ("QUIT", "EXIT"):
                break
            if line.upper() in ("HELP", "?"):
                print(INTERACTIVE_HELP)
                continue

            try:
                command = parse_interactive_command(line)
                client.send_command(command)
                ack, reports = client.receive_transaction(
                    command.order_id, expected_reports=None
                )
                if reports:
                    print_execution_reports(reports)
                print_ack(ack)
            except (ValueError, TimeoutError, OSError) as exc:
                print(f"ERROR: {exc}")
    finally:
        client.close()


def run_demo(args: argparse.Namespace) -> None:
    client = FpgaDemoClient(
        target=(args.fpga_host, args.fpga_port),
        bind=(args.bind_host, args.bind_port),
        timeout=args.timeout,
    )
    try:
        print("=" * 64)
        print("LIVE FPGA LIMIT ORDER BOOK DEMO")
        print("Real UDP orders -> FPGA matcher -> ACK / TRADE reports")
        print("=" * 64)
        print(f"Local UDP: {args.bind_host}:{args.bind_port}")
        print(f"FPGA UDP:  {args.fpga_host}:{args.fpga_port}")

        # Resting ask: this should be accepted and become best ask = 100.
        client.send_order(SIDE_SELL, 1234, 100, 50)
        ack_sell, reports_sell = client.receive_transaction(1234, 0)
        print_ack(ack_sell)
        if reports_sell:
            print_trade(reports_sell)
        if ack_sell.status != 0:
            raise RuntimeError(f"first order rejected: {ack_sell.status_name}")

        # Crossing bid: 50 shares trade at the resting ask price; 30 remain.
        client.send_order(SIDE_BUY, 5678, 105, 80)
        ack_buy, reports_buy = client.receive_transaction(5678, 2)
        print_trade(reports_buy)
        print_ack(ack_buy)
        if ack_buy.status != 0:
            raise RuntimeError(f"second order rejected: {ack_buy.status_name}")

        print("\n<<< REMAINING BUY")
        print(f"  Price:       105")
        print(f"  Quantity:    {ack_buy.remaining_qty}")
        print(f"  Order ID:    {ack_buy.order_id}")

        expected = ack_buy.remaining_qty == 30 and len(reports_buy) == 2
        print("\n" + ("PASS" if expected else "CHECK RESULT") + ": FPGA live demo complete")
        if not expected:
            raise RuntimeError("unexpected trade or remaining quantity")
    finally:
        client.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Send a fixed two-order live demo to the FPGA LOB board"
    )
    parser.add_argument("--fpga-host", default="192.168.1.10")
    parser.add_argument("--fpga-port", type=int, default=5001)
    parser.add_argument("--bind-host", default="0.0.0.0")
    parser.add_argument("--bind-port", type=int, default=5000)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="enter orders one at a time at a lob> prompt",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.interactive:
            run_interactive(args)
        else:
            run_demo(args)
    except (OSError, TimeoutError, ValueError, RuntimeError) as exc:
        print(f"\nERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
