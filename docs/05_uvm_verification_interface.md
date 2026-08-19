# 05 — UVM Verification Interface

The UVM environment consumes **exactly the same 32-byte messages** as the Python
reference and the RTL parser. The scoreboard replays one stimulus stream through
the Python golden model and the RTL DUT, then compares trades, execution
reports, acks, and the final book snapshot.

---

## 1. UVM transaction — mirrors `Message`

```systemverilog
class lob_msg_txn extends uvm_sequence_item;
    `uvm_object_utils_begin(lob_msg_txn)
        `uvm_field_int(version,      UVM_ALL_ON)
        `uvm_field_enum(msg_type_t,  msg_type,  UVM_ALL_ON)
        `uvm_field_enum(side_t,      side,      UVM_ALL_ON)
        `uvm_field_int(flags,        UVM_ALL_ON)
        `uvm_field_int(seq_num,      UVM_ALL_ON)
        `uvm_field_int(order_id,     UVM_ALL_ON)
        `uvm_field_int(price,        UVM_ALL_ON)
        `uvm_field_int(quantity,     UVM_ALL_ON)
        `uvm_field_int(timestamp_ns, UVM_ALL_ON)
    `uvm_object_utils_end

    rand bit [7:0]  version;
    rand msg_type_t msg_type;
    rand side_t     side;
    rand bit [7:0]  flags;
    rand bit [31:0] seq_num;
    rand bit [63:0] order_id;
    rand bit [31:0] price;
    rand bit [31:0] quantity;
    rand bit [63:0] timestamp_ns;

    constraint c_valid {
        version == lob_pkg::VERSION;               // 0x01
        msg_type inside {ADD, CANCEL, MODIFY, EXECUTE};
        side     inside {BUY, SELL};
        seq_num >= 1;
        quantity > 0;                              // order messages
    }
    constraint c_order_id_unique { unique {order_id}; }
    constraint c_price_range { price inside {[P_BASE : P_BASE + P_LEVELS-1]}; }

    function bit [255:0] pack_payload();
        // byte 0 = version (MSB), byte 1 = msg_type, ... byte 31 = ts low byte
        // identical to Message.encode() layout
    endfunction
    function void unpack_payload(bit [255:0] p); ... endfunction
endclass
```

`pack_payload()` / `unpack_payload()` must match `Message.encode()` /
`Message.decode()` **byte-for-byte** — a golden `lob_protocol_model` (DPI or a
checked reference file) cross-checks the two encoders in a lockstep test.

---

## 2. Environment (sketch)

```
                      ┌────────────────────────────────────────────────┐
stimulus (seeded .bin ─┤  lob_msg_agent                                  │
or UDP capture)        │  ├─ lob_msg_sequence (reads .bin / constrained  │
  sequence            ─┤  │    random, assigns seq_num)                  │
                      │  ├─ lob_msg_driver (pack_payload → AXI-stream    │
                      │  │    payload bus)                               │
                      │  └─ lob_msg_monitor (sniffs payload bus → txn)   │
                      └──────────────┬───────────────────────────────────┘
                                     │ payload[255:0] valid/ready
                                     ▼
                             ┌───────────────┐
                             │  lob_engine   │ DUT (lob_engine_top)
                             └───┬───────┬───┘
                                 │       │
                  trade_t + report/ack   │ status snapshot
                                 ▼       ▼
                      ┌────────────────────────┐
                      │  lob_scoreboard         │
                      │  ├─ trade predictor     │  (reads Python golden output,
                      │  │                      │   or replays stream in Python)
                      │  ├─ report checker      │  (2× 32-byte EXECUTE reports
                      │  │                      │   byte-compared)
                      │  └─ snapshot checker    │  (status vs Python snapshot())
                      └────────────────────────┘
```

The **Python golden model** runs as the expected source: for each stimulus, the
testbench feeds the same seeded stream to `GoldenReference` and compares:

| Output | Python source | RTL source | Compare |
|---|---|---|---|
| Trade stream | `GoldenReference.derived_trades` | `m_trade` (`trade_t`) | field-by-field |
| Execution reports | `Message` list (buyer/seller per trade) | `m_report` (32-byte) | byte-for-byte |
| Command ack / rejects | `OrderBook` exceptions / returns | `m_ack` (`ack_t`) | status + remaining qty |
| Final book state | `OrderBook.snapshot()` | `status_*` + `status_level_qty` | structural |

---

## 3. Python ↔ RTL mapping (frozen)

| Python feature (`software`) | RTL module |
|---|---|
| `OrderBook.add_order()` | `order_manager.sv` (enqueue) + `matcher.sv` (match) |
| `OrderBook.match_orders()` | `matcher.sv` (S3–S5 + RECIRC) |
| `OrderBook.cancel_order()` | `order_manager.sv` (hash + splice) |
| `OrderBook.modify_order()` (qty) | `order_manager.sv` (qty update, keep priority) |
| `OrderBook.modify_order()` (price) | `order_manager.sv` (splice + re-add) + `matcher.sv` |
| `OrderBook.execute_order()` (external) | `order_manager.sv` (EXECUTE path, counterparty 0) |
| `PriceLevel` FIFO (time priority) | `order_memory.sv` next/prev links + `price_level.sv` head/tail |
| `OrderBook.get_best_bid()/get_best_ask()` | `best_price_encoder.sv` + `best_bid/ask` registers |
| `OrderBook._orders` (order_id → order) | `order_id_table.sv` (BRAM hash) |
| `OrderBook.trade_log` | `m_trade` stream + `trade_generator.sv` reports |
| `OrderBook.snapshot()` | `status_*` port (UVM reads after each message) |
| `OrderBook.check_invariants()` | structural assertions in `lob_engine_top.sv` + peek/force interface |
| `Message.encode()` / `decode()` | `message_decoder.sv` (byte map) + pack/unpack in driver |

---

## 4. Scoreboard flow per message

1. **Drive:** sequence → driver packs the txn to 256 b and handshakes it into
   `lob_engine_top`; the same txn is pushed to the expected queue.
2. **Score expected:** the testbench calls the Python `GoldenReference`
   `process_message()` and records derived trades + expected reports + expected
   ack.
3. **Score actual:** monitor collects `m_trade`, `m_report`, `m_ack`; after the
   ack for message *k*, the scoreboard reads the DUT `status_*` port.
4. **Compare:** trades (buy/sell id, price, qty, ts), reports (32-byte), ack
   (status, remaining qty), and snapshot all must match. Trade price uses the
   **passive head's price** convention on both sides.
5. **Invariants:** end-of-test calls Python `check_invariants()` and pokes the
   RTL via the peek interface to assert the same structural checks (no empty
   level, no crossed book, pool/hash/free-list consistency).

The **peek/force interface** (`debug_read_slot(idx)`, `debug_read_level(idx)`,
`debug_force_level(...)`) lets directed tests inject crossed states and
pre-crossed books — mirroring the Python reference's internal access, so the
defensive `match_orders()` path (§5.3 in `architecture.md`) is covered.

---

## 5. Stimulus generation

* **Golden file:** `software` `make stimulus` writes a seeded `.bin`
  (32 bytes/message). The sequence reads it verbatim → byte-identical DUT input.
* **Constrained random:** the sequence can also generate transactions directly
  (using `lob_msg_txn` constraints) and the Python model consumes the same
  generated stream via DPI / a captured file, keeping expected == generated.
* **Replay:** on any UDP-gap or mismatch, the test is re-run from the same seed —
  determinism is guaranteed (`OrderFlowGenerator` is seeded and tested).
