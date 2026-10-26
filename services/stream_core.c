/*
 * stream_core.c - see stream_core.h. From the iq_stream prototype (feat/iq-stream), on
 * pluto_ctld's thread model and the iqwire block format.
 *
 * One epoch:
 *   gate held (axi_tdd ch1 LOW) -> pps_counter window [0, 0.5 s) programmed, output held
 *   -> RX core sync armed, kernel blocks queued -> fresh PPS -> window released in the
 *   gap -> the next PPS edge starts the DMA (latched: sample 0's GPS time)
 *   -> after block 0, ch1 held HIGH steadily and the window dropped (the OR never falls,
 *   so the DMA free-runs) -> one message per block until stop or a loss.
 * Time: the stream counts the pps_counter's clock from the latched start; each PPS edge
 * becomes a marker at its tick, so the receiver can place any sample in GPS time.
 */
#define _GNU_SOURCE
#include "stream_core.h"
#include "capture_core.h"
#include "iqwire.h"
#include "pps_timestamp.h"

#include <errno.h>
#include <iio.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <zmq.h>

#define R_LIVE      (0x0C / 4)
#define R_PPS_COUNT (0x10 / 4)
#define R_PPS_DELTA (0x14 / 4)
#define R_PPS_SEQ   (0x18 / 4)
#define DMA_STATUS  0x80000088u    /* ADC core register (DEBUGFS_DRA_PCORE_REG_MAGIC) */
#define DMA_OVF     0x4u
#define LOCK_PATH   "/tmp/pluto_ctld.capturing"
#define XO_STATE    "/run/xo_state"
#define MAX_MARKERS 8
#define SEND_CEILING_BPS 56e6      /* measured: the Pluto+'s GbE send tops out near 57 MB/s */
#define SEND_STALL_MS 5000         /* a block not sent this long ends the epoch */
#define SEND_HOLD_MS 30000         /* how long teardown waits for zmq to let go of a block */

enum { ST_IDLE, ST_ARMING, ST_STREAMING, ST_FAILED };
static const char *STATE_NAME[] = { "idle", "arming", "streaming", "failed" };

/* why an epoch ended */
enum { END_STOP, END_OVERFLOW, END_LAG, END_SEND, END_REFILL, END_ARM, END_NOEDGE, N_END };
static const char *END_NAME[] = { "stop", "overflow", "lag", "send", "refill", "arm", "no_edge" };

typedef struct {
    pthread_mutex_t mu;
    pthread_t       thr;
    int             thread_live, exited;
    volatile int    stop;
    void           *zctx;
    stream_req_t    req;
    int             state;
    char            err[200];
    double          fs, fc, t_start, lag_s, max_lag_s;
    int             mult, xo_locked, block_samples;
    unsigned        epoch;
    long long       epoch_sec;
    unsigned long long epochs, blocks, samples, bytes, ends[N_END];
} stream_t;

static stream_t g = { .mu = PTHREAD_MUTEX_INITIALIZER };

typedef struct {
    struct iio_context *ctx;
    struct iio_device  *rx;
    pps_ts_t            pps;
    int                 have_pps;
    void               *push;
    int                 pfd[2];
    long long           frame_len, win;
    size_t              n_blk;
    struct iio_buffer  *buf;
    int                 held;      /* zmq still owns a block of buf */
    int64_t             gain_mdb;  /* -1 = AGC */
} sess_t;

static double realtime_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void lock_touch(void) {
    FILE *f = fopen(LOCK_PATH, "w");
    if (f) { fprintf(f, "%d\n", (int)getpid()); fclose(f); }
}

/* xo_correct.sh's state line: timing is trustworthy only once it says LOCKED. */
static int xo_locked(void) {
    char line[256] = "";
    FILE *f = fopen(XO_STATE, "r");
    if (!f) return 0;
    while (fgets(line, sizeof line, f)) {}
    fclose(f);
    return strstr(line, "state=LOCKED") != NULL;
}

