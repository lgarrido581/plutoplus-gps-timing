# Interface Control Document — Pluto ZMQ Telemetry API

| | |
|---|---|
| **Interface** | `dsn.pluto_zmq/1` (read-only telemetry) |
| **Provider** | `pluto_zmqd` on the Pluto+ GPS-timing firmware |
| **Consumer** | DistributedSensingNetwork ("DSN") node agent, or any ZMQ client |
| **Transport** | ZeroMQ over TCP (libzmq 4.x wire protocol, ZMTP/3.0) |
| **Encoding** | UTF-8 JSON, one object per ZMQ message (single frame, no trailing newline) |
| **Status** | Implemented, built, and **hardware-validated** end-to-end (§13) |
| **Source of truth** | `services/pluto_zmqd.cpp`. This ICD documents that binary as built. |

This ICD is the **authoritative wire specification**. `docs/PLUTO_ZMQ_API.md` is the
companion design/integration overview (rationale, quickstart, test procedure).

---

## 1. Scope

Defines the read-only interface by which a consumer obtains the Pluto's **timing, GPS,
RF, and DMA-health** state without root SSH/`devmem`/`gpspipe`. Out of scope: IQ
capture, any control/retune/write operation (those are a separate, authenticated v2
interface — **this interface performs no writes of any kind**).

## 2. Reference documents

- `docs/PLUTO_ZMQ_API.md` — design overview, rationale, quickstart, test procedure.
- `dsn.health/1` — the DSN health contract whose `timing`+`gps` field names this
  interface reuses verbatim (a DSN `NodeStatus.from_health_json()` parses either).
- ZMTP/3.0 — ZeroMQ Message Transport Protocol (libzmq wire framing).

## 3. Definitions

| Term | Meaning |
|---|---|
| **snapshot** | a complete JSON object carrying all four telemetry blocks |
| **block** | one of `timing`, `gps`, `rf`, `dma` |
| **stale** | a GPS report not refreshed by gpsd within `GPS_STALE_MS` (5000 ms) |
| **counter** | the FPGA `pps_counter` AXI peripheral (present only on `--hwlatch` bitstreams) |
| **null** | JSON `null` — value is unknown/unavailable, distinct from absent key |

## 4. Transport & connection

### 4.1 Endpoints

| Socket | ZMQ type | Default endpoint | Direction | Purpose |
|---|---|---|---|---|
| PUB | `ZMQ_PUB` | `tcp://<bind>:5560` | provider→consumer | unsolicited 1 Hz snapshot |
| REP | `ZMQ_REP` | `tcp://<bind>:5561` | request/reply | synchronous on-demand read |

- `<bind>` = `0.0.0.0` (all interfaces) by default — the Pluto's LAN subnet is not
  knowable in advance, so `S65zmqapi` binds all interfaces. Override with env `ZMQ_BIND`
  = a specific IPv4 address to restrict it to one interface. (The daemon's own default
  when run with no `--bind` is `127.0.0.1`.)
- Ports overridable: env `ZMQ_PUB_PORT` / `ZMQ_REP_PORT` (init script), or
  `--pub-port` / `--rep-port` / `--bind` (daemon args).
- The provider serves identical content on every bound interface; the data is
  read-only. See §10 for the confidentiality model.

### 4.2 Socket patterns

- **PUB/SUB.** The consumer connects a `ZMQ_SUB` socket and **MUST set an empty
  subscription** (`SUBSCRIBE ""`); there is no topic prefix. Each message is a single
  frame containing one snapshot. PUB sends are non-blocking (`ZMQ_DONTWAIT`): if no
  subscriber is connected or the high-water mark is hit, frames are dropped (by design
  — liveness is conveyed by frame arrival, not by buffering).
- **REQ/REP.** Strict lockstep: exactly one reply per request; the consumer MUST
  receive the reply before sending the next request. One request frame in, one reply
  frame out.

### 4.3 Framing & encoding

- One ZMQ message = one JSON object (single part). No multipart, no topic frame, no
  newline terminator.
- Character encoding UTF-8. Numbers are emitted **verbatim from the source** (no
  re-rounding) to preserve precision (notably `gps.lat_deg`/`lon_deg`).
- Field order within an object is not significant; consumers MUST NOT depend on it.

### 4.4 Liveness

A consumer treats the PUB stream as a heartbeat: a snapshot is published every
**1000 ms ± scheduling jitter**. Absence of a frame for, e.g., >3 s indicates the
provider/node is down or unreachable. There is no separate keepalive.

## 5. Message catalog

### 5.1 PUB snapshot (unsolicited, 1 Hz)

