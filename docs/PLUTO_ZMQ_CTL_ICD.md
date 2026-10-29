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
  - `stream`, `tx` — §7b and §7c.
  - `tdd_status` — §7d.
  - `dechirp` — §7e: this bitstream has the PL `dechirp_decim` block, so `stream_start`
    takes a `dechirp` block. Absent on bitstreams without it.
  - `free_run` — `stream_start` takes `"require_pps": false` (§7b, free-running epochs).
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
- **A different `sample_rate_hz`: add up to ~3 s** (≥ 4.5 s ahead covers any request).
  A new rate re-runs the AD9361's RX analog-filter calibration, which is slowest at a
  few MHz and varies between runs. Measured (rate + bandwidth writes):
  - 30.72 → 2.5 MS/s ≈ 3.0 s;
  - 2.5 → 5 MS/s ≈ 2.9 s;
  - 30.72 → 5 MS/s ≈ 1.5–1.7 s;
  - 30.72 → 12.5 MS/s ≈ 0.7–0.9 s;
  - back up to 30.72 MS/s ≈ 0.4–0.5 s;
  - 30.72 → 1 or 2 MS/s ≈ 0.4 s.

  An LO change alone is ~20 ms, even 94.7 MHz ↔ 5.8 GHz.

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
  counter and current rate. It accepts only a count within 1000 ppm of a whole multiple
  and taken at least 2.1 s after the last rate change, and otherwise uses the last
  multiple it confirmed. Until then the counter still holds the old rate, which is an
  exact multiple of the new one when the rates differ by a power of two. Pluto+ uses a 61.44 MHz `l_clk` ceiling (normally
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

## 7b. Continuous stream — `stream_start` / `stream_stop` / `stream_status`

Advertised by `"stream"` in `ping`'s `caps`. A stream sends RX0 (and RX1 with
`channels: 2`, 2R2T mode) continuously to a receiver: one ZMQ PUSH message per DMA
block, in the format of `services/iqwire.h`.
- **Message:** a 64-byte header plus 24-byte markers, then the ci16 samples, sent
  zero-copy.
- **Receiver:** the host binds a PULL socket; the radio connects to it. The reference
  receiver keeps the last N seconds in a shared-memory ring that readers query by GPS
  time.

While a stream runs, the radio is the stream's: `capture` answers
`"radio is streaming (stream_stop first)"`. The stream also holds
`/tmp/pluto_ctld.capturing` the whole time, so `xo_correct.sh` doesn't step the clocks
under the DMA. The clock is therefore not disciplined while streaming; its rate is
measured per second by the PPS markers instead.

```json
{"op":"stream_start","connect":"tcp://192.168.50.20:5563","freq_hz":94700000,
 "sample_rate_hz":5000000,"gain_db":40,"channels":1,"block_ms":100,"blocks":8}
```
| field | default | meaning |
|---|---|---|
| `connect` | — | the receiver's `tcp://HOST:PORT` (required) |
| `freq_hz`, `sample_rate_hz` | — | LO and per-channel rate (required) |
| `gain_db` | AGC | manual RX gain; omitted ⇒ `slow_attack` |
| `channels` | 1 | 1, or 2 (2R2T only) |
| `block_ms` | 100 | DMA block length, 10–300 ms (rounded down to 1024 samples) |
| `blocks` | 8 | kernel blocks queued, 2–32: how long the send may stall without loss |
| `require_pps` | true | false: an epoch whose arm sees no PPS edge starts free-running instead of failing (below) |

