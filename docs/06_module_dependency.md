# 06 — Module Dependency Diagram

## 1. Instantiation tree

```
lob_engine_top.sv
├── message_decoder.sv          (raw 32-byte payload → msg_t)
├── fifo_queue.sv  (cmd_fifo)   (stages decoded commands, serialized)
├── matcher.sv                  (S1–S5 + RECIRC match pipeline)
│   ├── order_memory.sv         (port A: match reads/writes)   ─┐ shared
│   └── price_level.sv × 2      (level read + update)          │ instance
├── order_manager.sv            (enqueue / CANCEL / MODIFY / EXECUTE)
│   ├── order_memory.sv         (port B: manager access)      ─┘
│   ├── price_level.sv × 2      (head/tail/qty updates)
│   ├── order_id_table.sv       (BRAM hash, off match path)
│   └── best_price_encoder.sv   (refresh best bid/ask on level-empty)
├── trade_generator.sv
│   ├── fifo_queue.sv  (trade_fifo)     → m_trade (scoreboard)
│   ├── fifo_queue.sv  (report_fifo)    → m_report (32-byte EXECUTE)
│   └── fifo_queue.sv  (ack_fifo)       → m_ack
└── fifo_queue.sv   (payload_fifo, optional input staging)
```

`order_memory`, `price_level`, `best_price_encoder`, `order_id_table`,
`fifo_queue` are leaf modules (no sub-instances).

## 2. Control/data-flow diagram

```
 UDP parser
    │ payload[255:0], valid/ready
    ▼
 message_decoder ── msg_t ──► cmd_fifo ──► matcher ──► trade_generator ──► trade / report / ack
    │                                          │  ▲
    │                                          │  │ enq_cmd (remainder rests)
    ▼                                          ▼  │
 (bad version → error ack)              order_manager ── hash lookup ──► order_id_table
                                                 │
                                                 ├─► order_memory (port B)     ◄── port A (matcher)
                                                 ├─► price_level × 2
                                                 └─► best_price_encoder ──► best_bid/ask registers
                                                      (read every cycle by matcher S2)
```

Key arcs:

* **payload → msg_t → cmd_t**: decoder + command FIFO; one command released at a
  time (serialized execution).
* **matcher ↔ order_memory**: true dual port — matcher uses port A for head reads
  and partial-fill writes; manager uses port B for enqueue/splice/free.
* **matcher ↔ price_level**: S2 reads own level + opposite best level; S5 updates
  qty / head; level-empty events fire `req_refresh` to `best_price_encoder`.
* **order_manager ↔ order_id_table**: CANCEL / MODIFY / EXECUTE only; the matcher
  never hashes (guaranteed by construction).
* **matcher → order_manager**: when a remainder stops crossing, `enq_cmd`
  requests enqueue at its level tail (time priority preserved).
* **trade_generator**: fans one trade to the scoreboard (`m_trade`) and emits
  two 32-byte EXECUTE reports (`m_report`) with its own `seq_num` counter;
  external fills emit one report with `FLAG_EXTERNAL`.

## 3. Single-command critical path (crossing ADD)

```
cycle  cmd_fifo  matcher                      order_memory    price_level    best_price
 0     pop       S1 DECODE (level_idx)        –               –              –
 1     –         S2 LEVEL_READ                –               R(own) R(best) –
 2     –         S3 CROSS_CHECK               alloc slot      –              –
 3     –         S4 HEAD_READ                 R(head)         –              –
 4     –         S5 TRADE_UPDATE              W(head rem)     W(qty)         –
 5     –         RECIRC → S4 (next head)      R(head2)        –              –
 6     –         S5 TRADE_UPDATE              W(head2 rem)    W(qty)         refresh if empty
 7     –         ENQUEUE remainder            W(rest)         W(head/tail)   –
```

First trade out at cycle 4 (5 cycles from input), one extra cycle per additional
fill. Every arc is a fixed cycle budget → UVM-scoreboardable.
