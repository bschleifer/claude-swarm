#!/usr/bin/env bats
# Tests for resolve_pane_arg() — pane argument resolution.

setup() {
    load 'test_helper/common'
    _common_setup

    # Set a valid session name
    SESSION_NAME="test-session"
}

teardown() {
    _common_teardown
}

@test "all returns all panes" {
    get_panes() {
        printf '0.0\n0.1\n1.0\n'
    }
    export -f get_panes

    run resolve_pane_arg "all"
    assert_success
    assert_line -n 0 "0.0"
    assert_line -n 1 "0.1"
    assert_line -n 2 "1.0"
}

@test "numeric arg returns Nth pane (0-indexed)" {
    get_panes() {
        printf '0.0\n0.1\n1.0\n'
    }
    export -f get_panes
    get_pane_count() { echo 3; }
    export -f get_pane_count

    run resolve_pane_arg "1"
    assert_success
    assert_output "0.1"
}

@test "first pane (index 0) works" {
    get_panes() {
        printf '0.0\n0.1\n'
    }
    export -f get_panes
    get_pane_count() { echo 2; }
    export -f get_pane_count

    run resolve_pane_arg "0"
    assert_success
    assert_output "0.0"
}

@test "out-of-bounds number produces error" {
    get_panes() {
        printf '0.0\n0.1\n'
    }
    export -f get_panes
    get_pane_count() { echo 2; }
    export -f get_pane_count

    run resolve_pane_arg "5"
    assert_failure
    assert_output --partial "does not exist"
}

@test "non-numeric arg produces error" {
    run resolve_pane_arg "abc"
    assert_failure
    assert_output --partial "Invalid pane number"
}

@test "empty arg defaults to all" {
    get_panes() {
        printf '0.0\n0.1\n'
    }
    export -f get_panes

    run resolve_pane_arg ""
    assert_success
    assert_line -n 0 "0.0"
    assert_line -n 1 "0.1"
}

@test "no arg defaults to all" {
    get_panes() {
        printf '0.0\n'
    }
    export -f get_panes

    run resolve_pane_arg
    assert_success
    assert_output "0.0"
}

@test "boundary: last valid pane index" {
    get_panes() {
        printf '0.0\n0.1\n0.2\n'
    }
    export -f get_panes
    get_pane_count() { echo 3; }
    export -f get_pane_count

    run resolve_pane_arg "2"
    assert_success
    assert_output "0.2"
}