/* PPS_SEQ, PPS_COUNT and LIVE_COUNT as one consistent snapshot (no PPS between the reads). */
static void pps_snapshot(const pps_ts_t *p, uint32_t *seq, uint32_t *ppsc, uint32_t *live) {
    for (int i = 0; i < 3; i++) {
        uint32_t s1 = p->regs[R_PPS_SEQ];
        *ppsc = p->regs[R_PPS_COUNT];
        *live = p->regs[R_LIVE];
        *seq = p->regs[R_PPS_SEQ];
        if (*seq == s1) return;
    }
}

/* zmq frees a zero-copy block: wake the loop, which may then re-queue it for DMA. */
static void block_sent(void *data, void *hint) {
    (void)data;
    char c = 1;
    ssize_t w = write((int)(intptr_t)hint, &c, 1);
    (void)w;
}

static int wait_released(sess_t *s, int ms) {
    struct pollfd p = { s->pfd[0], POLLIN, 0 };
    if (poll(&p, 1, ms) != 1) return 0;
    char c;
    ssize_t r = read(s->pfd[0], &c, 1);
    (void)r;
    return 1;
}

static void set_state(int st, const char *err) {
    pthread_mutex_lock(&g.mu);
    g.state = st;
    if (err) snprintf(g.err, sizeof g.err, "%s", err);
    pthread_mutex_unlock(&g.mu);
}

/* ---- session: once per stream ------------------------------------------------- */

