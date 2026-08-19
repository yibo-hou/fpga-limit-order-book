# 03 — RTL Interface Specification (valid/ready)

No RTL is generated yet; this document **freezes the module interfaces** so that
RTL and UVM can be written in parallel against the same contracts.

---

## 1. Handshake protocol (global)

Every datapath interface is **valid/ready** (AXI-stream style):

```
        master ── data ─────────► slave
                ── valid ───────►
                ◄── ready ───────

A transfer happens on every clock edge where valid && ready.
```

Rules:

1. `valid` and `data` are asserted by the master and must stay stable until
   `ready` is sampled high — no dropping, no mid-transfer changes.
2. `ready` is combinatorial or registered; with a registered `ready`, the master
   must keep `valid` asserted until the transfer completes (the slave's
   `ready` is re-asserted).
3. A transfer consumes one item on each side.
4. All interfaces are backpressured; no unbounded queues.

**Naming:** a slave interface entering a module is `s_<name>_{valid,ready,data}`;
a master interface leaving it is `m_<name>_{valid,ready,data}`.

---

## 2. Shared types (`lob_pkg.sv`)

```systemverilog
package lob_pkg;
    typedef enum logic [2:0] { ADD=1, CANCEL=2, MODIFY=3, EXECUTE=4 } msg_type_t;
    typedef enum logic      { BUY=0, SELL=1 } side_t;
    typedef enum logic [2:0] {
        ACK_OK=0, REJECT_BAD_VERSION=1, REJECT_BAD_FIELD=2,
        REJECT_NOT_LIVE=3, REJECT_FULL=4, REJECT_INTERNAL=5
    } ack_status_t;

    // decoded 32-byte message (matches the wire 1:1)
    typedef struct packed {
        logic [7:0]  version;
        msg_type_t   msg_type;
        side_t       side;
        logic [7:0]  flags;          // bit0 FLAG_EXTERNAL
        logic [31:0] seq_num;
        logic [63:0] order_id;
        logic [31:0] price;
        logic [31:0] quantity;
        logic [63:0] timestamp_ns;
    } msg_t;                          // 256 bits == 32 bytes

    // command passed to the matcher / order manager
    typedef struct packed {
        msg_type_t   msg_type;
        side_t       side;
        logic [31:0] seq_num;
        logic [63:0] order_id;
        logic [31:0] price;           // wire price (fixed point)
        logic [31:0] quantity;
        logic [63:0] timestamp_ns;
        logic [11:0] level_idx;       // computed in matcher S1
    } cmd_t;

    typedef struct packed {
        logic [63:0] buy_order_id;    // 0 for external fill
        logic [63:0] sell_order_id;   // 0 for external fill
        logic [31:0] price;           // trade price (passive head's price)
        logic [31:0] quantity;
        logic [63:0] timestamp_ns;
    } trade_t;

    typedef struct packed {
        ack_status_t status;
        logic [63:0] order_id;
        logic [31:0] remaining_qty;
        logic [31:0] best_bid;
        logic [31:0] best_ask;
        logic [ 9:0] num_orders;
    } ack_t;

    typedef struct packed {
        logic [9:0]  head_ptr;        // 0 = empty
        logic [9:0]  tail_ptr;
        logic [15:0] total_qty;
    } level_rec_t;                    // 36 bits, price_level table entry

    typedef struct packed {
        logic        valid;
        side_t       side;
        logic [15:0] price_q;         // quantized price (level index)
        logic [31:0] quantity;
        logic [63:0] timestamp_ns;
        logic [63:0] order_id;
        logic [9:0]  next_ptr;
        logic [9:0]  prev_ptr;
    } order_rec_t;                    // 198 bits, order pool entry
endpackage
```

`msg_t` is exactly 32 bytes packed — the decoder's output maps 1:1 to the wire.

---

## 3. Byte-to-bit mapping (decoder input)

`lob_engine_top` receives the raw 32-byte UDP payload as one packed word.
**Byte 0 (version) is the MSB:**

```systemverilog
logic [255:0] s_payload;
// byte b occupies s_payload[255 - 8*b -: 8]
// byte 0 = version, byte 1 = msg_type, byte 2 = side, byte 3 = flags,
// bytes 4..7 = seq_num, bytes 8..15 = order_id, bytes 16..19 = price,
// bytes 20..23 = quantity, bytes 24..31 = timestamp_ns
```

