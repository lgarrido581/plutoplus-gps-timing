# Flashing a Pluto+ firmware over the network (repeatable)

For LibreSDR QSPI updates after SD validation, use
[`docs/LIBRESDR_QSPI.md`](docs/LIBRESDR_QSPI.md) and
`flash_libresdr_qspi.py`. The Pluto+ flow below flashes `output/pluto.frm`;
LibreSDR flashes `output/libre.frm` with board-specific safety checks. Keep the
LibreSDR recovery ladder in [`docs/LIBRESDR_RECOVERY.md`](docs/LIBRESDR_RECOVERY.md)
nearby before the first QSPI experiment.

How to flash a built `output/pluto.frm` to the radio over SSH — no USB mass-storage
drag-and-drop needed. Validated end-to-end (uptime resets, RX + GPS come back).

## TL;DR — use the script
```sh
pip install paramiko          # once
python flash_frm.py output/pluto.frm
#   --host <board-ip>          # if pluto.local doesn't resolve
#   --no-reboot                # flash now, reboot later
```
It transfers the `.frm`, **verifies the md5 on the board before touching flash**,
runs the board's `update_frm.sh` to flash it (which **also sets `fit_size`** — see
below), **asserts `fit_size` matches the new image**, and reboots. It **aborts** on an
md5, `update_frm.sh` or `fit_size` mismatch. After the reboot it only *prints* `uptime`,
PPS state (`pps_present`, PPS advancing) and — if `pyzmq` is installed — `dma.rx_ok`;
it does not fail on them, so read them.

## Why this is safe — and the `fit_size` gotcha that can brick you
- It writes **only `mtd3` (`qspi-linux`)** — the FIT image (kernel + dtb + rootfs +
  bitstream). **`mtd0` (FSBL/u-boot) and `mtd1` (env) are never touched**, so the
  bootloader + DFU stay intact: even an interrupted flash is recoverable via
  `device_reboot sf` → `dfu-util`. Recovery survives — see `RECOVERY.md`.
- ⚠️ **A bare `flashcp` is NOT enough — it can brick.** U-Boot reads exactly
  **`fit_size` bytes** of the FIT from QSPI at boot. If you write a FIT that is
  *larger* than the current `fit_size` and don't update `fit_size`, U-Boot loads a
  **truncated** FIT and the board won't boot. This is what shipped-broken v2.0.1 came
  down to: a 700 KB size change with a stale `fit_size`.
- So the flash **must** run `fw_setenv fit_size <new FIT.itb size>`. The board's
  `/sbin/update_frm.sh` does this (md5-checks the trailer, strips it, `dd`s the
  FIT.itb to `mtdblock3`, then `fw_setenv fit_size`). **Always flash through it**,
  which is what `flash_frm.py` does — never hand-roll a `flashcp`.
- The **md5-before-flash check** guards transfer integrity; the **`fit_size` assert**
  guards bootability. Both must pass before reboot.
- ⚠️ **LibreSDR: unverified.** `flash_libresdr_qspi.py` writes `libre.frm` with a bare
  `flashcp -v` and does **not** set `fit_size`. Nothing in this repo shows whether the
  LibreSDR U-Boot reads `fit_size` bytes or a fixed size at QSPI boot (its environment is
  generated during the build and not committed). Until that is checked, run
  `fw_printenv | grep -E 'fit_size|sf read'` on the board before rebooting: if the QSPI boot
  reads `${fit_size}` and `fit_size` is smaller than the new FIT (`.frm` bytes − 33), the same
  truncation applies — don't reboot. See [`docs/LIBRESDR_QSPI.md`](docs/LIBRESDR_QSPI.md).

