# FPGA Limit Order Book Engine — Hardware Architecture

**Target:** Xilinx Artix-7 **XC7A100T** (135 × 18 Kb BRAM, 63,400 LUT, 126,800 FF)
**Objective:** a synthesizable SystemVerilog **price–time priority matching engine**
with BRAM-based order storage, operating as the DUT for UVM verification against
the Python golden reference (`software/`).
**Design priorities:** low latency, deterministic execution, BRAM-friendly access,
byte-level UVM comparability.

---

## 0. Design goals and scope

| Goal | How it is met |
|---|---|
| Low latency | Best bid/ask in **registers**; matching is a 5-stage recirculating pipeline; first trade 5 cycles |
| Determinism | One command serialized at a time; fixed cycle budgets; no speculative paths |
| BRAM-friendly | Every structure is a fixed-depth BRAM keyed by an **index**, never a software pointer |
| UVM compatibility | Same 32-byte wire format, same trade-price convention as the Python reference; status port mirrors `OrderBook.snapshot()` |

Scope: a **simplified continuous exchange book**. The engine supports ADD, CANCEL,
MODIFY (qty / price), EXECUTE (external fill), and matching. Price space is
bounded and windowed (`PRICE_BASE` / `TICK_SHIFT` / `NUM_PRICE_LEVELS`), which is
what makes O(1) price-level lookup possible in BRAM.

---

## 1. Top-level architecture

```
                        ┌────────────────────────────────────────────────────────────────┐
 32-byte wire message   │                        lob_engine_top                            │
 (decoded by UDP        │  ┌───────────────────┐                                            │
  parser)               │  │  input command    │                                            │
 msg_type/side/         │  │  FIFO (fifo_queue)│                                            │
 order_id/price/        │  └─────────┬─────────┘                                            │
 qty/ts                 │            │ (one command at a time)                             │
 ─────────────────────► │  ┌─────────▼─────────┐   ┌──────────────────────────────┐        │
                        │  │  matcher.sv       │   │  order_manager.sv            │        │
                        │  │  (match pipeline, │   │  (ADD enqueue, CANCEL,       │        │
                        │  │   recirculating)  │   │   MODIFY, EXECUTE, free-list)│        │
                        │  └────┬──────────┬───┘   └───┬──────────┬──────────┬────┘        │
                        │       │          │           │          │          │             │
                        │  ┌────▼───┐  ┌───▼────────┐  ┌▼─────────┐┌▼─────────┐┌▼────────┐  │
                        │  │order_  │  │price_level │  │order_id  ││price_level││order_   │  │
                        │  │memory  │  │table (BUY) │  │table     ││table(SELL)││memory   │  │
                        │  │(order  │  │head/tail/  │  │(hash:    ││head/tail/ ││(order   │  │
                        │  │ pool)  │  │qty + occ)  │  │id→slot)  ││qty + occ) ││pool)    │  │
                        │  └────────┘  └────────────┘  └──────────┘└───────────┘└─────────┘  │
                        │  ┌───────────┐   ┌───────────┐  ┌─────────────┐                    │
                        │  │best_price │   │free list  │  │trade_generator.sv                 │
                        │  │_encoder.sv│   │(free slot │  │→ trade FIFO → trade record       │
                        │  │(occ → best│   │ stack)    │  │→ 2× 32-byte execution reports    │
                        │  │ bid/ask)  │   └───────────┘  │→ ack / status                    │
                        │  └───────────┘                  └──────────────────────┬─────────  │
                        └────────────────────────────────────────────────────────┼──────────┘
                                                                                 │
                           trade record ─────────────► UVM scoreboard (compare vs Python Trade)
                           2× 32-byte EXECUTE reports ► UDP TX path (compare vs reference reports)
                           ack/status (best_bid, best_ask, n_orders, qty) ► scoreboard snapshot check
```