The UVM driver packs `lob_msg_txn` with the same MSB-first convention, so the
bytes the parser sees are byte-identical to `Message.encode()` output.

---

## 4. Module interface definitions

### 4.1 `lob_engine_top.sv`

| Port | Direction | Width | Description |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | synchronous active-low reset |
| `s_payload` | in | 256 | raw 32-byte message (byte 0 = MSB) |
| `s_payload_valid` | in | 1 | handshake |
| `s_payload_ready` | out | 1 | handshake |
| `m_trade` | out | `trade_t` | matched trade record |
| `m_trade_valid` / `m_trade_ready` | out / in | 1 | trade output |
| `m_report` | out | 256 | 32-byte EXECUTE execution report |
| `m_report_valid` / `m_report_ready` | out / in | 1 | report output (2 per trade) |
| `m_ack` | out | `ack_t` | per-command acknowledgement + status |
| `m_ack_valid` / `m_ack_ready` | out / in | 1 | ack output |
| `status_best_bid` / `status_best_ask` | out | 32 | current top of book (registers) |
| `status_num_orders` | out | 10 | live order count |
| `status_level_qty[side][idx]` | out | 16 | per-level total qty (UVM snapshot compare) |

Top logic: instantiate `message_decoder` → command FIFO → dispatch to
`matcher` / `order_manager` → `trade_generator`. One command is driven to
completion before the next is released from the command FIFO (serialized
execution).

### 4.2 `message_decoder.sv`

| Port | Direction | Width | Description |
|---|---|---|---|
| `s_payload` / `s_payload_valid` / `s_payload_ready` | in | 256 / 1 / 1 | raw payload |
| `m_msg` | out | `msg_t` | decoded fields (wire order) |
| `m_msg_valid` / `m_msg_ready` | out / in | 1 | decoded message out |
| `m_bad_version` | out | 1 | pulse when `version != 0x01` (payload dropped) |

Rejects wrong `version`; passes `msg_type` / `side` **as-is** (numeric encoding,
no translation). Latency: 1 cycle (2 with registered ready).

### 4.3 `fifo_queue.sv` — parameterized synchronous FIFO

Parameters: `DATA_W`, `DEPTH` (power of two). Used for: command staging, trade
output, report output, ack output.

| Port | Direction | Width | Description |
|---|---|---|---|
| `s_data` / `s_valid` / `s_ready` | in | `DATA_W` / 1 / 1 | push |
| `m_data` / `m_valid` / `m_ready` | out / in | `DATA_W` / 1 / 1 | pop |
| `count`, `full`, `empty` | out | – | status (UVM can assert no overflow) |

### 4.4 `matcher.sv`

| Port | Direction | Width | Description |
|---|---|---|---|
| `s_cmd` / `s_cmd_valid` / `s_cmd_ready` | in | `cmd_t` / 1 / 1 | command to execute |
| `m_trade` / `m_trade_valid` / `m_trade_ready` | out / in | `trade_t` / 1 / 1 | matched trades (1/cycle) |
| `enq_cmd` / `enq_valid` / `enq_ready` | out / in | `cmd_t` / 1 / 1 | remainder to enqueue (→ order_manager) |
| pool port A (read/write order memory) | out/in | `order_rec_t` + addr | BRAM A port |
| level port (both sides) | out/in | `level_rec_t` + addr | level table update/read |
| `req_refresh` / `refresh_idx` | out | 1 / 12 | best-price recompute request |

Pipeline: S1 DECODE → S2 LEVEL_READ → S3 CROSS_CHECK → S4 HEAD_READ →
S5 TRADE_UPDATE → (RECIRC). First trade 5 cycles; steady state 1 trade/cycle.
Trade price = **passive head's price**. Fully filled → dequeue; remainder →
recirculate; no longer crossing → `enq_cmd` to `order_manager`.

### 4.5 `order_manager.sv`

| Port | Direction | Width | Description |
|---|---|---|---|
| `s_cmd` / `s_cmd_valid` / `s_cmd_ready` | in | `cmd_t` / 1 / 1 | ADD-enqueue / CANCEL / MODIFY / EXECUTE |
| `enq_cmd` / `enq_valid` / `enq_ready` | in | `cmd_t` / 1 / 1 | remainder from matcher (ADD rest) |
| `hash_req` / `hash_valid` / `hash_slot_in` / `hash_hit` / `hash_slot_out` | in/out | – | order_id_table interface |
| pool port B (read/write) | out/in | `order_rec_t` + addr | BRAM B port |
| level update interface | out/in | `level_rec_t` + addr | qty / head / tail updates |
| `m_ack` / `m_ack_valid` / `m_ack_ready` | out / in | `ack_t` / 1 / 1 | completion ack |

