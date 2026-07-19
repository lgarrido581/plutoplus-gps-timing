// pluto_zmqd -- read-only ZMQ telemetry daemon for the Pluto+ GPS-timing firmware.
//
// Exposes the data DSN currently needs *root SSH + devmem/gpspipe* for, so the two
// read-only SSH paths can be retired. Read-only by construction: no capture, no
// retune, no register writes. Those are deliberately v2 on a separate authed socket.
//
// Two ZMQ sockets, JSON bodies (UTF-8, one JSON object per message):
//   PUB  tcp://<ip>:5560  -- 1 Hz snapshot. Absence of frames == liveness signal.
//   REP  tcp://<ip>:5561  -- request/reply for a fresh synchronous read. Request is
//                            either {"op":"<name>"} or a bare op word. Ops:
//                              snapshot | timing | gps | rf | dma | ping
//
// JSON schema reuses the exact dsn.health/1 field names for timing+gps (so the DSN
// NodeStatus.from_health_json() works after only a transport swap) and ADDS rf{} and
// dma{} blocks. See docs/PLUTO_ZMQ_API.md.
//
// Data sources (all already on the radio; no new runtime deps beyond libzmq):
//   timing -- pps_counter AXI registers @ 0x7C460000 via /dev/mem mmap
//             + xo_ppm parsed from /var/log/xocorrect.log
//   gps    -- a persistent gpsd client connection (127.0.0.1:2947, WATCH json)
//   rf     -- ad9361-phy sysfs (rx/tx LO, sample rate, bandwidth, gain, gain mode)
//   dma    -- best-effort: scan the kernel log ring for cf_axi DMA error signatures
//
// Binds all interfaces (0.0.0.0) by default via the init script (the LAN subnet is not
// knowable in advance); set ZMQ_BIND to restrict it. Read-only telemetry on local
// links only; the Pluto is not on the tailnet by design. Build: cross-compiled C++
// (buildroot package pluto-zmqd, links libzmq). Debug a radio:  pluto_zmqd --print
//
// SPDX-License-Identifier: MIT
#include <zmq.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <setjmp.h>
#include <signal.h>
#include <sys/klog.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>

// Firmware release version (this repo's tag, e.g. "2.0.3"). Baked in at build time via
// -DGPS_TIMING_VERSION from the repo VERSION file (docker-run.sh -> docker-build-inner.sh),
// and reported in the snapshot "fw_version" so a consumer knows the exact release running.
#ifndef GPS_TIMING_VERSION
#define GPS_TIMING_VERSION "unknown"
#endif

// ---------------------------------------------------------------------------
// pps_counter AXI register map (raw devmem space; no DT node -- same as the CGI).
// ---------------------------------------------------------------------------
static const off_t  PPSC_BASE = 0x7C460000;
static const size_t PPSC_SPAN = 0x1000;       // one page covers all regs
static const uint32_t PPSC_MAGIC = 0x50505343; // "PPSC" at offset 0
static const off_t  REG_STATUS = 0x08;        // bit0 = pps_present
static const off_t  REG_DELTA  = 0x14;        // cnt_clk counts between PPS == rate
static const off_t  REG_SEQ    = 0x18;        // pps_seq (increments each PPS edge)

static const char*  XO_LOG     = "/var/log/xocorrect.log";
static const char*  GPSD_HOST  = "127.0.0.1";
static const int    GPSD_PORT  = 2947;
static const long   GPS_STALE_MS = 5000;      // gps fields older than this -> dropped
static const long   PUB_PERIOD_MS = 1000;     // PUB cadence (1 Hz)

// ---------------------------------------------------------------------------
// Globals (single-threaded daemon; a handful of cached values).
// ---------------------------------------------------------------------------
static volatile sig_atomic_t g_stop = 0;

static volatile uint32_t* g_regs = nullptr;   // mmap'd pps_counter page (or null)
static bool g_have_counter = false;