**Execution model — one command at a time.** The engine is intentionally
**serialized**: the input FIFO releases one decoded command, and that command is
driven to completion (possibly through many matched trades) before the next
command is released. This removes all BRAM port contention, makes cycle counts
fixed and testable, and is exactly how a deterministic golden reference is
scored. Higher throughput (interleaving multiple in-flight commands) is a
documented future tradeoff (§10).

---

## 2. Wire format → engine interface

The engine consumes the **decoded** fields of the 32-byte message (the UDP
parser is out of scope). Internal message type is a 2-bit/3-bit enum.

> **Interface note (frozen).** The wire protocol uses **numeric** encodings
> (`msg_type` 0x01–0x04, `side` 0x00/0x01), which `software` now emits.
> The `message_decoder.sv` validates the wire byte and maps it **directly** to
> the internal enum below — no translation, so the Python reference, the UVM
> stimulus files, and the DUT are byte-identical. See
> `docs/01_protocol_spec.md` (authoritative).

```
typedef enum logic [2:0] { ADD=1, CANCEL=2, MODIFY=3, EXECUTE=4 } msg_type_t;
typedef enum logic      { BUY=0, SELL=1 } side_t;              // wire: 0/1

input:  msg_type_t  msg_type;
        side_t      side;
        logic[63:0] order_id;
        logic[31:0] price;      // fixed point, e.g. 10025 == $100.25
        logic[31:0] quantity;
        logic[63:0] timestamp_ns;
        logic       valid;
output: trade_ack_t ack;       // accepted / rejected + remaining qty
        trade_rec_t trade;      // matched trade
```

The engine maps the wire `price` to a level index once, in matcher stage 1:
`level_idx = (price - PRICE_BASE) >> TICK_SHIFT`; `level_idx >= NUM_PRICE_LEVELS`
or `price < PRICE_BASE` ⇒ reject the command (acked as rejected).

---

## 3. Memory architecture

All memories are **single/double-port BRAM**, synchronous read, addressed by
index. Parameter summary: `MAX_ORDERS = 8192` (8191 usable),
`NUM_PRICE_LEVELS = 4096` (per side), `HASH_BUCKETS = 16384`,
`HASH_WAYS = 4`, `MAX_HASH_PROBE = 8` sets.

### 3.1 Order memory (order pool) — `order_memory.sv`

One slot per order. `next_ptr` / `prev_ptr` are **indices into the pool** (13 b
each), not software pointers — this is the FPGA equivalent of a doubly linked
FIFO.

| Field | Width | Notes |
|---|---|---|
| `valid` | 1 | slot in use |
| `side` | 1 | BUY / SELL |
| `price` | 16 | quantized price (level index space) |
| `quantity` | 32 | remaining qty (uint32, per wire) |
| `timestamp_ns` | 64 | arrival ts — for execution reports and head tie-break |
| `order_id` | 64 | client order id |
| `next_ptr` | 13 | next order at same price level (0 = none) |
| `prev_ptr` | 13 | previous order at same price level (0 = none) |
| **total** | **204** | |

Vivado infers the 8192 × 204 true-dual-port pool as 51 RAMB36.

Read/write timing: **synchronous read** — address at clock edge *n* yields data
at *n+1*. **Synchronous write** — fire-and-forget at edge *n*; a same-cycle read
of the same address is not needed anywhere in the design (the write of a filled
head and the read of the *next* head are separated by ≥ 1 cycle). True dual
port is used so the matcher (port A) and the manager (port B) never collide.

### 3.2 Price level table — `price_level.sv`

Indexed by level index (0 = lowest price). One entry per level:

| Field | Width | Notes |
|---|---|---|
| `head_ptr` | 13 | first order in the level FIFO (0 = empty) |
| `tail_ptr` | 13 | last order (enqueue point) |
| `total_qty` | 16 | Σ quantity at this level (65535 max per level) |

Entry width = **42 b** (the `occupied` bit lives in the occupancy RAM, §3.5).
The two implemented tables use 10 RAMB36. `total_qty` at 16 b is a deliberate trim (a level holding > 65 535
shares is out of scope); widen to 32 b at +4 BRAM/side if needed.

