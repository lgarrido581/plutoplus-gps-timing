#!/bin/sh
# Configure common GPS timing packages in an already-prepared Pluto-style tree.
set -eu

: "${GPS_UART:?}"
: "${BOARD_NAME:?}"
: "${BR_CONFIG:?}"
: "${ROOTFS_BOARD_DIR:?}"

set_kcfg() {
    file="$1"; sym="$2"; value="$3"
    sed -i "/^${sym}=/d; /^# ${sym} is not set$/d" "$file"
    printf '%s\n' "$value" >> "$file"
}

set_kcfg "$BR_CONFIG" BR2_PACKAGE_GPSD 'BR2_PACKAGE_GPSD=y'
set_kcfg "$BR_CONFIG" BR2_PACKAGE_GPSD_DEVICES "BR2_PACKAGE_GPSD_DEVICES=\"$GPS_UART\""
set_kcfg "$BR_CONFIG" BR2_PACKAGE_CHRONY 'BR2_PACKAGE_CHRONY=y'
set_kcfg "$BR_CONFIG" BR2_PACKAGE_PPS_TOOLS 'BR2_PACKAGE_PPS_TOOLS=y'
set_kcfg "$BR_CONFIG" BR2_PACKAGE_NCURSES 'BR2_PACKAGE_NCURSES=y'
set_kcfg "$BR_CONFIG" BR2_INSTALL_LIBSTDCPP 'BR2_INSTALL_LIBSTDCPP=y'
set_kcfg "$BR_CONFIG" BR2_PACKAGE_ZEROMQ 'BR2_PACKAGE_ZEROMQ=y'
set_kcfg "$BR_CONFIG" BR2_PACKAGE_LIBIIO 'BR2_PACKAGE_LIBIIO=y'
set_kcfg "$BR_CONFIG" BR2_TARGET_GENERIC_GETTY_PORT 'BR2_TARGET_GENERIC_GETTY_PORT=""'

OVERLAY="$ROOTFS_BOARD_DIR/gps-overlay"
POST="$ROOTFS_BOARD_DIR/gps-post-build.sh"
BR_OVERLAY="${OVERLAY#buildroot/}"
BR_POST="${POST#buildroot/}"
BR_BASE_POST="${ROOTFS_BOARD_DIR#buildroot/}/post-build.sh"
set_kcfg "$BR_CONFIG" BR2_ROOTFS_OVERLAY "BR2_ROOTFS_OVERLAY=\"$BR_OVERLAY\""
set_kcfg "$BR_CONFIG" BR2_ROOTFS_POST_BUILD_SCRIPT \
    "BR2_ROOTFS_POST_BUILD_SCRIPT=\"$BR_BASE_POST $BR_POST\""

mkdir -p "$OVERLAY/etc/init.d" "$OVERLAY/var/lib/chrony" "$OVERLAY/usr/bin"

cat > "$OVERLAY/etc/chrony.conf" <<'EOF'
refclock SHM 0 refid GPS precision 1e-1 offset 0.0 delay 0.2 noselect
refclock PPS /dev/pps0 refid PPS lock GPS prefer
makestep 1 3
rtcsync
driftfile /var/lib/chrony/drift
allow 192.168.0.0/16
allow 10.0.0.0/8
allow 172.16.0.0/12
allow fe80::/10
EOF

cat > "$OVERLAY/etc/init.d/S50gpsd" <<EOF
#!/bin/sh
DAEMON=/usr/sbin/gpsd
DEVICES="$GPS_UART"
PIDFILE=/var/run/gpsd.pid
case "\$1" in
 start)
  stty -F \$DEVICES 9600 raw -echo clocal 2>/dev/null
  start-stop-daemon -S -q -p \$PIDFILE --exec \$DAEMON -- -n -b -P \$PIDFILE \$DEVICES
  ;;
 stop) start-stop-daemon -K -q -p \$PIDFILE; rm -f \$PIDFILE ;;
 restart) "\$0" stop; "\$0" start ;;
 *) echo "Usage: \$0 {start|stop|restart}"; exit 1 ;;
esac
EOF
chmod +x "$OVERLAY/etc/init.d/S50gpsd"

cp /build/hdl-src/pps_counter/xo_correct.sh "$OVERLAY/usr/bin/xo_correct.sh"
chmod +x "$OVERLAY/usr/bin/xo_correct.sh"
cat > "$OVERLAY/etc/init.d/S70xocorrect" <<'EOF'
#!/bin/sh
PIDFILE=/var/run/xocorrect.pid
case "$1" in
 start)
  (
   while :; do
    [ "$(devmem 0x7C460008 32 2>/dev/null)" = "0x00000001" ] &&
      chronyc tracking 2>/dev/null | grep -q 'Leap status *: *Normal' && break
    sleep 5
   done
   exec sh /usr/bin/xo_correct.sh >>/var/log/xocorrect.log 2>&1
  ) &
  echo $! > "$PIDFILE"
  ;;
 stop) [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE" ;;
 restart) "$0" stop; "$0" start ;;
