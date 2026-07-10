# PlutoPlus GPS Timing Firmware

Custom firmware for the **Pluto+ (ADALM‑Pluto+ / "Pluto SDR+" clone, Zynq‑7010)** that turns it into
a **GPS‑disciplined timing source** — a stratum‑1 NTP server *and* a GPS‑disciplined RF sample clock.
Built entirely in Docker on [`sardylan/plutoplus`](https://github.com/sardylan/plutoplus) `fw‑0.39`;
no local Xilinx install is needed for the base firmware.

The repository also has a separate **LibreSDR Rev.5 (Zynq‑7020)** target. It
shares the timing/services code but uses its own pinned source cache, FPGA
overlay, Vivado 2022.2 build, and SD-card artifacts.

> ✅ **Verified on hardware.** Stratum‑1, PPS‑disciplined system clock (`chronyc tracking` →
> `Leap status: Normal`, ref `PPS`, within a few hundred ns of GPS). On the `--hwlatch` build the
> AD936x **sample clock** is also disciplined to GPS — **−7.77 ppm → +0.02 ppm**.

> ⚠️ **Read [`RECOVERY.md`](RECOVERY.md) before you flash** — the Pluto+ QSPI is *unprotected* and an
> interrupted write can brick the bootloader. Recovery is straightforward via SD‑card boot, but know
> the procedure first.

**Docs:** [Wiring](docs/WIRING.md) · [Verify/NTP serving](docs/NTP.md) · [Gotchas](docs/GOTCHAS.md) ·
[Build details](docs/BUILD.md) · [FPGA counter](hdl/pps_counter/README.md) ·
[Metrics](hdl/pps_counter/metrics/README.md) · [TDOA timing impact](docs/TDOA_TIMING.md) ·
[LibreSDR target](docs/LIBRESDR.md) ·
[LibreSDR QSPI](docs/LIBRESDR_QSPI.md) ·
[LibreSDR recovery](docs/LIBRESDR_RECOVERY.md) ·
[Networked TDOA](docs/NETWORK.md) · [GPS scheduling](docs/SCHEDULING.md) · [PPS-aligned TDD](hdl/pps_counter/TDD_PPS_DESIGN.md) ·
[ZMQ telemetry API](docs/PLUTO_ZMQ_API.md) · [ZMQ API ICD](docs/PLUTO_ZMQ_ICD.md) · [ZMQ capture-control ICD](docs/PLUTO_ZMQ_CTL_ICD.md) ·
[Roadmap](docs/ROADMAP.md) · [Recovery](RECOVERY.md) · [Changelog](CHANGELOG.md)

---

## What you get

| Feature | How |
|---|---|
| **PPS** → `/dev/pps0` | `pps-gpio` on **MIO9** (`CONFIG_PPS` + `CONFIG_PPS_CLIENT_GPIO`) |
| **GPS NMEA** → `/dev/ttyPS0` | **UART1** (MIO12/13); gpsd auto‑starts at **9600**, `-n -b` |
| **Stratum‑1 system clock** | chrony disciplines time from GPS (coarse) + **PPS** (precise) |
| **LAN NTP server** | serves GPS time to RFC1918 + IPv6 link‑local once locked — see [NTP](docs/NTP.md) |
| **Diagnostics** | `ppstest`, `gpsmon`, `cgps`, `gpspipe` |
| **Read-only telemetry over ZMQ** | `pluto_zmqd` serves timing/GPS/RF/DMA so a client can read node state **without root SSH** — autostarts at boot. See [ZMQ telemetry API](docs/PLUTO_ZMQ_API.md) |
| **GPS-anchored capture over ZMQ** | `pluto_ctld` tunes + captures PPS-gated IQ → a SigMF pair stamped with the measured GPS time of sample 0 (for multi-node TDOA) — autostarts at boot. See [capture-control ICD](docs/PLUTO_ZMQ_CTL_ICD.md) |
| **GPS‑disciplined sample clock** *(`--hwlatch`)* | FPGA `pps_counter` + `xo_correct.sh` lock the AD936x sample clock to GPS for `xo_correction`/TDOA — see [FPGA counter](hdl/pps_counter/README.md) |
| **GPS‑aligned TDD** *(`--hwlatch`, v1.4)* | `pps_counter` emits a PPS‑edge `pps_tick` that re‑anchors ADI's `axi_tdd` frame each GPS second → TX/RX windows phase‑locked to GPS across nodes. Verify with `tdd_verify.sh`; design in [PPS‑aligned TDD](hdl/pps_counter/TDD_PPS_DESIGN.md) |

**Two build variants:** the **base** firmware (`bash docker-run.sh`, no Vivado) gives everything above
except the FPGA counter; the **`--hwlatch`** firmware adds the sample‑clock counter + auto‑discipline
and rebuilds the bitstream (needs Vivado 2023.2). See [Build details](docs/BUILD.md).

## How this compares

This is a **software GPSDO built into an SDR**: it disciplines the Pluto's own TCXO sample clock to
GPS (and serves stratum‑1 NTP), rather than being a separate box that outputs a 10 MHz/1PPS reference.

| Approach | ~Cost | Discipline & stability | Holdover | GPS‑timestamped IQ (TDOA) | Stratum‑1 NTP |
|---|---|---|---|---|---|
| **This — Pluto+ + this firmware** | **$150–250** | software `xo_correction`, TCXO (~2e‑8 @1 s, ±33 ns/sample) | none | ✅ native | ✅ |
| Dedicated OCXO/Rb GPSDO (Leo Bodnar, Thunderbolt, Jackson Labs) | $100–1000+ | hardware OCXO/Rb (~1e‑11–1e‑12 @1 s) | hours–days | ❌ (outputs 10 MHz/1PPS for *other* gear) | ❌ (needs a host) |
| USRP / high‑end SDR + GPSDO option | $1000+ | hardware OCXO, locked sample clock | good | ✅ | ⚠️ via host |
| Raspberry Pi + GPS HAT | ~$60 | system clock only (no RF clock) | none | ❌ no SDR | ✅ |

**Where it wins:** one cheap, self‑contained board that is *simultaneously* a stratum‑1 NTP server
**and** an SDR whose **sample clock is referenced to GPS** — so you get sample‑accurate,
GPS‑timestamped IQ for **multi‑site TDOA** with no external GPSDO, no 10 MHz cabling, and no separate
NTP host. The firmware is fully open and reproducible.

**Where it doesn't:** it's TCXO‑class, software‑disciplined timing — short‑term stability (~2e‑8 ADEV
@1 s, ±33 ns/sample) is orders of magnitude off a lab OCXO/Rb GPSDO, and there is **no holdover**
(lose GPS → lose discipline within seconds). For lab‑grade frequency reference or GPS‑outage
ride‑through, feed an OCXO/Rb GPSDO into the Pluto+ external‑reference input instead of (or alongside)
this.

## Hardware

- **Pluto+ board** (V2 / 3V3 levels — SD slot + Ethernet ⇒ it's a Pluto+, not a stock ADALM‑Pluto).
- **GPS module** with a 3V3 UART (NMEA) + a **PPS** output (u‑blox NEO‑6M tested; NEO‑M8N/M8T better).
- **Active GPS antenna**, long cable, at a window/outside and **away from the Pluto** (the SDR
  desenses GPS L1 at close range — the #1 cause of "no lock").
- **microSD** (FAT32) for first‑time bootloader flashing / recovery — see [`RECOVERY.md`](RECOVERY.md).

## Wiring

GPS module → Pluto+ expansion header (map these **MIO numbers** to your board's header pinout):

| GPS pin | → Pluto+ | Notes |
|---|---|---|
| **PPS** | **MIO9** | rising edge → `/dev/pps0` (3.3 V is fine on MIO9) |
| **TX** (GPS out) | **MIO13** | UART1 **RX** — carries NMEA in. **#1 mistake: GPS TX must go to MIO13** |
| **RX** (GPS in) | **MIO12** | UART1 **TX** — optional (only to configure the GPS) |
| **GND** | **GND** | common ground |
| **VCC** | **3V3** | a real power rail, **not** an MIO pin |

> **Hardware PPS latch (`--hwlatch` only):** also route PPS to PL pin **F20** for ~ns timestamps — but
> F20 is **1.8 V** (bank‑35), so the 3.3 V GPS PPS **must be level‑shifted to ≤1.8 V** into F20. (MIO9
> stays 3.3 V.)

## Build

### Pluto+

```bash
bash docker-run.sh                                    # base firmware (no Vivado)
bash docker-run.sh --vivado /path/to/Xilinx --hwlatch # + FPGA sample-clock counter & discipline
```
Output lands in `./output/`: **`pluto.frm`** (flash this), `pluto.dfu`, and a release zip. (The host
`tee` pipeline may print a non‑zero exit even on success — trust the `Done.` line + `output/pluto.frm`.)
More in [Build details](docs/BUILD.md).

### LibreSDR Rev.5

LibreSDR bring-up is deliberately SD-card-only. It needs Docker Desktop, native
Vivado 2022.2, GNU Make for Windows, and a
FAT32 SD card.

```bash
# 1. Prepare the pinned LibreSDR/PlutoSDR HDL tree with this repo's overlay.
bash docker-run.sh --target libresdr --prepare-hdl
```

```powershell
# 2. Synthesize and route the FPGA image with native Windows Vivado.
.\tools\build-libresdr-hdl.ps1 `
  -VivadoRoot C:\Xilinx `
  -MakeExe C:\Xilinx\Vitis_HLS\2022.2\tps\win64\msys64\mingw64\bin\make.exe
```

The GNU Make bundled with Vitis HLS is shown above; a Cygwin installation such
as `C:\cygwin64\bin\make.exe` is also supported.
The build fails unless the AD9361 LVDS receive setup, FPGA input-path, and lane
skew constraints pass at the maximum 245.76 MHz interface clock. Calibrated
hold margin is checked on hardware with the packaged `verify_lvds.sh` PRBS test.

```bash
# 3. Build Linux, the rootfs, firmware, and staged SD files around that bitstream.
bash docker-run.sh --target libresdr \
  --prebuilt-bit output/libresdr-hdl/system_top.bit
```

```powershell
# 4. Generate BOOT.bin and SHA256SUMS.txt with Windows bootgen.
.\tools\finalize-libresdr-sd.ps1 -VivadoRoot C:\Xilinx
```

Copy the **contents** of `output/libresdr-sd/` to the FAT32 SD-card root.
Keep the known-good upstream card available for recovery and do not write QSPI
during bring-up.

After that SD image passes the complete hardware acceptance checklist, future
LibreSDR updates can be promoted to QSPI over SSH:

```powershell
python -m pip install paramiko
python flash_libresdr_qspi.py --host 192.168.1.50 --run-lvds-test --yes
```

The QSPI helper writes only `output/libre.frm` to the firmware/FIT partition; it
does not overwrite the FSBL, U-Boot, or U-Boot environment. See
[LibreSDR QSPI flashing](docs/LIBRESDR_QSPI.md) and keep the
[LibreSDR recovery ladder](docs/LIBRESDR_RECOVERY.md) handy.

> **Do not reuse a stale bitstream after an HDL change.** Changes to
> `hdl/pps_counter/`, `boards/libresdr/apply_overlay.py`, or FPGA capture/TDD
> wiring require rerunning steps 1 and 2 before the Docker firmware build.
> `boards/libresdr/validate_sd.sh` validates staged files and device-tree
> identities, but it cannot prove that an old `.bit` contains the new logic.

The detailed pinout, prerequisites, acceptance checklist, and recovery procedure
are in [LibreSDR build and bring-up](docs/LIBRESDR.md).

## Flash (normal update of a working device)

**Never power off mid‑write** — the unprotected QSPI corrupts easily.
```bash
scp output/pluto.frm root@pluto.local:/root/          # password: analog
ssh root@pluto.local 'update_frm.sh ./pluto.frm && reboot'
```
Or copy `pluto.frm` onto the `PlutoSDR` USB drive, **safely eject**, and wait for LED activity to
finish **+ ~30 s**. First boot on a fresh env: boot once with **GPS TX (MIO13) disconnected** so the
NMEA stream can't abort U‑Boot autoboot (see [Gotchas](docs/GOTCHAS.md)). Fresh/bricked boards need a
matching `boot.frm` first — [`RECOVERY.md`](RECOVERY.md).

## Verify it's working

SSH in (`ssh root@pluto.local`, password `analog`) with the GPS connected and a clear sky view.

> **✅ It's working when** `chronyc tracking` shows **Stratum 1** + **`Leap status: Normal`** — and,
> on the `--hwlatch` build, `devmem 0x7C460008 32` returns **`0x00000001`**.

Step through it; each line shows the **expected result**:

**1. Services + device nodes**
```sh
ps -ef | grep -E 'gpsd|chronyd' | grep -v grep   # -> one gpsd line + one chronyd line
ls -l /dev/pps0 /dev/ttyPS0                        # -> both nodes exist
```

**2. GPS fix** (needs sky view + ≥4 sats; can take a few minutes from cold)
```sh
gpsmon            # run BARE (gpsd owns ttyPS0). Good = sat SNRs climb into the 30s+,
                  # Status flips to 'A', Quality > 0. SNR ~0 on all sats = antenna not
                  # receiving -> see Gotchas.
```

**3. System clock disciplined** (once fixed)
```sh
ppstest /dev/pps0     # -> "assert" lines, ~one per second
chronyc sources -v    # -> the PPS line shows '*' (selected) and Reach 377
chronyc tracking      # -> Stratum: 1 | Reference ID: ...(PPS) | Leap status: Normal
```

**4. FPGA sample-clock discipline** (`--hwlatch` build only)
```sh
devmem 0x7C460000 32        # -> 0x50505343   ("PPSC" = counter present)
devmem 0x7C460008 32        # -> 0x00000001   (hardware PPS latch capturing; after GPS lock)
cat /var/log/xocorrect.log  # -> "locked, holding ... delta=30720000" (offset ~0 ppm)
```

**5. GPS-aligned TDD** (`--hwlatch` build, v1.4) — copy [`tdd_verify.sh`](hdl/pps_counter/tdd_verify.sh)
to the Pluto and run it:
```sh
scp hdl/pps_counter/tdd_verify.sh root@pluto.local:/tmp/   # password: analog
ssh root@pluto.local 'sh /tmp/tdd_verify.sh'
# -> PASS: FRAME_SEQ bounded 0..~100 and resets each PPS; axi_tdd CONTROL=0xB
```
It proves *function* (clock locked, frame re-anchors on PPS, `axi_tdd` consuming `pps_tick`). Software
reads are ms-jittery, so for nanosecond/sample precision scope a TDD channel vs PPS or two-node
cross-correlate — see [PPS-aligned TDD](hdl/pps_counter/TDD_PPS_DESIGN.md).

**No fix?** Almost always antenna/reception (SNR ≈ 0 = antenna not really receiving) — see
[Gotchas](docs/GOTCHAS.md). Serving NTP to other machines is covered in [NTP](docs/NTP.md).

## Credits & License

Built on [`sardylan/plutoplus`](https://github.com/sardylan/plutoplus) (`fw‑0.39`) and
[ADI `plutosdr-fw`](https://github.com/analogdevicesinc/plutosdr-fw); recovery method from the Pluto+
community FAQ. Glue scripts + docs in this repo: [MIT](LICENSE). Firmware components (Linux kernel,
U‑Boot, Buildroot packages) retain their own licenses (GPL, etc.).
