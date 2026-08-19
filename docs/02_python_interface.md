# 02 — Python Interface Design

Reference implementation: `software/`

```
External Feed ──► Message Adapter ──► Message Object ──► OrderBook
   (UDP socket /    (UDPServer +          (lob.protocol)  (lob.orderbook)
    stimulus file)   GoldenReference)
```

**Rule: the LOB engine never depends on UDP.** The `OrderBook` is driven purely
by `Message` objects; the socket, the adapter, and the wire format are separate
layers so the golden model is bit-identical whether it is fed from UDP, a file,
or a live Python object.

---

## 1. `Message` — `lob/protocol.py`

`dataclass` with the exact wire fields, in wire order:

```python
@dataclass
class Message:
    version: int = VERSION          # 0x01
    msg_type: int = MSG_ADD         # 0x01..0x04
    side: int = SIDE_BUY            # 0x00 / 0x01
    flags: int = 0                  # bit0 FLAG_EXTERNAL
    seq_num: int = 0
    order_id: int = 0
    price: int = 0                  # fixed point, e.g. 10025
    quantity: int = 0
    timestamp_ns: int = 0

    def encode(self) -> bytes: ...          # exactly 32 bytes, big-endian
    @classmethod
    def decode(cls, payload) -> Message: ...  # validates length/version/type/side
```

Module-level forms (thin wrappers, kept for callers that already use them):
`encode_message(msg)` / `decode_message(payload)` / `build_message(...)`.

`MSG_SIZE = 32`, `VERSION = 0x01`, numeric constants `MSG_ADD/CANCEL/MODIFY/EXECUTE`,
`SIDE_BUY/SELL`, `FLAG_EXTERNAL`, and `OFF_*` byte offsets for RTL/UVM reference.

**Unit tests (`tests/test_protocol.py`):** size == 32 for all four types;
round-trip; exact byte layout vs `struct`; big-endian; `OFF_*` offsets; numeric
encodings; max-uint round-trip; wrong-length / bad-version / bad-type / bad-side
rejection; overflow rejection on encode; `bytearray` input; `Message.encode()`
and `Message.decode()` methods.

---

## 2. `OrderBook` — `lob/orderbook.py`

Supports ADD, CANCEL, MODIFY, MATCH (and external EXECUTE).

```python
book = OrderBook()

trades = book.add_order(order)              # ADD_ORDER  -> returns list[Trade]
book.cancel_order(order_id)                 # CANCEL_ORDER
trades = book.modify_order(order_id,
                           new_quantity, new_price, timestamp_ns=None)
trades = book.match_orders()                # defensive drain (normal flow auto-matches)
book.execute_order(order_id, qty, timestamp_ns=None)  # external fill

book.get_best_bid()      # highest live bid, or None
book.get_best_ask()      # lowest live ask,  or None
book.check_invariants()  # structural self-check (scoreboard helper)
book.snapshot()          # deterministic dump for reference vs DUT compare
```

Rules (identical to the RTL):

* **Price–time priority**: better price first; at the same price, earlier
  arrival (`timestamp_ns`) first — implemented as FIFO position.
* **ADD** inserts then matches; a crossing remainder rests at its limit behind
  existing orders.
* **CANCEL / MODIFY-price** splice the order out of its level FIFO in O(1)
  (doubly linked).
* **MODIFY quantity-only** keeps time priority; **MODIFY price** resets it and
  re-matches.
* **Trade prints at the passive head's price** (aggressive order gets price
  improvement).
* **External EXECUTE** reduces a live order; fully filled orders leave the book;
  counterparty id `0`.

Supporting types: `Order(order_id, side, price, quantity, timestamp_ns)`,
`Trade(buy_order_id, sell_order_id, price, quantity, timestamp_ns)` (counterparty
`0` for external fills), `Side` enum (`BUY=0x00`, `SELL=0x01`), `PriceLevel`
(FIFO queue).

---

## 3. Message Adapter — `lob/consumer.py`

```python
class GoldenReference:              # feeds Messages into a fresh OrderBook
    def process_message(self, msg) -> list[Trade]: ...
    def process_payload(self, payload) -> list[Trade]: ...  # decode + process
    def check_invariants(self): ...
    def snapshot(self): ...

class UDPServer:                    # socket -> payload -> process_payload
    def receive_once(self, timeout=None): ...
```

The adapter *validates* matched-fill EXECUTE reports (compares against its own
derived fills) and *applies* external executions — so one feed checks both the
book updates and the execution output. Sequence gaps are counted.

---

## 4. Simulator — `lob/simulator.py`

```python
class OrderFlowGenerator:           # deterministic for a given seed
    def next_batch(self) -> list[Message]: ...   # one event + its reports
    def run_payloads(self, count) -> list[bytes]: ...
    def write_stimulus(self, path, count): ...   # 32 bytes/message .bin

class UDPSender:
    def send_message(self, msg): ...             # encode + UDP send
```

The generator owns a **mirror OrderBook** so it knows live order ids and can
emit the exact EXECUTE reports the consumer will expect — same algorithm, so a
full replay reproduces the exchange state byte-for-byte (`snapshot()` equality
is asserted in tests).

---

## 5. Mapping to the four consumers

| Layer | Python | Shared contract |
|---|---|---|
| Wire bytes | `Message.encode()` / `decode()` | `01_protocol_spec.md` |
| Feed → book | `GoldenReference` | `OrderBook` API |
| RTL stimulus | `run_payloads()` / `write_stimulus()` | same 32-byte stream |
| Golden output | `Trade` list + `snapshot()` | compared against RTL `trade_out` |
