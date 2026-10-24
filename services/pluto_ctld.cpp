// pluto_ctld -- GPS-anchored capture-control daemon (ZMQ REP @ :5562) for the
// Pluto+ GPS-timing firmware. The WRITE counterpart to the read-only telemetry
// daemon (pluto_zmqd, :5560/:5561): it tunes the AD9361 and performs a PPS-gated,
// GPS-anchored IQ capture, returning a SigMF (meta + raw ci16_le IQ) pair.
//
// Contract: docs/PLUTO_ZMQ_CTL_ICD.md (api "dsn.pluto_zmq.ctl/1"). The capture core
// is capture_core.c (a refactor of the validated DSN/sdr-stack iq_capture.c).
//
// Two ops on one REP socket (strict REQ/REP lockstep -- EXACTLY one reply each):
//   ping     -> 1 frame  {"pong":true,"api":"dsn.pluto_zmq.ctl/1",...}
//   capture  -> 2 frames [meta-json, iq-bytes] on success; 1 frame {"error":...} on failure
// The client decides success purely by frame count, so on ANY failure send exactly
// one frame, and on success exactly two.
//
// Bind: all interfaces (0.0.0.0) by default; ZMQ_BIND overrides. WRITE interface --
// keep it on the trusted private LAN only (see the ICD security section).
//
// SPDX-License-Identifier: MIT
#include <zmq.h>

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>

#include "capture_core.h"

static volatile sig_atomic_t g_stop = 0;
static void on_term(int) { g_stop = 1; }

static const char *API = "dsn.pluto_zmq.ctl/1";

static double now_unix() {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// ---- tiny flat-JSON readers (the request is one flat object from json.dumps) ----

// Index just past `"key":` (whitespace skipped), or std::string::npos.
static size_t jpos(const std::string &s, const char *key) {
    std::string pat = "\"";
    pat += key;
    pat += "\"";
    size_t p = s.find(pat);
    if (p == std::string::npos) return std::string::npos;
    p = s.find(':', p + pat.size());
    if (p == std::string::npos) return std::string::npos;
    p++;
    while (p < s.size() && (s[p] == ' ' || s[p] == '\t' || s[p] == '\n')) p++;
    return p;
}

// Numeric token at `key`; returns true and sets *out if present & parseable.
static bool jnum(const std::string &s, const char *key, double *out) {
    size_t p = jpos(s, key);
    if (p == std::string::npos) return false;
    size_t q = p;
    while (q < s.size()) {
        char c = s[q];
        if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' ||
            c == 'e' || c == 'E') q++;
        else break;
    }
    if (q == p) return false;
    *out = atof(s.substr(p, q - p).c_str());
    return true;
}

static bool jbool(const std::string &s, const char *key, bool dflt) {
    size_t p = jpos(s, key);
    if (p == std::string::npos) return dflt;
    if (s.compare(p, 4, "true") == 0) return true;
    if (s.compare(p, 5, "false") == 0) return false;
    return dflt;
}

// String token at `key` (no escape handling needed for our fields).
static std::string jstr(const std::string &s, const char *key) {
    size_t p = jpos(s, key);
    if (p == std::string::npos || s[p] != '"') return "";
    size_t q = s.find('"', p + 1);
    if (q == std::string::npos) return "";
    return s.substr(p + 1, q - (p + 1));
}

static std::string json_escape(const std::string &s) {
    std::string o;
    for (size_t i = 0; i < s.size(); ++i) {
        char c = s[i];
        if (c == '"' || c == '\\') { o += '\\'; o += c; }
        else if (c == '\n') o += "\\n";
        else if (c == '\r') o += "\\r";
        else if ((unsigned char)c < 0x20) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); o += b; }
        else o += c;
    }
    return o;
}

// ---- replies ---------------------------------------------------------------

static void send_one(void *sock, const std::string &s) {
    zmq_send(sock, s.data(), s.size(), 0);
}

static void send_error(void *sock, const std::string &msg) {
    std::string r = "{\"error\":\"";
    r += json_escape(msg);
    r += "\",\"api\":\"";
    r += API;
    r += "\"}";
    send_one(sock, r);
}

static void send_ping(void *sock) {
    char b[192];
    snprintf(b, sizeof b,
             "{\"pong\":true,\"api\":\"%s\",\"schema\":\"dsn.health/1\",\"t_unix\":%.3f}",
             API, now_unix());
    send_one(sock, b);
}

