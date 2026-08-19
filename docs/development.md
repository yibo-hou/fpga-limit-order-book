# Development and Reproducibility

## Supported environment

The project is designed to use only standard Python modules at runtime. The
following versions are known to work:

| Component | Tested version | Purpose |
|---|---:|---|
| Python | 3.14.5 | Golden model, stimulus and board tools |
| pytest | 9.1.1 | Python test suite |
| Icarus Verilog | 12.0 | Portable RTL smoke test |
| AMD Vivado | 2025.2 | Synthesis, implementation and XSim compilation |
| Questa | 2025.3 | UVM verification |

Python 3.10 or newer is supported. Vivado and Questa are optional unless their
respective FPGA or UVM flows are used.

## Reproduce the portable test suite

From a fresh clone:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e './software[dev]'
make test
```

`make test` runs the Python reference-model suite and the Icarus Verilog smoke
test. Build products are written only to ignored `build/` directories.

## Vivado flows

The default target is the ALIENTEK DaVinci Pro
`XC7A100T-2FGG484`. Override the FPGA part or standalone-core clock period with
environment variables:

```bash
make synth
LOB_PART=xc7a100tfgg484-2 LOB_PERIOD_NS=5.0 make synth
make bitstream
```

Vivado reports, checkpoints and bitstreams are generated under
`hardware/build/` and are not committed.

`make synth` is a fast synthesis-only sanity check. Its timing report is an
unplaced estimate and is not a timing-closure result. Use `make bitstream` and
inspect the post-route timing report before claiming a target frequency.

## Questa UVM flow

Set `UVM_HOME` to either the UVM 1.2 installation directory or its `src`
directory. If the simulator requires the precompiled DPI library, set
`UVM_DPI` to the full library path without the `.so` suffix.

```bash
export UVM_HOME=/opt/questa/verilog_src/uvm-1.2
export UVM_DPI=/opt/questa/uvm-1.2/linux_x86_64/uvm_dpi  # optional
make uvm
```

No build script depends on a developer-specific home directory.
