#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# start-claude-agents.sh — Launch Claude Code agents in tmux panes
#
# Scans ~/projects/ for git repositories and opens each in its own tmux pane
# with Claude Code ready to go. Panes are tiled 4-per-window.
#
# Groups let you select related repos as a unit in the interactive picker.
# Each member repo gets its own pane.
###############################################################################

# ── Configuration ────────────────────────────────────────────────────────────
SESSION_NAME="claude-agents"
PROJECTS_DIR="$HOME/projects"
CLAUDE_CMD="claude"
PANES_PER_WINDOW=4

# Manual override: list specific directory names to use instead of auto-detect.
# Leave empty to auto-detect git repos.
# Example: AGENTS=("rcg-v6-root" "SillyTavern" "root")
AGENTS=()

# Groups: select related repos as a unit in the picker.
# Format: "Label|repo1,repo2,..."
# Each member repo gets its own pane. Grouped repos are removed from the
# individual auto-detect list so they don't appear twice.
AGENT_GROUPS=(
    "D365 & Azure|d365-solutions,rcg-azure-functions,rcg-d365-plugins,rcg-d365-webresources"
    "RCG V6|rcg-v6-root,rcg-v6-agent-1,rcg-v6-agent-2,rcg-v6-agent-3"
)

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "${CYAN}[info]${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ok]${RESET}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[warn]${RESET}  %s\n" "$*"; }
err()   { printf "${RED}[error]${RESET} %s\n" "$*" >&2; }

# ── Help ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Launch Claude Code agents in a tmux session with tiled panes.

Options:
  -s, --session NAME   Session name (default: $SESSION_NAME)
  -d, --dir PATH       Projects directory (default: $PROJECTS_DIR)
  -n, --dry-run        Show what would be launched without doing it
  -a, --all            Skip interactive picker and launch all agents
  -h, --help           Show this help message

Groups:
  Edit the AGENT_GROUPS array in the script to select related repos as a unit.
  Format: "Label|repo1,repo2,..."  Each member gets its own pane.
  Grouped repos are excluded from individual auto-detection.

By default, all git repositories under ~/projects/ are detected.
Edit the AGENTS array in the script to use a fixed list instead.
EOF
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────
DRY_RUN=false
SELECT_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--session) SESSION_NAME="$2"; shift 2 ;;
        -d|--dir)     PROJECTS_DIR="$2"; shift 2 ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        -a|--all)     SELECT_ALL=true; shift ;;
        -h|--help)    usage ;;
        *)            err "Unknown option: $1"; usage ;;
    esac
done

# ── Dependency check ─────────────────────────────────────────────────────────
if ! command -v tmux &>/dev/null; then
    err "tmux is not installed. Install it with: sudo apt install tmux"
    exit 1
fi

if ! command -v "$CLAUDE_CMD" &>/dev/null; then
    err "Claude CLI ('$CLAUDE_CMD') not found in PATH."
    exit 1
fi