Operation cycle budgets: ADD-enqueue ≈ 3; CANCEL ≈ 6–8; MODIFY-qty ≈ 5;
MODIFY-price ≈ 8–12; EXTERNAL EXECUTE ≈ 5–7. **Matching (matcher) and
management (manager) never run concurrently** — serialized command model.

### 4.6 `order_memory.sv`

True dual port (A = matcher, B = manager). Parameters: `MAX_ORDERS = 8192`,
`ADDR_W = 13`; slot 0 is reserved, so 8191 orders are usable.

| Port | Direction | Width | Description |
|---|---|---|---|
| portA `addr` / `we` / `re` / `wdata` / `rdata` | in / out | `ADDR_W` / `order_rec_t` | matcher access |
| portB `addr` / `we` / `re` / `wdata` / `rdata` | in / out | same | manager access |
| `free_pop` / `free_slot` / `free_push` / `free_push_slot` | in / out | 1 / `ADDR_W` | free-list stack |
| `count` | out | `ADDR_W` | live order count |

### 4.7 `price_level.sv` — one per side

| Port | Direction | Width | Description |
|---|---|---|---|
| `addr` | in | 12 | level index |
| `we` / `wdata` / `re` / `rdata` | in / in / in / out | `level_rec_t` | synchronous BRAM access |
| `update_cmd` (head/tail/qty delta) | in | – | atomic enqueue/dequeue/splice update |

Level table is a BRAM indexed by level index — O(1) head/tail/qty.

### 4.8 `order_id_table.sv` — BRAM hash, four-way set associative

| Port | Direction | Width | Description |
|---|---|---|---|
| `lookup_id` / `lookup_valid` | in | 64 / 1 | search (CANCEL/MODIFY/EXECUTE) |
| `insert_slot` / `insert_valid` | in | 13 / 1 | bind `order_id` on ADD |
| `delete_valid` / `delete_id` | in | 1 / 64 | unbind on removal |
| `hit_slot` / `hit` / `miss` | out | 13 / 1 / 1 | result |

The table has 16384 logical buckets arranged as 4096 rows × four parallel ways.
At most eight rows (32 buckets) are examined. It remains off the matching
critical path.

### 4.9 `trade_generator.sv`

| Port | Direction | Width | Description |
|---|---|---|---|
| `s_trade` / `s_trade_valid` / `s_trade_ready` | in | `trade_t` / 1 / 1 | trades from matcher / manager |
| `m_trade` / `m_trade_valid` / `m_trade_ready` | out / in | `trade_t` / 1 / 1 | trade to scoreboard |
| `m_report` / `m_report_valid` / `m_report_ready` | out / in | 256 / 1 / 1 | 32-byte EXECUTE reports |
| `m_ack` / `m_ack_valid` / `m_ack_ready` | out / in | `ack_t` / 1 / 1 | command ack |

For each matched trade emits **two** 32-byte EXECUTE reports (buyer, then seller,
`flags=0`) with the trade's `price`/`quantity`/`timestamp_ns`; external fills
emit one report (`flags=FLAG_EXTERNAL`). Report `seq_num` increments
continuously. Outputs are FIFO-buffered so backpressure cannot stall matching.

---

## 5. Latency budget (frozen)

| Operation | Cycles | Notes |
|---|---|---|
| Decode (payload → msg) | 1 | 8 ns @ 125 MHz |
| Crossing ADD, first trade | **5** from command in | 40 ns @ 125 MHz |
| Each additional fill (same order) | +1 | 1 trade/cycle steady state (+8 ns) |
| Non-crossing ADD commit | 5 | 40 ns @ 125 MHz |
| CANCEL | 6–8 (≤10) | hash probes dominate |
| MODIFY quantity-only | 5 | keeps time priority |
| MODIFY price change | 8–12 | splice + re-add + re-match |
| EXECUTE external | 5–7 | |
| Best bid/ask read | 0 | registers |

Serialized command model ⇒ fixed, order-independent cycle budgets ⇒ the UVM
scoreboard can score every command deterministically.