A full snapshot object (§6). Emitted on the PUB socket only.

### 5.2 REP request → response

Request body is **either** a JSON object `{"op":"<name>"}` **or** a bare op word
(e.g. `timing`). Surrounding whitespace/quotes are tolerated. Empty body ⇒ `snapshot`.

| `op` | Response object |
|---|---|
| `snapshot` (or empty) | full snapshot (§6) |
| `timing` | `{ schema, api, t_unix, "timing": {…} }` |
| `gps` | `{ schema, api, t_unix, "gps": {…} }` |
| `rf` | `{ schema, api, t_unix, "rf": {…} }` |
| `dma` | `{ schema, api, t_unix, "dma": {…} }` |
| `ping` | `{ schema, api, "pong": true, t_unix }` |
| *(unrecognised)* | `{ "error": "unknown op", "op": "<echo>" }` (still a valid reply) |

## 6. Snapshot object & data dictionary

### 6.0 Envelope (top level)

| Field | Type | Units | Null? | Always present | Description |
|---|---|---|---|---|---|
| `schema` | string | — | no | yes | Constant `"dsn.health/1"` (timing+gps field compatibility). |
| `api` | string | — | no | yes | Constant `"dsn.pluto_zmq/1"` (this interface + version). |
| `node_id` | string | — | no | yes | Hostname; default `"pluto"`. |
| `board` | string | — | no | yes | Hardware target: `"plutoplus"` or `"libresdr"`. |
| `t_unix` | integer | s | no | yes | Provider wall-clock at emit (UNIX seconds, UTC). |
| `uptime_s` | integer | s | no | yes | System uptime (whole seconds). |
| `timing` | object | — | no | yes | §6.1 |
| `gps` | object | — | no | yes | §6.2 (may be `{}`) |
| `rf` | object | — | no | yes | §6.3 (may be `{}`) |
| `dma` | object | — | no | yes | §6.4 |

### 6.1 `timing` (all keys always present)

Source: FPGA `pps_counter` AXI registers via `/dev/mem` mmap @ `0x7C460000`, and
`/var/log/xocorrect.log`.

| Field | Type | Units | Null when | Range | Source |
|---|---|---|---|---|---|
| `pps_present` | boolean | — | never (false if no counter) | — | STATUS reg `0x7C460008` bit0 |
| `pps_advancing` | boolean \| null | — | until 2 PUB ticks elapse, or no counter | — | SEQ increased over the last 1 Hz tick |
| `pps_seq` | integer \| null | count | no counter | 0…2³²−1 (wraps) | SEQ reg `0x7C460018` |
| `xo_ppm` | number \| null | ppm | no `xocorrect.log` value | ~ −50…+50 | last logged xo_correction error |
| `cnt_clk_hz` | integer \| null | Hz | no counter | ≈ AD9361 `l_clk` | DELTA reg `0x7C460014`: `l_clk` ticks counted in one PPS second (see note) |

Notes: `pps_present` is true only on a `--hwlatch` bitstream after the GPS PPS reaches
F20. On a base (no-counter) build, `pps_present=false` and the three numeric fields are
`null`. `pps_advancing` is computed only on the 1 Hz tick (a sub-second REP reports the
cached verdict but reads `pps_present`/`pps_seq`/`cnt_clk_hz` live).

`cnt_clk_hz` is the counter's clock — the AD936x `l_clk` (data-path clock) — counted
over one GPS PPS second, i.e. the `l_clk` **frequency in Hz**. It is the data clock, a
multiple of the baseband `rf.sample_rate_hz` (for a `30_720_000` rate, commonly
**2×**/`61_440_000` on Pluto+ and **4×**/`122_880_000` on LibreSDR).
GPS-disciplined it sits within a few counts of nominal — the basis for `xo_ppm`.

### 6.2 `gps` (sparse — a key appears only with a fresh value)

Source: persistent gpsd client (`127.0.0.1:2947`, `?WATCH={json:true}`); fields taken
from the latest `TPV`/`SKY`. If a report is stale (>5 s) its fields are omitted; with no
fix the object may be `{}` or carry only `mode`.

| Field | Type | Units | Range | Source (gpsd) |
|---|---|---|---|---|
| `mode` | integer | — | 0 unknown, 1 no-fix, 2 = 2D, 3 = 3D | TPV `mode` |
| `lat_deg` | number | ° | −90…90 | TPV `lat` |
| `lon_deg` | number | ° | −180…180 | TPV `lon` |
| `alt_hae_m` | number | m | — | TPV `altHAE` (ellipsoidal — **use this**, not MSL) |
| `alt_msl_m` | number | m | — | TPV `altMSL` |
| `geoid_sep_m` | number | m | — | TPV `geoidSep` |
| `eph_m` | number | m | ≥0 | TPV `eph` (horizontal error est.) |
| `epv_m` | number | m | ≥0 | TPV `epv` (vertical error est.) |
| `n_sat_used` | integer | count | ≥0 | SKY `uSat` (sats used in fix) |
| `speed_mps` | number | m/s | ≥0 | TPV `speed` |
| `track_deg` | number | ° | 0…360 | TPV `track` |
| `climb_mps` | number | m/s | — | TPV `climb` |

