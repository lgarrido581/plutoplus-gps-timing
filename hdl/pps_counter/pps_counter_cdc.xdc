# Flat project XDC: no Tcl procedures or conditionals (Vivado ignores those).
# Only first-stage D pins are selected. Stage two and downstream logic remain
# normally timed. Bound CDC latency and bus skew to 4 ns, the faster clock's
# period (RX up to 250 MHz). Only actual connected register-to-D paths apply.
set pps_sources [get_cells -quiet -hier -filter {NAME =~ *pps_counter_0/inst/*_reg* && IS_SEQUENTIAL == 1}]

# RX -> AXI: live Gray observations and held PPS/capture/frame snapshots.
set pps_to_axi [get_cells -quiet -hier -filter {NAME =~ *pps_counter_0/inst/gray_s1_reg* || NAME =~ *pps_counter_0/inst/fgray_s1_reg* || NAME =~ *pps_counter_0/inst/fseq_s1_reg* || NAME =~ *pps_counter_0/inst/ppsc_s1_reg* || NAME =~ *pps_counter_0/inst/ppsd_s1_reg* || NAME =~ *pps_counter_0/inst/ppss_s1_reg* || NAME =~ *pps_counter_0/inst/lc_s1_reg* || NAME =~ *pps_counter_0/inst/lseq_s1_reg*}]
set pps_to_axi_d [get_pins -of_objects $pps_to_axi -filter {REF_PIN_NAME == D}]
set_max_delay -datapath_only 4.000 -from $pps_sources -to $pps_to_axi_d
set_bus_skew 4.000 -from $pps_sources -to $pps_to_axi_d

# AXI -> RX: configuration obeys the existing disabled-write-enable contract.
# Bound routing into stage one, without excepting the stage-one -> two paths.
set pps_to_rx [get_cells -quiet -hier -filter {NAME =~ *pps_counter_0/inst/tdc_s1_reg* || NAME =~ *pps_counter_0/inst/flen_s1_reg* || NAME =~ *pps_counter_0/inst/rxa_s1_reg* || NAME =~ *pps_counter_0/inst/rxo_s1_reg* || NAME =~ *pps_counter_0/inst/txa_s1_reg* || NAME =~ *pps_counter_0/inst/txo_s1_reg* || NAME =~ *pps_counter_0/inst/flenm2_s1_reg* || NAME =~ *pps_counter_0/inst/rxam2_s1_reg* || NAME =~ *pps_counter_0/inst/rxom2_s1_reg* || NAME =~ *pps_counter_0/inst/txam2_s1_reg* || NAME =~ *pps_counter_0/inst/txom2_s1_reg* || NAME =~ *pps_counter_0/inst/tdf_s1_reg* || NAME =~ *pps_counter_0/inst/en_sync_reg?0? || NAME =~ *pps_counter_0/inst/clr_sync_reg?0?}]
set pps_to_rx_d [get_pins -of_objects $pps_to_rx -filter {REF_PIN_NAME == D}]
set_max_delay -datapath_only 4.000 -from $pps_sources -to $pps_to_rx_d
set_bus_skew 4.000 -from $pps_sources -to $pps_to_rx_d

# External PPS: asynchronous input to only the first synchronization stage.
set pps_first [get_cells -quiet -hier -filter {NAME =~ *pps_counter_0/inst/pps_meta_reg?0?}]
set_false_path -to [get_pins -of_objects $pps_first -filter {REF_PIN_NAME == D}]

# Only the reset release synchronizer's asynchronous assertion pins are cut.
# Its output -> counter/frame reset fanout remains timed against the RX clock.
set pps_reset_sync [get_cells -quiet -hier -filter {NAME =~ *pps_counter_0/inst/cnt_reset_sync_reg*}]
set_false_path -to [get_pins -of_objects $pps_reset_sync -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]
