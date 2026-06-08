#!/bin/bash
# =============================================================================
# Runs INSIDE the container. Do not invoke directly.
# Called by docker-run.sh via the container CMD.
# Base: sardylan/plutoplus fw-0.39 (sardylan/plutosdr-fw, plutoplus-fw-v0.39)
# GPS additions: PPS on MIO9, NMEA on UART1 (MIO12/13), gpsd + chrony
# =============================================================================
set -euo pipefail

REPO="https://github.com/sardylan/plutoplus"
BRANCH="fw-0.39"
SRC="/build/src"
PPS_MIO=9

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

# set_kcfg <kconfig-file> <SYMBOL> <full-line>
# Idempotently set a Kconfig symbol: drop any existing "SYM=..." or
# "# SYM is not set" line, then append the desired line. Survives the cached
# source tree (previous runs' appends don't accumulate duplicates).
set_kcfg() {
    local f="$1" sym="$2" line="$3"
    sed -i "/^${sym}=/d; /^# ${sym} is not set\$/d" "$f"
    echo "$line" >> "$f"
}

# ---- Check Vivado ----
# v0.39's plutosdr-fw Makefile expects Vivado 2023.2 (VIVADO_VERSION). Mount the
# host install at /opt/Xilinx via:  docker-run.sh --vivado /opt/Xilinx
# With Vivado present, the HDL is built from source -> system_top.bit -> boot.frm.
HAVE_VIVADO=0
# VIVADO_PATH is set by docker-run.sh (--vivado) and equals the host install path,
# mounted at the SAME path here so Vivado's settings64.sh (which hardcodes its
# absolute path) resolves its helper scripts. Default /opt/Xilinx for legacy use.
VIVADO_PATH="${VIVADO_PATH:-/opt/Xilinx}"
VIVADO_VERSION="${VIVADO_VERSION:-2023.2}"
VIVADO_SETTINGS="$VIVADO_PATH/Vivado/${VIVADO_VERSION}/settings64.sh"
if [ -f "$VIVADO_SETTINGS" ]; then
    source "$VIVADO_SETTINGS" &>/dev/null
    export VIVADO_VERSION VIVADO_SETTINGS          # Makefile honors these (?=)
    HAVE_VIVADO=1
    info "Vivado $VIVADO_VERSION found at $VIVADO_PATH — full build (HDL bitstream + boot.frm)"
