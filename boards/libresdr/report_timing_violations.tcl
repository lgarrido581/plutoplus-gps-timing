# Generate detailed setup/hold violation reports from a routed LibreSDR DCP.
# Usage:
#   vivado -mode batch -source report_timing_violations.tcl \
#     -tclargs <routed.dcp> <output-directory>

if {$argc != 2} {
  error "usage: report_timing_violations.tcl <routed.dcp> <output-directory>"
}
set dcp [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
file mkdir $out_dir

open_checkpoint $dcp
report_timing -delay_type max -slack_lesser_than 0.0 \
  -max_paths 1000 -nworst 20 \
  -file [file join $out_dir setup_violations.rpt]
report_timing -delay_type min -slack_lesser_than 0.0 \
  -max_paths 1000 -nworst 20 \
  -file [file join $out_dir hold_violations.rpt]
set rx_ports [get_ports -quiet {
  rx_data_in_p[*] rx_data_in_n[*]
  rx_frame_in_p rx_frame_in_n
}]
report_timing -from $rx_ports -delay_type max -max_paths 100 \
  -file [file join $out_dir lvds_setup_paths.rpt]
report_timing -from $rx_ports -delay_type min -max_paths 100 \
  -file [file join $out_dir lvds_hold_paths.rpt]
report_high_fanout_nets -timing -max_nets 100 \
  -file [file join $out_dir high_fanout_nets.rpt]
report_methodology \
  -file [file join $out_dir methodology.rpt]

puts "TIMING_DIAGNOSTICS: reports written to $out_dir"
