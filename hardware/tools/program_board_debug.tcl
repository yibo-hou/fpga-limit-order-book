set script_dir  [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir ..]]
set build_dir   [file join $project_dir build board]
set bit_file    [file join $build_dir lob_davinci_pro_debug.bit]
set ltx_file    [file join $build_dir lob_davinci_pro.ltx]

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
refresh_hw_device $dev
set_property PROGRAM.FILE $bit_file $dev
set_property PROBES.FILE $ltx_file $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "LOB_DEBUG_ILAS=[get_property CELL_NAME [get_hw_ilas]]"
close_hw_manager