Any field gpsd does not report is omitted: e.g. `track_deg`/`climb_mps` are absent while
stationary, and `alt_*`/`epv_m` are absent on a 2-D fix. Consumers treat absent ⇒ unknown.

### 6.3 `rf` (sparse — a key appears only if its sysfs attribute is readable)

Source: `ad9361-phy` IIO sysfs (device resolved by name under
`/sys/bus/iio/devices/iio:deviceN`).

| Field | Type | Units | Source attribute |
|---|---|---|---|
| `phy` | string | — | constant `"ad9361-phy"` (present iff the phy is found) |
| `rx_lo_hz` | integer | Hz | `out_altvoltage0_RX_LO_frequency` (**actual** chip LO — compare to your requested LO to catch the silent clamp) |
| `tx_lo_hz` | integer | Hz | `out_altvoltage1_TX_LO_frequency` |
| `sample_rate_hz` | integer | Hz | `in_voltage_sampling_frequency` |
| `rf_bandwidth_hz` | integer | Hz | `in_voltage_rf_bandwidth` |
| `rx_gain_db` | number | dB | `in_voltage0_hardwaregain` |
| `gain_control_mode` | string | — | `in_voltage0_gain_control_mode` (`manual`/`slow_attack`/`fast_attack`/`hybrid`) |
| `rf_port_select` | string | — | `in_voltage0_rf_port_select` |

### 6.4 `dma` (best-effort; both keys always present)

Source: non-destructive scan of the kernel log ring (`klogctl`) for `cf_axi`/`ad9361`
error/timeout/under-overflow lines.

| Field | Type | Null? | Description |
|---|---|---|---|
| `rx_ok` | boolean | no | `false` iff a matching DMA-error line is in the ring; else `true` |
| `last_error` | string \| null | yes | the matching kernel-log line (truncated to 200 chars), else `null` |

> **Best-effort caveat:** a wedge that does not log (some errno-110/`ETIMEDOUT`
> stalls) still reads `rx_ok=true`. Treat `rx_ok=false` as a trustworthy negative
> signal and `rx_ok=true` as "no evidence of fault", not a guarantee.

## 7. Error handling

| Condition | Behaviour |
|---|---|
| Unrecognised `op` | REP returns `{"error":"unknown op","op":"<echo>"}` (valid reply; never silent) |
| Counter absent (base build) | `timing.pps_present=false`, numeric timing fields `null`; other blocks normal |
| gpsd unavailable / no fix | `gps` block sparse or `{}`; provider auto-reconnects to gpsd (~2 s) |
| phy sysfs unreadable | affected `rf` keys omitted |
| kernel ring unreadable | `dma.rx_ok=true`, `last_error=null` |
| Malformed REP request | parsed leniently (bare word / `{"op":…}` / empty→snapshot); never crashes |

The provider never sends a partial/invalid JSON object; every REP request yields
exactly one well-formed JSON reply.

## 8. Timing & sequencing

| Parameter | Value | Notes |
|---|---|---|
| PUB period | 1000 ms | monotonic; catches up after a stall without bursting |
| GPS staleness window | 5000 ms | older TPV/SKY fields are dropped |
| gpsd reconnect backoff | ~2000 ms | on disconnect/error |
| REP latency | sub-ms server-side | registers + sysfs read live per request; network RTT adds to wall-clock |
| `dma` last_error cap | 200 chars | truncated |

## 9. Versioning & compatibility

- The interface version is carried in `api` (`dsn.pluto_zmq/1`). `schema`
  (`dsn.health/1`) marks `timing`+`gps` field-name compatibility with HTTP `/health`.
- **Compatibility rule:** consumers MUST ignore unknown object keys and tolerate
  absent optional keys. Additive fields/blocks/ops are **minor**, non-breaking changes
  within `dsn.pluto_zmq/1`. Renames, removals, type changes, or transport changes bump
  the major (`/2`).

## 10. Security

- **Read-only by construction.** No op writes any register, retunes, or initiates a
  capture. There is no socket-level auth.