**Best bid / best ask lookup** — not a search. The occupancy RAM (§3.5) feeds a
priority encoder that computes the best index in **one to two cycles**; the
result is cached in `best_bid` / `best_ask` registers read by the matcher in
stage 2. O(1) lookup, deterministic.

### 3.3 Order ID table (hash) — `order_id_table.sv`

Random access by `order_id` (CANCEL / MODIFY / EXECUTE) uses a **BRAM-backed
four-way set-associative hash table**. This is the FPGA stand-in for the Python
`_orders` dict.

| Field | Width | Notes |
|---|---|---|
| `valid` | 1 | bucket occupied |
| `order_id` | 64 | tag (full id for exact match) |
| `slot_ptr` | 13 | order pool address |

`HASH_BUCKETS = 16384`: 4096 sets × four ways, with each 312-bit row holding four
78-bit buckets. Four ways are compared in parallel and at most eight consecutive
sets (32 buckets) are examined. The implemented table uses 35 RAMB36.
It is **off the matching critical path**. ADD commits the order and level only
after hash insertion succeeds; failure returns the reserved slot to the free list.

### 3.4 Free list — part of `order_manager.sv`

LIFO stack of free slot indices (8192 × 13 b, slot 0 reserved). Its reset-filled
implementation currently maps to 4608 LUTRAM LUTs. `alloc` = pop, `free` = push.

### 3.5 Occupancy bitmap + best-price encoder — `best_price_encoder.sv`

1 bit per level per side (4096 × 2 = 8192 b, **distributed RAM / LUTRAM**, 0 BRAM).
Any level transition to empty clears its bit; any new level sets it. Two
priority encoders: **MSB** priority for bids (highest price first), **LSB**
priority for asks (lowest price first), each 4096→12 b. Built as a pipelined
LUT/CARRY tree (1–2 cycles) so it does not become the Fmax bottleneck.

### 3.6 Implemented memory summary (XC7A100T)

The complete board image uses 96 RAMB36 (192 of 270 physical 18-Kb blocks,
71.1%). The LOB core accounts for all of these block RAMs; small FIFOs
and the free list are currently LUTRAM.

---

## 4. FIFO queue design (same-price time priority)

A price level is a FIFO of order slots linked by `next_ptr`:

```
level[100]:  head_ptr ─► slot(1) ─next─► slot(2) ─next─► slot(3) ◄─ tail_ptr
```

| Operation | Hardware | Cycles |
|---|---|---|
| **Enqueue** (ADD) | write order to free slot; `old_tail.next_ptr = new_slot`; level `{tail_ptr=new_slot, qty+=q}`; if level was empty also `{head_ptr=new_slot, set occupied}` | 3 |
| **Dequeue** (head fully filled) | `head_ptr = head.next_ptr`; free old head slot; level `{qty-=q}`; if now empty `{tail_ptr=0, clear occupied}` | 1 |
| **Remove** (CANCEL / MODIFY-price) | splice via `prev_ptr`/`next_ptr`: `prev.next = next`, `next.prev = prev`; fix `head_ptr`/`tail_ptr` if splicing at an end; `qty-=q` | 1–2 |
| **Partial fill** | head qty field rewritten with remainder; level `qty-=fill`; no pointer change | 1 |

The FIFO position *is* the time priority — no timestamp comparison is needed to
enforce priority; the oldest order is always at `head_ptr`. `timestamp_ns` is
stored only to (a) fill execution reports and (b) break a head-vs-head tie in
the (never-normal) crossed-state resolution (§5.3).

---

## 5. Matching engine

### 5.1 Pipeline stages

A recirculating 5-stage pipeline. One command per pass; when a large incoming
order fills against several resting orders, the remainder loops back through
stages 4–5.

