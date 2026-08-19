"""Python reference model for the FPGA limit-order-book accelerator.

Roles:
* ``lob.protocol``  -- 32-byte UDP wire format (encode/decode).
* ``lob.orderbook`` -- golden reference matching engine (Order, Trade, OrderBook).
* ``lob.simulator`` -- market data simulator: order-flow generator + UDP sender.
* ``lob.consumer``  -- golden reference consumer: replays the feed and
  validates executions (UDP receiver).

``simulator`` and ``consumer`` are imported lazily (PEP 562) so that
``python -m lob.simulator`` / ``python -m lob.consumer`` run cleanly without
re-importing their ``__main__`` targets from the package ``__init__``.
"""

from .orderbook import (
    Order,
    Trade,
    Side,
    OrderBook,
    PriceLevel,
    OrderBookError,
    DuplicateOrderError,
    OrderNotFoundError,
)
from .protocol import (
    Message,
    MSG_SIZE,
    VERSION,
    MSG_ADD,
    MSG_CANCEL,
    MSG_MODIFY,
    MSG_EXECUTE,
    SIDE_BUY,
    SIDE_SELL,
    FLAG_EXTERNAL,
    OFF_VERSION,
    OFF_MSG_TYPE,
    OFF_SIDE,
    OFF_FLAGS,
    OFF_SEQ_NUM,
    OFF_ORDER_ID,
    OFF_PRICE,
    OFF_QUANTITY,
    OFF_TIMESTAMP,
    encode_message,
    decode_message,
    build_message,
    hexdump,
)

__all__ = [
    # models
    "Order", "Trade", "Side", "OrderBook", "PriceLevel",
    "OrderBookError", "DuplicateOrderError", "OrderNotFoundError",
    # protocol
    "Message", "MSG_SIZE", "VERSION",
    "MSG_ADD", "MSG_CANCEL", "MSG_MODIFY", "MSG_EXECUTE",
    "SIDE_BUY", "SIDE_SELL", "FLAG_EXTERNAL",
    "OFF_VERSION", "OFF_MSG_TYPE", "OFF_SIDE", "OFF_FLAGS", "OFF_SEQ_NUM",
    "OFF_ORDER_ID", "OFF_PRICE", "OFF_QUANTITY", "OFF_TIMESTAMP",
    "encode_message", "decode_message", "build_message", "hexdump",
    # simulator + consumer (lazy)
    "OrderFlowGenerator", "UDPSender",
    "GoldenReference", "UDPServer", "ExecutionMismatchError",
]

_LAZY_MODULES = {
    "OrderFlowGenerator": "simulator",
    "UDPSender": "simulator",
    "GoldenReference": "consumer",
    "UDPServer": "consumer",
    "ExecutionMismatchError": "consumer",
}


def __getattr__(name):
    """Lazy import of simulator / consumer symbols (PEP 562)."""
    module_name = _LAZY_MODULES.get(name)
    if module_name is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    import importlib

    module = importlib.import_module(f"{__name__}.{module_name}")
    return getattr(module, name)


def __dir__():
    return sorted(set(globals()) | set(_LAZY_MODULES))