**Reply.** Once the first epoch's sample 0 has landed on its PPS edge, the reply is one
frame, `{"ok":true,"api":...,"stream":{...status...}}`. If the stream can't start, it's
one `{"error":...}` frame. The causes include: no live PPS (with `require_pps`), no
receiver taking blocks,
more than ~56 MB/s (`sample_rate_hz × channels × 4` past the Pluto+'s send ceiling), or a
bad request. The reply takes up to the retune time plus ~1–2 s, and at most 15 s:
- **First arm:** it is retried once (a missed PPS edge, say). The failed try still
  counts in `ended`.
- **Rate just changed:** if no `l_clk` multiple has been confirmed since `pluto_ctld`
  started, the start first waits until 2.1 s after the change (by `tx_load`, for
  example).

A refused `stream_start` also shows in `stream_status` while nothing streams: state
`failed` with the refusal as `error`. The other fields still describe the last stream that
ran.

`stream_stop` sends one more block, flagged `LAST`, then stops. It restores the gate as
a capture leaves it (channel 1 HIGH, PPS window off) and answers with the final status.
`stream_status` answers at any time.

The status object holds:
- **state:** `idle|arming|streaming|failed`;
- **stream:** `connect`, `sample_rate_hz` and `center_freq_hz` as read back, `channels`,
  `block_samples`, `blocks_queued`, `ticks_per_sample`;
- **counters:** `epoch`, `epochs`, `epoch_t0_s`, `blocks`, `seconds`, `MBps`, `lag_ms`,
  `max_lag_ms`, `xo_locked_at_start` (at the current epoch's start);
- **timing:** `require_pps` as requested; `timing` is `"pps"` or `"free_running"` for the
  current (or last) epoch, `null` before the first;
- **endings:** `ended` counts epochs by reason (`overflow`, `lag`, `send`, `refill`,
  `arm`, `no_edge`, `pps_back`), with the last `error` (`pps_back` is not one);
- **dechirp:** `null`, or the PL block's state for a dechirp stream (§7e).

**Epochs.** Sample 0 of an epoch is latched in hardware on a PPS edge (`epoch_t0_ns`,
about +100 ns), as in a gated capture. The DMA then free-runs, and every later PPS edge
rides along as a marker at its counter tick. The samples of an epoch are continuous.
These end an epoch:
- a DMA overflow;
- a lag past the queue;
- a refill error;
- a send the receiver doesn't take (no receiver, or a stall over 30 s).

A new epoch then starts on the next PPS edge, flagged `EPOCH_START` (plus `OVERFLOW` when
samples were lost), so a gap is never hidden inside an epoch.

**Free-running epochs** (`"require_pps": false`). The PPS is preferred: each arm waits up
to 1.5 s for a PPS edge, as with `require_pps`. With none, instead of failing, the daemon
holds the gate open itself:
- **Sample 0:** still the hardware-latched gate edge, so the samples, the TX markers and a
  dechirp stream's sweep phase are exactly as in a PPS epoch.
- **Label:** `epoch_t0_ns` is the radio's system clock at that edge, read beside the
  counter. It is as good as chrony's holdover (typically ms), not GPS.
- **Wire:** every block of the epoch carries `IQW_F_FREE_RUN` (bit 4), and no PPS markers
  follow; the sample clock is undisciplined, so a reader maps time at the nominal rate.
- **Return:** once the PPS has been back for 10 edges in a row, about a second apart, the
  epoch ends (`ended.pps_back`) and the next one arms on the PPS. That costs one gap of
  one to two seconds. A PPS that flaps can cost a gap each time it holds for 10 s.

The default (`require_pps` true or absent) is unchanged: no PPS edge, no stream.

**Measured on node1** (2026-10-25, 5 MS/s, 100 ms blocks, to the Jetson over GbE):
- **Load:** `pluto_ctld` at ~17% CPU, the Jetson receiver at ~7% of a core.
- **Clock:** 9,999,998 counts per GPS second (nominal).
- **Edge read:** a window read at a PPS edge starts on the edge sample.

Sustainable: ~12.5 MS/s on one channel (≈ 50 MB/s; the prototype's limit).

## 7c. Cyclic TX — `tx_load` / `tx_start` / `tx_stop` / `tx_status`

Advertised by `"tx"` in `ping`'s `caps`. TX1 plays one buffer over and over, for example
one radar CPI of whole sweeps. The order:
1. **`tx_load`:** TX tuning can disturb a running RX stream, so this is refused while
   one runs.
2. **`stream_start`:** at TX's sample rate; it's refused at any other rate while TX is
   loaded.
3. **`tx_start`:** starts the loaded buffer.

`tx_load` is a two-frame request. Frame 0 is
`{"op":"tx_load","freq_hz":2.4e9,"sample_rate_hz":4e6,"gain_db":-10,"bandwidth_hz":0}`
(optional `"latency_samples"`, below).
Frame 1 is the ci16 I/Q of one period: at least 64 samples, a whole number of sweeps,
full scale ±32767 (the DAC takes the top 12 bits).
- **Defaults:** `gain_db` is TX1's attenuation, −89.75 to 0, default −10;
  `bandwidth_hz` 0 means the rate.
- **Steps:**
  1. Tunes TX (rate shared with RX, TX LO, bandwidth) with the attenuation at −89 dB.
  2. Puts the AD9361 in FDD.
  3. Holds axi_tdd channel 2, the TX DMA's gate, HIGH (off, polarity 1).
  4. Fills a cyclic buffer, then sets the requested attenuation.
- **Does not start it.** The reply carries the buffer's 64-bit FNV-1a `hash`.

`tx_start` pushes the buffer, which plays until `tx_stop`. pluto_ctld reads the
pps_counter just before and after the push. With a stream running, the next block carries:
- **`TX_START`:** at the tick where TX sample 0 reaches the RX samples, with value =
  buffer length in samples. Sweep boundaries are tick + k·len·ticks_per_sample.
  - **Placement:** the DMA starts at the end of the push, so the tick is the after-push
    reading plus `latency_samples`. By default that is 68.5 − 2.375 per MS/s,
    rounded, with the rate clamped to the 4–12 MS/s span measured: 59 at 4 MS/s, 50 at
    8, 40 at 12. `tx_load`'s `latency_samples` overrides it.
  - **Calibration:** measured with the radar's direct path on node1, TX and RX antennas
    ~1 m apart, three to six starts at each rate: ~59 samples at 4 MS/s, ~50 at 8, ~40
    at 12. With the default, the markers landed within ±5 samples at 4 and 8 MS/s. The
    model is a delay fixed in samples (the filter chains) less one fixed in time
    (~2.4 µs). Outside 4–12 MS/s, measure and pass `latency_samples`.
- **`TX_HASH`:** at the same tick, with value = the hash.

Every later epoch restates both at its first period boundary, so the phase is known in
any epoch. The marker is good to about ±5 samples; a direct-path matched filter can
refine it. `tx_status` reports `start_window_counts` (the push's length)
and `latency_samples`.

A TX started before the stream is placed only if it started less than 2^31 counter ticks
earlier (~3.5 min at 5 MS/s).

`tx_stop` sets the attenuation to −89 dB, then frees the buffer. Channel 2 stays HIGH, which
transmits nothing with no buffer loaded. `tx_status` reports `loaded`, `running`,
`samples`, `sample_rate_hz`, `freq_hz`, `gain_db`, `hash`, `starts`, `start_live`,
`start_window_counts`, `underflows` and `ensm_was`.

`underflows` counts the `tx_status` reads that found the DAC's sticky underflow bit set
since the previous read; it is cleared 2 ms after the push. A cyclic DMA that runs dry
resumes late, which shifts the waveform against `TX_START`. Nonzero means resync from the
direct path. On node1 it stayed 0 over 60 s at 4 MS/s and 40 s at 12 MS/s, with RX
streaming at the same rate (45 MB/s at 12 MS/s).

Between captures and streams, `pluto_ctld` now holds both channel 1 (RX) and channel 2
(TX) HIGH. Another client driving the TDD core must relatch polarity 0 before using
windows (`docs/GOTCHAS.md`). §7d shows what is latched.

`tdoa/ctl_tx_test.py` runs the whole order against a receiver and checks the markers in
the ring.

## 7d. TDD gate state — `tdd_status`

Advertised by `"tdd_status"` in `ping`'s `caps`. The axi_tdd core gates both DMAs:
- channel 1 is the RX DMA's sync, ORed with pps_counter's PPS window;
- channel 2 is the TX DMA's.

**Finding the core.** On the Pluto+ it is IIO device `adi-iio-fakedev`, labeled
`iio-axi-tdd-0` (iio:device5 on node1). pyadi's `tddn` looks for `axi-core-tdd`, the
newer driver, which this firmware doesn't have. LibreSDR's TDD v2 is the platform device
`7c440000.tdd`.

**Why sysfs alone isn't enough.** A channel's `polarity` attribute is only the register.
It reaches the output at the core's next `enable` 0 → 1 transition. While the channel is
off, or the core is disabled, the channel drives the polarity latched then. So reading
`out_channel1_polarity = 0` doesn't mean channel 1 is LOW.

Request `tdd_status` (or `{"op":"tdd_status"}`). Reply, one frame:
```json
{"ok":true,"api":"dsn.pluto_zmq.ctl/1","tdd":{"found":true,
 "sysfs":"/sys/bus/iio/devices/iio:device5","enable":1,"state":1,"burst_count":0,
 "frame_length_raw":10000000,"latched_at":1793017745.120,
 "channels":[{"enable":0,"polarity":0,"on_raw":0,"off_raw":0,"latched":0},
             {"enable":0,"polarity":1,"on_raw":0,"off_raw":0,"latched":1},
             {"enable":0,"polarity":1,"on_raw":0,"off_raw":0,"latched":1}]}}
```
- **Core:** `enable`, `state` (0 idle, 1 armed, 3 running), `burst_count` and
  `frame_length_raw` as read from sysfs; −1 is an attribute that isn't there.
- **Channels (0–2):** each has its registers, plus `latched`. That is the polarity at
  `pluto_ctld`'s own last `enable` 0 → 1 (at `latched_at`), so what an off channel drives
  now. −1 means none since `pluto_ctld` started.
- **Other clients:** a client that toggles `enable` itself makes `latched` stale. The
  example above is the idle state `pluto_ctld` leaves, with RX and TX gates both HIGH.

## 7e. PL dechirp — `stream_start` with `dechirp`

Advertised by `"dechirp"` in `ping`'s `caps`, only on a bitstream built with the
`dechirp_decim` HDL overlay. The block sits between the AD9361 core's RX output and the RX
DMA:
- **Dechirp:** it multiplies each RX sample by the conjugate of the TX word the DAC sent
  `align_samples + 1` strobes earlier.
- **Decimation:** a CIC3 decimates by D = 2^k, with its state zeroed at every sweep start.
- **Sweep starts:** a start is where the replica's words (n−1, n) equal the loaded TX
  buffer's words 0 and 1.

So the DMA, and the stream, carry fs/D sweep-aligned ci16 beat samples. The register map
and arithmetic are in `services/dechirp_pl.h`; the design is radar-stack
`docs/PL_DECHIRP_DECIM.md`.

**Bypass.** At power-up the block is a wire. `pluto_ctld` holds it there at start, before
every `capture`, for every raw stream and at the end of every stream (any exit path), so
captures and raw streams see the stock path.

**Presence.** The block is touched only when `/etc/plutoplus/pl_features` (packed into the
same FIT as the bitstream) lists `dechirp_decim 0x7C470000 v1`, and its ID register then
reads `0x4443444D` ("DCDM") with VERSION 1.1 or later (the sync-edge re-arm). A read of
an unmapped AXI address aborts, so nothing probes it blindly.

```json
{"op":"stream_start","connect":"tcp://192.168.50.20:5563","freq_hz":5.8e9,
 "sample_rate_hz":30720000,"channels":1,"block_ms":100,"blocks":8,
 "dechirp":{"decim":16,"sweep_samples":12288,"align_samples":100,"filter":"cic3"}}
```
| field | meaning |
|---|---|
| `decim` | D, a power of two from 1 up to 2^(VERSION's max log2 D) (32) |
| `sweep_samples` | input samples per sweep: a multiple of D, below 2^24 |
| `align_samples` | the replica delay beyond one DAC strobe, 0–4094 (optional; below) |
| `filter` | `"cic3"`, the only one (optional) |

**`align_samples`** is the loop from the block's DAC tap to its RX input, in input
samples. It runs through the AD9361's digital chains: mostly a sample count, plus a small
part fixed in time (one sample more per ~9 MS/s). It isn't TX's `latency_samples`. Calibrate it with the direct path: in a beat sweep
the direct path is a tone at slope × residual delay, and the right ALIGN puts it in bin 0.
Measured on node1 (Pluto+, 2r2t), 2026-10-27:

| rate | ALIGN |
|---|---|
| 4 MS/s | 44 |
| 12 MS/s | 45 |
| 30.72 MS/s | 46 |

If the request omits it, `pluto_ctld` uses this table, linear between the points and held
outside them; `stream_status` reports the value used.

**Order:** `tx_load` → `tx_start` → `stream_start`, the reverse of the raw cycle (§7c). The
block emits nothing until the replica shows a sweep start. `stream_start` refuses:
- no `dechirp` cap;
- TX not loaded and running at the stream's rate;
- `channels` other than 1;
- an out-of-range field;
- a TX buffer whose words 0 and 1 also occur anywhere other than k·`sweep_samples`
  (checked cyclically at `tx_load`). A zero guard at the sweep start, or per-sweep
  coding, would give false starts or none. The buffer must be identical sweeps.

**Configuration.** With the block disabled, `pluto_ctld`:
1. soft-resets it;
2. writes DECIM, SWEEP_LEN, ALIGN, PAT0 and PAT1 (TX words 0 and 1 exactly as loaded:
   I in bits 15..0, Q in 31..16) and reads each back;
3. clears bypass and sets enable, once, before the first arm.

Every rising edge of the RX-DMA sync re-arms the block:
- the output is gated and the pipeline cleared;
- the next sweep start re-latches S0.

So each epoch's DMA sample 0 is a sweep start of that epoch.

**The stream.** The header and markers change as follows:
- `sample_rate_hz` = fs/D, and `ticks_per_sample` = (ticks per input sample) × D.
- `epoch_t0_ns` and every marker `tick` still count from input sample 0, the PPS edge.
- Each epoch's first block carries a `DECIM_PHASE` marker (kind 5) with
  `tick` = S0 × input ticks per sample and `value` = S0.
- Output sample m covers input samples S0 + m·D … S0 + m·D + D − 1. A tick maps to output
  samples as `(tick / (ticks_per_sample / D) − S0) / D`.
- The ~56 MB/s send ceiling applies to the output rate.
- `TX_START`/`TX_HASH` are still sent when TX's start can be placed (§7c); the sweep phase
  comes from `DECIM_PHASE`.

`stream_status`'s `dechirp` object:
```json
{"decim":16,"sweep_samples":12288,"align_samples":100,"s0":4711,"healthy":true,
 "locked":true,"running":true,"period":12288,"outputs_per_sweep":768,"period_err":0,
 "saturated":false,"sat_count":0,"tx_running":true,"pat0":"0x00007213","pat1":"0x0A1F7101"}
```
- `s0` — this epoch's DECIM_PHASE.
- `locked` — the detector's last measured `period` equals `sweep_samples`.
- `outputs_per_sweep` — as the block counted it.
- `healthy` — all of: `running`, `locked`, `period` = `sweep_samples`,
  `outputs_per_sweep` = `sweep_samples`/D, and TX running.
- `period_err` — sweep starts that came off schedule since the configuration. A dropped or
  repeated DAC sample counts here; the block re-phases on the next match.
- `saturated`, `sat_count` — product or output saturations.

`tx_stop` during a dechirp stream is allowed, but the output then has no replica
(`healthy` false).

**Measured on node1** (2026-10-27, the radar's dechirp image, the radar's direct path at
5.8 GHz):
- **4 MS/s, D = 8 and 16:** `healthy`, locked, `period_err` 0. The direct path is in
  bin 0 with ALIGN 44.
- **12 MS/s, D = 4:** the dechirped direct path matches the raw path's; ALIGN 45 puts it
  at 0 Hz.
- **30.72 MS/s, D = 16:** ALIGN 46 puts the direct path at 0 Hz, and the radar's
  tracker runs live on the stream (ws-fmcw-5800, 5.8 m cells).

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