else
    # Fall back to any installed Vivado under VIVADO_PATH.
    ALT=$(ls "$VIVADO_PATH"/Vivado/*/settings64.sh 2>/dev/null | head -1)
    if [ -n "$ALT" ]; then
        source "$ALT" &>/dev/null
        VIVADO_VERSION=$(basename "$(dirname "$ALT")")
        VIVADO_SETTINGS="$ALT"
        export VIVADO_VERSION VIVADO_SETTINGS
        HAVE_VIVADO=1
        warn "Using Vivado $VIVADO_VERSION at $VIVADO_PATH (v0.39 expects 2023.2) — may warn/fail if mismatched"
    else
        warn "No Vivado under $VIVADO_PATH/Vivado — building Linux + u-boot + rootfs only (no boot.frm)"
        warn "system_top.xsa will be downloaded from the v0.39 release automatically"
    fi
fi

# Vivado WebTalk fingerprints the host via libudev (udev_enumerate_scan_devices),
# which heap-corrupts and aborts inside a container. Disable WebTalk so the HDL
# build (write_bitstream) doesn't crash. Vivado reads ~/.Xilinx/Vivado/Vivado_init.tcl
# on every launch.
if (( HAVE_VIVADO )); then
    mkdir -p "$HOME/.Xilinx/Vivado"
    cat > "$HOME/.Xilinx/Vivado/Vivado_init.tcl" << 'TCLEOF'
catch { config_webtalk -install off }
catch { config_webtalk -user off }
TCLEOF
    info "  Vivado WebTalk disabled (avoids libudev crash in container)"
fi

# ---- Clone ----
# Check if an existing clone is actually the right repo; wipe and re-clone if not.
if [ -d "$SRC/.git" ]; then
    CACHED_REMOTE=$(git -C "$SRC" remote get-url origin 2>/dev/null || true)
    if echo "$CACHED_REMOTE" | grep -qi "sardylan/plutoplus"; then
        info "Source already present ($BRANCH), skipping clone"
    else
        warn "Cached clone is from a different repo ($CACHED_REMOTE), wiping and re-cloning..."
        # /build/src is a Docker named volume mount point — the directory itself
        # cannot be removed (it's busy/mounted). Clear its contents instead.
        find "$SRC" -mindepth 1 -delete 2>/dev/null || true
        info "Cloning $REPO ($BRANCH)..."
        git clone --branch "$BRANCH" "$REPO" "$SRC"
    fi
else
    info "Cloning $REPO ($BRANCH)..."
    git clone --branch "$BRANCH" "$REPO" "$SRC"
fi
cd "$SRC"

# Absolute path to patches dir (sardylan's patches live here)
PATCHES_DIR="$(pwd)/patches"

info "Initializing submodules..."
git submodule update --init --depth=1 plutosdr-fw
cd plutosdr-fw
git submodule update --init --depth=1 u-boot-xlnx buildroot

# Linux kernel — manual shallow fetch to avoid WSL memory crash on full clone
git submodule init linux
LINUX_URL=$(git config submodule.linux.url)
LINUX_COMMIT=$(git ls-files -s linux | awk '{print $2}')
if [ ! -f linux/Makefile ]; then
    info "Fetching Linux kernel (shallow, commit only)..."
    [ -d linux ] && rm -rf linux
    mkdir linux && cd linux
    git init -q
    git remote add origin "$LINUX_URL"
    git fetch --depth=1 --progress origin "$LINUX_COMMIT"
    git checkout FETCH_HEAD
    cd ..
fi

# Shallow clone has no tags → git describe → SUBLEVEL gets garbage → expr fails
# → LINUX_VERSION_CODE empty → hundreds of compile errors.
# Lock SUBLEVEL=0 and silence scm version queries.
sed -i 's/^SUBLEVEL\s*=.*/SUBLEVEL = 0/' linux/Makefile
echo "" > linux/.scmversion

(( HAVE_VIVADO )) && git submodule update --init --depth=1 hdl

# ---- Apply sardylan patches ----
# apply_patch <subdir-inside-plutosdr-fw> <patch-filename>
# Uses absolute PATCHES_DIR so "." (plutosdr-fw root) works correctly.
info "Applying sardylan patches..."
apply_patch() {
    local dir="$1" patch="$PATCHES_DIR/$2"
    if [ ! -f "$patch" ]; then
        warn "  $2 not found, skipping"
        return 0
    fi
    (cd "$dir" && git apply --check "$patch" &>/dev/null \
        && git apply "$patch" && info "  $2 applied" \
        || warn "  $2 skipped (already applied or conflict)")
}

apply_patch "."           fw.diff
apply_patch "linux"       linux.diff
apply_patch "buildroot"   buildroot.diff
apply_patch "u-boot-xlnx" u-boot-xlnx.diff
(( HAVE_VIVADO )) && apply_patch "hdl" hdl.diff

# ---- GPS / PPS additions (on top of sardylan base) ----
info "Applying GPS/PPS changes..."

DEFCONFIG="linux/arch/arm/configs/zynq_pluto_defconfig"

# Remove UART1 debug console (sardylan enables uart1 for normal use in linux.diff;
# we just need to ensure the early debug console config is gone so the port is free)
sed -i '/^CONFIG_DEBUG_LL=y$/d'         "$DEFCONFIG"
sed -i '/^CONFIG_DEBUG_ZYNQ_UART1=y$/d' "$DEFCONFIG"
sed -i '/^CONFIG_EARLY_PRINTK=y$/d'     "$DEFCONFIG"

# Add PPS subsystem + GPIO PPS client (if not already present)
grep -q "CONFIG_PPS=y" "$DEFCONFIG" || cat >> "$DEFCONFIG" << 'EOF'

# GPS PPS timing
CONFIG_PPS=y
CONFIG_PPS_CLIENT_GPIO=y
EOF
info "  defconfig: UART1 debug removed, PPS enabled"

# Add pps-gpio DTS node to RevC DTS (sardylan's linux.diff modifies this file
# but only adds Ethernet/USB — no conflict with our appended node)
DTS="linux/arch/arm/boot/dts/zynq-pluto-sdr-revc.dts"
if ! grep -q "pps-gpio" "$DTS"; then
    cat >> "$DTS" << EOF

/ {
	pps {
		compatible = "pps-gpio";
		pinctrl-names = "default";
		pinctrl-0 = <&pinctrl_gpio0_default>;
		gpios = <&gpio0 ${PPS_MIO} 0>;
	};
};
EOF
    info "  DTS: pps-gpio node on MIO${PPS_MIO}"
fi

# U-boot: remove console=ttyPS1 so UART1 is free for GPS NMEA
# (sardylan's u-boot-xlnx.diff does not touch UART settings)
for f in \
    u-boot-xlnx/include/configs/zynq-common.h \
    u-boot-xlnx/configs/zynq_pluto_defconfig; do
    [ -f "$f" ] && grep -q "console=ttyPS1" "$f" \
        && sed -i 's/console=ttyPS1,[^ "]*//g' "$f" \
        && info "  u-boot: removed console=ttyPS1 from $(basename $f)"
done

# Buildroot: use sardylan's BR2_TOOLCHAIN_EXTERNAL_LINARO_ARM=y as-is.
# DO NOT switch to CUSTOM — Buildroot's LINARO_ARM downloads and installs its
# own Linaro ARM toolchain with correct sysroot layout, prefix, and glibc config.
# Switching to CUSTOM causes sysroot symlink failures in Buildroot 2020.02.
#
# Previous versions of this script appended CUSTOM toolchain settings to the
# defconfig. They are NOT part of any patch (patches say "already applied" and
# skip), so they survive across runs. Explicitly scrub them so LINARO_ARM wins.
BR_CFG=""
for c in buildroot/configs/zynq_pluto_defconfig buildroot/configs/pluto_defconfig; do
    [ -f "$c" ] && BR_CFG="$c" && break
done
if [ -n "$BR_CFG" ]; then
    # --- Scrub any CUSTOM toolchain lines our old scripts may have appended ---
    for sym in \
        BR2_TOOLCHAIN_EXTERNAL_CUSTOM \
        BR2_TOOLCHAIN_EXTERNAL_PATH \
        BR2_TOOLCHAIN_EXTERNAL_PREFIX \
        BR2_TOOLCHAIN_EXTERNAL_CUSTOM_GLIBC \
        BR2_TOOLCHAIN_EXTERNAL_CUSTOM_UCLIBC \
        BR2_TOOLCHAIN_EXTERNAL_CUSTOM_MUSL \
        BR2_TOOLCHAIN_EXTERNAL_HAS_THREADS \
        BR2_TOOLCHAIN_EXTERNAL_HAS_THREADS_DEBUG \
        BR2_TOOLCHAIN_EXTERNAL_HAS_SSP \
        BR2_TOOLCHAIN_EXTERNAL_HAS_NATIVE_RPC \
        BR2_TOOLCHAIN_EXTERNAL_WCHAR \
        BR2_TOOLCHAIN_EXTERNAL_INET_RPC; do
        sed -i "/^${sym}[=]/d" "$BR_CFG"
    done
    info "  buildroot: scrubbed old CUSTOM toolchain settings (keeping LINARO_ARM)"

    # Wipe stale buildroot/output if the toolchain wasn't fully installed last
    # time. Earlier runs (CUSTOM toolchain attempts) left a DANGLING sysroot
    # symlink at output/host/<tuple>/sysroot. The external-toolchain staging
    # install then fails with:
    #   ln: failed to create symbolic link '.../sysroot/usr/lib': No such file
    # because mkdir -p can't traverse the dangling symlink. The toolchain
    # tarball lives in buildroot/dl/ (NOT under output/), so wiping output does
    # NOT trigger a re-download — only a re-extract/rebuild of the toolchain.
    TC_STAMP=$(find buildroot/output/build -maxdepth 2 \
        -name '.stamp_staging_installed' -path '*toolchain-external*' 2>/dev/null | head -1)
    if [ -d buildroot/output ] && [ -z "$TC_STAMP" ]; then
        warn "  Wiping stale/partial buildroot/output (toolchain not fully installed; dl/ cache kept)..."
        rm -rf buildroot/output
    fi

    # Drop a bogus symbol an earlier script appended (not a real Kconfig option)
    sed -i '/^BR2_PACKAGE_GPSD_NMEA=/d' "$BR_CFG"

    # --- GPS timing packages + config (idempotent via set_kcfg) ---
    # gpsd on the REAL uart: UART1 (MIO12/13) enumerates as /dev/ttyPS0 because
    # UART0 is disabled and UART1 owns the serial0 alias. Stock default is
    # /dev/ttyS1 (does not exist) so gpsd read nothing.
    set_kcfg "$BR_CFG" BR2_PACKAGE_GPSD         'BR2_PACKAGE_GPSD=y'
    set_kcfg "$BR_CFG" BR2_PACKAGE_GPSD_DEVICES 'BR2_PACKAGE_GPSD_DEVICES="/dev/ttyPS0"'
    # chrony for GPS-disciplined time.
    set_kcfg "$BR_CFG" BR2_PACKAGE_CHRONY       'BR2_PACKAGE_CHRONY=y'
    # pps-tools provides <sys/timepps.h> so chrony/gpsd COMPILE the PPS refclock
    # (else chrony errors "refclock driver PPS is not compiled in"). buildroot
    # auto-orders pps-tools before chrony/gpsd. Also installs 'ppstest'.
    set_kcfg "$BR_CFG" BR2_PACKAGE_PPS_TOOLS    'BR2_PACKAGE_PPS_TOOLS=y'
    # ncurses -> gpsd also builds its curses clients (gpsmon, cgps) for a live
    # satellite/SNR/fix dashboard. gpsd auto-detects ncurses via pkg-config.
    set_kcfg "$BR_CFG" BR2_PACKAGE_NCURSES      'BR2_PACKAGE_NCURSES=y'
    # Free UART1 for GPS: drop the login getty buildroot puts on ttyPS0 (it
    # competes with gpsd for the NMEA bytes). USB console (ttyGS0) is unaffected.
    set_kcfg "$BR_CFG" BR2_TARGET_GENERIC_GETTY_PORT 'BR2_TARGET_GENERIC_GETTY_PORT=""'
    # Dedicated rootfs overlay for chrony.conf (stock sets BR2_ROOTFS_OVERLAY=""
    # so files dropped elsewhere never reach the image).
    set_kcfg "$BR_CFG" BR2_ROOTFS_OVERLAY       'BR2_ROOTFS_OVERLAY="board/pluto/gps-overlay"'
    # Append our post-build script (keep sardylan's). GETTY_PORT="" only blanks
    # the getty line into a malformed respawn stub; this script DELETES it.
    set_kcfg "$BR_CFG" BR2_ROOTFS_POST_BUILD_SCRIPT \
        'BR2_ROOTFS_POST_BUILD_SCRIPT="board/pluto/post-build.sh board/pluto/gps-post-build.sh"'

    info "  buildroot: gpsd->/dev/ttyPS0, chrony+pps-tools, getty removed, overlay set"
fi

# Rootfs overlay (dedicated dir, wired via BR2_ROOTFS_OVERLAY above).
# chrony.conf: GPS coarse time via gpsd shared memory + precise PPS via /dev/pps0.
GPS_OVL="buildroot/board/pluto/gps-overlay"
mkdir -p "$GPS_OVL/etc" "$GPS_OVL/var/lib/chrony"
cat > "$GPS_OVL/etc/chrony.conf" << 'EOF'
# GPS NMEA gives coarse time (via gpsd SHM 0); PPS gives precision.
refclock SHM 0 refid GPS precision 1e-1 offset 0.0 delay 0.2 noselect
refclock PPS /dev/pps0 refid PPS lock GPS prefer
makestep 1 3
rtcsync
driftfile /var/lib/chrony/drift

# Serve NTP to the local network. This device becomes a stratum-1, GPS-backed
# NTP server once it holds a PPS lock (it will NOT serve bad time before lock).
# Adjust/remove these subnets for your network.
allow 192.168.0.0/16
allow 10.0.0.0/8
allow 172.16.0.0/12
# IPv6 link-local — clients reaching the Pluto over its eth0/usb0 fe80:: address
# (without this, NTP queries that resolve to the IPv6 address are silently dropped).
allow fe80::/10
EOF
info "  rootfs overlay: $GPS_OVL/etc/chrony.conf written"

# Custom gpsd init. The stock S50gpsd runs gpsd with no options, so it can't lock
# the GPS baud (9600) while the kernel leaves ttyPS0 at the console's 115200
# (-> garbage), and without -n gpsd won't poll continuously to feed chrony SHM.
# Ours: force 9600, then gpsd -n (continuous poll) -b (readonly; safe sharing the
# port with the kernel console). Overlay overwrites the package-installed copy.
mkdir -p "$GPS_OVL/etc/init.d"
cat > "$GPS_OVL/etc/init.d/S50gpsd" << 'EOF'
#!/bin/sh
NAME=gpsd
DAEMON=/usr/sbin/$NAME
DEVICES="/dev/ttyPS0"
PIDFILE=/var/run/$NAME.pid
start() {
	printf "Starting $NAME: "
	stty -F $DEVICES 9600 raw -echo clocal 2>/dev/null
	start-stop-daemon -S -q -p $PIDFILE --exec $DAEMON -- -n -b -P $PIDFILE $DEVICES && echo "OK" || echo "Failed"
}
stop() {
	printf "Stopping $NAME: "
	start-stop-daemon -K -q -p $PIDFILE && echo "OK" || echo "Failed"
	rm -f $PIDFILE
}
case "$1" in
	start) start ;;
	stop) stop ;;
	restart|reload) stop; start ;;
	*) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
