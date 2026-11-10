# Fishball7020 / PlutoSky R1 build and bring-up

The `fishball` target builds this firmware for the board sold as Fishball7020,
PlutoSky R1 or "7020 AD9363 SDR with PA" (XC7Z020 CLG400 + AD9363/AD9361 run as
an AD9361, 2T2R, RTL8211 gigabit Ethernet on the PS, a PA on each TX port). It is
the Pluto+ flow (sardylan fw-0.39 base, `pps_counter`, `axi_tdd`, `pluto_ctld`,
`pluto_zmqd`) with the board files in `boards/fishball/`. It does not change the
default Pluto+ target.

> This is not the PlutoSky R2 (XC7Z020 CLG484, different pinout), which this
> repository does not support. Check the FPGA marking (`XC7Z020 CLG400`) or the
> factory firmware string (`v0.38-4-g95aad`) before installing.
>
> The board boots from its SD card. Nothing in this target writes QSPI;
> `fishball.frm` is a by-product of the shared flow; do not flash it.

## What differs from the Pluto+

| | Pluto+ | Fishball7020 |
|---|---|---|
| FPGA | XC7Z010-1 CLG400 | XC7Z020-2 CLG400 |
| AD9361 interface | CMOS | LVDS (bank 34) |
| Ethernet | PS GEM0 on MIO 16..27 | the same |
| DDR | 512 MiB, 16-bit | 1 GiB, 32-bit |
| Console | UART1 MIO12/13 (given to GPS NMEA) | UART1 MIO8/9 = FTDI channel B, kept as the login console |
| SD card | card detect on MIO47 | no card detect |
| PPS input | F20 (1.8 V) + MIO9 | JP5 pin 7 (`3V3_IO1`, V10, 3.3 V), to the `pps_counter` latch and EMIO gpio 71 (`/dev/pps0`); not yet validated with a real PPS (see Time) |
| Coarse time | GPS NMEA via gpsd | LAN NTP servers from the u-boot env (no gpsd) |
| Boot | QSPI (`pluto.frm`) | SD card (`output/fishball-sd/`) |

## Vendor inputs

`boards/fishball/vendor.lock` pins two repositories and the sha256 of each file
the build takes from them:

