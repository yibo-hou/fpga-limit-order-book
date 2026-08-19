# 01 — Internal Market Message Protocol (FINAL, FROZEN)

**Owner:** software/hardware interface
**Status:** frozen at v1 — any change increments `version` (byte 0) and is
reviewed by both the RTL and the verification owners.
**Consumers (must be byte-identical):** Python reference (`lob/protocol.py`),
UVM environment, RTL UDP parser, testbench stimulus generator.

---

## 1. Byte layout (32 bytes, network byte order / big-endian)

| Offset | Size | Field | Type | Notes |
|---:|---:|---|---|---|
| 0 | 1 | `version` | uint8 | protocol version = `0x01` |
| 1 | 1 | `msg_type` | uint8 | `0x01` ADD · `0x02` CANCEL · `0x03` MODIFY · `0x04` EXECUTE |
| 2 | 1 | `side` | uint8 | `0x00` BUY · `0x01` SELL |
| 3 | 1 | `flags` | uint8 | bit0 `FLAG_EXTERNAL` (below); others reserved = 0 |
| 4–7 | 4 | `seq_num` | uint32 | monotonically increasing per sender |
| 8–15 | 8 | `order_id` | uint64 | client order id |
| 16–19 | 4 | `price` | uint32 | fixed point, e.g. `10025` = `$100.25` |
| 20–23 | 4 | `quantity` | uint32 | shares / lots, `> 0` for order messages |
| 24–31 | 8 | `timestamp_ns` | uint64 | nanoseconds (monotonic per stream) |

All multi-byte fields are **big-endian**: byte *k* carries bits 7–0 of the most
significant byte. The RTL indexes the payload by byte offset directly
(offsets are the same constants as `lob/protocol.py` `OFF_*`).

---

## 2. Message types

| `msg_type` | Name | Wire behaviour |
|---:|---|---|
| `0x01` | `ADD_ORDER` | insert into the book, then match crossing orders; remainder rests |
| `0x02` | `CANCEL_ORDER` | remove a live order by `order_id` |
| `0x03` | `MODIFY_ORDER` | change quantity and/or price of a live order |
| `0x04` | `EXECUTE_ORDER` | trade execution event (two roles, see §4) |

Any other value → message rejected with an error ack.

---

## 3. Side, flags, fixed-point price

- **Side** — `0x00` BUY, `0x01` SELL. Any other value → reject.
- **Flags** — bit 0 `FLAG_EXTERNAL = 0x01`. Bits 1–7 reserved, must be 0.
- **Price** — unsigned uint32 fixed point. The display scale is application
  defined (example: `10025` = `$100.25`, i.e. cents). The engine quantizes to a
  level index via `PRICE_BASE` / `TICK_SHIFT`; prices outside `[PRICE_BASE,
  PRICE_BASE + NUM_PRICE_LEVELS<<TICK_SHIFT)` → reject.

---

## 4. EXECUTE_ORDER — two roles selected by `flags`

| `flags` | Role | Consumer behaviour |
|---|---|---|
| `0x00` | **matched-fill execution report** | emitted by the matching engine for each fill (two reports per trade: buyer's + seller's). The reference **validates** these against its own derived fills; the RTL emits them on the trade/report output. Not applied to the book. |
| `0x01` (`FLAG_EXTERNAL`) | **external execution** | an off-book fill applied to a live order (counterparty unknown). Applied to the book; the resulting trade carries counterparty id `0`. |

`quantity` > remaining qty on an external execution → reject.

---

## 5. Ordering and loss detection

- `seq_num` increments by exactly 1 per message emitted by the sender (starts at 1).
- Consumers count `gap = observed_seq - expected_seq - 1`; any nonzero gap is
  reported (UDP loss / reorder). A gap means the stream must be replayed or the
  verification run marked invalid — the engine itself never reorders.

---

## 6. Validation rules (shared by encode and decode)

| Check | On encode | On decode |
|---|---|---|
| payload length == 32 | always (fixed packer) | reject otherwise |
| `version == 0x01` | reject | reject |
| `msg_type ∈ {1..4}` | reject | reject |
| `side ∈ {0,1}` | reject | reject |
| every field fits its width (≤ uint max) | `ValueError` | n/a (already 32 bytes) |
| `quantity ≥ 1` for ADD / MODIFY / external EXECUTE | enforce at OrderBook | enforce at OrderBook |

Encoded output is **exactly 32 bytes** — verified by unit tests.

---

## 7. Example

`ADD_ORDER`, BUY, qty 50 @ 100.25, order 7, seq 1, ts 1234 ns:

```
byte:  0    1    2    3    4    5    6    7    8    ...   15   16   17   18   19   20   21   22   23   24   ...   31
hex:   01   01   00   00   00   00   00   01   00    ...   00   00   00   27   00   00   00   32   00   00   00   04
       ver  ADD  BUY  flg        seq=1          order_id=7            price=10025        quantity=50      ts=1234
```

`encode_message()` / `Message.encode()` produce exactly this; `decode_message()` /
`Message.decode()` consume it.