static int setup(sess_t *s, const stream_req_t *r, char *err, size_t el) {
    s->ctx = iio_create_local_context();
    if (!s->ctx) { snprintf(err, el, "no local iio context"); return -1; }
    struct iio_device *phy = iio_context_find_device(s->ctx, "ad9361-phy");
    s->rx = iio_context_find_device(s->ctx, "cf-ad9361-lpc");
    struct iio_channel *p_rx = phy ? iio_device_find_channel(phy, "voltage0", false) : NULL;
    struct iio_channel *p_rx1 = phy ? iio_device_find_channel(phy, "voltage1", false) : NULL;
    struct iio_channel *p_lo = phy ? iio_device_find_channel(phy, "altvoltage0", true) : NULL;
    const char *names[4] = { "voltage0", "voltage1", "voltage2", "voltage3" };
    struct iio_channel *ch[4] = { NULL, NULL, NULL, NULL };
    for (int i = 0; i < 2 * r->channels && s->rx; i++)
        ch[i] = iio_device_find_channel(s->rx, names[i], false);
    if (!p_rx || !p_lo || !ch[0] || !ch[1]) { snprintf(err, el, "ad9361 devices/channels not found"); return -1; }
    if (r->channels == 2 && (!ch[2] || !ch[3] || !p_rx1)) {
        snprintf(err, el, "channels=2 needs the 2R2T mode (no RX2 here)");
        return -1;
    }
    s->have_pps = pps_ts_init(&s->pps, 0.0) == 0;
    if (!s->have_pps) { snprintf(err, el, "pps_counter not mappable (/dev/mem)"); return -1; }

    long long cur = 0;
    iio_channel_attr_read_longlong(p_rx, "sampling_frequency", &cur);
    int mult = capture_lclk_multiple(cur, s->pps.regs[R_PPS_DELTA]);
    double bps = (double)r->rate_hz * r->channels * 4.0;
    if (bps > SEND_CEILING_BPS) {
        snprintf(err, el, "%.1f MB/s exceeds the Pluto's send ceiling (~%.0f MB/s)",
                 bps / 1e6, SEND_CEILING_BPS / 1e6);
        return -1;
    }
    if ((double)r->rate_hz * mult > 61440000.0) {
        snprintf(err, el, "sample_rate_hz %lld exceeds 61.44 MHz / %d", r->rate_hz, mult);
        return -1;
    }

    /* tune once: a rate or LO write disturbs the sample clock for that second */
    struct iio_channel *prx[2] = { p_rx, p_rx1 };
    iio_channel_attr_write_longlong(p_rx, "sampling_frequency", r->rate_hz);
    for (int c = 0; c < r->channels; c++) {
        iio_channel_attr_write_longlong(prx[c], "rf_bandwidth", r->rate_hz);
        if (r->have_gain) {
            iio_channel_attr_write(prx[c], "gain_control_mode", "manual");
            iio_channel_attr_write_double(prx[c], "hardwaregain", r->gain_db);
        } else {
            iio_channel_attr_write(prx[c], "gain_control_mode", "slow_attack");
        }
    }
    iio_channel_attr_write_longlong(p_lo, "frequency", r->freq_hz);
    long long fs = r->rate_hz, fc = r->freq_hz;
    iio_channel_attr_read_longlong(p_rx, "sampling_frequency", &fs);
    iio_channel_attr_read_longlong(p_lo, "frequency", &fc);
    s->pps.nominal_cnt_hz = (double)mult * (double)fs;   /* the latch's plausibility check */
    s->pps.cnt_tol = 0.001;
    for (int i = 0; i < 2 * r->channels; i++) iio_channel_enable(ch[i]);
    s->gain_mdb = r->have_gain ? (int64_t)llround(r->gain_db * 1000.0) : -1;

    s->frame_len = (long long)mult * r->rate_hz;
    s->win = s->frame_len / 2;
    s->n_blk = (size_t)((double)r->rate_hz * r->block_ms / 1000.0) & ~(size_t)1023;
    if (s->n_blk < 1024) { snprintf(err, el, "block_ms too short for this rate"); return -1; }

    s->push = zmq_socket(g.zctx, ZMQ_PUSH);
    int linger = 0, hwm = 2, immediate = 1;
    zmq_setsockopt(s->push, ZMQ_LINGER, &linger, sizeof linger);
    zmq_setsockopt(s->push, ZMQ_SNDHWM, &hwm, sizeof hwm);
    /* queue only to a connected receiver: with none (or once it is gone) a send fails at
     * once and the epoch ends, instead of a block waiting in zmq for a reconnect while
     * the DMA runs out of queue */
    zmq_setsockopt(s->push, ZMQ_IMMEDIATE, &immediate, sizeof immediate);
    if (zmq_connect(s->push, r->connect) != 0) {
        snprintf(err, el, "zmq connect %s: %s", r->connect, zmq_strerror(zmq_errno()));
        return -1;
    }
    if (pipe(s->pfd) != 0) { snprintf(err, el, "pipe: %s", strerror(errno)); return -1; }
    lock_touch();
    usleep(300000);                                    /* let the connection come up */

    pthread_mutex_lock(&g.mu);
    g.fs = (double)fs; g.fc = (double)fc; g.mult = mult; g.block_samples = (int)s->n_blk;
    g.xo_locked = xo_locked();
    pthread_mutex_unlock(&g.mu);
    if (!g.xo_locked)
        fprintf(stderr, "pluto_ctld: stream: WARNING %s is not LOCKED -- timing is unreliable "
                "until it is\n", XO_STATE);
    return 0;
}

static void teardown_epoch(sess_t *s) {
    iio_device_attr_write(s->rx, "sync_start_enable", "disarm");
    if (s->buf) {
        if (s->held && !wait_released(s, SEND_HOLD_MS)) {
            /* zmq may still read the block: never free memory under it */
            fprintf(stderr, "pluto_ctld: stream: zmq still holds a block after %d s; "
                    "buffer leaked\n", SEND_HOLD_MS / 1000);
        } else {
            iio_buffer_destroy(s->buf);
        }
        s->buf = NULL;
        s->held = 0;
    }
    capture_gate_open(s->frame_len, (long long)g.req.rate_hz);  /* as a capture leaves it */
}

