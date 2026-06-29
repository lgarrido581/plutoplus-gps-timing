# Interface Control Document — Pluto ZMQ Capture-Control API (`:5562`)

| | |
|---|---|
| **Interface** | `dsn.pluto_zmq.ctl/1` (GPS-anchored capture — a **WRITE** interface) |
| **Provider** | `pluto_ctld` on the Pluto+ GPS-timing firmware |
| **Consumer** | DistributedSensingNetwork ("DSN") capture client (`dsn/pluto_zmq.py`) |
| **Transport** | ZeroMQ `REP` over TCP, port **5562** (libzmq 4.x / ZMTP-3.0) |
| **Encoding** | request: one UTF-8 frame (bare op word **or** JSON object). reply: see §3 |
| **Status** | Implemented & built; capture core is the validated `iq_capture.c`, ported in-memory |
| **Source of truth** | `services/pluto_ctld.cpp` + `services/capture_core.c`. This ICD documents that build. |

Companion to the read-only telemetry interface (`dsn.pluto_zmq/1`, ports 5560/5561,
`docs/PLUTO_ZMQ_ICD.md`). This one **tunes the radio and captures IQ**; it is separate
by design. The authoritative client-facing spec is DSN's `docs/FIRMWARE_CTL_5562_SPEC.md`;
this ICD documents the firmware server built from it.

---

## 1. Scope

One socket, two ops: a liveness **`ping`** and a **`capture`** — "tune to this
frequency/rate, capture N complex samples with sample 0 gated to an agreed future 1PPS
edge, and return them as a SigMF (metadata + raw int16 IQ) pair, stamped with the
*measured* GPS time of sample 0." This lets a fleet take time-aligned snapshots for
TDOA. It replaces the old SSH-pushed `iq_capture` path.

Out of scope: streaming, file writing, per-packet timestamps, control of the telemetry
daemon (5560/5561). DSN's GPS/PPS/LO trust gate reads telemetry independently.

## 2. Transport & framing

- ZeroMQ **`REP`** bound to `tcp://<bind>:5562`. Strict REQ/REP lockstep: **exactly one
  reply per request, always** — a missing reply permanently desyncs the client's REQ
  socket, so every path (incl. malformed input) replies exactly once.
- **Bind:** `0.0.0.0` (all interfaces) by default; env `ZMQ_BIND` restricts it to one
  IP, `ZMQ_CTL_PORT` overrides the port. (Daemon args: `--bind`, `--port`.)
- **Request frame** is either (1) a bare ASCII op word — currently only `ping` — or
  (2) a UTF-8 JSON object with an `"op"` field. Parsing: a body whose first non-space
  char is `{` is treated as JSON and dispatched on its `op`; otherwise the trimmed
  frame text *is* the op (so the literal `ping` works). `{"op":"ping"}` also works.
- **Reply framing encodes the outcome by frame count** — the client decides success
  vs. failure purely by counting frames:

  | Outcome | Frames | Content |
  |---|---|---|
  | `ping` | **1** | one JSON object |
  | `capture` success | **2** | `[ meta-json (UTF-8), iq-bytes ]` |
  | `capture` error / refusal | **1** | one JSON object with an `"error"` key |

## 3. `ping`

Request: `ping` (or `{"op":"ping"}`). Reply (1 frame):
```json
{ "pong": true, "api": "dsn.pluto_zmq.ctl/1", "schema": "dsn.health/1", "t_unix": 1782523200.123 }
```
- `pong` = boolean `true`. `api` starts with `"dsn.pluto_zmq"` (exactly
  `"dsn.pluto_zmq.ctl/1"`). This is how DSN auto-discovery confirms the control port.

## 4. `capture` — request

A single JSON object. Optional fields are omitted when unset — do not assume presence.

| Field | Type | Req? | Meaning |
|---|---|---|---|
| `op` | string | yes | `"capture"` |
| `freq_hz` | integer | yes | requested RX LO, Hz |
| `sample_rate_hz` | integer | yes | baseband complex sample rate, Hz |
| `samples` | integer | yes | number of complex samples to return |
| `require_gps` | bool | yes | refuse unless a live PPS is present (default true if absent) |
| `tdd_sync` | bool | yes | gate sample 0 to the PPS-anchored frame edge (TDOA mode) |
| `t0_gps` | number | opt* | agreed 1PPS edge, absolute seconds; present when `tdd_sync` |
| `offset_samples` | integer | opt | samples to skip past the edge before sample 0 (default 0) |
| `gain_db` | number | opt | manual RX gain, dB; omitted ⇒ `slow_attack` AGC |
| `node_id` | string | opt | echoed to meta as `gpsanchor:node_id` |
| `lat`,`lon`,`alt` | numbers | opt | antenna geotag (deg, deg, m HAE) → `gpsanchor:antenna_position` |

