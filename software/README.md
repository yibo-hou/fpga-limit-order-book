# LOB Python Reference Model

A clean, modular **Python reference model for an FPGA-based low-latency
limit order book (LOB) accelerator**. It serves two roles:

1. **Market data simulator** — generates a random but internally consistent
   order flow and emits it as fixed-size UDP messages.
2. **Golden reference model** — a price–time priority matching engine plus a
   consumer that replays the feed and validates every execution report,
   suitable as the reference model for FPGA / UVM verification.

```
┌────────────────────┐        UDP / stimulus file        ┌──────────────────────┐
│   Market data      │ ── 32-byte datagrams ───────────► │  Golden reference     │
│   simulator        │   (or .bin stimulus for UVM)      │  consumer + OrderBook │
│  lob/simulator.py  │                                   │    lob/consumer.py    │
└─────────┬──────────┘                                   └──────────┬───────────┘
          │ owns a mirror OrderBook                                  │ same algorithm
          │ to know live orders +                                   ▼
          │ emit execution reports                          reproduces exchange
                                                             book state exactly
```

## Layout

```
software/
├── lob/
│   ├── __init__.py      public API
│   ├── protocol.py      32-byte UDP wire format: encode_message / decode_message
│   ├── orderbook.py     golden reference matching engine (Order, Trade, OrderBook)
│   ├── simulator.py     market data generator + UDP sender (exchange side)
│   └── consumer.py      golden reference consumer + UDP receiver (subscriber side)
├── tests/
│   ├── test_protocol.py wire format unit tests
│   ├── test_orderbook.py matching engine unit tests (incl. spec examples)
│   ├── test_stress.py   10000-message random stress test
│   └── test_udp.py      end-to-end simulator → UDP loopback → reference
├── demo.py              end-to-end demo: generate, replay, validate
├── Makefile             test / lint / clean targets
└── README.md
```

## Wire format (v1, fixed 32 bytes, network byte order)

| Offset | Size | Field        | Type     | Notes                                   |
| -----: | ---: | ------------ | -------- | --------------------------------------- |
| 0      | 1    | `version`    | uint8    | protocol version (`0x01`)               |
| 1      | 1    | `msg_type`   | uint8    | `0x01`..`0x04`, see below              |
| 2      | 1    | `side`       | uint8    | `0x00` = BUY, `0x01` = SELL            |
| 3      | 1    | `flags`      | uint8    | bit0 `FLAG_EXTERNAL`                    |
| 4–7    | 4    | `seq_num`    | uint32   | monotonic sequence (UDP loss detection) |
| 8–15   | 8    | `order_id`   | uint64   | client order id                         |
| 16–19  | 4    | `price`      | uint32   | fixed point, `10025` = `$100.25`        |
| 20–23  | 4    | `quantity`   | uint32   | shares / lots                           |
| 24–31  | 8    | `timestamp_ns` | uint64 | nanoseconds (time priority)           |

* All integers are big-endian fixed-width — the RTL can index the payload by
  byte offset directly (`OFF_*` constants in `lob/protocol.py`).
* `encode_message()` always produces **exactly 32 bytes** and raises
  `ValueError` on overflow / invalid fields; `decode_message()` validates
  length, version, `msg_type` and `side`.

### Message types

| Value | Meaning      | Behaviour                                        |
| ----: | ------------ | ------------------------------------------------ |
| `0x01` | ADD_ORDER   | insert into the book, then match crossing orders |
| `0x02` | CANCEL_ORDER | remove a live order by `order_id`               |
| `0x03` | MODIFY_ORDER | change quantity (and optionally price)          |
| `0x04` | EXECUTE_ORDER | trade execution event                         |

> **Frozen.** This exact byte layout and these numeric encodings are shared
> verbatim by the Python reference model, the UVM environment, the RTL UDP
> parser, and the testbench stimulus generator. The authoritative spec is
> `docs/01_protocol_spec.md`.

Two kinds of EXECUTE_ORDER messages exist, distinguished by `flags`:

* `flags = 0` — a **matched fill execution report** emitted by the matching
  engine right after the order event that caused it (two reports per fill:
  buyer's and seller's). The consumer *validates* these against its own
  derived fills rather than applying them.
* `FLAG_EXTERNAL` set — an **external execution** (e.g. an off-book fill).
  The consumer applies it to the book as a fill with unknown counterparty
  (`0` in the Trade).

## Matching engine

```
BUY book: price levels high → low        SELL book: price levels low → high
each level: FIFO order queue (time priority)
```

