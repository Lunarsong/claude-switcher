#!/bin/zsh
# Builds the macOS menu-bar app, or runs the tests.
#
#   ./build.sh            build "build/Claude Usage Tray.app"
#   ./build.sh test       build and run the tests (exit code = failures)
#   ./build.sh install    build, then copy the app to ~/Applications
#
# Needs only the Xcode command-line tools (swiftc). No packages are downloaded.
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Claude Usage Tray"
EXE="ClaudeUsageTray"
OUT="build"
APP="$OUT/$APP_NAME.app"
FLAGS=(-swift-version 5 -O -target "$(uname -m)-apple-macos13.0")
CORE=(Sources/JSON.swift Sources/Core.swift Sources/Login.swift)

mkdir -p "$OUT"

if [[ "${1:-}" == "test" ]]; then
  swiftc "${FLAGS[@]}" -o "$OUT/run-tests" "${CORE[@]}" Tests/main.swift
  exec "$OUT/run-tests"
fi

swiftc "${FLAGS[@]}" -o "$OUT/$EXE" "${CORE[@]}" Sources/CLI.swift Sources/App.swift Sources/PopoverView.swift Sources/AddAccountView.swift Sources/main.swift \
  -framework AppKit -framework SwiftUI -framework UserNotifications

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/$EXE" "$APP/Contents/MacOS/$EXE"
cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature: required for notifications and for macOS to run it cleanly.
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"$APP_NAME.app"
  cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/$APP_NAME.app"
fi
