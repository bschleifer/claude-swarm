#!/usr/bin/env bats
# Tests for classify_pane_content() — pure state detection logic.

setup() {
    load 'test_helper/common'
    _common_setup
}

teardown() {
    _common_teardown
}

# ── EXITED states ──────────────────────────────────────────────────────────

@test "bash command → EXITED" {
    run classify_pane_content "bash" "some content"
    assert_output "EXITED"
}

@test "zsh command → EXITED" {
    run classify_pane_content "zsh" ""
    assert_output "EXITED"
}

@test "sh command → EXITED" {
    run classify_pane_content "sh" "$ "
    assert_output "EXITED"
}

# ── WORKING states ─────────────────────────────────────────────────────────

@test "esc to interrupt → WORKING" {
    run classify_pane_content "node" "Processing files...
esc to interrupt"
    assert_output "WORKING"
}

@test "both esc to interrupt AND prompt → WORKING (esc wins)" {
    run classify_pane_content "node" "> previous prompt
esc to interrupt
>
? for shortcuts"
    assert_output "WORKING"
}

@test "empty content with non-shell cmd → WORKING" {
    run classify_pane_content "node" ""
    assert_output "WORKING"
}

@test "random output with non-shell cmd → WORKING" {
    run classify_pane_content "claude" "Loading model...
Initializing..."
    assert_output "WORKING"
}

# ── IDLE states ────────────────────────────────────────────────────────────

@test "> prompt → IDLE" {
    run classify_pane_content "node" "Done.
>"
    assert_output "IDLE"
}

@test "❯ prompt → IDLE" {
    run classify_pane_content "node" "Completed.
❯"
    assert_output "IDLE"
}

@test "? for shortcuts → IDLE" {
    run classify_pane_content "node" "? for shortcuts
Type your message..."
    assert_output "IDLE"
}

@test "> prompt with leading whitespace → IDLE" {
    run classify_pane_content "node" "   > "
    assert_output "IDLE"
}

# ── Non-shell commands should NOT produce EXITED ───────────────────────────

@test "node command does not return EXITED" {
    run classify_pane_content "node" "> prompt"
    assert_output "IDLE"
}

@test "python command does not return EXITED" {
    run classify_pane_content "python" ""
    assert_output "WORKING"
}

@test "claude command does not return EXITED" {
    run classify_pane_content "claude" "> waiting"
    assert_output "IDLE"
}

# ── Edge cases ────────────────────────────────────────────────────────────

@test "esc to interrupt at start of content → WORKING" {
    run classify_pane_content "node" "esc to interrupt
Some output below"
    assert_output "WORKING"
}

@test "content with ANSI escape codes around prompt → WORKING (grep sees raw escapes)" {
    local content=$'\033[32m>\033[0m '
    run classify_pane_content "node" "$content"
    # ANSI escapes prevent grep from matching the bare > prompt
    assert_output "WORKING"
}

@test "dash command is not treated as shell (not EXITED)" {
    run classify_pane_content "dash" "some content"
    assert_output "WORKING"
}

@test "empty cmd with empty content → WORKING" {
    run classify_pane_content "" ""
    assert_output "WORKING"
}
