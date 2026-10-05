#!/bin/sh
# Removes Claude Notch, its login item and its Claude Code hooks (other hooks are kept).
DEST="$HOME/Applications/Claude Notch.app"
AGENT="$HOME/Library/LaunchAgents/com.claude-notch.app.plist"
[ -x "$DEST/Contents/MacOS/ClaudeNotch" ] && "$DEST/Contents/MacOS/ClaudeNotch" --uninstall-hooks
launchctl bootout "gui/$(id -u)/com.claude-notch.app" 2>/dev/null || true
pkill -x ClaudeNotch 2>/dev/null || true
rm -f "$AGENT"
rm -rf "$DEST" "$HOME/.claude/notch"
echo "Claude Notch removed."
