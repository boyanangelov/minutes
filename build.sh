#!/bin/zsh
# Builds build/Minutes.app (Apple Silicon, macOS 14.4+). See install.sh to install and start at login.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Minutes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Plain swiftc (no SwiftPM or Xcode needed). Swift 5 mode keeps Core Audio callbacks free of strict-concurrency noise.
swiftc -O -swift-version 5 \
    -target arm64-apple-macos14.4 \
    -framework AppKit -framework AVFoundation -framework CoreAudio \
    Sources/Minutes/*.swift \
    -o "$APP/Contents/MacOS/Minutes"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature (no Developer ID, no hardened runtime, so no audio-input entitlement needed).
codesign --force --sign - --identifier io.github.boyanangelov.minutes "$APP"
echo "Built $APP — run with: open $APP"
