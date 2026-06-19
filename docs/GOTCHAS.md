# Gotchas (hard-won)

- **No GPS fix is almost always antenna/reception.** The Pluto is an SDR and desenses the GPS L1
  band badly at close range — keep the GPS antenna **well away** from the board (a long-cable active
  antenna at a window/outside). A NEO-6M sitting next to the Pluto often sees only 1–2 satellites and
  never locks. You need **≥4** sats (3 for a 2D fix). Multi-GNSS (NEO-M8N) sees far more; a
  timing-grade NEO-M8T can hold time on a single satellite after survey-in. If `gpsmon` shows
  satellites with **SNR ≈ 0**, the antenna isn't really receiving (passive antenna with no bias, loose
  connector, or no sky view).

- **U-Boot autoboot vs GPS.** UART1 (MIO13) is also U-Boot's console input. The GPS NMEA stream makes
  U-Boot think a key was pressed and it **stops at the prompt instead of booting**. Fix:
  `bootdelay=-2` (boot immediately, ignore console input). The `S30bootdelay` init script applies this
  automatically — but it can only run *after* a successful boot, so the **first** boot on a fresh env
  must have the **GPS TX (MIO13) disconnected**, or set it by hand:
  ```sh
  printf 'bootdelay -2\n' > /tmp/bd && fw_setenv -s /tmp/bd && fw_printenv bootdelay
  ```
  (Use script mode — `fw_setenv bootdelay -2` fails because it parses `-2` as a flag.) This setting
  lives in the QSPI env and survives `pluto.frm` re-flashes.

- **GPS baud.** u-blox modules default to **9600**; the kernel leaves `ttyPS0` at the console's
  115200. The shipped `S50gpsd` forces 9600. If reading manually, `stty -F /dev/ttyPS0 9600 raw`.

- **`gpsmon /dev/ttyPS0` says "already opened by another process".** gpsd (`-n`) holds the port
  exclusively. Monitor *through* gpsd instead: run `gpsmon` (no device) or `cgps` with no args.

- **Spurious build exit code.** `docker-run.sh`'s `tee` pipeline can report a non-zero code even on a
  successful build. Trust the `Done.` line and `output/pluto.frm`.
