#!/bin/bash
# Installs AILimits.app into /Applications and starts it at login.
#
# A LaunchAgent rather than a System Events login item: no Automation
# permission prompt, and the whole thing is one plist the user can read.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="/Applications/AILimits.app"
AGENT="$HOME/Library/LaunchAgents/dev.ailimits.AILimits.plist"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/dev.ailimits.AILimits" 2>/dev/null || true
  rm -f "$AGENT"
  pkill -f "$TARGET/Contents/MacOS/AILimits" 2>/dev/null || true
  rm -rf "$TARGET"
  echo "odinstalowane (baza w ~/Library/Application Support/AILimits została nietknięta)"
  exit 0
fi

"$ROOT/scripts/build.sh" release

# Stop whatever is running before replacing the bundle underneath it.
launchctl bootout "gui/$(id -u)/dev.ailimits.AILimits" 2>/dev/null || true
pkill -f "AILimits.app/Contents/MacOS/AILimits" 2>/dev/null || true
sleep 1

rm -rf "$TARGET"
cp -R "$ROOT/.build/AILimits.app" "$TARGET"

mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>dev.ailimits.AILimits</string>
    <key>ProgramArguments</key> <array><string>$TARGET/Contents/MacOS/AILimits</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key>      <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "zainstalowane w $TARGET, wystartuje przy logowaniu"
