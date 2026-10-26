/*
 * tx_core.h - cyclic TX for pluto_ctld (tx_load / tx_start / tx_stop / tx_status).
 *
 * tx_load tunes TX1 (LO, bandwidth, attenuation; the sample rate is shared with RX),
 * puts the AD9361 in FDD, holds axi_tdd channel2 (the TX DMA's gate) HIGH and fills a
 * cyclic buffer, without starting it. tx_start pushes it: the DMA plays it until
 * tx_stop, which drops the attenuation to -89 dB and frees the buffer. tx_start reads
 * the pps_counter just before and after the push, so a running stream can place TX
 * sample 0 among its RX samples (an iqwire TX_START marker).
 */
#ifndef TX_CORE_H
#define TX_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    long long freq_hz;       /* TX LO */
    long long rate_hz;       /* sample rate, shared with RX */
    double    gain_db;       /* TX hardwaregain (attenuation): -89.75 .. 0 */
    long long bandwidth_hz;  /* 0 = rate_hz */
    int       latency_samples; /* < 0 = TX_LATENCY_SAMPLES: from the end of the push to TX
                              * sample 0 at the RX side (DMA + DAC + RX chain) */
} tx_req_t;

/* Measured on node1 (2026-10-26, 4 MS/s, TX LPDA ~1 m from RX LPDA): the DMA starts at the
 * END of the push, and the direct path's matched filter put TX sample 0 55 +- 4 samples
 * after it (+59, +59, +52 over three starts; the push windows were 172..1504 counts). */
#define TX_LATENCY_SAMPLES 55

/* Tune TX and load `bytes` of ci16 I/Q (one cyclic period; bytes % 4 == 0), not started.
 * Replaces a loaded or running buffer. 0 ok, -1 with err set. */
int  tx_load(const tx_req_t *req, const void *iq, size_t bytes, char *err, size_t errlen);

/* Start the loaded buffer (cyclic). 0 ok, -1 with err set. */
int  tx_start(char *err, size_t errlen);

/* Stop and free TX (attenuation to -89 dB first). `json` gets the status. 0 if TX was loaded. */
int  tx_stop(char *json, size_t len);

/* One flat JSON object: loaded, running, samples, rate, LO, gain, hash, start counters. */
void tx_status(char *json, size_t len);

int       tx_loaded(void);   /* a buffer is loaded (started or not) */
long long tx_rate(void);     /* the rate tx_load set, 0 when nothing is loaded */

/* For the stream: 1 while TX runs, with the pps_counter LIVE count just after the push
 * (the DMA starts at the push's end), the latency from there to TX sample 0 in samples,
 * the buffer length in samples, its 64-bit hash, and a generation that changes on every
 * tx_start. */
int  tx_start_info(uint32_t *live_after, int *latency_samples, uint64_t *len,
                   uint64_t *hash, unsigned *gen);

#ifdef __cplusplus
}
#endif

#endif /* TX_CORE_H */
