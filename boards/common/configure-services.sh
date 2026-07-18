#!/bin/sh
set -eu
CFG="$1"

set_kcfg() {
    sed -i "/^$2=/d; /^# $2 is not set$/d" "$1"
    printf '%s\n' "$3" >> "$1"
}

register_package() {
    line="source \"package/$1/Config.in\""
    grep -Fqx "$line" buildroot/package/Config.in || printf '%s\n' "$line" >> buildroot/package/Config.in
}

Z=buildroot/package/pluto-zmqd
mkdir -p "$Z"
cp /build/services-src/pluto_zmqd.cpp "$Z/"
cp /build/services-src/S65zmqapi "$Z/"
printf '%s' "${GPS_TIMING_VERSION:-unknown}" > "$Z/FW_VERSION"
cat > "$Z/Config.in" <<'EOF'
config BR2_PACKAGE_PLUTO_ZMQD
	bool "pluto-zmqd"
	depends on BR2_INSTALL_LIBSTDCPP
	depends on BR2_TOOLCHAIN_HAS_THREADS
	select BR2_PACKAGE_ZEROMQ
EOF
cat > "$Z/pluto-zmqd.mk" <<'EOF'
PLUTO_ZMQD_VERSION = 1.0
PLUTO_ZMQD_SITE = $(TOPDIR)/package/pluto-zmqd
PLUTO_ZMQD_SITE_METHOD = local
PLUTO_ZMQD_DEPENDENCIES = zeromq
define PLUTO_ZMQD_BUILD_CMDS
	$(TARGET_CXX) $(TARGET_CXXFLAGS) -std=c++11 -O2 -pthread -DGPS_TIMING_VERSION='"$(shell cat $(PLUTO_ZMQD_SITE)/FW_VERSION)"' -o $(@D)/pluto_zmqd $(@D)/pluto_zmqd.cpp -lzmq
endef
define PLUTO_ZMQD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/pluto_zmqd $(TARGET_DIR)/usr/bin/pluto_zmqd
	$(INSTALL) -D -m 0755 $(@D)/S65zmqapi $(TARGET_DIR)/etc/init.d/S65zmqapi
endef
$(eval $(generic-package))
EOF
register_package pluto-zmqd

C=buildroot/package/pluto-ctld
mkdir -p "$C"
for f in pluto_ctld.cpp capture_core.c capture_core.h pps_timestamp.c pps_timestamp.h S66ctld; do
    cp "/build/services-src/$f" "$C/"
done
cat > "$C/Config.in" <<'EOF'
config BR2_PACKAGE_PLUTO_CTLD
	bool "pluto-ctld"
	depends on BR2_INSTALL_LIBSTDCPP
	depends on BR2_TOOLCHAIN_HAS_THREADS
	select BR2_PACKAGE_ZEROMQ
	select BR2_PACKAGE_LIBIIO
EOF
cat > "$C/pluto-ctld.mk" <<'EOF'
PLUTO_CTLD_VERSION = 1.0
PLUTO_CTLD_SITE = $(TOPDIR)/package/pluto-ctld
PLUTO_CTLD_SITE_METHOD = local
PLUTO_CTLD_DEPENDENCIES = zeromq libiio
define PLUTO_CTLD_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -std=gnu11 -O2 -I$(@D) -c $(@D)/pps_timestamp.c -o $(@D)/pps_timestamp.o
	$(TARGET_CC) $(TARGET_CFLAGS) -std=gnu11 -O2 -I$(@D) -c $(@D)/capture_core.c -o $(@D)/capture_core.o
	$(TARGET_CXX) $(TARGET_CXXFLAGS) -std=c++11 -O2 -I$(@D) -c $(@D)/pluto_ctld.cpp -o $(@D)/pluto_ctld.o
	$(TARGET_CXX) $(TARGET_CXXFLAGS) -o $(@D)/pluto_ctld $(@D)/pluto_ctld.o $(@D)/capture_core.o $(@D)/pps_timestamp.o -lzmq -liio
endef
define PLUTO_CTLD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/pluto_ctld $(TARGET_DIR)/usr/bin/pluto_ctld
	$(INSTALL) -D -m 0755 $(@D)/S66ctld $(TARGET_DIR)/etc/init.d/S66ctld
endef
$(eval $(generic-package))
EOF
register_package pluto-ctld

set_kcfg "$CFG" BR2_INSTALL_LIBSTDCPP 'BR2_INSTALL_LIBSTDCPP=y'
set_kcfg "$CFG" BR2_PACKAGE_ZEROMQ 'BR2_PACKAGE_ZEROMQ=y'
set_kcfg "$CFG" BR2_PACKAGE_LIBIIO 'BR2_PACKAGE_LIBIIO=y'
set_kcfg "$CFG" BR2_PACKAGE_PLUTO_ZMQD 'BR2_PACKAGE_PLUTO_ZMQD=y'
set_kcfg "$CFG" BR2_PACKAGE_PLUTO_CTLD 'BR2_PACKAGE_PLUTO_CTLD=y'