// pps_advancing is a *time-based* liveness verdict, recomputed on the 1 Hz tick so a
// sub-second REP can't make it flap; REP reads present/seq/delta live but report this
// cached verdict. It is NOT "seq changed since the last tick": the tick is a ~1 Hz
// software timer (mono clock) sampling the 1 Hz hardware PPS_SEQ, so their two 1 Hz
// rates beat -- when a tick lands in the same PPS second as the previous one, seq is
// unchanged for that single tick even though PPS is perfectly live. Declaring "not
// advancing" on one unchanged tick therefore aliases to a false negative. Instead we
// latch the mono time PPS_SEQ last changed and only call PPS dead once it has been
// frozen longer than a couple PPS periods.
static uint32_t g_last_seq = 0;
static bool g_last_seq_valid = false;
static struct timespec g_seq_change_ts = {0, 0};   // mono time PPS_SEQ last moved
static const double PPS_STALE_S = 2.5;             // > 2 PPS periods: immune to the beat
static const char* g_advancing = "null";      // "true" | "false" | "null"

static std::string g_node_id = "pluto";
static std::string g_board_id = "plutoplus";

// latest gpsd reports (raw JSON lines) + their arrival time (monotonic ms)
static int g_gps_fd = -1;
static std::string g_gps_buf;                 // line-assembly buffer
static std::string g_last_tpv, g_last_sky;
static long g_tpv_ms = -1000000, g_sky_ms = -1000000;

// SIGBUS guard for the one-time counter probe (an absent AXI slave faults on read).
static sigjmp_buf g_busjmp;
static volatile sig_atomic_t g_bus_faulted = 0;
static void on_sigbus(int) { g_bus_faulted = 1; siglongjmp(g_busjmp, 1); }
static void on_term(int) { g_stop = 1; }

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------
static long mono_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// Append `val` (already a valid JSON token) under `name` to a "{...}" body builder.
// Skips empty values so absent fields are simply omitted (matches the /health CGI).
static void add_field(std::string& body, bool& first, const char* name,
                      const std::string& val) {
    if (val.empty()) return;
    if (!first) body += ",";
    first = false;
    body += "\"";
    body += name;
    body += "\":";
    body += val;
}

// JSON-escape an arbitrary string into a quoted JSON string token.
static std::string json_str(const std::string& s) {
    std::string o = "\"";
    for (size_t i = 0; i < s.size(); ++i) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n";  break;
            case '\r': o += "\\r";  break;
            case '\t': o += "\\t";  break;
            default:
                if (c < 0x20) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); o += b; }
                else o += (char)c;
        }
    }
    o += "\"";
    return o;
}

// Extract the numeric token following "key": in a JSON line, verbatim (so we never
// reformat / lose precision on lat/lon). Mirrors the CGI's grep -oE "\"key\":-?[0-9.]+".
static std::string find_num(const std::string& s, const char* key) {
    if (s.empty()) return "";
    std::string pat = "\"";
    pat += key;
    pat += "\":";
    size_t p = s.find(pat);
    if (p == std::string::npos) return "";
    p += pat.size();
    size_t q = p;
    while (q < s.size()) {
        char c = s[q];
        if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' ||
            c == 'e' || c == 'E')
            q++;
        else
            break;
    }
    if (q == p) return "";
    return s.substr(p, q - p);
}

// Read a whole small sysfs/proc file, trimmed of trailing whitespace/newline.
static std::string read_file_trim(const std::string& path) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return "";
    char buf[512];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';
    std::string s(buf);
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ' ||
                          s.back() == '\t'))
        s.pop_back();
    return s;
}

