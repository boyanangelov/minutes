#!/bin/bash
# Builds "Call Recorder.app" into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Call Recorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Plain swiftc (no SwiftPM needed). Swift 5 mode keeps Core Audio callbacks free of strict-concurrency noise.
swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos14.4" \
    -framework AppKit -framework AVFoundation -framework CoreAudio \
    Sources/CallRecorder/*.swift \
    -o "$APP/Contents/MacOS/CallRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature (no hardened runtime, so no audio-input entitlement needed).
codesign --force --sign - --identifier local.callrecorder.app "$APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Call Recorder.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Call Recorder.app"
else
    echo "Built $APP"
fi
