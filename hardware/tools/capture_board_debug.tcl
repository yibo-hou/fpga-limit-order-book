set script_dir  [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir ..]]
set build_dir   [file join $project_dir build board]
set ltx_file    [file join $build_dir lob_davinci_pro.ltx]

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
set_property PROBES.FILE $ltx_file $dev
refresh_hw_device $dev

foreach ila [get_hw_ilas] {
  set cell [get_property CELL_NAME $ila]
  set safe_name [string map {/ _} $cell]
  run_hw_ila -trigger_now $ila
  wait_on_hw_ila $ila
  set data [upload_hw_ila_data $ila]
  set csv_file [file join $build_dir "capture_${safe_name}.csv"]
  write_hw_ila_data -force -csv_file $csv_file $data
  puts "LOB_CAPTURE=$cell:$csv_file"
}

close_hw_manager