// Is `s` a JSON-number token (optional sign, digits, one dot, optional exponent)?
static bool is_number(const std::string& s) {
    if (s.empty()) return false;
    bool digit = false;
    for (size_t i = 0; i < s.size(); ++i) {
        char c = s[i];
        if (c >= '0' && c <= '9') digit = true;
        else if (c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E') continue;
        else return false;
    }
    return digit;
}

// ---------------------------------------------------------------------------
// timing: pps_counter registers + xo_ppm
// ---------------------------------------------------------------------------
static uint32_t reg_read(off_t off) {
    return *(volatile uint32_t*)((volatile char*)g_regs + off);
}

// Map /dev/mem and verify the pps_counter is actually present (ID == "PPSC"). The
// probe read is wrapped in a SIGBUS guard because on a base (no-counter) bitstream
// that AXI address has no slave and the read would fault. If absent, the timing
// block degrades gracefully (pps_present=false, numeric fields null).
static void timing_init() {
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "pluto_zmqd: open(/dev/mem) failed: %s\n", strerror(errno));
        return;
    }
    void* m = mmap(nullptr, PPSC_SPAN, PROT_READ, MAP_SHARED, fd, PPSC_BASE);
    close(fd);
    if (m == MAP_FAILED) {
        fprintf(stderr, "pluto_zmqd: mmap(pps_counter) failed: %s\n", strerror(errno));
        return;
    }
    g_regs = (volatile uint32_t*)m;

    struct sigaction sa, old;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sigbus;
    sigaction(SIGBUS, &sa, &old);
    uint32_t id = 0;
    if (sigsetjmp(g_busjmp, 1) == 0) {
        id = reg_read(0x00);
    } else {
        g_bus_faulted = 1;
    }
    sigaction(SIGBUS, &old, nullptr);  // restore: a later genuine fault should be loud

    if (!g_bus_faulted && id == PPSC_MAGIC) {
        g_have_counter = true;
    } else {
        g_have_counter = false;
        munmap(m, PPSC_SPAN);
        g_regs = nullptr;
        fprintf(stderr, "pluto_zmqd: pps_counter not present (base build) -- "
                        "timing block degraded\n");
    }
}

// Update the cached pps_advancing verdict. Called once per 1 Hz tick only.
// Time-based (see the g_last_seq comment): "true" while PPS_SEQ has moved within the
// last PPS_STALE_S; "false" only once it has been frozen longer than that (real dead
// PPS). A single tick that happens to see no change (the 1 Hz tick/PPS beat) stays
// "true", so healthy PPS never aliases to a spurious "not advancing".
static void timing_tick() {
    if (!g_have_counter) return;
    uint32_t seq = reg_read(REG_SEQ);
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (!g_last_seq_valid) {                 // first sample: seed, verdict stays "null"
        g_last_seq = seq;
        g_seq_change_ts = now;
        g_last_seq_valid = true;
        return;
    }
    if (seq != g_last_seq) {                 // PPS edge counted -> live; stamp when
        g_last_seq = seq;
        g_seq_change_ts = now;
        g_advancing = "true";
    } else {                                 // unchanged -> live unless frozen too long
        double stale = (double)(now.tv_sec - g_seq_change_ts.tv_sec)
                     + (double)(now.tv_nsec - g_seq_change_ts.tv_nsec) / 1e9;
        g_advancing = (stale > PPS_STALE_S) ? "false" : "true";
    }
}

// xo_ppm = the last "(+0.000ppm)"-style value the xocorrect daemon logged (it
// auto-derives nominal from live rate x channel mode, so it is correct in any mode).
// JSON has no leading '+', so strip it. Reads only the file tail.
static std::string parse_xo_ppm() {
    FILE* f = fopen(XO_LOG, "rb");
    if (!f) return "";
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    if (sz <= 0) { fclose(f); return ""; }
    long n = sz < 4096 ? sz : 4096;
    fseek(f, sz - n, SEEK_SET);
    std::string buf;
    buf.resize((size_t)n);
    size_t got = fread(&buf[0], 1, (size_t)n, f);
    fclose(f);
    buf.resize(got);
    size_t pos = buf.rfind("ppm");
    if (pos == std::string::npos) return "";
    long e = (long)pos, b = e - 1;
    while (b >= 0) {
        char c = buf[(size_t)b];
        if ((c >= '0' && c <= '9') || c == '.' || c == '+' || c == '-') b--;
        else break;
    }
    std::string tok = buf.substr((size_t)(b + 1), (size_t)(e - (b + 1)));
    if (!tok.empty() && tok[0] == '+') tok = tok.substr(1);
    return is_number(tok) ? tok : "";
}

static std::string timing_block() {
    bool present = false;
    std::string seq = "null", delta = "null";
    if (g_have_counter) {
        present = (reg_read(REG_STATUS) & 1u) != 0;
        seq = std::to_string(reg_read(REG_SEQ));
        delta = std::to_string(reg_read(REG_DELTA));
    }
    std::string xo = parse_xo_ppm();
    if (xo.empty()) xo = "null";
    std::string b = "{";
    b += "\"pps_present\":";
    b += present ? "true" : "false";
    b += ",\"pps_advancing\":";
    b += g_have_counter ? g_advancing : "null";
    b += ",\"pps_seq\":";
    b += seq;
    b += ",\"xo_ppm\":";
    b += xo;
    b += ",\"cnt_clk_hz\":";
    b += delta;
    b += "}";
    return b;
}

