# `services/` — on-device read-only telemetry

Server-side services that let a consumer (DistributedSensingNetwork, "DSN") read the
Pluto's timing / GPS / RF / DMA state **without root SSH or `devmem`**.

| file | role |
|---|---|
| `pluto_zmqd.cpp` | the **ZMQ telemetry daemon** — aggregates `pps_counter` (devmem mmap) + `xocorrect.log` (`xo_ppm`) + `gpsd` (persistent client) + `ad9361-phy` sysfs (`rf`) + kernel-log scan (`dma`) into JSON, served over **PUB :5560** (1 Hz snapshot) and **REP :5561** (op reads). Read-only by construction. Contract: [`docs/PLUTO_ZMQ_API.md`](../docs/PLUTO_ZMQ_API.md). |
| `S65zmqapi` | init script: launches `pluto_zmqd` bound to **all interfaces** (`0.0.0.0`; override `ZMQ_BIND=<ip>`), after `gpsd` + networking. |

## How it's built

`pluto_zmqd` links **libzmq**, so unlike a shell CGI it can't just be dropped into the
rootfs overlay — it must be cross-compiled. `docker-build-inner.sh` turns these files
into a **buildroot package** (`buildroot/package/pluto-zmqd`, `select`s
`BR2_PACKAGE_ZEROMQ`) so libzmq builds first and the target toolchain/sysroot are used.
The package installs `pluto_zmqd → /usr/bin` and `S65zmqapi → /etc/init.d`.

`services/` is mounted at `/build/services-src` by `docker-run.sh`. A normal base build
picks it up automatically:

```sh
bash docker-run.sh        # -> output/pluto.frm  (no Vivado needed)
```

## Test on a running radio (no reflash)

```sh
# one snapshot to stdout, no sockets (validate data-gathering over SSH):
ssh root@pluto.local 'pluto_zmqd --print'

# live API: the shipped daemon already binds 0.0.0.0, so just hit it over the network:
python3 -c "import zmq,json;c=zmq.Context();s=c.socket(zmq.REQ);s.connect('tcp://pluto.local:5561');s.send_string('ping');print(s.recv())"
```

Notes:
- New runtime dep vs. the shell-only `/health`: **libzmq** (+ `libstdc++` for the C++
  daemon). Both are enabled automatically by the package.
- `gps` reuses the exact `dsn.health/1` field names, so DSN's `NodeStatus`
  parser is transport-agnostic between this and HTTP `/health`.
- `dma` is **best-effort** (heuristic kernel-log scan; a non-logging wedge reads OK).
- Capture/retune are deliberately **not** here — they are v2 on a separate authed
  socket. See [`docs/PLUTO_ZMQ_API.md`](../docs/PLUTO_ZMQ_API.md).
