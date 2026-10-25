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
{ "pong": true, "api": "dsn.pluto_zmq.ctl/1", "schema": "dsn.health/1", "t_unix": 1782523200.123,
  "caps": ["held_arm", "zero_copy", "start_check"], "max_block_size": 134217728 }
```
- `pong` = boolean `true`. `api` starts with `"dsn.pluto_zmq"` (exactly
  `"dsn.pluto_zmq.ctl/1"`). This is how DSN auto-discovery confirms the control port.
- `caps` (absent on older builds) says what `capture` can do, so a client can size and
  schedule captures without trial and error:
  - `held_arm` — the window is released only once the buffer is queued (§7, arming): a
    capture fits in `offset + samples + 10 ms + 4096 samples ≤ 1 s − 20 ms`, and the
    lead `t0_gps` needs doesn't depend on its length (§4). Without it: the window is
    1.5× the capture, armed 0.35 s before `t0_gps`.
  - `zero_copy` — the IQ frame is sent straight from the DMA buffer.
  - `start_check` — `ctl:start_check_ms` / `ctl:start_edge_latched` are in the meta.
- `max_block_size` (bytes, absent on older builds) — the kernel's DMA block cap now;
  `samples × 4` must fit in it.

## 4. `capture` — request

A single JSON object. Optional fields are omitted when unset — do not assume presence.

| Field | Type | Req? | Meaning |
|---|---|---|---|
| `op` | string | yes | `"capture"` |
| `freq_hz` | integer | yes | requested RX LO, Hz |
| `sample_rate_hz` | integer | yes | baseband complex sample rate, Hz |
| `samples` | integer | yes | number of complex samples to return; up to ~0.97 s with `tdd_sync` (§7, capture length) |
| `require_gps` | bool | yes | refuse unless a live PPS is present (default true if absent) |
| `tdd_sync` | bool | yes | gate sample 0 to the PPS-anchored frame edge (TDOA mode) |
| `t0_gps` | number | opt* | agreed 1PPS edge, absolute seconds; present when `tdd_sync` |
| `offset_samples` | integer | opt | samples to skip past the edge before sample 0 (default 0) |
| `gain_db` | number | opt | manual RX gain, dB; omitted ⇒ `slow_attack` AGC |
| `node_id` | string | opt | echoed to meta as `gpsanchor:node_id` |
| `lat`,`lon`,`alt` | numbers | opt | antenna geotag (deg, deg, m HAE) → `gpsanchor:antenna_position` |

\* When `tdd_sync` is true, `t0_gps` is supplied and the server releases the PPS window
into the DMA in the second before it (§7, arming) — so every node given the same `t0_gps`
grabs the **same** PPS edge. Before that the server retunes, programs the window, and
waits for a fresh PPS (up to 1 s) that proves the GPS is live and anchors the window; it
then needs `t0_gps` more than 0.35 s after that PPS. So the lead a request needs is
**the retune + up to 1 s + 0.35 s**, at any capture length up to ~0.95 s:
- **Same rate as the last request: send `t0_gps` ≥ ~1.5 s ahead.** The retune is then a
  set of same-value writes, ≤ ~0.2 s.
- **A different `sample_rate_hz`: add up to ~1.5 s** (≥ 3 s ahead covers any request).
  A new rate re-runs the AD9361's RX analog-filter calibration, which is slowest at low
  bandwidths: measured 30.72 → 5 MS/s ≈ 1.5 s, 30.72 → 12.5 MS/s ≈ 0.7 s, back up to
  30.72 MS/s ≈ 0.4 s.

Measured on a Pluto+ with a live PPS, 2026-10-25, integer `t0_gps` sent exactly that far
ahead: at a fixed rate 0.95 s captures work from 1.2 s (5 MS/s) and 1.1 s (30.72 MS/s);
a request sent too late is refused with how far ahead it still was after the retune and
the PPS wait. (The first v2.1.0 build programmed the window after that PPS, so a long
window started mid-second and needed ~1 s more lead than a short one.)

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
  - ⚠️ **The `tdd_pps_latch` path needs a bitstream that actually contains the DMA-start
    latch registers** (`LATCH_COUNT`/`LATCH_SEQ` at 0x3C/0x40, added in HDL commit
    `d329bbc`, built via `--hwlatch`). The **prebuilt `v1.5` bitstream predates that commit**
    (its `pps_counter` has a 6-bit address decode: reading 0x40 aliases back to the 0x00 ID
    `0x50505343`, and 0x3C reads 0). On that image the latch can **never** fire, so every
    capture uses `tdd_pps_window` — a frame-grid *assertion* that the window opened on a PPS
    edge, not a measurement. To get true ±~16 ns `gps_ns0`, rebuild the bitstream from
    `d329bbc`+ (`docker-run.sh --vivado <vivado-2023.2> --hwlatch`, which also re-drives
    `axi_tdd/sync_in` from `pps_tick` so the frame re-anchors every PPS instead of free-
    running). The firmware already reads the latch correctly — it just needs the register to
    exist. Confirm on hardware with `devmem 0x7C460040 32`: a real latch counts up from a
    small value; `0x50505343` means the latch isn't in the image.
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
  latch_rms_ns (number) }`. `degraded` is true if PPS is absent, a coarse-second
  skew was detected (above), **or** the start self-check failed (`ctl:start_check_ms`). Also emitted: `gpsanchor:cnt_clk_hz`, `:pps_seq`,
  `:pps_count`, `:sample_index0`, `:method`, `:second_source`, `:coarse_skew_s`,
  `core:datetime`, `core:sample_start`.