// ---------------------------------------------------------------------------
// gps: persistent gpsd client (no per-request fork, instant snapshots)
// ---------------------------------------------------------------------------
static void gps_connect() {
    if (g_gps_fd >= 0) return;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons(GPSD_PORT);
    inet_pton(AF_INET, GPSD_HOST, &sa.sin_addr);
    if (connect(fd, (struct sockaddr*)&sa, sizeof sa) != 0) {
        close(fd);
        return;
    }
    const char* watch = "?WATCH={\"enable\":true,\"json\":true};\n";
    (void)!write(fd, watch, strlen(watch));
    fcntl(fd, F_SETFL, O_NONBLOCK);
    g_gps_fd = fd;
    g_gps_buf.clear();
}

static void gps_drop() {
    if (g_gps_fd >= 0) close(g_gps_fd);
    g_gps_fd = -1;
    g_gps_buf.clear();
}

// Drain whatever gpsd has sent and cache the latest TPV / SKY lines. Returns false
// if the connection closed/errored (caller drops + reconnects later).
static bool gps_pump() {
    if (g_gps_fd < 0) return false;
    char buf[4096];
    for (;;) {
        ssize_t n = read(g_gps_fd, buf, sizeof buf);
        if (n > 0) {
            g_gps_buf.append(buf, (size_t)n);
            if (g_gps_buf.size() > 65536) g_gps_buf.erase(0, g_gps_buf.size() - 65536);
            continue;
        }
        if (n == 0) return false;                          // peer closed
        if (errno == EAGAIN || errno == EWOULDBLOCK) break; // drained
        if (errno == EINTR) continue;
        return false;                                       // real error
    }
    long now = mono_ms();
    size_t nl;
    while ((nl = g_gps_buf.find('\n')) != std::string::npos) {
        std::string line = g_gps_buf.substr(0, nl);
        g_gps_buf.erase(0, nl + 1);
        if (line.find("\"class\":\"TPV\"") != std::string::npos) {
            g_last_tpv = line;
            g_tpv_ms = now;
        } else if (line.find("\"class\":\"SKY\"") != std::string::npos) {
            g_last_sky = line;
            g_sky_ms = now;
        }
    }
    return true;
}

static std::string gps_block() {
    long now = mono_ms();
    std::string tpv = (now - g_tpv_ms <= GPS_STALE_MS) ? g_last_tpv : "";
    std::string sky = (now - g_sky_ms <= GPS_STALE_MS) ? g_last_sky : "";
    std::string b = "{";
    bool first = true;
    add_field(b, first, "mode", find_num(tpv, "mode"));
    add_field(b, first, "lat_deg", find_num(tpv, "lat"));
    add_field(b, first, "lon_deg", find_num(tpv, "lon"));
    add_field(b, first, "alt_hae_m", find_num(tpv, "altHAE"));
    add_field(b, first, "alt_msl_m", find_num(tpv, "altMSL"));
    add_field(b, first, "geoid_sep_m", find_num(tpv, "geoidSep"));
    add_field(b, first, "eph_m", find_num(tpv, "eph"));
    add_field(b, first, "epv_m", find_num(tpv, "epv"));
    add_field(b, first, "n_sat_used", find_num(sky, "uSat"));
    add_field(b, first, "speed_mps", find_num(tpv, "speed"));
    add_field(b, first, "track_deg", find_num(tpv, "track"));
    add_field(b, first, "climb_mps", find_num(tpv, "climb"));
    b += "}";
    return b;
}

// ---------------------------------------------------------------------------
// rf: ad9361-phy sysfs (resolve the phy by name, then read its attributes)
// ---------------------------------------------------------------------------
static std::string g_phy_path;  // cached "/sys/bus/iio/devices/iio:deviceN"

static void rf_init() {
    for (int i = 0; i < 16; ++i) {
        std::string base = "/sys/bus/iio/devices/iio:device" + std::to_string(i);
        if (read_file_trim(base + "/name") == "ad9361-phy") {
            g_phy_path = base;
            return;
        }
    }
}

