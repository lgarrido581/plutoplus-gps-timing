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
    char    *meta_json;   /* malloc'd NUL-terminated SigMF JSON; caller free()s */
    uint8_t *iq;          /* malloc'd ci16_le payload; caller free()s */
    size_t   iq_len;      /* bytes (== samples * 4 on success) */
    char     err[256];    /* human error message when the call returns < 0 */
} capture_result_t;

/* Run ONE GPS-anchored capture. Returns 0 on success (out->meta_json and out->iq
 * are set and owned by the caller), <0 on failure (out->err set; nothing to free).
 * Not thread-safe -- call serialized (the REP server already does, one at a time). */
int capture_run(const capture_req_t *req, capture_result_t *out);

#ifdef __cplusplus
}
#endif

#endif /* CAPTURE_CORE_H */