esac
EOF
chmod +x "$OVERLAY/etc/init.d/S70xocorrect"

cat > "$OVERLAY/etc/gps-timing-board" <<EOF
BOARD=$BOARD_NAME
GPS_UART=$GPS_UART
PPS_GPIO=71
PPS_COUNTER_BASE=0x7C460000
AXI_TDD_BASE=0x7C440000
EOF

# LibreSDR's stock sequence binds the composite gadget in S23udc, then attaches
# the mass-storage backing file in S45msd. Windows can leave the UDC detached
# after that live LUN change. Binding once after S45 makes RNDIS/ACM/MSD/IIO
# enumerate reliably while leaving the upstream Pluto+ sequence untouched.
if [ "$BOARD_NAME" = "libresdr" ]; then
install -m 0755 /build/boards-src/libresdr/verify_lvds.sh \
    "$OVERLAY/usr/bin/verify_lvds.sh"

# LibreSDR's upstream S40network writes only a DHCP start address. BusyBox
# udhcpd requires both start and end, otherwise it exits immediately.
sed -i '/echo "start \$IPADDR_HOST" > \$UDHCPD_CONF/a echo "end $IPADDR_HOST" >> $UDHCPD_CONF' \
    "$ROOTFS_BOARD_DIR/S40network"

# Do not expose a half-configured composite gadget. Upstream binds the UDC in
# S23, before S45 attaches the mass-storage backing file; Windows detaches when
# that live LUN changes. S46 performs the first (and only) bind after S45.
sed -i 's|^[[:space:]]*echo ci_hdrc\.0 > \$GADGET/UDC$|# Deferred to S46udc-bind on LibreSDR|' \
    "$ROOTFS_BOARD_DIR/S23udc"

# Keep IIOD robust if an older/single-core QSPI environment is still installed.
# The preferred LibreSDR environment sets `maxcpus=2`, matching the Zynq-7020,
# but a temporary regression to `maxcpus=1` made the inherited Pluto
# `taskset -c 1` fail and left FunctionFS IIO unready.
sed -i 's|taskset -c 1 /usr/sbin/iiod|taskset -c 0 /usr/sbin/iiod|' \
    "$ROOTFS_BOARD_DIR/S23udc"

cat > "$OVERLAY/etc/init.d/S46udc-bind" <<'EOF'
#!/bin/sh
G=/sys/kernel/config/usb_gadget/composite_gadget
case "$1" in
 start)
  [ -e "$G/UDC" ] || exit 0
  [ -n "$(cat "$G/UDC")" ] || echo ci_hdrc.0 > "$G/UDC"
  # S40/S41 have already configured usb0 and started udhcpd. Cycling the
  # network after Windows has begun enumerating the composite gadget creates a
  # needless RNDIS link flap, so only ensure the interface is up here.
  ifup usb0 2>/dev/null || true
  ;;
esac
EOF
chmod +x "$OVERLAY/etc/init.d/S46udc-bind"
fi

cat > "$POST" <<EOF
#!/bin/sh
INITTAB="\$1/etc/inittab"
# Pluto+ uses ttyPS0 for GPS, so its stock serial getty competes with gpsd.
# LibreSDR uses the independent AXI UART Lite ttyUL0; retain the USB serial
# console so early userspace failures remain diagnosable.
if [ "$GPS_UART" = "/dev/ttyPS0" ] && [ -f "\$INITTAB" ]; then
    sed -i '/# GENERIC_SERIAL$/d' "\$INITTAB"
fi
if [ "$GPS_UART" = "/dev/ttyUL0" ] && [ -f "\$INITTAB" ] &&
   ! grep -q '^ttyPS0:' "\$INITTAB"; then
    echo 'ttyPS0::respawn:/sbin/getty -L ttyPS0 115200 vt100 # Debug console' >> "\$INITTAB"
fi
exit 0
EOF
chmod +x "$POST"

# Add the two existing service daemons as local Buildroot packages.
sh /build/boards-src/common/configure-services.sh "$BR_CONFIG"

rm -rf buildroot/output/build/chrony-* buildroot/output/build/gpsd-* \
       buildroot/output/build/pluto-zmqd-* buildroot/output/build/pluto-ctld-* 2>/dev/null || true