// Emit a string-valued attribute (e.g. gain_control_mode) as a JSON string.
static void rf_add(std::string& b, bool& first, const char* name, const char* attr) {
    if (g_phy_path.empty()) return;
    std::string v = read_file_trim(g_phy_path + "/" + attr);
    if (v.empty()) return;
    add_field(b, first, name, is_number(v) ? v : json_str(v));
}

// Emit a numeric attribute as a JSON number. Some IIO attributes carry a unit
// suffix (e.g. hardwaregain reads "71.000000 dB"), so take the leading token and
// emit it bare if numeric; otherwise fall back to the raw string (never silently drop).
static void rf_add_num(std::string& b, bool& first, const char* name, const char* attr) {
    if (g_phy_path.empty()) return;
    std::string v = read_file_trim(g_phy_path + "/" + attr);
    if (v.empty()) return;
    size_t sp = v.find_first_of(" \t");
    std::string tok = (sp == std::string::npos) ? v : v.substr(0, sp);
    add_field(b, first, name, is_number(tok) ? tok : json_str(v));
}

static std::string rf_block() {
    if (g_phy_path.empty()) rf_init();  // retry (iio may appear after boot)
    std::string b = "{";
    bool first = true;
    add_field(b, first, "phy", g_phy_path.empty() ? "" : json_str("ad9361-phy"));
    rf_add_num(b, first, "rx_lo_hz", "out_altvoltage0_RX_LO_frequency");
    rf_add_num(b, first, "tx_lo_hz", "out_altvoltage1_TX_LO_frequency");
    rf_add_num(b, first, "sample_rate_hz", "in_voltage_sampling_frequency");
    rf_add_num(b, first, "rf_bandwidth_hz", "in_voltage_rf_bandwidth");
    rf_add_num(b, first, "rx_gain_db", "in_voltage0_hardwaregain");
    rf_add(b, first, "gain_control_mode", "in_voltage0_gain_control_mode");
    rf_add(b, first, "rf_port_select", "in_voltage0_rf_port_select");
    b += "}";
    return b;
}

// ---------------------------------------------------------------------------
// dma: best-effort. Scan the kernel log ring (non-destructive) for cf_axi DMA error
// signatures so DSN can spot the errno-110 wedge WITHOUT attempting a capture. This
// is a heuristic -- a wedge does not always log -- so it is documented as best-effort.
// ---------------------------------------------------------------------------
static bool line_is_dma_error(const std::string& l) {
    if (l.find("cf_axi") == std::string::npos &&
        l.find("axi-ad9361") == std::string::npos &&
        l.find("ad9361") == std::string::npos)
        return false;
    return l.find("timeout") != std::string::npos ||
           l.find("Timeout") != std::string::npos ||
           l.find("underflow") != std::string::npos ||
           l.find("overflow") != std::string::npos ||
           l.find("error") != std::string::npos ||
           l.find("Error") != std::string::npos;
}

static std::string dma_block() {
    std::string b = "{";
    int len = klogctl(10 /*SYSLOG_ACTION_SIZE_BUFFER*/, nullptr, 0);
    if (len <= 0 || len > (1 << 20)) len = 131072;
    std::string buf;
    buf.resize((size_t)len);
    int got = klogctl(3 /*SYSLOG_ACTION_READ_ALL*/, &buf[0], len);
    bool ok = true;
    std::string last_err;
    if (got > 0) {
        buf.resize((size_t)got);
        size_t start = 0, nl;
        while (start < buf.size()) {
            nl = buf.find('\n', start);
            std::string line = buf.substr(start, nl == std::string::npos ? std::string::npos
                                                                          : nl - start);
            if (line_is_dma_error(line)) { ok = false; last_err = line; }
            if (nl == std::string::npos) break;
            start = nl + 1;
        }
    }
    b += "\"rx_ok\":";
    b += ok ? "true" : "false";
    b += ",\"last_error\":";
    if (last_err.empty()) {
        b += "null";
    } else {
        if (last_err.size() > 200) last_err.resize(200);
        b += json_str(last_err);
    }
    b += "}";
    return b;
}

// ---------------------------------------------------------------------------
// snapshot assembly
// ---------------------------------------------------------------------------
static std::string read_uptime_s() {
    std::string up = read_file_trim("/proc/uptime");  // "12345.67 8888.88"
    size_t sp = up.find_first_of(" .");
    if (sp == std::string::npos) return "0";
    std::string s = up.substr(0, sp);
    return is_number(s) ? s : "0";
}

