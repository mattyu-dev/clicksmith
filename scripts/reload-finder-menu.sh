#!/usr/bin/env bash
# Reload the Clicksmith Finder extension in place. Finder keeps running (T-0019).
# Why not `killall Finder`: our extension runs in Finder's process coalition. If it outlives a
# killed Finder, loginwindow says "“Finder” is running in the background after it was closed".
# Usage: scripts/reload-finder-menu.sh [--restart-finder]
#   --restart-finder  last resort: stop our extension (and wait until it is gone), then restart Finder.
# Prints "RELOAD OK|WARN finder <before>→<after> extension <before>→<after> heartbeat <pid> <time>".
# OK only when a NEW extension pid (not the one in the old heartbeat) wrote the heartbeat and runs.
# Env (tests): CLICKSMITH_HEARTBEAT, RELOAD_WAIT (seconds, default 15).
set -euo pipefail
ID="dev.clicksmith.app.finder"
PATTERN="ClicksmithFinder.appex/Contents/MacOS/ClicksmithFinder"
HEARTBEAT="${CLICKSMITH_HEARTBEAT:-$HOME/Library/Application Support/Clicksmith/extension-heartbeat.json}"
WAIT="${RELOAD_WAIT:-15}"
ext_pids() { pgrep -f "$PATTERN" | sort -n | paste -sd, - || true; }
finder_pid() { pgrep -x Finder || true; }
hb_field() { sed -n "s/.*\"$1\" *: *\"\\{0,1\\}\\([^\",}]*\\).*/\\1/p" "$HEARTBEAT" 2>/dev/null | head -1 || true; }
alive() { [ -n "$1" ] && pgrep -f "$PATTERN" | grep -qx "$1"; }

# Whatever happens from here (error, Ctrl-C, kill), the extension is turned back on.
restore() { pluginkit -e use -i "$ID" 2>/dev/null || true; }
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

F0=$(finder_pid); E0=$(ext_pids); OLD_PID=$(hb_field pid)

pluginkit -e ignore -i "$ID"
if [ "${1:-}" = "--restart-finder" ]; then
  pkill -f "$PATTERN" 2>/dev/null || true            # leave Finder's coalition first …
  for _ in $(seq 1 10); do [ -z "$(ext_pids)" ] && break; sleep 0.5; done
  [ -z "$(ext_pids)" ] || { pkill -9 -f "$PATTERN" 2>/dev/null || true; sleep 1; }
  if [ -n "$(ext_pids)" ]; then
    echo "RELOAD WARN extension $(ext_pids) does not stop; Finder NOT restarted"; exit 1
  fi
  killall Finder 2>/dev/null || true                 # … and only then restart Finder
else
  sleep 1
fi
pluginkit -e use -i "$ID"

# Proof of a fresh load: a new pid in the heartbeat that runs now.
new=""
for _ in $(seq 1 $((WAIT * 2))); do
  p=$(hb_field pid); h=$(hb_field host)
  case "${h:-unknown}" in unknown|com.apple.finder) finders=1 ;; *) finders=0 ;; esac   # a dialog copy is not a reload
  if [ -n "$p" ] && [ "$p" != "$OLD_PID" ] && [ "$finders" = 1 ] && alive "$p"; then new="$p"; break; fi
  sleep 0.5
done
F1=$(finder_pid); E1=$(ext_pids)
if [ -n "$new" ]; then r=OK; hb="$new $(hb_field loaded)"; else r=WARN; hb="not refreshed (old pid ${OLD_PID:-none}; open a Finder window)"; fi
echo "RELOAD $r finder ${F0:-none}→${F1:-none} extension ${E0:-none}→${E1:-none} heartbeat $hb"
