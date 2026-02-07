#!/usr/bin/env bash
set -euo pipefail

# Require bash 4.3+ for namerefs (local -n) and associative arrays
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "Error: bash 4.3+ required (found ${BASH_VERSION})" >&2
    exit 1
fi

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
#   swarm conductor [start|stop|pause|resume|log]
#                                  Manage the autonomous conductor agent
###############################################################################

# ── Configuration ────────────────────────────────────────────────────────────
SESSION_NAME="claude-agents"
PROJECTS_DIR="$HOME/projects"
CLAUDE_CMD="claude"
PANES_PER_WINDOW=4

# Conductor configuration
CONDUCTOR_INTERVAL=30          # seconds between conductor triggers
CONDUCTOR_DIR="$HOME/.swarm"
CONDUCTOR_STATUS="$CONDUCTOR_DIR/status.md"
CONDUCTOR_LOG="$CONDUCTOR_DIR/conductor.log"
CONDUCTOR_CLAUDE_MD="$CONDUCTOR_DIR/conductor/CLAUDE.md"
CONDUCTOR_PAUSE_FLAG="$CONDUCTOR_DIR/conductor.paused"
CONDUCTOR_SESSION=""           # set at runtime; the session the conductor pane lives in
CONDUCTOR_PANE=""              # set at runtime; the conductor's pane target

# Path to this script (used for tmux keybindings and subcommand invocations)
SWARM_PATH="${SWARM_PATH:-$(realpath "$0" 2>/dev/null || echo "$0")}"

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
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info()  { printf '%s[info]%s  %s\n' "$CYAN" "$RESET" "$*"; }
ok()    { printf '%s[ok]%s    %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s[warn]%s  %s\n' "$YELLOW" "$RESET" "$*"; }
err()   { printf '%s[error]%s %s\n' "$RED" "$RESET" "$*" >&2; }

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
    local win_id win_name pstate _pane_id
    while IFS=$'\t' read -r win_id win_name; do
        # Strip any existing " (N idle)" suffix to get the base name.
        local base_name="${win_name% (*}"
        # Never rename the conductor window — it breaks grep-based detection.
        [[ "$base_name" == "conductor" ]] && continue
        local win_idle=0 win_total=0
        while IFS= read -r _pane_id; do
            win_total=$((win_total + 1))
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

# ── Extracted watch helpers ────────────────────────────────────────────────

# Scans all panes, applies hysteresis, sets @swarm_state, rings bell on transitions.
# Uses namerefs to return: idle_count, total_count, has_actionable, transitioned_panes.
# Relies on outer-scope associative arrays: prev_state, idle_confirm.
scan_pane_states() {
    local session="$1" conductor_pane="$2" conductor_active="$3"
    local -n _idle_count=$4 _total_count=$5 _has_actionable=$6 _transitioned=$7
    _idle_count=0; _total_count=0; _has_actionable=false; _transitioned=()

    local pane_target state prev
    while IFS= read -r pane_target; do
        # Skip conductor/dashboard panes — they're managed separately
        local _pane_name
        _pane_name=$(tmux show -p -t "${session}:${pane_target}" -v @swarm_name 2>/dev/null || echo "")
        [[ "$_pane_name" == "DASHBOARD" || "$_pane_name" == "CONDUCTOR" ]] && continue

        state=$(detect_pane_state "${session}:${pane_target}")
        prev="${prev_state[$pane_target]:-UNKNOWN}"

        # Hysteresis: require 2 consecutive IDLE readings before accepting WORKING→IDLE
        if [[ "$state" == "IDLE" && "$prev" == "WORKING" ]]; then
            idle_confirm["$pane_target"]=$(( ${idle_confirm[$pane_target]:-0} + 1 ))
            if (( ${idle_confirm[$pane_target]} < 2 )); then
                state="WORKING"  # not confirmed yet
            fi
        else
            idle_confirm["$pane_target"]=0
        fi

        _total_count=$((_total_count + 1))
        [[ "$state" == "IDLE" ]] && _idle_count=$((_idle_count + 1))

        tmux set -p -t "${session}:${pane_target}" @swarm_state "$state" 2>/dev/null || true

        # Track actionable (skip conductor pane)
        if [[ "$conductor_active" == "true" ]] && [[ "$pane_target" == "$conductor_pane" ]]; then
            :
        elif [[ "$state" == "IDLE" || "$state" == "EXITED" ]]; then
            _has_actionable=true
        fi

        # Bell on WORKING→IDLE transition
        if [[ "$prev" == "WORKING" && "$state" == "IDLE" ]]; then
            local client_tty
            client_tty=$(tmux list-clients -t "$session" -F '#{client_tty}' 2>/dev/null | head -1)
            if [[ -n "$client_tty" && -w "$client_tty" ]]; then
                printf '\a' > "$client_tty"
            fi
            _transitioned+=("$pane_target")
        fi

        # Track timestamp of state transitions for duration display
        if [[ "$state" != "$prev" ]]; then
            tmux set -p -t "${session}:${pane_target}" @swarm_state_since "$(date +%s)" 2>/dev/null || true
        fi

        prev_state["$pane_target"]="$state"
    done < <(get_panes)
}

# Returns 0 (should trigger) or 1 (skip).
should_trigger_conductor() {
    local has_actionable="$1" last_trigger="$2" interval="$3"
    local now
    now=$(date +%s)
    [[ "$has_actionable" == "true" ]] && (( now - last_trigger >= interval )) && return 0
    return 1
}

# Trigger the conductor when new agents need attention.
# Uses transition-based triggering: only fires when NEW agents become idle/exited.
CONDUCTOR_TRIGGER_FILE="$CONDUCTOR_DIR/.last_trigger"

# Build trigger.md with info about specific agents.
# Arg $1: output file, Arg $2: newline-separated "target\tname\tstate\tpath" lines
build_trigger_summary() {
    local outfile="$1" pane_lines="$2"
    local count=0
    {
        while IFS=$'\t' read -r target name state path; do
            [[ -z "$target" ]] && continue
            count=$((count + 1))
            local summary
            summary=$(extract_pane_summary "$target" 80)
            printf -- '- %s (%s) %s' "$name" "$target" "$state"
            [[ -n "$summary" ]] && printf ': %s' "$summary"
            printf '\n'
        done <<< "$pane_lines"
    } > "$outfile"
    echo "$count"
}