static std::string build_snapshot() {
    char hdr[320];
    snprintf(hdr, sizeof hdr,
             "{\"schema\":\"dsn.health/1\",\"api\":\"dsn.pluto_zmq/1\","
             "\"fw_version\":\"" GPS_TIMING_VERSION "\","
             "\"node_id\":%s,\"board\":%s,\"t_unix\":%ld,\"uptime_s\":%s,",
             json_str(g_node_id).c_str(), json_str(g_board_id).c_str(),
             (long)time(nullptr), read_uptime_s().c_str());
    std::string out = hdr;
    out += "\"timing\":" + timing_block() + ",";
    out += "\"gps\":" + gps_block() + ",";
    out += "\"rf\":" + rf_block() + ",";
    out += "\"dma\":" + dma_block() + "}";
    return out;
}

// A single sub-block reply: {schema, api, t_unix, "<name>":<block>}.
static std::string build_block(const char* name, const std::string& block) {
    char hdr[160];
    snprintf(hdr, sizeof hdr,
             "{\"schema\":\"dsn.health/1\",\"api\":\"dsn.pluto_zmq/1\",\"t_unix\":%ld,",
             (long)time(nullptr));
    std::string out = hdr;
    out += "\"";
    out += name;
    out += "\":" + block + "}";
    return out;
}

// Pull the op out of a request: prefer {"op":"X"}, else treat the trimmed body as X.
static std::string parse_op(const std::string& req) {
    std::string pat = "\"op\":";
    size_t p = req.find(pat);
    if (p != std::string::npos) {
        p = req.find('"', p + pat.size());
        if (p != std::string::npos) {
            size_t q = req.find('"', p + 1);
            if (q != std::string::npos) return req.substr(p + 1, q - p - 1);
        }
    }
    std::string s = req;
    while (!s.empty() && (s.front() == ' ' || s.front() == '"' || s.front() == '\n'))
        s.erase(s.begin());
    while (!s.empty() && (s.back() == ' ' || s.back() == '"' || s.back() == '\n' ||
                          s.back() == '\r'))
        s.pop_back();
    return s;
}

