#!/usr/bin/env python3
"""Generate a stimulus.hex file for the RTL testbench from the Python
market-data simulator, and later compare the RTL trace against the Python
golden reference model.

The .hex format is one 256-bit hex word per 32-byte message, MSB first
(byte 0 = most significant byte) -- exactly the byte layout the RTL
message_decoder expects.

Usage:
    python3 tools/stimulus.py gen  --seed 0xCAFE --batches 500 --out sim/stimulus.hex
    python3 tools/stimulus.py run  --out-dir sim/   # compile + run iverilog
    python3 tools/stimulus.py cmp  --out-dir sim/   # compare RTL trace vs golden
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "software"))

from lob.consumer import GoldenReference
from lob.protocol import MSG_SIZE, decode_message, FLAG_EXTERNAL, MSG_EXECUTE
from lob.simulator import OrderFlowGenerator

RTL_DIR = Path(__file__).resolve().parent.parent / "rtl"
SIM_DIR = Path(__file__).resolve().parent.parent / "sim"


# ----------------------------------------------------------------------------
#  stimulus generation
# ----------------------------------------------------------------------------

def gen_stimulus(seed, batches, out_path, price_min=1000, price_max=4095):
    gen = OrderFlowGenerator(seed=seed, price_min=price_min, price_max=price_max)
    count = 0
    with open(out_path, "w") as fh:
        for _ in range(batches):
            for msg in gen.next_batch():
                # Matched-fill reports are outputs of the DUT. Only order
                # events and external executions belong on its command input.
                if msg.msg_type == MSG_EXECUTE and not (msg.flags & FLAG_EXTERNAL):
                    continue
                payload = msg.encode()
                assert len(payload) == MSG_SIZE
                word = int.from_bytes(payload, "big")
                fh.write(f"{word:064x}\n")
                count += 1
    print(f"wrote {count} messages to {out_path}")
    return count


# ----------------------------------------------------------------------------
#  compile + run the RTL simulation
# ----------------------------------------------------------------------------

def run_sim():
    pkg = RTL_DIR / "lob_pkg.sv"
    files = [str(pkg)] + sorted(
        str(p) for p in RTL_DIR.glob("*.sv") if p != pkg
    ) + [
        str(SIM_DIR / "tb_lob_engine.sv")
    ]
    vvp = "/tmp/lob_sim.vvp"
    # Do not elaborate unrelated board-network modules as simulation roots.
    cmd = ["iverilog", "-g2012", "-s", "tb_lob_engine", "-o", vvp] + files
    print("compile:", " ".join(cmd[:5]), "...")
    subprocess.run(cmd, check=True)
    print("run:", vvp)
    subprocess.run([vvp], cwd=str(SIM_DIR), check=True)
    print("sim done")


# ----------------------------------------------------------------------------
#  compare RTL trace vs Python golden
# ----------------------------------------------------------------------------

def read_trades(path):
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            buy, sell, price, qty, ts = line.split()
            rows.append((int(buy), int(sell), int(price), int(qty), int(ts)))
    return rows


def read_acks(path):
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            status, oid, rem, bid, ask, n = line.split()
            rows.append((int(status), int(oid), int(rem), int(bid), int(ask), int(n)))
    return rows


def read_status(path):
    with open(path) as fh:
        line = fh.readline().strip()
    bid, ask, n = line.split()
    return (int(bid), int(ask), int(n))


def read_reports(path):
    words = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                words.append(int(line, 16))
    return words


def run_compare(out_dir, seed, batches, price_min=1000, price_max=4095):
    """Replay the same seeded stream through the Python golden model and
    compare: trades, reports, acks (non-status fields), final status."""
    errors = []

    out_dir = Path(out_dir)
    rtl_trades = read_trades(out_dir / "out_trades.txt")
    rtl_reports = read_reports(out_dir / "out_reports.txt")
    rtl_acks = read_acks(out_dir / "out_acks.txt")
    rtl_status = read_status(out_dir / "out_status.txt")

    # ---------------- golden replay ----------------
    gen = OrderFlowGenerator(seed=seed, price_min=price_min, price_max=price_max)
    events = []
    for _ in range(batches):
        for msg in gen.next_batch():
            if msg.msg_type == MSG_EXECUTE and not (msg.flags & FLAG_EXTERNAL):
                continue
            events.append(msg)

    ref = GoldenReference()
    for msg in events:
        ref.process_message(msg)

    # ---------------- reports: derive expected from golden trades ------------
    # For each trade the RTL emits 2 reports (buyer, seller) for matched
    # trades, 1 report (FLAG_EXTERNAL) for external fills.
    # We rebuild expected report payloads directly from the golden model.
    expected_reports = []
    report_seq = 1
    for trade in ref.derived_trades:
        ts = trade.timestamp_ns
        if trade.buy_order_id and trade.sell_order_id:
            expected_reports.append(make_report(
                0x00, 0x00, report_seq, trade.buy_order_id,
                trade.price, trade.quantity, ts))
            report_seq += 1
            expected_reports.append(make_report(
                0x01, 0x00, report_seq, trade.sell_order_id,
                trade.price, trade.quantity, ts))
        else:
            side = 0x00 if trade.buy_order_id else 0x01
            oid = trade.buy_order_id or trade.sell_order_id
            expected_reports.append(make_report(
                side, FLAG_EXTERNAL, report_seq, oid,
                trade.price, trade.quantity, ts))
        report_seq += 1

    # golden trade stream (from ref which processed all messages)
    py_trades = [(t.buy_order_id, t.sell_order_id, t.price, t.quantity,
                  t.timestamp_ns) for t in ref.derived_trades]
    # note: ref.derived_trades includes external fills too (they are appended in
    # execute_order).  The RTL also emits external fills on m_trade.  Good.

    # status
    snap = ref.book.snapshot()
    py_status = (snap["best_bid"] if snap["best_bid"] is not None else 0,
                 snap["best_ask"] if snap["best_ask"] is not None else 0,
                 snap["num_orders"])

    # Per-command acknowledgement, including the book status after the event.
    expected_acks = []
    ack_ref = GoldenReference()
    for msg in events:
        ack_ref.process_message(msg)
        live = ack_ref.book.get_order(msg.order_id)
        best_bid = ack_ref.book.get_best_bid()
        best_ask = ack_ref.book.get_best_ask()
        expected_acks.append((
            0, msg.order_id, live.quantity if live else 0,
            best_bid if best_bid is not None else 0,
            best_ask if best_ask is not None else 0,
            len(ack_ref.book),
        ))

    # ---- compare ----
    if rtl_trades != py_trades:
        errors.append(f"TRADE mismatch: RTL {len(rtl_trades)} vs golden {len(py_trades)}")
        for a, b in zip(rtl_trades, py_trades):
            if a != b:
                errors.append(f"  first diff: RTL={a} golden={b}")
                break

    if rtl_status != py_status:
        errors.append(f"STATUS mismatch: RTL={rtl_status} golden={py_status}")

    if rtl_reports != expected_reports:
        errors.append(
            f"REPORT mismatch: RTL {len(rtl_reports)} vs expected "
            f"{len(expected_reports)}")
        for actual, expected in zip(rtl_reports, expected_reports):
            if actual != expected:
                errors.append(
                    f"  first diff: RTL={actual:064x} golden={expected:064x}")
                break

    if rtl_acks != expected_acks:
        errors.append(
            f"ACK mismatch: RTL {len(rtl_acks)} vs expected {len(expected_acks)}")
        for actual, expected in zip(rtl_acks, expected_acks):
            if actual != expected:
                errors.append(f"  first diff: RTL={actual} golden={expected}")
                break

    if errors:
        print("\n".join(errors))
        sys.exit(1)

    print("ALL COMPARISONS PASSED")
    print(f"  trades   : {len(rtl_trades)}")
    print(f"  reports  : {len(rtl_reports)}")
    print(f"  acks     : {len(rtl_acks)}")
    print(f"  status   : {rtl_status}")


def make_report(side, flags, seq, oid, price, qty, ts):
    b = bytearray(32)
    b[0] = 0x01
    b[1] = 0x04
    b[2] = side
    b[3] = flags
    b[4:8] = seq.to_bytes(4, "big")
    b[8:16] = oid.to_bytes(8, "big")
    b[16:20] = price.to_bytes(4, "big")
    b[20:24] = qty.to_bytes(4, "big")
    b[24:32] = ts.to_bytes(8, "big")
    return int.from_bytes(b, "big")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("gen")
    p.add_argument("--seed", type=lambda s: int(s, 0), default=0xCAFE)
    p.add_argument("--batches", type=int, default=500)
    p.add_argument("--out", default=str(SIM_DIR / "stimulus.hex"))
    p.add_argument("--price-min", type=int, default=1000)
    p.add_argument("--price-max", type=int, default=4095)
    p.add_argument("--compare-after", action="store_true")
    p.set_defaults(func=cmd_gen)

    p = sub.add_parser("run")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("cmp")
    p.add_argument("--seed", type=lambda s: int(s, 0), default=0xCAFE)
    p.add_argument("--batches", type=int, default=500)
    p.add_argument("--price-min", type=int, default=1000)
    p.add_argument("--price-max", type=int, default=4095)
    p.set_defaults(func=cmd_cmp)

    args = ap.parse_args()
    args.func(args)


def cmd_gen(args):
    out = gen_stimulus(args.seed, args.batches, args.out,
                       args.price_min, args.price_max)
    print(f"generated {out} messages")
    if args.compare_after:
        run_sim()
        run_compare(SIM_DIR, args.seed, args.batches,
                    args.price_min, args.price_max)


def cmd_run(args):
    run_sim()


def cmd_cmp(args):
    run_compare(SIM_DIR, args.seed, args.batches,
                args.price_min, args.price_max)


if __name__ == "__main__":
    main()
