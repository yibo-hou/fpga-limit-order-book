set script_dir  [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir ..]]
set bit_file    [file join $project_dir build board lob_davinci_pro.bit]

if {![file exists $bit_file]} {
  error "bitstream not found: $bit_file"
}

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
if {$dev eq ""} {
  error "no XC7A100T found in JTAG chain"
}
current_hw_device $dev
refresh_hw_device $dev
set_property PROGRAM.FILE $bit_file $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "LOB_PROGRAMMED_DEVICE=[get_property NAME $dev]"
puts "LOB_PROGRAMMED_BIT=$bit_file"
close_hw_manager
