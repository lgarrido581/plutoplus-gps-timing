/*
 * stream_core.h - continuous, GPS-timed RX stream for pluto_ctld (stream_start/_stop).
 *
 * The stream runs on its own thread: RX0 (and RX1 with channels = 2) goes out as one
 * ZMQ PUSH message per DMA block, an iqwire.h header + the ci16 samples (zero-copy).
 * Sample 0 of every epoch lands on a PPS edge (the held-arm start of capture_core); the
 * DMA then free-runs, and each later PPS edge rides along as a marker. A DMA overflow, a
 * lag past the queue or a send failure ends the epoch; a new one starts on the next PPS
 * edge. While it streams it holds /tmp/pluto_ctld.capturing (xo_correct must not step
 * the clocks under the DMA) and pluto_ctld refuses captures (one radio owner).
 *
 * Dechirp (decim > 0): on a bitstream with the PL dechirp_decim block (dechirp_pl.h) the
 * DMA receives the RX samples mixed with the running TX buffer and CIC3-decimated by D,
 * sweep-aligned. Each epoch's output sample 0 is the first sweep start after its sync
 * edge, at input sample S0 (a DECIM_PHASE marker); sample_rate_hz is fs/D and
 * ticks_per_sample is the l_clk multiple x D. TX must be loaded and started first.
 *
 * Free-running (require_pps = 0): an epoch whose arm sees no PPS edge in 1.5 s opens the
 * gate itself instead of failing. Its sample 0 is still the latched gate edge; only the
 * label comes from the system clock (iqwire IQW_F_FREE_RUN). Once the PPS has been back
 * for 10 s the epoch ends (pps_back) and the next one arms on the PPS again.
 */
#ifndef STREAM_CORE_H
#define STREAM_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char      connect[160];  /* the receiver's endpoint, e.g. tcp://192.168.50.20:5563 */
    long long freq_hz;       /* LO */
    long long rate_hz;       /* sample rate, per channel */
    double    gain_db;       /* manual RX gain when have_gain, else slow_attack AGC */
    int       have_gain;
    int       channels;      /* 1, or 2 (2R2T mode) */
    double    block_ms;      /* DMA block length, 10..300 ms */
    int       nblocks;       /* kernel blocks queued, 2..32 */
    /* PL dechirp: decim = D (a power of two) asks for it, 0 = the raw samples */
    int       decim;
    long long sweep_samples; /* input samples per sweep; the TX buffer is whole sweeps */
    int       align_samples; /* replica delay beyond one DAC strobe, 0..4094; < 0 =
                              * dcdm_default_align(rate) */
    int       require_pps;   /* 1: no PPS edge at the arm fails it; 0: free-run then */
    /* filled by stream_start from the loaded TX buffer */
    int       log2d;
    unsigned  pat0, pat1;
} stream_req_t;

/* Start streaming. `zctx` is pluto_ctld's zmq context (the stream opens its own socket
 * in it). Returns 0 once the first epoch's sample 0 has landed on its PPS edge, else -1
 * with `err` set (nothing left running). */
int  stream_start(void *zctx, const stream_req_t *req, char *err, size_t errlen);

/* Stop and join the stream thread; `json` gets a summary. Returns 0 if one was running. */
int  stream_stop(char *json, size_t len);

/* One flat JSON object: state, rates, epochs, restarts and their reasons, lag. */
void stream_status(char *json, size_t len);

/* A stream_start refused before its thread ran: with no stream running, stream_status
 * shows it (state failed, this error) instead of the last stream's ending. */
void stream_refused(const char *why);

/* 1 while a stream thread exists (starting, streaming or restarting). */
int  stream_running(void);

#ifdef __cplusplus
}
#endif

#endif /* STREAM_CORE_H */
