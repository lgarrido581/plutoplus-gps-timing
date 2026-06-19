# PlutoPlus GPS Timing Firmware

Custom firmware for the **Pluto+ (ADALM‑Pluto+ / "Pluto SDR+" clone, Zynq‑7010)** that turns it into
a **GPS‑disciplined timing source** — a stratum‑1 NTP server *and* a GPS‑disciplined RF sample clock.
Built entirely in Docker on [`sardylan/plutoplus`](https://github.com/sardylan/plutoplus) `fw‑0.39`;
no local Xilinx install is needed for the base firmware.

> ✅ **Verified on hardware.** Stratum‑1, PPS‑disciplined system clock (`chronyc tracking` →
> `Leap status: Normal`, ref `PPS`, within a few hundred ns of GPS). On the `--hwlatch` build the
> AD936x **sample clock** is also disciplined to GPS — **−7.77 ppm → +0.02 ppm**.

> ⚠️ **Read [`RECOVERY.md`](RECOVERY.md) before you flash** — the Pluto+ QSPI is *unprotected* and an
> interrupted write can brick the bootloader. Recovery is straightforward via SD‑card boot, but know
> the procedure first.

**Docs:** [Wiring](docs/WIRING.md) · [Verify/NTP serving](docs/NTP.md) · [Gotchas](docs/GOTCHAS.md) ·
[Build details](docs/BUILD.md) · [FPGA counter](hdl/pps_counter/README.md) ·
[Metrics](hdl/pps_counter/metrics/README.md) · [Networked TDOA](docs/NETWORK.md) ·
[Recovery](RECOVERY.md) · [Changelog](CHANGELOG.md)

---

## What you get

| Feature | How |
|---|---|
| **PPS** → `/dev/pps0` | `pps-gpio` on **MIO9** (`CONFIG_PPS` + `CONFIG_PPS_CLIENT_GPIO`) |
| **GPS NMEA** → `/dev/ttyPS0` | **UART1** (MIO12/13); gpsd auto‑starts at **9600**, `-n -b` |
| **Stratum‑1 system clock** | chrony disciplines time from GPS (coarse) + **PPS** (precise) |
| **LAN NTP server** | serves GPS time to RFC1918 + IPv6 link‑local once locked — see [NTP](docs/NTP.md) |
| **Diagnostics** | `ppstest`, `gpsmon`, `cgps`, `gpspipe` |
| **GPS‑disciplined sample clock** *(`--hwlatch`)* | FPGA `pps_counter` + `xo_correct.sh` lock the AD936x sample clock to GPS for `xo_correction`/TDOA — see [FPGA counter](hdl/pps_counter/README.md) |

**Two build variants:** the **base** firmware (`bash docker-run.sh`, no Vivado) gives everything above
except the FPGA counter; the **`--hwlatch`** firmware adds the sample‑clock counter + auto‑discipline
and rebuilds the bitstream (needs Vivado 2023.2). See [Build details](docs/BUILD.md).

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

```bash
bash docker-run.sh                                    # base firmware (no Vivado)
bash docker-run.sh --vivado /path/to/Xilinx --hwlatch # + FPGA sample-clock counter & discipline
```
Output lands in `./output/`: **`pluto.frm`** (flash this), `pluto.dfu`, and a release zip. (The host
`tee` pipeline may print a non‑zero exit even on success — trust the `Done.` line + `output/pluto.frm`.)
More in [Build details](docs/BUILD.md).

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

SSH in (`ssh root@pluto.local`, password `analog`) with the GPS connected and a sky view:

```sh
# services + devices up
ps -ef | grep -E 'gpsd|chronyd' | grep -v grep   # both running
ls -l /dev/pps0 /dev/ttyPS0                        # both present

# GPS fix (needs sky view, >=4 sats)
gpsmon                       # SNR bars + fix status (run bare, NOT 'gpsmon /dev/ttyPS0' — gpsd owns it)

# once it has a fix — system clock disciplined
ppstest /dev/pps0            # ~1 assert/sec
chronyc sources -v           # PPS refclock gets '*' when locked
chronyc tracking             # Stratum 1, Leap status: Normal

# FPGA sample-clock counter (--hwlatch build only)
devmem 0x7C460000 32         # 0x50505343 ("PPSC") = counter present
devmem 0x7C460008 32         # 0x1 = hardware PPS latch capturing (after lock)
cat /var/log/xocorrect.log   # discipline loop converging PPS_DELTA -> 30,720,000
```

**No fix?** Almost always antenna/reception (SNR ≈ 0 = antenna not really receiving) — see
[Gotchas](docs/GOTCHAS.md). Serving NTP to other machines is covered in [NTP](docs/NTP.md).

## Credits & License

Built on [`sardylan/plutoplus`](https://github.com/sardylan/plutoplus) (`fw‑0.39`) and
[ADI `plutosdr-fw`](https://github.com/analogdevicesinc/plutosdr-fw); recovery method from the Pluto+
community FAQ. Glue scripts + docs in this repo: [MIT](LICENSE). Firmware components (Linux kernel,
U‑Boot, Buildroot packages) retain their own licenses (GPL, etc.).
