PYTHON ?= python3

.PHONY: help test test-python test-rtl uvm uvm-gui synth bitstream fpga clean

help:
	@echo "FPGA Limit Order Book - Project Root"
	@echo ""
	@echo "Available commands:"
	@echo "  make test         - Run Python and RTL smoke tests"
	@echo "  make test-python  - Run the Python reference-model tests"
	@echo "  make test-rtl     - Run the RTL smoke test with Icarus Verilog"
	@echo "  make uvm          - Run the default Questa UVM test"
	@echo "  make uvm-gui      - Open the Questa UVM test in the GUI"
	@echo "  make synth        - Synthesize the standalone LOB core"
	@echo "  make bitstream    - Build the DaVinci Pro bitstream"
	@echo "  make clean        - Remove generated files"

test: test-python test-rtl

test-python:
	$(MAKE) -C software test PYTHON=$(PYTHON)

test-rtl:
	$(MAKE) -C hardware/sim test

uvm:
	$(MAKE) -C hardware/verif run

uvm-gui:
	$(MAKE) -C hardware/verif gui

synth:
	cd hardware && vivado -mode batch -nolog -nojournal -source tools/synth.tcl

bitstream fpga:
	cd hardware && vivado -mode batch -nolog -nojournal -source tools/build_board.tcl

clean:
	$(MAKE) -C software clean || true
	$(MAKE) -C hardware/sim clean || true
	$(MAKE) -C hardware/verif clean || true
	rm -rf hardware/build/
	rm -rf hardware/sim/xsim.dir/
	find . -type d -name "__pycache__" -exec rm -rf {} +
	find . -type f -name "*.pyc" -delete
