# `/health` service — read-only timing + GPS over HTTP

Serves the **DSN health contract** (`dsn.health/1`) so a sensing app can read the
Pluto's timing + GPS **without root SSH or `devmem`**. Consumed by
DistributedSensingNetwork (`dsn/health_api.py`, `docs/HEALTH_API.md`); this is the
server side.

| file | role |
|---|---|
| `health_cgi.sh` | the CGI — aggregates `pps_counter` (devmem) + `xocorrect.log` (`xo_ppm`) + `gpsd` (`gpspipe`) into the `dsn.health/1` JSON |
| `S60healthd` | init script: busybox `httpd` bound to the **hardware-LAN IP** (`192.168.50.x`), port 8080, docroot `/www` |

Installed into the rootfs overlay by `docker-build-inner.sh` (mounted from here via
`docker-run.sh -v services:/build/services-src`): `health_cgi.sh → /www/cgi-bin/health`,
`S60healthd → /etc/init.d/S60healthd`.

`GET http://<hw-lan-ip>:8080/cgi-bin/health` → the JSON. **Read-only**, hw-LAN only
(never the tailnet — GPS position is sensitive). Capture/control are deliberately
*not* here.

Notes:
- No new buildroot deps — uses busybox `httpd` (needs `FEATURE_HTTPD`+`_CGI`, already on),
  `devmem`, `gpspipe`. **busybox has no `timeout`** → the CGI uses gpspipe's `-x SECONDS`.
- `xo_ppm` comes from the `xocorrect` daemon's log, which auto-derives nominal from the
  live rate × channel mode — so it's correct in 1R1T and 2R2T (no client-side guess).
- `pps_advancing` uses a tiny `/tmp` SEQ cache (no per-request sleep); it resolves on
  the 2nd poll. The orchestrator polls each cycle, so it settles immediately.

## Test on a running radio (no reflash)
```sh
ssh root@<pluto> 'mkdir -p /tmp/www/cgi-bin'
scp health_cgi.sh root@<pluto>:/tmp/www/cgi-bin/health        # or: cat | ssh '... > ...'
ssh root@<pluto> 'chmod +x /tmp/www/cgi-bin/health; httpd -p <hw-ip>:8080 -h /tmp/www'
wget -qO- http://<hw-ip>:8080/cgi-bin/health
```
Validated end-to-end 2026-06-26 against a Pluto+ (3-D fix) and the DSN client
(`OffloadPlutoCaptureSource(status_url=...)` → `TRUSTED … fix=3`, root-free).
