#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# swarm.sh — Launch and manage Claude Code agents in tmux panes
#
# Subcommands:
#   swarm [OPTIONS] [NUMBERS...]   Launch agents (default)
#   swarm status                   Show agent status (idle/working/exited)
#   swarm continue [N|all]         Send "continue" to agent(s)
#   swarm send [N|all] "message"   Send a message to agent(s)
#   swarm restart [N|all]          Restart agent(s)
#   swarm kill                     Kill the entire session
#   swarm watch                    Run notification watcher (auto-started)
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

# ── Dynamic UI helpers ──────────────────────────────────────────────────────

# Braille spinner frames (cycled each poll tick when all agents are working).
SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
SPINNER_IDX=0

# Update the Windows Terminal tab title via OSC 0 escape sequence.
# Writes to the client TTY (not a pane) so Claude's TUI isn't corrupted.
# Shows ✔ when agents need input, a spinner when all are working.
update_terminal_title() {
    local session="$1" idle_count="$2" total_count="$3"
    local client_tty
    client_tty=$(tmux list-clients -t "$session" -F '#{client_tty}' 2>/dev/null | head -1)
    [[ -z "$client_tty" || ! -w "$client_tty" ]] && return

    local indicator title
    if (( idle_count == 0 )); then
        indicator="${SPINNER_FRAMES[$SPINNER_IDX]}"
        SPINNER_IDX=$(( (SPINNER_IDX + 1) % ${#SPINNER_FRAMES[@]} ))
        title="${indicator} swarm: all working"
    else
        title="🟢 swarm: ${idle_count}/${total_count} IDLE"
    fi
    printf '\033]0;%s\007' "$title" > "$client_tty"
}

# Rename tmux windows to include idle pane counts.
# e.g. "RCG V6" → "RCG V6 (2 idle)" when agents need input.
update_window_names() {
    local session="$1"
    local win_id win_name
    while IFS=$'\t' read -r win_id win_name; do
        # Strip any existing " (N idle)" suffix to get the base name.
        local base_name="${win_name% (*}"
        local win_idle=0 win_total=0
        while IFS= read -r _pane_id; do
            win_total=$((win_total + 1))
            local pstate
            pstate=$(tmux show -p -t "${session}:${win_id}.${_pane_id}" -v @swarm_state 2>/dev/null || echo "WORKING")
            [[ "$pstate" == "IDLE" ]] && win_idle=$((win_idle + 1))
        done < <(tmux list-panes -t "${session}:${win_id}" -F '#{pane_index}' 2>/dev/null)

        local new_name
        if (( win_idle > 0 )); then
            new_name="${base_name} (${win_idle} idle)"
        else
            new_name="$base_name"
        fi
        # Only rename if changed to avoid flicker.
        if [[ "$new_name" != "$win_name" ]]; then
            tmux rename-window -t "${session}:${win_id}" "$new_name" 2>/dev/null || true
        fi
    done < <(tmux list-windows -t "$session" -F '#{window_index}'$'\t''#{window_name}' 2>/dev/null)
}

# ── Help ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [NUMBERS...]
       $(basename "$0") <command> [args]

Launch and manage Claude Code agents in a tmux session.

Launch options:
  -s, --session NAME   Session name (default: $SESSION_NAME)
  -d, --dir PATH       Projects directory (default: $PROJECTS_DIR)
  -n, --dry-run        Show what would be launched without doing it
  -a, --all            Skip interactive picker and launch all agents
  -h, --help           Show this help message
  NUMBERS              Pre-select agents by number (e.g. swarm 2 or swarm 1 3)

Commands (operate on a running session):
  status               Show status of all agents (idle/working/exited)
  continue [N|all]     Send "continue" to pane N or all panes (default: all)
  send [N|all] "msg"   Send a custom message to pane N or all panes
  restart [N|all]      Restart Claude in pane N or all panes
  kill                 Kill the entire tmux session
  watch                Run notification watcher (auto-started with session)

Notifications:
  A background watcher monitors agent states. When an agent finishes and
  goes idle, the Windows Terminal taskbar flashes and the tmux window tab
  shows a ! marker. The watcher starts automatically with the session.

Tmux hotkeys (^b = Ctrl-b, then the key):
  ^b c                 Continue current pane (press Enter)
  ^b C                 Continue ALL panes in current window
  ^b r                 Restart Claude in current pane
  ^b s                 Show agent status popup

Groups:
  Edit the AGENT_GROUPS array in the script to select related repos as a unit.
  Format: "Label|repo1,repo2,..."  Each member gets its own pane.
  Grouped repos are excluded from individual auto-detection.

By default, all git repositories under ~/projects/ are detected.
Edit the AGENTS array in the script to use a fixed list instead.
EOF
    exit 0
}

# ── Subcommand helpers ───────────────────────────────────────────────────────

# Find running swarm session(s). If -s was given, use that. Otherwise auto-detect.
# Sets SESSION_NAME to the resolved session.
require_session() {
    # If the named session exists, use it.
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        return
    fi

    # Auto-detect: list all tmux sessions, look for swarm-created ones.
    local sessions=()
    while IFS= read -r s; do
        [[ -n "$s" ]] && sessions+=("$s")
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

    if [[ ${#sessions[@]} -eq 0 ]]; then
        err "No tmux sessions running. Launch with: swarm"
        exit 1
    elif [[ ${#sessions[@]} -eq 1 ]]; then
        SESSION_NAME="${sessions[0]}"
    else
        # Multiple sessions — prompt user to pick.
        printf "\n${BOLD}Multiple tmux sessions found:${RESET}\n\n"
        for i in "${!sessions[@]}"; do
            local pcount
            pcount=$(tmux list-panes -s -t "${sessions[$i]}" 2>/dev/null | wc -l)
            printf "  ${GREEN}%d.${RESET} %-30s ${YELLOW}(%d panes)${RESET}\n" \
                "$((i + 1))" "${sessions[$i]}" "$pcount"
        done
        echo
        printf "${BOLD}Select session${RESET} [number]: "
        read -r pick
        if ! [[ "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#sessions[@]} )); then
            err "Invalid selection."
            exit 1
        fi
        SESSION_NAME="${sessions[$((pick - 1))]}"
    fi
}

# Get all pane IDs in the session (window:pane format).
get_panes() {
    tmux list-panes -s -t "$SESSION_NAME" -F '#{window_index}.#{pane_index}'
}

# Get pane count.
get_pane_count() {
    tmux list-panes -s -t "$SESSION_NAME" | wc -l
}

# Detect the state of a pane: IDLE, WORKING, or EXITED.
# IDLE    = Claude is showing the > prompt (waiting for input)
# WORKING = Claude is running and producing output
# EXITED  = Claude process has ended, back at shell prompt
detect_pane_state() {
    local target="$1"
    # Get the current command running in the pane.
    local cmd
    cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || echo "")

    # If the foreground process is bash/zsh, Claude has exited.
    if [[ "$cmd" == "bash" || "$cmd" == "zsh" || "$cmd" == "sh" ]]; then
        echo "EXITED"
        return
    fi

    # Capture the full visible pane (not just the tail — "esc to interrupt"
    # can appear anywhere on screen depending on scroll position).
    local content
    content=$(tmux capture-pane -p -t "$target" 2>/dev/null || echo "")

    # "esc to interrupt" only appears when Claude is actively processing.
    # Check this FIRST because the > prompt is visible in both states.
    if echo "$content" | grep -qF 'esc to interrupt'; then
        echo "WORKING"
    elif echo "$content" | grep -qE '^\s*[>❯]|^\? for shortcuts'; then
        echo "IDLE"
    else
        echo "WORKING"
    fi
}

# Send text to a specific pane (by window:pane target).
send_text() {
    local target="$1" text="$2"
    tmux send-keys -t "${SESSION_NAME}:${target}" "$text" C-m
}

# Resolve pane argument: "all", a number, or default to "all".
# Outputs a list of window:pane targets.
resolve_pane_arg() {
    local arg="${1:-all}"
    if [[ "$arg" == "all" ]]; then
        get_panes
    else
        if ! [[ "$arg" =~ ^[0-9]+$ ]]; then
            err "Invalid pane number: $arg"
            exit 1
        fi
        local total
        total=$(get_pane_count)
        if (( arg >= total )); then
            err "Pane $arg does not exist (valid: 0-$((total - 1)))"
            exit 1
        fi
        # Find the actual window:pane for the Nth pane globally.
        get_panes | sed -n "$((arg + 1))p"
    fi
}

# ── Subcommand: status ───────────────────────────────────────────────────────
cmd_status() {
    require_session
    printf "\n${BOLD}Agent Status${RESET}  (session: ${CYAN}%s${RESET})\n\n" "$SESSION_NAME"

    local idx=0
    while IFS= read -r pane_target; do
        # Use working directory basename as the display name (Claude overrides pane_title).
        local pane_path
        pane_path=$(tmux display-message -p -t "${SESSION_NAME}:${pane_target}" '#{pane_current_path}' 2>/dev/null || echo "")
        local title
        title=$(basename "$pane_path" 2>/dev/null || echo "pane-${idx}")
        local state
        state=$(detect_pane_state "${SESSION_NAME}:${pane_target}")

        local color
        case "$state" in
            IDLE)    color="$GREEN" ;;
            WORKING) color="$YELLOW" ;;
            EXITED)  color="$RED" ;;
            *)       color="$RESET" ;;
        esac

        printf "  ${CYAN}%d${RESET}  %-25s ${color}%-10s${RESET}\n" "$idx" "$title" "$state"
        idx=$((idx + 1))
    done < <(get_panes)
    echo
    # Wait for keypress so tmux popups don't vanish immediately.
    if [[ -t 0 ]]; then
        printf "${BOLD}Press any key to close${RESET}"
        read -rsn1
    fi
}

# ── Subcommand: continue ─────────────────────────────────────────────────────
cmd_continue() {
    require_session
    local arg="${1:-all}"
    local sent=0

    while IFS= read -r pane_target; do
        local state
        state=$(detect_pane_state "${SESSION_NAME}:${pane_target}")
        local title
        title=$(basename "$(tmux display-message -p -t "${SESSION_NAME}:${pane_target}" '#{pane_current_path}' 2>/dev/null)" 2>/dev/null || echo "$pane_target")

        if [[ "$state" == "IDLE" ]]; then
            tmux send-keys -t "${SESSION_NAME}:${pane_target}" C-m
            ok "Continued $title"
            sent=$((sent + 1))
        elif [[ "$state" == "EXITED" ]]; then
            send_text "$pane_target" "$CLAUDE_CMD --continue"
            ok "Restarted Claude with --continue in $title"
            sent=$((sent + 1))
        else
            info "Skipping $title (currently working)"
        fi
    done < <(resolve_pane_arg "$arg")

    if [[ $sent -eq 0 ]]; then
        info "No idle or exited agents to continue."
    fi
}

# ── Subcommand: send ─────────────────────────────────────────────────────────
cmd_send() {
    require_session
    local arg="${1:-}"
    local message="${2:-}"

    # If first arg is not a number and not "all", treat it as the message.
    if [[ -n "$arg" && ! "$arg" =~ ^[0-9]+$ && "$arg" != "all" ]]; then
        message="$arg"
        arg="all"
    fi

    if [[ -z "$message" ]]; then
        err "Usage: swarm send [N|all] \"message\""
        exit 1
    fi

    while IFS= read -r pane_target; do
        local title
        title=$(basename "$(tmux display-message -p -t "${SESSION_NAME}:${pane_target}" '#{pane_current_path}' 2>/dev/null)" 2>/dev/null || echo "$pane_target")
        send_text "$pane_target" "$message"
        ok "Sent to $title"
    done < <(resolve_pane_arg "$arg")
}

# ── Subcommand: restart ──────────────────────────────────────────────────────
cmd_restart() {
    require_session
    local arg="${1:-}"

    if [[ -z "$arg" ]]; then
        err "Usage: swarm restart <N|all>"
        exit 1
    fi

    while IFS= read -r pane_target; do
        local title
        title=$(basename "$(tmux display-message -p -t "${SESSION_NAME}:${pane_target}" '#{pane_current_path}' 2>/dev/null)" 2>/dev/null || echo "$pane_target")

        # Send Ctrl-C to interrupt, wait, then relaunch.
        tmux send-keys -t "${SESSION_NAME}:${pane_target}" C-c
        sleep 0.5
        # Send exit in case Claude dropped to a sub-prompt.
        tmux send-keys -t "${SESSION_NAME}:${pane_target}" C-c
        sleep 0.3
        send_text "$pane_target" "$CLAUDE_CMD --continue"
        ok "Restarted $title"
    done < <(resolve_pane_arg "$arg")
}

# ── Subcommand: kill ─────────────────────────────────────────────────────────
cmd_kill() {
    require_session
    tmux kill-session -t "$SESSION_NAME"
    ok "Session '$SESSION_NAME' killed."
}

# ── Subcommand: watch (background notification watcher) ─────────────────────
# Polls pane states every few seconds. When a pane transitions from WORKING to
# IDLE, sends a bell to the CLIENT terminal (not the pane) so Windows Terminal
# flashes the taskbar without corrupting Claude's TUI.
WATCH_INTERVAL=5

cmd_watch() {
    require_session

    # Track previous state of each pane so we only notify on transitions.
    declare -A prev_state
    # Require 2 consecutive IDLE readings before transitioning WORKING→IDLE.
    # Prevents flickering during brief gaps between Claude tool calls.
    declare -A idle_confirm

    while tmux has-session -t "$SESSION_NAME" 2>/dev/null; do
        local idle_count=0 total_count=0

        while IFS= read -r pane_target; do
            state=$(detect_pane_state "${SESSION_NAME}:${pane_target}")
            prev="${prev_state[$pane_target]:-UNKNOWN}"

            # Hysteresis: only accept WORKING→IDLE after 2 consecutive IDLE reads.
            if [[ "$state" == "IDLE" && "$prev" == "WORKING" ]]; then
                idle_confirm["$pane_target"]=$(( ${idle_confirm[$pane_target]:-0} + 1 ))
                if (( ${idle_confirm[$pane_target]} < 2 )); then
                    state="WORKING"  # not confirmed yet
                fi
            else
                idle_confirm["$pane_target"]=0
            fi

            total_count=$((total_count + 1))
            [[ "$state" == "IDLE" ]] && idle_count=$((idle_count + 1))

            # Update per-pane state option (drives pane-border-format coloring)
            tmux set -p -t "${SESSION_NAME}:${pane_target}" @swarm_state "$state" 2>/dev/null || true

            if [[ "$prev" == "WORKING" && "$state" == "IDLE" ]]; then
                # Agent just finished — ring the bell on the CLIENT terminal.
                # Never write to pane TTYs — that corrupts Claude's TUI.
                local client_tty
                client_tty=$(tmux list-clients -t "$SESSION_NAME" -F '#{client_tty}' 2>/dev/null | head -1)
                if [[ -n "$client_tty" && -w "$client_tty" ]]; then
                    printf '\a' > "$client_tty"
                fi
            fi

            prev_state["$pane_target"]="$state"
        done < <(get_panes)

        # Update Windows Terminal tab title and tmux window names
        update_terminal_title "$SESSION_NAME" "$idle_count" "$total_count"
        update_window_names "$SESSION_NAME"

        sleep "$WATCH_INTERVAL"
    done
}

# ── Subcommand dispatch ──────────────────────────────────────────────────────
SESSION_EXPLICIT=false

# Parse -s/--session early so it works with subcommands (e.g. swarm -s foo status).
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--session) [[ $# -lt 2 ]] && { err "-s requires a value"; exit 1; }
                      SESSION_NAME="$2"; SESSION_EXPLICIT=true; shift 2 ;;
        *)            break ;;
    esac
done

# Check if the first remaining argument is a subcommand.
if [[ $# -gt 0 ]]; then
    case "$1" in
        status)   shift; cmd_status "$@"; exit 0 ;;
        continue) shift; cmd_continue "$@"; exit 0 ;;
        send)     shift; cmd_send "$@"; exit 0 ;;
        restart)  shift; cmd_restart "$@"; exit 0 ;;
        kill)     shift; cmd_kill "$@"; exit 0 ;;
        watch)    shift; cmd_watch "$@"; exit 0 ;;
    esac
fi

# ── Argument parsing (launch mode) ───────────────────────────────────────────
DRY_RUN=false
SELECT_ALL=false
PRESELECT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--session) [[ $# -lt 2 ]] && { err "-s requires a value"; exit 1; }
                      SESSION_NAME="$2"; SESSION_EXPLICIT=true; shift 2 ;;
        -d|--dir)     [[ $# -lt 2 ]] && { err "-d requires a value"; exit 1; }
                      PROJECTS_DIR="$2"; shift 2 ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        -a|--all)     SELECT_ALL=true; shift ;;
        -h|--help)    usage ;;
        # Positional numbers: treat as pre-selections (e.g. swarm 2 or swarm 1,3)
        [0-9]*)       PRESELECT+="$1 "; shift ;;
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
PANE_GROUP=()     # group name (or repo name for individuals) — used for window naming

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
            PANE_GROUP+=("$label")
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
            PANE_GROUP+=("$agent")
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

