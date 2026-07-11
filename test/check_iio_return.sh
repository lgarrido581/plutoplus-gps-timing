#!/bin/sh
# check_iio_return.sh - CI guard for the libiio return-value contract that shipped
# broken in v2.0 (fixed in v2.0.1).
#
# The STRING attr writers return the BYTE COUNT on success (positive), negative on
# error -- NOT 0:
#     ssize_t iio_device_attr_write (dev, attr, "str");
#     ssize_t iio_channel_attr_write(chn, attr, "str");
# The v2.0 bug: `return iio_device_attr_write(...)` from a helper whose caller did
# `if (helper() != 0) fail(...)` -> every success read as failure.
# (The typed *_write_longlong / *_write_double variants DO return 0 on success, so
# they are exempt.)
#
# This flags two anti-patterns in services/*.c:
#   1. returning a bare string-writer result   (return iio_..._attr_write(...);)
#   2. comparing a bare string-writer to 0      (... == 0  /  ... != 0)
# The correct idiom is:  (iio_..._attr_write(...) < 0) ? -1 : 0   (or check `< 0`).
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
files="$here/../services"/*.c
fail=0

# strip _longlong/_double variants (which are 0-on-success) from consideration:
W='iio_\(device\|channel\)_attr_write[^_a-zA-Z]'

for f in $files; do
    [ -e "$f" ] || continue
    # 1) `return <string-writer>(...)` without a `< 0` normalization on the line
    if grep -nE "return[[:space:]]+iio_(device|channel)_attr_write[[:space:]]*\(" "$f" \
         | grep -vE '<[[:space:]]*0' ; then
        echo "  ^-- $f: returning a string-writer's byte-count as status (normalize: '... < 0 ? -1 : 0')"
        fail=1
    fi
    # 2) `<string-writer>(...) == 0` or `!= 0`
    if grep -nE "iio_(device|channel)_attr_write[[:space:]]*\([^;]*\)[[:space:]]*(==|!=)[[:space:]]*0" "$f"; then
        echo "  ^-- $f: comparing a string-writer's byte-count to 0 (use '< 0' for the error test)"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "FAIL: libiio string-writer return-value misuse (this is the v2.0 capture regression)."
    exit 1
fi
echo "check_iio_return: OK (no string-writer return-value misuse in services/)"
