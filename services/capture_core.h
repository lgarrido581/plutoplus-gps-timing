/*
 * capture_core.h - in-memory GPS-anchored IQ capture for the pluto_ctld :5562
 * capture op. Refactor of the validated DSN/sdr-stack device/streamer/iq_capture.c:
 * same tune + axi_tdd PPS-gated arm + single-DMA contiguous refill + pps_counter
 * anchor, but it RETURNS the SigMF metadata + ci16_le IQ in memory (no files,
 * no argv) so the ZMQ server can ship them as two frames.
 *
 * See docs/PLUTO_ZMQ_CTL_ICD.md (firmware) and the DSN client (dsn/pluto_zmq.py).
 */
#ifndef CAPTURE_CORE_H
#define CAPTURE_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    long long  freq_hz;        /* requested RX LO, Hz */
    long long  rate_hz;        /* baseband complex sample rate, Hz */
    size_t     samples;        /* number of complex samples to capture */
    double     gain_db;        /* manual RX gain (dB) if have_gain */
    int        have_gain;      /* 0 => slow_attack AGC */
    int        tdd_sync;       /* gate sample 0 to the PPS-anchored frame edge */
    int        require_gps;    /* refuse unless a live PPS is present */
    int        have_t0;        /* t0_gps provided */
    double     t0_gps;         /* agreed 1PPS edge, absolute seconds (CLOCK_REALTIME epoch) */
    long long  offset_samples; /* samples past the edge before sample 0 (channel1 on_raw) */
    const char *node_id;       /* DSN bookkeeping, echoed to meta (may be NULL) */
    int        have_pos;       /* surveyed antenna position present */
    double     lat, lon, alt;  /* deg, deg, m HAE */
} capture_req_t;

typedef struct {
    char    *meta_json;   /* malloc'd NUL-terminated SigMF JSON */
    uint8_t *iq;          /* ci16_le payload: points INTO the DMA buffer (zero-copy);
                           * valid until capture_release() */
    size_t   iq_len;      /* bytes (== samples * 4 on success) */
    void    *priv;        /* the live iio buffer + context behind iq */
    char     err[256];    /* human error message when the call returns < 0 */
} capture_result_t;

/* Run ONE GPS-anchored capture. Returns 0 on success: out->meta_json and out->iq
 * are set, and the caller MUST call capture_release() once it is done with them
 * (the IQ stays in the DMA buffer, so a capture costs its size in memory once,
 * not three times). Returns <0 on failure (out->err set; nothing to release).
 * Not thread-safe -- call serialized (the REP server already does, one at a time). */
int capture_run(const capture_req_t *req, capture_result_t *out);

/* Free what a successful capture_run() returned (DMA buffer, context, meta). */
void capture_release(capture_result_t *out);

/* The kernel's DMA block cap in bytes (one capture must fit in one block), 0 if unknown. */
long long capture_block_cap(void);

/* The AD936x interface multiple (counter ticks per sample, 1-4) from the current rate and
 * PPS_DELTA, accepted only when the count is settled (within 1000 ppm of a whole
 * multiple, and taken wholly after the last rate change); otherwise the last multiple
 * confirmed, or 2. Shared by capture, stream and TX. */
int capture_lclk_multiple(long long cur_rate_hz, uint32_t pps_delta);

/* 1 once a settled count has confirmed the multiple (it is fixed for the boot). */
int capture_lclk_known(void);

/* Seconds until PPS_DELTA counts only the current rate (0: it does now). */
double capture_rate_settle_left(long long cur_rate_hz);

struct iio_context;
struct iio_device;
struct iio_channel;

/* Write the sample rate on ad9361-phy voltage0 (in), noting a change for
 * capture_lclk_multiple. Every rate write in pluto_ctld goes through here. Returns the
 * rate read back. */
long long capture_set_rate(struct iio_channel *p_rx, long long rate_hz);

/* The RX-DMA gate, for the stream (stream_core.c). capture_gate_hold: axi_tdd parked if it
 * was running, then off with channel 1 latched LOW, so pps_counter's window owns the gate
 * (0 ok, -1 no axi_tdd, -2 would not park). capture_gate_open: channel 1 held HIGH (as
 * after boot) and pps_counter's window off -- free-running RX. */
int  capture_gate_hold(struct iio_context *ctx);

/* Put the AD9361 (ad9361-phy) in FDD if it is not: in ALERT, left there by another
 * libiio client, the DMA fills with a constant DC level at the wrong rate. `was` gets
 * the state found ("fdd", "alert", ...). 0 = FDD now, -1 = the write failed. */
int  capture_assert_fdd(struct iio_device *phy, char *was, size_t len);
void capture_gate_open(long long frame_len, long long rate_hz);

/* Hold axi_tdd channel2 (the TX DMA's gate) HIGH, leaving channel1 as it is. 0 ok,
 * -1 no axi_tdd, -2 a running core would not park. Not while a stream runs: it toggles
 * the core's enable. */
int  capture_gate_tx_open(struct iio_context *ctx);

/* axi_tdd as JSON, read from sysfs: enable, state (0 idle, 1 armed, 3 running), the frame,
 * and per channel (0..2) its enable/polarity/on/off registers plus `latched`, the polarity
 * at this daemon's last enable 0 -> 1 (-1: none since start). A register written since
 * reaches the output only at the next transition. Channel 1 is the RX DMA's sync (ORed
 * with pps_counter's window), channel 2 the TX DMA's. */
void capture_tdd_status(char *json, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* CAPTURE_CORE_H */
