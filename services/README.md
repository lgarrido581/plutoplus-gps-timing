# `services/` — on-device read-only telemetry

Server-side services that let a consumer (DistributedSensingNetwork, "DSN") read the
Pluto's timing / GPS / RF / DMA state **without root SSH or `devmem`**.

| file | role |
|---|---|
| `pluto_zmqd.cpp` | the **ZMQ telemetry daemon** (read-only) — aggregates `pps_counter` (devmem mmap) + `xocorrect.log` (`xo_ppm`) + `gpsd` (persistent client) + `ad9361-phy` sysfs (`rf`) + kernel-log scan (`dma`) into JSON, served over **PUB :5560** (1 Hz snapshot) and **REP :5561** (op reads). Contract: [`docs/PLUTO_ZMQ_API.md`](../docs/PLUTO_ZMQ_API.md). |
| `S65zmqapi` | init script: launches `pluto_zmqd` bound to **all interfaces** (`0.0.0.0`; override `ZMQ_BIND=<ip>`), after `gpsd` + networking. |
| `pluto_ctld.cpp` | the **ZMQ capture-control daemon** (WRITE) — tunes the AD9361 and runs a PPS-gated, GPS-anchored IQ capture, returning a SigMF (meta + `ci16_le` IQ) pair over **REP :5562** (`ping`/`capture`). Contract: [`docs/PLUTO_ZMQ_CTL_ICD.md`](../docs/PLUTO_ZMQ_CTL_ICD.md). |
| `capture_core.c` / `.h` | the capture core called by `pluto_ctld` — a refactor of the validated DSN/sdr-stack `iq_capture.c` (tune + `axi_tdd` PPS-gated arm + single-DMA refill + `pps_counter` anchor), returning meta + IQ **in memory**. |
| `pps_timestamp.c` / `.h` | GPS anchor from the FPGA `pps_counter` (LATCH/PPS regs). Vendored verbatim from DSN/sdr-stack. |
| `S66ctld` | init script: launches `pluto_ctld` (REP :5562, `ZMQ_BIND`/`ZMQ_CTL_PORT` overrides), after `S65zmqapi`. |

## How it's built

These daemons link **libzmq** (and `pluto_ctld` also **libiio**), so unlike a shell CGI
they can't just be dropped into the rootfs overlay — they must be cross-compiled.
`docker-build-inner.sh` turns these files into two **buildroot packages**:
`pluto-zmqd` (`select`s `BR2_PACKAGE_ZEROMQ`) and `pluto-ctld` (`select`s
`BR2_PACKAGE_ZEROMQ` + `BR2_PACKAGE_LIBIIO`), so the libraries build first and the
target toolchain/sysroot are used. They install `pluto_zmqd`/`pluto_ctld` → `/usr/bin`
and `S65zmqapi`/`S66ctld` → `/etc/init.d`. Building `pluto_ctld` inside buildroot uses
the Pluto's own toolchain, sidestepping the glibc-≤2.25 cross-build the standalone
`iq_capture` needs.

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
