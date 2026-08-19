# FPGA Limit Order Book

A hardware-accelerated, price-time-priority limit order book for the Xilinx
Artix-7 FPGA family. The repository contains synthesizable SystemVerilog, a
byte-compatible Python golden model, deterministic stimulus generation, RTL
and UVM verification, and Ethernet/UDP integration for the ALIENTEK DaVinci
Pro board.

The protocol uses fixed 32-byte, big-endian messages for add, cancel, modify
and execute events. The Python model and RTL consume the same wire format.

## Architecture

The Python model and the RTL consume the same 32-byte wire format, so a
deterministic software order flow can drive the FPGA directly over UDP, and
the same flow can be replayed by the UVM scoreboard to check every trade and
acknowledgement against the golden model.

```
                        ┌──────────────────────────────────┐
                        │        Host — software/          │
                        │                                  │
                        │   lob/simulator.py               │
                        │    deterministic order flow      │
                        │   lob/consumer.py                │
                        │    golden reference OrderBook    │
                        └────────────────┬─────────────────┘
                                         │ 32-byte UDP datagrams
                                         ▼
                        ┌──────────────────────────────────┐
                        │        FPGA — XC7A100T           │
                        │                                  │
                        │   eth_ipv4_udp_rx               │
                        │          │ payload[255:0]        │
                        │          ▼                       │
                        │   message_decoder                │
                        │          │ cmd_t                 │
                        │          ▼                       │
                        │   lob_engine_top                 │
                        │    ├─ matcher                    │
                        │    ├─ order_manager              │
                        │    ├─ price_level                │
                        │    ├─ order_memory               │
                        │    ├─ order_id_table             │
                        │    └─ trade_generator            │
                        │          │                       │
                        │          ▼                       │
                        │   udp_ipv4_eth_tx                │
                        └────────────────┬─────────────────┘
                                         │ 2× 32-byte EXECUTE reports + ACKs
                                         ▼
                          back to host (UDP port 5000)

       ┌────────────────────────────────────────────────────────┐
       │  UVM verification (Questa)                             │
       │  replays the same 32-byte stimulus and checks every     │
       │  trade / ack / snapshot against the Python golden model │
       └────────────────────────────────────────────────────────┘
```

## Features

- Price-time-priority matching with add, cancel, modify and execute commands
- Up to 8,191 simultaneously live orders
- 4,096 price levels and a four-way set-associative order-ID table
- UDP/IPv4/Ethernet board interface with acknowledgements and trade reports
- Deterministic Python golden model and stress-test generator
- Portable Python and Icarus Verilog tests
- Vivado build scripts and a Questa UVM verification environment

## Repository layout

```text
.
├── hardware/
│   ├── rtl/          Core LOB and Ethernet/UDP RTL
│   ├── board/        DaVinci Pro integration
│   ├── constraints/  Board pin and timing constraints
│   ├── sim/          Portable RTL testbench
│   ├── verif/        Questa UVM environment
│   └── tools/        Vivado and board-control scripts
├── software/
│   ├── lob/          Python model, protocol and UDP tools
│   └── tests/        Unit, stress and loopback tests
└── docs/                 Architecture and interface specifications
```

## Quick start

Install the portable development dependencies and run both the Python and RTL
tests:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e './software[dev]'
make test
```

The suite requires Python 3.10 or newer and Icarus Verilog. See the
[development and reproducibility guide](docs/development.md) for tested tool
versions, Vivado synthesis, bitstream generation and Questa setup.

Run the Python demonstration separately with:

```bash
make -C software demo
```

## FPGA build

Build the standalone core or the complete DaVinci Pro bitstream with Vivado:

```bash
make synth
make bitstream
```

The board build defaults to `XC7A100T-2FGG484`. See the
[board guide](hardware/board/README.md) for network settings, programming and
hardware tests.

## Documentation

- [Architecture Overview](docs/architecture.md)
- [Protocol Specification](docs/01_protocol_spec.md)
- [Memory Architecture](docs/04_memory_architecture.md)
- [RTL Interface Specification](docs/03_rtl_interface_spec.md)
- [UVM Verification Interface](docs/05_uvm_verification_interface.md)
- [Development and Reproducibility](docs/development.md)

## Project status

This is a research and educational FPGA implementation, not a production
exchange system. Protocol version 1 is frozen; incompatible wire-format
changes require a version increment.

## License

Released under the [MIT License](LICENSE).
