# ==============================================================================
# Makefile: QuestaSim UVM Verification Execution Manager
#
# Usage:
#   make smoke    - Run basic smoke test (lob_smoke_test)
#   make sweep    - Run multi-level book sweep test (lob_sweep_test)
#   make cancel   - Run order cancel and modify test (lob_cancel_modify_test)
#   make stress   - Run heavy realistic financial stress test (lob_stress_test)
#   make cov      - Run stress test with full functional coverage report
#   make gui      - Open QuestaSim GUI with auto-populated waveforms
#   make clean    - Remove simulation artifacts, work library, and logs
# ==============================================================================

TEST ?= lob_stress_test

all: run

run:
	vsim -c -do "set test_name $(TEST); do run_questa.do"

smoke:
	vsim -c -do "set test_name lob_smoke_test; do run_questa.do"

sweep:
	vsim -c -do "set test_name lob_sweep_test; do run_questa.do"

cancel:
	vsim -c -do "set test_name lob_cancel_modify_test; do run_questa.do"

stress:
	vsim -c -do "set test_name lob_stress_test; do run_questa.do"

cov:
	vsim -c -do "set test_name lob_stress_test; do run_questa.do"

gui:
	vsim -gui -onfinish stop -do "set test_name $(TEST); do gui.do"

clean:
	rm -rf work transcript vsim.wlf lob_uvm_wave.vcd modelsim.ini tr_db.log
