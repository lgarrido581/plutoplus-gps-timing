# Post-route guard for the LibreSDR AD9361 source-synchronous RX interface.
# This is sourced by system_project.tcl after ADI's implementation and delay
# report. It makes a green build require real, finite setup and hold analysis.

if {[current_design -quiet] eq ""} {
  if {$argc != 1} {
    error "usage: validate_lvds_timing.tcl <routed.dcp>"
  }
  set checkpoint [file normalize [lindex $argv 0]]
  open_checkpoint $checkpoint
  set report_dir [file dirname $checkpoint]
} else {
  set report_dir [file join [pwd] libre.runs impl_1]
}

set rx_ports [get_ports -quiet {
  rx_data_in_p[*] rx_data_in_n[*]
  rx_frame_in_p rx_frame_in_n
}]
if {[llength $rx_ports] != 14} {
  error "LVDS_TIMING: expected 14 RX data/frame ports, found [llength $rx_ports]"
}

set rx_iddr_d [get_pins -quiet -hier -filter {
  NAME =~ *axi_ad9361*/i_dev_if/*i_rx_data_iddr/D
}]
if {[llength $rx_iddr_d] != 7} {
  error "LVDS_TIMING: expected 7 RX IDDR inputs, found [llength $rx_iddr_d]"
}

set rx_clocks [get_clocks -quiet -of_objects [get_ports rx_clk_in_p]]
if {[llength $rx_clocks] != 1} {
  error "LVDS_TIMING: expected one clock on rx_clk_in_p, found [llength $rx_clocks]"
}
set rx_period [get_property PERIOD [lindex $rx_clocks 0]]
if {$rx_period > 4.070} {
  error "LVDS_TIMING: rx_clk period $rx_period ns does not cover 245.76 MHz"
}

report_timing -from $rx_ports -delay_type max -max_paths 100 \
  -file [file join $report_dir libresdr_lvds_setup.rpt]
report_timing -from $rx_ports -delay_type min -max_paths 100 \
  -file [file join $report_dir libresdr_lvds_hold.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
  -file [file join $report_dir libresdr_timing_summary.rpt]
check_timing -verbose -file [file join $report_dir libresdr_check_timing.rpt]

set setup_paths [get_timing_paths -quiet -from $rx_ports \
  -to $rx_iddr_d -delay_type max -max_paths 100]
if {[llength $setup_paths] != 7} {
  error "LVDS_TIMING: expected 7 RX setup paths, found [llength $setup_paths]"
}
set lane_delays {}
set lane_report [open [file join $report_dir libresdr_lvds_lane_delays.rpt] w]
puts $lane_report "LibreSDR post-route FPGA LVDS input lane delays"
foreach path $setup_paths {
  set slack [get_property SLACK $path]
  if {$slack eq "" || [regexp -nocase {inf|nan} $slack]} {
    error "LVDS_TIMING: RX setup path has non-finite slack '$slack'"
  }
  if {$slack < 0.0} {
    error "LVDS_TIMING: RX setup path failed with slack $slack ns"
  }
  set delay [get_property DATAPATH_DELAY $path]
  if {$delay eq "" || [regexp -nocase {inf|nan} $delay]} {
    error "LVDS_TIMING: RX path has non-finite datapath delay '$delay'"
  }
  lappend lane_delays $delay
  puts $lane_report "[get_property STARTPOINT_PIN $path] -> [get_property ENDPOINT_PIN $path]: ${delay} ns"
}
set sorted_lane_delays [lsort -real $lane_delays]
set min_lane_delay [lindex $sorted_lane_delays 0]
set max_lane_delay [lindex $sorted_lane_delays end]
set lane_skew [expr {$max_lane_delay - $min_lane_delay}]
puts $lane_report "spread: [format %.3f $lane_skew] ns (limit 0.200 ns)"
close $lane_report
if {$lane_skew > 0.200} {
  error "LVDS_TIMING: post-route FPGA lane-delay spread [format %.3f $lane_skew] ns exceeds 0.200 ns"
}

set hold_paths [get_timing_paths -quiet -from $rx_ports \
  -delay_type min -max_paths 100]
if {[llength $hold_paths] != 7} {
  error "LVDS_TIMING: expected 7 calibrated RX IDDR hold paths, found [llength $hold_paths]"
}
foreach path $hold_paths {
  set slack [get_property SLACK $path]
  if {$slack ne "" && ![regexp -nocase {inf} $slack]} {
    error "LVDS_TIMING: calibrated RX IDDR hold path is not exempt (slack '$slack')"
  }
}

puts "LVDS_TIMING: PASS period=${rx_period}ns; setup/path constraints met; FPGA lane spread=[format %.3f $lane_skew]ns; calibrated hold is covered by verify_lvds.sh"
