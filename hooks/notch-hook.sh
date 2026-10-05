#!/bin/sh
# Claude Notch — Claude Code hook.
# Usage: notch-hook.sh <prompt|tool|posttool|waiting|done|end>   (hook JSON on stdin)
#
# Leaves small files in ~/.claude/notch/sessions/, one per session and event kind:
#   <session_id>.prompt.json   UserPromptSubmit payload (prompt, cwd, transcript)
#   <session_id>.tool.json     PreToolUse payload (what Claude is doing right now)
#   <session_id>.posttool      PostToolUse marker (tool finished / permission granted)
#   <session_id>.waiting.json  Notification payload (Claude needs you)
#   <session_id>.done.json     Stop payload (turn finished)
#   <session_id>.pid           pid of the owning `claude` process
# The app derives each session's state from which file is newest.
# Must stay fast and silent, and never fail: Claude Code waits on it.

[ -n "$CLAUDE_NOTCH_SKIP" ] && exit 0

dir="$HOME/.claude/notch/sessions"
input=$(cat)
sid=$(printf '%s' "$input" | /usr/bin/plutil -extract session_id raw -o - - 2>/dev/null)
case "$sid" in ''|*/*|.*|*.*) exit 0 ;; esac

kind=$1
case "$kind" in
  end) rm -f "$dir/$sid".*; exit 0 ;;
  working) kind=tool ;;   # pre-1.1 hook argument
  prompt|tool|posttool|waiting|done) ;;
  *) exit 0 ;;
esac

mkdir -p "$dir" || exit 0

# Atomic write (tmp + rename) so the app never reads half a file,
# and the rename is what wakes up the app's folder watcher.
put() { tmp="$dir/.$sid.$$"; cat > "$tmp" && mv -f "$tmp" "$dir/$sid.$1"; }

# Find the claude process that owns this session (once per turn; ps is slowish).
if [ "$kind" = prompt ] || [ ! -s "$dir/$sid.pid" ]; then
  p=$PPID; i=0
  while [ "$i" -lt 8 ] && [ "${p:-0}" -gt 1 ]; do
    line=$(ps -o ppid=,comm= -p "$p" 2>/dev/null) || break
    case "$line" in */claude|*" claude") printf '%s\n' "$p" | put pid; break ;; esac
    p=$(printf '%s' "$line" | awk '{print $1}'); i=$((i + 1))
  done
fi

if [ "$kind" = posttool ]; then
  # PostToolUse carries the whole tool output (can be huge) — a marker is enough.
  : | put posttool
else
  printf '%s' "$input" | put "$kind.json"
fi
exit 0