- `captures[0]["ctl:alloc_ms"]` (number) — time to allocate the DMA buffer (≈ 300 ms for
  118 MB), and `captures[0]["ctl:max_block_size"]` (integer bytes) — the kernel's DMA
  block cap at capture time, which bounds `samples × 4` (§7, capture length).
- `captures[0]["ctl:start_check_ms"]` (number) and `["ctl:start_edge_latched"]` (bool) —
  a gated capture's self-check, from raw counter ticks: (when the block finished − its
  duration) − the latched start edge. ≈ +0.07 ms when the DMA started on the latched
  edge. Negative (block finished early) or no edge latched means the DMA started before
  the edge it is labeled with; the capture is flagged `degraded` — drop it.
  `captures[0]["ctl:arm_frame_pos"]` (integer `cnt_clk` counts) is where in the frame the
  window was released (§7, arming). All three are 0 / true for ungated captures.
- `captures[0]["ctl:cnt_clk_settled"]` (bool) — whether `PPS_DELTA` (the counts in the
  last GPS second, reported raw as `gpsanchor:cnt_clk_hz`) was within 1000 ppm of
  `l_clk` for this rate. Within ~2 s of a sample-rate change it counts a mix of the old
  and new rates; the server then converts counts to time at the nominal `l_clk`
  instead, and `timing:health.xo_ppm` (computed from the raw value) is meaningless for
  that capture.

### Frame 1 — IQ payload (raw bytes)

`ci16_le` — interleaved int16 LE `I0,Q0,I1,Q1,…`, **4 bytes per complex sample**, raw
ADC counts, no header/scaling. Length = `samples × 4`. One ZMQ frame, sent zero-copy
straight from the DMA buffer: 118 MB (0.96 s at 30.72 MS/s) arrives in ≈ 2.5 s after
the capture ends over GbE (≈ 45–55 MB/s).

## 6. `capture` — error reply (one frame)

```json
{ "error": "not GPS-trusted (pps_present=false)", "api": "dsn.pluto_zmq.ctl/1" }
```
Used for: PPS absent while `require_gps`; `tdd_sync` without a live PPS (arming an
unfillable window would wedge the DMA); `sample_rate_hz` over the channel-mode max (§7);
`offset_samples + samples` past the PPS window (the message gives the largest
`samples` that fits); `t0_gps` less than 0.35 s or more than 60 s ahead on arrival, or no
longer ahead after the retune and the PPS wait (the message gives how far ahead it was;
§4 has the lead); a buffer over the DMA block cap or CMA; the window not releasable before
the edge ("window still open at the arm deadline", e.g. a slow allocation); the previous
reply's IQ still unsent (§7); a DMA/refill fault; a malformed/unknown request. The reply is always exactly one frame.

## 7. Capture semantics & safety

