# PPS-aligned TDD frame counter — design proposal

Tie the AD936x **TDD frame timing to GPS** by adding a PPS-reset frame counter in the PL, so every
node's TX/RX windows start on the same GPS-second boundary. This extends `pps_counter` (which already
has the synchronized PPS edge + the `l_clk` counter) rather than adding a new IP.

> Status: **proposal — not yet built.** Needs the Vivado HDL build (see [build-environment]). Review
> the register map + the two open decisions below before I implement.

## Why this works for a multi-node network

- `cnt_clk` is the AD936x `l_clk`, which `xo_correction` disciplines to GPS (±~0.03 ppm). So a frame of
  `FRAME_LEN` samples is a stable, known duration on every node.
- Resetting the frame counter on the **hardware PPS edge** (the same `pps_rise` already in this IP)
  re-anchors the frame phase to the GPS second once per second, nulling any residual drift between
  re-locks. Two disciplined nodes then agree on frame phase to **±1 `cnt_clk` (the latch quantization,
  ~33 ns at 30.72 MHz)** — the same bound we measured for the PPS latch.
- Net: TX/RX windows are common-time across the network without any inter-node messaging.

## Block (added to `pps_counter.v`, all in the `cnt_clk` domain)

```
                 pps_rise (existing) ─────────────┐ (sync reset)
                                                  ▼
 cnt_clk ─►  frame_cnt  (0 … FRAME_LEN-1, wraps) ─┬─► == 0  ──► tdd_sync   (1-cyc pulse @ frame start)
                                                  ├─► [RX_START,RX_STOP) ─► tdd_rx_on
                                                  └─► [TX_START,TX_STOP) ─► tdd_tx_on
                                                       tdd_txnrx = tx_on
                                                       tdd_enable = rx_on | tx_on
```

- **`frame_cnt`** increments every `cnt_clk`; wraps at `FRAME_LEN`. On `pps_rise` it loads 0
  (re-anchor). If `FRAME_LEN` does **not** evenly divide the samples-per-PPS, the frame that straddles
  the PPS edge is truncated (a "runt") — expected; choose `FRAME_LEN` to divide the GPS second to avoid
  it (see decision 1).
- **Window comparators** produce `tdd_rx_on` / `tdd_tx_on` from programmable edges, and a one-cycle
  **`tdd_sync`** at each frame start (== 0). These are the signals that drive the AD936x.
- Gated by a new `TDD_CTRL.enable`; when disabled the outputs are inert and the existing counter/latch
  behavior is unchanged (fully backward compatible).

## Register map extension (same AXI slave; 0x1C–0x3C are free today)

| Off | Name | R/W | Meaning |
|---|---|---|---|
| 0x1C | `TDD_CTRL` | RW | bit0 `enable`, bit1 `pps_sync_en` (reset frame on PPS), bit2 `drive_pins` (0=emit tdd_sync only, 1=drive ENABLE/TXNRX), bit3 `txnrx_pol`, bit4 `enable_pol` |
| 0x20 | `FRAME_LEN` | RW | frame length in `cnt_clk` samples |
| 0x24 | `RX_START` | RW | frame-count at which RX window opens |
| 0x28 | `RX_STOP` | RW | frame-count at which RX window closes |
| 0x2C | `TX_START` | RW | TX window open |
| 0x30 | `TX_STOP` | RW | TX window close |
| 0x34 | `FRAME_POS` | RO | live `frame_cnt` (CDC-synced) — for verification |
| 0x38 | `FRAME_SEQ` | RO | frames elapsed since last PPS (RO) — confirms FRAME_LEN divides the second |

All window/length writes are latched in the AXI domain and 2-FF synced into `cnt_clk` (they change
rarely, like the existing CTRL bits). `FRAME_POS`/`FRAME_SEQ` cross back via the same Gray/2-FF pattern
already in the IP.

## Integration into the AD936x path — the key decision (decision 2)

The new outputs (`tdd_sync`, `tdd_txnrx`, `tdd_enable`) must reach the AD936x. Two ways, selectable via
`TDD_CTRL.drive_pins`:

- **(A) Emit `tdd_sync` only → feed ADI's TDD controller.** If we enable ADI's `axi_ad9361` TDD /
  `axi_tdd` core, it already generates the ENSM windows; we just hand it a PPS-locked `tdd_sync` to
  reset its frame. Smallest, most idiomatic; frame/window config lives in ADI's TDD regs. Requires that
  core to be present/enabled in the Pluto BD.