static void teardown(sess_t *s) {
    if (s->push) { zmq_close(s->push); s->push = NULL; }     /* drops (releases) any block */
    if (s->buf) teardown_epoch(s);
    if (s->pfd[0] >= 0) { close(s->pfd[0]); close(s->pfd[1]); }
    if (s->have_pps) pps_ts_close(&s->pps);
    if (s->ctx) iio_context_destroy(s->ctx);
    unlink(LOCK_PATH);
}

/* ---- one epoch ------------------------------------------------------------------- */

static int run_epoch(sess_t *s, const stream_req_t *r, unsigned epoch, uint32_t *seq,
                     int prev_end, int *started, char *err, size_t el) {
    *started = 0;
    const int mult = g.mult;
    struct iio_device *rx = s->rx;
    int gh = capture_gate_hold(s->ctx);
    if (gh != 0) {
        snprintf(err, el, "%s", gh == -2 ? "axi_tdd is running and would not park"
                                         : "axi_tdd not found");
        return END_ARM;
    }
    if (pps_ts_config_frame((uint32_t)s->frame_len, 0, (uint32_t)s->win) != 0) {
        snprintf(err, el, "pps_counter frame config failed");
        capture_gate_open(s->frame_len, r->rate_hz);
        return END_ARM;
    }
    uint32_t lseq_prev = 0;
    pps_ts_latch(&s->pps, NULL, &lseq_prev, NULL);
    /* arm the RX core's sync start around buffer creation, as capture_core does: without
     * it the DMA does not wait for the gate */
    iio_device_reg_write(rx, DMA_STATUS, DMA_OVF);
    if (iio_device_attr_write(rx, "sync_start_enable", "arm") < 0) {
        snprintf(err, el, "sync_start_enable not settable");
        capture_gate_open(s->frame_len, r->rate_hz);
        return END_ARM;
    }
    iio_device_set_kernel_buffers_count(rx, (unsigned int)r->nblocks);
    s->buf = iio_device_create_buffer(rx, s->n_blk, false);
    if (!s->buf) {
        snprintf(err, el, "create_buffer failed (%d x %zu samples)", r->nblocks, s->n_blk);
        teardown_epoch(s);
        return END_ARM;
    }
    iio_device_attr_write(rx, "sync_start_enable", "arm");
    iio_context_set_timeout(s->ctx, 3000);
    uint32_t pos = 0;
    if (!pps_ts_live(&s->pps, 1.5)) {
        snprintf(err, el, "no live PPS");
        teardown_epoch(s);
        return END_ARM;
    }
    if (pps_ts_drive_in_gap((uint32_t)s->frame_len, (uint32_t)s->win,
                            (uint32_t)(mult * r->rate_hz / 1000), realtime_s() + 1.0, &pos) != 0) {
        snprintf(err, el, "could not release the window before the PPS edge");
        teardown_epoch(s);
        return END_ARM;
    }

    uint32_t lc = 0, lseq = 0, live_prev = 0, pseq_prev = 0, start_pseq = 0;
    uint64_t lgps = 0, cnt64 = 0;
    long long start_sec = 0;
    unsigned long long k = 0;
    double t_touch = realtime_s();
    int end = END_STOP;
    for (;;) {
        int last = g.stop;
        ssize_t nb = iio_buffer_refill(s->buf);
        if (nb <= 0) {
            snprintf(err, el, "refill failed (%zd) at block %llu", nb, k);
            end = k == 0 ? END_NOEDGE : END_REFILL;
            break;
        }
        uint32_t pseq, ppsc, live;
        pps_snapshot(&s->pps, &pseq, &ppsc, &live);
        uint32_t dma = 0;
        int ovf = iio_device_reg_read(rx, DMA_STATUS, &dma) == 0 && (dma & DMA_OVF);
        if (ovf) iio_device_reg_write(rx, DMA_STATUS, DMA_OVF);   /* sticky: clear */
        if (k == 0) {
            pps_ts_latch(&s->pps, &lc, &lseq, &lgps);
            if (lseq == lseq_prev || lgps == 0) {
                snprintf(err, el, "no start edge latched (latch seq %u -> %u)", lseq_prev, lseq);
                end = END_NOEDGE;
                break;
            }
            /* hold the gate open steadily before the 0.5 s window closes, and drop the window */
            capture_gate_open(s->frame_len, r->rate_hz);
            start_sec = (long long)((lgps + 500000000ULL) / 1000000000ULL);
            start_pseq = pseq;
            pseq_prev = pseq;
            live_prev = lc;
            ovf = 0;      /* the ADC overflowed while the DMA waited for the edge: expected */
        }
        cnt64 += (uint32_t)(live - live_prev);
        live_prev = live;
        double lag = (double)cnt64 / mult - (double)((k + 1) * s->n_blk);
        if (ovf) { snprintf(err, el, "DMA overflow at block %llu", k); end = END_OVERFLOW; break; }
        if (lag > (double)(r->nblocks + 1) * (double)s->n_blk) {
            snprintf(err, el, "lag %.0f samples past the %d-block queue at block %llu",
                     lag, r->nblocks, k);
            end = END_LAG;
            break;
        }

        unsigned char hb[sizeof(iqw_hdr) + MAX_MARKERS * sizeof(iqw_marker)];
        iqw_hdr *h = (iqw_hdr *)hb;
        iqw_marker *mk = (iqw_marker *)(hb + sizeof(iqw_hdr));
        int nm = 0;
        memset(hb, 0, sizeof hb);
        if (k == 0) {
            mk[nm].tick = 0; mk[nm].value = s->gain_mdb; mk[nm].kind = IQW_M_GAIN; nm++;
        }
        if (pseq != pseq_prev) {
            mk[nm].tick = cnt64 - (uint32_t)(live - ppsc);       /* ticks since sample 0 */
            mk[nm].value = start_sec + (int32_t)(pseq - start_pseq);
            mk[nm].kind = IQW_M_PPS;
            nm++;
            pseq_prev = pseq;
        }
        h->magic = IQW_MAGIC;
        h->version = IQW_VERSION;
        h->hdr_bytes = (uint16_t)(sizeof(iqw_hdr) + (size_t)nm * sizeof(iqw_marker));
        h->seq = (*seq)++;
        h->flags = (last ? IQW_F_LAST : 0);
        if (k == 0) {
            h->flags |= IQW_F_EPOCH_START | (g.xo_locked ? IQW_F_XO_LOCKED : 0);
            if (prev_end == END_OVERFLOW || prev_end == END_LAG || prev_end == END_SEND ||
                prev_end == END_REFILL)
                h->flags |= IQW_F_OVERFLOW;
        }
        h->epoch = epoch;
        h->channels = (uint16_t)r->channels;
        h->format = IQW_FMT_CI16;
        h->sample0 = k * s->n_blk;
        h->nsamples = (uint32_t)((size_t)nb / (4u * (unsigned)r->channels));
        h->n_markers = (uint16_t)nm;
        h->ticks_per_sample = (uint16_t)mult;
        h->sample_rate_hz = g.fs;
        h->center_freq_hz = g.fc;
        h->epoch_t0_ns = lgps;
        if (zmq_send(s->push, hb, h->hdr_bytes, ZMQ_SNDMORE | ZMQ_DONTWAIT) < 0) {
            snprintf(err, el, "receiver at %s is not taking blocks (%s)", r->connect,
                     zmq_strerror(zmq_errno()));
            end = END_SEND;
            break;
        }
        zmq_msg_t m;
        zmq_msg_init_data(&m, iio_buffer_start(s->buf), (size_t)nb, block_sent,
                          (void *)(intptr_t)s->pfd[1]);
        s->held = 1;
        int sent = zmq_msg_send(&m, s->push, ZMQ_DONTWAIT) >= 0;
        if (!sent) zmq_msg_close(&m);                                  /* -> block_sent */
        if (!wait_released(s, SEND_STALL_MS)) {
            snprintf(err, el, "receiver at %s stalled %d s", r->connect, SEND_STALL_MS / 1000);
            end = END_SEND;
            break;
        }
        s->held = 0;
        if (!sent) {
            snprintf(err, el, "block %llu not sent (%s)", k, zmq_strerror(zmq_errno()));
            end = END_SEND;
            break;
        }

        pthread_mutex_lock(&g.mu);
        if (k == 0) {
            g.epoch = epoch;
            g.epochs++;
            g.epoch_sec = start_sec;
            g.state = ST_STREAMING;
        }
        g.blocks++;
        g.samples += h->nsamples;
        g.bytes += (unsigned long long)nb;
        g.lag_s = lag / g.fs;
        if (g.lag_s > g.max_lag_s) g.max_lag_s = g.lag_s;
        pthread_mutex_unlock(&g.mu);
        *started = 1;
        k++;
        if (realtime_s() - t_touch > 30.0) { lock_touch(); t_touch = realtime_s(); }
        if (last) { end = END_STOP; break; }
    }
    teardown_epoch(s);
    return end;
}

