# ADRV9009-ZU11EG build and bring-up (experimental)

The `adrv9009zu11eg` target adds this repo's GPS `pps_counter` to ADI's
reference design for the **ADRV9009-ZU11EG RF-SOM on the ADRV2CRR-FMC carrier**
(Zynq UltraScale+ ZU11EG, two ADRV9009 on JESD204B). It does not build a
firmware image of its own: it produces a `BOOT.BIN` and a `system.dtb` that
replace the ones on an ADI Kuiper SD card. Everything is pinned to ADI HDL
`2023_R2_p1` and ADI Linux `2023_R2`, so use the Kuiper image from the 2023_R2
release.

For how the counter works and why the design looks like this, see
[`hdl/pps_counter/README.md`](../hdl/pps_counter/README.md) and the
[PPS-aligned TDD design notes](../hdl/pps_counter/TDD_PPS_DESIGN.md).

## Status

| Verified | Not yet |
|---|---|
| ADI's block design builds and validates in Vivado 2023.2 with the patch; `pps_counter` lands at `0x9C46_0000` | Synthesis and implementation: they need a license for `xczu11eg` |
| Simulation of the capture start (`sim/tb_rx_sync.v`) with SYSREF running: one latch per second, `LATCH − PPS = RX_START + 1`, first RX sample `= LATCH + 2` | Timing closure, `BOOT.BIN`, boot on hardware |
| `system.dtb` builds for the plain and `jesd204-fsm` board variants | Every step in the bring-up checklist below |

Treat this as a first hardware bring-up: expect to report back, not to ship.

## What you need

**Hardware**

- ADRV9009-ZU11EG RF-SOM on an ADRV2CRR-FMC carrier, its power supply, and a
  microSD card (16 GB or more).
- A GPS reference with **coherent 10 MHz and 1 PPS outputs**: a GPSDO, or a
  timing GPS module that outputs both. A PPS from a separate plain receiver
  also works, with about ±20 ns (±5 ticks) of jitter.
- A 3.3 V → 1.8 V buffer for the PPS, unless the carrier's PMOD connector is
  already level-translated (see Wiring).
- An Ethernet link to an NTP server (e.g. the Jetson) for the whole second.
- For latency calibration (step 7): a signal generator that can trigger on the
  PPS, attenuators, and a scope.

**Software**

