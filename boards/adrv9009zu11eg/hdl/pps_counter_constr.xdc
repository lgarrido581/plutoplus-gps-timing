## plutoplus-gps-timing: pps_counter on ADRV9009-ZU11EG + ADRV2CRR-FMC
##
## GPS PPS enters on PMOD0 pin 1 (pmod0_d0, FPGA AW12). ADI's carrier XDC
## already places it as LVCMOS18, so the PPS must be driven at 1.8 V.
## The pulldown makes an unplugged GPS read as "no PPS" rather than noise.
set_property PULLDOWN TRUE [get_ports pmod0_d0]

## CDC: the first stage of every pps_counter synchronizer, both directions
## between s_axi_aclk and core_clk_b (*_s1 regs, the PPS input and the CTRL
## bits). Bracket-free patterns: a TCL -filter cannot hold a bus index.
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/*_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/pps_meta_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/en_sync_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/clr_sync_reg*}]
