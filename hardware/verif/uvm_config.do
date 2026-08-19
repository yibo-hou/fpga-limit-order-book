# Portable UVM configuration shared by batch and GUI simulations.
#
# UVM_HOME may point either to the UVM installation directory (containing
# src/uvm_pkg.sv) or directly to its src directory. UVM_DPI is optional and
# must be the platform library path without the .so suffix when supplied.

if {![info exists env(UVM_HOME)]} {
    error "UVM_HOME is not set. Point it to the UVM 1.2 directory or its src directory."
}

set uvm_home [file normalize $env(UVM_HOME)]
if {[file exists [file join $uvm_home src uvm_pkg.sv]]} {
    set uvm_src [file join $uvm_home src]
} elseif {[file exists [file join $uvm_home uvm_pkg.sv]]} {
    set uvm_src $uvm_home
} else {
    error "Cannot find uvm_pkg.sv below UVM_HOME=$uvm_home"
}

set uvm_dpi ""
if {[info exists env(UVM_DPI)] && $env(UVM_DPI) ne ""} {
    set uvm_dpi [file normalize $env(UVM_DPI)]
    if {![file exists "${uvm_dpi}.so"]} {
        error "Cannot find ${uvm_dpi}.so specified by UVM_DPI"
    }
}

puts "UVM source: $uvm_src"
if {$uvm_dpi ne ""} {
    puts "UVM DPI library: ${uvm_dpi}.so"
} else {
    puts "UVM DPI library: disabled (set UVM_DPI to enable it)"
}