exit $?
EOF
chmod +x "$GPS_OVL/etc/init.d/S50gpsd"
info "  rootfs overlay: custom S50gpsd (force 9600 + gpsd -n -b) written"

# Keep U-Boot from aborting autoboot when the GPS streams NMEA into the console
# UART (UART1 = MIO13). We can't rebuild U-Boot (no Vivado/boot.frm), but it
# reads bootdelay from the QSPI env, which fw_setenv can change from Linux.
# bootdelay=-2 -> boot immediately, ignore console input. Idempotent self-heal.
# NOTE: applies from the NEXT boot; the first boot on a fresh env must have GPS
# TX (MIO13) disconnected so the device can boot far enough to run this.
cat > "$GPS_OVL/etc/init.d/S30bootdelay" << 'EOF'
#!/bin/sh
case "$1" in
	start)
		command -v fw_setenv >/dev/null 2>&1 || exit 0
		cur=$(fw_printenv bootdelay 2>/dev/null | sed -n 's/^bootdelay=//p')
		if [ "$cur" != "-2" ]; then
			# value -2 starts with '-', so use script mode (fw_setenv would
			# otherwise parse it as an option flag).
			printf 'bootdelay -2\n' > /tmp/.bd.$$ \
				&& fw_setenv -s /tmp/.bd.$$ 2>/dev/null \
				&& echo "u-boot bootdelay -> -2 (GPS-safe autoboot)"
			rm -f /tmp/.bd.$$
		fi
		;;
