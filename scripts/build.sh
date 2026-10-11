#!/bin/sh
# Build a signed Release app. Pass --install to replace /Applications/Appshot.app.
set -eu
cd "$(dirname "$0")/.."

if [ ! -f Config/Local.xcconfig ]; then
  echo "Config/Local.xcconfig is missing. Create it with: DEVELOPMENT_TEAM = <your team id>" >&2
  exit 2
fi

mkdir -p .work
xcodegen generate --quiet
xcodebuild -project Appshot.xcodeproj -scheme Appshot -configuration Release \
  -derivedDataPath .work/DerivedData build >.work/xcodebuild.log 2>&1 || {
  grep -E "error:|warning: .*Sendable" .work/xcodebuild.log | head -40 >&2
  echo "xcodebuild failed; full log: .work/xcodebuild.log" >&2
  exit 1
}
grep -E "warning:" .work/xcodebuild.log | grep -v "appintentsmetadataprocessor" | sort -u | head -20 || true

APP=.work/DerivedData/Build/Products/Release/Appshot.app
codesign --verify --strict "$APP"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  INSTALL_DIR="${INSTALL_DIR:-/Applications}"
  pkill -x Appshot 2>/dev/null || true
  rm -rf "$INSTALL_DIR/Appshot.app"
  ditto "$APP" "$INSTALL_DIR/Appshot.app"
  echo "installed $INSTALL_DIR/Appshot.app"
fi
