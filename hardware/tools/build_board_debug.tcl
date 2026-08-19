set script_dir  [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir ..]]
set build_dir   [file join $project_dir build board]

open_checkpoint [file join $build_dir post_synth.dcp]

set core_debug_nets [lsort -dictionary \
  [get_nets -hier -filter {MARK_DEBUG == 1 && NAME =~ *core_debug_bus*}]]
create_debug_core u_ila_core ila
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_core]
set_property port_width [llength $core_debug_nets] [get_debug_ports u_ila_core/probe0]
connect_debug_port u_ila_core/clk [get_nets clk_125m]
connect_debug_port u_ila_core/probe0 $core_debug_nets

opt_design
place_design
phys_opt_design
route_design
phys_opt_design
write_checkpoint -force [file join $build_dir debug_post_route.dcp]
write_debug_probes -force [file join $build_dir lob_davinci_pro.ltx]
write_bitstream -force [file join $build_dir lob_davinci_pro_debug.bit]
