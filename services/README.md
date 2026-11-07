# `services/` — on-device telemetry and radio control

Server-side services that let a consumer (DistributedSensingNetwork, "DSN") read the
Pluto's timing / GPS / RF / DMA state **without root SSH or `devmem`** (`pluto_zmqd`,
read-only), and drive the radio — capture, continuous RX stream and TX (`pluto_ctld`,
write).

| file | role |
|---|---|
| `pluto_zmqd.cpp` | the **ZMQ telemetry daemon** (read-only) — aggregates `pps_counter` (devmem mmap) + `xocorrect.log` (`xo_ppm`) + `gpsd` (persistent client) + `ad9361-phy` sysfs (`rf`) + kernel-log scan (`dma`) into JSON, served over **PUB :5560** (1 Hz snapshot) and **REP :5561** (op reads). Contract: [`docs/PLUTO_ZMQ_API.md`](../docs/PLUTO_ZMQ_API.md). |
| `S65zmqapi` | init script: launches `pluto_zmqd` bound to **all interfaces** (`0.0.0.0`; override `ZMQ_BIND=<ip>`), after `gpsd` + networking. |
| `pluto_ctld.cpp` | the **ZMQ radio-control daemon** (WRITE, **no authentication**) on **REP :5562**. Ops: `ping`; `capture` (tune + PPS-gated, GPS-anchored IQ capture → SigMF meta + `ci16_le` IQ pair); `stream_start`/`stream_stop`/`stream_status` (continuous GPS-timed RX to a receiver you name); `tx_load`/`tx_start`/`tx_stop`/`tx_status` (load and transmit a cyclic TX1 waveform); `tdd_status` (axi_tdd gate state). Contract: [`docs/PLUTO_ZMQ_CTL_ICD.md`](../docs/PLUTO_ZMQ_CTL_ICD.md). |
| `capture_core.c` / `.h` | the capture core called by `pluto_ctld` — a refactor of the validated DSN/sdr-stack `iq_capture.c` (tune + `axi_tdd` PPS-gated arm + single-DMA refill + `pps_counter` anchor), returning meta + IQ **in memory**. |
| `stream_core.c` / `.h`, `tx_core.c` / `.h`, `iqwire.h` | the continuous RX stream, the cyclic TX, and the stream's binary wire header. |
| `pps_timestamp.c` / `.h` | GPS anchor from the FPGA `pps_counter` (LATCH/PPS regs). Vendored verbatim from DSN/sdr-stack. |
| `S66ctld` | init script: launches `pluto_ctld` bound to **all interfaces** (`0.0.0.0`; `ZMQ_BIND`/`ZMQ_CTL_PORT` overrides), after `S65zmqapi`. |

> ⚠️ **Any host that can reach port 5562 can make the radio transmit.** `pluto_ctld` has no
> authentication and binds `0.0.0.0` by default, so anyone on a network the board is on can
> retune it, capture, and load and start a TX waveform. Keep the board on a trusted network (or
> firewall :5562). `ZMQ_BIND` restricts the listen address, but `S66ctld` only reads it from its
> environment (it sources no config file) and the rootfs is in RAM, so a restart like
> `ZMQ_BIND=<board-ip> /etc/init.d/S66ctld restart` lasts until the next reboot; to make it stick,
> change `services/S66ctld` and rebuild. See the ICD's Security section.

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

`services/` is mounted at `/build/services-src` by `docker-run.sh`. A normal build
picks it up automatically:

```sh
bash docker-run.sh        # -> output/pluto.frm  (no Vivado; reuses output/working.bit, see docs/BUILD.md)
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
- `pluto_zmqd` itself never captures, retunes or writes registers; those ops are on
  `pluto_ctld` (:5562, unauthenticated — see the warning above). See
  [`docs/PLUTO_ZMQ_API.md`](../docs/PLUTO_ZMQ_API.md).