| Stage | Name | Work | Mem access |
|---|---|---|---|
| **S1** | DECODE | pop command; compute `level_idx`; validate price range | — |
| **S2** | LEVEL_READ | read own level `{head,tail,qty}`; read **opposite best level** `{head_ptr}` (index = `best_bid`/`best_ask` register) | level table, both ports |
| **S3** | CROSS_CHECK | bid ≥ ask ? cross : no cross. Cross ⇒ latch opposite `head_ptr`. No cross ⇒ enqueue path | — |
| **S4** | HEAD_READ | read order pool at opposite head slot: `{price, qty, order_id, next_ptr, ts}` | order pool |
| **S5** | TRADE_UPDATE | `match_qty = min(in_qty, head_qty)`; emit trade record; decrement both; write back head; update level `qty`; if head filled ⇒ dequeue (advance `head_ptr`) | order pool + level table |
| **REC** | RECIRCULATE | if `in_qty > 0` and still crossing ⇒ **back to S4** with new `head_ptr`; if `in_qty > 0` and no longer crossing ⇒ enqueue remainder (S3 enqueue path); else DONE | — |

**Trade price rule (matches Python reference exactly):** the trade always prints
at the **resting (passive) head order's price** — the aggressive order receives
price improvement. In the normal insert-then-match flow the passive head is
always the older order, so this is identical to the reference's
`bid_head.ts <= ask_head.ts ? bid_price : ask_price` rule (see §5.3 corner case).

### 5.2 Latency and throughput

| Metric | Value |
|---|---|
| First trade (crossing ADD), from engine input | **5 cycles** = 40 ns @ 125 MHz |
| Additional fills for the same incoming order | +1 cycle each (steady state **1 trade/cycle**, +8 ns) |
| Non-crossing ADD commit | 5 cycles = 40 ns @ 125 MHz |
| CANCEL / MODIFY-qty / EXECUTE | 5–10 cycles (dominated by hash probes) |
| Best bid/ask read | 0 cycles (registers) |
| Pipeline Fmax target | 125 MHz (board standard matching Ethernet clock) |

A single crossing ADD spanning *K* resting orders therefore takes `5 + (K−1)`
cycles and emits *K* trades. This bounded, order-independent behavior is what
the UVM scoreboard replays from the Python model.

### 5.3 Crossed-state corner case (defensive `match_orders` parity)

The reference's standalone `match_orders()` also resolves an already-crossed
book (never produced by normal flow), trading at the head whose timestamp is
older, **bid winning ties**. In the RTL this path is reachable only by a
testbench forcing a crossed state; implement it as: compare the two heads'
`timestamp_ns`, `bid_ts <= ask_ts ? trade@bid : trade@ask`. Normal flow never
takes this branch, but having it keeps the scoreboard bit-exact for directed
UVM tests that inject crossed states.

### 5.4 Matcher FSM

```
        ┌────────────────────────────────────────────────────────────┐
        │                                                            ▼
 IDLE ──► DECODE ──► LEVEL_READ ──► CROSS_CHECK ──(no cross)──► ENQUEUE ──► DONE ──► IDLE
        ▲                │                │ cross                        ▲
        │                │                ▼                              │
        │                │             HEAD_READ ◄─── RECIRC (remainder still crosses)
        │                │                │                              │
        │                └────► TRADE_UPDATE ────────(remainder)─────────┘
        └──────────── DONE (no remainder, or fully filled)
```

`CROSS_CHECK` also holds the allocation decision: a slot is popped from the free
list only when the incoming order actually rests (S3 enqueue path), so a fully
filled order never wastes a slot.

---

## 6. Cancellation / Modify / Execute

### 6.1 CANCEL (by `order_id`)

```
1. HASH_LOOKUP : order_id → slot      (≤4 probe cycles, typically 1–2)
2. READ_SLOT   : {side, price→idx, prev, next, qty}
3. READ_LEVEL  : {head_ptr, tail_ptr, qty}
4. SPLICE      : prev.next = next; next.prev = prev;
                 head/tail adjusted if splicing at an end
5. UPDATE_LEVEL: qty -= q; if level empty → clear occupied bit (best-price refresh)
6. FREE        : valid = 0; push slot to free list; ack(order_id, OK, rem=0)
```
Efficient because the FIFO is doubly linked (`prev_ptr` ⇒ O(1) splice) and the
hash gives O(1) amortized lookup. **Total ≈ 6–8 cycles** (≤ 10 worst case).