/* ---- the stream thread ------------------------------------------------------------ */

static void *run(void *arg) {
    (void)arg;
    sess_t s;
    memset(&s, 0, sizeof s);
    s.pfd[0] = s.pfd[1] = -1;
    char err[200] = "";
    stream_req_t r = g.req;
    int failed = 0;
    if (setup(&s, &r, err, sizeof err) != 0) {
        failed = 1;
    } else {
        unsigned epoch = 0;
        uint32_t seq = 0;
        int prev_end = -1, ever = 0, tries = 0;
        while (!g.stop) {
            int started = 0;
            int end = run_epoch(&s, &r, epoch, &seq, prev_end, &started, err, sizeof err);
            pthread_mutex_lock(&g.mu);
            g.ends[end]++;
            if (end != END_STOP) snprintf(g.err, sizeof g.err, "%s", err);
            pthread_mutex_unlock(&g.mu);
            if (started) { epoch++; ever = 1; tries = 0; }
            if (end == END_STOP) break;
            if (!ever) { failed = 1; break; }          /* stream_start reports it */
            /* a missing receiver may come back: keep trying until stream_stop. The radio
             * failing to arm ten times running is a hardware problem: give up. */
            if (!started && end != END_SEND && ++tries >= 10) { failed = 1; break; }
            if (end == END_SEND || end == END_ARM || end == END_NOEDGE) usleep(1000000);
            set_state(ST_ARMING, NULL);
            fprintf(stderr, "pluto_ctld: stream: epoch ended (%s): %s; re-arming\n",
                    END_NAME[end], err);
            prev_end = end;
        }
    }
    teardown(&s);
    pthread_mutex_lock(&g.mu);
    g.state = failed ? ST_FAILED : ST_IDLE;
    if (failed) snprintf(g.err, sizeof g.err, "%s", err);
    g.exited = 1;
    pthread_mutex_unlock(&g.mu);
    return NULL;
}

