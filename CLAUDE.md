# Claude Swarm — Project Guide

## What This Is
A bash script (`swarm.sh`) that launches and manages multiple Claude Code agents in tmux panes.

## Architecture
- **Single file**: all logic lives in `swarm.sh`
- **Subcommands**: `status`, `continue`, `send`, `restart`, `kill`, `watch` — dispatched near line 372
- **Launch mode**: interactive picker → tmux session builder → attach
- **Watch loop**: background process polls pane states every 5 seconds

## Key Patterns
- `detect_pane_state()` reads tmux pane content to classify: IDLE / WORKING / EXITED
- `@swarm_state` per-pane tmux user option stores the last detected state (set by `cmd_watch`)
- `pane-border-format` uses tmux conditionals to read `@swarm_state` and color-code borders
- OSC escape sequences are written to the **client TTY** (not pane TTY) to avoid corrupting Claude's TUI
- Hotkeys use `^b` prefix (Ctrl-b): `c` = continue, `C` = continue all, `r` = restart, `s` = status popup

## Conventions
- Use `tmux set -p -t TARGET @swarm_state "STATE"` to update pane state
- Never write escape sequences to pane TTYs — always use `tmux list-clients -F '#{client_tty}'`
- Session naming: auto-derived from selection labels, sanitized for tmux
- Groups defined in `AGENT_GROUPS` array, individual repos auto-detected from `~/projects/`

## Testing
- Launch: `./swarm.sh` (interactive) or `./swarm.sh -a` (all agents)
- Verify borders: heavy lines with colored state labels
- Verify watch: `swarm watch` updates `@swarm_state` and terminal title
- Check state: `tmux show -p -t SESSION:WIN.PANE @swarm_state`
