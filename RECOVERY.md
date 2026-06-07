# Recovery & first‑time bootloader flashing (Pluto+)

The Pluto+ QSPI flash is **not write‑protected**, so an interrupted firmware write can corrupt the
**bootloader** (FSBL/U‑Boot), leaving the device with **no USB enumeration, no DFU — just a green
LED**. This guide gets it back using **SD‑card boot**, which works even when the internal QSPI is
fully corrupt.

You need this when:
- An update was interrupted (unplugged mid‑write) and the device no longer boots, **or**
- You're flashing a brand‑new board's bootloader, **or**
- `pluto.frm` alone won't fix boot (because the bootloader, not the firmware partition, is bad).

> **Why a normal `update_frm.sh ./pluto.frm` can't fix this:** that only writes the *firmware*
> partition. The corrupted part is the *bootloader* (`boot.frm`). You must write **both**.

---

## You will need

1. A **microSD card** (FAT32).
2. A Pluto+ **`boot.frm`** — this is **hardware/board specific** and is **not produced by this
   repo's no‑Vivado build**. Get one that matches your board:
   - Best: the **same firmware package you used to make the SD card** (proven to boot your board), **or**
   - A Pluto+ release that includes `boot.frm`, e.g. the full
     [`plutoplus/plutoplus`](https://github.com/plutoplus/plutoplus/releases) release zip
     (contains `boot.frm` + `pluto.frm`).
3. The firmware you want to run: this repo's **`output/pluto.frm`** (with GPS timing), or a stock
   `pluto.frm` to return to known‑good first.
4. The Pluto+ **boot‑mode jumper** access (the `SD_H` strap — see below).

> ⚠️ `boot.frm` contains the FSBL, which configures DDR/MIO for your exact board revision. Using a
> `boot.frm` for the wrong board can fail to boot. Prefer the one that matches your working SD image.

---

## Step 1 — Enable SD boot (hardware strap)

On the **V2 (3V3) board**, short **`SD_H` to 3V3** and leave the jumper on **MIO46** (per the
Pluto+ community recovery method). This makes the Zynq boot from the SD card instead of QSPI.

*(Exact pad/jumper locations vary by board revision — consult your Pluto+ pinout.)*

## Step 2 — Make the SD card

Copy the **`sdimg/` folder contents** from a Pluto+ firmware package onto a freshly FAT32‑formatted
SD card (root of the card). Insert it into the Pluto+.

## Step 3 — Boot from SD

Plug in USB **while holding the DFU button**; release once it boots. The device should come up
normally (it's running from the SD card now). Confirm:

```powershell
# on the host
ping pluto.local
# or look for the PlutoSDR USB drive / network adapter to appear
```

## Step 4 — Write BOTH partitions to QSPI

With the device booted from SD, it exposes a removable drive containing `config.txt`. Copy **both**
files to that drive's root:

- `boot.frm`  ← matching your board
- `pluto.frm` ← this repo's GPS image (or stock to un‑brick to known‑good first)

Then **safely eject** the drive. It will flash QSPI:

- Wait until the **fast LED blinking stops**, then **+ at least 3 minutes**.
- 🚫 **Do not disconnect power.** This is the step that bricks devices.

## Step 5 — Boot from QSPI

1. Power off completely and **remove the SD card**.
2. **Remove the `SD_H`→3V3 strap** (leave the MIO46 jumper).
3. Power on, wait ~10 s. **Blue steady + green blinking = recovered**, now booting your QSPI firmware.

---

## Alternative: DFU flashing

If the device still enumerates in DFU mode (USB ID `0456:b674`, DONE LED off / LED1 solid):

```bash
# Linux: enter DFU from a running system, then flash
device_reboot sf                       # or hold the DFU button while powering on
dfu-util -a firmware.dfu  -D pluto.dfu
dfu-util -a boot.dfu      -D boot.dfu   # only if you have a matching boot.dfu
dfu-util -e                             # reset
```

On **Windows** you must bind the DFU interface to **WinUSB** with [Zadig](https://zadig.akeo.ie/)
first (Options → List All Devices → select `0456 B674` → install WinUSB), then use
`dfu-util.exe --list` to confirm before flashing.

> DFU mode itself is provided by U‑Boot, so it only works if the bootloader still runs. If the
> bootloader is corrupt (no DFU at all), use the **SD‑boot** method above.

---

## Recommended two‑pass recovery (safest)

1. **Un‑brick to known‑good:** write a **matched** `boot.frm` + `pluto.frm` pair (both from the same
   package). Confirm it boots from QSPI.
2. **Apply GPS firmware:** then `update_frm.sh ./pluto.frm` with this repo's image. A normal update
   only touches the firmware partition, leaving the now‑good bootloader intact.

This separates "is the bootloader fixed?" from "does my custom firmware boot?", so if anything
misbehaves you know which step to look at.

---

## After recovery: GPS boot note

Once on the GPS firmware, remember the **U‑Boot autoboot vs GPS NMEA** issue (see the main
[`README.md`](README.md) *Gotchas*): the first boot on a fresh env must have the **GPS TX (MIO13)
disconnected**, or set `bootdelay=-2` so U‑Boot ignores the incoming NMEA:

```sh
printf 'bootdelay -2\n' > /tmp/bd && fw_setenv -s /tmp/bd
```

(The shipped `S30bootdelay` init script does this automatically on the first successful boot.)
