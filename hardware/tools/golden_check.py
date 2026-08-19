#!/usr/bin/env python3
"""Golden-reference check: RTL LOB engine vs the Python reference model.

Flow:
  1. Generate a deterministic event stream with the market-data simulator
     (order events only - matched-fill reports are the DUT's OUTPUT, not input).
  2. Replay the events through the Python golden reference (OrderBook),
     collecting expected trades, reports, acks and the final snapshot.
  3. Write the event stream as stimulus.hex for the iverilog testbench.
  4. Run iverilog, parse the RTL trace, and compare byte-for-byte:
       trades (buy sell price qty ts)      vs reference trades
       reports (32-byte EXECUTE messages)  vs reference reports
       acks   (status / remaining / TBB)   vs reference book state per message
       status (best_bid best_ask n_orders) vs reference snapshot

Usage:
  python3 tools/golden_check.py [--seed 123] [--count 1000] [--noverify]
"""

import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..",
                                "software"))

from lob.consumer import GoldenReference
from lob.protocol import (
    MSG_ADD, MSG_CANCEL, MSG_MODIFY, MSG_EXECUTE, FLAG_EXTERNAL,
    SIDE_BUY, SIDE_SELL, VERSION, Message, encode_message,
)
from lob.simulator import OrderFlowGenerator

# RTL test configuration (must match sim/tb_lob_engine.sv)
NUM_PRICE_LEVELS = 4096
MAX_ORDERS = 8192            # usable slots = MAX_ORDERS - 1
PRICE_MIN = 100
PRICE_MAX = 3900             # within [1, 4095]
MAX_QTY = 100                # keeps per-level total_qty < 65536


def integer(text):
    return int(text, 0)


def rtl_hash_set(order_id):
    """Python copy of order_id_table.hash64 for collision test generation."""
    mixed = order_id ^ (order_id >> 17) ^ (order_id >> 41)
    result = 0
    for bit_index in range(64):
        if (mixed >> bit_index) & 1:
            result ^= 1 << (bit_index % 12)
    return result


def add_message(sequence, order_id, price=100, quantity=1, side=SIDE_BUY):
    return Message(msg_type=MSG_ADD, side=side, seq_num=sequence,
                   order_id=order_id, price=price, quantity=quantity,
                   timestamp_ns=sequence)


def make_report(side, flags, seq, oid, price, qty, ts):
    """Encode a 32-byte EXECUTE report as a 256-bit integer (byte0 = MSB)."""
    r = (VERSION << 248) | (0x04 << 240) | (side << 232) | (flags << 224) \
        | (seq << 192) | (oid << 128) | (price << 96) | (qty << 64) | ts
    return r


