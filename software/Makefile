PYTHON   ?= python3
BUILD    ?= build

# ------------------------------------------------------------------ targets

.PHONY: all test stress demo video-demo video-interactive run-sim run-ref stimulus clean

all: test

## run the full test suite
test:
	$(PYTHON) -m pytest tests/ -v

## 10000-message random stress test
stress:
	$(PYTHON) -m pytest tests/test_stress.py -v

## end-to-end demo: generate, replay, validate
demo:
	$(PYTHON) demo.py

## fixed two-order live demo for the FPGA board
video-demo:
	$(PYTHON) video_demo.py

## interactive command prompt for the real FPGA board
video-interactive:
	$(PYTHON) video_demo.py --interactive

## live UDP demo, terminal 1: market data simulator
run-sim:
	$(PYTHON) -m lob.simulator --host 127.0.0.1 --port 9000 --count 1000

## live UDP demo, terminal 2: golden reference consumer
run-ref:
	$(PYTHON) -m lob.consumer --host 127.0.0.1 --port 9000 --count 0 --timeout 30

## write a deterministic binary stimulus file for UVM (32 bytes/message)
stimulus:
	@mkdir -p $(BUILD)
	$(PYTHON) -c "from lob.simulator import OrderFlowGenerator as G; \
	              print(G(seed=0).write_stimulus('$(BUILD)/stimulus.bin', 2000), \
	                    'messages -> $(BUILD)/stimulus.bin')"

clean:
	rm -rf $(BUILD) .pytest_cache *.egg-info
	find . -type d -name __pycache__ -exec rm -rf {} +
