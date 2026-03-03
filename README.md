# Killian

*"You thought you could hide in the menu bar? Think again, runner."*

A macOS menu bar app that hunts down rogue `tsgo` processes — the TypeScript native preview language server that VS Code spawns and sometimes forgets about. Each one devours 3-4 GB of RAM. Killian sits in your menu bar like a game show host, watching for runners that have overstayed their welcome.

## What It Does

Scans every 30 seconds for `tsgo` processes and kills them when they're:

1. **Orphaned** — parent is `launchd` (PID 1), meaning VS Code already exited
2. **Parent dead** — parent process no longer exists or isn't VS Code/Node
3. **Memory hogs** — using more than 4 GB (likely a memory leak)
4. **Excess instances** — more than one tsgo per VS Code window

Legitimate tsgo processes (parent VS Code alive, under 4 GB) are left alone.

## Menu Bar

| State | Icon | Meaning |
|-------|------|---------|
| `figure.run` | Default | All clear, no runners |
| `figure.run` (orange) + count | Monitoring | Tracking N active tsgo processes |
| `figure.fall` (red) | Kill in progress | Runner down! |
| `checkmark.circle.fill` (green) | Kill complete | Clean kill confirmed |

**Left-click**: immediate scan. **Right-click**: menu with active runners, recent kills, stats, and actions.

## Build & Run

```bash
bash build.sh          # Build Killian.app
open Killian.app       # Run it
```

## Install (auto-start on login)

```bash
bash build.sh install    # Copies to ~/Applications, installs LaunchAgent
bash build.sh uninstall  # Removes everything
```

## Logs

Activity is logged to `~/Library/Logs/Killian.log`.
