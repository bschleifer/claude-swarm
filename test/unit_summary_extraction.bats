#!/usr/bin/env bats
# Tests for extract_summary_text() — pure summary extraction logic.

setup() {
    load 'test_helper/common'
    _common_setup
}

teardown() {
    _common_teardown
}

@test "returns last meaningful line (bottom-up)" {
    local content="Line one
Line two
Line three"
    run extract_summary_text "$content" 60
    assert_output "Line three"
}

@test "skips blank lines" {
    local content="Meaningful line


"
    run extract_summary_text "$content" 60
    assert_output "Meaningful line"
}

@test "skips prompt-only lines" {
    local content="Some output
>
❯"
    run extract_summary_text "$content" 60
    assert_output "Some output"
}

@test "skips esc to interrupt lines" {
    local content="Actual content
esc to interrupt"
    run extract_summary_text "$content" 60
    assert_output "Actual content"
}

@test "skips ? for shortcuts lines" {
    local content="Real output
? for shortcuts"
    run extract_summary_text "$content" 60
    assert_output "Real output"
}

@test "skips ctrl+t to hide lines" {
    local content="Good content
ctrl+t to hide"
    run extract_summary_text "$content" 60
    assert_output "Good content"
}

@test "skips box-drawing characters" {
    local content="Important message
═══════════════════"
    run extract_summary_text "$content" 60
    assert_output "Important message"
}

@test "truncates to max_chars with ellipsis" {
    local content="This is a very long line that should be truncated because it exceeds the maximum character limit"
    run extract_summary_text "$content" 20
    assert_output "This is a very lo..."
}

@test "empty content → empty string" {
    run extract_summary_text "" 60
    assert_output ""
}

@test "all noise content → empty string" {
    local content=">
❯
esc to interrupt
? for shortcuts
═══════════════"
    run extract_summary_text "$content" 60
    assert_output ""
}

@test "content within max_chars is not truncated" {
    local content="Short line"
    run extract_summary_text "$content" 60
    assert_output "Short line"
}

@test "whitespace-only lines are skipped" {
    local content="Real content

   "
    run extract_summary_text "$content" 60
    assert_output "Real content"
}

# ── Edge cases ────────────────────────────────────────────────────────────

@test "max_chars=1 truncates without ellipsis" {
    local content="Hello world"
    run extract_summary_text "$content" 1
    assert_output "H"
}

@test "max_chars=3 truncates without ellipsis" {
    local content="Hello world"
    run extract_summary_text "$content" 3
    assert_output "Hel"
}

@test "max_chars=4 truncates with ellipsis" {
    local content="Hello world"
    run extract_summary_text "$content" 4
    assert_output "H..."
}

@test "content with tab characters" {
    local content=$'First line\n\tTabbed line'
    run extract_summary_text "$content" 60
    assert_output $'\tTabbed line'
}

@test "mixed box-drawing and real text picks real text" {
    local content="Real message
═══════════════
>
? for shortcuts"
    run extract_summary_text "$content" 60
    assert_output "Real message"
}
