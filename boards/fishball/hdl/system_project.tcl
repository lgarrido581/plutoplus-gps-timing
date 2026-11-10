###############################################################################
## Copyright (C) 2014-2023 Analog Devices, Inc. All rights reserved.
### SPDX short identifier: ADIBSD
###############################################################################
## Fishball7020 / PlutoSky R1 (XC7Z020 CLG400): the Pluto project on this board.
## The -2 speed grade is the vendor design's (Fish-Wan @ 95aad369). Pin
## constraints are the vendor's system_constr.xdc, pinned in
## boards/fishball/vendor.lock and installed by boards/fishball/apply_board.py.

source ../../scripts/adi_env.tcl
source $ad_hdl_dir/projects/scripts/adi_project_xilinx.tcl
source $ad_hdl_dir/projects/scripts/adi_board.tcl

adi_project_create pluto 0 {} "xc7z020clg400-2"

adi_project_files pluto [list \
  "system_top.v" \
  "system_constr.xdc" \
  "$ad_hdl_dir/library/common/ad_iobuf.v"]

set_property is_enabled false [get_files  *system_sys_ps7_0.xdc]
adi_project_run pluto
source $ad_hdl_dir/library/axi_ad9361/axi_ad9361_delay.tcl