esac
exit 0
EOF
chmod +x "$GPS_OVL/etc/init.d/S30bootdelay"
info "  rootfs overlay: S30bootdelay (sets u-boot bootdelay=-2) written"

# Post-build script: delete buildroot's generic serial getty from inittab so the
# GPS UART (ttyPS0) has no login console competing with gpsd. Runs AFTER the
# getty finalize hook. USB console (ttyGS0) is left intact.
cat > buildroot/board/pluto/gps-post-build.sh << 'EOF'
#!/bin/sh
INITTAB="$1/etc/inittab"
[ -f "$INITTAB" ] && sed -i '/# GENERIC_SERIAL$/d' "$INITTAB"
exit 0
EOF
chmod +x buildroot/board/pluto/gps-post-build.sh
info "  post-build: gps-post-build.sh created (removes serial getty)"

# Force chrony + gpsd to rebuild so they pick up PPS support (via new pps-tools)
# and the corrected gpsd device. buildroot does NOT auto-rebuild packages on a
# .config change alone, so removing their build dirs forces a clean rebuild.
# (pps-tools is a new package and builds automatically; the getty/overlay are
# applied by target-finalize on every make.)
if [ -d buildroot/output/build ]; then
    rm -rf buildroot/output/build/chrony-* buildroot/output/build/gpsd-* 2>/dev/null || true
    info "  forced chrony + gpsd rebuild (PPS support + /dev/ttyPS0 + overlay)"
