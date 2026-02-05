# claude-swarm

Launch multiple [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agents in a tmux session — one per repo, tiled across windows, with an interactive picker so you choose what to spin up.

```
Claude Code Agent Monitor

   1. D365 & Azure             (group: 4 repos)
   2. rcg-v6-root
   3. root
   4. SillyTavern

Select agents [enter numbers, 'all', or press Enter for all]: 1 3
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

By default, the script scans `PROJECTS_DIR` for directories containing a `.git` folder and offers each as an agent. No config needed.

### Manual agent list

Pin specific repos instead of auto-detecting:

```bash
AGENTS=("repo-one" "repo-two" "my-app")
```

### Groups

Bundle related repos into a single agent pane that opens at a shared working directory:

```bash
GROUPS=(
    "Label|/path/to/working/dir|repo1,repo2,repo3"
)
```

| Field | Description |
|-------|-------------|
| Label | Display name shown in the picker and pane banner |
| Working directory | Where Claude opens for the group pane |
| Repos | Comma-separated repo names — these are excluded from individual auto-detection |

Example:

```bash
GROUPS=(
    "D365 & Azure|$PROJECTS_DIR|d365-solutions,rcg-azure-functions,rcg-d365-plugins"
    "Frontend|$PROJECTS_DIR/frontend|app-web,design-system"
)
```

## How it works

1. Detects git repos (or reads your manual list)
2. Parses groups — grouped repos are removed from the individual list
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
