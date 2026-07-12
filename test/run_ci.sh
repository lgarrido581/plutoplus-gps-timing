#!/bin/sh
# run_ci.sh - hardware-free checks that gate every PR (see .github/workflows/ci.yml).
# These catch build/lint/contract regressions; the RUNTIME, per-board catch is
# tools/smoke_test.py (see RELEASING.md). Exits non-zero on the first failure.
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root" || exit 1
rc=0
step() { printf '\n=== %s ===\n' "$1"; }
bad()  { echo "FAIL: $1"; rc=1; }

step "shell syntax (sh -n)"
for f in $(git ls-files '*.sh'); do sh -n "$f" || bad "sh -n $f"; done
command -v shellcheck >/dev/null 2>&1 && \
    { shellcheck -S warning $(git ls-files '*.sh') || bad "shellcheck"; } || \
    echo "  (shellcheck not installed -- skipped)"

step "libiio return-value contract"
sh test/check_iio_return.sh || bad "check_iio_return"

step "C services: -Wall -Wextra -Werror + cppcheck"
if command -v gcc >/dev/null 2>&1; then
    for c in $(git ls-files 'services/*.c'); do
        gcc -std=c11 -D_POSIX_C_SOURCE=199309L -Wall -Wextra -Werror \
            -Iservices -c "$c" -o /dev/null 2>/tmp/gccout || { cat /tmp/gccout; bad "gcc $c"; }
    done
else echo "  (gcc not installed -- skipped)"; fi
command -v cppcheck >/dev/null 2>&1 && \
    { cppcheck --error-exitcode=1 --enable=warning --std=c11 -Iservices \
        $(git ls-files 'services/*.c') 2>/tmp/cpp || { cat /tmp/cpp; bad "cppcheck"; }; } || \
    echo "  (cppcheck not installed -- skipped)"

step "python compile"
if command -v python3 >/dev/null 2>&1; then
    for p in $(git ls-files '*.py'); do python3 -m py_compile "$p" || bad "py_compile $p"; done
else echo "  (python3 not installed -- skipped)"; fi

step "unit/model tests"
[ -f hdl/pps_counter/test_xo_correct.sh ] && { sh hdl/pps_counter/test_xo_correct.sh || bad "test_xo_correct"; }
[ -f hdl/pps_counter/test_tdd_window_model.py ] && command -v python3 >/dev/null 2>&1 && \
    { python3 hdl/pps_counter/test_tdd_window_model.py || bad "test_tdd_window_model"; }

step "frm image integrity (if a built artifact is present)"
if command -v mkimage >/dev/null 2>&1 || command -v dumpimage >/dev/null 2>&1; then
    _found=0
    for frm in output/*.frm; do
        [ -f "$frm" ] || continue
        _found=1
        sh test/check_frm_images.sh "$frm" || bad "check_frm_images $frm"
    done
    [ "$_found" -eq 0 ] && echo "  (no output/*.frm to check -- built artifacts are gitignored)"
else
    echo "  (mkimage/dumpimage not installed -- skipped; run test/check_frm_images.sh at release)"
fi

step "HDL lint (optional -- needs Vivado xvlog)"
command -v xvlog >/dev/null 2>&1 && \
    { xvlog hdl/pps_counter/pps_counter.v >/dev/null 2>&1 || bad "xvlog pps_counter.v"; } || \
    echo "  (xvlog not on PATH -- run the OOC synth check in the --vivado build)"

echo
[ "$rc" -eq 0 ] && echo "=== run_ci: ALL PASS ===" || echo "=== run_ci: FAILURES ABOVE ==="
exit $rc
