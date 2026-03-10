# Killian

*"You thought you could hide in my RAM? Think again, runner."*

A macOS menu bar app that hunts down lingering `tsgo` processes — the TypeScript native preview language server that VS Code spawns and sometimes forgets about. Each one devours 3-4 GB of RAM. Left unchecked, a couple of forgotten instances will eat your entire memory budget before lunch.

Killian sits in your menu bar, scanning every 30 seconds. When he spots a rogue runner, the kill sequence plays out right in your menu bar: crosshair locks on, the runner falls, skull and crossbones. Justice served.

## Quick Start

```bash
bash build.sh           # build the app + zip
bash build.sh install   # copy to ~/Applications, enable auto-start, launch
```

## The Hunt

Every 30 seconds, Killian inspects `tsgo` and `next-server` processes, but it only auto-kills runners that look genuinely abandoned across multiple scans.

| # | Rule | What It Means | Verdict |
|---|------|---------------|---------|
| 1 | **Multi-scan confirmation** | A process must look stale for 3 consecutive scans | Avoids transient false positives |
| 2 | **Language server only for tsgo** | Auto-kill applies only to `tsgo --stdio` language-server processes | CLI builds are left alone |
| 3 | **Grace period** | Process must survive at least 3 minutes before it is considered stale | Avoids reload/build handoff kills |
| 4 | **Idle** | `tsgo` must stay under 5% CPU, `next-server` under 3% CPU | Active work is left alone |
| 5 | **Confirmed orphaning** | `tsgo` must lose VS Code/Cursor ancestry and have a dead parent; `next-server` must have no TTY and a dead parent | Only abandoned runners are targeted |
| 6 | **Memory budget** | If confirmed-stale runners exceed 6 GB combined, Killian kills the biggest offenders first | Memory leaks are drained faster |

Killian no longer auto-kills based on visible window counts. It also checks PID start time before escalating from `SIGTERM` to `SIGKILL`, so PID reuse does not hit the wrong process.

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
