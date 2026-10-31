#!/bin/sh
# Build a Release app. Pass --install to replace /Applications/Appshot.app.
# With DEVELOPMENT_TEAM in Config/Local.xcconfig the app is signed with that Apple Development
# certificate; without it the app is signed ad hoc, which needs no developer account.
set -eu
cd "$(dirname "$0")/.."

install_requested="${1:-}"
team=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' Config/Local.xcconfig 2>/dev/null | tail -1 | tr -d '[:space:]')
set --
if [ -z "$team" ]; then
  set -- CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  echo "No DEVELOPMENT_TEAM in Config/Local.xcconfig: signing ad hoc." >&2
  echo "macOS sees every ad-hoc rebuild as a different app, so Screen Recording and Accessibility" >&2
  echo "have to be allowed again after each build, and in-app updates are refused." >&2
  echo "For one stable identity: echo 'DEVELOPMENT_TEAM = <your team id>' > Config/Local.xcconfig" >&2
fi

mkdir -p .work
xcodegen generate --quiet
xcodebuild -project Appshot.xcodeproj -scheme Appshot -configuration Release \
  -derivedDataPath .work/DerivedData "$@" build >.work/xcodebuild.log 2>&1 || {
  grep -E "error:|warning: .*Sendable" .work/xcodebuild.log | head -40 >&2
  echo "xcodebuild failed; full log: .work/xcodebuild.log" >&2
  exit 1
}
grep -E "warning:" .work/xcodebuild.log | grep -v "appintentsmetadataprocessor" | sort -u | head -20 || true

APP=.work/DerivedData/Build/Products/Release/Appshot.app
codesign --verify --strict "$APP"
if [ -z "$team" ]; then echo "built $APP (ad-hoc signature)"; else echo "built $APP"; fi

if [ "$install_requested" = "--install" ]; then
  INSTALL_DIR="${INSTALL_DIR:-/Applications}"
  pkill -x Appshot 2>/dev/null || true
  rm -rf "$INSTALL_DIR/Appshot.app"
  ditto "$APP" "$INSTALL_DIR/Appshot.app"
  echo "installed $INSTALL_DIR/Appshot.app"
fi