- **(B) Drive `ENABLE`/`TXNRX` directly** from our comparators (mux/override the current ENSM control).
  Self-contained — no dependency on ADI's TDD core — but we own the ENSM timing and must respect the
  AD9361 ENSM state-transition timing (TX/RX guard intervals, `ENABLE`/`TXNRX` setup).

I lean **(A) for correctness/least risk** (reuse ADI's validated ENSM control, our job is just the
GPS-locked sync), with the frame counter here as the sync source and an optional **(B)** path for
direct control. The BD wiring (which top-level port carries `tdd_sync`/`ENABLE`/`TXNRX`, plumbed in the
build's `system_top.v` patch like `pps_ext` is today) is confirmed during implementation against the
ADI `hdl` tree.

## As built (v1.4)

- **Method A** — `pps_counter` emits `pps_tick` (1-cyc pulse per PPS edge); the build rewires ADI's
  `axi_tdd_0/sync_in` from the unused external `tdd_ext_sync` port to `pps_tick`. `axi_tdd` generates
  the TX/RX windows (its own regs at `0x7C440000`) and re-anchors to the GPS second on each PPS.
- **FRAME_LEN** should divide the samples-per-second (e.g. 10 ms = 307200 @ 30.72 MSPS); a sub-ppm
  residual leaves a 1-sample runt frame, which is harmless.
- Ships **disabled** (powers up identical to v1.3) until software configures `axi_tdd` + enables sync.

## Testing

- **Functional (no scope) — [`tdd_verify.sh`](tdd_verify.sh):** confirms the sample clock is locked,
  the frame counter stays bounded and re-anchors on every PPS, and `axi_tdd` is in external-sync mode.
  Proves *function*; software `devmem` reads are ms-jittery so they can't resolve ns.
- **TX-vs-PPS timing (scope) — [`tdd_tx_test.sh`](tdd_tx_test.sh):** sets up a GPS-aligned, TDD-gated
  TX burst. Scope `Ch1 = PPS`, `Ch2 = Pluto TX SMA`, trigger on PPS rising:
  - *delay PPS→TX-rising* = fixed pipeline latency (axi_tdd + AD9361 + RF), ~constant per node →
    the **per-node calibration term** that must be characterized so it cancels in a TDOA difference;
  - *jitter* of that delay = sync jitter, expect ≤ 1 sample (~32.6 ns @ 30.72 MSPS);
  - *drift over minutes* = sample-clock lock quality (≈0 with `xo_correct` locked).
- **Two-node / sub-sample:** cross-correlate two nodes' GPS-timed captures for the inter-node
  alignment (the real network metric); add a PPS-phase TDC (ROADMAP) to push below 1 sample.

## PPS loss & holdover

A brief PPS dropout does **not** break triggering:

- `axi_tdd` **free-runs** between sync pulses — `pps_tick` *re-aligns* its frame counter, it does not
  gate it. Same for `pps_counter`'s own frame counter (`frame_wrap` keeps it running; the PPS edge only
  *reloads* it). So frames/bursts keep coming during a gap.
- The only effect is loss of re-anchoring: frame phase drifts vs absolute GPS by
  `residual_ppm × gap` (~30 ns per second of gap at the ~0.03 ppm hold). The next PPS snaps it back.
- The sample clock holds its last `xo_correction` (TCXO runs at the last-disciplined frequency);
  `xo_correct.sh` just waits for PPS to resume and (v1.4) won't rail on a glitchy/returning PPS.

Caveats / when a backup matters:

- **First PPS arms it.** `axi_tdd` in external-sync mode waits for the first sync edge to *start*
  framing — at cold start with no GPS it won't begin. Fallback: use `axi_tdd`'s internal/soft sync
  (`CONTROL.sync_int`/`sync_soft`) to free-run un-aligned until GPS appears.
- **Long outages** (minutes+): TCXO temperature drift degrades alignment beyond ±1 sample → use the
  ROADMAP holdover items: detect PPS loss → freeze `xo` + flag timestamps `degraded`; and the hardware
  path (external OCXO/Rb GPSDO) for true holdover.
- Quick check: start TDD, disable PPS, watch `tdd_verify.sh` — `FRAME_SEQ` keeps advancing (free-run)
  until PPS returns and re-aligns.
