#!/usr/bin/env python3
"""Apply the LibreSDR GPS timing HDL/Linux overlay to a prepared v0.38 tree.

This script deliberately fails when an upstream anchor changes. Silent partial
Vivado designs are much harder to diagnose than a stopped, pinned build.
"""
from pathlib import Path
import shutil
import sys
import re

ROOT = Path(sys.argv[1]).resolve()
ASSETS = Path(sys.argv[2]).resolve()
BOARD_ASSETS = Path(__file__).resolve().parent
HDL = ROOT / "hdl/projects/libre"


def replace(path: Path, old: str, new: str) -> None:
    data = path.read_text()
    if old not in data:
        raise SystemExit(f"overlay anchor missing in {path}: {old[:80]!r}")
    path.write_text(data.replace(old, new, 1))


def append_once(path: Path, marker: str, text: str) -> None:
    data = path.read_text()
    if marker not in data:
        path.write_text(data.rstrip() + "\n\n" + text.rstrip() + "\n")


def set_kconfig(path: Path, values: dict[str, bool]) -> None:
    data = path.read_text()
    for symbol, enabled in values.items():
        data = re.sub(rf"^{symbol}=.*\n", "", data, flags=re.MULTILINE)
        data = re.sub(rf"^# {symbol} is not set\n", "", data, flags=re.MULTILINE)
        data = data.rstrip() + "\n" + (
            f"{symbol}=y\n" if enabled else f"# {symbol} is not set\n"
        )
    path.write_text(data)


# ---- top-level ports: reclaim expansion SPI K14/J14 for GPS UART ----
top = HDL / "system_top.v"
replace(
    top,
    """  output          pl_spi_clk_o,
  output          pl_spi_mosi,
  input           pl_spi_miso
""",
    """  input           gps_pps,
  input           gps_uart_rx,
  output          gps_uart_tx
""",
)
replace(
    top,
    "  assign gpio_i[16:14] = gpio_o[16:14];",
    """  assign gpio_i[16:14] = gpio_o[16:14];
  // Zynq GPIO numbers 54..78 are EMIO[0..24]; PPS is GPIO 71.
  assign gpio_i[24:17] = {7'b0, gps_pps};""",
)
replace(
    top,
    """    .spi_clk_i(1'b0),
    .spi_clk_o(pl_spi_clk_o),
    .spi_csn_i(1'b1),
    .spi_csn_o(),
    .spi_sdi_i(pl_spi_miso),
    .spi_sdo_i(1'b0),
    .spi_sdo_o(pl_spi_mosi),
""",
    """    .gps_pps (gps_pps),
    .gps_uart_rx (gps_uart_rx),
    .gps_uart_tx (gps_uart_tx),
""",
)

