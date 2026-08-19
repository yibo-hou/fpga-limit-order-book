# Batch synthesis baseline for the standalone LOB core.
# Override with environment variables LOB_PART and LOB_PERIOD_NS if needed.

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir ..]]
set rtl_dir [file join $project_dir rtl]
set build_dir [file join $project_dir build synth]
file mkdir $build_dir

set part_name xc7a100tfgg484-2
if {[info exists ::env(LOB_PART)]} {
  set part_name $::env(LOB_PART)
}

set period_ns 5.000
if {[info exists ::env(LOB_PERIOD_NS)]} {
  set period_ns $::env(LOB_PERIOD_NS)
}

set rtl_files [list [file join $rtl_dir lob_pkg.sv]]
foreach source [lsort [glob -nocomplain [file join $rtl_dir *.sv]]] {
  if {[file tail $source] ne "lob_pkg.sv"} {
    lappend rtl_files $source
  }
}

read_verilog -sv $rtl_files
synth_design -top lob_engine_top -part $part_name -flatten_hierarchy rebuilt
create_clock -name core_clk -period $period_ns [get_ports clk]

report_utilization -hierarchical -file [file join $build_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 \
  -file [file join $build_dir timing_summary.rpt]
report_high_fanout_nets -timing -load_types -max_nets 50 \
  -file [file join $build_dir high_fanout.rpt]
write_checkpoint -force [file join $build_dir lob_engine_top_synth.dcp]

puts "LOB_SYNTH_PART=$part_name"
puts "LOB_SYNTH_PERIOD_NS=$period_ns"
puts "LOB_SYNTH_REPORT_DIR=$build_dir"
