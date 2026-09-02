#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$HOME/Library/Application Support/CursorTrail"
PLIST="$HOME/Library/LaunchAgents/io.cursortrail.agent.plist"

if [[ ! -x "$ROOT/bin/cursortrail" ]]; then
  "$ROOT/build.sh"
fi

mkdir -p "$APPDIR" "$HOME/Library/LaunchAgents"
cp "$ROOT/bin/cursortrail" "$APPDIR/cursortrail"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.cursortrail.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APPDIR/cursortrail</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/tmp/cursortrail.log</string>
  <key>StandardErrorPath</key><string>/tmp/cursortrail.err</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/io.cursortrail.agent"

echo "Installed and started CursorTrail."
echo "Binary: $APPDIR/cursortrail"
echo "Logs: /tmp/cursortrail.log /tmp/cursortrail.err"
