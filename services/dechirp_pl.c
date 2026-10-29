/*
 * dechirp_pl.c - see dechirp_pl.h. The block is reached like pps_counter: one 4 KB page
 * of /dev/mem, mapped O_SYNC (uncached), no driver.
 */
#define _GNU_SOURCE
#include "dechirp_pl.h"

#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define R_ID         (0x00 / 4)
#define R_VERSION    (0x04 / 4)
#define R_CTRL       (0x08 / 4)
#define R_DECIM      (0x0C / 4)
#define R_SWEEP_LEN  (0x10 / 4)
#define R_ALIGN      (0x14 / 4)
#define R_PAT0       (0x18 / 4)
#define R_STATUS     (0x1C / 4)
#define R_PERIOD     (0x20 / 4)
#define R_S0         (0x28 / 4)
#define R_SAT_COUNT  (0x2C / 4)
#define R_PAT1       (0x30 / 4)
#define R_PERIOD_ERR (0x34 / 4)

#define C_ENABLE     0x01u
#define C_BYPASS     0x02u
#define C_DETECTOR   0x04u
#define C_SOFT_RESET 0x10u
#define MAP_SIZE     0x1000

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static int probed = 0;
static dcdm_info_t info;
static volatile uint32_t *regs = NULL;

/* `dechirp_decim <base> v1` in the feature file: the bitstream has the block at <base>. */
static int features_base(uint32_t *base, char *why, size_t wl) {
    FILE *f = fopen(DCDM_FEATURES, "r");
    if (!f) { snprintf(why, wl, "no %s", DCDM_FEATURES); return -1; }
    char line[160];
    int found = -1;
    while (fgets(line, sizeof line, f)) {
        char name[48] = "", addr[32] = "", ver[16] = "";
        if (line[0] == '#' || sscanf(line, "%47s %31s %15s", name, addr, ver) < 3) continue;
        if (strcmp(name, "dechirp_decim") != 0) continue;
        char *end = NULL;
        unsigned long a = strtoul(addr, &end, 0);
        /* the PL's general-purpose AXI window, page aligned */
        if (!end || *end || a < 0x40000000UL || a > 0x7FFFF000UL || (a & (MAP_SIZE - 1))) {
            snprintf(why, wl, "%s: bad address %s", DCDM_FEATURES, addr);
            break;
        }
        if (strcmp(ver, "v1") != 0) {
            snprintf(why, wl, "%s: dechirp_decim %s, this daemon knows v1", DCDM_FEATURES, ver);
            break;
        }
        *base = (uint32_t)a;
        found = 0;
        break;
    }
    fclose(f);
    if (found != 0 && !why[0]) snprintf(why, wl, "%s does not list dechirp_decim", DCDM_FEATURES);
    return found;
}

int dcdm_probe(dcdm_info_t *out) {
    pthread_mutex_lock(&mu);
    if (!probed) {
        probed = 1;
        memset(&info, 0, sizeof info);
        uint32_t base = 0;
        if (features_base(&base, info.why, sizeof info.why) == 0) {
            int fd = open("/dev/mem", O_RDWR | O_SYNC);
            void *m = fd >= 0 ? mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                                     (off_t)base) : MAP_FAILED;
            if (fd >= 0) close(fd);                 /* the mapping outlives the fd */
            if (m == MAP_FAILED) {
                snprintf(info.why, sizeof info.why, "/dev/mem map of 0x%08X failed", base);
            } else {
                volatile uint32_t *r = (volatile uint32_t *)m;
                uint32_t id = r[R_ID], ver = r[R_VERSION];
                if (id != DCDM_ID_WORD) {
                    snprintf(info.why, sizeof info.why, "ID at 0x%08X reads 0x%08X", base, id);
                    munmap(m, MAP_SIZE);
                } else if ((ver >> 24) != 1 || ((ver >> 16) & 0xFF) < 1 || (ver & 0xFF) != 3 ||
                           ((ver >> 8) & 0xFF) > 8) {
                    /* 1.1: a sync edge re-arms the sweep state (the stream enables once) */
                    snprintf(info.why, sizeof info.why, "VERSION 0x%08X: this daemon needs "
                             "1.1+ (sync-edge re-arm) with a CIC3", ver);
                    munmap(m, MAP_SIZE);
                } else {
                    regs = r;
                    info.present = 1;
                    info.base = base;
                    info.version = ver;
                    info.max_log2d = (int)((ver >> 8) & 0xFF);
                }
            }
        }
    }
    if (out) *out = info;
    int p = info.present;
    pthread_mutex_unlock(&mu);
    return p;
}