# ── Auto-detect git repos ───────────────────────────────────────────────────
detect_agents() {
    local agents=()
    for dir in "$PROJECTS_DIR"/*/; do
        [[ ! -d "$dir" ]] && continue
        local name
        name="$(basename "$dir")"
        # Skip hidden directories
        [[ "$name" == .* ]] && continue
        # Only include directories with a .git folder or worktree file
        [[ -e "$dir/.git" ]] || continue
        agents+=("$name")
    done
    # Sort alphabetically
    IFS=$'\n' agents=($(sort <<<"${agents[*]}")); unset IFS
    printf '%s\n' "${agents[@]}"
}

if [[ ${#AGENTS[@]} -eq 0 ]]; then
    mapfile -t AGENTS < <(detect_agents)
fi

# ── Build unified entries (groups + individual repos) ────────────────────────
# Picker-level arrays: one entry per selectable item in the picker.
PICKER_LABELS=()  # display label
PICKER_META=()    # "(group: N repos)" or blank

# Pane-level arrays: one entry per actual tmux pane to create.
# PICKER_PANES[i] holds a space-separated list of pane indices for picker item i.
PICKER_PANES=()
PANE_LABELS=()    # display label for the pane
PANE_PATHS=()     # working directory
PANE_BANNERS=()   # banner text shown inside the pane

build_entries() {
    # Collect all repo names claimed by groups so we can exclude them.
    local -A grouped_repos

    for group in "${AGENT_GROUPS[@]}"; do
        IFS='|' read -r _label repos <<< "$group"
        IFS=',' read -ra repo_list <<< "$repos"
        for r in "${repo_list[@]}"; do
            grouped_repos["$r"]=1
        done
    done

    # Add group entries — each member repo gets its own pane.
    for group in "${AGENT_GROUPS[@]}"; do
        IFS='|' read -r label repos <<< "$group"
        IFS=',' read -ra repo_list <<< "$repos"
        local count=${#repo_list[@]}

        PICKER_LABELS+=("$label")
        PICKER_META+=("(group: ${count} repos)")

        local pane_indices=""
        for r in "${repo_list[@]}"; do
            local pi=${#PANE_LABELS[@]}
            pane_indices+="${pi} "
            PANE_LABELS+=("$r")
            PANE_PATHS+=("${PROJECTS_DIR}/${r}")
            PANE_BANNERS+=("═══════════════════════════════════════\n  Agent: ${r}  [${label}]\n═══════════════════════════════════════")
        done
        PICKER_PANES+=("$pane_indices")
    done

    # Add individual repos (excluding any that belong to a group).
    for agent in "${AGENTS[@]}"; do
        if [[ -z "${grouped_repos[$agent]+x}" ]]; then
            local pi=${#PANE_LABELS[@]}
            PICKER_LABELS+=("$agent")
            PICKER_META+=("")
            PICKER_PANES+=("$pi")
            PANE_LABELS+=("$agent")
            PANE_PATHS+=("${PROJECTS_DIR}/${agent}")
            PANE_BANNERS+=("═══════════════════════════════════════\n  Agent: ${agent}\n═══════════════════════════════════════")
        fi
    done
}

build_entries

if [[ ${#PICKER_LABELS[@]} -eq 0 ]]; then
    err "No git repositories found in $PROJECTS_DIR"
    exit 1
fi

# ── Interactive picker ───────────────────────────────────────────────────────
printf "\n${BOLD}Claude Code Agent Monitor${RESET}\n\n"

# Show the numbered list.
for i in "${!PICKER_LABELS[@]}"; do
    local_meta="${PICKER_META[$i]}"
    if [[ -n "$local_meta" ]]; then
        printf "  ${GREEN}%2d.${RESET} %-30s ${YELLOW}%s${RESET}\n" \
            "$((i + 1))" "${PICKER_LABELS[$i]}" "$local_meta"
    else
        printf "  ${GREEN}%2d.${RESET} %s\n" "$((i + 1))" "${PICKER_LABELS[$i]}"
    fi
done
echo

# Determine selected picker indices.
SELECTED_PICKER=()

if $SELECT_ALL; then
    for i in "${!PICKER_LABELS[@]}"; do
        SELECTED_PICKER+=("$i")
    done
else
    while true; do
        printf "${BOLD}Select agents${RESET} [enter numbers, 'all', or press Enter for all]: "
        read -r selection

        if [[ -z "$selection" || "$selection" == "all" ]]; then
            for i in "${!PICKER_LABELS[@]}"; do
                SELECTED_PICKER+=("$i")
            done
            break
        fi

        selection="${selection//,/ }"
        valid=true
        SELECTED_PICKER=()
        for token in $selection; do
            if ! [[ "$token" =~ ^[0-9]+$ ]]; then
                err "Invalid input: '$token' — enter numbers, 'all', or press Enter."
                valid=false
                break
            fi
            idx=$((token - 1))
            if (( idx < 0 || idx >= ${#PICKER_LABELS[@]} )); then
                err "Out of range: $token (valid: 1-${#PICKER_LABELS[@]})"
                valid=false
                break
            fi
            SELECTED_PICKER+=("$idx")
        done

        if $valid && [[ ${#SELECTED_PICKER[@]} -gt 0 ]]; then
            break
        fi
        SELECTED_PICKER=()
    done
fi

if [[ ${#SELECTED_PICKER[@]} -eq 0 ]]; then
    err "No agents selected."
    exit 1
fi

# Expand selected picker items into pane indices.
SELECTED_PANES=()
for pi in "${SELECTED_PICKER[@]}"; do
    for pane_idx in ${PICKER_PANES[$pi]}; do
        SELECTED_PANES+=("$pane_idx")
    done
done

# ── Display launch plan ─────────────────────────────────────────────────────
NUM_PANES=${#SELECTED_PANES[@]}
NUM_WINDOWS=$(( (NUM_PANES + PANES_PER_WINDOW - 1) / PANES_PER_WINDOW ))

printf "Session: ${CYAN}%s${RESET}  |  Panes: ${CYAN}%d${RESET}  |  Windows: ${CYAN}%d${RESET}\n\n" \
    "$SESSION_NAME" "$NUM_PANES" "$NUM_WINDOWS"

for si in "${!SELECTED_PANES[@]}"; do
    pane_idx="${SELECTED_PANES[$si]}"
    win=$(( si / PANES_PER_WINDOW + 1 ))
    pane=$(( si % PANES_PER_WINDOW ))
    printf "  ${GREEN}%2d.${RESET} %-30s ${YELLOW}(window %d, pane %d)${RESET}\n" \
        "$((si + 1))" "${PANE_LABELS[$pane_idx]}" "$win" "$pane"
done
echo

if $DRY_RUN; then
    ok "Dry run complete — no session created."
    exit 0
fi

# ── Session management ───────────────────────────────────────────────────────
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    warn "Session '$SESSION_NAME' already exists."
    printf "  ${BOLD}(a)${RESET}ttach  |  ${BOLD}(k)${RESET}ill & restart  |  ${BOLD}(q)${RESET}uit: "
    read -r choice
    case "$choice" in
        a|A)
            info "Attaching to existing session..."
            exec tmux attach-session -t "$SESSION_NAME"
            ;;
        k|K)
            info "Killing existing session..."
            tmux kill-session -t "$SESSION_NAME"
            ;;
        *)
            info "Aborted."
            exit 0
            ;;
    esac
fi

# ── Helper: send a command into a specific pane ──────────────────────────────
send_to_pane() {
    local session="$1" window="$2" pane="$3" cmd="$4"
    tmux send-keys -t "${session}:${window}.${pane}" "$cmd" C-m
}

# ── Build the session ────────────────────────────────────────────────────────
info "Creating tmux session '${SESSION_NAME}'..."

FIRST=true
WINDOW_INDEX=0

for si in "${!SELECTED_PANES[@]}"; do
    pane_idx="${SELECTED_PANES[$si]}"
    local_pane=$(( si % PANES_PER_WINDOW ))
    entry_label="${PANE_LABELS[$pane_idx]}"
    entry_path="${PANE_PATHS[$pane_idx]}"
    entry_banner="${PANE_BANNERS[$pane_idx]}"

    # Start of a new window
    if [[ $local_pane -eq 0 ]]; then
        WINDOW_INDEX=$(( si / PANES_PER_WINDOW + 1 ))
        WINDOW_NAME="agents-${WINDOW_INDEX}"

        if $FIRST; then
            tmux new-session -d -s "$SESSION_NAME" -n "$WINDOW_NAME" -c "$entry_path"
            FIRST=false
        else
            tmux new-window -t "$SESSION_NAME" -n "$WINDOW_NAME" -c "$entry_path"
        fi
    else
        # Additional pane in the current window
        tmux split-window -t "${SESSION_NAME}:${WINDOW_NAME}" -c "$entry_path"
        tmux select-layout -t "${SESSION_NAME}:${WINDOW_NAME}" tiled
    fi

    # Send startup commands
    send_to_pane "$SESSION_NAME" "$WINDOW_NAME" "$local_pane" \
        "clear && printf '${entry_banner}\n' && ${CLAUDE_CMD}"
done

# Select the first window and first pane
tmux select-window -t "${SESSION_NAME}:agents-1"
tmux select-pane -t "${SESSION_NAME}:agents-1.0"

ok "Session '${SESSION_NAME}' created with ${NUM_PANES} agents across ${NUM_WINDOWS} window(s)."
info "Attaching now... (Detach with Ctrl-b d)"
echo

exec tmux attach-session -t "$SESSION_NAME"