* **Price priority** — higher bid / lower ask first.
* **Time priority** — at the same price, earlier `timestamp_ns` first.
* **Resting (passive) order always trades at its own limit price** — the
  aggressive order receives price improvement. (Only reachable directly
  through the defensive `match_orders()`; a well-formed feed never sees it.)
* On `ADD_ORDER`, insert then drain the cross; the remainder of the incoming
  order rests at its limit price, behind orders already at that price.
* `MODIFY_ORDER`: quantity-only change keeps queue position; a price change is
  cancel + re-add (time priority resets) and re-matches.
* Orders are never left with zero or negative quantity; fully filled orders
  leave the book.

The spec example is covered in `tests/test_orderbook.py`
(`TestTimePriority::test_spec_time_priority_example`):

```
BUY id=1 px=100 qty=50 ts=1     BUY id=2 px=100 qty=30 ts=2
incoming SELL px=100 qty=60
→ Trade 1: buyer=1 qty=50;  Trade 2: buyer=2 qty=10;  remaining bid qty=20
```

## Core API

```python
from lob import Order, OrderBook, Side

book = OrderBook()
book.add_order(Order(1, Side.BUY, 10025, 50, ts=1))
trades = book.add_order(Order(2, Side.SELL, 10025, 20, ts=2))
book.cancel_order(order_id=1)
trades = book.modify_order(order_id=2, new_quantity=10, new_price=10050)
best_bid, best_ask = book.get_best_bid(), book.get_best_ask()
book.check_invariants()          # UVM-scoreboard style structural self-check
book.snapshot()                  # deterministic dump for reference vs DUT compare
```

## Running

From the repository root, create an isolated environment and install the
pinned development dependency:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e './software[dev]'
```

Then run commands from this directory:

```bash
make test          # full test suite (57 tests)
make stress        # 10000-message random stress test only
make demo          # run demo.py

# Fixed two-order live demo against the FPGA board
make video-demo    # FPGA 192.168.1.10:5001, host UDP port 5000
make video-interactive  # type ADD/CANCEL/MODIFY/EXECUTE at a lob> prompt

# Two-terminal live UDP demo (exchange simulator ↔ golden reference):
make run-sim       # terminal 1: python -m lob.simulator --port 9000
make run-ref       # terminal 2: python -m lob.consumer  --port 9000

# Generate a deterministic binary stimulus file for UVM:
make stimulus      # writes build/stimulus.bin (32 bytes per message)
```

`video_demo.py` sends a resting `SELL 100 x 50` followed by a crossing
`BUY 105 x 80`. It formats the board's ACK and the two matched EXECUTE
reports as a human-readable trade, showing the remaining buy quantity of 30.
The command requires the board bitstream, Ethernet link, and host IP settings
from `hardware/board/README.md`.

Interactive example:

```text
lob> ADD SELL 1234 100 50
lob> ADD BUY 5678 105 80
lob> CANCEL 5678
```

## Verification story

* **Determinism** — `OrderFlowGenerator` is seeded, so the same seed yields
  the same encoded stream. A test verifies this. That makes the generator a
  repeatable **stimulus source** and the consumer a repeatable **expected
  source** for UVM.
* **Cross-check** — the stress and UDP tests replay the stream through a fresh
  `OrderBook` and require it to reproduce the exchange's `snapshot()` exactly,
  while every matched-fill EXECUTE report is validated byte-for-byte.
* **Invariants** — `check_invariants()` verifies: order index agrees with the
  price levels, no duplicated or zero/negative-quantity orders, no empty
  levels, no crossed book.
* **Stress test** — 10000 random messages; verifies no negative quantity, no
  duplicated `order_id`, book consistency.

## FPGA mapping notes

| Python reference                        | FPGA DUT                                             |
| --------------------------------------- | ---------------------------------------------------- |
| `dict: price → PriceLevel`              | price-indexed RAM of FIFOs / per-level FIFO           |
| `PriceLevel.orders` (deque, FIFO)       | per-price FIFO, head pointer + order_id search        |
| `bid_heap` / `ask_heap` (max/min price) | `best_bid` / `best_ask` registers with stale cleanup  |
| `OrderBook.match_orders()`              | pipelined comparators: bid ≥ ask, then trade at the passive head's price |
| `encode_message` / `decode_message`    | fixed-offset byte slice, no parsing needed            |
| `check_invariants()` / `snapshot()`     | scoreboard compare + structural assertions in UVM     |