### 6.2 MODIFY

- **Quantity only** — keep time priority (matches reference):
  `HASH → READ_SLOT → write new qty → level.qty += Δ`. ≈ 5 cycles. No FIFO
  movement: the order keeps its head/tail position.
- **Price change** — cancel + re-add semantics (matches reference: time priority
  resets): splice out of the old level (CANCEL steps 1–6 *without* freeing),
  rewrite `price`/`level_idx`, **link at the tail of the new level** (newest
  arrival ⇒ last in FIFO), then run the matcher if the new price crosses.
  ≈ 8–12 cycles. Reusing the slot keeps `order_id → slot` valid with no hash
  churn.

### 6.3 EXECUTE (external fill, `flags=EXTERNAL`)

`HASH → READ_SLOT → qty -= fill → level.qty -= fill →` if qty hits 0 run the
CANCEL tail (splice + free). Emits a trade record with **counterparty id 0**
(unknown counterparty) — identical to the reference's `execute_order()`.
≈ 5–7 cycles.

### 6.4 Order manager FSM (shared by 6.1–6.3)

```
        ┌──────────────┐
        │    IDLE      │ ◄────────────────────────────┐
        └──────┬───────┘                              │
               ▼                                      │
        HASH_LOOKUP (1..MAX_HASH_PROBE cycles)        │
               ▼                                      │
           READ_SLOT                                  │
               ▼                                      │
           READ_LEVEL                                 │
               ▼                                      │
      ┌──── SPLICE_UPDATE ────┬───────────────────────┤
      │  (modify-qty: skip)   │                       │
      ▼                       ▼                       │
 UPDATE_QTY / NEW_LEVEL    FREE_SLOT (only if qty==0 or CANCEL)
      │                       │                       │
      └───────────────────────┴──► DONE ──────────────┘
```

CANCEL and MODIFY-price share the same splice datapath; MODIFY-price then
re-enters the matcher. No two paths run concurrently (single-command model).

---

## 7. SystemVerilog module hierarchy

```
rtl/
├── lob_engine_top.sv        -- top: input FIFO, command dispatch, ack/trade out
├── order_memory.sv          -- order pool (4 BRAM banks) + free-list stack
├── price_level.sv           -- per-side level table {head,tail,qty} (BRAM)
├── best_price_encoder.sv    -- occupancy RAM + MSB/LSB priority encoders → best_bid/ask
├── order_id_table.sv        -- BRAM 4-way set-associative hash, order_id → slot
├── fifo_queue.sv            -- parameterized synchronous FIFO (staging/trade/ack)
├── matcher.sv               -- S1–S5 + RECIRC pipeline and match-loop FSM
├── order_manager.sv         -- ADD enqueue, CANCEL/MODIFY/EXECUTE FSMs, free-list control
└── trade_generator.sv       -- trade record + 2× 32-byte EXECUTE reports + ack/status
```

Key port sketches:

```systemverilog
// matcher.sv
module matcher #(
    parameter int MAX_ORDERS = 8192,
    parameter int NUM_LEVELS = 4096
) (
    input  logic clk, rst_n,
    input  cmd_t     cmd,          // decoded command
    input  logic     cmd_valid,
    output logic     cmd_ready,
    output trade_t   trade_out,
    output logic     trade_valid,
    // BRAM port interfaces to order_memory / price_level (wishbone-style)
    output logic [9:0]  pool_waddr,   pool_raddr,
    output logic [197:0]pool_wdata,
    output logic        pool_we,  pool_re,
    input  logic [197:0]pool_rdata,
    output logic [11:0] lvl_addr,   lvl_we,
    output logic [36:0] lvl_wdata,
    input  logic [36:0] lvl_rdata
);
```

