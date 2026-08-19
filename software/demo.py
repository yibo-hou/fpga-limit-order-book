"""End-to-end demo: generate, replay, validate.

1. Generate a deterministic order-flow stream (exchange side, mirror book).
2. Replay it through a fresh reference OrderBook (subscriber side).
3. Validate that the reference reproduces the exchange state exactly and
   that every execution report checks out.
"""

from lob import OrderBook
from lob.consumer import GoldenReference
from lob.protocol import (
    MSG_ADD, MSG_EXECUTE, FLAG_EXTERNAL, decode_message, hexdump
)
from lob.simulator import OrderFlowGenerator


def print_book(book):
    print(f"  best bid = {book.get_best_bid():>6}    "
          f"best ask = {book.get_best_ask():>6}    "
          f"live orders = {len(book)}")


def main():
    seed = 0xC0FFEE
    count = 2000
    print(f"=== LOB reference model demo (seed={seed:#x}, {count} batches) ===")

    generator = OrderFlowGenerator(seed=seed)
    reference = GoldenReference()

    # 1. generate the stream and replay it through the reference consumer
    payloads = []
    for _ in range(count):
        for msg in generator.next_batch():
            payloads.append(msg)

    for payload in payloads:
        reference.process_message(payload)

    # 2. validate
    generator.book.check_invariants()
    reference.book.check_invariants()
    assert reference.snapshot() == generator.book.snapshot(), \
        "reference book diverged from the exchange!"
    assert reference.matched_fills == 2 * generator.stats["trades"], \
        "not every matched fill report was validated!"

    print("\n--- stream statistics (exchange side) ---")
    for key, value in generator.stats.items():
        print(f"  {key:<10} {value:>7}")
    print(f"\n  validated matched-fill reports : {reference.matched_fills}")
    print(f"  applied external executions     : {reference.external_fills}")
    print(f"  UDP sequence gaps observed      : {reference.gaps}")
    print("\n--- final reference book ---")
    print_book(reference.book)

    # 3. show one decoded message + its 32-byte wire image
    from lob.protocol import encode_message
    print("\n--- sample wire message ---")
    sample = payloads[len(payloads) // 2]
    print(f"decoded: {sample}")
    print("hexdump of the 32-byte payload:")
    print(hexdump(encode_message(sample)))

    print("\nOK: reference model validated the stream end-to-end.")


if __name__ == "__main__":
    main()
