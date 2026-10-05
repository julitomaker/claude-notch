#!/bin/sh
# Builds Claude Notch, installs it to ~/Applications, wires up Claude Code hooks
# and starts it at login. Safe to re-run (idempotent).
set -e
cd "$(dirname "$0")"
./build.sh

DEST="$HOME/Applications/Claude Notch.app"
AGENT="$HOME/Library/LaunchAgents/com.claude-notch.app.plist"

pkill -x ClaudeNotch 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/.claude/notch/sessions" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R "build/Claude Notch.app" "$DEST"

install -m 755 hooks/notch-hook.sh "$HOME/.claude/notch/notch-hook.sh"
install -m 755 uninstall.sh "$HOME/.claude/notch/uninstall.sh"
"$DEST/Contents/MacOS/ClaudeNotch" --install-hooks

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.claude-notch.app</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/ClaudeNotch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/com.claude-notch.app" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "Claude Notch installed and running."
echo "Restart open Claude Code sessions to pick up the hooks."
echo "Uninstall any time with: ~/.claude/notch/uninstall.sh"