```systemverilog
// order_id_table.sv — four-way set-associative hash
module order_id_table #(
    parameter int BUCKETS = 16384,
    parameter int WAYS = 4,
    parameter int MAX_SET_PROBE = 8
) (
    input  logic clk, rst_n,
    input  logic [63:0] lookup_id,
    input  logic        lookup_valid,        // search or insert
    input  logic [12:0] insert_slot,
    input  logic        insert_valid,
    output logic [12:0] hit_slot,
    output logic        hit, miss
);
```

`lob_engine_top.sv` instantiates one `order_memory`, one `order_id_table`, two
`price_level` (BUY/SELL), one `best_price_encoder`, one `matcher`, one
`order_manager`, and the three `fifo_queue`s. All datapath widths are
`localparam`-derived from the single `MAX_ORDERS`/`NUM_LEVELS` pair so the UVM
testbench can configure a smaller DUT for fast sim.

---

## 8. Timing diagrams

Legend: `R()` = BRAM read (address → data, +1 cycle); `W()` = write; `[x]` = data held in a pipeline register.

### 8.1 Crossing ADD, fills two resting orders (BUY 60 hits SELL 50 + SELL 10)

```
cycle   0       1       2       3       4       5       6       7       8       9
        ┌───────┐┌───────┐┌───────┐┌───────┐┌───────┐┌───────┐┌───────┐┌───────┐┌───────┐
cmd_out│ DECODE ││ LVL_RD││ CROSS ││ HEAD_RD││TRADE+ ││HEAD_RD││TRADE+ ││ENQ   ││ DONE  │
        │ S1    ││ S2    ││ S3    ││ S4     ││UPDATE ││S4     ││UPDATE ││(rest)││       │
        └───────┘└───────┘└───────┘└───────┘└───────┘└───────┘└───────┘└───────┘└───────┘
 level  table      R(own)      R(bestA)                        R(ownLvl)
 order  pool               alloc                      R(head1) W(head1)  R(head2) W(head2) W(rest)
 best price                                    reg update if empty   (recompute via encoder)
 trade  fifo                                                       TRADE1        TRADE2
```

First trade out at **cycle 4** after `cmd_out` (5 cycles from engine input);
the second fill at cycle 6; remainder enqueued at cycle 7–8. Latency grows one
cycle per additional resting order — deterministic and scoreboardable.

### 8.2 CANCEL order_id → slot

```
cycle   0        1        2        3        4        5        6        7
        ┌────────┐┌────────┐┌────────┐┌────────┐┌────────┐┌────────┐┌────────┐
        │ DECODE ││HASH p0 ││HASH p1 ││READ_SLOT││READ_LEVEL││SPLICE ││ FREE+ACK │
        └────────┘└────────┘└────────┘└────────┘└────────┘└────────┘└────────┘
 hash   R(bucket0) R(bucket1)                                    W(clear)
 pool                                     R(slot)         W(prev.next)  W(valid=0)
 level                                                        R(lvl)  W(head/tail,qty)
```

6–8 cycles typical; ≤ 10 with `MAX_HASH_PROBE` misses.

---

## 9. Measured FPGA resources (XC7A100T, 8191 usable orders)

| Resource | Implemented board image | Available | Utilization |
|---|---:|---:|---:|
| BRAM | 96 RAMB36 | 135 RAMB36 | **71.1 %** |
| LUT | 12,464 | 63,400 | **19.7 %** |
| FF | 7,042 | 126,800 | **5.6 %** |
| Timing | 125 MHz, WNS +0.040 ns, WHS +0.036 ns | — | met |

The LOB core uses 11,346 LUTs, 4,216 FFs and 96 RAMB36. Of that, the hash uses
674 LUTs and 35 RAMB36; the order pool/free list uses 6,354 LUTs and 51 RAMB36.
The post-route timing margin is valid but thin. No extra pipeline was required
for this capacity, but the free-list LUTRAM and hash writeback remain the first
places to optimize before further scaling.

