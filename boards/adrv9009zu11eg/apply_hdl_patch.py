#!/usr/bin/env python3
"""Add the GPS pps_counter to ADI's ADRV9009-ZU11EG + ADRV2CRR-FMC HDL project.

Usage: apply_hdl_patch.py <adi-hdl-root> [<plutoplus-gps-timing-root>]

Pinned to ADI HDL tag 2023_R2_p1 (Vivado 2023.2). The script fails when an
upstream anchor changes: a silently half-patched block design is much harder
to diagnose than a stopped build. Running it twice is safe.

What it changes (see docs/ADRV9009_ZU11EG.md):
  * pps_counter on core_clk_b (the RX link clock that also clocks the RX
    TPL, cpack and the RX DMA), AXI at 0x7C46_0000 (Linux sees 0x9C46_0000).
  * GPS PPS on PMOD0 pin 1 (pmod0_d0 = gpio_i[12], also EMIO GPIO 90 for
    Linux pps-gpio).
  * pps_rx_sync_mux in front of the RX TPL's adc_sync_in: the PPS window
    while a GPS capture is armed, SYSREF (ADI's original source) otherwise.
    The same signal triggers the DMA-start latch.
"""
from pathlib import Path
import shutil
import sys

MARKER = "plutoplus-gps-timing"

HDL_ROOT = Path(sys.argv[1]).absolute()   # not resolve(): keep a subst drive
REPO = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else \
    Path(__file__).resolve().parents[2]
BOARD = Path(__file__).resolve().parent
PROJ = HDL_ROOT / "projects/adrv9009zu11eg"
COMMON = PROJ / "common"
CARRIER = PROJ / "adrv2crr_fmc"


def replace_once(path: Path, old: str, new: str) -> None:
    data = path.read_text()
    if new in data:
        return                                   # already applied
    if data.count(old) != 1:
        raise SystemExit(f"patch anchor not found exactly once in {path}:\n  {old[:90]!r}")
    path.write_text(data.replace(old, new, 1))


if not (COMMON / "adrv9009zu11eg_bd.tcl").exists():
    raise SystemExit(f"not an ADI HDL tree with projects/adrv9009zu11eg: {HDL_ROOT}")

# ---- sources -------------------------------------------------------------
shutil.copy2(REPO / "hdl/pps_counter/pps_counter.v", COMMON / "pps_counter.v")
shutil.copy2(BOARD / "hdl/pps_rx_sync_mux.v", COMMON / "pps_rx_sync_mux.v")
shutil.copy2(BOARD / "hdl/pps_counter_constr.xdc", COMMON / "pps_counter_constr.xdc")

# ---- block design: replace ADI's SYSREF -> adc_sync_in with the mux -------
bd = COMMON / "adrv9009zu11eg_bd.tcl"
replace_once(
    bd,
    "ad_connect  rx_adrv9009_som_tpl_core/adc_tpl_core/adc_sync_in rx_sysref_0\n",
    f"""# --- {MARKER}: GPS PPS counter + PPS-anchored RX start ---
add_files -norecurse $ad_hdl_dir/projects/adrv9009zu11eg/common/pps_counter.v
add_files -norecurse $ad_hdl_dir/projects/adrv9009zu11eg/common/pps_rx_sync_mux.v
create_bd_port -dir I pps_ext
create_bd_cell -type module -reference pps_counter pps_counter_0
create_bd_cell -type module -reference pps_rx_sync_mux pps_rx_sync_mux_0
ad_connect core_clk_b pps_counter_0/cnt_clk
ad_connect sys_cpu_resetn pps_counter_0/cnt_resetn
ad_connect pps_ext pps_counter_0/pps_in
ad_connect pps_counter_0/tdd_armed pps_rx_sync_mux_0/armed
ad_connect pps_counter_0/tdd_enable pps_rx_sync_mux_0/window
ad_connect rx_sysref_0 pps_rx_sync_mux_0/sysref
ad_connect pps_rx_sync_mux_0/sync_out rx_adrv9009_som_tpl_core/adc_tpl_core/adc_sync_in
ad_connect pps_rx_sync_mux_0/sync_out pps_counter_0/latch_trig
# --- end {MARKER} ---
""",
)
replace_once(
    bd,
    "ad_cpu_interconnect 0x7c440000 axi_adrv9009_som_obs_dma\n",
    "ad_cpu_interconnect 0x7c440000 axi_adrv9009_som_obs_dma\n"
    f"ad_cpu_interconnect 0x7c460000 pps_counter_0 ;# {MARKER}: Linux sees 0x9C460000\n",
)

# ---- top level: PMOD0 pin 1 (gpio_i[12]) into the block design -----------
replace_once(
    CARRIER / "system_top.v",
    "    .core_clk_b(core_clk_b),\n",
    "    .core_clk_b(core_clk_b),\n"
    f"    .pps_ext (gpio_i[12]),            // {MARKER}: GPS PPS on pmod0_d0\n",
)

# ---- constraints ---------------------------------------------------------
replace_once(
    CARRIER / "system_project.tcl",
    '  "../common/adrv2crr_fmc_constr.xdc" \\\n',
    '  "../common/adrv2crr_fmc_constr.xdc" \\\n'
    f'  "../common/pps_counter_constr.xdc" \\\n',
)

print(f"[INFO] {MARKER}: patched {PROJ} (pps_counter @ 0x9C460000, PPS on pmod0_d0)")
