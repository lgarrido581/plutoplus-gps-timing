# Pluto ZMQ telemetry API — read-only timing / GPS / RF / DMA

> **Formal interface spec:** [`docs/PLUTO_ZMQ_ICD.md`](PLUTO_ZMQ_ICD.md) is the
> authoritative wire ICD (per-field data dictionary, message catalog, framing, error
> matrix, versioning — conformance-tested against the binary). This page is the
> design/integration overview.

A read-only **ZMQ** API (`pluto_zmqd`) that exposes everything a sensing consumer
(DistributedSensingNetwork, "DSN") currently needs **root SSH + `devmem`/`gpspipe`**
for. With this running, the two read-only SSH paths can be retired:

| was (root SSH)                                   | now (ZMQ)                       |
|--------------------------------------------------|---------------------------------|
| `ssh root@pluto devmem 0x7C46…` (pps_counter)    | `timing` block                  |
| `ssh root@pluto gpspipe -w` (gpsd)               | `gps` block                     |
| `ssh root@pluto cat …/out_altvoltage0_RX_LO_…`   | `rf` block                      |
| *(no equivalent — could only detect by capturing)* | `dma` block (best-effort)     |

IQ capture itself is **out of scope** and stays as-is. This API is **read-only by
construction** — no capture, no retune, no register writes (see [Security](#security)).

It is the **server side** of the same contract DSN reads over HTTP from
[`/health`](../services/README.md): `timing` and `gps` reuse the **exact
`dsn.health/1` field names**, so a DSN `NodeStatus.from_health_json()` works after only
a transport swap. The ZMQ API adds the `rf` and `dma` blocks and a 1 Hz PUB heartbeat
that HTTP polling can't give cheaply.

---

## Transport

Two ZMQ sockets, JSON bodies (UTF-8, one JSON object per message), **bound to all
interfaces (`0.0.0.0`) by default** — the Pluto's LAN subnet isn't knowable in advance,
so a hardcoded subnet is fragile. Override `ZMQ_BIND` to pin it to one IP. The data is
read-only and the Pluto's interfaces are local (wired LAN + USB); it is not on the
tailnet by design. See [Security](#security).

| socket | endpoint              | pattern | use |
|--------|-----------------------|---------|-----|
| **PUB** | `tcp://<bind>:5560` | publish | 1 Hz full snapshot. **Absence of frames is the liveness signal** — no failed-SSH timeout dance. Subscribe with an empty filter (`""`) to get every frame. |
| **REP** | `tcp://<bind>:5561` | request/reply | a fresh **synchronous** read — for the per-cycle admission gate that wants a definite answer *now*. |

Ports are overridable via `ZMQ_PUB_PORT` / `ZMQ_REP_PORT` (see the init script).

### REP request

The request body is either `{"op":"<name>"}` or a bare op word. Ops:

| op | reply |
|----|-------|
| `snapshot` (or empty) | the full snapshot (same body as a PUB frame) |
| `timing` | `{schema, api, t_unix, "timing":{…}}` |
| `gps` | `{schema, api, t_unix, "gps":{…}}` |
| `rf` | `{schema, api, t_unix, "rf":{…}}` |
| `dma` | `{schema, api, t_unix, "dma":{…}}` |
| `ping` | `{schema, api, "pong":true, t_unix}` |

REP is strict request/reply (one reply per request); always read the reply before
sending again.

---

## Snapshot schema

```jsonc
{
  "schema":  "dsn.health/1",       // identical envelope to /health (timing+gps fields)
  "api":     "dsn.pluto_zmq/1",    // marks the rf/dma extension + ZMQ transport
  "node_id": "pluto",              // hostname
  "board": "plutoplus",            // "plutoplus" or "libresdr"
  "t_unix":  1750000000,           // server wall clock at emit (seconds)
  "uptime_s": 12345,

  "timing": {                      // pps_counter (devmem) + xocorrect.log
    "pps_present":   true,         // STATUS bit0 — hw PPS latch alive (--hwlatch build,
                                   //   after the GPS PPS reaches F20). false on base build.
    "pps_advancing": true,         // PPS_SEQ advanced over the last 1 Hz tick. null until
                                   //   two ticks have elapsed, or if no counter.
    "pps_seq":       42,           // pps_counter SEQ (increments once per GPS PPS edge)
    "xo_ppm":        0.0,          // last value the xocorrect daemon logged. It auto-derives
                                   //   nominal from live rate x channel mode, so it is correct
                                   //   in 1R1T and 2R2T (no client-side guess). null if absent.
    "cnt_clk_hz":    61440000      // DELTA reg = AD9361 l_clk ticks per PPS second (data clock,
                                   //   ~2x sample_rate in 2R2T). GPS-disciplined; basis for xo_ppm.
  },

  "gps": {                         // gpsd (persistent client). Only fields with a value appear.
    "mode":        3,              // 0 unknown, 1 no fix, 2 = 2D, 3 = 3D
    "lat_deg":     37.1234567,
    "lon_deg":   -122.1234567,
    "alt_hae_m":   42.7,           // ELLIPSOIDAL height (HAE) — use this, not MSL
    "alt_msl_m":   75.3,
    "geoid_sep_m": -32.6,
    "eph_m":       3.1,            // horizontal position error estimate
    "epv_m":       5.4,            // vertical position error estimate
    "n_sat_used":  9,              // satellites used in the fix (SKY uSat)
    "speed_mps":   0.03,
    "track_deg":   118.2,
    "climb_mps":   0.0
  },

  "rf": {                          // ad9361-phy sysfs (actual chip state)
    "phy":               "ad9361-phy",
    "rx_lo_hz":          2400000000,   // ACTUAL rx LO — compare to your request to catch
                                       //   the silent LO clamp (the old SSH cat path)
    "tx_lo_hz":          2400000000,
    "sample_rate_hz":    30720000,
    "rf_bandwidth_hz":   18000000,
    "rx_gain_db":        71.0,
    "gain_control_mode": "slow_attack",
    "rf_port_select":    "A_BALANCED"
  },

  "dma": {                         // best-effort (see note)
    "rx_ok":      true,            // no cf_axi DMA error signature in the kernel log ring
    "last_error": null             // else the matching kernel-log line (truncated)
  }
}
```

Consumers should treat **missing keys as "unknown"** (e.g. before a GPS fix, the
`gps` block has only `mode`). Numbers are emitted verbatim from the source to preserve
precision (lat/lon especially).

### `dma` is best-effort

There is no reliable, capture-free kernel signal for the errno-110 (`ETIMEDOUT`) RX
DMA wedge. `pluto_zmqd` heuristically scans the kernel log ring (non-destructive) for
`cf_axi`/`ad9361` error/timeout/under-overflow lines: `rx_ok=false` + `last_error`
when found. A wedge that doesn't log will still read `rx_ok=true` — so use it as a
**negative signal you can trust and a positive signal you shouldn't fully rely on.**

---

## Security

- **Read-only by construction.** No op writes any register, retunes, or captures.
  Capture/retune are deliberately **v2**, planned on a *separate, authenticated*
  socket — never folded into this one. No socket-level auth.
- **Binds all interfaces by default (`0.0.0.0`).** The Pluto's LAN subnet isn't
  knowable ahead of time, so the init script binds everything and serves the same
  read-only telemetry on each interface. This is acceptable because the Pluto's
  interfaces are local (wired LAN + USB gadget) and the box is not on the tailnet by
  design. To narrow it to one interface, set `ZMQ_BIND=<ip>`.
- If you ever need this on a shared/untrusted network, do **not** just change the bind
  — add CurveZMQ (encryption + client auth) and coarsen/round `gps` position first.

---

## Build & runtime

- **Dependency:** `libzmq`, enabled via `BR2_PACKAGE_ZEROMQ` (auto-selected by the
  package; buildroot 2023.02 names the libzmq package `zeromq`). This is the one new
  runtime library vs. the shell-only `/health`. The
  daemon is C++ and also needs `libstdc++` (`BR2_INSTALL_LIBSTDCPP=y`).
- **Package:** `buildroot/package/pluto-zmqd` — a buildroot package (created by
  `docker-build-inner.sh` from `services/pluto_zmqd.cpp` + `services/S65zmqapi`). It is
  a real package (not a rootfs-overlay drop-in like the `/health` CGI) so libzmq builds
  first and the daemon is cross-compiled with the target toolchain + sysroot.
- **Autostart:** `/etc/init.d/S65zmqapi` (after `S50gpsd`, after networking). It binds
  `0.0.0.0` (override `ZMQ_BIND`) and launches `/usr/bin/pluto_zmqd` via `start-stop-daemon`.
- **Build it:** the standard base build picks it up automatically —
  `bash docker-run.sh` → `output/pluto.frm`. No Vivado needed (the `timing` block
  reads the counter via raw devmem; on a base/no-counter bitstream the `timing` block
  degrades to `pps_present=false` and null numeric fields, the rest still work).

### Debug a running radio without a ZMQ client

`pluto_zmqd --print` builds **one** snapshot, prints it to stdout, and exits — so you
can validate the data-gathering over SSH before wiring up a subscriber:

```sh
ssh root@pluto.local 'pluto_zmqd --print'      # one JSON snapshot, no sockets bound
```

### Test the live API on a running radio (no reflash)

```sh
# The shipped daemon already binds 0.0.0.0, so it's reachable as soon as it autostarts.
# (To run a freshly cross-built binary by hand: stop the service first, then launch it.)

# from the consumer (Python; pip install pyzmq):
python3 - <<'PY'
import zmq, json
c = zmq.Context()
s = c.socket(zmq.REQ); s.connect("tcp://pluto.local:5561")
s.send_string('{"op":"snapshot"}'); print(json.dumps(json.loads(s.recv()), indent=2))

sub = c.socket(zmq.SUB); sub.connect("tcp://pluto.local:5560")
sub.setsockopt_string(zmq.SUBSCRIBE, "")          # empty filter = every frame
print("PUB:", sub.recv_string())                  # ~1 Hz heartbeat
PY
```

> The shipped init script binds `0.0.0.0` by default; set `ZMQ_BIND=<ip>` to restrict
> it to one interface (see [Security](#security)).

---

## Relationship to `/health`

Both serve the same `dsn.health/1` `timing`+`gps` fields, so DSN's parser is
transport-agnostic. Pick per use:

| want | use |
|------|-----|
| occasional pull, zero new deps, shell-only | HTTP [`/health`](../services/README.md) |
| 1 Hz push liveness, sub-ms synchronous reads, `rf`/`dma` | this ZMQ API |

The `rf`/`dma` blocks could be backported into the `/health` CGI if a no-new-dep
deployment ever needs them.
