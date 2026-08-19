IVERILOG ?= iverilog
VVP      ?= vvp
BUILD    ?= build

RTL_DIR := ../rtl
RTL_SOURCES := \
	$(RTL_DIR)/lob_pkg.sv \
	$(RTL_DIR)/best_price_encoder.sv \
	$(RTL_DIR)/fifo_queue.sv \
	$(RTL_DIR)/message_decoder.sv \
	$(RTL_DIR)/order_id_table.sv \
	$(RTL_DIR)/order_memory.sv \
	$(RTL_DIR)/price_level.sv \
	$(RTL_DIR)/matcher.sv \
	$(RTL_DIR)/order_manager.sv \
	$(RTL_DIR)/trade_generator.sv \
	$(RTL_DIR)/lob_engine_top.sv

SMOKE_IMAGE := $(BUILD)/lob_engine_smoke.vvp

.PHONY: all test clean

all: test

test: $(SMOKE_IMAGE)
	$(VVP) $(SMOKE_IMAGE)

$(SMOKE_IMAGE): $(RTL_SOURCES) tb_lob_engine_smoke.sv
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -s tb_lob_engine_smoke -o $@ $(RTL_SOURCES) tb_lob_engine_smoke.sv

clean:
	rm -rf $(BUILD)