def parse_int_trace(path):
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            rows.append([int(x) for x in line.split()])
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=integer, default=0x1234)
    ap.add_argument("--count", type=int, default=1000, help="event batches")
    ap.add_argument("--scenario",
                    choices=("random", "capacity", "collision", "fastpath",
                             "parallel-read"),
                    default="random")
    ap.add_argument("--noverify", action="store_true",
                    help="write stimulus only, skip the RTL run")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    sim_dir = os.path.abspath(os.path.join(here, "..", "sim"))
    rtl_dir = os.path.abspath(os.path.join(here, "..", "rtl"))

    # ---------------------------------------------------------------- generate
    events = []
    rejected = {}
    if args.scenario == "random":
        gen = OrderFlowGenerator(seed=args.seed, price_min=PRICE_MIN,
                                 price_max=PRICE_MAX, max_quantity=MAX_QTY)
        for _ in range(args.count):
            for msg in gen.next_batch():
                # keep order events; drop matched-fill reports (flags == 0)
                if (msg.msg_type == MSG_EXECUTE
                        and not (msg.flags & FLAG_EXTERNAL)):
                    continue
                events.append(msg)
    elif args.scenario == "capacity":
        events = [add_message(index, index, price=100)
                  for index in range(1, MAX_ORDERS + 1)]
        rejected[MAX_ORDERS - 1] = 4       # ACK_REJECT_FULL
    elif args.scenario == "collision":
        collision_ids = []
        candidate = 1
        while len(collision_ids) < 33:
            if rtl_hash_set(candidate) == 0:
                collision_ids.append(candidate)
            candidate += 1
        events = [add_message(index, order_id, price=200)
                  for index, order_id in enumerate(collision_ids, 1)]
        rejected[32] = 5                   # ACK_REJECT_INTERNAL
    elif args.scenario == "fastpath":
        # Directed fast-path coverage: BUY and SELL aggression, a partial
        # passive fill, multiple price levels, a fully consumed incoming order
        # and an incoming remainder that must fall back to enqueue.
        events = [
            add_message(1, 1, price=100, quantity=10, side=SIDE_SELL),
            add_message(2, 2, price=101, quantity=20, side=SIDE_SELL),
            add_message(3, 3, price=103, quantity=50, side=SIDE_SELL),
            add_message(4, 10, price=102, quantity=25, side=SIDE_BUY),
            add_message(5, 11, price=103, quantity=60, side=SIDE_BUY),
            add_message(6, 12, price=102, quantity=2, side=SIDE_SELL),
            add_message(7, 13, price=103, quantity=10, side=SIDE_SELL),
        ]
    else:
        # Force the defensive drain (rather than ADD fast-path): MODIFY a
        # resting bid through the best ask.  This directly covers the two-beat
        # parallel level/head read sequence in matcher.sv.
        events = [
            add_message(1, 1, price=100, quantity=10, side=SIDE_SELL),
            add_message(2, 2, price=90, quantity=10, side=SIDE_BUY),
            Message(msg_type=MSG_MODIFY, side=SIDE_BUY, seq_num=3,
                    order_id=2, price=101, quantity=10, timestamp_ns=3),
        ]

    if not events:
        print("ERROR: no events generated")
        sys.exit(1)

    # ------------------------------------------------------------- reference
    ref = GoldenReference()
    peak_live = 0
    for event_index, msg in enumerate(events):
        if event_index in rejected:
            continue
        ref.process_message(msg)
        peak_live = max(peak_live, len(ref.book))
    print(f"INFO: {len(events)} events, peak live orders = {peak_live} "
          f"(limit {MAX_ORDERS - 1})")
    if peak_live >= MAX_ORDERS:
        print("ERROR: peak live orders exceed the RTL pool - increase MAX_ORDERS")
        sys.exit(1)

    expected_trades = list(ref.derived_trades)

    # expected reports (RTL report seq starts at 1)
    expected_reports = []
    rseq = 1
    for tr in expected_trades:
        if tr.buy_order_id and tr.sell_order_id:
            expected_reports.append(
                make_report(SIDE_BUY, 0, rseq, tr.buy_order_id, tr.price,
                            tr.quantity, tr.timestamp_ns)); rseq += 1
            expected_reports.append(
                make_report(SIDE_SELL, 0, rseq, tr.sell_order_id, tr.price,
                            tr.quantity, tr.timestamp_ns)); rseq += 1
        else:
            side = SIDE_BUY if tr.buy_order_id else SIDE_SELL
            oid = tr.buy_order_id or tr.sell_order_id
            expected_reports.append(
                make_report(side, FLAG_EXTERNAL, rseq, oid, tr.price,
                            tr.quantity, tr.timestamp_ns)); rseq += 1

    # per-event expected ack state (replayed against a fresh book)
    ack_expected = []          # (status, remaining, best_bid, best_ask, n_orders)
    ref2 = GoldenReference()
    for event_index, msg in enumerate(events):
        if event_index in rejected:
            bb = ref2.book.get_best_bid()
            ba = ref2.book.get_best_ask()
            ack_expected.append((rejected[event_index], 0,
                                 bb if bb is not None else 0,
                                 ba if ba is not None else 0,
                                 len(ref2.book)))
            continue
        ref2.process_message(msg)
        live = ref2.book.get_order(msg.order_id)
        remaining = live.quantity if live else 0
        bb = ref2.book.get_best_bid()
        ba = ref2.book.get_best_ask()
        ack_expected.append((0, remaining,
                             bb if bb is not None else 0,
                             ba if ba is not None else 0,
                             len(ref2.book)))

    snap = ref.snapshot()

    # ------------------------------------------------------------ stimulus.hex
    hex_lines = []
    for m in events:
        p = encode_message(m)
        val = int.from_bytes(p, "big")
        hex_lines.append(f"{val:064x}")
    stim_path = os.path.join(sim_dir, "stimulus.hex")
    with open(stim_path, "w") as fh:
        fh.write("\n".join(hex_lines) + "\n")
    print(f"INFO: wrote {stim_path} ({len(hex_lines)} messages)")

    if args.noverify:
        return 0

    # ---------------------------------------------------------------- run RTL
    pkg = os.path.join(rtl_dir, "lob_pkg.sv")     # must compile first
    others = [os.path.join(rtl_dir, f) for f in sorted(os.listdir(rtl_dir))
              if f != "lob_pkg.sv"]
    rtl_files = [pkg] + others
    tb = os.path.join(sim_dir, "tb_lob_engine.sv")
    vvp = os.path.join(sim_dir, "lob_sim.vvp")

    # Explicitly select the LOB testbench. The rtl directory also contains
    # board-network helpers with Xilinx primitives which are not part of this
    # simulation and must not be elaborated as independent root modules.
    cmd = ["iverilog", "-g2012", "-s", "tb_lob_engine", "-o", vvp] \
        + rtl_files + [tb]
    print("INFO: " + " ".join(cmd))
    r = subprocess.run(cmd, cwd=sim_dir, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-3000:])
        print(r.stderr[-3000:])
        sys.exit(1)

    r = subprocess.run(["vvp", vvp], cwd=sim_dir, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-3000:])
        print(r.stderr[-3000:])
        sys.exit(1)
    print(r.stdout.strip())

    # ---------------------------------------------------------------- compare
    failures = 0

    def check(label, cond, detail=""):
        nonlocal failures
        if not cond:
            failures += 1
            print(f"FAIL {label}: {detail}")

    # trades
    rtl_trades = parse_int_trace(os.path.join(sim_dir, "out_trades.txt"))
    exp_trades = [(t.buy_order_id, t.sell_order_id, t.price, t.quantity,
                   t.timestamp_ns) for t in expected_trades]
    check("trade count", len(rtl_trades) == len(exp_trades),
          f"RTL={len(rtl_trades)} expected={len(exp_trades)}")
    for i, (rt, et) in enumerate(zip(rtl_trades, exp_trades)):
        if tuple(rt) != et:
            check(f"trade[{i}]", False,
                  f"RTL={tuple(rt)} expected={et}")
            if failures > 10:
                break
    if len(rtl_trades) != len(exp_trades):
        for i, (rt, et) in enumerate(
                zip(rtl_trades[:10], exp_trades[:10])):
            print(f"  trade[{i}] RTL={tuple(rt)} exp={et}")

    # reports (256-bit hex)
    with open(os.path.join(sim_dir, "out_reports.txt")) as fh:
        rtl_reports = [int(line.strip(), 16) for line in fh if line.strip()]
    check("report count", len(rtl_reports) == len(expected_reports),
          f"RTL={len(rtl_reports)} expected={len(expected_reports)}")
    for i, (rr, er) in enumerate(zip(rtl_reports, expected_reports)):
        if rr != er:
            check(f"report[{i}]", False,
                  f"RTL={rr:064x} expected={er:064x}")
            if failures > 20:
                break

    # acks (per event)
    rtl_acks = parse_int_trace(os.path.join(sim_dir, "out_acks.txt"))
    check("ack count", len(rtl_acks) == len(ack_expected),
          f"RTL={len(rtl_acks)} expected={len(ack_expected)}")
    for i, (ra, ea) in enumerate(zip(rtl_acks, ack_expected)):
        status, oid, remaining, bb, ba, n = ra
        est, erem, ebb, eba, en = ea
        if status != est:
            check(f"ack[{i}] status", False,
                  f"RTL={status} expected={est}")
        if remaining != erem:
            check(f"ack[{i}] remaining", False,
                  f"order={oid} RTL={remaining} exp={erem}")
        # The RTL status interface encodes an empty side as zero.
        if bb != ebb:
            check(f"ack[{i}] best_bid", False,
                  f"RTL={bb} exp={ebb}")
        if ba != eba:
            check(f"ack[{i}] best_ask", False,
                  f"RTL={ba} exp={eba}")
        if n != en:
            check(f"ack[{i}] num_orders", False,
                  f"RTL={n} exp={en}")
        if failures > 20:
            break

    # final status snapshot
    rtl_status = parse_int_trace(os.path.join(sim_dir, "out_status.txt"))
    if rtl_status:
        rb, ra, rn = rtl_status[0]
        eb = snap["best_bid"]
        ea = snap["best_ask"]
        check("final best_bid", rb == (eb if eb is not None else 0),
              f"RTL={rb} exp={eb}")
        check("final best_ask", ra == (ea if ea is not None else 0),
              f"RTL={ra} exp={ea}")
        check("final num_orders", rn == snap["num_orders"],
              f"RTL={rn} exp={snap['num_orders']}")

    print()
    if failures == 0:
        print(f"PASS: RTL matches the Python golden reference "
              f"({len(exp_trades)} trades, {len(expected_reports)} reports, "
              f"{len(ack_expected)} acks)")
        return 0
    print(f"FAIL: {failures} mismatches")
    return 1


if __name__ == "__main__":
    sys.exit(main())
