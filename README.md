# Claude Notch

> 🇦🇷 **Instalación rápida:** cloná el repo, entrá a la carpeta y corré `./install.sh`.
> Necesitás macOS 13+, Claude Code y las Command Line Tools (`xcode-select --install`).
> Reiniciá las sesiones de Claude Code abiertas. Para desinstalar: `~/.claude/notch/uninstall.sh`.

A minimal Claude Code status indicator that lives in the MacBook notch, with a tiny tamagotchi.

**Compact (always):** a little pixel pet on the left, one dot per session on the right.

| Dot | Meaning |
|---|---|
| orange, softly pulsing | working |
| amber | needs you (permission / question) |
| green | finished and not seen yet — stays until you hover the notch |
| (none) | resting — when everything rests, the notch hides completely |

More than 6 sessions collapse into counts (`●3 ●1`). The pet mirrors the overall state
(typing, waving, celebrating) and sleeps when you are away.

**Inline toast:** when a session finishes or needs you, its project name shows inside the
notch bar for 4 s (`✓ api-server`, `! landing`). Nothing drops down on its own.

**Hover:** a compact list — one row per session with what it is doing, what it needs, or
a one-line summary of what it finished. Click a row to jump to the app running it. The footer
shows the pet: level (XP from finished tasks), belly and mood bars, tasks today. Click the pet
to pet it. It gains a sprout at level 3, a party hat at 6 and a crown at 10.

Settings: `~/.claude/notch/config.json` (`petName`, `autoExpand` for the inline toasts).

## Install

Requirements: a Mac on macOS 13+ (best with a notch), [Claude Code](https://claude.com/claude-code),
and Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone <repo-url> claude-notch
cd claude-notch
./install.sh
```

This builds the app into `~/Applications/Claude Notch.app`, copies the hook to
`~/.claude/notch/notch-hook.sh`, adds hooks to `~/.claude/settings.json`
(backup saved as `settings.json.claude-notch.bak`; your existing hooks are kept),
and registers a LaunchAgent so it starts at login. Already-open Claude Code
sessions need to be restarted to pick up the hooks.

Uninstall with `~/.claude/notch/uninstall.sh` (also copied there by the installer).

## Try it without installing

```sh
./build.sh && "build/Claude Notch.app/Contents/MacOS/ClaudeNotch" --demo
```

Or open `Resources/notch.html?demo` in a browser.

## How it works

- `hooks/notch-hook.sh` — run by Claude Code on `UserPromptSubmit`, `PreToolUse`,
  `PostToolUse`, `Notification` (permission prompts), `Stop` and `SessionEnd`. Drops one small
  file per session and event kind in `~/.claude/notch/sessions/`; the newest one is the state.
- `Sources/main.swift` — a click-through panel over the notch. Derives every session's state,
  detects Esc interrupts (Claude Code doesn't fire `Stop` on them) and dead `claude` processes,
  summarizes finished turns from the transcript, keeps the pet in `~/.claude/notch/pet.json`.
- `Resources/notch.html` — the view: spring-animated SVG shape, pixel pet, dots, hover list.

On Macs without a notch it drops a pill from the top center of the menu bar.