static void reap(void) {
    pthread_mutex_lock(&g.mu);
    int join = g.thread_live && g.exited;
    pthread_mutex_unlock(&g.mu);
    if (join) {
        pthread_join(g.thr, NULL);
        g.thread_live = 0;
    }
}

int stream_running(void) {
    reap();
    return g.thread_live;
}

int stream_start(void *zctx, const stream_req_t *req, char *err, size_t errlen) {
    reap();
    if (g.thread_live) { snprintf(err, errlen, "already streaming"); return -1; }
    if (!req->connect[0] || req->rate_hz <= 0 || req->freq_hz <= 0 ||
        (req->channels != 1 && req->channels != 2) || req->block_ms < 10 ||
        req->block_ms > 300 || req->nblocks < 2 || req->nblocks > 32) {
        snprintf(err, errlen, "bad stream request (connect, freq_hz, sample_rate_hz; "
                 "channels 1|2, block_ms 10..300, blocks 2..32)");
        return -1;
    }
    pthread_mutex_lock(&g.mu);
    g.req = *req;
    g.zctx = zctx;
    g.stop = 0;
    g.exited = 0;
    g.state = ST_ARMING;
    g.err[0] = '\0';
    g.t_start = realtime_s();
    g.epochs = g.blocks = g.samples = g.bytes = 0;
    memset(g.ends, 0, sizeof g.ends);
    g.lag_s = g.max_lag_s = 0.0;
    pthread_mutex_unlock(&g.mu);
    if (pthread_create(&g.thr, NULL, run, NULL) != 0) {
        snprintf(err, errlen, "pthread_create: %s", strerror(errno));
        return -1;
    }
    g.thread_live = 1;
    /* tune (up to ~3 s for a new rate) + a fresh PPS + the arm + block 0 */
    for (int i = 0; i < 600; i++) {
        pthread_mutex_lock(&g.mu);
        int st = g.state, ex = g.exited;
        pthread_mutex_unlock(&g.mu);
        if (st == ST_STREAMING) return 0;
        if (ex) {
            reap();
            snprintf(err, errlen, "%s", g.err[0] ? g.err : "stream failed to start");
            return -1;
        }
        usleep(20000);
    }
    g.stop = 1;
    pthread_join(g.thr, NULL);
    g.thread_live = 0;
    snprintf(err, errlen, "stream did not start within 12 s");
    return -1;
}

