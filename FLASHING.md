# Flashing a Pluto+ firmware over the network (repeatable)

How to flash a built `output/pluto.frm` to the radio over SSH — no USB mass-storage
drag-and-drop needed. Validated end-to-end (uptime resets, RX + GPS come back).

## TL;DR — use the script
```sh
pip install paramiko          # once
python flash_frm.py output/pluto.frm
#   --host 192.168.50.30       # if pluto.local doesn't resolve
#   --no-reboot                # flash now, reboot later
```
It transfers the `.frm`, **verifies the md5 on the board before touching flash**,
`flashcp`s it, reboots, and confirms `uptime` reset + RX works. It **aborts** if the
md5 doesn't match.

## Why this is safe
- It writes **only `mtd3` (`qspi-linux`)** — the FIT image (kernel + dtb + rootfs +
  bitstream). **`mtd0` (FSBL/u-boot) and `mtd1` (env) are never touched**, so the
  bootloader + DFU stay intact: even a botched/interrupted flash is recoverable via
  `device_reboot sf` → `dfu-util`. You can't brick it this way.
- This is exactly what the official "copy `pluto.frm` to the USB drive + eject"
  update does internally (`flashcp` to the QSPI) — just over SSH.
- The **md5-before-flash check** is the real safety net: a corrupt transfer never
  reaches flash.

## Manual sequence (what the script does)
```sh
# 0. (host) note the local md5
md5sum output/pluto.frm

# 1. (host->board) raw-copy the .frm  (SSH is binary-safe; no scp/sftp on Pluto)
ssh root@pluto.local 'cat > /tmp/fw.frm' < output/pluto.frm        # pw: analog

# 2. (board) VERIFY md5 matches step 0 -- do NOT proceed if it differs
ssh root@pluto.local 'md5sum /tmp/fw.frm'

# 3. (board) flash to qspi-linux (erase + write + verify)
ssh root@pluto.local 'flash_unlock /dev/mtd3 2>/dev/null; flashcp -v /tmp/fw.frm /dev/mtd3'
#   flash_unlock may print "Operation not supported" -- harmless; flashcp still works.
#   Wait for "Verifying data: ... (100%)".

# 4. (board) reboot into the new firmware
ssh root@pluto.local 'sync; /sbin/reboot'

# 5. (host) after ~20-30 s, verify it came back + RX works
#    NOTE: pluto.local mDNS is often slow to re-register after a reboot --
#    the board is also reachable at its GPS-firmware static IP 192.168.50.30.
ssh root@192.168.50.30 'uptime; devmem 0x7C460008 32; \
  iio_readdev -b 8192 -s 8192 cf-ad9361-lpc voltage0 voltage1 | wc -c'
#   expect: uptime "up 0 min", pps_present 0x1, and 32768 bytes from iio_readdev.
```

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