# Helper: parse a space-separated string of numbers into SELECTED_PICKER.
# Returns 0 on success, 1 on error.
parse_selection() {
    local input="$1"
    input="${input//,/ }"
    SELECTED_PICKER=()
    for token in $input; do
        if ! [[ "$token" =~ ^[0-9]+$ ]]; then
            err "Invalid input: '$token' — enter numbers, 'all', or press Enter."
            return 1
        fi
        local idx=$((token - 1))
        if (( idx < 0 || idx >= ${#PICKER_LABELS[@]} )); then
            err "Out of range: $token (valid: 1-${#PICKER_LABELS[@]})"
            return 1
        fi
        SELECTED_PICKER+=("$idx")
    done
    [[ ${#SELECTED_PICKER[@]} -gt 0 ]]
}

if $SELECT_ALL; then
    for i in "${!PICKER_LABELS[@]}"; do
        SELECTED_PICKER+=("$i")
    done
elif [[ -n "$PRESELECT" ]]; then
    # Numbers passed on command line (e.g. swarm 2 or swarm 1 3)
    if ! parse_selection "$PRESELECT"; then
        exit 1
    fi
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

        if parse_selection "$selection"; then
            break
        fi
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

# ── Auto-name session based on selection ────────────────────────────────────
# When -s wasn't given and the user picked a subset, derive a session name
# so multiple swarms can coexist (e.g. "swarm 1" + "swarm 2" simultaneously).
if ! $SESSION_EXPLICIT && ! $SELECT_ALL; then
    # Build a name from the selected picker labels.
    auto_parts=()
    for pi in "${SELECTED_PICKER[@]}"; do
        auto_parts+=("${PICKER_LABELS[$pi]}")
    done
    # Join with "+" and sanitize for tmux (no dots or colons, lowercase).
    auto_name=$(IFS='+'; echo "${auto_parts[*]}")
    auto_name=$(echo "$auto_name" | tr '[:upper:]' '[:lower:]' | tr ' &' '-' | tr -d '.' | tr -d ':' | sed 's/--*/-/g; s/^-//; s/-$//')
    SESSION_NAME="$auto_name"
fi

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

# Path to this script (for tmux keybindings).
SWARM_PATH="$(realpath "$0")"

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
        WINDOW_NAME="${PANE_GROUP[$pane_idx]}"

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

    # Set pane title (shows in border via pane-border-status)
    tmux select-pane -t "${SESSION_NAME}:${WINDOW_NAME}.${local_pane}" -T "$entry_label"

    # Initialize per-pane user options (drives dynamic border coloring).
    # @swarm_name is used instead of pane_title because Claude's TUI overwrites it.
    tmux set -p -t "${SESSION_NAME}:${WINDOW_NAME}.${local_pane}" @swarm_name "$entry_label"
    tmux set -p -t "${SESSION_NAME}:${WINDOW_NAME}.${local_pane}" @swarm_state "WORKING"

    # Send startup commands
    send_to_pane "$SESSION_NAME" "$WINDOW_NAME" "$local_pane" \
        "clear && printf '${entry_banner}\n' && ${CLAUDE_CMD}"
done

# ── Visual styling (borders, status bar) ─────────────────────────────────────
# Heavy borders with state-colored labels
tmux set -t "$SESSION_NAME" pane-border-status top
tmux set -t "$SESSION_NAME" pane-border-lines heavy
tmux set -t "$SESSION_NAME" pane-border-indicators arrows

# Border colors: subtle grey for inactive, bright blue for active
tmux set -t "$SESSION_NAME" pane-border-style "fg=#585858"
tmux set -t "$SESSION_NAME" pane-active-border-style "fg=#00afff,bold"

# Dynamic border format: color-coded for active pane, subdued grey for inactive.
# NOTE: commas inside #[...] break #{?...} conditionals — tmux splits branches
# on ALL commas, even those inside style blocks. Use separate #[] blocks instead.
# Uses @swarm_name instead of pane_title (Claude's TUI overwrites it).
# Outer conditional: #{pane_active} — colorful for active, grey for inactive.
BORDER_FMT='#{?#{pane_active},'
# Active pane: IDLE=green, WORKING=yellow, EXITED=red
BORDER_FMT+='#{?#{==:#{@swarm_state},IDLE},'
BORDER_FMT+='#[fg=#00ff00]#[bold] #{@swarm_name} [ IDLE - needs input ]#[default],'
BORDER_FMT+='#{?#{==:#{@swarm_state},EXITED},'
BORDER_FMT+='#[fg=#ff0000]#[bold] #{@swarm_name} [ EXITED ]#[default],'
BORDER_FMT+='#[fg=#ffff00] #{@swarm_name} [ working... ]#[default]}},'
# Inactive pane: all grey
BORDER_FMT+='#[fg=#585858] #{@swarm_name} #{?#{==:#{@swarm_state},IDLE},'
BORDER_FMT+='[ IDLE - needs input ],'
BORDER_FMT+='#{?#{==:#{@swarm_state},EXITED},'
BORDER_FMT+='[ EXITED ],'
BORDER_FMT+='[ working... ]}}#[default]}'
tmux set -t "$SESSION_NAME" pane-border-format "$BORDER_FMT"

# Status bar styling
tmux set -t "$SESSION_NAME" status-style "bg=#1c1c1c,fg=#808080"
tmux set -t "$SESSION_NAME" status-left "#[fg=#00afff,bold] #{session_name} #[default] "
tmux set -t "$SESSION_NAME" status-right "#[fg=#585858]^b c:cont  C:all  r:restart  s:status  n/p:window  z:zoom  d:detach "
tmux set -t "$SESSION_NAME" status-right-length 80
tmux set -t "$SESSION_NAME" window-status-format " #I:#W "
tmux set -t "$SESSION_NAME" window-status-current-format "#[fg=#1c1c1c]#[bg=#00afff]#[bold] #I:#W #[default]"

# Prevent tmux from overwriting our window names
tmux set -t "$SESSION_NAME" automatic-rename off
tmux set -t "$SESSION_NAME" allow-rename off

# ── Bind session-level hotkeys (^b prefix) ───────────────────────────────────
# ^b c: press Enter in current pane (continue Claude)
tmux bind c send-keys C-m

# ^b C: press Enter in ALL panes in current window (continue all)
tmux bind C set-window-option synchronize-panes on \; \
    send-keys C-m \; \
    set-window-option synchronize-panes off

# ^b r: restart Claude in current pane (Ctrl-C twice, then relaunch)
tmux bind r send-keys C-c \; \
    run-shell "sleep 0.3" \; \
    send-keys C-c \; \
    run-shell "sleep 0.3" \; \
    send-keys "$CLAUDE_CMD --continue" C-m

# ^b s: show status in a popup (requires tmux 3.2+)
tmux bind s display-popup -E -w 60 -h 15 "$SWARM_PATH -s $SESSION_NAME status"

# ── Enable silence monitoring for idle detection ────────────────────────────
# When a pane has no output for 15 seconds, tmux flags it in the status bar.
# This detects agents that finished working and went idle.
tmux set -t "$SESSION_NAME" -g monitor-silence 15

# Select the first window and first pane
FIRST_WINDOW="${PANE_GROUP[${SELECTED_PANES[0]}]}"
tmux select-window -t "${SESSION_NAME}:${FIRST_WINDOW}"
tmux select-pane -t "${SESSION_NAME}:${FIRST_WINDOW}.0"

ok "Session '${SESSION_NAME}' created with ${NUM_PANES} agents across ${NUM_WINDOWS} window(s)."

# Auto-start the watch loop in the background (drives border colors, tab title, alerts).
"$SWARM_PATH" -s "$SESSION_NAME" watch &>/dev/null &
disown

info "Attaching now... (Detach with Ctrl-b d)"
echo

exec tmux attach-session -t "$SESSION_NAME"