static std::string handle_request(const std::string& req) {
    std::string op = parse_op(req);
    if (op == "snapshot" || op.empty()) return build_snapshot();
    if (op == "timing") return build_block("timing", timing_block());
    if (op == "gps") return build_block("gps", gps_block());
    if (op == "rf") return build_block("rf", rf_block());
    if (op == "dma") return build_block("dma", dma_block());
    if (op == "ping") {
        char b[160];
        snprintf(b, sizeof b,
                 "{\"schema\":\"dsn.health/1\",\"api\":\"dsn.pluto_zmq/1\","
                 "\"pong\":true,\"t_unix\":%ld}", (long)time(nullptr));
        return b;
    }
    return "{\"error\":\"unknown op\",\"op\":" + json_str(op) + "}";
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    std::string bind_ip = "127.0.0.1";
    int pub_port = 5560, rep_port = 5561;
    bool print_once = false;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--bind" && i + 1 < argc) bind_ip = argv[++i];
        else if (a == "--pub-port" && i + 1 < argc) pub_port = atoi(argv[++i]);
        else if (a == "--rep-port" && i + 1 < argc) rep_port = atoi(argv[++i]);
        else if (a == "--print" || a == "--once") print_once = true;
        else if (a == "-h" || a == "--help") {
            printf("usage: pluto_zmqd [--bind IP] [--pub-port N] [--rep-port N] "
                   "[--print]\n");
            return 0;
        }
    }

    char hn[128];
    if (gethostname(hn, sizeof hn) == 0) { hn[sizeof hn - 1] = '\0'; g_node_id = hn; }
    std::string board_cfg = read_file_trim("/etc/gps-timing-board");
    size_t board_pos = board_cfg.find("BOARD=");
    if (board_pos != std::string::npos) {
        board_pos += 6;
        size_t board_end = board_cfg.find_first_of("\r\n", board_pos);
        g_board_id = board_cfg.substr(board_pos, board_end - board_pos);
    }

    timing_init();
    rf_init();

    // --print: emit one snapshot to stdout and exit (debug a radio without a client).
    if (print_once) {
        gps_connect();
        for (int i = 0; i < 30 && g_gps_fd >= 0; ++i) {  // up to ~1.5s for a TPV
            if (!gps_pump()) break;
            if (g_tpv_ms > -1000000) break;
            struct timespec t = {0, 50 * 1000 * 1000};
            nanosleep(&t, nullptr);
        }
        timing_tick();
        printf("%s\n", build_snapshot().c_str());
        gps_drop();
        return 0;
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, nullptr);
    sigaction(SIGINT, &sa, nullptr);
    signal(SIGPIPE, SIG_IGN);

    void* ctx = zmq_ctx_new();
    void* pub = zmq_socket(ctx, ZMQ_PUB);
    void* rep = zmq_socket(ctx, ZMQ_REP);
    int linger = 0;
    zmq_setsockopt(pub, ZMQ_LINGER, &linger, sizeof linger);
    zmq_setsockopt(rep, ZMQ_LINGER, &linger, sizeof linger);

    std::string pub_ep = "tcp://" + bind_ip + ":" + std::to_string(pub_port);
    std::string rep_ep = "tcp://" + bind_ip + ":" + std::to_string(rep_port);
    if (zmq_bind(pub, pub_ep.c_str()) != 0) {
        fprintf(stderr, "pluto_zmqd: bind %s failed: %s\n", pub_ep.c_str(),
                zmq_strerror(zmq_errno()));
        return 1;
    }
    if (zmq_bind(rep, rep_ep.c_str()) != 0) {
        fprintf(stderr, "pluto_zmqd: bind %s failed: %s\n", rep_ep.c_str(),
                zmq_strerror(zmq_errno()));
        return 1;
    }
    fprintf(stderr, "pluto_zmqd: PUB %s  REP %s  (counter=%d)\n", pub_ep.c_str(),
            rep_ep.c_str(), g_have_counter ? 1 : 0);

    gps_connect();
    long next_pub = mono_ms();
    long next_gps_retry = mono_ms();

    while (!g_stop) {
        zmq_pollitem_t items[2];
        int n = 0;
        items[n].socket = rep; items[n].fd = 0; items[n].events = ZMQ_POLLIN;
        int rep_idx = n++;
        int gps_idx = -1;
        if (g_gps_fd >= 0) {
            items[n].socket = nullptr; items[n].fd = g_gps_fd;
            items[n].events = ZMQ_POLLIN; gps_idx = n++;
        }

        long now = mono_ms();
        long timeout = next_pub - now;
        if (timeout < 0) timeout = 0;
        if (timeout > 200) timeout = 200;  // also bound it so gpsd drains promptly

        int rc = zmq_poll(items, n, timeout);
        if (rc < 0) {
            if (zmq_errno() == EINTR) continue;
            break;
        }

        if (gps_idx >= 0 && (items[gps_idx].revents & ZMQ_POLLIN)) {
            if (!gps_pump()) { gps_drop(); next_gps_retry = mono_ms() + 2000; }
        }

        if (items[rep_idx].revents & ZMQ_POLLIN) {
            zmq_msg_t m;
            zmq_msg_init(&m);
            if (zmq_msg_recv(&m, rep, 0) >= 0) {
                std::string req((char*)zmq_msg_data(&m), zmq_msg_size(&m));
                zmq_msg_close(&m);
                std::string resp = handle_request(req);
                zmq_send(rep, resp.data(), resp.size(), 0);
            } else {
                zmq_msg_close(&m);
            }
        }

        now = mono_ms();
        if (g_gps_fd < 0 && now >= next_gps_retry) {
            gps_connect();
            next_gps_retry = now + 2000;
        }
        if (now >= next_pub) {
            timing_tick();
            std::string snap = build_snapshot();
            zmq_send(pub, snap.data(), snap.size(), ZMQ_DONTWAIT);
            next_pub += PUB_PERIOD_MS;
            if (next_pub < now) next_pub = now + PUB_PERIOD_MS;  // catch up after a stall
        }
    }

    fprintf(stderr, "pluto_zmqd: shutting down\n");
    gps_drop();
    zmq_close(pub);
    zmq_close(rep);
    zmq_ctx_term(ctx);
    return 0;
}