\* When `tdd_sync` is true, `t0_gps` is supplied and the server waits until ~350 ms
before it, then arms — so every node given the same `t0_gps` grabs the **same** PPS edge.

## 5. `capture` — success reply (two frames)

### Frame 0 — SigMF metadata (UTF-8 JSON)

Bold = consumed by DSN (`dsn/offload_capture.py::burst_from_sigmf`):

- **`global["core:datatype"]`** = `"ci16_le"` (must match frame 1).
- **`global["core:sample_rate"]`** (number, Hz) — the actual rate used.
- **`captures[0]["gpsanchor:gps_ns0"]`** (integer ns) — **the measured GPS time of
  sample 0** — the whole point. From the FPGA `pps_counter` DMA-start latch
  (`gpsanchor:method == "tdd_pps_latch"`, sample-exact ±~16 ns) when it fired this
  capture, else a frame-grid snap (`"tdd_pps_window"`), else the free-running anchor
  (`"live_count_at_refill"`). Epoch is the PPS-disciplined `CLOCK_REALTIME` — consistent
  on every node, which is all DSN's cross-node differencing needs.
- **Integer-second anchoring (`tdd_sync` + `t0_gps`).** The hardware sub-second
  (`pps_counter` phase within the second) is unambiguous, but the *integer* second comes
  from the OS clock, which chrony can lock a whole second off (gpsd pinning an NMEA epoch
  to the wrong PPS pulse at 9600 baud — phase-perfect, second wrong). Because `tdd_sync`
  gates sample 0 on the **first PPS at/after the arm point** (`t0_gps − 0.35 s` arm lead),
  sample 0's true integer second is the **scheduled PPS edge** — `ceil(t0_gps − 0.35)`,
  which for a well-formed integer `t0_gps` (a real PPS edge) is just `t0_gps`, and stays
  correct if `t0_gps` carries a fractional part. The server sets
  `gps_ns0 = scheduled_edge·1e9 + HW_sub_second` and reports the source in
  **`captures[0]["gpsanchor:second_source"]`** (`"t0_gps"` when rebased, else
  `"os_clock"`). **Send an integer (PPS-edge) `t0_gps`** for the cleanest contract. If the
  OS clock disagreed with the scheduled edge by ≥1 s, that delta is reported in
  **`captures[0]["gpsanchor:coarse_skew_s"]`** (integer s, signed) and the capture is
  flagged `timing:health.degraded = true` — **a non-zero skew means the arm may have gated
  the wrong physical edge, so the consumer should drop the capture** rather than trust the
  relabeled anchor. (The Level-2 gpsd/chrony hardening prevents the wrong lock in the first
  place.)
- **`captures[0]["core:frequency"]`** (number, Hz) — the **AD9361 LO read back**, not
  the requested `freq_hz` (the chip silently clamps an out-of-range LO); DSN trusts this.
- `global["timing:health"]` = `{ pps_present (bool), degraded (bool), xo_ppm (number),
  latch_rms_ns (number) }`. `degraded` is true if PPS is absent **or** a coarse-second
  skew was detected (above). Also emitted: `gpsanchor:cnt_clk_hz`, `:pps_seq`,
  `:pps_count`, `:sample_index0`, `:method`, `:second_source`, `:coarse_skew_s`,
  `core:datetime`, `core:sample_start`.

### Frame 1 — IQ payload (raw bytes)

`ci16_le` — interleaved int16 LE `I0,Q0,I1,Q1,…`, **4 bytes per complex sample**, raw
ADC counts, no header/scaling. Length = `samples × 4`. One ZMQ frame (8 MB for 2 M
samples is fine over a LAN).

## 6. `capture` — error reply (one frame)

```json
{ "error": "not GPS-trusted (pps_present=false)", "api": "dsn.pluto_zmq.ctl/1" }
```
Used for: PPS absent while `require_gps`; `tdd_sync` without a live PPS (arming an
unfillable window would wedge the DMA); `sample_rate_hz` over the channel-mode max (§7);
a DMA/refill fault; a malformed/unknown request. The reply is always exactly one frame.

## 7. Capture semantics & safety

- **PPS gating.** `tdd_sync` programs ADI `axi_tdd` channel-1 as a per-frame window
  (`on_raw = offset_samples`), `sync_external=1` so the 1 s frame re-anchors on each GPS
  PPS, then arms the RX DMA (`sync_start_enable=arm`). One contiguous `iio_buffer_refill`
  = one gap-free DMA block. After the grab it disarms and restores a full-open window
  (it never *disables* the core — that starves the DMA and needs a reboot).
