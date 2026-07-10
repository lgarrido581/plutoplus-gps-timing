/*
 * pps_timestamp.h - GPS-anchored sample-accurate timestamps from the FPGA
 * pps_counter core (hdl/pps_counter). VENDORED from the DSN/sdr-stack
 * device/streamer (validated on hardware); keep in sync if the anchor logic
 * changes upstream. Used by capture_core.c (the pluto_ctld :5562 capture op).
 *
 *     gps_ns(count) = last_pps_gps_ns + (count - PPS_COUNT) / cnt_clk_hz * 1e9
 *
 * where last_pps_gps_ns is the PPS-disciplined system clock's most recent integer
 * second (PPS fires on the GPS second) and cnt_clk_hz = PPS_DELTA (live, self-
 * calibrating).
 *
 * Register map (AXI4-Lite base 0x7C460000, see hdl/pps_counter/pps_counter.v):
 *   0x08 STATUS     bit0 pps_present
 *   0x0C LIVE_COUNT free-running cnt_clk counter (read anytime)
 *   0x10 PPS_COUNT  counter latched at the last PPS rising edge
 *   0x14 PPS_DELTA  counts in the last GPS second (== live cnt_clk Hz)
 *   0x18 PPS_SEQ    PPS edges seen
 *   0x3C LATCH_COUNT counter latched on the DMA-start (tdd_channel_1) rising edge
 *   0x40 LATCH_SEQ  increments per latch (freshness)
 */
#ifndef PPS_TIMESTAMP_H
#define PPS_TIMESTAMP_H

#include <stdint.h>
#include <stdbool.h>

#define PPS_COUNTER_BASE 0x7C460000UL

typedef struct {
    volatile uint32_t *regs;   /* mmap'd register window */
    int   mem_fd;
    double nominal_cnt_hz;     /* fallback if PPS_DELTA looks invalid */
} pps_ts_t;

/* Map the pps_counter. Returns 0 on success. nominal_cnt_hz is commonly 30.72e6
 * or 61.44e6 on Pluto+, and 122.88e6 on LibreSDR. It is only a sanity fallback;
 * the live PPS_DELTA wins. */
int  pps_ts_init(pps_ts_t *p, double nominal_cnt_hz);
void pps_ts_close(pps_ts_t *p);

/* True if the hardware PPS latch has seen at least one edge (STATUS.pps_present).
 * This flag is sticky; use pps_ts_live() when deciding whether a capture is safe. */
bool pps_ts_present(const pps_ts_t *p);

/* Prove that PPS is live by observing PPS_SEQ advance, rather than trusting the
 * sticky STATUS/PPS_DELTA registers or modulo counter age. Waits for at most
 * timeout_seconds and returns false if no new hardware edge arrives. */
bool pps_ts_live(const pps_ts_t *p, double timeout_seconds);

/* GPS-absolute nanoseconds of "now" (the instant LIVE_COUNT is read). */
uint64_t pps_ts_now_ns(const pps_ts_t *p);

/* GPS-absolute nanoseconds of sample[0] of a buffer that just finished filling,
 * given the buffer length and the RX *sample* rate (Hz). Subtracts the buffer
 * age (n_samples / fs) from "now". Note cnt_clk (PPS_DELTA) may differ from fs. */
uint64_t pps_ts_buffer_start_ns(const pps_ts_t *p, uint64_t n_samples, double fs_hz);

/* Live cnt_clk frequency (PPS_DELTA) -- useful for logging / health. */
uint32_t pps_ts_cnt_hz(const pps_ts_t *p);

/* One-shot GPS anchor for a recording's sample[0]: the GPS-absolute time plus the
 * raw pps_counter values it was derived from (so the mapping is auditable offline).
 * Read as close as possible to the capture start. */
typedef struct {
    uint64_t gps_ns;      /* GPS-absolute ns at this instant (== sample[0] time) */
    uint32_t live_count;  /* LIVE_COUNT now */
    uint32_t pps_count;   /* LIVE_COUNT at the last PPS edge */
    uint32_t pps_seq;     /* PPS edges seen */
    uint32_t cnt_hz;      /* PPS_DELTA (live cnt_clk Hz) */
    bool     present;     /* STATUS.pps_present */
} pps_anchor_t;

void pps_ts_anchor(const pps_ts_t *p, pps_anchor_t *a);

/* Configure the pps_counter PPS-anchored TDD frame (for GPS-sequenced capture):
 * FRAME_LEN/RX_START/RX_STOP (cnt_clk counts), then TDD_CTRL = enable|pps_sync_en.
 * tdd_sync then pulses at each frame start (re-anchored to the GPS second) -- in
 * the --hwlatch build that pulse drives the RX DMA sync. Opens its own RW mapping
 * (the read path stays RO). Returns 0 on success. frame_len must exceed the
 * capture length in cnt_clk counts (frame period > capture duration). */
int pps_ts_config_frame(uint32_t frame_len, uint32_t rx_start, uint32_t rx_stop);

/* Disable the frame (TDD_CTRL=0) -- restore the default inert state. */
int pps_ts_disable_frame(void);

/* Read the firmware DMA-start latch (LATCH_COUNT 0x3C / LATCH_SEQ 0x40, set on the
 * tdd_channel_1 rising edge = the RX-DMA transfer start of a TDD-gated capture).
 * *count = the exact cnt_clk count of sample[0]; *gps_ns = its GPS-absolute time
 * (NO host read race); *seq increments per latch (read before/after a capture to
 * confirm freshness). Returns false if no pps_counter mapping. Needs the latch
 * firmware (pps_counter LATCH_*); on older firmware these read 0. */
bool pps_ts_latch(const pps_ts_t *p, uint32_t *count, uint32_t *seq, uint64_t *gps_ns);

#endif /* PPS_TIMESTAMP_H */
