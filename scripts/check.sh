#!/usr/bin/env bash
# Gate before review: build all targets + run all tests. Prints one summary line at the end.
set -uo pipefail
cd "$(dirname "$0")/.."
start=$(date +%s)
BUILD=()
if [ -n "${CLICKSMITH_CHECK_SCRATCH_PATH:-}" ]; then BUILD=(--scratch-path "$CLICKSMITH_CHECK_SCRATCH_PATH"); fi
b=$(swift build --disable-sandbox ${BUILD[@]+"${BUILD[@]}"} 2>&1) || { echo "$b" | grep -E "error|warning: unre" | head -30; echo "CHECK FAIL: build ($(git rev-parse --short HEAD 2>/dev/null))"; exit 1; }
# CLT-only toolchain: swift-testing macros + framework live in non-default paths.
CLT="$(xcode-select -p)"; TF=()
if [ -d "$CLT/usr/lib/swift/host/plugins/testing" ]; then
  FW="$CLT/Library/Developer/Frameworks"
  TF=(-Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" -Xlinker -rpath -Xlinker "$FW")
fi
out=$(swift test --disable-sandbox ${BUILD[@]+"${BUILD[@]}"} "${TF[@]}" "$@" 2>&1 | tee "${CLICKSMITH_CHECK_LOG:-/dev/null}"); rc=$?
echo "$out" | grep -E "✘|error:" | grep -v "ld: warning" | head -30
skips=$(echo "$out" | grep -E '(^|[[:space:]])SKIP(PED)?([[:space:]:]|$)' || true)
skipped=$(printf '%s\n' "$skips" | awk 'NF { n++ } END { print n+0 }')
if [ "$skipped" -gt 0 ]; then
  echo "SKIPPED: $skipped"
  printf '%s\n' "$skips"
fi
[ $rc -eq 0 ] || { echo "CHECK FAIL: tests, $skipped skipped ($(git rev-parse --short HEAD 2>/dev/null))"; exit 1; }
n=$(echo "$out" | grep -oE "Test run with [0-9]+ tests?" | grep -oE "[0-9]+" | paste -sd+ - | bc)
echo "CHECK PASS: build ok, ${n:-?} tests green, $skipped skipped, $(( $(date +%s)-start ))s, commit $(git rev-parse --short HEAD 2>/dev/null)$(git diff --quiet 2>/dev/null || echo '+dirty')"