- **Confidentiality boundary = the Pluto's local interfaces.** By default the provider
  binds all interfaces (`0.0.0.0`), serving the same read-only telemetry on each. The
  `gps` block contains position, so this is appropriate only because the Pluto's
  interfaces are local (wired LAN + USB gadget) and the box is **not** placed on the
  tailnet by design (the edge host is the tailnet node). To narrow the exposure to a
  single interface, set `ZMQ_BIND` to that address.
- For untrusted networks: do not merely change the bind — add CurveZMQ (encryption +
  client keys) and coarsen/round `gps` position. Such a deployment is a new interface
  revision, not a config tweak.

## 11. Interface states / startup

1. Boot → `S50gpsd` starts gpsd → `S65zmqapi` launches `pluto_zmqd` (after networking).
2. The provider binds PUB+REP immediately and begins publishing; `timing`/`rf`/`dma`
   are valid at once, `gps` populates after gpsd reports (and a fix, for position).
3. `pluto_zmqd --print` emits one snapshot to stdout and exits (offline diagnostic; no
   sockets bound).

## 12. Wire examples

REP (request → reply):
```
-> ping
<- {"schema":"dsn.health/1","api":"dsn.pluto_zmq/1","pong":true,"t_unix":1750000000}

-> {"op":"timing"}
<- {"schema":"dsn.health/1","api":"dsn.pluto_zmq/1","t_unix":1750000000,
    "timing":{"pps_present":true,"pps_advancing":true,"pps_seq":42,"xo_ppm":0.0,"cnt_clk_hz":61440000}}
```

PUB (one 1 Hz frame; subscriber uses an empty subscription):

```
{"schema":"dsn.health/1","api":"dsn.pluto_zmq/1","node_id":"pluto","t_unix":1750000000,
 "uptime_s":12345,
 "timing":{"pps_present":true,"pps_advancing":true,"pps_seq":42,"xo_ppm":0.0,"cnt_clk_hz":61440000},
 "gps":{"mode":3,"lat_deg":37.1234567,"lon_deg":-122.7654321,"alt_hae_m":42.7,"alt_msl_m":75.3,
        "geoid_sep_m":-32.6,"eph_m":3.1,"epv_m":5.4,"n_sat_used":9,"speed_mps":0.03,"track_deg":118.2,"climb_mps":0.0},
 "rf":{"phy":"ad9361-phy","rx_lo_hz":2400000000,"tx_lo_hz":2450000000,"sample_rate_hz":30720000,
       "rf_bandwidth_hz":18000000,"rx_gain_db":71.0,"gain_control_mode":"slow_attack","rf_port_select":"A_BALANCED"},
 "dma":{"rx_ok":true,"last_error":null}}
```

## 13. Verification

Conformance-tested against the daemon built from `services/pluto_zmqd.cpp` (compiled
for x86 + cross-compiled ARMv7), run with a fake gpsd (3-D fix) and a stub
`xocorrect.log`. **54/54 assertions passed**, covering: the §6.0 envelope constants
and types; every §5.2 op (`ping`/`snapshot`/`timing`/`gps`/`rf`/`dma`/unknown) in both
the bare-word and `{"op":…}` forms plus empty→snapshot; §6.1 `timing` key set, types,
the no-counter null-degradation (§7), and the `xo_ppm` parse (`(+0.033ppm)`→`0.033`);
the full §6.2 `gps` data dictionary with lat/lon precision preserved; §6.4 `dma`; and
§4.2/§4.3 PUB framing (single frame, valid JSON, no trailing newline, and a
non-matching subscription receiving nothing — proving there is no topic prefix).

Two aspects can't be exercised off-target — `rf` field *values* (need `ad9361-phy`
sysfs; off-target only the absence path `rf:{}` is checked) and counter-present `timing`
values (need the `--hwlatch` `pps_counter` at `0x7C460000`). Both were then covered by an
**on-hardware run** (Pluto+ at a 3-D fix, `--hwlatch` firmware): REP `ping`/`snapshot`
and the 1 Hz PUB heartbeat exercised over TCP from a LAN client. Confirmed live:
`timing` with `pps_present=true`, advancing `pps_seq`, `xo_ppm=0.0`, `cnt_clk_hz` (≈2×
`sample_rate_hz`); a real `gps` 3-D fix (`track_deg` correctly omitted while stationary);
and real `rf` chip values. The run also surfaced and fixed two issues now in the binary:
`rx_gain_db` was emitted as `"71.000000 dB"` (string) — the daemon now strips the unit
and emits the number (§6.3); and the bind defaulted to a hardcoded subnet that left it on
loopback — now `0.0.0.0` by default with a `ZMQ_BIND` override (§4.1).
