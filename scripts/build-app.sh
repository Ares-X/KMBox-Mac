#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Native system frameworks only. SwiftPM downloads no packages.
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP_DIR="$PWD/dist/KMBox Mac.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PWD/artifacts"
cp "$BIN_DIR/KMBoxMac" "$APP_DIR/Contents/MacOS/KMBoxMac"
cp "$BIN_DIR/kmctl" "$PWD/dist/kmctl"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
swift scripts/make-icon.swift "$PWD/artifacts/KMBox.iconset"
iconutil -c icns "$PWD/artifacts/KMBox.iconset" -o "$APP_DIR/Contents/Resources/KMBox.icns"
# Rebuild generated documentation so retired local research notes cannot survive an incremental build.
rm -rf "$APP_DIR/Contents/Resources/docs"
for name in README.md README.en.md LICENSE SOURCES.md CHANGELOG.md CONTRIBUTING.md; do
  cp "$name" "$APP_DIR/Contents/Resources/$name"
done
ditto docs "$APP_DIR/Contents/Resources/docs"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
file "$APP_DIR/Contents/MacOS/KMBoxMac"
printf 'App: %s\nCLI: %s\n' "$APP_DIR" "$PWD/dist/kmctl"
