#!/usr/bin/env bats
# Tests for send_text() — sending commands to panes.

setup() {
    load 'test_helper/common'
    _common_setup
    SESSION_NAME="test-session"
}

teardown() {
    _common_teardown
}

@test "send_text calls tmux send-keys with correct target" {
    local captured_target="" captured_text=""
    tmux() {
        if [[ "$1" == "send-keys" ]]; then
            captured_target="$3"
            captured_text="$4"
        fi
    }
    export -f tmux

    send_text "0.0" "hello world"
    assert_equal "$captured_target" "test-session:0.0"
    assert_equal "$captured_text" "hello world"
}

@test "send_text uses SESSION_NAME in target" {
    local captured_target=""
    tmux() {
        if [[ "$1" == "send-keys" ]]; then
            captured_target="$3"
        fi
    }
    export -f tmux

    SESSION_NAME="my-swarm"
    send_text "1.2" "test"
    assert_equal "$captured_target" "my-swarm:1.2"
}

@test "send_text sends C-m after text" {
    local last_arg=""
    tmux() {
        if [[ "$1" == "send-keys" ]]; then
            last_arg="${@: -1}"
        fi
    }
    export -f tmux

    send_text "0.0" "test"
    assert_equal "$last_arg" "C-m"
}
