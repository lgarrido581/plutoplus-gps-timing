# LibreSDR Rev.5 AD9361 source-synchronous LVDS timing.
#
# At the maximum 2R2T sample rate (61.44 MSPS), AD9361 DATA_CLK is 245.76 MHz
# and transfers data on both edges. ADI AN-1441 specifies RX_DATA/RX_FRAME
# clock-to-output delay tDDRX/tDDDV = 0.25 ns minimum, 1.25 ns maximum.
#
# LibreSDR PCB clock-to-data trace skew is not published. These constraints
# explicitly assume zero inter-signal PCB skew; hardware PRBS analysis validates
# the aggregate AD9361 + PCB + FPGA timing eye. Replace the values below with
# characterized board limits if trace or measurement data becomes available.

set rx_lvds_inputs [get_ports {
  rx_data_in_p[*] rx_data_in_n[*]
  rx_frame_in_p rx_frame_in_n
}]

# Model the uncalibrated AD9361 clock-to-data limits for setup analysis on both
# halves of the DDR interface.
set_input_delay -clock rx_clk -min 0.250 $rx_lvds_inputs
set_input_delay -clock rx_clk -max 1.250 $rx_lvds_inputs
set_input_delay -clock rx_clk -clock_fall -add_delay -min 0.250 $rx_lvds_inputs
set_input_delay -clock rx_clk -clock_fall -add_delay -max 1.250 $rx_lvds_inputs

# AN-1441 allows either DATA_CLK half-cycle to shrink to 45% of 4.069 ns.
# A 0.204 ns setup uncertainty covers the difference from an ideal 50% duty
# cycle. Same-edge internal hold paths do not depend on external duty cycle.
set_clock_uncertainty -setup 0.204 [get_clocks rx_clk]

# axi_ad9361 deliberately calibrates this link before registering the RX IIO
# device: Linux sweeps the AD9361 clock/data delay and each FPGA IDELAY tap.
# A static hold check at the bitstream's reset tap therefore does not describe
# the operating circuit. Exempt only the external-port -> RX IDDR hold paths,
# and replace that check with explicit FPGA path/skew budgets plus the runtime
# 16x16 PRBS margin test in verify_lvds.sh.
set rx_lvds_iddr_d [get_pins -hier -filter {
  NAME =~ *axi_ad9361*/i_dev_if/*i_rx_data_iddr/D
}]

set_false_path -hold -from $rx_lvds_inputs -to $rx_lvds_iddr_d

# Keep the raw FPGA input paths short and mutually matched so the combined
# AD9361 + FPGA programmable-delay range can center the eye. Vivado includes
# the 1.25 ns external input delay in this datapath-only requirement, leaving
# a 2.00 ns FPGA IBUFDS + IDELAY routing budget. Vivado 2022.2 does not
# support set_bus_skew on primary-input paths, so validate_lvds_timing.tcl
# explicitly measures and enforces a 0.200 ns post-route lane-delay spread.
set_max_delay 3.250 -datapath_only \
  -from $rx_lvds_inputs -to $rx_lvds_iddr_d
