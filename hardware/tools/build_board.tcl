set script_dir  [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir ..]]
set rtl_dir     [file join $project_dir rtl]
set board_dir   [file join $project_dir board]
set build_dir   [file join $project_dir build board]
file mkdir $build_dir

set part_name xc7a100tfgg484-2
if {[info exists ::env(LOB_PART)]} {
  set part_name $::env(LOB_PART)
}

set sources [list \
  [file join $rtl_dir lob_pkg.sv] \
  [file join $rtl_dir best_price_encoder.sv] \
  [file join $rtl_dir fifo_queue.sv] \
  [file join $rtl_dir lob_engine_top.sv] \
  [file join $rtl_dir matcher.sv] \
  [file join $rtl_dir message_decoder.sv] \
  [file join $rtl_dir order_id_table.sv] \
  [file join $rtl_dir order_manager.sv] \
  [file join $rtl_dir order_memory.sv] \
  [file join $rtl_dir price_level.sv] \
  [file join $rtl_dir trade_generator.sv] \
  [file join $rtl_dir ethernet_crc32.sv] \
  [file join $rtl_dir phy_reset_ctrl.sv] \
  [file join $rtl_dir mdio_master.sv] \
  [file join $rtl_dir yt8511_ctrl.sv] \
  [file join $board_dir rgmii_rx.sv] \
  [file join $rtl_dir rgmii_tx.sv] \
  [file join $rtl_dir eth_ipv4_udp_rx.sv] \
  [file join $rtl_dir udp_ipv4_eth_tx.sv] \
  [file join $rtl_dir arp_reply_tx.sv] \
  [file join $board_dir cdc_mailbox.sv] \
  [file join $board_dir lob_clock_reset.sv] \
  [file join $board_dir udp_order_ingress.sv] \
  [file join $board_dir lob_udp_egress.sv] \
  [file join $board_dir lob_davinci_pro_top.sv]]

read_verilog -sv $sources
read_xdc [file join $project_dir constraints davinci_pro_lob.xdc]

synth_design -top lob_davinci_pro_top -part $part_name \
  -flatten_hierarchy rebuilt
write_checkpoint -force [file join $build_dir post_synth.dcp]
report_utilization -hierarchical -file [file join $build_dir post_synth_utilization.rpt]
report_timing_summary -file [file join $build_dir post_synth_timing.rpt]

opt_design
place_design
phys_opt_design
write_checkpoint -force [file join $build_dir post_place.dcp]
report_utilization -hierarchical -file [file join $build_dir post_place_utilization.rpt]
report_timing_summary -max_paths 20 -file [file join $build_dir post_place_timing.rpt]

route_design
phys_opt_design
write_checkpoint -force [file join $build_dir post_route.dcp]
report_timing_summary -max_paths 20 -file [file join $build_dir post_route_timing.rpt]
report_drc -file [file join $build_dir post_route_drc.rpt]
report_methodology -file [file join $build_dir methodology.rpt]

set bit_file [file join $build_dir lob_davinci_pro.bit]
write_bitstream -force $bit_file
puts "LOB_BOARD_PART=$part_name"
puts "LOB_BOARD_BIT=$bit_file"