- Vivado **and** Vitis **2023.2** with a license that covers `xczu11eg`
  (Enterprise, or AMD's 30-day evaluation). Linux is the recommended build
  host; the `BOOT.BIN` step only runs on Linux.
- Python 3.8+ and git.
- Docker (uses this repo's `plutoplus-gps-builder` image), or any Linux with
  `git`, `cpp` and `dtc`, for the device tree.
- The ADI Kuiper Linux SD-card image from the **2023_R2** release.

## 1. Get the code

```sh
git clone https://github.com/lgarrido581/plutoplus-gps-timing.git
cd plutoplus-gps-timing
git checkout feat/adrv9009-zu11eg
```

## 2. Build

### 2a. Check the patch and the simulation (no license)

```sh
source /tools/Xilinx/Vivado/2023.2/settings64.sh      # your install path
# Clones ADI HDL into ~/adi-hdl, patches it, packages ADI's IP (slow the first
# time), builds and validates the block design, then stops before synthesis.
python3 boards/adrv9009zu11eg/build_hdl.py --hdl ~/adi-hdl --vivado vivado --skip-synthesis
bash boards/adrv9009zu11eg/sim/run_xsim.sh ~/adi-hdl  # prints PASS tb_rx_sync
```

Logs land in `~/adi-hdl/gps-timing-logs/`.

### 2b. Bitstream (licensed machine)

```sh
python3 boards/adrv9009zu11eg/build_hdl.py --hdl ~/adi-hdl --vivado vivado
# -> ~/adi-hdl/gps-timing-out/system_top.bit and system_top.xsa
```

This runs synthesis and implementation. Expect it to take an hour or more.
If timing fails, ADI's flow stops with `Timing Constraints NOT met` and writes
`adrv9009zu11eg.sdk/system_top_bad_timing.xsa`. Don't use that file; send back
`projects/adrv9009zu11eg/adrv2crr_fmc/timing_impl.log`.

### 2c. BOOT.BIN (Linux, Vivado + Vitis 2023.2 sourced)

`bootgen_sysfiles.tgz` is in the board's folder on the Kuiper SD card's BOOT
partition (step 3 picks the folder). It holds the `u-boot.elf` and `bl31.elf`
ADI built for this board.

```sh
bash boards/adrv9009zu11eg/make_boot_bin.sh ~/adi-hdl/gps-timing-out/system_top.xsa \
    /path/to/BOOT/<folder>/bootgen_sysfiles.tgz
# -> output/zu11eg-boot/BOOT.BIN
```

### 2d. system.dtb

Build it on the **same** ADI device tree as the Kuiper folder you boot from:
`BASE` is that folder's name.

```sh
docker run --rm -v "$PWD":/w -w /w -e BASE=zynqmp-adrv9009-zu11eg-revb-adrv2crr-fmc-revb \
    plutoplus-gps-builder bash boards/adrv9009zu11eg/dts/build_dtb.sh
# -> output/zu11eg-dtb/system.dtb
```

An unknown `BASE` prints the list of valid names.

### On Windows

- `build_hdl.py` and `sim/run_xsim.ps1` work with native Windows Vivado; pass
  `--vivado C:/Xilinx/Vivado/2023.2/bin/vivado.bat`. No `make` or Cygwin is
  needed.
- Keep the HDL tree on a short path, e.g. `subst Z: C:\work\zu` and
  `--hdl Z:/hdl`. Vivado's generated IP paths exceed `MAX_PATH` otherwise.
  Remove the mapping later with `subst Z: /D`.
- Build `BOOT.BIN` on Linux.

## 3. Prepare the SD card

1. Write the Kuiper 2023_R2 image to the card. Its BOOT partition has a
   `ReadMe.txt` naming the release and explaining the board folders.
2. Choose the folder **`zynqmp-adrv9009-zu11eg-revb-adrv2crr-fmc-revb`**, or its
   `-jesd204-fsm` variant. Don't use the `sync-*` or `*fmcomms8*` folders: they
   go with different HDL builds (multi-SOM, FMCOMMS8) from the one this target
   patches.
3. Copy that folder's files to the BOOT partition root, as `ReadMe.txt`
   describes, and **boot the stock image once**. `iio_info | grep adrv9009`
   should list the radio. Without a working baseline, a failure later can't be
   pinned on this design.
4. Back up `BOOT.BIN` and `system.dtb` from the root, then replace them with
   `output/zu11eg-boot/BOOT.BIN` and `output/zu11eg-dtb/system.dtb` (built with
   the matching `BASE`).

Recovery: put the two backed-up files back.

## 4. Wiring

| Signal | Where | Level |
|---|---|---|
| GPS PPS | PMOD0 `pmod0_d0` (FPGA AW12); usually PMOD pin 1, so confirm on the ADRV2CRR-FMC schematic | **1.8 V**: ADI constrains the pin LVCMOS18 (high ≥ 1.17 V, never above 1.8 V). If the PMOD has no level translator, buffer a 3.3 V PPS down to 1.8 V |
| Ground | a PMOD GND pin | — |
| GPS-locked 10 MHz | J4 (the AD9545's reference A) | ADI's device tree sets J4 as a **DC-coupled 1.8 V single-ended** input. Read the carrier's input network on the schematic before connecting a 3.3 V square wave or a sine |

The 10 MHz path on the dev kit is J4 → AD9545 → carrier HMC7044 → SOM
HMC7044, which clocks both ADRV9009s and the FPGA's `core_clk_b`.

## 5. Bring-up on the SOM

Copy `boards/adrv9009zu11eg/som/ppsc.py` to the SOM (e.g. with `scp`). It reads
registers through `/dev/mem`, so run it with `sudo`. The capture step needs the
libiio Python bindings: check them with `python3 -c "import iio"`.

First, confirm the new design is the one running:

```sh
ls /proc/device-tree/fpga-axi@0/ | grep pps-counter   # the new system.dtb
sudo python3 ppsc.py status                            # ID 0x50505343: the new bitstream
```

| # | Do | Pass when |
|---|---|---|
| 1 | `sudo python3 ppsc.py status` | `ID` = `0x50505343` |
| 2 | PPS connected, no 10 MHz: `sudo python3 ppsc.py watch -n 30` | `PPS_SEQ` +1 per second; `PPS_DELTA` ≈ 245 760 000, off by the VCXO's error and wandering. Exit 1 ("not locked") is expected here; keep the output as the free-running baseline |
| 3 | Connect the 10 MHz. Find the clock chips with `grep . /sys/bus/iio/devices/iio:device*/name \| grep -i hmc7044`, then `sudo cat /sys/kernel/debug/iio/iio:deviceN/status` for each | Both HMC7044s report PLL1 and PLL2 locked. Then `sudo python3 ppsc.py watch -n 3600` exits 0: `PPS_DELTA` = 245 760 000 ±1 every second for an hour |
| 4 | `sudo apt install chrony` if needed. In `/etc/chrony/chrony.conf` put `server <ntp-host> iburst` and `refclock SOCK /var/run/chrony.ppsc.sock refid PPSC precision 1e-7 prefer`, restart chrony, then run `sudo python3 ppsc.py chrony` | `chronyc sources` selects `PPSC` with an offset of a few µs |
| 5 | `sudo python3 ppsc.py capture -o 0 -n 1000000`, five times | Exit 0 every time: `LATCH-PPS` = 1 tick (`RX_START + 1`), `LATCH_SEQ +1`. Also try `-o 100000` (expect 100 001) |
| 6 | Latency: feed a burst from a generator triggered by the GPSDO PPS through an attenuator into RX1; capture with `--out burst.iq`; scope the PPS against the burst at the RX input | The burst's sample index repeats to ±1 tick across captures. Record the PPS-to-sample offset for the ADRV9009 profile in use |
| 7 | Reboot 10 times (or re-initialise the JESD links), repeating step 6 each time | No jumps. A jump of tens to hundreds of ns is a multiframe step: SYSREF isn't being captured the same way each time |
| 8 | Pull the 10 MHz for 10 minutes, then pull the PPS | Without 10 MHz, `PPS_DELTA` drifts slowly in holdover and recovers when it returns. Without PPS, `PPS_SEQ` stops and the capture refuses to run |

If the Kuiper profile isn't 245.76 MSPS, `ppsc.py status` prints the measured
clock. Pass it before the subcommand, e.g. `sudo python3 ppsc.py --nominal 122880000 watch`.

## 6. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `no pps_counter at 0x9c460000`, or the board hangs on the first access | The stock `BOOT.BIN` is still the one booting (wrong folder or file not at the root). Reboot and recheck step 3 |
| No `pps-counter` under `/proc/device-tree/fpga-axi@0/` | The stock `system.dtb` is still in use |
| `PPS_SEQ` doesn't advance | Wrong PMOD pin, no shared ground, or the PPS below the 1.17 V threshold (or not buffered to 1.8 V) |
| 10 MHz connected, but `PPS_DELTA` still wanders | The reference isn't reaching the SOM's HMC7044. Check the J4 level, the AD9545 and HMC7044 lock status, and that the board's device tree includes the AD9545 |
| `IIO device axi-adrv9009-rx-hpc not found` | The JESD link didn't come up, or the `system.dtb` base doesn't match the folder. Compare `iio_info` with the stock boot |
| `capture` times out | The RX core never saw the window edge. Check `TDD_CTRL` is 7 during the capture, and that the device has a `sync_start_enable` attribute (`iio_attr -d axi-adrv9009-rx-hpc`) |
| `LATCH-PPS` isn't `RX_START + 1` | Note the value and the `-o` used; it should be constant for a given offset |
| `Timing Constraints NOT met` | Send `timing_impl.log`. CDC paths inside `pps_counter_0` should be covered by `pps_counter_constr.xdc` |

## 7. What to send back

- The branch commit, the Kuiper release, and the folder (`BASE`) used.
- From the build: `timing_impl.log`, or at least the WNS/WHS line.
- `ppsc.py status` output.
- The summary lines of `watch` from steps 2 and 3, and the HMC7044 `status`
  output.
- Five `capture` outputs from step 5.
- `chronyc sources -v` and `chronyc tracking` from step 4.
- The latency number from step 6, with the ADRV9009 profile.

## Design notes

| | Pluto+ | ADRV9009-ZU11EG |
|---|---|---|
| Counter clock | `axi_ad9361/l_clk` | `core_clk_b`, the RX JESD link clock (245.76 MHz in ADI's default profile: about 4.07 ns and one IQ sample per tick) |
| Capture start | PPS window ORed into the RX DMA `sync` | `pps_rx_sync_mux` in front of the RX transport core's `adc_sync_in`: the PPS window while a GPS capture is armed, SYSREF (ADI's original source) otherwise |
| DMA-start latch | the OR output | the mux output; the RX core's first valid sample is 2 ticks after `LATCH_COUNT` |
| Registers | `0x7C46_0000` | same HDL address; Linux sees **`0x9C46_0000`** (ADI's ZynqMP remap) |
| PPS input | F20 | PMOD0 `pmod0_d0` (FPGA AW12, LVCMOS18), also EMIO GPIO 90 |
| Clock discipline | `xo_correct.sh` → `xo_correction` | in hardware, through the GPS 10 MHz. `PPS_DELTA` becomes the lock monitor |
| Linux time | `pps-gpio` + chrony | `ppsc.py chrony` feeds the FPGA counter to chrony as a SOCK refclock (ADI's kernel lacks `pps-gpio`); NTP gives the whole second |

- `TDD_CTRL = 0` returns the RX core's start to SYSREF, so ADI's multi-SOM
  start and normal streaming are unchanged. `ppsc.py capture` restores it after
  each capture.
- The 32-bit counter wraps every 17.5 s at 245.76 MHz. That's fine for the
  capture math (a signed difference against the latest PPS), but a continuous
  pulse-descriptor stream needs a 64-bit time-of-day; that extension is
  proposed, not built.
- Custom carriers that use only the SOM's HMC7044 need the reference on one of
  its CLKIN pins and a matching device tree; that's outside this target.

Files:

| Path | Purpose |
|---|---|
| `hdl/pps_counter/pps_counter.v` | shared RTL; gains a `tdd_armed` output and explicit AXI interface attributes (no logic change for Pluto+/LibreSDR) |
| `boards/adrv9009zu11eg/hdl/pps_rx_sync_mux.v` | the RX sync source mux |
| `boards/adrv9009zu11eg/hdl/pps_counter_constr.xdc` | PPS pulldown and CDC false paths |
| `boards/adrv9009zu11eg/apply_hdl_patch.py` | patches ADI's project (block design, top level, constraints) |
| `boards/adrv9009zu11eg/build_hdl.py` | clone, patch, package ADI IP, build; `--skip-synthesis` needs no license |
| `boards/adrv9009zu11eg/sim/` | `tb_rx_sync.v`, with `run_xsim.sh` (Linux) and `run_xsim.ps1` (Windows) |
| `boards/adrv9009zu11eg/dts/` | `gps.dtsi` and `build_dtb.sh` |
| `boards/adrv9009zu11eg/make_boot_bin.sh` | `BOOT.BIN` from the new `.xsa` via ADI's script |
| `boards/adrv9009zu11eg/som/ppsc.py` | on-SOM register tool, lock watch, gated capture, chrony feeder |