# ---- block design ----
bd = HDL / "system_bd.tcl"
replace(
    bd,
    "source $ad_hdl_dir/projects/common/xilinx/adi_fir_filter_bd.tcl",
    """source $ad_hdl_dir/projects/common/xilinx/adi_fir_filter_bd.tcl
source $ad_hdl_dir/library/axi_tdd/scripts/axi_tdd.tcl
add_files -norecurse $ad_hdl_dir/projects/libre/pps_counter.v
update_compile_order -fileset sources_1""",
)
replace(
    bd,
    """create_bd_port -dir I spi_sdi_i
""",
    """create_bd_port -dir I spi_sdi_i

create_bd_port -dir I gps_pps
create_bd_port -dir I gps_uart_rx
create_bd_port -dir O gps_uart_tx
""",
)
replace(
    bd,
    """ad_ip_instance axi_quad_spi axi_spi
ad_ip_parameter axi_spi CONFIG.C_USE_STARTUP 0
ad_ip_parameter axi_spi CONFIG.C_NUM_SS_BITS 1
ad_ip_parameter axi_spi CONFIG.C_SCK_RATIO 8
""",
    """ad_ip_instance axi_quad_spi axi_spi
ad_ip_parameter axi_spi CONFIG.C_USE_STARTUP 0
ad_ip_parameter axi_spi CONFIG.C_NUM_SS_BITS 1
ad_ip_parameter axi_spi CONFIG.C_SCK_RATIO 8

# GPS UART on expansion pins. AXI UART Lite avoids changing the PS/FSBL setup.
ad_ip_instance axi_uartlite gps_uart
ad_ip_parameter gps_uart CONFIG.C_BAUDRATE 9600
ad_ip_parameter gps_uart CONFIG.C_DATA_BITS 8
ad_ip_parameter gps_uart CONFIG.C_USE_PARITY 0
ad_connect gps_uart_rx gps_uart/rx
ad_connect gps_uart/tx gps_uart_tx
""",
)
replace(
    bd,
    "ad_cpu_interconnect 0x7C430000 axi_spi",
    """ad_cpu_interconnect 0x7C430000 axi_spi
ad_cpu_interconnect 0x40600000 gps_uart
ad_cpu_interconnect 0x7C440000 axi_tdd_0
ad_cpu_interconnect 0x7C460000 pps_counter_0""",
)
replace(
    bd,
    "ad_cpu_interrupt ps-11 mb-11 axi_spi/ip2intc_irpt",
    """ad_cpu_interrupt ps-11 mb-11 axi_spi/ip2intc_irpt
ad_cpu_interrupt ps-10 mb-10 gps_uart/interrupt""",
)
replace(
    bd,
    "ad_connect  axi_ad9361/tdd_sync GND",
    """ad_connect  axi_ad9361/tdd_sync GND

# GPS sample counter and PPS-anchored DMA gating.
create_bd_cell -type module -reference pps_counter pps_counter_0
ad_connect axi_ad9361/l_clk pps_counter_0/cnt_clk
ad_connect gps_pps pps_counter_0/pps_in

set TDD_CHANNEL_CNT 3
set TDD_DEFAULT_POL 0b010
set TDD_REG_WIDTH 32
set TDD_BURST_WIDTH 32
set TDD_SYNC_WIDTH 0
set TDD_SYNC_INT 0
set TDD_SYNC_EXT 1
set TDD_SYNC_EXT_CDC 1
ad_tdd_gen_create axi_tdd_0 $TDD_CHANNEL_CNT $TDD_DEFAULT_POL \
  $TDD_REG_WIDTH $TDD_BURST_WIDTH $TDD_SYNC_WIDTH $TDD_SYNC_INT \
  $TDD_SYNC_EXT $TDD_SYNC_EXT_CDC

ad_ip_instance util_vector_logic gps_tdd_reset_inv [list C_OPERATION {not} C_SIZE 1]
ad_connect axi_ad9361/rst gps_tdd_reset_inv/Op1
ad_connect gps_tdd_reset_inv/Res axi_tdd_0/resetn
ad_connect gps_tdd_reset_inv/Res pps_counter_0/cnt_resetn
ad_connect axi_ad9361/l_clk axi_tdd_0/clk
ad_connect pps_counter_0/pps_tick axi_tdd_0/sync_in

# Streaming uses axi_tdd channel 1 full-open. A coincident capture disables
# axi_tdd and drives the PPS-reset pps_counter window instead.
ad_ip_instance util_vector_logic gps_dma_sync_or [list C_OPERATION {or} C_SIZE 1]
ad_connect axi_tdd_0/tdd_channel_1 gps_dma_sync_or/Op1
ad_connect pps_counter_0/tdd_enable gps_dma_sync_or/Op2
ad_connect gps_dma_sync_or/Res axi_ad9361_adc_dma/fifo_wr_sync
ad_connect gps_dma_sync_or/Res pps_counter_0/latch_trig
""",
)
replace(
    bd,
    "ad_ip_parameter axi_ad9361_adc_dma CONFIG.SYNC_TRANSFER_START 0",
    "ad_ip_parameter axi_ad9361_adc_dma CONFIG.SYNC_TRANSFER_START 1",
)
replace(
    bd,
    "ad_connect  axi_ad9361/rst tx_upack/reset",
    """# Channel 2 gates the TX unpack path exactly as the ADI Pluto design does.
ad_ip_instance util_vector_logic gps_tx_reset_or [list C_OPERATION {or} C_SIZE 1]
ad_connect axi_ad9361/rst gps_tx_reset_or/Op1
ad_connect axi_tdd_0/tdd_channel_2 gps_tx_reset_or/Op2
ad_connect gps_tx_reset_or/Res tx_upack/reset""",
)

shutil.copy2(ASSETS / "pps_counter.v", HDL / "pps_counter.v")
shutil.copy2(BOARD_ASSETS / "libresdr_lvds_timing.xdc",
             HDL / "libresdr_lvds_timing.xdc")
shutil.copy2(BOARD_ASSETS / "validate_lvds_timing.tcl",
             HDL / "validate_lvds_timing.tcl")

