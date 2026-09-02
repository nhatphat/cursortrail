#!/bin/bash
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/io.cursortrail.agent.plist"
APPDIR="$HOME/Library/Application Support/CursorTrail"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APPDIR"
echo "CursorTrail removed."
