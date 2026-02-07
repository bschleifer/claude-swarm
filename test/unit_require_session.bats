#!/usr/bin/env bats
# Tests for require_session() — session detection and selection.

setup() {
    load 'test_helper/common'
    _common_setup
}

teardown() {
    _common_teardown
}

@test "existing session: returns immediately" {
    SESSION_NAME="my-session"
    tmux() {
        case "$1" in
            has-session) return 0 ;;
        esac
    }
    export -f tmux

    run require_session
    assert_success
}

@test "no sessions: exits with error" {
    SESSION_NAME="nonexistent"
    tmux() {
        case "$1" in
            has-session) return 1 ;;
            list-sessions) echo "" ;;
        esac
    }
    export -f tmux

    run require_session
    assert_failure
    assert_output --partial "No tmux sessions"
}

@test "single session: auto-selects it" {
    SESSION_NAME="nonexistent"
    tmux() {
        case "$1" in
            has-session) return 1 ;;
            list-sessions) echo "found-session" ;;
        esac
    }
    export -f tmux

    # Can't use `run` because we need to check SESSION_NAME side-effect
    require_session
    assert_equal "$SESSION_NAME" "found-session"
}

@test "has-session called with correct target" {
    SESSION_NAME="test-sess"
    local checked_target=""
    tmux() {
        case "$1" in
            has-session)
                checked_target="$3"
                return 0
                ;;
        esac
    }
    export -f tmux

    require_session
    assert_equal "$checked_target" "test-sess"
}
