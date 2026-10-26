/*
 * tx_core.c - see tx_core.h. The order follows what the radar learned on this radio
 * (sdr-stack sdr_control/pluto.py): tune, FDD, both gates HIGH, then one cyclic buffer
 * of a whole number of periods; never toggle the TDD core under a buffer in flight.
 * Called from pluto_ctld's REP loop only (one request at a time); the stream thread
 * reads tx_start_info() under the lock.
 */
#define _GNU_SOURCE
#include "tx_core.h"
#include "capture_core.h"
#include "pps_timestamp.h"

#include <iio.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#define R_LIVE (0x0C / 4)
#define TX_ATTEN_OFF "-89.000000"

static struct {
    pthread_mutex_t     mu;
    struct iio_context *ctx;
    struct iio_device  *tx;
    struct iio_buffer  *buf;
    size_t              nsamp;
    long long           rate_hz, freq_hz;
    double              gain_db;
    uint64_t            hash;
    int                 running;
    uint32_t            live0, live1;
    int                 latency;   /* samples from the push's end to TX sample 0 at RX */
    unsigned            gen;
    char                ensm_was[32];
} T = { .mu = PTHREAD_MUTEX_INITIALIZER };

static uint64_t fnv1a64(const void *p, size_t n) {
    const unsigned char *b = (const unsigned char *)p;
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ULL; }
    return h;
}

static void release(void) {   /* caller holds T.mu */
    if (T.ctx) {
        struct iio_device *phy = iio_context_find_device(T.ctx, "ad9361-phy");
        struct iio_channel *ptx = phy ? iio_device_find_channel(phy, "voltage0", true) : NULL;
        if (ptx) iio_channel_attr_write(ptx, "hardwaregain", TX_ATTEN_OFF);
        if (T.buf) iio_buffer_destroy(T.buf);
        iio_context_destroy(T.ctx);
    }
    T.ctx = NULL; T.tx = NULL; T.buf = NULL;
    T.nsamp = 0; T.rate_hz = 0; T.running = 0;
}

int tx_load(const tx_req_t *req, const void *iq, size_t bytes, char *err, size_t el) {
    if (req->rate_hz <= 0 || req->freq_hz <= 0 || req->gain_db > 0.0 || req->gain_db < -89.75) {
        snprintf(err, el, "bad tx request (freq_hz, sample_rate_hz; gain_db -89.75..0)");
        return -1;
    }
    if (!iq || bytes < 4 * 64 || bytes % 4) {
        snprintf(err, el, "tx needs at least 64 ci16 I/Q samples (4 bytes each); got %zu bytes", bytes);
        return -1;
    }
    long long cap = capture_block_cap();
    if (cap > 0 && (long long)bytes > cap) {
        snprintf(err, el, "%zu bytes exceed the DMA block cap (%lld)", bytes, cap);
        return -1;
    }
    pthread_mutex_lock(&T.mu);
    release();
    T.ctx = iio_create_local_context();
    struct iio_device *phy = T.ctx ? iio_context_find_device(T.ctx, "ad9361-phy") : NULL;
    T.tx = T.ctx ? iio_context_find_device(T.ctx, "cf-ad9361-dds-core-lpc") : NULL;
    struct iio_channel *prx = phy ? iio_device_find_channel(phy, "voltage0", false) : NULL;
    struct iio_channel *ptx = phy ? iio_device_find_channel(phy, "voltage0", true) : NULL;
    struct iio_channel *plo = phy ? iio_device_find_channel(phy, "altvoltage1", true) : NULL;
    struct iio_channel *i0 = T.tx ? iio_device_find_channel(T.tx, "voltage0", true) : NULL;
    struct iio_channel *q0 = T.tx ? iio_device_find_channel(T.tx, "voltage1", true) : NULL;
    if (!phy || !prx || !ptx || !plo || !i0 || !q0) {
        release();
        pthread_mutex_unlock(&T.mu);
        snprintf(err, el, "ad9361 TX devices/channels not found");
        return -1;
    }
    /* tune: the rate is shared with RX; TX LO, bandwidth, attenuation are TX1's own */
    iio_channel_attr_write(ptx, "hardwaregain", TX_ATTEN_OFF);      /* quiet while tuning */
    iio_channel_attr_write_longlong(prx, "sampling_frequency", req->rate_hz);
    iio_channel_attr_write_longlong(plo, "frequency", req->freq_hz);
    iio_channel_attr_write_longlong(ptx, "rf_bandwidth",
                                    req->bandwidth_hz > 0 ? req->bandwidth_hz : req->rate_hz);
    capture_assert_fdd(phy, T.ensm_was, sizeof T.ensm_was);
    int g = capture_gate_tx_open(T.ctx);
    if (g != 0) {
        release();
        pthread_mutex_unlock(&T.mu);
        snprintf(err, el, "%s", g == -2 ? "axi_tdd is running and would not park"
                                        : "axi_tdd channel2 not found");
        return -1;
    }
    iio_device_attr_write(T.tx, "sync_start_enable", "disarm");     /* best effort */
    iio_channel_enable(i0);
    iio_channel_enable(q0);
    T.nsamp = bytes / 4;
    iio_device_set_kernel_buffers_count(T.tx, 1);
    T.buf = iio_device_create_buffer(T.tx, T.nsamp, true);
    if (!T.buf) {
        release();
        pthread_mutex_unlock(&T.mu);
        snprintf(err, el, "TX create_buffer failed for %zu samples", bytes / 4);
        return -1;
    }
    memcpy(iio_buffer_start(T.buf), iq, bytes);
    iio_channel_attr_write_double(ptx, "hardwaregain", req->gain_db);
    long long fs = req->rate_hz, fc = req->freq_hz;
    iio_channel_attr_read_longlong(prx, "sampling_frequency", &fs);
    iio_channel_attr_read_longlong(plo, "frequency", &fc);
    T.rate_hz = fs;
    T.freq_hz = fc;
    T.gain_db = req->gain_db;
    T.latency = req->latency_samples >= 0 ? req->latency_samples : TX_LATENCY_SAMPLES;
    T.hash = fnv1a64(iq, bytes);
    T.running = 0;
    pthread_mutex_unlock(&T.mu);
    return 0;
}

