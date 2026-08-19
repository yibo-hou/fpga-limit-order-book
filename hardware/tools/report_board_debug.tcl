set script_dir  [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir ..]]
set build_dir   [file join $project_dir build board]

open_checkpoint [file join $build_dir debug_post_route.dcp]
report_timing_summary -max_paths 20 \
  -file [file join $build_dir debug_post_route_timing.rpt]
report_drc -file [file join $build_dir debug_post_route_drc.rpt]