- **PPS gating.** `tdd_sync` disables ADI `axi_tdd` channel 1 temporarily and
  programs `pps_counter`'s RX window, whose frame resets on every GPS PPS. The
  FPGA ORs that window with the normal AXI-TDD streaming gate before the RX DMA.
  One contiguous `iio_buffer_refill` = one gap-free DMA block. After the grab,
  the server disables the PPS window and holds channel 1 HIGH again, as after boot, so
  ungated captures stream freely.
  With channel 1 off, `axi_tdd` drives it at its *latched* polarity, which after boot is
  the synthesis default — HIGH on Pluto — and which latches only across an `enable`
  0 → 1 transition. So a gated capture first disables the core, then runs it once with
  channel 1 off at polarity 0 to latch it LOW; the restore does the same at polarity 1.
  (A full-open window — on 0, off = frame — does not hold it HIGH: enabled without a
  sync, the core sits ARMED with every channel LOW, and builds before v2.1.0 left it that
  way, so an ungated capture after a gated one never started.)
- **Arming.** ADI's `axi_dmac` (`SYNC_TRANSFER_START`) starts each ≤ 16 MB segment on
  the first sample with its sync HIGH — a level test, not an edge — while the latch
  fires only on a rising edge. So a buffer queued while a window is already open starts
  at once, and the latch then labels it with the *next* window. The server therefore:
  (1) programs the window with its output held LOW (`drive_pins` clear); (2) creates the
  buffer, which queues the DMA behind the low gate; (3) in the second before the gated
  edge, once that second's window has closed, sets `drive_pins` — one bit, checked
  against `FRAME_POS` before and after the write — so the next rising edge is the
  gated PPS. Measured with a free-running frame: the DMA starts within 0.1 ms of the
  latched edge at 0.05–0.9 s; the old order (window live from configure, buffer
  created 0.35 s before t0) started 0.5 s captures 375 ms early and 0.9 s captures
  643 ms early, with a gap where the DMA waited for the next window, and labeled
  them with that later edge.
- **Measured anchor.** The FPGA latches the `cnt_clk` count of sample 0 on the DMA-start
  edge (`LATCH_COUNT`/`LATCH_SEQ`, race-free); the server confirms the latch fired for
  *this* capture (seq advanced) and reports the hardware time, else falls back.
- **Rate cap (enforced).** The AD936x data clock is
  `l_clk = interface_multiplier × sample_rate`; overrunning the interface wedges
  the RX DMA (reboot to clear). The server detects the multiplier from the live
  counter and current rate, accepting only a count within 1000 ppm of a whole multiple
  (right after a rate change the counter still holds the old rate), and otherwise uses
  the last multiple it confirmed. Pluto+ uses a 61.44 MHz `l_clk` ceiling (normally
  1×/2×); LibreSDR's validated 2R2T LVDS path uses 4× with a 122.88 MHz ceiling.
  Both therefore cap the common 2R2T configuration at 30.72 MSPS.
- **Capture length.** One capture is one DMA block, gap-free. Three limits apply:
  - *PPS window* (`tdd_sync`): the window stays open for `offset_samples + samples` plus
    10 ms + 4096 samples of margin, and must close ≥ 20 ms before the next PPS. At
    offset 0 that allows ≈ 0.97 s (29.79 M samples at 30.72 MS/s).
  - *DMA block cap*: `samples × 4` ≤ the kernel's `max_block_size`. ADI's boot default
    is 64 MiB (0.55 s at 30.72 MS/s); `S66ctld` raises it to 128 MiB (`CTL_MAX_BLOCK`)
    unless the U-Boot env sets `iio_max_block_size`, which still wins.
  - *CMA* (256 MB): the buffer is one block, allocated once.
- **Memory.** The IQ is sent zero-copy from the DMA buffer, so a capture costs its size
  in RAM once (measured: 118 MB capture → 115 MB less available, of 428 MB). The buffer
  is freed when zmq has written the reply. If a consumer stalls mid-reply for 30 s, the
  server parks the buffer and serves other ops; the next `capture` waits up to 5 s for
  it, then answers "previous capture's IQ is still being sent" until the stalled peer
  reads or disconnects.
- **Blocking** is expected: a reply takes ≈ `max(0, t0_gps − now) + samples/rate +
  transfer`. The client's default timeout is 30 s, so a near-future `t0_gps` is fine.
  One capture at a time (REP serializes). The buffer is allocated as soon as the
  window is programmed, so even a 118 MB buffer (≈ 300 ms) is ready long before the
  release.

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