---

## 10. Design decisions and tradeoffs

1. **Price-grid level table vs. sorted linked list of levels.** A fixed
   `NUM_PRICE_LEVELS` grid gives O(1) `head/tail/qty` access — the latency and
   determinism the engine needs. Cost: bounded price window. The alternative
   (sorted level list) supports arbitrary prices but needs O(n) insert. Chosen:
   **grid**, with `PRICE_BASE`/`TICK_SHIFT` parameters to fit any market.
2. **Occupancy bitmap + priority encoder vs. software-style scan.** Recomputing
   best bid/ask by scanning downward on every level-empty event is O(levels).
   A 1-bit-per-level RAM plus MSB/LSB priority encoders is O(1)-ish (1–2 pipelined
   cycles) and barely costs LUTs. Chosen: **bitmap + encoder**, cached in
   registers.
3. **Four-way set-associative hash for order_id → slot.** A true CAM is not
   native to Artix-7; direct indexing collides for general IDs. Four parallel
   ways plus eight bounded set probes give a 32-bucket window and remain **off
   the matching critical path**. Chosen: **BRAM set-associative hash**.
4. **Doubly linked pool FIFOs with index pointers.** `prev_ptr` makes CANCEL an
   O(1) splice; indices (not memory addresses from a host) keep every reference
   a fixed-width BRAM word. Chosen: **index-based doubly linked FIFO**.
5. **Single-command serialization.** Simplest possible memory arbitration and
   fixed cycle budgets; this is precisely what a golden-reference scoreboard
   needs. Tradeoff: sustained throughput for a burst of *crossing* orders is
   capped at 1 trade/cycle. If a future revision needs interleaving, split the
   order pool into two banks and allow one match loop + one management op
   concurrently (substantial complexity increase — deferred).
6. **Trade prints at the passive head's price.** Matches the Python golden
   reference exactly and is implementable in a comparator; the alternative
   (printing the aggressive price) makes trade prices state-dependent and
   breaks bit-exact scoring.
7. **`total_qty` truncated to 16 b per level.** Configurable; keeps the level
   table at exactly 9 BRAM/side. Same trim philosophy as the pool's bounded
   price window.

---

## 11. UVM verification hooks

| Python reference | RTL equivalent | Scoreboard check |
|---|---|---|
| `OrderBook.snapshot()` | status port `{best_bid, best_ask, n_orders, per-side qty}` | compare after each message |
| `add_order/cancel/modify/execute` → trades | `trade_out` records + ack | replay the same 32-byte stimulus through Python; compare trade streams |
| matched-fill EXECUTE reports (2 per trade) | `trade_generator` 32-byte output | byte-for-byte vs reference reports |
| external EXECUTE input | `EXECUTE` input path (counterparty 0) | compare `Trade(…, 0, …)` |
| `check_invariants()` | structural assertions in `lob_engine_top` | no empty level, no crossed book, pool/hash/free-list consistency |
| seeded stimulus `.bin` (32 B/msg) | testbench feeds bytes to parser | same seed ⇒ identical expected output file |

The engine exposes its memories to the testbench via an optional
**peek/force interface** (read/write any pool slot or level entry by index) so
UVM can inject crossed states and assert internal invariants — mirroring the
Python reference's `_levels` / `check_invariants()`.

---

## Appendix A — message encodings (frozen)

| Field | Encoding | Notes |
|---|---|---|
| `msg_type` | `0x01` ADD · `0x02` CANCEL · `0x03` MODIFY · `0x04` EXECUTE | numeric, no translation in the decoder |
| `side` | `0x00` BUY · `0x01` SELL | numeric |

These values are shared verbatim by `lob/protocol.py`, the UVM transaction
class, the RTL parser, and the stimulus generator. `message_decoder.sv` maps
the wire byte straight onto the internal enum (validation only).
