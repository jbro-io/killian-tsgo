# Killian

*"You thought you could hide in my RAM? Think again, runner."*

A macOS menu bar app that hunts down rogue `tsgo` processes — the TypeScript native preview language server that VS Code spawns and sometimes forgets about. Each one devours 3-4 GB of RAM. Left unchecked, a couple of forgotten instances will eat your entire memory budget before lunch.

Killian sits in your menu bar, scanning every 30 seconds. When he spots a rogue runner, the kill sequence plays out right in your menu bar: crosshair locks on, the runner falls, skull and crossbones. Justice served.

## Quick Start

```bash
bash build.sh           # build the app + zip
bash build.sh install   # copy to ~/Applications, enable auto-start, launch
```

## The Hunt

Every 30 seconds, Killian scans for `tsgo` processes and evaluates each one against four kill heuristics:

| # | Heuristic | What It Means | Verdict |
|---|-----------|---------------|---------|
| 1 | **Orphaned** | Parent is `launchd` (PID 1) — VS Code already left the building | Immediate kill |
| 2 | **Parent dead** | Parent process is gone or isn't VS Code/Node | Immediate kill |
| 3 | **Memory hog** | Using more than 4 GB — almost certainly a leak | Immediate kill |
| 4 | **Excess instances** | Multiple tsgo per VS Code window — only the newest survives | Kill older duplicates |

Legitimate processes (parent VS Code alive, under 4 GB, one per window) are left alone. Killian isn't a monster — just efficient.

## Menu Bar Icons

Watch the story unfold in your menu bar:

| Icon | State | What's Happening |
|------|-------|-----------------|
| `figure.run` | Idle | All quiet. No runners on the loose |
| `figure.run` / `figure.walk` | Scanning | He's on the move — scanning for targets |
| `scope` | Headshot | Target acquired. Crosshair locked |
| `figure.fall` | Runner down | The runner has been neutralized |
| ☠ | Confirmed kill | Skull and crossbones. It's over |

## Usage

**Click the icon** to open the menu:

- **Active runners** are listed with PID, memory usage, CPU, and uptime — click any runner to kill it on the spot
- **Scan Now** triggers an immediate sweep
- **Kill All Runners** — no mercy, no questions
- **Simulate** submenu lets you preview all the icon animations
- **Recent Kills** shows your latest takedowns with timestamps

## Download from Slack

If someone sent you `Killian.zip`:

1. Unzip it — you'll get `Killian.app`
2. Double-click to run (you may need to right-click > Open the first time to bypass Gatekeeper)
3. For auto-start on login, clone this repo and run `bash build.sh install`

## Uninstall

```bash
bash build.sh uninstall
```

This removes the app from `~/Applications`, removes the login LaunchAgent, and stops any running instance. The runners win this round.

## Building from Source

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone <repo-url>
cd killian-tsgo
bash build.sh
open Killian.app
```

## Logs

Kill reports and scan activity are logged to `~/Library/Logs/Killian.log`.

```bash
tail -f ~/Library/Logs/Killian.log   # watch the hunt live
```

## Why "Killian"?

Named after the host of *The Running Man*. The tsgo processes are the runners. Killian always gets his man.