- **Measured anchor.** The FPGA latches the `cnt_clk` count of sample 0 on the DMA-start
  edge (`LATCH_COUNT`/`LATCH_SEQ`, race-free); the server confirms the latch fired for
  *this* capture (seq advanced) and reports the hardware time, else falls back.
- **Rate cap (enforced).** The AD9361 data clock `l_clk = n_active_rx × sample_rate`;
  overrunning the interface wedges the RX DMA (reboot to clear). The server detects
  `n_active_rx` from the live counter vs. the current rate and **refuses** rates above
  `61.44 MHz / n_active_rx` (61.44 MSPS for 1R1T, 30.72 MSPS for 2R2T) with an error
  frame — it does not attempt the capture.
- **Blocking** is expected: a reply takes ≈ `max(0, t0_gps − now) + samples/rate +
  transfer`. The client's default timeout is 30 s, so a near-future `t0_gps` is fine.
  One capture at a time (REP serializes).

## 7a. Coexistence — one radio owner

The AD9361 is a single shared resource. **`pluto_ctld` must be the *only* thing driving
the radio.** Two concurrent owners of the chip will wedge the RX DMA (`errno-110`, "window
missed / DMA error" on every subsequent capture until reboot) — this is a hardware
limitation, not a daemon bug, and it cannot be papered over server-side.

- **Do NOT also run a host-side libiio capture path** (e.g. the deprecated
  `TddPlutoCaptureSource` that arms `sync_start_enable` / reprograms `axi_tdd` over the
  *network* libiio backend). Pick one path: the `:5562` offload API **or** host-side
  libiio — never both at once. Running both is the classic way to wedge the DMA.
- **`xo_correct.sh` is made capture-safe.** Writing `xo_correction` re-derives the chip
  clocks and resets the sample rate (a rate change mid-DMA wedges the capture). While a
  capture is in flight `pluto_ctld` drops `/tmp/pluto_ctld.capturing`; `xo_correct.sh`
  **skips its correction** while that lock is fresh (stale locks > 2 min are ignored, and
  `/tmp` is tmpfs so it clears on reboot — a crashed daemon cannot stall discipline). GPS
  discipline simply resumes between captures.
- A wedge, if one is provoked anyway, **requires a reboot** (`ssh root@<pluto> reboot`) —
  a power-cycle is not needed, and disabling the `axi_tdd` core does not clear it.

## 8. Security

A **WRITE** interface (tunes + captures). On the trusted private hardware LAN, no auth
is acceptable. **Do not expose 5562 to the tailnet / any shared network unauthenticated**
— add CurveZMQ (client keys) first; that is a `/2` revision, not a config flag. The
default `0.0.0.0` bind is for the local wired/USB LAN; the Pluto is not on the tailnet by
design. Restrict with `ZMQ_BIND` where appropriate.

## 9. Versioning

`api = "dsn.pluto_zmq.ctl/1"`. Adding request fields or meta keys is a non-breaking
minor change (consumers ignore unknown keys). Renames / type changes / transport changes
⇒ `/2`. The `ping` envelope keeps `schema = "dsn.health/1"` for stack compatibility.

## 10. Build & runtime

- **Package:** `buildroot/package/pluto-ctld` — generated by `docker-build-inner.sh`
  from `services/{pluto_ctld.cpp, capture_core.c, pps_timestamp.c, …, S66ctld}`. Links
  **libzmq** (`BR2_PACKAGE_ZEROMQ`) + **libiio** (`BR2_PACKAGE_LIBIIO`, already shipped),
  needs `libstdc++`. Building inside buildroot uses the Pluto's own toolchain, avoiding
  the glibc-≤2.25 cross-build dance the standalone `iq_capture` needs.
- **Autostart:** `/etc/init.d/S66ctld` (after `S65zmqapi` + gpsd + networking).
- **Capture core:** `capture_core.c` is a refactor of the validated DSN/sdr-stack
  `device/streamer/iq_capture.c` — same tune/arm/refill/latch logic, returning
  meta + IQ in memory instead of writing SigMF files.

### Test client (any host with `pyzmq`)
```python
import zmq, json
s = zmq.Context.instance().socket(zmq.REQ)
s.setsockopt(zmq.RCVTIMEO, 30000); s.connect("tcp://<pluto>:5562")
s.send_string("ping"); print(s.recv_string())
s.send_string(json.dumps({"op":"capture","freq_hz":100_300_000,"sample_rate_hz":30_720_000,
    "samples":200_000,"require_gps":True,"tdd_sync":True,"t0_gps":<future_sec>}))
f = s.recv_multipart()
meta = json.loads(f[0]); print(meta["captures"][0]["gpsanchor:gps_ns0"], len(f[1]), "bytes")
```
