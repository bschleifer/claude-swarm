#!/usr/bin/env bats
# Tests for parse_selection() — picker input parsing.

setup() {
    load 'test_helper/common'
    _common_setup

    # parse_selection requires PICKER_LABELS to know valid range.
    PICKER_LABELS=("Agent A" "Agent B" "Agent C")
}

teardown() {
    _common_teardown
}

@test "valid space-separated numbers" {
    run parse_selection "1 2 3"
    assert_success
}

@test "valid comma-separated numbers" {
    run parse_selection "1,2,3"
    assert_success
}

@test "valid single number" {
    run parse_selection "2"
    assert_success
}

@test "SELECTED_PICKER is populated correctly" {
    # Called without `run` to inspect side-effect on SELECTED_PICKER array.
    SELECTED_PICKER=()
    parse_selection "1 3"
    assert_equal "${#SELECTED_PICKER[@]}" 2
    assert_equal "${SELECTED_PICKER[0]}" 0
    assert_equal "${SELECTED_PICKER[1]}" 2
}

@test "invalid: non-numeric input" {
    run parse_selection "abc"
    assert_failure
}

@test "invalid: zero (out of range, 1-indexed)" {
    run parse_selection "0"
    assert_failure
}

@test "invalid: number exceeding range" {
    run parse_selection "999"
    assert_failure
}

@test "invalid: empty string" {
    run parse_selection ""
    assert_failure
}

@test "mixed valid and invalid" {
    run parse_selection "1 abc 3"
    assert_failure
}

# ── Edge cases ────────────────────────────────────────────────────────────

@test "duplicate numbers are preserved" {
    # Called without `run` to inspect side-effect on SELECTED_PICKER array.
    SELECTED_PICKER=()
    parse_selection "1 1"
    assert_equal "${#SELECTED_PICKER[@]}" 2
    assert_equal "${SELECTED_PICKER[0]}" 0
    assert_equal "${SELECTED_PICKER[1]}" 0
}

@test "mixed separators (spaces and commas)" {
    run parse_selection "1 2,3"
    assert_success
}

@test "empty PICKER_LABELS causes all numbers to be out of range" {
    PICKER_LABELS=()
    run parse_selection "1"
    assert_failure
}