# Check if the conductor pane has an empty prompt (safe to inject text).
# Returns 0 if the prompt is empty, 1 if user is typing or pane is busy.
is_conductor_prompt_empty() {
    local session="$1" pane="$2"
    local last_lines
    last_lines=$(tmux capture-pane -p -t "${session}:${pane}" -S -3 2>/dev/null || echo "")
    # Check that the very last non-blank line is JUST a prompt character with nothing after it
    local last_line
    last_line=$(printf '%s\n' "$last_lines" | tac | while IFS= read -r l; do
        [[ -z "${l// /}" ]] && continue
        printf '%s' "$l"
        break
    done)
    # Match bare prompt: optional whitespace, then > or ❯, then optional whitespace, nothing else
    local _prompt_re='^[[:space:]]*(>|❯)[[:space:]]*$'
    [[ "$last_line" =~ $_prompt_re ]]
}

# Trigger the conductor for specific agents. If the user is actively typing,
# only writes to trigger-pending file (no text injection). If the prompt is
# empty, auto-sends the message.
# $1=session, $2=pane_lines (target\tname\tstate\tpath for NEW agents only)
trigger_conductor() {
    local session="$1" new_pane_lines="$2"
    local CONDUCTOR_PENDING="$CONDUCTOR_DIR/trigger-pending"
    if [[ -z "$CONDUCTOR_PANE" ]]; then return 1; fi

    local conductor_state
    conductor_state=$(detect_pane_state "${session}:${CONDUCTOR_PANE}")
    if [[ "$conductor_state" != "IDLE" ]]; then return 1; fi

    # Build a concise agent list
    local agent_names=""
    while IFS=$'\t' read -r target name state path; do
        [[ -z "$target" ]] && continue
        agent_names+="${name} (${state}), "
    done <<< "$new_pane_lines"
    agent_names="${agent_names%, }"

    # Always write status files so they're ready when the conductor checks
    build_conductor_status "$CONDUCTOR_STATUS"
    local trigger_summary="$CONDUCTOR_DIR/trigger.md"
    local agent_count
    agent_count=$(build_trigger_summary "$trigger_summary" "$new_pane_lines")

    # Write pending trigger file (conductor CLAUDE.md tells it to check this)
    {
        printf 'Agents needing attention (%s):\n' "$(date '+%H:%M:%S')"
        cat "$trigger_summary"
        printf '\nRead ~/.swarm/status.md for full captured output.\n'
    } > "$CONDUCTOR_PENDING"

    # Only inject text if the prompt is truly empty (user isn't typing)
    if is_conductor_prompt_empty "$session" "$CONDUCTOR_PANE"; then
        tmux send-keys -t "${session}:${CONDUCTOR_PANE}" C-u
        tmux send-keys -t "${session}:${CONDUCTOR_PANE}" \
            "Read ~/.swarm/trigger-pending — ${agent_count} agents need attention." C-m
        rm -f "$CONDUCTOR_PENDING"
        echo "[$(date '+%H:%M:%S')] TRIGGERED — ${agent_count} new: ${agent_names}" >> "$CONDUCTOR_LOG"
    else
        echo "[$(date '+%H:%M:%S')] PENDING — ${agent_count} new: ${agent_names} (user typing, wrote to trigger-pending)" >> "$CONDUCTOR_LOG"
    fi

    date +%s > "$CONDUCTOR_TRIGGER_FILE"
}

