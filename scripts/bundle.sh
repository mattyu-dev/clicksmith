#!/usr/bin/env bash
# Build build/Clicksmith.app (app + csx + Finder extension), ad-hoc signed. ADR-0002.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
VERSION="$(grep -oE 'version = "[^"]+"' Sources/ClicksmithCore/ClicksmithCore.swift | cut -d'"' -f2)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
swift build --disable-sandbox -c "$CONFIG" 2>&1 | grep -E "error|Compiling|Build complete" | grep -v "^$" | tail -5
BIN="$(swift build --disable-sandbox -c "$CONFIG" --show-bin-path)"
APP="build/Clicksmith.app"; EXT="$APP/Contents/PlugIns/ClicksmithFinder.appex"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS"
cp "$BIN/Clicksmith" "$APP/Contents/MacOS/Clicksmith"
cp "$BIN/csx" "$APP/Contents/MacOS/csx"
cp "$BIN/ClicksmithFinder" "$EXT/Contents/MacOS/ClicksmithFinder"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Support/App-Info.plist > "$APP/Contents/Info.plist"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Support/Finder-Info.plist > "$EXT/Contents/Info.plist"
[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns "$APP/Contents/Resources/"
# Sign inside-out. Extension must be sandboxed.
codesign -f -s - --options runtime --entitlements Support/ClicksmithFinder.entitlements "$EXT"
codesign -f -s - --options runtime "$APP/Contents/MacOS/csx"
codesign -f -s - --options runtime "$APP"
codesign --verify --deep --strict "$APP" && echo "BUNDLE OK: $APP ($VERSION build $BUILD)"
