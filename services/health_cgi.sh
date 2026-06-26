#!/bin/sh
# Pluto read-only /health CGI for busybox httpd -- the server side of the DSN
# health contract (DistributedSensingNetwork docs/HEALTH_API.md, schema
# "dsn.health/1"). Lets the sensing app read timing + GPS over HTTP on the private
# hardware LAN, with NO root SSH / devmem on the consumer side.
#
# Aggregates three sources already on the radio (no extra deps):
#   * pps_counter regs via devmem  -> pps_present, pps_seq, cnt_clk (delta)
#   * /var/log/xocorrect.log       -> xo_ppm (the daemon AUTO-DERIVES nominal from the
#                                      live rate x mode, so this is correct in any mode)
#   * gpsd via gpspipe             -> lat/lon/alt_hae + fix/sats/velocity
#
# Served by S60healthd as  GET /cgi-bin/health  (httpd bound to the hw-LAN IP only).
set -u

STATUS=0x7C460008; DELTA=0x7C460014; SEQ=0x7C460018
XLOG=/var/log/xocorrect.log
SEQCACHE=/tmp/.health_seq          # for liveness without an in-request sleep

# --- timing (pps_counter) ---------------------------------------------------
st=$(devmem $STATUS 32 2>/dev/null); st=${st:-0}
pps_present=false; [ "$(( st & 1 ))" = "1" ] && pps_present=true
seq=$(( $(devmem $SEQ 32 2>/dev/null) + 0 ))
delta=$(( $(devmem $DELTA 32 2>/dev/null) + 0 ))

# liveness: PPS_SEQ must advance between two polls. We cache (seq, ts) so a single
# request never has to sleep ~1 s -- the orchestrator polls every cycle, so by the
# 2nd poll this resolves to true/false (null until then).
now=$(date +%s); pps_adv=null
if [ -f "$SEQCACHE" ]; then
    read pseq pts _ < "$SEQCACHE" 2>/dev/null || { pseq=""; pts=0; }
    if [ -n "$pseq" ] && [ "$(( now - pts ))" -ge 1 ] && [ "$(( now - pts ))" -le 30 ]; then
        if [ "$seq" -gt "$pseq" ]; then pps_adv=true; else pps_adv=false; fi
    fi
fi
echo "$seq $now" > "$SEQCACHE" 2>/dev/null

# xo_ppm: last value the xocorrect daemon logged, e.g. "... (+0.000ppm) ...".
# JSON has no leading '+', so strip it.
xo_ppm=null
if [ -f "$XLOG" ]; then
    p=$(tail -1 "$XLOG" 2>/dev/null | grep -oE '[+-][0-9]+\.[0-9]+ppm' | head -1 \
        | sed 's/ppm//; s/^+//')
    [ -n "$p" ] && xo_ppm="$p"
fi

# --- gps (gpsd via gpspipe; -x bounds the run, busybox has no `timeout`) -----
g=$(gpspipe -w -x 2 2>/dev/null)
tpv=$(echo "$g" | grep -m1 '"class":"TPV"')
sky=$(echo "$g" | grep '"class":"SKY"' | tail -1)
jget() { echo "$1" | grep -oE "\"$2\":-?[0-9.]+" | head -1 | cut -d: -f2; }

gps=""
add() { [ -n "$2" ] && gps="${gps}${gps:+,}\"$1\":$2"; }
add mode        "$(jget "$tpv" mode)"
add lat_deg     "$(jget "$tpv" lat)"
add lon_deg     "$(jget "$tpv" lon)"
add alt_hae_m   "$(jget "$tpv" altHAE)"
add alt_msl_m   "$(jget "$tpv" altMSL)"
add geoid_sep_m "$(jget "$tpv" geoidSep)"
add eph_m       "$(jget "$tpv" eph)"
add epv_m       "$(jget "$tpv" epv)"
add n_sat_used  "$(jget "$sky" uSat)"
add speed_mps   "$(jget "$tpv" speed)"
add track_deg   "$(jget "$tpv" track)"
add climb_mps   "$(jget "$tpv" climb)"

# --- emit (CGI: headers, blank line, JSON body) ----------------------------
printf 'Content-type: application/json\r\n\r\n'
printf '{"schema":"dsn.health/1","node_id":"%s","t_unix":%s,"uptime_s":%s,' \
    "$(hostname)" "$now" "$(cut -d. -f1 /proc/uptime 2>/dev/null)"
printf '"timing":{"pps_present":%s,"pps_advancing":%s,"pps_seq":%s,"xo_ppm":%s,"cnt_clk_hz":%s},' \
    "$pps_present" "$pps_adv" "$seq" "$xo_ppm" "$delta"
printf '"gps":{%s}}\n' "$gps"
