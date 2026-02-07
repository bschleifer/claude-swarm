#!/usr/bin/env bats
# Tests for update_terminal_title() — terminal tab title updates.

setup() {
    load 'test_helper/common'
    _common_setup
}

teardown() {
    _common_teardown
}

@test "all working: spinner advances and title is written" {
    tmux() {
        case "$1" in
            list-clients) echo "/dev/null" ;;
        esac
    }
    export -f tmux

    SPINNER_IDX=0
    update_terminal_title "test-session" 0 4
    # Spinner should have advanced from 0 to 1
    assert_equal "$SPINNER_IDX" 1
}

@test "spinner index advances on each call" {
    tmux() {
        case "$1" in
            list-clients) echo "/dev/null" ;;
        esac
    }
    export -f tmux

    SPINNER_IDX=0
    update_terminal_title "test-session" 0 4
    assert_equal "$SPINNER_IDX" 1

    update_terminal_title "test-session" 0 4
    assert_equal "$SPINNER_IDX" 2
}

@test "spinner wraps around at array length" {
    tmux() {
        case "$1" in
            list-clients) echo "/dev/null" ;;
        esac
    }
    export -f tmux

    SPINNER_IDX=$(( ${#SPINNER_FRAMES[@]} - 1 ))
    update_terminal_title "test-session" 0 4
    assert_equal "$SPINNER_IDX" 0
}

@test "idle count > 0: no spinner advancement" {
    tmux() {
        case "$1" in
            list-clients) echo "/dev/null" ;;
        esac
    }
    export -f tmux

    SPINNER_IDX=3
    update_terminal_title "test-session" 2 4
    # Spinner should NOT advance when there are idle panes
    assert_equal "$SPINNER_IDX" 3
}

@test "no client TTY: returns early without error" {
    tmux() {
        case "$1" in
            list-clients) echo "" ;;
        esac
    }
    export -f tmux

    SPINNER_IDX=0
    # Must call directly (not run) to check SPINNER_IDX side-effect
    update_terminal_title "test-session" 0 4
    # Spinner should NOT have advanced since we returned early
    assert_equal "$SPINNER_IDX" 0
}

@test "list-clients failure: returns early without error" {
    tmux() {
        case "$1" in
            list-clients) return 1 ;;
        esac
    }
    export -f tmux

    SPINNER_IDX=5
    run update_terminal_title "test-session" 2 4
    assert_success
}
