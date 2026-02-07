#!/usr/bin/env bats
# Integration tests for subcommands: cmd_status, cmd_continue, cmd_send, cmd_restart, cmd_kill.
# Uses the mock tmux binary on PATH with per-flag env vars.

setup() {
    load 'test_helper/common'
    _common_setup
    setup_conductor_dir

    # Put mock tmux on PATH for integration tests
    PATH="${BATS_TEST_DIRNAME}/mocks:${PATH}"
    export MOCK_TMUX_LOG="${BATS_TEST_TMPDIR}/tmux.log"
    : > "$MOCK_TMUX_LOG"

    SESSION_NAME="test-session"
    export MOCK_TMUX_HAS_SESSION=0
}

teardown() {
    _common_teardown
}

# ── cmd_status ────────────────────────────────────────────────────────────

@test "cmd_status displays formatted output" {
    export MOCK_TMUX_LIST_PANES="0.0"
    export MOCK_TMUX_DISPLAY_MSG="bash"
    export MOCK_TMUX_DISPLAY_MSG_CMD="bash"
    export MOCK_TMUX_DISPLAY_MSG_PATH="/home/user/projects/test"
    export MOCK_TMUX_CAPTURE_PANE="some output"

    # Pipe to avoid the "press any key" prompt (stdin not a tty)
    run cmd_status
    assert_success
    assert_output --partial "Agent Status"
    assert_output --partial "EXITED"
}

@test "cmd_status shows session name" {
    export MOCK_TMUX_LIST_PANES="0.0"
    export MOCK_TMUX_DISPLAY_MSG="bash"
    export MOCK_TMUX_DISPLAY_MSG_CMD="bash"
    export MOCK_TMUX_DISPLAY_MSG_PATH="/home/user/projects/test"

    run cmd_status
    assert_success
    assert_output --partial "test-session"
}

@test "cmd_status shows pane directory as name" {
    export MOCK_TMUX_LIST_PANES="0.0"
    export MOCK_TMUX_DISPLAY_MSG_CMD="node"
    export MOCK_TMUX_DISPLAY_MSG_PATH="/home/user/projects/my-project"
    export MOCK_TMUX_CAPTURE_PANE="> "

    run cmd_status
    assert_success
    assert_output --partial "my-project"
}

# ── cmd_continue ──────────────────────────────────────────────────────────

@test "cmd_continue sends to idle panes" {
    export MOCK_TMUX_LIST_PANES="0.0"
    export MOCK_TMUX_DISPLAY_MSG="node"
    export MOCK_TMUX_DISPLAY_MSG_CMD="node"
    export MOCK_TMUX_DISPLAY_MSG_PATH="/tmp/test"
    export MOCK_TMUX_CAPTURE_PANE="> "

    run cmd_continue "all"
    assert_success
    assert_output --partial "Continued"
    grep -q "send-keys" "$MOCK_TMUX_LOG"
}

@test "cmd_continue restarts exited panes" {
    export MOCK_TMUX_LIST_PANES="0.0"
    export MOCK_TMUX_DISPLAY_MSG="bash"
    export MOCK_TMUX_DISPLAY_MSG_CMD="bash"
    export MOCK_TMUX_DISPLAY_MSG_PATH="/tmp/test"
    export MOCK_TMUX_CAPTURE_PANE="$ "

    run cmd_continue "all"
    assert_success
    assert_output --partial "Restarted"
}

@test "cmd_continue skips working panes" {
    export MOCK_TMUX_LIST_PANES="0.0"
    export MOCK_TMUX_DISPLAY_MSG="node"
    export MOCK_TMUX_DISPLAY_MSG_CMD="node"
    export MOCK_TMUX_DISPLAY_MSG_PATH="/tmp/test"
    export MOCK_TMUX_CAPTURE_PANE="esc to interrupt"

    run cmd_continue "all"
    assert_success
    assert_output --partial "Skipping"
}

@test "cmd_continue with no idle panes shows info message" {
    export MOCK_TMUX_LIST_PANES="0.0"
    export MOCK_TMUX_DISPLAY_MSG="node"
    export MOCK_TMUX_DISPLAY_MSG_CMD="node"
    export MOCK_TMUX_DISPLAY_MSG_PATH="/tmp/test"
    export MOCK_TMUX_CAPTURE_PANE="esc to interrupt"

    run cmd_continue "all"
    assert_success
    assert_output --partial "No idle or exited"
}

# ── cmd_send ──────────────────────────────────────────────────────────────

@test "cmd_send routes message to pane" {
    export MOCK_TMUX_LIST_PANES="0.0"
    export MOCK_TMUX_DISPLAY_MSG="bash"
    export MOCK_TMUX_DISPLAY_MSG_PATH="/tmp/test"

    run cmd_send "all" "hello world"
    assert_success
    assert_output --partial "Sent to"
    grep -q "send-keys" "$MOCK_TMUX_LOG"
}

@test "cmd_send treats first non-numeric arg as message" {
    export MOCK_TMUX_LIST_PANES="0.0"
    export MOCK_TMUX_DISPLAY_MSG="bash"
    export MOCK_TMUX_DISPLAY_MSG_PATH="/tmp/test"

    run cmd_send "hello world"
    assert_success
    assert_output --partial "Sent to"
}

@test "cmd_send errors on missing message" {
    run cmd_send
    assert_failure
    assert_output --partial "Usage"
}

# ── cmd_restart ───────────────────────────────────────────────────────────

@test "cmd_restart sends Ctrl-C and relaunches" {
    export MOCK_TMUX_LIST_PANES="0.0"
    export MOCK_TMUX_DISPLAY_MSG="bash"
    export MOCK_TMUX_DISPLAY_MSG_PATH="/tmp/test"

    run cmd_restart "all"
    assert_success
    assert_output --partial "Restarted"
    # Should have send-keys calls (Ctrl-C + relaunch)
    grep -q "send-keys" "$MOCK_TMUX_LOG"
}

@test "cmd_restart errors on missing arg" {
    run cmd_restart
    assert_failure
    assert_output --partial "Usage"
}

# ── cmd_kill ──────────────────────────────────────────────────────────────

@test "cmd_kill kills the session" {
    run cmd_kill
    assert_success
    assert_output --partial "killed"
    grep -q "kill-session" "$MOCK_TMUX_LOG"
}

# ── cmd_conductor ─────────────────────────────────────────────────────────

@test "cmd_conductor pause creates pause flag" {
    run cmd_conductor "pause"
    assert_success
    assert_output --partial "paused"
    [ -f "$CONDUCTOR_PAUSE_FLAG" ]
}

@test "cmd_conductor resume removes pause flag" {
    mkdir -p "$(dirname "$CONDUCTOR_PAUSE_FLAG")"
    touch "$CONDUCTOR_PAUSE_FLAG"
    run cmd_conductor "resume"
    assert_success
    assert_output --partial "resumed"
    [ ! -f "$CONDUCTOR_PAUSE_FLAG" ]
}

@test "cmd_conductor log shows log content" {
    echo "test log entry" > "$CONDUCTOR_LOG"
    run cmd_conductor "log"
    assert_success
    assert_output --partial "test log entry"
}

@test "cmd_conductor log shows message when no log" {
    rm -f "$CONDUCTOR_LOG"
    run cmd_conductor "log"
    assert_success
    assert_output --partial "No log yet"
}

@test "cmd_conductor invalid subcommand fails" {
    run cmd_conductor "invalid"
    assert_failure
    assert_output --partial "Usage"
}
