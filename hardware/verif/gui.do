# ==============================================================================
# gui.do: QuestaSim Interactive GUI and Waveform Loader Script
# ==============================================================================

# 1. Resolve the UVM installation from environment variables
do uvm_config.do

# 2. Compile Design and Testbench
vlib work
vmap work work

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

vlog -sv -work work +incdir+$uvm_src $uvm_src/uvm_pkg.sv
vlog -sv -work work +incdir+$uvm_src +incdir+../rtl lob_if.sv
vlog -sv -work work +incdir+$uvm_src +incdir+../rtl lob_uvm_pkg.sv
vlog -sv -work work +incdir+$uvm_src +incdir+../rtl lob_tests.sv
vlog -sv -work work +incdir+$uvm_src +incdir+../rtl lob_tb_top.sv

# 3. Parse Target Test Name (Defaults to lob_stress_test)
if { ![info exists test_name] } {
    set test_name "lob_stress_test"
}

# 4. Start Simulation Engine (-onfinish stop prevents closing GUI on $finish)
if {$uvm_dpi ne ""} {
    vsim -onfinish stop -sv_lib $uvm_dpi -suppress 7061 -voptargs="+acc" work.lob_tb_top +UVM_TESTNAME=$test_name
} else {
    vsim -onfinish stop -suppress 7061 -voptargs="+acc" work.lob_tb_top +UVM_TESTNAME=$test_name
}

# 5. Populate Structured Wave Window
add wave -divider "=== System Clock & Reset ==="
add wave /lob_tb_top/clk
add wave /lob_tb_top/intf/rst_n

add wave -divider "=== Order Command Ingress ==="
add wave /lob_tb_top/intf/s_payload_valid
add wave /lob_tb_top/intf/s_payload_ready
add wave -radix hex /lob_tb_top/intf/s_payload

add wave -divider "=== Engine Top FSM ==="
add wave /lob_tb_top/u_dut/state
add wave -radix dec /lob_tb_top/intf/status_best_bid
add wave -radix dec /lob_tb_top/intf/status_best_ask
add wave -radix dec /lob_tb_top/intf/status_num_orders

add wave -divider "=== Matcher FSM & Fast Path ==="
add wave /lob_tb_top/u_dut/u_matcher/state
add wave /lob_tb_top/u_dut/u_matcher/s_fast_path

add wave -divider "=== Matched Trades Output ==="
add wave /lob_tb_top/intf/m_trade_valid
add wave /lob_tb_top/intf/m_trade_ready
add wave -radix dec /lob_tb_top/intf/m_trade.price
add wave -radix dec /lob_tb_top/intf/m_trade.quantity
add wave -radix hex /lob_tb_top/intf/m_trade.buy_order_id
add wave -radix hex /lob_tb_top/intf/m_trade.sell_order_id

add wave -divider "=== Acks Output ==="
add wave /lob_tb_top/intf/m_ack_valid
add wave /lob_tb_top/intf/m_ack.status
add wave -radix hex /lob_tb_top/intf/m_ack.order_id
add wave -radix dec /lob_tb_top/intf/m_ack.remaining_qty

# 6. Execute Simulation and Auto-Fit Waves
run -all
wave zoom full