# Auto-focus: if exactly one pane transitioned WORKING→IDLE, select it.
# Skip if target is in a different window than the active one.
auto_focus_pane() {
    local session="$1"; shift
    local -a transitioned=("$@")
    if (( ${#transitioned[@]} == 1 )); then
        local target_pane="${transitioned[0]}"
        local target_win="${target_pane%%.*}"
        local active_win
        active_win=$(tmux display-message -t "$session" -p '#{window_index}' 2>/dev/null || echo "")
        if [[ -n "$active_win" && "$active_win" == "$target_win" ]]; then
            tmux select-pane -t "${session}:${target_pane}" 2>/dev/null || true
        fi
    fi
}

# Attach or switch to a tmux session, handling nested tmux correctly.
tmux_attach_or_switch() {
    local target="$1"
    if [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "$target" 2>/dev/null && exit 0
        unset TMUX  # fallback if switch-client fails
    fi
    exec tmux attach-session -t "$target"
}

# Kill any existing watch loop and start a new one in the background.
restart_watch() {
    kill_existing_watch
    "$SWARM_PATH" -s "$SESSION_NAME" watch &>/dev/null &
    disown
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
  conductor [start|stop|pause|resume|log]
                       Manage the autonomous conductor agent

Notifications:
  A background watcher monitors agent states. When an agent finishes and
  goes idle, the Windows Terminal taskbar flashes and the tmux window tab
  shows a ! marker. The watcher starts automatically with the session.

Tmux hotkeys (^b = Ctrl-b, then the key):
  ^b c                 Continue current pane (press Enter)
  ^b C                 Continue ALL panes in current window
  ^b r                 Restart Claude in current pane
  ^b s                 Show agent status popup
  ^b y                 Send "yes" to current pane (approve tool use)
  ^b N                 Send "no" to current pane (reject tool use)
  ^b L                 Show conductor decision log
  ^b P                 Pause/resume conductor

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
        printf '\n%sMultiple tmux sessions found:%s\n\n' "$BOLD" "$RESET"
        for i in "${!sessions[@]}"; do
            local pcount
            pcount=$(tmux list-panes -s -t "${sessions[$i]}" 2>/dev/null | wc -l)
            printf "  ${GREEN}%d.${RESET} %-30s ${YELLOW}(%d panes)${RESET}\n" \
                "$((i + 1))" "${sessions[$i]}" "$pcount"
        done
        echo
        printf '%sSelect session%s [number]: ' "$BOLD" "$RESET"
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

# Classify pane content into a state: IDLE, WORKING, or EXITED.
# Pure function — no tmux dependency. Takes the foreground command name and
# raw pane content; returns the state string.
classify_pane_content() {
    local cmd="$1" content="$2"
    # If the foreground process is bash/zsh/sh, Claude has exited.
    if [[ "$cmd" == "bash" || "$cmd" == "zsh" || "$cmd" == "sh" ]]; then
        echo "EXITED"; return
    fi
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

# Detect the state of a pane: IDLE, WORKING, or EXITED.
# Thin wrapper around classify_pane_content that fetches data from tmux.
detect_pane_state() {
    local target="$1"
    local cmd content
    cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || echo "")
    content=$(tmux capture-pane -p -t "$target" 2>/dev/null || echo "")
    classify_pane_content "$cmd" "$content"
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

# ── Helper: extract last meaningful line from content ─────────────────────────
# Pure function — no tmux dependency. Takes raw content string and max_chars.
# Walks bottom-up, skips noise (blank, prompt, status hints, box-drawing),
# truncates to max_chars.
extract_summary_text() {
    local content="$1" max_chars="${2:-60}"

    local line summary=""
    local prompt_re='^[[:space:]]*[>❯][[:space:]]*$'
    while IFS= read -r line; do
        [[ -z "${line// /}" ]] && continue
        [[ "$line" =~ $prompt_re ]] && continue
        [[ "$line" == *"esc to interrupt"* ]] && continue
        [[ "$line" == *"? for shortcuts"* ]] && continue
        [[ "$line" == *"ctrl+t to hide"* ]] && continue
        [[ "$line" =~ ^[[:space:]═─━┃│┌┐└┘├┤┬┴┼]+$ ]] && continue
        summary="$line"
        break
    done < <(printf '%s\n' "$content" | tac)

    if (( ${#summary} > max_chars )); then
        if (( max_chars > 3 )); then
            summary="${summary:0:$((max_chars - 3))}..."
        else
            summary="${summary:0:$max_chars}"
        fi
    fi
    printf '%s' "$summary"
}

# Thin wrapper: extract summary from a tmux pane.
extract_pane_summary() {
    local target="$1" max_chars="${2:-60}"
    local content
    content=$(tmux capture-pane -p -t "$target" -S -10 2>/dev/null || echo "")
    extract_summary_text "$content" "$max_chars"
}

# Extract multiple meaningful lines from pane content (bottom-up).
# Returns up to $2 lines (default 3), each truncated to $3 chars (default 100).
extract_pane_detail() {
    local target="$1" max_lines="${2:-3}" max_chars="${3:-100}"
    local content
    content=$(tmux capture-pane -p -t "$target" -S -50 2>/dev/null || echo "")

    local line collected=0
    local prompt_re='^[[:space:]]*[>❯][[:space:]]*$'
    while IFS= read -r line; do
        [[ -z "${line// /}" ]] && continue
        [[ "$line" =~ $prompt_re ]] && continue
        [[ "$line" == *"esc to interrupt"* ]] && continue
        [[ "$line" == *"? for shortcuts"* ]] && continue
        [[ "$line" == *"ctrl+t to hide"* ]] && continue
        [[ "$line" == *"bypass permissions"* ]] && continue
        [[ "$line" =~ ^[[:space:]═─━┃│┌┐└┘├┤┬┴┼]+$ ]] && continue
        if (( ${#line} > max_chars )); then
            line="${line:0:$((max_chars - 3))}..."
        fi
        printf '%s\n' "$line"
        collected=$((collected + 1))
        (( collected >= max_lines )) && break
    done < <(printf '%s\n' "$content" | tac)
}

# Format a duration from epoch timestamp to human-readable (e.g. "3m", "1h 5m").
format_duration() {
    local since="$1"
    [[ -z "$since" || "$since" == "0" ]] && return
    local now elapsed_s
    now=$(date +%s)
    elapsed_s=$(( now - since ))
    (( elapsed_s < 0 )) && return
    if (( elapsed_s < 60 )); then
        printf '%ds' "$elapsed_s"
    elif (( elapsed_s < 3600 )); then
        printf '%dm' $(( elapsed_s / 60 ))
    else
        printf '%dh %dm' $(( elapsed_s / 3600 )) $(( (elapsed_s % 3600) / 60 ))
    fi
}

# ── Helper: discover Claude panes across ALL tmux sessions ───────────────────
# Returns: TARGET\tNAME\tSTATE\tPATH (one line per pane)
discover_claude_panes() {
    local session pane_target
    while IFS= read -r session; do
        while IFS= read -r pane_target; do
            local full_target="${session}:${pane_target}"
            local state
            state=$(detect_pane_state "$full_target")
            local pane_path
            pane_path=$(tmux display-message -p -t "$full_target" '#{pane_current_path}' 2>/dev/null || echo "")
            local name
            name=$(tmux show -p -t "$full_target" -v @swarm_name 2>/dev/null) || continue
            [[ -z "$name" ]] && continue
            [[ "$name" == "DASHBOARD" || "$name" == "CONDUCTOR" ]] && continue
            printf '%s\t%s\t%s\t%s\n' "$full_target" "$name" "$state" "$pane_path"
        done < <(tmux list-panes -s -t "$session" -F '#{window_index}.#{pane_index}' 2>/dev/null)
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}

# ── Helper: build status file for the conductor ─────────────────────────────
build_conductor_status() {
    local status_file="$1"
    mkdir -p "$(dirname "$status_file")"

    local pane_data
    pane_data=$(discover_claude_panes)

    {
        printf '# Agent Status Report\n'
        printf 'Generated: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"

        printf '## Agents Needing Attention\n\n'
        local has_actionable=false
        if [[ -n "$pane_data" ]]; then
            while IFS=$'\t' read -r target name state path; do
                [[ -z "$target" ]] && continue
                [[ "$state" == "WORKING" ]] && continue
                # Skip the conductor's own pane
                # CONDUCTOR/DASHBOARD already filtered by discover_claude_panes()
                has_actionable=true
                printf '### %s (%s) — %s\n' "$name" "$target" "$state"
                local since
                since=$(tmux show -p -t "$target" -v @swarm_state_since 2>/dev/null || echo "")
                if [[ -n "$since" ]]; then
                    local elapsed_min=$(( ($(date +%s) - since) / 60 ))
                    printf 'In this state for: %d minutes\n' "$elapsed_min"
                fi
                printf 'Working directory: %s\n' "$path"
                printf 'Last output:\n```\n'
                tmux capture-pane -p -t "$target" -S -20 2>/dev/null || echo "(unable to capture)"
                printf '```\n\n'
                printf 'Recent errors (if any):\n```\n'
                tmux capture-pane -p -t "$target" -S -50 2>/dev/null | grep -i -E 'error|fail|denied|rejected|warning' | tail -5 || true
                printf '```\n\n'
            done <<< "$pane_data"
        fi

        if [[ "$has_actionable" != "true" ]]; then
            printf 'All agents are currently working. No action needed.\n'
        fi

        printf '\n## All Agent States\n\n'
        printf '| Target | Name | State |\n'
        printf '|--------|------|-------|\n'
        if [[ -n "$pane_data" ]]; then
            while IFS=$'\t' read -r target name state path; do
                [[ -z "$target" ]] && continue
                # CONDUCTOR/DASHBOARD already filtered by discover_claude_panes()
                printf '| %s | %s | %s |\n' "$target" "$name" "$state"
            done <<< "$pane_data"
        fi

        # Include recent conductor decisions for context
        printf '\n## Recent Conductor Actions (last 20)\n\n'
        if [[ -f "$CONDUCTOR_LOG" ]]; then
            tail -20 "$CONDUCTOR_LOG"
        else
            printf 'No previous actions.\n'
        fi
    } > "$status_file"
}

# ── Helper: generate CLAUDE.md for the conductor instance ────────────────────
generate_conductor_claude_md() {
    mkdir -p "$(dirname "$CONDUCTOR_CLAUDE_MD")"
    cat > "$CONDUCTOR_CLAUDE_MD" << 'CONDUCTOR_EOF'
# Conductor — Autonomous Agent Orchestrator

You are the conductor of a swarm of Claude Code agents running in tmux panes.
Your job is to keep ALL agents productive at ALL times by acting autonomously.
You must be proactive — never wait to be told when agents need help.

## Your Core Loop

After EVERY response, you MUST do this:
1. Read `~/.swarm/status.md` for the full status of all agents
2. Check `~/.swarm/trigger-pending` — if it exists, agents need attention NOW
3. For each agent that is IDLE or EXITED, read their captured output and act
4. Log your actions to `~/.swarm/conductor.log`
5. After acting, read `~/.swarm/status.md` AGAIN to check for new changes

**You will also receive automatic messages** when new agents become idle/exit.
But do NOT rely solely on these messages — always self-check status.md.

## Reading Agent Output

To see what an agent is doing or asking, use `tmux capture-pane`:
```bash
tmux capture-pane -p -t "SESSION:WIN.PANE" -S -50
```
This gives you the last 50 lines. Use this to understand EXACTLY what the agent needs.

The status file at `~/.swarm/status.md` also includes captured output for each agent.

## Actions You Can Take

### For IDLE agents (waiting at the `>` prompt):
- **Continue**: Agent finished a step and is waiting. Press Enter.
  `tmux send-keys -t "SESSION:WIN.PANE" C-m`
- **Approve tool use**: Agent is asking permission (you'll see a Y/N prompt). Send "y".
  `tmux send-keys -t "SESSION:WIN.PANE" "y" C-m`
- **Reject tool use**: Agent is asking about something risky. Send "n".
  `tmux send-keys -t "SESSION:WIN.PANE" "n" C-m`
- **Send a message**: Agent needs guidance. Type a SHORT, single-line message.
  `tmux send-keys -t "SESSION:WIN.PANE" "your message here" C-m`

### For EXITED agents (Claude process ended):
- **Restart**: Relaunch Claude to continue.
  `tmux send-keys -t "SESSION:WIN.PANE" "claude --continue" C-m`

## Decision Guidelines

1. **Capture and read the agent's output** before deciding. Use `tmux capture-pane`.
2. **Approve tool use** (send "y") for: reading files, running tests, editing code,
   installing dependencies, git operations. Most tool use is safe — approve quickly.
3. **Reject** (send "n") only for: deleting files outside project, destructive commands,
   accessing secrets, unknown network requests.
4. **Continue** (send Enter) when the agent finished and is just waiting.
5. **Send guidance** when the agent seems stuck or confused.
6. **Restart** exited agents immediately.
7. **Act fast** — idle agents are wasted time. Don't deliberate excessively.

## CRITICAL Rules

- **NEVER send keys to your own pane** (the conductor pane)
- **NEVER paste images** — tmux cannot handle image data. If you need to reference
  an image or screenshot, pass the FILE PATH as text (e.g., `/tmp/screenshot.png`)
- **Keep messages single-line** — multi-line text breaks in tmux send-keys
- **Always use `C-m` (Enter)** at the end of send-keys to submit
- **NEVER send `C-u`** before a message — only the watch loop does that
- **Approve liberally** — agents are working on code, most operations are safe

## Logging

After EVERY action, log it:
```bash
echo "[$(date '+%H:%M:%S')] ACTION target=SESSION:WIN.PANE agent=NAME — reason" >> ~/.swarm/conductor.log
```

## Self-Check Reminder

**After you finish processing agents, ALWAYS read status.md one more time.**
New agents may have become idle while you were working. Never stop checking.
If all agents are WORKING, say "All agents working" and wait for the next trigger.
CONDUCTOR_EOF
}

# ── Subcommand: status ───────────────────────────────────────────────────────
cmd_status() {
    local live=false all_sessions=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --live|--watch|-w) live=true ;;
            --all|-a) all_sessions=true ;;
        esac; shift
    done

    if $live; then cmd_status_live "$all_sessions"; return; fi

    if ! $all_sessions; then
        require_session
    fi

    # Print agent table
    _status_print_agents "$all_sessions"

    # Conductor section
    local conductor_session="swarm-conductor"
    if tmux has-session -t "$conductor_session" 2>/dev/null; then
        printf '\n%sConductor:%s ' "$BOLD" "$RESET"
        if [[ -f "$CONDUCTOR_PAUSE_FLAG" ]]; then
            printf '%sPAUSED%s\n' "$YELLOW" "$RESET"
        else
            printf '%sACTIVE%s\n' "$GREEN" "$RESET"
        fi
        if [[ -f "$CONDUCTOR_LOG" ]]; then
            printf '\n%sLast 5 actions:%s\n' "$BOLD" "$RESET"
            tail -5 "$CONDUCTOR_LOG"
        fi
    fi

    printf '\n%sHotkeys:%s ^b c:cont  C:all  y:yes  N:no  r:restart  L:log  P:pause\n' "$BOLD" "$RESET"

    echo
    # Wait for keypress so tmux popups don't vanish immediately.
    if [[ -t 0 ]]; then
        printf '%sPress any key to close%s' "$BOLD" "$RESET"
        read -rsn1
    fi
}

# Print a single agent entry with multi-line detail.
# Args: idx, name, state, target (tmux pane target)
_print_agent_entry() {
    local idx="$1" name="$2" state="$3" target="$4"
    local color
    case "$state" in
        IDLE)    color="$GREEN" ;;
        WORKING) color="$YELLOW" ;;
        EXITED)  color="$RED" ;;
        *)       color="$RESET" ;;
    esac

    # Duration in current state
    local since duration_str=""
    since=$(tmux show -p -t "$target" -v @swarm_state_since 2>/dev/null || echo "")
    if [[ -n "$since" ]]; then
        duration_str=$(format_duration "$since")
        [[ -n "$duration_str" ]] && duration_str=" (${duration_str})"
    fi

    # Working directory
    local pane_path
    pane_path=$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || echo "")
    local dir_display=""
    [[ -n "$pane_path" ]] && dir_display="  ~/$(basename "$pane_path")"

    # Header line: index, name, state, duration, dir
    printf "  ${CYAN}%d${RESET}  ${BOLD}%-20s${RESET} ${color}%-8s${RESET}%s${CYAN}%s${RESET}\n" \
        "$idx" "$name" "$state" "$duration_str" "$dir_display"

    # Detail lines: more for working agents (they have active output to show)
    local max_detail=3
    [[ "$state" == "WORKING" ]] && max_detail=5
    local detail_lines
    detail_lines=$(extract_pane_detail "$target" "$max_detail" 100)
    if [[ -n "$detail_lines" ]]; then
        local -a lines=()
        while IFS= read -r line; do
            lines+=("$line")
        done <<< "$detail_lines"
        # Print in reverse (detail is bottom-up, we want chronological)
        for (( i=${#lines[@]}-1; i>=0; i-- )); do
            printf '     %s│%s %s\n' "$color" "$RESET" "${lines[$i]}"
        done
    fi
    echo
}

# Print the agent table for status display.
# $1 = "true" to show all sessions, "false" for current session only.
_status_print_agents() {
    local all_sessions="$1"

    if [[ "$all_sessions" == "true" ]]; then
        printf '\n%sAgent Status%s  (all sessions)\n\n' "$BOLD" "$RESET"
        local pane_data current_session=""
        pane_data=$(discover_claude_panes)
        if [[ -n "$pane_data" ]]; then
            local idx=0
            while IFS=$'\t' read -r target name state path; do
                [[ -z "$target" ]] && continue
                local sess="${target%%:*}"
                if [[ "$sess" != "$current_session" ]]; then
                    current_session="$sess"
                    printf '  %s── %s ──%s\n' "$CYAN" "$sess" "$RESET"
                fi
                _print_agent_entry "$idx" "$name" "$state" "$target"
                idx=$((idx + 1))
            done <<< "$pane_data"
        fi
    else
        printf '\n%sAgent Status%s  (session: %s%s%s)\n\n' "$BOLD" "$RESET" "$CYAN" "$SESSION_NAME" "$RESET"
        local idx=0
        while IFS= read -r pane_target; do
            local pane_path
            pane_path=$(tmux display-message -p -t "${SESSION_NAME}:${pane_target}" '#{pane_current_path}' 2>/dev/null || echo "")
            local title
            title=$(basename "$pane_path" 2>/dev/null || echo "pane-${idx}")
            local state
            state=$(detect_pane_state "${SESSION_NAME}:${pane_target}")
            _print_agent_entry "$idx" "$title" "$state" "${SESSION_NAME}:${pane_target}"
            idx=$((idx + 1))
        done < <(get_panes)
    fi
    echo
}

# Live auto-refreshing status dashboard.
cmd_status_live() {
    local all_sessions="$1"

    if [[ "$all_sessions" != "true" ]]; then
        require_session
    fi

    # Hide cursor, restore on exit
    tput civis 2>/dev/null || true
    trap 'tput cnorm 2>/dev/null || true; exit 0' INT TERM EXIT

    while true; do
        clear
        printf '%s╔══ SWARM DASHBOARD ══╗%s  %s\n\n' "$BOLD" "$RESET" "$(date '+%H:%M:%S')"

        _status_print_agents "$all_sessions"

        # Conductor section
        local conductor_session="swarm-conductor"
        printf '%s── Conductor ──%s\n' "$BOLD" "$RESET"
        if tmux has-session -t "$conductor_session" 2>/dev/null; then
            # Conductor status
            printf '  Status: '
            if [[ -f "$CONDUCTOR_PAUSE_FLAG" ]]; then
                printf '%sPAUSED%s' "$YELLOW" "$RESET"
            else
                printf '%sACTIVE%s' "$GREEN" "$RESET"
            fi

            # Watch process health
            local cw_pid_file="$CONDUCTOR_DIR/conductor-watch.pid"
            if [[ -f "$cw_pid_file" ]]; then
                local cw_pid
                cw_pid=$(cat "$cw_pid_file" 2>/dev/null)
                if [[ -n "$cw_pid" ]] && kill -0 "$cw_pid" 2>/dev/null; then
                    printf '  |  Watch: %srunning%s (pid %s)' "$GREEN" "$RESET" "$cw_pid"
                else
                    printf '  |  Watch: %sDEAD%s' "$RED" "$RESET"
                fi
            else
                printf '  |  Watch: %sNOT STARTED%s' "$RED" "$RESET"
            fi

            # Last trigger time
            if [[ -f "$CONDUCTOR_TRIGGER_FILE" ]]; then
                local last_t
                last_t=$(cat "$CONDUCTOR_TRIGGER_FILE" 2>/dev/null)
                if [[ -n "$last_t" ]]; then
                    local ago
                    ago=$(format_duration "$last_t")
                    [[ -n "$ago" ]] && printf '  |  Last trigger: %s ago' "$ago"
                fi
            fi
            printf '\n'

            # Conductor Claude state
            local cond_state
            cond_state=$(detect_pane_state "${conductor_session}:0.0" 2>/dev/null || echo "UNKNOWN")
            local cond_color
            case "$cond_state" in
                IDLE)    cond_color="$GREEN" ;;
                WORKING) cond_color="$YELLOW" ;;
                *)       cond_color="$RED" ;;
            esac
            printf '  Claude: %s%s%s' "$cond_color" "$cond_state" "$RESET"
            if [[ "$cond_state" == "WORKING" ]]; then
                local cond_summary
                cond_summary=$(extract_pane_summary "${conductor_session}:0.0" 80)
                [[ -n "$cond_summary" ]] && printf ' — %s' "$cond_summary"
            fi
            printf '\n'

            # Recent log entries
            if [[ -f "$CONDUCTOR_LOG" ]]; then
                printf '\n%s  Recent actions:%s\n' "$BOLD" "$RESET"
                tail -10 "$CONDUCTOR_LOG" | while IFS= read -r logline; do
                    printf '  %s\n' "$logline"
                done
            fi
        else
            printf '  %sNOT RUNNING%s  (start: swarm conductor start)\n' "$RED" "$RESET"
        fi

        printf '\n%s(refreshing every 5s — Ctrl-C to exit)%s\n' "$CYAN" "$RESET"
        sleep 5
    done
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

# ── Subcommand: conductor ───────────────────────────────────────────────────
cmd_conductor() {
    local subcmd="${1:-start}"
    case "$subcmd" in
        start)  conductor_start ;;
        stop)   conductor_stop ;;
        watch)  cmd_conductor_watch ;;
        pause)  mkdir -p "$CONDUCTOR_DIR"; touch "$CONDUCTOR_PAUSE_FLAG"; ok "Conductor paused" ;;
        resume) rm -f "$CONDUCTOR_PAUSE_FLAG"; ok "Conductor resumed" ;;
        log)    [[ -f "$CONDUCTOR_LOG" ]] && cat "$CONDUCTOR_LOG" || echo "No log yet." ;;
        *)      err "Usage: swarm conductor [start|stop|pause|resume|log]"; exit 1 ;;
    esac
}

