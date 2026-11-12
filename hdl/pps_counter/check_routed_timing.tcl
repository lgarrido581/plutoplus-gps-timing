# vivado -mode batch -source check_routed_timing.tcl -tclargs <routed.dcp> <report-dir>
if {$argc != 2} {error "Expected routed checkpoint and report directory"}
set checkpoint [lindex $argv 0]
set reports [lindex $argv 1]
file mkdir $reports
open_checkpoint $checkpoint
report_timing_summary -warn_on_violation -file $reports/timing_summary.rpt
report_cdc -details -file $reports/cdc.rpt
report_exceptions -coverage -file $reports/exception_coverage.rpt
report_bus_skew -warn_on_violation -file $reports/bus_skew.rpt

foreach pattern {cnt_reset_sync_reg* gray_s1_reg* gray_s2_reg* fgray_s1_reg* fgray_s2_reg*} {
    set cells [get_cells -quiet -hier -filter "NAME =~ *pps_counter_0/inst/$pattern"]
    if {![llength $cells]} {error "Expected synchronizer registers missing: $pattern"}
    foreach cell $cells {
        if {![get_property ASYNC_REG $cell]} {error "ASYNC_REG is absent on $cell"}
    }
    puts "Verified ASYNC_REG: $pattern ([llength $cells] cells)"
}
foreach kind {max min} {
    set worst [get_timing_paths -quiet -delay_type $kind -max_paths 1]
    if {![llength $worst]} {error "No $kind timing paths reported"}
    set slack [get_property SLACK $worst]
    puts "ROUTED_${kind}_SLACK_NS=$slack"
    if {$slack < 0} {error "Routed $kind timing fails: $slack ns"}
}
set skew [report_bus_skew -return_string]
if {[string match *VIOLATED* $skew]} {error "CDC bus skew constraint failed"}
puts ROUTED_PPS_TIMING_AUDIT_PASS
close_design