int tx_start(char *err, size_t el) {
    pthread_mutex_lock(&T.mu);
    if (!T.buf) { pthread_mutex_unlock(&T.mu); snprintf(err, el, "nothing loaded (tx_load first)"); return -1; }
    if (T.running) { pthread_mutex_unlock(&T.mu); snprintf(err, el, "TX already running"); return -1; }
    pps_ts_t pps;
    int have = pps_ts_init(&pps, 0.0) == 0;
    uint32_t l0 = have ? pps.regs[R_LIVE] : 0;
    ssize_t n = iio_buffer_push(T.buf);
    uint32_t l1 = have ? pps.regs[R_LIVE] : 0;
    if (have) pps_ts_close(&pps);
    if (n < 0) {
        pthread_mutex_unlock(&T.mu);
        snprintf(err, el, "TX push failed (%zd)", n);
        return -1;
    }
    T.live0 = l0;
    T.live1 = l1;
    T.running = 1;
    T.gen++;
    pthread_mutex_unlock(&T.mu);
    return 0;
}

void tx_status(char *json, size_t len) {
    pthread_mutex_lock(&T.mu);
    snprintf(json, len,
        "{\"loaded\":%s,\"running\":%s,\"samples\":%zu,\"sample_rate_hz\":%lld,"
        "\"freq_hz\":%lld,\"gain_db\":%.2f,\"hash\":\"0x%016llx\",\"starts\":%u,"
        "\"start_live_after\":%u,\"start_window_counts\":%u,\"latency_samples\":%d,"
        "\"ensm_was\":\"%s\"}",
        T.buf ? "true" : "false", T.running ? "true" : "false", T.nsamp, T.rate_hz,
        T.freq_hz, T.gain_db, (unsigned long long)T.hash, T.gen, T.live1,
        (uint32_t)(T.live1 - T.live0), T.latency, T.ensm_was[0] ? T.ensm_was : "unknown");
    pthread_mutex_unlock(&T.mu);
}

int tx_stop(char *json, size_t len) {
    pthread_mutex_lock(&T.mu);
    int was = T.buf != NULL;
    release();
    pthread_mutex_unlock(&T.mu);
    tx_status(json, len);
    return was ? 0 : -1;
}

int tx_loaded(void) {
    pthread_mutex_lock(&T.mu);
    int l = T.buf != NULL;
    pthread_mutex_unlock(&T.mu);
    return l;
}

long long tx_rate(void) {
    pthread_mutex_lock(&T.mu);
    long long r = T.buf ? T.rate_hz : 0;
    pthread_mutex_unlock(&T.mu);
    return r;
}

int tx_start_info(uint32_t *live_after, int *latency_samples, uint64_t *len,
                  uint64_t *hash, unsigned *gen) {
    pthread_mutex_lock(&T.mu);
    int r = T.running;
    if (r) {
        *live_after = T.live1;
        *latency_samples = T.latency;
        *len = T.nsamp;
        *hash = T.hash;
        *gen = T.gen;
    }
    pthread_mutex_unlock(&T.mu);
    return r;
}