conductor_start() {
    local conductor_session="swarm-conductor"
    mkdir -p "$CONDUCTOR_DIR/conductor"
    generate_conductor_claude_md

    # Kill existing conductor if running
    if tmux has-session -t "$conductor_session" 2>/dev/null; then
        warn "Conductor session already exists."
        printf '  %s(a)%sttach  |  %s(k)%sill & restart  |  %s(q)%suit: ' \
            "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET"
        read -r choice
        case "$choice" in
            a|A) tmux_attach_or_switch "$conductor_session"; return ;;
            k|K) tmux kill-session -t "$conductor_session" ;;
            *)   return ;;
        esac
    fi

    # Create standalone conductor session with Claude agent
    tmux new-session -d -s "$conductor_session" -n "conductor" -c "$CONDUCTOR_DIR/conductor"
    tmux set -t "$conductor_session" automatic-rename off
    tmux set -t "$conductor_session" allow-rename off

    tmux set -p -t "${conductor_session}:conductor.0" @swarm_name "CONDUCTOR"
    tmux set -p -t "${conductor_session}:conductor.0" @swarm_state "WORKING"
    tmux send-keys -t "${conductor_session}:conductor.0" \
        "claude --dangerously-skip-permissions" C-m

    # Split: add live dashboard pane on the right
    tmux split-window -h -t "${conductor_session}:conductor.0" -l 55% \
        -c "$CONDUCTOR_DIR"
    tmux set -p -t "${conductor_session}:conductor.1" @swarm_name "DASHBOARD"
    tmux set -p -t "${conductor_session}:conductor.1" @swarm_state "WORKING"
    tmux send-keys -t "${conductor_session}:conductor.1" \
        "'${SWARM_PATH}' status --live --all" C-m
    tmux select-pane -t "${conductor_session}:conductor.0"

    # Visual styling for the conductor session
    tmux set -t "$conductor_session" pane-border-status top
    tmux set -t "$conductor_session" pane-border-lines heavy
    tmux set -t "$conductor_session" pane-border-style "fg=#585858"
    tmux set -t "$conductor_session" pane-active-border-style "fg=#ff8700,bold"
    tmux set -t "$conductor_session" pane-border-format \
        '#[fg=#ff8700]#[bold] #{@swarm_name} #[default]'
    tmux set -t "$conductor_session" status-style "bg=#1c1c1c,fg=#808080"
    tmux set -t "$conductor_session" status-left "#[fg=#ff8700,bold] CONDUCTOR #[default] "
    tmux set -t "$conductor_session" status-right "#[fg=#585858]P:pause  L:log "

    # Kill any stale conductor watch and start fresh
    local cw_pid_file="$CONDUCTOR_DIR/conductor-watch.pid"
    if [[ -f "$cw_pid_file" ]]; then
        local old_pid
        old_pid=$(cat "$cw_pid_file" 2>/dev/null)
        [[ -n "$old_pid" ]] && kill "$old_pid" 2>/dev/null || true
        rm -f "$cw_pid_file"
    fi
    rm -f "$CONDUCTOR_TRIGGER_FILE"
    "$SWARM_PATH" conductor watch &>/dev/null &
    disown

    ok "Conductor started in session '$conductor_session'"
    info "Attach: tmux attach -t $conductor_session"

    # Attach/switch to the conductor session
    tmux_attach_or_switch "$conductor_session"
}

