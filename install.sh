#!/bin/zsh
# Builds Minutes, installs it to ~/Applications and starts it at login (LaunchAgent).
set -e
cd "$(dirname "$0")"
./build.sh
DEST="$HOME/Applications/Minutes.app"
PLIST="$HOME/Library/LaunchAgents/io.github.boyanangelov.minutes.plist"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
pkill -x Minutes 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
rm -rf "$DEST" && cp -R build/Minutes.app "$DEST"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.github.boyanangelov.minutes</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/Minutes</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed to $DEST; starts at login."
echo "Uninstall: launchctl bootout gui/\$(id -u) $PLIST && rm $PLIST && rm -rf $DEST"