## Manual sequence (what the script does)
```sh
# 0. (host) note the local md5
md5sum output/pluto.frm

# 1. (host->board) raw-copy the .frm  (SSH is binary-safe; no scp/sftp on Pluto).
#    The remote name MUST end in .frm -- update_frm.sh checks the extension.
ssh root@pluto.local 'cat > /tmp/fw.frm' < output/pluto.frm        # pw: analog

# 2. (board) VERIFY md5 matches step 0 -- do NOT proceed if it differs
ssh root@pluto.local 'md5sum /tmp/fw.frm'

# 3. (board) flash via the board's own updater -- it validates the .frm's md5
#    trailer, writes the FIT to mtdblock3, AND sets fit_size (the anti-brick step).
ssh root@pluto.local '/sbin/update_frm.sh /tmp/fw.frm'
#   expect "Done". A "Failed Checksum error" means a corrupt/mismatched .frm (safe --
#   nothing was flashed). Do NOT substitute a raw `flashcp`: it skips fit_size.

# 4. (board) confirm fit_size now matches the new FIT.itb size (frm bytes minus 33):
ssh root@pluto.local 'fw_printenv fit_size'
#   e.g. a 16317300-byte .frm -> FIT.itb 16317267 -> fit_size=F8FB53 (printf %X).

# 5. (board) reboot into the new firmware
ssh root@pluto.local 'sync; /sbin/reboot'

# 6. (host) after ~20-30 s, verify it came back + RX works
#    NOTE: pluto.local mDNS is often slow to re-register after a reboot --
#    use the board's eth0 IPv4 address instead. This firmware sets no static IP:
#    eth0 takes the U-Boot env `ipaddr_eth` if you set one, otherwise whatever the
#    network gives it (DHCP, or only a 169.254 link-local -- see docs/NTP.md).
ssh root@<board-ip> 'uptime; devmem 0x7C460008 32'
#   expect: uptime "up 0 min", pps_present 0x1. Then run the release gate:
#   python tools/smoke_test.py --host <board-ip> --board plutoplus
```

## Post-flash validation (quick checklist)

`flash_frm.py` already asserts the flash landed (`fit_size`), and after the reboot prints
PPS state and — if `pyzmq` is available — `dma.rx_ok` (printed, not asserted: check them).
For a manual once-over (`root`/`analog`, `<board-ip>` = `pluto.local` / the board's eth0
address / usb `192.168.2.1`), confirm:

```sh
uname -a                         # NEW build date/#N -> the flash took (not the old rootfs)
fw_printenv mode                 # channel mode preserved (e.g. 2r2t)
fw_printenv fit_size             # == new FIT.itb size (.frm bytes - 33, printf %X)
devmem 0x7C460000 32             # pps_counter ID -> 0x50505343 ("PPSC"): the timing core is present
devmem 0x7C460040 32             # latch SEQ -> a real count that advances per capture, NOT 0x50505343
                                 #   (0x50505343 here == the old 6-bit-decode alias -> latch can't fire)
iio_attr -c ad9361-phy altvoltage0 frequency      # RX LO tuned to your center freq
iio_attr -c ad9361-phy voltage0 sampling_frequency
iio_attr -c ad9361-phy voltage0 rssi              # RX chain alive (a real dB reading)
iio_attr -d | grep tdd           # "iio-axi-tdd-0: found N device attributes" -> configure_tdd works
```

Then the release gate: `python tools/smoke_test.py --host <board-ip> --board <plutoplus|libresdr>`
(asserts an actual GPS-anchored capture succeeds). For LibreSDR the same checks apply; the
board reports `board=libresdr` and clocks the AD9361 data path at 2× the Pluto+ (see `docs/LIBRESDR.md`).

## MTD layout (for reference)
| dev  | partition         | flashed? |
|------|-------------------|----------|
| mtd0 | qspi-fsbl-uboot   | no (keep — recovery) |
| mtd1 | qspi-uboot-env    | no |
| mtd2 | qspi-nvmfs        | no |
| **mtd3** | **qspi-linux** (FIT) | **yes** |

## Recovery if a board doesn't come back
The bootloader is untouched, so:
```sh
# put the board into Serial-Flash DFU mode, then flash with dfu-util from the host
ssh root@<addr> 'device_reboot sf'        # if SSH still works
# or hold the DFU condition at power-on; then:
dfu-util -a firmware.dfu -D output/pluto.dfu -R
```
See `RECOVERY.md` for the full DFU recovery procedure.

## Notes
- GPS re-acquires PPS after a reboot; `pps_present` (devmem `0x7C460008`) returns to
  `0x1` within a few seconds if the antenna has a fix.
- The clock isn't GPS-*disciplined* for the first ~tens of seconds after boot (chrony
  needs a fix), so absolute timestamps right after boot reflect the un-disciplined
  system clock — wait for discipline before trusting absolute GPS time.
- Keep the prior `output/pluto_v1pN.frm` around; rolling back is just
  `python flash_frm.py output/pluto_v1p5.frm`.
