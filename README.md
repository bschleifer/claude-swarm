# claude-swarm

Launch multiple [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agents in a tmux session — one per repo, tiled across windows, with an interactive picker so you choose what to spin up.

```
Claude Code Agent Monitor

   1. D365 & Azure             (group: 4 repos)
   2. RCG V6                   (group: 4 repos)
   3. SillyTavern
   4. claude-swarm
   5. root

Select agents [enter numbers, 'all', or press Enter for all]: 2
```

## Quick start

```bash
git clone https://github.com/bschleifer/claude-swarm.git
cd claude-swarm
chmod +x swarm.sh

# Edit the config section at the top of swarm.sh to match your setup,
# then launch:
./swarm.sh
```

## Requirements

- **tmux** — `sudo apt install tmux` / `brew install tmux`
- **Claude Code CLI** — `claude` must be in your PATH

## Usage

```
Usage: swarm.sh [OPTIONS]

Options:
  -s, --session NAME   Session name (default: claude-agents)
  -d, --dir PATH       Projects directory (default: ~/projects)
  -n, --dry-run        Show what would be launched without doing it
  -a, --all            Skip interactive picker and launch all agents
  -h, --help           Show this help message
```

### Examples

```bash
# Interactive picker (default)
./swarm.sh

# Launch everything, no prompts
./swarm.sh --all

# Preview without launching
./swarm.sh --dry-run

# Custom session name and directory
./swarm.sh -s my-session -d ~/work
```

## Configuration

Open `swarm.sh` and edit the config section near the top.

### Auto-detection

By default, the script scans `PROJECTS_DIR` for directories containing a `.git` folder or file (git worktrees included) and offers each as an agent. No config needed.

### Manual agent list

Pin specific repos instead of auto-detecting:

```bash
AGENTS=("repo-one" "repo-two" "my-app")
```

### Groups

Select related repos as a unit in the picker. Each member gets its own pane:

```bash
AGENT_GROUPS=(
    "Label|repo1,repo2,repo3"
)
```

| Field | Description |
|-------|-------------|
| Label | Display name shown in the picker |
| Repos | Comma-separated directory names under `PROJECTS_DIR` — excluded from individual auto-detection |

Example:

```bash
AGENT_GROUPS=(
    "D365 & Azure|d365-solutions,rcg-azure-functions,rcg-d365-plugins"
    "RCG V6|rcg-v6-root,rcg-v6-agent-1,rcg-v6-agent-2,rcg-v6-agent-3"
)
```

## How it works

1. Detects git repos (or reads your manual list)
2. Parses groups — grouped repos are removed from the individual list, each member gets its own pane
3. Shows an interactive numbered picker (skip with `--all`)
4. Creates a tmux session with panes tiled 4-per-window
5. Each pane `cd`s to the repo and runs `claude`

Detach with `Ctrl-b d`. Reattach with `tmux attach -t claude-agents`.

## Tips

- **Alias it:** `alias swarm='~/projects/claude-swarm/swarm.sh --all'`
- **Dry run first:** Use `--dry-run` to preview the layout before launching
- **Reattach:** If you detach, just run the script again — it will offer to reattach or restart

## License

MIT
