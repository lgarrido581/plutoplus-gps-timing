# ADRV9009-ZU11EG build and bring-up (experimental)

The `adrv9009zu11eg` target adds this repo's GPS `pps_counter` to ADI's
reference design for the **ADRV9009-ZU11EG RF-SOM on the ADRV2CRR-FMC carrier**
(Zynq UltraScale+ ZU11EG, two ADRV9009 on JESD204B). It does not replace the
Pluto+ or LibreSDR targets, and unlike them it builds no firmware image of its
own: it produces a `BOOT.BIN` and a `system.dtb` that replace the ones on an
ADI Kuiper SD card.

> **Status:** block design validated in Vivado 2023.2, capture-start RTL
> verified in simulation, `system.dtb` built. **Not yet synthesized or run on
> hardware**: synthesis for `xczu11eg` needs a Vivado Enterprise (or
> evaluation) license. Pinned to ADI HDL `2023_R2_p1` / ADI Linux `2023_R2`,
> so use a Kuiper 2023_R2 SD card.

## What it adds

| | Pluto+ | ADRV9009-ZU11EG |
|---|---|---|
| Counter clock | `axi_ad9361/l_clk` | `core_clk_b`, the RX JESD link clock (245.76 MHz in ADI's default profile: about 4.07 ns and one IQ sample per tick) |
| Capture start | PPS window ORed into the RX DMA `sync` | `pps_rx_sync_mux` in front of the RX transport core's `adc_sync_in`: the PPS window while a GPS capture is armed, SYSREF (ADI's original source) otherwise |
| DMA-start latch | the OR output | the mux output; the RX core's first valid sample is 2 ticks after `LATCH_COUNT` |
| Registers | `0x7C46_0000` | same HDL address; Linux sees **`0x9C46_0000`** (ADI's ZynqMP remap) |
| PPS input | F20 | PMOD0 pin 1 (`pmod0_d0`, FPGA AW12, **LVCMOS18**), also EMIO GPIO 90 |
| Clock discipline | `xo_correct.sh` → `xo_correction` | in hardware: a GPS 10 MHz into the carrier's clock tree (J4 → AD9545 → HMC7044s). `PPS_DELTA` becomes the lock monitor |
| Linux time | `pps-gpio` + chrony | `ppsc.py chrony` feeds the FPGA counter to chrony (ADI's kernel lacks `pps-gpio`); NTP gives the whole second |

Files:

| Path | Purpose |
|---|---|
| `hdl/pps_counter/pps_counter.v` | shared RTL; gains a `tdd_armed` output (unused on Pluto+/LibreSDR) |
| `boards/adrv9009zu11eg/hdl/pps_rx_sync_mux.v` | the RX sync source mux |
| `boards/adrv9009zu11eg/hdl/pps_counter_constr.xdc` | PPS pulldown and CDC false paths |
| `boards/adrv9009zu11eg/apply_hdl_patch.py` | patches ADI's project (block design, top level, constraints) |
| `boards/adrv9009zu11eg/build_hdl.py` | clone, patch, package ADI IP, build; `--skip-synthesis` needs no license |
| `boards/adrv9009zu11eg/sim/` | `tb_rx_sync.v` + `run_xsim.ps1` |
| `boards/adrv9009zu11eg/dts/` | `system.dtb` source and `build_dtb.sh` |
| `boards/adrv9009zu11eg/make_boot_bin.sh` | `BOOT.BIN` from the new `.xsa` via ADI's script |
| `boards/adrv9009zu11eg/som/ppsc.py` | on-SOM register tool, lock watch, gated capture, chrony feeder |

## Build

Vivado 2023.2 (ADI's `2023_R2` requirement). On Windows, keep the HDL tree on a
short path, e.g. `subst Z: C:\some\dir`; Vivado's generated IP paths exceed
`MAX_PATH` otherwise.

```sh
# 1. Check the patch: builds and validates the block design. No license needed.
python boards/adrv9009zu11eg/build_hdl.py --hdl Z:/hdl \
    --vivado F:/Xilinx/Vivado/2023.2/bin/vivado.bat --skip-synthesis

# 2. Simulate the capture-start path (Vivado simulator, no license).
powershell boards/adrv9009zu11eg/sim/run_xsim.ps1 -Hdl Z:\hdl -VivadoBin F:\Xilinx\Vivado\2023.2\bin

# 3. Full build on a machine licensed for xczu11eg -> gps-timing-out/system_top.{bit,xsa}
python boards/adrv9009zu11eg/build_hdl.py --hdl <hdl> --vivado <vivado>

# 4. BOOT.BIN (Linux, Vivado + Vitis 2023.2 sourced). bootgen_sysfiles.tgz is in
#    the board's folder on the Kuiper SD card's BOOT partition.
bash boards/adrv9009zu11eg/make_boot_bin.sh <hdl>/gps-timing-out/system_top.xsa bootgen_sysfiles.tgz

# 5. system.dtb
docker run --rm -v "$PWD":/w -w /w plutoplus-gps-builder \
    bash boards/adrv9009zu11eg/dts/build_dtb.sh
```

Install: set up a Kuiper 2023_R2 SD card for this board as Kuiper's README
describes (the files from the `zynqmp-adrv9009-zu11eg-revb-adrv2crr-fmc-revb`
folder go to the BOOT partition root). Then back up and replace `BOOT.BIN` and
`system.dtb` at the root. Recovery is restoring those two files.

## Wiring

| Signal | Where | Level |
|---|---|---|
| GPS PPS | PMOD0 pin 1 (`pmod0_d0`) | **1.8 V**: ADI constrains the pin LVCMOS18. Check the carrier schematic for a PMOD level translator; if there is none, buffer a 3.3 V PPS down to 1.8 V |
| GPS-locked 10 MHz | J4 (AD9545 reference A) | ADI's device tree configures J4 as a **DC-coupled 1.8 V single-ended** input. Read the carrier's input network before connecting a 3.3 V square wave or a sine |
| Ground | PMOD GND | — |

Use a GPSDO, or a timing GPS whose PPS and 10 MHz are coherent. A PPS from a
separate receiver works, but its jitter (about ±20 ns for a plain u-blox) is
roughly ±5 ticks at 245.76 MHz.

## Bring-up checklist

Copy `som/ppsc.py` to the SOM and run it as root.

| # | Do | Pass when |
|---|---|---|
| 1 | `ppsc.py status` | `ID` = `0x50505343` |
| 2 | PPS connected, no 10 MHz: `ppsc.py watch -n 30` | `PPS_SEQ` +1 per second; `PPS_DELTA` ≈ 245 760 000, off by the VCXO's error and wandering (exit 1 is expected: not locked) |
| 3 | 10 MHz into J4; confirm the AD9545 and both HMC7044s report lock (`cat /sys/kernel/debug/iio/iio:deviceN/status` for each HMC7044) | `ppsc.py watch -n 3600` exits 0: `PPS_DELTA` = 245 760 000 ±1 every second |
| 4 | chrony: `server <ntp-host> iburst` + `refclock SOCK /var/run/chrony.ppsc.sock refid PPSC precision 1e-7 prefer`, then run `ppsc.py chrony` | `chronyc sources` selects `PPSC` with an offset of a few µs |
| 5 | `ppsc.py capture -o 0 -n 1000000` | exit 0: `LATCH-PPS` = 1 tick (`RX_START + 1`), `LATCH_SEQ +1` |
| 6 | Latency: a burst from a generator triggered by the GPSDO PPS, through an attenuator into RX; scope PPS against the burst at the RX input | the burst's position in the capture repeats to ±1 tick; record it per ADRV9009 profile |
| 7 | Reboot 10× and re-initialise the JESD links 10×, repeating 6 | no jumps (a jump of tens to hundreds of ns is a multiframe step: SYSREF isn't captured the same way each time) |
| 8 | Pull the 10 MHz for 10 min, then pull the PPS | `PPS_DELTA` drifts slowly in holdover and recovers; with no PPS the frame counter free-runs |

## Notes

- The mux returns the RX core's start to SYSREF whenever `TDD_CTRL` is 0, so
  ADI's multi-SOM start and normal streaming are unchanged; `ppsc.py capture`
  restores it after each capture.
- A 32-bit counter at 245.76 MHz wraps every 17.5 s. That is fine for the
  capture math (signed difference against the latest PPS) but a continuous
  pulse-descriptor stream needs a 64-bit time-of-day; that extension is a
  proposal, not built.
- Custom carriers that use only the SOM's HMC7044 need the reference on one of
  its CLKIN pins and a matching device tree; that work is out of scope here.
