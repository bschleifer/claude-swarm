#!/usr/bin/env bats
# Tests for kill_existing_watch() — PID file management and process cleanup.

setup() {
    load 'test_helper/common'
    _common_setup
    setup_conductor_dir
}

teardown() {
    _common_teardown
}

@test "removes stale PID file (dead process)" {
    echo "99999" > "$WATCH_PID_FILE"
    [ -f "$WATCH_PID_FILE" ]
    kill_existing_watch "$SESSION_NAME"
    [ ! -f "$WATCH_PID_FILE" ]
}

@test "no-op when PID file does not exist" {
    rm -f "$WATCH_PID_FILE"
    run kill_existing_watch "$SESSION_NAME"
    assert_success
}

@test "removes PID file with empty content" {
    : > "$WATCH_PID_FILE"
    kill_existing_watch "$SESSION_NAME"
    [ ! -f "$WATCH_PID_FILE" ]
}

@test "kills running process and removes PID file" {
    # Start a background sleep process to kill
    sleep 300 &
    local bg_pid=$!

    echo "$bg_pid" > "$WATCH_PID_FILE"
    kill_existing_watch "$SESSION_NAME"

    # Process should be dead
    ! kill -0 "$bg_pid" 2>/dev/null
    # PID file should be removed
    [ ! -f "$WATCH_PID_FILE" ]
}

@test "handles non-numeric PID gracefully" {
    echo "not-a-pid" > "$WATCH_PID_FILE"
    run kill_existing_watch "$SESSION_NAME"
    assert_success
    [ ! -f "$WATCH_PID_FILE" ]
}
