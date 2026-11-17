#!/usr/bin/env bash
# Install build/Clicksmith.app to ~/Applications, (re)register the Finder extension, reload it in place.
# Finder is NOT restarted (T-0019, see scripts/reload-finder-menu.sh).
# FINDER_RESTART=1 scripts/install.sh → last resort: restart Finder (our extension is stopped first).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="build/Clicksmith.app"; DST="$HOME/Applications/Clicksmith.app"; ID="dev.clicksmith.app.finder"
[ -d "$SRC" ] || scripts/bundle.sh
pkill -x Clicksmith 2>/dev/null || true
# Finder lets go of the running extension before we replace its files. It is always turned back on.
pluginkit -e ignore -i "$ID" 2>/dev/null || true
trap 'pluginkit -e use -i "$ID" 2>/dev/null || true' EXIT
# Drop stale registrations (other copies of the app) so Finder loads only ours.
pluginkit -m -v -i "$ID" 2>/dev/null | awk -F'\t' '{print $NF}' | while read -r p; do
  [ -n "$p" ] && [ "$p" != "$DST/Contents/PlugIns/ClicksmithFinder.appex" ] && pluginkit -r "$p" 2>/dev/null || true
done
mkdir -p "$HOME/Applications"; rm -rf "$DST"; cp -R "$SRC" "$DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST"
pluginkit -a "$DST/Contents/PlugIns/ClicksmithFinder.appex"
open -g "clicksmith://refresh"   # starts the app quietly; it writes menu.json then quits when idle
if [ "${FINDER_RESTART:-0}" = 1 ]; then
  pluginkit -e use -i "$ID"
  scripts/reload-finder-menu.sh --restart-finder
else
  scripts/reload-finder-menu.sh   # ignore → use: Finder loads the new copy; Finder pid stays the same
fi
pluginkit -m -i "$ID"
pgrep -fl ClicksmithFinder >/dev/null && echo "INSTALL OK: Finder loaded the extension" || echo "INSTALL WARN: extension not loaded yet (open a Finder window)"