// ---- capture dispatch ------------------------------------------------------

// Coexistence lock with xo_correct.sh. While a capture holds the AD9361, the
// xo discipline daemon must NOT write `xo_correction` -- that re-derives the chip
// clocks and snaps the sample rate back to the default, which would reconfigure the
// data path under an in-flight DMA and wedge the capture (errno-110). pluto_ctld
// drops this file for the duration of capture_run(); xo_correct.sh skips its
// correction while a FRESH lock is present (it ignores a stale one via find -mmin,
// so a crashed daemon can't block discipline forever -- and /tmp is tmpfs, cleared
// on reboot). Best-effort: a missing file just means no extra protection.
static const char *CAP_LOCK_PATH = "/tmp/pluto_ctld.capturing";
static void cap_lock_acquire(void) {
    int fd = open(CAP_LOCK_PATH, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return;
    char b[16];
    int n = snprintf(b, sizeof b, "%ld\n", (long)getpid());
    if (n > 0) { ssize_t w = write(fd, b, (size_t)n); (void)w; }
    close(fd);
}
static void cap_lock_release(void) { unlink(CAP_LOCK_PATH); }

// Zero-copy IQ frame. zmq calls this (on its I/O thread) once it no longer needs the
// bytes -- after they are written to the socket, or dropped with a vanished peer.
static void iq_sent(void *data, void *hint) {
    (void)data;
    char c = 1;
    ssize_t w = write((int)(intptr_t)hint, &c, 1);
    (void)w;
}
static const int IQ_SEND_TIMEOUT_MS = 30000;    // 118 MB goes out in ~2.5 s on GbE

// Wait up to wait_ms for zmq to let go of a reply's IQ, then free its DMA buffer.
static bool finish_send(capture_result_t *res, int pfd[2], int wait_ms) {
    struct pollfd p;
    p.fd = pfd[0]; p.events = POLLIN; p.revents = 0;
    if (poll(&p, 1, wait_ms) != 1) return false;
    char c;
    ssize_t r = read(pfd[0], &c, 1);
    (void)r;
    capture_release(res);
    close(pfd[0]);
    close(pfd[1]);
    return true;
}

// A reply zmq had not finished sending (stalled peer). Its buffer stays allocated, and
// the next capture would fail to create one, until zmq lets go of it.
static capture_result_t g_unsent;
static int g_unsent_fd[2] = {-1, -1};

static void handle_capture(void *sock, const std::string &body) {
    capture_req_t req;
    memset(&req, 0, sizeof req);

    if (g_unsent_fd[0] >= 0) {
        if (!finish_send(&g_unsent, g_unsent_fd, 5000)) {
            send_error(sock, "previous capture's IQ is still being sent");
            return;
        }
        g_unsent_fd[0] = g_unsent_fd[1] = -1;
    }

    double v;
    if (!jnum(body, "freq_hz", &v))        { send_error(sock, "missing freq_hz"); return; }
    req.freq_hz = (long long)v;
    if (!jnum(body, "sample_rate_hz", &v)) { send_error(sock, "missing sample_rate_hz"); return; }
    req.rate_hz = (long long)v;
    if (!jnum(body, "samples", &v))        { send_error(sock, "missing samples"); return; }
    req.samples = (size_t)v;

    req.require_gps = jbool(body, "require_gps", true);
    req.tdd_sync    = jbool(body, "tdd_sync", false);
    if (jnum(body, "gain_db", &v))        { req.gain_db = v; req.have_gain = 1; }
    if (jnum(body, "t0_gps", &v))         { req.t0_gps = v; req.have_t0 = 1; }
    if (jnum(body, "offset_samples", &v)) { req.offset_samples = (long long)v; }

    std::string node = jstr(body, "node_id");      // keep alive for req.node_id
    if (!node.empty()) req.node_id = node.c_str();

    double la, lo, al;
    if (jnum(body, "lat", &la) && jnum(body, "lon", &lo) && jnum(body, "alt", &al)) {
        req.lat = la; req.lon = lo; req.alt = al; req.have_pos = 1;
    }

    capture_result_t res;
    cap_lock_acquire();              /* pause xo_correct's rate-disturbing write */
    int rc = capture_run(&req, &res);
    cap_lock_release();
    if (rc != 0) {
        send_error(sock, res.err[0] ? res.err : "capture failed");
        return;
    }

    // success: exactly two frames [meta, iq]. The IQ goes out zero-copy from the DMA
    // buffer; release the buffer only after zmq is done with it.
    zmq_send(sock, res.meta_json, strlen(res.meta_json), ZMQ_SNDMORE);
    int pfd[2];
    if (pipe(pfd) != 0) {                       // no pipe: fall back to a copying send
        zmq_send(sock, res.iq, res.iq_len, 0);
        capture_release(&res);
        return;
    }
    zmq_msg_t m;
    zmq_msg_init_data(&m, res.iq, res.iq_len, iq_sent, (void *)(intptr_t)pfd[1]);
    if (zmq_msg_send(&m, sock, 0) < 0) zmq_msg_close(&m);   // close runs iq_sent
    if (!finish_send(&res, pfd, IQ_SEND_TIMEOUT_MS)) {
        // zmq still holds the bytes: never free memory it may still read. Park the
        // buffer; the next capture request finishes the release.
        fprintf(stderr, "pluto_ctld: IQ send not finished after %d s; buffer kept\n",
                IQ_SEND_TIMEOUT_MS / 1000);
        g_unsent = res;
        g_unsent_fd[0] = pfd[0];
        g_unsent_fd[1] = pfd[1];
    }
}

// ---- main ------------------------------------------------------------------

int main(int argc, char **argv) {
    std::string bind_ip = "0.0.0.0";
    int port = 5562;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--bind" && i + 1 < argc) bind_ip = argv[++i];
        else if (a == "--port" && i + 1 < argc) port = atoi(argv[++i]);
        else if (a == "-h" || a == "--help") {
            printf("usage: pluto_ctld [--bind IP] [--port N]\n");
            return 0;
        }
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, nullptr);
    sigaction(SIGINT, &sa, nullptr);
    signal(SIGPIPE, SIG_IGN);

    void *ctx = zmq_ctx_new();
    void *rep = zmq_socket(ctx, ZMQ_REP);
    int linger = 0;
    zmq_setsockopt(rep, ZMQ_LINGER, &linger, sizeof linger);

    std::string ep = "tcp://" + bind_ip + ":" + std::to_string(port);
    if (zmq_bind(rep, ep.c_str()) != 0) {
        fprintf(stderr, "pluto_ctld: bind %s failed: %s\n", ep.c_str(),
                zmq_strerror(zmq_errno()));
        return 1;
    }
    fprintf(stderr, "pluto_ctld: REP %s (capture-control)\n", ep.c_str());

    while (!g_stop) {
        zmq_msg_t m;
        zmq_msg_init(&m);
        int n = zmq_msg_recv(&m, rep, 0);
        if (n < 0) {
            zmq_msg_close(&m);
            if (zmq_errno() == EINTR) continue;
            break;
        }
        std::string raw((char *)zmq_msg_data(&m), zmq_msg_size(&m));
        zmq_msg_close(&m);

        // Drain any extra request frames (the client sends single-frame requests;
        // be robust so a stray multipart can't desync the REP socket).
        int more = 0;
        size_t mlen = sizeof more;
        while (zmq_getsockopt(rep, ZMQ_RCVMORE, &more, &mlen) == 0 && more) {
            zmq_msg_t extra; zmq_msg_init(&extra);
            if (zmq_msg_recv(&extra, rep, 0) < 0) { zmq_msg_close(&extra); break; }
            zmq_msg_close(&extra);
        }

        // Dispatch (spec §1): a body starting with '{' is a JSON object -> use its
        // "op"; otherwise the raw frame text IS the op (so bare "ping" works).
        std::string body = raw;
        size_t s = body.find_first_not_of(" \t\r\n");
        std::string op;
        if (s != std::string::npos && body[s] == '{') {
            op = jstr(body, "op");
        } else {
            size_t e = body.find_last_not_of(" \t\r\n");
            op = (s == std::string::npos) ? "" : body.substr(s, e - s + 1);
        }

        if (op == "ping") {
            send_ping(rep);
        } else if (op == "capture") {
            handle_capture(rep, body);
        } else {
            send_error(rep, std::string("unknown op ") + op);
        }
    }

    fprintf(stderr, "pluto_ctld: shutting down\n");
    zmq_close(rep);
    zmq_ctx_term(ctx);
    return 0;
}
