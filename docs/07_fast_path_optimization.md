# 07 — Fast-Path and Parallel-Read Optimization

This document records the latency optimization implemented for crossing `ADD`
commands. It also separates three latency concepts that must not be mixed:

- normal enqueue-then-match latency;
- matcher memory-read latency;
- measured core latency from command acceptance to the first trade.

The target board is the DaVinci Pro with an Artix-7
`XC7A100T-2FGG484`, running the order-book core at 125 MHz. One core cycle is
8 ns.

## 1. Motivation

Before this optimization, every `ADD` used the same path, including an order
that immediately crossed the opposite best price:

```text
C_VALIDATE
    -> allocate a free order slot
    -> insert order_id into the hash table
    -> write the order pool BRAM
    -> read/update the price-level BRAM
    -> wait for enqueue completion
    -> C_DRAIN
    -> read both sides of the book
    -> emit a trade
```

This is required for a resting order, but it is unnecessary work for the
aggressive part of a crossing order. The newly written record may be consumed
immediately, so the old path paid both the persistent-memory write latency and
the subsequent matcher read latency.

The old full path is longer and partly data-dependent because hash probing,
empty/non-empty price levels, linked-list updates, and the number of generated
trades affect completion time. It must not be described simply as an
11-cycle-to-9-cycle change. The two-cycle saving discussed in section 3 applies
only to the matcher read sequence.

## 2. Fast-Path bypass

`lob_engine_top.sv` now has a `FAST_PATH_ENABLE` parameter, enabled by default.
During `C_VALIDATE`, an `ADD` enters `C_FAST` when all of the following hold:

- the command is valid;
- the opposite side has a valid best price;
- a BUY price is greater than or equal to the best ask, or a SELL price is
  less than or equal to the best bid;
- the best-price state is not being refreshed;
- at least one free slot exists, so an unfilled remainder can still be
  admitted with the original full-book semantics.

The aggressive order remains in matcher registers and is never inserted into
the order pool before its first trade. The fast sequence is:

```text
C_VALIDATE -> C_FAST
                 |
                 +-> F_CHECK -> F_LEVEL -> F_HEAD -> F_TRADE
                                                    -> F_UPDATE
```

Only the passive resting order is read from persistent memory. A completed
passive order is removed from its price level and order-ID hash table in the
normal transactional order.

If the aggressive order is fully filled, it never occupies an order slot and
the controller proceeds to acknowledgement. If a quantity remains after the
last possible match, only that remainder is sent to `C_ENQ`. It preserves the
original order ID, price, side, and arrival timestamp.

This distinction is important:

- **first-trade latency** avoids the enqueue writes;
- **command completion latency** can still include `C_ENQ` when a remainder
  must become a resting order;
- multiple passive fills still require repeated update and hash-delete work.

## 3. Bid/ask reads reduced from four beats to two

The normal book-crossing matcher previously serialized four synchronous reads:

```text
M_BID_LVL -> M_ASK_LVL -> M_BID_ORD -> M_ASK_ORD
```

The two price-level tables are independent memories, and the order pool is a
true dual-port memory. The matcher now uses both resources concurrently:

```text
M_LEVELS -> M_ORDERS -> M_TRADE
```

| Beat | Concurrent operations |
|---:|---|
| `M_LEVELS` | Read best-bid and best-ask level rows from the two level BRAMs |
| `M_ORDERS` | Consume both level rows and read the bid and ask head orders through pool ports A and B |
| `M_TRADE` | Consume both head records, select price and quantity, and assert the trade output |

This removes two cycles from the matcher read portion. It does not by itself
account for all of the Fast-Path improvement: bypassing allocation, hash
insertion, order-pool writes, level writes, and enqueue completion is the larger
end-to-end saving for a crossing `ADD`.

While the matcher owns both pool ports, the top-level arbiter prevents the
order manager from using port B. Commands are serialized, so matcher/manager
write conflicts are not permitted.

## 4. Current latency result

The debug counter measured approximately **9 core cycles**, or **72 ns at
125 MHz**, from accepted command payload to the first Fast-Path trade.

This is a core measurement. It does not include Ethernet wire serialization,
PHY delay, UDP framing, host networking, or the time required to transmit both
execution reports and the final acknowledgement.

The measurement was made with the diagnostic image before the final
order-ID-table timing pipeline was added. That later pipeline affects hash
operations after a passive order is removed; it is not on the path to the first
Fast-Path trade. Therefore 9 cycles remains the expected first-trade value, but
it should be re-captured if a release-grade latency certificate is required.

The original 5-cycle/40-ns end-to-end goal has **not** yet been reached.

## 5. Timing closure optimization

The order-ID table originally combined a wide BRAM row read, four-way compare,
replacement selection, and a 312-bit row update in one critical path.
`order_id_table.sv` now separates selection and row construction with `S_PREP`:

```text
S_READ -> S_EVAL -> S_PREP -> S_WRITE
```

Registers hold the selected way, bucket, and base row before the wide row is
rewritten. After post-route physical optimization, the final board image has:

| Check | Result |
|---|---:|
| WNS | `+0.001 ns` |
| TNS | `0 ns` |
| WHS | `+0.035 ns` |
| DRC errors | `0` |

The design meets constraints, but the setup margin is only 1 ps and is not a
comfortable production margin.

## 6. Verification evidence

Software and RTL/reference checks completed with the following results:

| Test | Result |
|---|---|
| Python test suite | 56 passed, 1 skipped |
| Golden random, seed `0x1234`, 1000 commands | PASS; 198 trades, 263 reports, 1000 ACKs |
| Directed Fast-Path | PASS; 7 commands, 6 trades, 12 reports, 7 ACKs |
| Directed parallel-read | PASS; 3 commands, 1 trade, 2 reports, 3 ACKs |
| Hash-collision boundary | PASS; 33 commands/ACKs |

The final release bitstream was programmed to the board. Directed Fast-Path and
parallel-read scenarios both passed. A paced board random run also passed all
1000 commands and 263 reports with a 20-ms command interval, approximately
48.1 commands/s.

Unpaced/high-rate board traffic is not yet fully stable: intermittent commands
can reach the core without a returned ACK or report. ILA evidence showed equal
RX and core-command counts, no TX error, and an ACK count one behind at the
failure point. This places the remaining issue after packet reception, but does
not yet prove whether its root cause is zero-margin timing, command/control
handshake, or another core-side condition.

Consequently, the current status is:

- functionally verified in simulation and directed hardware tests;
- stable for paced board operation;
- timing-clean but with almost no setup margin;
- not yet qualified for sustained maximum-rate operation;
- approximately 9 cycles to the first Fast-Path trade, not 5 cycles.

## 7. Path toward five cycles

Reaching five cycles requires more than further FSM state renaming. The two
synchronous passive-memory reads, command admission, and trade output currently
consume most of the budget. Likely architectural steps are:

1. keep the best passive level and its head order in a register-resident cache;
2. combine command validation and Fast-Path dispatch without adding a separate
   registered boundary;
3. compute the first trade directly from the cached head while BRAM supplies
   later queue entries;
4. move passive cleanup and hash deletion behind the first-trade output while
   preserving ordering and backpressure rules;
5. add sequence-aware watchdog/diagnostic state before increasing input rate;
6. restore meaningful positive timing margin before treating 125 MHz as a
   stable delivery point.

Any cached-head design must define atomic updates for cancel, modify, execute,
partial fill, price-level deletion, and best-price refresh. Those correctness
rules are the main complexity cost of a true 5-cycle implementation.