int dcdm_configure(int log2d, uint32_t sweep_len, uint32_t align, uint32_t pat0,
                   uint32_t pat1, char *err, size_t el) {
    if (!dcdm_probe(NULL)) { snprintf(err, el, "no dechirp_decim block: %s", info.why); return -1; }
    regs[R_CTRL] = C_BYPASS | C_DETECTOR;          /* enable 0: configure only like this */
    regs[R_CTRL] = C_BYPASS | C_DETECTOR | C_SOFT_RESET;
    regs[R_DECIM] = (uint32_t)log2d;
    regs[R_SWEEP_LEN] = sweep_len;
    regs[R_ALIGN] = align;
    regs[R_PAT0] = pat0;
    regs[R_PAT1] = pat1;
    const struct { int r; uint32_t v; const char *n; } chk[] = {
        { R_DECIM, (uint32_t)log2d, "DECIM" }, { R_SWEEP_LEN, sweep_len, "SWEEP_LEN" },
        { R_ALIGN, align, "ALIGN" }, { R_PAT0, pat0, "PAT0" }, { R_PAT1, pat1, "PAT1" },
    };
    for (size_t i = 0; i < sizeof chk / sizeof chk[0]; i++) {
        uint32_t got = regs[chk[i].r];
        if (got != chk[i].v) {
            regs[R_CTRL] = C_BYPASS | C_DETECTOR;
            snprintf(err, el, "dechirp_decim %s reads back 0x%08X, wrote 0x%08X", chk[i].n,
                     got, chk[i].v);
            return -1;
        }
    }
    regs[R_CTRL] = C_DETECTOR;                     /* bypass off, still disabled: DMA quiet */
    return 0;
}

void dcdm_enable(int on) {
    if (!dcdm_probe(NULL)) return;
    regs[R_CTRL] = C_DETECTOR | (on ? C_ENABLE : 0u);
}

void dcdm_bypass(void) {
    if (!dcdm_probe(NULL)) return;
    regs[R_CTRL] = C_BYPASS | C_DETECTOR;
}

/* A status register read from the AXI side of an unsynchronised l_clk value: read until
 * two reads agree (they change at most once per sweep). */
static uint32_t rd2(int r) {
    uint32_t a = regs[r];
    for (int i = 0; i < 4; i++) {
        uint32_t b = regs[r];
        if (b == a) break;
        a = b;
    }
    return a;
}

int dcdm_default_align(long long rate_hz) {
    static const double pts[3][2] = { { 4.0, 44.0 }, { 12.0, 45.0 }, { 30.72, 46.0 } };
    double ms = (double)rate_hz / 1e6;
    if (ms <= pts[0][0]) return (int)pts[0][1];
    for (int i = 1; i < 3; i++)
        if (ms <= pts[i][0])
            return (int)(pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * (ms - pts[i - 1][0]) /
                         (pts[i][0] - pts[i - 1][0]) + 0.5);
    return (int)pts[2][1];
}

int dcdm_read(dcdm_state_t *st) {
    if (!dcdm_probe(NULL)) return -1;
    uint32_t s = rd2(R_STATUS);
    st->locked = (int)(s & 1u);
    st->running = (int)((s >> 1) & 1u);
    st->saturated = (int)((s >> 2) & 1u);
    st->outs_per_sweep = s >> 16;
    st->period = rd2(R_PERIOD);
    st->s0 = rd2(R_S0);
    st->sat_count = rd2(R_SAT_COUNT);
    st->period_err = rd2(R_PERIOD_ERR);
    return 0;
}
