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

## Swarm / Conductor

When working on the swarm/conductor system: never inject text into tmux panes while the user may be typing. Always use targeted send-keys with proper Enter key submission. Throttle polling to at least 30-second intervals. Never run idle polling loops without a shutdown mechanism.

### Headless Conductor Pattern
Instead of infinite polling loops, use bounded headless invocations with clear exit conditions:
```bash
claude -p "Check swarm agent status in tmux. If any agent needs approval, approve it. If any agent is idle and there are pending tasks, assign one. If all agents are idle and no tasks remain, output SWARM_COMPLETE." \
  --allowedTools "Bash,Read" --max-turns 10
```
Wrap in a bash loop with proper sleep and exit detection:
```bash
while true; do
  OUTPUT=$(claude -p "..." --allowedTools "Bash,Read" --max-turns 10 2>&1)
  echo "$OUTPUT" >> swarm-conductor.log
  if echo "$OUTPUT" | grep -q "SWARM_COMPLETE"; then
    echo "All agents idle, no tasks remain. Exiting."
    break
  fi
  sleep 30
done
```
Key rules: always set `--max-turns`, always define an exit signal, always log output, always sleep between cycles.

## General Rules

When the user shows a screenshot proving something is broken, do NOT claim it's correct. Trust the user's visual evidence over code assumptions, especially for UI color/theme rendering issues.

## Testing
- Run all tests: `./test/run-tests.sh`
- Run unit tests only: `./test/bats/bin/bats test/unit_*.bats`
- Run integration tests only: `./test/bats/bin/bats test/integration_*.bats`
- Launch: `./swarm.sh` (interactive) or `./swarm.sh -a` (all agents)
- Verify borders: heavy lines with colored state labels
- Verify watch: `swarm watch` updates `@swarm_state` and terminal title
- Check state: `tmux show -p -t SESSION:WIN.PANE @swarm_state`
