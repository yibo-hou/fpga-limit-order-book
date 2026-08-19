# Interface Specification — FPGA LOB Engine

**Status: FROZEN.** Protocol version 1 is implemented and shared verbatim by
all four consumers:

```
1. Python reference model        software/lob/protocol.py
2. UVM verification environment  hardware/verif/ (same 32-byte transaction)
3. FPGA RTL parser               hardware/rtl/message_decoder.sv
4. Testbench stimulus generator  software/lob/simulator.py
```

## Documents

| # | Document | Contents |
|---|---|---|
| 0 | `00_interface_index.md` | this index + frozen decision log |
| 1 | `01_protocol_spec.md` | final 32-byte wire protocol (authoritative) |
| 2 | `02_python_interface.md` | `Message` class, `OrderBook` API, adapter |
| 3 | `03_rtl_interface_spec.md` | valid/ready interfaces, module ports, cycle budgets |
| 4 | `04_memory_architecture.md` | BRAM order pool, price levels, hash, free list |
| 5 | `05_uvm_verification_interface.md` | transaction class, scoreboard, Python↔RTL mapping |
| 6 | `06_module_dependency.md` | module hierarchy and data-flow diagrams |
| 7 | `07_fast_path_optimization.md` | fast-path design and measured latency |
| 8 | `development.md` | reproducible setup, tests and vendor-tool configuration |

## Frozen decisions (change requires a protocol version bump)

1. **32-byte message, network byte order (big endian)** — layout in `01_protocol_spec.md`.
2. **Numeric encodings** — `msg_type` `0x01` ADD / `0x02` CANCEL / `0x03` MODIFY /
   `0x04` EXECUTE; `side` `0x00` BUY / `0x01` SELL. (Supersedes the earlier ASCII
   draft; `software` now emits numeric.)
3. **`timestamp_ns` is a full uint64** at bytes 24–31.
4. **`flags` bit 0 = `FLAG_EXTERNAL`**: EXECUTE_ORDER is either a matched-fill
   execution report (flags=0, validated, not applied) or an external fill
   (flags=1, applied to the book, counterparty id 0).
5. **Matching is price-time priority**; trade prints at the **passive head's price**.
6. **Engine executes one command at a time** (serialized), 5-stage recirculating
   match pipeline, first trade in 5 cycles.
7. **Matching path never touches the order_id hash** — hash is used only by
   CANCEL / MODIFY / EXECUTE.
8. **Price grid** (`PRICE_BASE` / `TICK_SHIFT` / `NUM_PRICE_LEVELS`) enables O(1)
   price-level lookup; best bid/ask come from registers refreshed by priority
   encoders, never a scan.
9. **All pointers are index-based** into an 8192-slot pool (13 b, slot 0 reserved,
   8191 usable), never host/software addresses.

## Dataflow (single view)

```
Python simulator ──32B UDP──► FPGA UDP parser ──payload[255:0]──► message_decoder.sv
                                                                        │ cmd_t
                                                                        ▼
   software ──stims──► UVM env ──same 32B──► lob_engine_top ──► matcher ──► trade_generator
    (golden model)                 │                                        │
        │                          │ trade_t                               ack/status
        ▼                          ▼
  expected trades ───── scoreboard ───── actual trades + reports + snapshot
```