fi

# ---- Fix VERSION and LATEST_TAG (both use git describe; fail on shallow clone) ----
# sardylan's Makefile has two variables:
#   VERSION     = $(shell git describe --abbrev=4 --dirty --always --tags)
#   LATEST_TAG  = $(shell git describe --abbrev=0 --tags)
# Both fall back to v0.39 so the XSA download URL resolves correctly.
info "Patching plutosdr-fw Makefile for shallow-clone version fallback..."
python3 - << 'PYEOF'
import re, sys
with open('Makefile', 'r') as f:
    content = f.read()
patched = re.sub(
    r'\$\(shell git describe[^)]*\)',
    '$(shell git describe 2>/dev/null || echo v0.39)',
    content
)
n = len(re.findall(r'\$\(shell git describe', content))
if patched == content:
    if '2>/dev/null || echo v0.39' in content:
        print("  Makefile already patched (v0.39 fallback present)")
    else:
        print("  WARNING: no git describe found in Makefile — version fallback NOT applied", file=sys.stderr)
else:
    with open('Makefile', 'w') as f:
        f.write(patched)
    print(f"  Makefile patched ({n} git describe call(s) → v0.39 fallback)")
PYEOF

# ---- Build ----
info "Starting build ($(nproc) cores)..."
make -j$(nproc) 2>&1 | tee /build/output/build.log
BUILD_EXIT=${PIPESTATUS[0]}

# Copy firmware to output volume (always run, even if make partially failed)
cp build/pluto.frm  /build/output/ 2>/dev/null && info "  pluto.frm -> /build/output/" || true
cp build/boot.frm   /build/output/ 2>/dev/null && info "  boot.frm  -> /build/output/" || true
cp build/pluto.dfu  /build/output/ 2>/dev/null || true
cp build/boot.dfu   /build/output/ 2>/dev/null || true
cp build/*.zip      /build/output/ 2>/dev/null || true

[ $BUILD_EXIT -ne 0 ] && die "Build failed with exit code $BUILD_EXIT" || true

info "=================================================="
info "Done. Firmware in /build/output (mapped to ./output on host)"
info "To flash: copy pluto.frm to the PlutoSDR USB drive"
info "=================================================="
