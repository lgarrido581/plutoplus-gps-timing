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

- **Never `sync_soft` the axi_tdd core on a radio that does gated captures.** After a sync the
  core is RUNNING (`state` 3) with `burst_count` 0 and can't be stopped: `enable 0` reads back
  0, but the core stays RUNNING and keeps driving its channels. Channel changes (enable,
  polarity) apply only at the next frame end. If channel 1 (the RX-DMA sync) is left HIGH, the
  next gated capture can't hold the gate LOW, so its DMA starts at once and the capture carries
  the wrong label. Stop a running core with it enabled: `burst_count 1`, then `enable 0`; the
  state drops to 0 (IDLE) within a frame. Then restore `burst_count 0` and enable without a sync
  (ARMED, channels LOW): the state `pluto_ctld` leaves. Check with
  `iio_attr -d iio-axi-tdd-0 state` (0 idle, 1 armed, 3 running). Seen on node1, 2026-10-25.

- **`iio_attr -q` writes may silently not happen** on the shipped libiio 0.26. Use the plain
  form and redirect its output.
