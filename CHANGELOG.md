# Changelog

All notable changes to this project. Versions are git tags.

## v1.2
- **NTP/IPv6 fix:** also allow **IPv6 link-local** clients (`allow fe80::/10`). The v1.1 allow list
  was IPv4-only, so NTP queries that resolved to the Pluto's `fe80::` address (the common case over
  `eth0`/`pluto.local`) were silently dropped. Verified serving to a Windows host over `pluto.local`.

## v1.1
- **NTP server:** chrony now serves time to the LAN (`allow` for RFC1918 ranges); the device is a
  **stratum-1, GPS-backed NTP server** once it holds a PPS lock (it won't serve bad time before lock).
- **TDOA tooling:** added `tdoa/` with GPS-timestamped IQ capture scripts
  (`capture_gps_timestamped.sh`, `capture_timestamp.py`) and a TDOA roadmap.

## v1.0
Initial, verified-working firmware: GPS-disciplined time on the Pluto+.

- **PPS** on **MIO9** (`pps-gpio` → `/dev/pps0`); `CONFIG_PPS` + `CONFIG_PPS_CLIENT_GPIO`.
- **GPS NMEA** on **UART1** (MIO12/13) → **`/dev/ttyPS0`**; gpsd auto-starts at **9600** with `-n -b`.
- **chrony** with the **PPS refclock compiled in** (via `pps-tools`/`timepps.h`) + shipped
  `/etc/chrony.conf` (GPS SHM + PPS).
- Diagnostics: `ppstest`, `gpsmon`, `cgps`, `gpspipe`.
- Serial login **getty removed** from `ttyPS0` so it doesn't fight gpsd.
- **U-Boot `bootdelay=-2`** (auto-applied by `S30bootdelay`) so the GPS NMEA stream can't abort
  autoboot.
- Dockerized build on `sardylan/plutoplus` `fw-0.39`; no Vivado required for `pluto.frm`.
- **Verified:** `chronyc tracking` → stratum 1, reference `PPS`, `Leap status: Normal`, system time
  within a few hundred nanoseconds of GPS.