/* text from the system or the client, made safe inside a JSON string */
static void json_text(char *dst, size_t len, const char *src) {
    size_t i = 0;
    for (; src[i] && i + 1 < len; i++)
        dst[i] = (src[i] == '"' || src[i] == '\\' || (unsigned char)src[i] < 0x20) ? '\'' : src[i];
    dst[i] = '\0';
}

void stream_status(char *json, size_t len) {
    reap();
    pthread_mutex_lock(&g.mu);
    char e[sizeof g.err], c[sizeof g.req.connect];
    json_text(e, sizeof e, g.err);
    json_text(c, sizeof c, g.req.connect);
    double up = realtime_s() - g.t_start;
    double secs = g.fs > 0 ? (double)g.samples / g.fs : 0.0;
    snprintf(json, len,
        "{\"state\":\"%s\",\"connect\":\"%s\",\"sample_rate_hz\":%.0f,\"center_freq_hz\":%.0f,"
        "\"channels\":%d,\"block_samples\":%d,\"blocks_queued\":%d,\"ticks_per_sample\":%d,"
        "\"epoch\":%u,\"epochs\":%llu,\"epoch_t0_s\":%lld,\"blocks\":%llu,\"seconds\":%.3f,"
        "\"MBps\":%.2f,\"lag_ms\":%.1f,\"max_lag_ms\":%.1f,\"xo_locked_at_start\":%s,"
        "\"ended\":{\"overflow\":%llu,\"lag\":%llu,\"send\":%llu,\"refill\":%llu,\"arm\":%llu,"
        "\"no_edge\":%llu},\"error\":\"%s\"}",
        STATE_NAME[g.state], c, g.fs, g.fc, g.req.channels, g.block_samples,
        g.req.nblocks, g.mult, g.epoch, g.epochs, g.epoch_sec, g.blocks, secs,
        up > 0 ? (double)g.bytes / up / 1e6 : 0.0, g.lag_s * 1e3, g.max_lag_s * 1e3,
        g.xo_locked ? "true" : "false", g.ends[END_OVERFLOW], g.ends[END_LAG],
        g.ends[END_SEND], g.ends[END_REFILL], g.ends[END_ARM], g.ends[END_NOEDGE], e);
    pthread_mutex_unlock(&g.mu);
}

int stream_stop(char *json, size_t len) {
    reap();
    int was = g.thread_live;
    if (was) {
        g.stop = 1;
        pthread_join(g.thr, NULL);
        g.thread_live = 0;
    }
    stream_status(json, len);
    return was ? 0 : -1;
}
