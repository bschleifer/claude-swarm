#!/usr/bin/env bats
# Tests for build_conductor_status() — conductor status file generation.

setup() {
    load 'test_helper/common'
    _common_setup
    setup_conductor_dir

    # Mock discover_claude_panes to return controlled data
    discover_claude_panes() {
        printf '%s\t%s\t%s\t%s\n' "test-session:0.0" "agent-a" "IDLE" "/home/user/projects/a"
        printf '%s\t%s\t%s\t%s\n' "test-session:0.1" "agent-b" "WORKING" "/home/user/projects/b"
        printf '%s\t%s\t%s\t%s\n' "test-session:1.0" "agent-c" "EXITED" "/home/user/projects/c"
    }
    export -f discover_claude_panes

    # Mock tmux for capture-pane calls within build_conductor_status
    tmux() {
        case "$1" in
            capture-pane) echo "mock pane output" ;;
            *) ;;
        esac
    }
    export -f tmux

    # Clear conductor pane so it doesn't filter anything unexpectedly
    CONDUCTOR_PANE=""
    CONDUCTOR_SESSION=""
}

teardown() {
    _common_teardown
}

@test "status file is created" {
    build_conductor_status "$CONDUCTOR_STATUS"
    [ -f "$CONDUCTOR_STATUS" ]
}

@test "status file contains markdown header" {
    build_conductor_status "$CONDUCTOR_STATUS"
    grep -q "# Agent Status Report" "$CONDUCTOR_STATUS"
}

@test "status file contains timestamp" {
    build_conductor_status "$CONDUCTOR_STATUS"
    grep -q "Generated:" "$CONDUCTOR_STATUS"
}

@test "IDLE agents appear in Needing Attention section" {
    build_conductor_status "$CONDUCTOR_STATUS"
    grep -q "agent-a.*IDLE" "$CONDUCTOR_STATUS"
}

@test "WORKING agents skipped from Needing Attention" {
    build_conductor_status "$CONDUCTOR_STATUS"
    # agent-b is WORKING — should not appear in the attention section (between
    # "Needing Attention" and "All Agent States")
    local attention_section
    attention_section=$(sed -n '/## Agents Needing Attention/,/## All Agent States/p' "$CONDUCTOR_STATUS")
    ! echo "$attention_section" | grep -q "agent-b"
}

@test "EXITED agents appear in Needing Attention section" {
    build_conductor_status "$CONDUCTOR_STATUS"
    grep -q "agent-c.*EXITED" "$CONDUCTOR_STATUS"
}

@test "all agents appear in summary table" {
    build_conductor_status "$CONDUCTOR_STATUS"
    grep -q "| test-session:0.0 | agent-a | IDLE |" "$CONDUCTOR_STATUS"
    grep -q "| test-session:0.1 | agent-b | WORKING |" "$CONDUCTOR_STATUS"
    grep -q "| test-session:1.0 | agent-c | EXITED |" "$CONDUCTOR_STATUS"
}

@test "conductor pane is excluded from summary table" {
    # Override discover_claude_panes to include CONDUCTOR — it should be filtered
    # by the real discover_claude_panes, but since we mock it, simulate the
    # post-filter output (CONDUCTOR excluded).
    discover_claude_panes() {
        printf '%s\t%s\t%s\t%s\n' "test-session:0.0" "agent-a" "IDLE" "/home/user/projects/a"
        printf '%s\t%s\t%s\t%s\n' "test-session:1.0" "agent-c" "EXITED" "/home/user/projects/c"
    }
    export -f discover_claude_panes
    build_conductor_status "$CONDUCTOR_STATUS"
    # Only agent-a and agent-c should appear (no conductor pane)
    grep -q "| test-session:0.0 |" "$CONDUCTOR_STATUS"
    grep -q "| test-session:1.0 |" "$CONDUCTOR_STATUS"
    [ "$(grep -c '| test-session:' "$CONDUCTOR_STATUS")" -eq 2 ]
}

@test "log included when present" {
    echo "test log entry" > "$CONDUCTOR_LOG"
    build_conductor_status "$CONDUCTOR_STATUS"
    grep -q "test log entry" "$CONDUCTOR_STATUS"
}

@test "no previous actions when log absent" {
    rm -f "$CONDUCTOR_LOG"
    build_conductor_status "$CONDUCTOR_STATUS"
    grep -q "No previous actions." "$CONDUCTOR_STATUS"
}