# Keep the upstream implementation strategy. A design-wide Performance_Explore
# override can move the source-synchronous AD9361 input clock relative to its
# data paths. Timing closure for the GPS additions must be solved on the actual
# failing paths, not by changing the routing strategy for the whole design.
project_tcl = HDL / "system_project.tcl"
replace(
    project_tcl,
    """  "system_constr.xdc" \\
  "$ad_hdl_dir/library/common/ad_iobuf.v"]""",
    """  "system_constr.xdc" \\
  "libresdr_lvds_timing.xdc" \\
  "$ad_hdl_dir/library/common/ad_iobuf.v"]""",
)
replace(
    project_tcl,
    "source $ad_hdl_dir/library/axi_ad9361/axi_ad9361_delay.tcl",
    """source $ad_hdl_dir/library/axi_ad9361/axi_ad9361_delay.tcl
source $ad_hdl_dir/projects/libre/validate_lvds_timing.tcl""",
)

# ---- constraints ----
xdc = HDL / "system_constr.xdc"
replace(
    xdc,
    """set_property  -dict {PACKAGE_PIN  K14  IOSTANDARD LVCMOS33} [get_ports pl_spi_clk_o]
set_property  -dict {PACKAGE_PIN  J14  IOSTANDARD LVCMOS33} [get_ports pl_spi_miso]
set_property  -dict {PACKAGE_PIN  N15  IOSTANDARD LVCMOS33} [get_ports pl_spi_mosi]
""",
    """# LibreSDR GPS header: bank 35 is powered at 3.3 V.
set_property -dict {PACKAGE_PIN G15 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports gps_pps]
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33} [get_ports gps_uart_rx]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports gps_uart_tx]
""",
)
replace(
    xdc,
    "create_clock -period 8.000 -name rx_clk [get_ports rx_clk_in_p]",
    """# AD9361 DATA_CLK reaches 245.76 MHz in LVDS 2R2T mode at 61.44 MSPS.
# The data/frame input delays and duty-cycle margin are in libresdr_lvds_timing.xdc.
create_clock -period 4.069 -name rx_clk [get_ports rx_clk_in_p]""",
)
append_once(
    xdc,
    "# ---- LibreSDR GPS timing CDC ----",
    """# ---- LibreSDR GPS timing CDC ----
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/gray_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/ppsc_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/ppsd_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/ppss_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/en_sync_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/clr_sync_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/pps_meta_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/lc_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/lseq_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/fgray_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/fseq_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/flen_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/txa_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/txo_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/rxa_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/rxo_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/tdc_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/flenm2_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/rxam2_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/rxom2_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/txam2_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/txom2_s1_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *pps_counter_0/inst/tdf_s1_reg*}]""",
)

# ---- Linux ----
cfg = ROOT / "linux/arch/arm/configs/zynq_libre_defconfig"
append_once(cfg, "# LibreSDR GPS timing", "# LibreSDR GPS timing")
set_kconfig(cfg, {
    "CONFIG_SERIAL_UARTLITE": True,
    "CONFIG_SERIAL_UARTLITE_CONSOLE": False,
    "CONFIG_PPS": True,
    "CONFIG_PPS_CLIENT_GPIO": True,
    "CONFIG_ADI_AXI_TDD": True,
    "CONFIG_CF_AXI_TDD": False,
})

dtsi = ROOT / "linux/arch/arm/boot/dts/zynq-libre.dtsi"
append_once(
    dtsi,
    "gps_uart: serial@40600000",
    """
/ {
	gps_pps {
		compatible = "pps-gpio";
		gpios = <&gpio0 71 GPIO_ACTIVE_HIGH>;
		status = "okay";
	};
};

&fpga_axi {
		gps_uart: serial@40600000 {
			compatible = "xlnx,xps-uartlite-1.00.a";
			reg = <0x40600000 0x10000>;
			interrupt-parent = <&intc>;
			interrupts = <0 54 IRQ_TYPE_LEVEL_HIGH>;
			clocks = <&clkc 15>;
			clock-names = "s_axi_aclk";
			current-speed = <9600>;
			status = "okay";
		};

		axi_tdd_0: tdd@7c440000 {
			compatible = "adi,axi-tdd";
			reg = <0x7c440000 0x10000>;
			clocks = <&clkc 15>, <&adc0_ad9364 13>;
			clock-names = "s_axi_aclk", "intf_clk";
			status = "okay";
		};

		pps_counter_0: pps-counter@7c460000 {
			compatible = "gps-timing,pps-counter-1.0";
			reg = <0x7c460000 0x10000>;
			status = "okay";
		};
};""",
)

print("LibreSDR GPS timing overlay applied")