conductor_stop() {
    local conductor_session="swarm-conductor"
    if ! tmux has-session -t "$conductor_session" 2>/dev/null; then
        err "No conductor running"
        exit 1
    fi

    # Kill the conductor watch process
    local pid_file="$CONDUCTOR_DIR/conductor-watch.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        rm -f "$pid_file"
    fi

    tmux kill-session -t "$conductor_session"
    rm -f "$CONDUCTOR_PAUSE_FLAG"

    ok "Conductor stopped"
}

# ── Conductor watch loop (global, cross-session monitoring) ──────────────────
# Transition-based: only triggers when NEW agents become idle/exited.
# Tracks which panes have been reported to the conductor; clears them when
# they go back to WORKING (so a re-idle will trigger again).
cmd_conductor_watch() {
    local conductor_session="swarm-conductor"
    local CONDUCTOR_WATCH_PID_FILE="$CONDUCTOR_DIR/conductor-watch.pid"
    local CONDUCTOR_PENDING="$CONDUCTOR_DIR/trigger-pending"
    mkdir -p "$CONDUCTOR_DIR"

    # Clean up stale PID file from dead processes
    if [[ -f "$CONDUCTOR_WATCH_PID_FILE" ]]; then
        local existing_pid
        existing_pid=$(cat "$CONDUCTOR_WATCH_PID_FILE" 2>/dev/null)
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$CONDUCTOR_WATCH_PID_FILE"
    fi

    echo $$ > "$CONDUCTOR_WATCH_PID_FILE"
    trap 'rm -f "$CONDUCTOR_WATCH_PID_FILE" "$CONDUCTOR_TRIGGER_FILE"' EXIT
    rm -f "$CONDUCTOR_TRIGGER_FILE"

    # Track which panes we've already told the conductor about.
    # Key: pane target, Value: state we reported (IDLE or EXITED).
    declare -A reported_panes

    while tmux has-session -t "$conductor_session" 2>/dev/null; do
        local pane_data
        pane_data=$(discover_claude_panes)

        # Find NEW actionable panes (transitioned to IDLE/EXITED since last check)
        local new_pane_lines="" has_new=false
        declare -A current_actionable

        if [[ -n "$pane_data" ]]; then
            while IFS=$'\t' read -r target name state path; do
                [[ -z "$target" ]] && continue
                if [[ "$state" == "IDLE" || "$state" == "EXITED" ]]; then
                    current_actionable["$target"]="$state"
                    # Is this a NEW actionable pane we haven't reported?
                    if [[ -z "${reported_panes[$target]:-}" ]] || [[ "${reported_panes[$target]}" != "$state" ]]; then
                        has_new=true
                        new_pane_lines+="${target}"$'\t'"${name}"$'\t'"${state}"$'\t'"${path}"$'\n'
                    fi
                fi
            done <<< "$pane_data"
        fi

        # Clear reported status for panes that went back to WORKING
        for key in "${!reported_panes[@]}"; do
            if [[ -z "${current_actionable[$key]:-}" ]]; then
                unset 'reported_panes[$key]'
            fi
        done

        # Resolve conductor pane each tick
        CONDUCTOR_PANE=$(tmux display-message -t "${conductor_session}:conductor.0" \
            -p '#{window_index}.#{pane_index}' 2>/dev/null || echo "")

        if [[ -n "$CONDUCTOR_PANE" ]] && [[ ! -f "$CONDUCTOR_PAUSE_FLAG" ]]; then
            local conductor_state_now
            conductor_state_now=$(detect_pane_state "${conductor_session}:${CONDUCTOR_PANE}")

            # Trigger for NEW actionable panes
            if [[ "$has_new" == "true" ]]; then
                if trigger_conductor "$conductor_session" "$new_pane_lines"; then
                    # Mark these panes as reported only on successful delivery/pending
                    while IFS=$'\t' read -r target name state path; do
                        [[ -z "$target" ]] && continue
                        reported_panes["$target"]="$state"
                    done <<< "$new_pane_lines"
                fi
                # If trigger failed (conductor busy), don't mark — we'll retry next tick
            fi

            # When conductor is IDLE: deliver pending triggers or re-check unreported panes
            if [[ "$conductor_state_now" == "IDLE" ]]; then
                # Retry pending triggers
                if [[ -f "$CONDUCTOR_PENDING" ]] && is_conductor_prompt_empty "$conductor_session" "$CONDUCTOR_PANE"; then
                    local pending_count
                    pending_count=$(grep -c '^- ' "$CONDUCTOR_PENDING" 2>/dev/null || echo "0")
                    tmux send-keys -t "${conductor_session}:${CONDUCTOR_PANE}" C-u
                    tmux send-keys -t "${conductor_session}:${CONDUCTOR_PANE}" \
                        "Read ~/.swarm/trigger-pending — ${pending_count} agents need attention." C-m
                    rm -f "$CONDUCTOR_PENDING"
                    echo "[$(date '+%H:%M:%S')] DELIVERED pending trigger (${pending_count} agents)" >> "$CONDUCTOR_LOG"
                # If no pending file but there are actionable panes we haven't triggered for
                elif [[ ! -f "$CONDUCTOR_PENDING" ]] && [[ ${#current_actionable[@]} -gt 0 ]]; then
                    # Check if any actionable panes are not yet reported
                    local unreported_lines="" has_unreported=false
                    for key in "${!current_actionable[@]}"; do
                        if [[ -z "${reported_panes[$key]:-}" ]]; then
                            has_unreported=true
                            # Look up name and path from pane_data
                            local _name _path
                            _name=$(echo "$pane_data" | awk -F'\t' -v t="$key" '$1==t{print $2}')
                            _path=$(echo "$pane_data" | awk -F'\t' -v t="$key" '$1==t{print $4}')
                            unreported_lines+="${key}"$'\t'"${_name}"$'\t'"${current_actionable[$key]}"$'\t'"${_path}"$'\n'
                        fi
                    done
                    if [[ "$has_unreported" == "true" ]]; then
                        if trigger_conductor "$conductor_session" "$unreported_lines"; then
                            while IFS=$'\t' read -r target name state path; do
                                [[ -z "$target" ]] && continue
                                reported_panes["$target"]="$state"
                            done <<< "$unreported_lines"
                        fi
                    fi
                fi
            fi
        fi

        unset current_actionable
        sleep "$WATCH_INTERVAL"
    done
}

# ── Watch PID file helpers ───────────────────────────────────────────────────
kill_existing_watch() {
    local session="${1:-$SESSION_NAME}"
    local pidfile="$CONDUCTOR_DIR/watch-${session}.pid"
    if [[ -f "$pidfile" ]]; then
        local old_pid
        old_pid=$(cat "$pidfile" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            kill "$old_pid" 2>/dev/null
            # Wait for it to actually die (up to 3 seconds)
            local i=0
            while kill -0 "$old_pid" 2>/dev/null && (( i++ < 6 )); do
                sleep 0.5
            done
        fi
        rm -f "$pidfile"
    fi
}

# ── Subcommand: watch (background notification watcher) ─────────────────────
# Polls pane states every few seconds. When a pane transitions from WORKING to
# IDLE, sends a bell to the CLIENT terminal (not the pane) so Windows Terminal
# flashes the taskbar without corrupting Claude's TUI.
WATCH_INTERVAL=5

cmd_watch() {
    require_session

    # Per-session PID file so multiple swarm sessions don't stomp each other
    local WATCH_PID_FILE="$CONDUCTOR_DIR/watch-${SESSION_NAME}.pid"

    # Write PID file and set up cleanup trap
    mkdir -p "$CONDUCTOR_DIR"
    kill_existing_watch "$SESSION_NAME"
    # Atomic PID write — fails if another process beat us
    ( set -C; echo $$ > "$WATCH_PID_FILE" ) 2>/dev/null || {
        # Another watcher won the race; exit silently
        return 0
    }
    trap '[[ -f "$WATCH_PID_FILE" && "$(cat "$WATCH_PID_FILE" 2>/dev/null)" == "$$" ]] && rm -f "$WATCH_PID_FILE"' EXIT

    # Track previous state of each pane so we only notify on transitions.
    declare -A prev_state
    # Require 2 consecutive IDLE readings before transitioning WORKING→IDLE.
    declare -A idle_confirm

    while tmux has-session -t "$SESSION_NAME" 2>/dev/null; do
        local idle_count=0 total_count=0 has_actionable=false
        local -a transitioned_panes=()

        scan_pane_states "$SESSION_NAME" "" "false" \
            idle_count total_count has_actionable transitioned_panes

        auto_focus_pane "$SESSION_NAME" "${transitioned_panes[@]}"

        # Update Windows Terminal tab title and tmux window names
        update_terminal_title "$SESSION_NAME" "$idle_count" "$total_count"
        update_window_names "$SESSION_NAME"

        sleep "$WATCH_INTERVAL"
    done
}

# ── Helper: parse a space-separated string of numbers into SELECTED_PICKER ──
# Returns 0 on success, 1 on error.
parse_selection() {
    local input="$1"
    input="${input//,/ }"
    SELECTED_PICKER=()
    set -f  # disable globbing for unquoted $input expansion
    for token in $input; do
        if ! [[ "$token" =~ ^[0-9]+$ ]]; then
            set +f
            err "Invalid input: '$token' — enter numbers, 'all', or press Enter."
            return 1
        fi
        local idx=$((token - 1))
        if (( idx < 0 || idx >= ${#PICKER_LABELS[@]} )); then
            set +f
            err "Out of range: $token (valid: 1-${#PICKER_LABELS[@]})"
            return 1
        fi
        SELECTED_PICKER+=("$idx")
    done
    set +f
    [[ ${#SELECTED_PICKER[@]} -gt 0 ]]
}

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
    mapfile -t agents < <(printf '%s\n' "${agents[@]}" | sort)
    printf '%s\n' "${agents[@]}"
}

# ── Build unified entries (groups + individual repos) ────────────────────────
# Populates PICKER_LABELS, PICKER_META, PICKER_PANES, PANE_LABELS, PANE_PATHS,
# PANE_BANNERS, PANE_GROUP from AGENTS and AGENT_GROUPS.
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

# ── Main entry point (skipped when sourced for testing) ─────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

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
        conductor) shift; cmd_conductor "$@"; exit 0 ;;
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

# ── Auto-detect + build entries (functions defined above source guard) ──────
if [[ ${#AGENTS[@]} -eq 0 ]]; then
    mapfile -t AGENTS < <(detect_agents)
fi

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

build_entries

if [[ ${#PICKER_LABELS[@]} -eq 0 ]]; then
    err "No git repositories found in $PROJECTS_DIR"
    exit 1
fi

# ── Interactive picker ───────────────────────────────────────────────────────
printf '\n%sClaude Code Agent Monitor%s\n\n' "$BOLD" "$RESET"

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
elif [[ -n "$PRESELECT" ]]; then
    # Numbers passed on command line (e.g. swarm 2 or swarm 1 3)
    if ! parse_selection "$PRESELECT"; then
        exit 1
    fi
else
    while true; do
        printf '%sSelect agents%s [enter numbers, '\''all'\'', or press Enter for all]: ' "$BOLD" "$RESET"
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
    auto_name=$(echo "$auto_name" | tr '[:upper:]' '[:lower:]' | tr ' &' '-' | tr -d ".:'\"" | sed 's/--*/-/g; s/^-//; s/-$//')
    [[ -z "$auto_name" ]] && auto_name="swarm"
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
    printf '  %s(a)%sttach  |  %s(k)%sill & restart  |  %s(q)%suit: ' "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET"
    read -r choice
    case "$choice" in
        a|A)
            info "Attaching to existing session..."
            tmux_attach_or_switch "$SESSION_NAME"
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

for si in "${!SELECTED_PANES[@]}"; do
    pane_idx="${SELECTED_PANES[$si]}"
    local_pane=$(( si % PANES_PER_WINDOW ))
    entry_label="${PANE_LABELS[$pane_idx]}"
    entry_path="${PANE_PATHS[$pane_idx]}"
    entry_banner="${PANE_BANNERS[$pane_idx]}"

    # Start of a new window
    if [[ $local_pane -eq 0 ]]; then
        WINDOW_NAME="${PANE_GROUP[$pane_idx]}"

        if $FIRST; then
            tmux new-session -d -s "$SESSION_NAME" -n "$WINDOW_NAME" -c "$entry_path"
            # Prevent tmux from auto-renaming windows during the build loop
            tmux set -t "$SESSION_NAME" automatic-rename off
            tmux set -t "$SESSION_NAME" allow-rename off
            FIRST=false
        else
            tmux new-window -t "$SESSION_NAME" -n "$WINDOW_NAME" -c "$entry_path"
        fi
        # Capture the actual window index for reliable targeting (avoids
        # ambiguity when multiple windows share the same name).
        CURRENT_WIN_IDX=$(tmux display-message -t "${SESSION_NAME}:${WINDOW_NAME}" -p '#{window_index}')
    else
        # Additional pane in the current window — target by index, not name
        tmux split-window -t "${SESSION_NAME}:${CURRENT_WIN_IDX}" -c "$entry_path"
        tmux select-layout -t "${SESSION_NAME}:${CURRENT_WIN_IDX}" tiled
    fi

    # Set pane title (shows in border via pane-border-status)
    tmux select-pane -t "${SESSION_NAME}:${CURRENT_WIN_IDX}.${local_pane}" -T "$entry_label"

    # Initialize per-pane user options (drives dynamic border coloring).
    # @swarm_name is used instead of pane_title because Claude's TUI overwrites it.
    tmux set -p -t "${SESSION_NAME}:${CURRENT_WIN_IDX}.${local_pane}" @swarm_name "$entry_label"
    tmux set -p -t "${SESSION_NAME}:${CURRENT_WIN_IDX}.${local_pane}" @swarm_state "WORKING"

    # Send startup commands
    send_to_pane "$SESSION_NAME" "$CURRENT_WIN_IDX" "$local_pane" \
        "clear && printf '${entry_banner}\n' && ${CLAUDE_CMD}"
done

# ── Visual styling (borders, status bar) ─────────────────────────────────────
# Heavy borders with state-colored labels
tmux set -t "$SESSION_NAME" pane-border-status top
tmux set -t "$SESSION_NAME" pane-border-lines heavy
tmux set -t "$SESSION_NAME" pane-border-indicators arrows

# Pane background: blue tint on active pane only
tmux set -t "$SESSION_NAME" window-active-style "bg=#0d1b30"

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
BORDER_FMT+='#[fg=#00afff]#[bold] #{@swarm_name} [ IDLE - needs input ]#[default],'
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
tmux set -t "$SESSION_NAME" status-right "#[fg=#585858]^b c:cont  C:all  y:yes  N:no  r:restart  s:status  n/p:win  z:zoom "
tmux set -t "$SESSION_NAME" status-right-length 100
tmux set -t "$SESSION_NAME" window-status-format " #I:#W "
tmux set -t "$SESSION_NAME" window-status-current-format "#[fg=#1c1c1c]#[bg=#00afff]#[bold] #I:#W #[default]"

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

# ^b y: send "yes" to current pane (approve tool use)
tmux bind y send-keys "yes" C-m

# ^b N: send "no" to current pane (reject tool use)
# Note: ^b n is tmux's next-window — we use uppercase N to avoid conflict.
tmux bind N send-keys "no" C-m

# ^b s: show status in a popup (requires tmux 3.2+)
tmux bind s display-popup -E -w 110 -h 30 "'${SWARM_PATH}' -s '${SESSION_NAME}' status"

# ^b L: show conductor log in a popup
tmux bind L display-popup -E -w 100 -h 25 "tail -f '$HOME/.swarm/conductor.log' 2>/dev/null || { echo 'No conductor log yet.'; echo; echo 'Press any key to close'; read -rsn1; }"

# ^b P: toggle conductor pause
tmux bind P run-shell "if [ -f '$HOME/.swarm/conductor.paused' ]; then rm -f '$HOME/.swarm/conductor.paused' && tmux display-message 'Conductor RESUMED'; else touch '$HOME/.swarm/conductor.paused' && tmux display-message 'Conductor PAUSED'; fi"

# ── Enable silence monitoring for idle detection ────────────────────────────
# When a pane has no output for 15 seconds, tmux flags it in the status bar.
# This detects agents that finished working and went idle.
tmux set -t "$SESSION_NAME" monitor-silence 15

# Select the first window and first pane
tmux select-window -t "${SESSION_NAME}:0"
tmux select-pane -t "${SESSION_NAME}:0.0"

ok "Session '${SESSION_NAME}' created with ${NUM_PANES} agents across ${NUM_WINDOWS} window(s)."

# Auto-start the watch loop in the background (drives border colors, tab title, alerts).
restart_watch

info "Attaching now... (Detach with Ctrl-b d)"
echo

tmux_attach_or_switch "$SESSION_NAME"

fi # end source guard
