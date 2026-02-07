#!/usr/bin/env bash
# Shared test setup for BATS tests.
# Sources swarm.sh (safe due to source-only guard) and provides mock helpers.

_common_setup() {
    # Project root
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

    # Load helpers using absolute paths (load is relative to BATS_TEST_DIRNAME)
    load "${PROJECT_ROOT}/test/test_helper/bats-support/load"
    load "${PROJECT_ROOT}/test/test_helper/bats-assert/load"

    # Override SWARM_PATH before sourcing to avoid realpath "$0" issues
    export SWARM_PATH="${PROJECT_ROOT}/swarm.sh"

    # Source swarm.sh — the source guard prevents the main entry point from running
    source "${PROJECT_ROOT}/swarm.sh"

    # Point conductor dirs at temp space
    CONDUCTOR_DIR="${BATS_TEST_TMPDIR}/swarm"
    CONDUCTOR_STATUS="${CONDUCTOR_DIR}/status.md"
    CONDUCTOR_LOG="${CONDUCTOR_DIR}/conductor.log"
    CONDUCTOR_CLAUDE_MD="${CONDUCTOR_DIR}/conductor/CLAUDE.md"
    CONDUCTOR_PAUSE_FLAG="${CONDUCTOR_DIR}/conductor.paused"
    # Per-session PID file (matches kill_existing_watch's convention)
    WATCH_PID_FILE="${CONDUCTOR_DIR}/watch-${SESSION_NAME}.pid"

    mkdir -p "$CONDUCTOR_DIR"
}

# Override tmux with a bash function for unit tests.
# Usage: mock_tmux_fn "output_string"
# All tmux calls will return the given string.
mock_tmux_fn() {
    local output="${1:-}"
    tmux() {
        echo "$output"
    }
    export -f tmux
}

_common_teardown() {
    # Unset function overrides
    unset -f tmux 2>/dev/null || true
    unset -f discover_claude_panes 2>/dev/null || true
    unset -f detect_pane_state 2>/dev/null || true
    unset -f get_panes 2>/dev/null || true
    unset -f get_pane_count 2>/dev/null || true

    # Reset global arrays that tests may mutate
    SELECTED_PICKER=()
    PICKER_LABELS=()
    PICKER_META=()
    PICKER_PANES=()
    PANE_LABELS=()
    PANE_PATHS=()
    PANE_BANNERS=()
    PANE_GROUP=()

    # Reset global scalars
    SESSION_NAME="claude-agents"
    CONDUCTOR_PANE=""
    CONDUCTOR_SESSION=""
    SPINNER_IDX=0

    teardown_conductor_dir
}

setup_conductor_dir() {
    mkdir -p "${CONDUCTOR_DIR}/conductor"
}

teardown_conductor_dir() {
    rm -rf "${CONDUCTOR_DIR}" 2>/dev/null || true
}
