#!/usr/bin/env bash
# Builds MultiDock.app into ./build. Pass --install to copy it to ~/Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

APP="build/MultiDock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MultiDock" "$APP/Contents/MacOS/MultiDock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/MultiDock.app"
  mkdir -p "$HOME/Applications"
  pkill -x MultiDock 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed $DEST"
fi
