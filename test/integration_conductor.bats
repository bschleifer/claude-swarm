#!/usr/bin/env bats
# Integration tests for conductor management functions.

setup() {
    load 'test_helper/common'
    _common_setup
    setup_conductor_dir

    # Put mock tmux on PATH for integration tests
    PATH="${BATS_TEST_DIRNAME}/mocks:${PATH}"
    export MOCK_TMUX_LOG="${BATS_TEST_TMPDIR}/tmux.log"
    : > "$MOCK_TMUX_LOG"
}

teardown() {
    _common_teardown
}

@test "generate_conductor_claude_md creates the file" {
    generate_conductor_claude_md
    [ -f "$CONDUCTOR_CLAUDE_MD" ]
}

@test "generated CLAUDE.md contains orchestrator instructions" {
    generate_conductor_claude_md
    grep -q "Conductor — Autonomous Agent Orchestrator" "$CONDUCTOR_CLAUDE_MD"
}

@test "generated CLAUDE.md contains action guidelines" {
    generate_conductor_claude_md
    grep -q "Actions You Can Take" "$CONDUCTOR_CLAUDE_MD"
    grep -q "Decision Guidelines" "$CONDUCTOR_CLAUDE_MD"
    grep -q "Logging" "$CONDUCTOR_CLAUDE_MD"
}

@test "pause flag toggle works" {
    # Initially no pause flag
    [ ! -f "$CONDUCTOR_PAUSE_FLAG" ]

    # Create pause flag
    mkdir -p "$(dirname "$CONDUCTOR_PAUSE_FLAG")"
    touch "$CONDUCTOR_PAUSE_FLAG"
    [ -f "$CONDUCTOR_PAUSE_FLAG" ]

    # Remove pause flag
    rm -f "$CONDUCTOR_PAUSE_FLAG"
    [ ! -f "$CONDUCTOR_PAUSE_FLAG" ]
}

@test "build_conductor_status produces valid markdown with mocked panes" {
    # Override discover_claude_panes for this test
    discover_claude_panes() {
        printf '%s\t%s\t%s\t%s\n' "sess:0.0" "test-agent" "IDLE" "/tmp/test"
    }
    export -f discover_claude_panes

    CONDUCTOR_PANE=""
    CONDUCTOR_SESSION=""

    build_conductor_status "$CONDUCTOR_STATUS"
    [ -f "$CONDUCTOR_STATUS" ]
    grep -q "# Agent Status Report" "$CONDUCTOR_STATUS"
    grep -q "## Agents Needing Attention" "$CONDUCTOR_STATUS"
    grep -q "## All Agent States" "$CONDUCTOR_STATUS"
    grep -q "test-agent" "$CONDUCTOR_STATUS"
}

@test "kill_existing_watch removes stale PID file" {
    echo "99999" > "$WATCH_PID_FILE"
    [ -f "$WATCH_PID_FILE" ]
    kill_existing_watch "$SESSION_NAME"
    [ ! -f "$WATCH_PID_FILE" ]
}

@test "mock tmux logs correct calls" {
    tmux has-session -t "test-session"
    tmux list-panes -s -t "test-session"

    grep -q "tmux has-session -t test-session" "$MOCK_TMUX_LOG"
    grep -q "tmux list-panes -s -t test-session" "$MOCK_TMUX_LOG"
}
