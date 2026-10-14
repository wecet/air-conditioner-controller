#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODE=preview
LAUNCH=1
usage() { echo "Usage: ./start.sh [--preview | --production] [--no-launch]"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preview) MODE=preview ;;
    --production) MODE=production ;;
    --no-launch) LAUNCH=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[[ "$(uname -s)" == Darwin ]] || { echo 'GreeBar requires macOS.' >&2; exit 1; }
for TOOL in swiftc codesign plutil ditto; do
  command -v "$TOOL" >/dev/null || { echo "Missing $TOOL. Install Xcode Command Line Tools: xcode-select --install" >&2; exit 1; }
done
BUILD="$ROOT/build/GreeBar.app"
DEPLOY="$ROOT/.local/GreeBar.app"
mkdir -p "$BUILD/Contents/MacOS" "$ROOT/build/ModuleCache" "$ROOT/.local"
echo 'Building GreeBar…'
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$ROOT/build/ModuleCache" \
  -import-objc-header "$ROOT/Sources/Crypto.h" \
  "$ROOT/Sources/AnimationProfile.swift" "$ROOT/Sources/OffTimer.swift" "$ROOT/Sources/GreeClient.swift" "$ROOT/Sources/App.swift" \
  -o "$BUILD/Contents/MacOS/GreeBar" -framework SwiftUI -framework AppKit
cp "$ROOT/Info.plist" "$BUILD/Contents/Info.plist"
plutil -lint "$BUILD/Contents/Info.plist"
codesign --force --sign - "$BUILD"
codesign --verify --deep --strict "$BUILD"
# Only quit the app deployed by this workspace. Leave unrelated copies alone.
if [[ "$LAUNCH" == 1 ]]; then
  pkill -f "^$DEPLOY/Contents/MacOS/GreeBar([[:space:]]|$)" 2>/dev/null || true
fi
ditto "$BUILD" "$DEPLOY"
codesign --verify --deep --strict "$DEPLOY"
echo "Deployed: $DEPLOY"
if [[ "$LAUNCH" == 1 ]]; then
  # -n creates a new instance so requested mode takes effect on every launch.
  open -n "$DEPLOY" --args "--$MODE"
  echo "Opened in $MODE mode. Look for the AC icon in your menu bar."
fi
