#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# start-claude-agents.sh — Launch Claude Code agents in tmux panes
#
# Scans ~/projects/ for git repositories and opens each in its own tmux pane
# with Claude Code ready to go. Panes are tiled 4-per-window.
#
# Groups let you bundle related repos into a single pane at a shared working
# directory. An interactive picker lets you choose which agents to launch.
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

# Groups: bundle related repos into a single agent pane.
# Format: "Label|working_directory|repo1,repo2,..."
# The label is the display name. The working dir is where Claude opens.
# Repos listed here are removed from the individual auto-detect list.
AGENT_GROUPS=(
    "D365 & Azure|$PROJECTS_DIR|d365-solutions,rcg-azure-functions,rcg-d365-plugins,rcg-d365-webresources"
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
  Edit the AGENT_GROUPS array in the script to bundle related repos into a
  single agent pane. Format: "Label|working_directory|repo1,repo2,..."
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
        # Only include directories with a .git folder
        [[ -d "$dir/.git" ]] || continue
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
# Arrays that hold the merged list of launchable items.
ENTRIES=()    # display label
PATHS=()      # working directory for the pane
BANNERS=()    # banner text shown inside the pane
ENTRY_META=() # "(group: N repos)" or blank — used in picker display

build_entries() {
    # Collect all repo names claimed by groups so we can exclude them.
    local -A grouped_repos

    for group in "${AGENT_GROUPS[@]}"; do
        IFS='|' read -r _label _dir repos <<< "$group"
        IFS=',' read -ra repo_list <<< "$repos"
        for r in "${repo_list[@]}"; do
            grouped_repos["$r"]=1
        done
    done

    # Add group entries first.
    for group in "${AGENT_GROUPS[@]}"; do
        IFS='|' read -r label dir repos <<< "$group"
        IFS=',' read -ra repo_list <<< "$repos"
        local count=${#repo_list[@]}

        ENTRIES+=("$label")
        PATHS+=("$dir")
        ENTRY_META+=("(group: ${count} repos)")

        # Build a banner that lists the member repos.
        local banner
        banner="═══════════════════════════════════════\n"
        banner+="  Group: ${label}\n"
        banner+="  Repos:"
        for r in "${repo_list[@]}"; do
            banner+=" ${r}"
        done
        banner+="\n═══════════════════════════════════════"
        BANNERS+=("$banner")
    done

    # Add individual repos (excluding any that belong to a group).
    for agent in "${AGENTS[@]}"; do
        if [[ -z "${grouped_repos[$agent]+x}" ]]; then
            ENTRIES+=("$agent")
            PATHS+=("${PROJECTS_DIR}/${agent}")
            ENTRY_META+=("")
            BANNERS+=("═══════════════════════════════════════\n  Agent: ${agent}\n═══════════════════════════════════════")
        fi
    done
}

build_entries

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
    err "No git repositories found in $PROJECTS_DIR"
    exit 1
fi

# ── Interactive picker ───────────────────────────────────────────────────────
printf "\n${BOLD}Claude Code Agent Monitor${RESET}\n\n"

# Show the numbered list.
for i in "${!ENTRIES[@]}"; do
    local_meta="${ENTRY_META[$i]}"
    if [[ -n "$local_meta" ]]; then
        printf "  ${GREEN}%2d.${RESET} %-30s ${YELLOW}%s${RESET}\n" \
            "$((i + 1))" "${ENTRIES[$i]}" "$local_meta"
    else
        printf "  ${GREEN}%2d.${RESET} %s\n" "$((i + 1))" "${ENTRIES[$i]}"
    fi
done
echo

# Determine selected indices.
SELECTED=()

if $SELECT_ALL; then
    # --all flag: select everything, no prompt.
    for i in "${!ENTRIES[@]}"; do
        SELECTED+=("$i")
    done
else
    # Interactive prompt.
    while true; do
        printf "${BOLD}Select agents${RESET} [enter numbers, 'all', or press Enter for all]: "
        read -r selection

        # Empty or "all" → select everything.
        if [[ -z "$selection" || "$selection" == "all" ]]; then
            for i in "${!ENTRIES[@]}"; do
                SELECTED+=("$i")
            done
            break
        fi

        # Parse space/comma-separated numbers.
        # Replace commas with spaces, then iterate.
        selection="${selection//,/ }"
        valid=true
        SELECTED=()
        for token in $selection; do
            # Check it's a positive integer.
            if ! [[ "$token" =~ ^[0-9]+$ ]]; then
                err "Invalid input: '$token' — enter numbers, 'all', or press Enter."
                valid=false
                break
            fi
            idx=$((token - 1))
            if (( idx < 0 || idx >= ${#ENTRIES[@]} )); then
                err "Out of range: $token (valid: 1-${#ENTRIES[@]})"
                valid=false
                break
            fi
            SELECTED+=("$idx")
        done

        if $valid && [[ ${#SELECTED[@]} -gt 0 ]]; then
            break
        fi
        SELECTED=()
    done
fi

if [[ ${#SELECTED[@]} -eq 0 ]]; then
    err "No agents selected."
    exit 1
fi

# ── Display launch plan ─────────────────────────────────────────────────────
NUM_SELECTED=${#SELECTED[@]}
NUM_WINDOWS=$(( (NUM_SELECTED + PANES_PER_WINDOW - 1) / PANES_PER_WINDOW ))

printf "Session: ${CYAN}%s${RESET}  |  Agents: ${CYAN}%d${RESET}  |  Windows: ${CYAN}%d${RESET}\n\n" \
    "$SESSION_NAME" "$NUM_SELECTED" "$NUM_WINDOWS"

for si in "${!SELECTED[@]}"; do
    idx="${SELECTED[$si]}"
    win=$(( si / PANES_PER_WINDOW + 1 ))
    pane=$(( si % PANES_PER_WINDOW ))
    local_meta="${ENTRY_META[$idx]}"
    label="${ENTRIES[$idx]}"
    if [[ -n "$local_meta" ]]; then
        printf "  ${GREEN}%2d.${RESET} %-30s ${YELLOW}(window %d, pane %d)${RESET} %s\n" \
            "$((si + 1))" "$label" "$win" "$pane" "$local_meta"
    else
        printf "  ${GREEN}%2d.${RESET} %-30s ${YELLOW}(window %d, pane %d)${RESET}\n" \
            "$((si + 1))" "$label" "$win" "$pane"
    fi
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

for si in "${!SELECTED[@]}"; do
    idx="${SELECTED[$si]}"
    local_pane=$(( si % PANES_PER_WINDOW ))
    entry_label="${ENTRIES[$idx]}"
    entry_path="${PATHS[$idx]}"
    entry_banner="${BANNERS[$idx]}"

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

ok "Session '${SESSION_NAME}' created with ${NUM_SELECTED} agents across ${NUM_WINDOWS} window(s)."
info "Attaching now... (Detach with Ctrl-b d)"
echo

exec tmux attach-session -t "$SESSION_NAME"
