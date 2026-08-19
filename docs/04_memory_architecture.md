# 04 — Memory Architecture (implemented)

All persistent book state is addressed by fixed-width indices; there are no
software pointers in RTL. Current XA100T parameters are:

- `MAX_ORDERS = 8192`, with slot 0 reserved: **8191 live orders**
- `ADDR_W = 13`
- `NUM_PRICE_LEVELS = 4096` per side
- `HASH_BUCKETS = 16384`, `HASH_WAYS = 4`, `MAX_HASH_PROBE = 8`

## 1. Order pool

`order_memory.sv` stores one `order_rec_t` per slot. The record is 204 bits:

| Field | Width |
|---|---:|
| valid / side | 1 / 1 |
| price / quantity | 16 / 32 |
| timestamp / order ID | 64 / 64 |
| next / previous slot | 13 / 13 |

The inferred 8192 × 204 true dual-port memory uses 51 RAMB36.
Port A belongs to the matcher and port B to the manager. Synchronous reads are
registered; the serialized command model prevents conflicting operations.

## 2. Price-level tables

BUY and SELL each have 4096 entries. A 42-bit entry contains 13-bit head and
tail pointers plus 16-bit aggregate quantity. The level index is derived from
the configured price grid. Occupancy bits feed the best-price priority encoder,
so best bid/ask does not scan all levels.

The two tables together use 10 RAMB36 in the implemented design.

## 3. Order-ID table

`order_id_table.sv` is a BRAM-backed **four-way set-associative hash table**:

| Item | Value |
|---|---:|
| Logical buckets | 16384 |
| Sets | 4096 |
| Ways per set | 4 |
| Consecutive sets examined | 8 |
| Maximum candidate buckets per request | 32 |
| Bucket | valid + 64-bit order ID + 13-bit slot = 78 bits |
| Stored row | four buckets = 312 bits |

Each request hashes the full 64-bit order ID to a base set. It checks four ways
in parallel, then advances to the next set if necessary. Lookup and delete stop
on an exact full-ID match. Insert scans the complete eight-set window to reject
duplicates and records the first empty way. Because lookup does not terminate
at an empty bucket, deletion can clear the valid bit without tombstones.

An ADD is transactional: reserve a free slot, attempt the hash insert, and only
after hash success write the order pool and price level. On hash-window failure,
the slot is returned to the free list and the command returns
`ACK_REJECT_INTERNAL`; no partial order remains. CANCEL and completed removals
delete the hash entry before returning the slot.

Synthesis maps the hash to 35 RAMB36. The table is 50% loaded at the maximum
8191 live orders; an adversarial collision can still exhaust one
eight-set/32-bucket window, which is intentionally reported rather than hidden.

## 4. Free list

Slot 0 is the null pointer. Slots 1–8191 form a LIFO free stack. The current
reset-initialized 8192 × 13 implementation maps to 4608 LUTRAM LUTs rather than BRAM.
Allocation pops a slot; cancel/full execution or failed hash insertion pushes
it back.

## 5. Measured XA100T implementation

Vivado 2025.2, `XC7A100T-2FGG484`, complete UDP/Ethernet board image:

| Resource | Used | Available | Utilization |
|---|---:|---:|---:|
| LUT | 12,464 | 63,400 | 19.7% |
| FF | 7,042 | 126,800 | 5.6% |
| RAMB36 | 96 | 135 | 71.1% |
| RAMB18 | 0 | 270 | 0% |

BRAM consumption is `96 × 2 = 192` 18-Kb blocks, or 71.1% of the device's
270 18-Kb physical blocks (the datasheet's 135 figure is RAMB36 equivalents).
At 125 MHz, post-route physical optimization reports WNS `+0.040 ns`, WHS
`+0.036 ns`, and zero failing endpoints.

## 6. Verified boundaries

- Random 1000-batch RTL/reference comparison passes.
- Capacity scenario accepts exactly 8191 live orders and rejects order 8192
  with `ACK_REJECT_FULL` while preserving the count.
- Collision scenario accepts 32 IDs mapped to one probe window, rejects the
  33rd with `ACK_REJECT_INTERNAL`, and proves the reserved slot was rolled back.

The same scenarios pass in RTL and on the XA100T board. No extra hash pipeline
was required, although the +0.040 ns WNS remains thin. Moving the reset-filled
free list to sequentially initialized BRAM is the clearest future resource and
timing optimization.
