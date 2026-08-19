# ==============================================================================
# run_questa.do: Automated QuestaSim Compile and Batch Execution Script
# ==============================================================================

# 1. Resolve the UVM installation from environment variables
do uvm_config.do

# 2. Create Working Library
if [file exists work] {
    vdel -lib work -all
}
vlib work
vmap work work

# 3. Compile RTL Source Code (lob_pkg.sv must be compiled first)
vlog -sv -work work ../rtl/lob_pkg.sv
vlog -sv -work work ../rtl/best_price_encoder.sv
vlog -sv -work work ../rtl/fifo_queue.sv
vlog -sv -work work ../rtl/message_decoder.sv
vlog -sv -work work ../rtl/order_id_table.sv
vlog -sv -work work ../rtl/order_memory.sv
vlog -sv -work work ../rtl/price_level.sv
vlog -sv -work work ../rtl/matcher.sv
vlog -sv -work work ../rtl/order_manager.sv
vlog -sv -work work ../rtl/trade_generator.sv
vlog -sv -work work ../rtl/lob_engine_top.sv

# 4. Compile UVM Verification Packages and Testbench
vlog -sv -work work +incdir+$uvm_src $uvm_src/uvm_pkg.sv
vlog -sv -work work +incdir+$uvm_src +incdir+../rtl lob_if.sv
vlog -sv -work work +incdir+$uvm_src +incdir+../rtl lob_uvm_pkg.sv
vlog -sv -work work +incdir+$uvm_src +incdir+../rtl lob_tests.sv
vlog -sv -work work +incdir+$uvm_src +incdir+../rtl lob_tb_top.sv

# 5. Parse Test Name (Defaults to lob_smoke_test)
if { ![info exists test_name] } {
    set test_name "lob_smoke_test"
}

puts "========================================================"
puts "  Running UVM test: $test_name"
puts "========================================================"

# 6. Execute Simulation
if {$uvm_dpi ne ""} {
    vsim -c -sv_lib $uvm_dpi -suppress 7061 -voptargs="+acc" work.lob_tb_top +UVM_TESTNAME=$test_name -do "run -all; quit -f"
} else {
    vsim -c -suppress 7061 -voptargs="+acc" work.lob_tb_top +UVM_TESTNAME=$test_name -do "run -all; quit -f"
}