- [Xiaozhang-code-cloud/Fish-Wan-plutosdr-fw-7020-SDR](https://github.com/Xiaozhang-code-cloud/Fish-Wan-plutosdr-fw-7020-SDR)
  at `95aad369`, the commit the factory firmware reports:
  - `system_constr.xdc`: the AD9361 pins, used as is.
  - `zynq-pluto-sdr.dtsi`, `zynq-pluto-sdr-revc.dts`: the board device tree.
    `apply_board.py` brings them to the factory `devicetree.dtb` (no clock-select
    hogs or button, 200 ppm refclk accuracy, which sets the `xo_correction`
    range), adds `pps-gpio`, and probes the transmitter at 89.75 dB attenuation
    because of the PAs.
- [OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR](https://github.com/OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR)
  (Apache-2.0), the stock SD set: `BOOT.bin` and `uEnv.txt`.
  `boards/fishball/split_boot.py` cuts the FSBL and U-Boot out of that
  `BOOT.bin`, and `make_sd.sh` repacks them around this bitstream and checks
  that both come back byte for byte. That FSBL's `ps7_init` is the board's own;
  the PS7 settings in `boards/fishball/hdl/system_bd.tcl` match the vendor
  design's.

`boards/fishball/hdl/` holds the block design (Pluto+ fw-0.39 design plus the
vendor board deltas), top level and project script.

The community [fishball7020-fpga-devkit](https://github.com/matsvandamme/fishball7020-fpga-devkit)
documents the board (JP5 pinout, boot switches, PA safety) and builds the
vendor firmware from source.

## Build

From WSL (Vivado 2023.2 at `/tools/Xilinx`; `bootgen` comes with it):

```sh
./docker-run.sh --target fishball --vivado /tools/Xilinx
```

The build uses its own source cache volume (`gps-timing-fishball-src-cache`).
Outputs:

- `output/fishball-sd/`: `BOOT.bin` (stock FSBL + this bitstream + stock U-Boot),
  `uImage`, `uramdisk.image.gz`, `devicetree.dtb`, `uEnv.txt`, `SHA256SUMS`.
- `output/fishball/system_top.bit`: the bitstream alone, for JTAG.

## Install

Over the network, onto a board that is already running (any firmware that
mounts its card as `/dev/mmcblk0p1`, including the stock one):

```sh
python tools/flash_sd.py output/fishball-sd --host <addr>
```

It backs up the card first (`output/fishball-sd-backups/`), md5-checks every
file before swapping, keeps the old set in `/prev` on the card and reboots.

With a card reader: back up the card's files, then copy the contents of
`output/fishball-sd/` to the FAT32 card root. Boot switches on SD (both off),
power off while changing them.

The board keeps its network settings in the QSPI u-boot environment, which SD
boot still reads. Set them once from the console (COM port of FTDI channel B,
115200 8N1). On a board whose environment has never been saved, `fw_setenv` from
Linux reports "Bad CRC" and writes generic defaults that stop it booting; set
them from the `Pluto>` prompt instead:

```
env default -a
setenv ipaddr_eth 192.168.x.y
setenv netmask_eth 255.255.255.0
setenv hostname fishball
setenv ntp_server "192.168.x.z"
saveenv
reset
```

## Time

`chronyd` takes its servers from `ntp_server` (space- or comma-separated) through
`/etc/init.d/S48ntpsources`, which writes `/var/run/chrony-sources/env.sources`
before chrony starts. A GPS-locked Pluto+ running this firmware is a stratum-1
server and makes a good `ntp_server`. To change servers without rebooting:

```sh
fw_setenv ntp_server "192.168.x.z"
/etc/init.d/S48ntpsources reload
chronyc sources
```

> **The PPS input is not validated on hardware yet.** The pin placement (V10,
> LVCMOS33, pull-down) is confirmed from the Vivado I/O report and `/dev/pps0`
> registers at boot, but no 1PPS has been fed to JP5 pin 7 so far. Until the
> checklist items below pass, treat cross-node timing on this board as NTP-grade.

The PPS refclock has no `lock` source: once a 3.3 V
1PPS reaches JP5 pin 7 (ground on pin 2 or 20) it numbers its pulses from the
NTP time and becomes the preferred source. JP5 pins 1, 3 and 5 are power rails
and pin 15 is the 40 MHz oscillator's tune input; do not drive them. GPS NMEA
is not wired yet.

## Bring-up checklist

- [ ] Boots to the login prompt on the FTDI console; banner says `(fishball)`.
- [ ] `eth0` links at 1000 Mb/s and answers on its configured address.
- [ ] `iio_info -u ip:<addr>` lists `ad9361-phy`, `cf-ad9361-lpc`,
      `cf-ad9361-dds-core-lpc`, `xadc` and `iio-axi-tdd-0`.
- [ ] RX loopback (TX1 → 30 dB attenuator → RX1) shows the tone at 2R2T 30.72 MS/s
      with no DMA overflow. Mind the PAs: never transmit into an open port.
- [ ] `devmem 0x7C460000` reads `0x50505343` (`pps_counter` ID); LIVE_COUNT
      (`0x7C46000C`) advances between reads.
- [ ] `chronyc sources` shows the `ntp_server` entries reachable and selected.
- [ ] With a PPS on JP5 pin 7: `ppstest /dev/pps0` sees it, STATUS bit 0
      (`0x7C460008`) is set and PPS_SEQ (`0x7C460018`) counts once a second.
- [ ] `pluto_ctld` / `pluto_zmqd` answer on :5562 / :5560.
