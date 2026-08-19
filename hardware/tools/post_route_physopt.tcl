set script_dir  [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir ..]]
set build_dir   [file join $project_dir build board]
open_checkpoint [file join $build_dir post_route.dcp]
phys_opt_design -directive AggressiveExplore
write_checkpoint -force [file join $build_dir post_route.dcp]
report_timing_summary -max_paths 20 \
  -file [file join $build_dir post_route_timing.rpt]
report_drc -file [file join $build_dir post_route_drc.rpt]
write_bitstream -force [file join $build_dir lob_davinci_pro.bit]
