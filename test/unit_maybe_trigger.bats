#!/usr/bin/env bats
# Tests for trigger_conductor() — conductor trigger logic.

setup() {
    load 'test_helper/common'
    _common_setup
    setup_conductor_dir
    rm -f "$CONDUCTOR_TRIGGER_FILE"
    rm -f "$CONDUCTOR_DIR/trigger-pending"
}

teardown() {
    _common_teardown
}

@test "skips when CONDUCTOR_PANE is empty" {
    CONDUCTOR_PANE=""
    local send_keys_called=false

    tmux() {
        case "$1" in
            send-keys) send_keys_called=true ;;
            *) ;;
        esac
    }
    export -f tmux
    detect_pane_state() { echo "IDLE"; }
    export -f detect_pane_state
    discover_claude_panes() { echo ""; }
    export -f discover_claude_panes

    # trigger_conductor returns 1 when skipping
    run trigger_conductor "test-session" "$(printf '%s\t%s\t%s\t%s\n' 'sess:0.0' 'agent-a' 'IDLE' '/tmp/a')"
    assert_failure
    [ ! -f "$CONDUCTOR_TRIGGER_FILE" ]
}

@test "skips when conductor is not idle" {
    CONDUCTOR_PANE="1.0"
    local send_keys_called=false

    detect_pane_state() { echo "WORKING"; }
    export -f detect_pane_state

    tmux() {
        case "$1" in
            send-keys) send_keys_called=true ;;
            *) ;;
        esac
    }
    export -f tmux

    # trigger_conductor returns 1 when conductor is busy
    run trigger_conductor "test-session" "$(printf '%s\t%s\t%s\t%s\n' 'sess:0.0' 'agent-a' 'IDLE' '/tmp/a')"
    assert_failure
    [ ! -f "$CONDUCTOR_TRIGGER_FILE" ]
}

@test "triggers when conductor is idle and prompt is empty" {
    CONDUCTOR_PANE="1.0"
    local send_keys_called=false

    detect_pane_state() { echo "IDLE"; }
    export -f detect_pane_state

    discover_claude_panes() { echo ""; }
    export -f discover_claude_panes

    tmux() {
        case "$1" in
            send-keys) send_keys_called=true ;;
            capture-pane) printf '>\n' ;;
            *) ;;
        esac
    }
    export -f tmux

    trigger_conductor "test-session" "$(printf '%s\t%s\t%s\t%s\n' 'sess:0.0' 'agent-a' 'IDLE' '/tmp/a')"
    assert_equal "$send_keys_called" "true"
    [ -f "$CONDUCTOR_TRIGGER_FILE" ]
    local ts
    ts=$(cat "$CONDUCTOR_TRIGGER_FILE")
    (( ts > 0 ))
}

@test "writes pending file when prompt is not empty" {
    CONDUCTOR_PANE="1.0"
    local send_keys_called=false

    detect_pane_state() { echo "IDLE"; }
    export -f detect_pane_state

    discover_claude_panes() { echo ""; }
    export -f discover_claude_panes

    tmux() {
        case "$1" in
            send-keys) send_keys_called=true ;;
            capture-pane) printf 'some user text\n' ;;
            *) ;;
        esac
    }
    export -f tmux

    trigger_conductor "test-session" "$(printf '%s\t%s\t%s\t%s\n' 'sess:0.0' 'agent-a' 'IDLE' '/tmp/a')"
    # Should NOT have sent keys (user is typing)
    assert_equal "$send_keys_called" "false"
    # But should have written the pending file
    [ -f "$CONDUCTOR_DIR/trigger-pending" ]
    grep -q "agent-a" "$CONDUCTOR_DIR/trigger-pending"
}

@test "builds conductor status file on trigger" {
    CONDUCTOR_PANE="1.0"

    detect_pane_state() { echo "IDLE"; }
    export -f detect_pane_state

    discover_claude_panes() {
        printf '%s\t%s\t%s\t%s\n' "sess:0.0" "agent-a" "IDLE" "/tmp/a"
    }
    export -f discover_claude_panes

    tmux() {
        case "$1" in
            capture-pane) printf '>\n' ;;
            *) ;;
        esac
    }
    export -f tmux

    trigger_conductor "test-session" "$(printf '%s\t%s\t%s\t%s\n' 'sess:0.0' 'agent-a' 'IDLE' '/tmp/a')"
    [ -f "$CONDUCTOR_STATUS" ]
    grep -q "Agent Status Report" "$CONDUCTOR_STATUS"
}

@test "sends C-u before message to clear stale input" {
    CONDUCTOR_PANE="1.0"
    local tmux_calls=""

    detect_pane_state() { echo "IDLE"; }
    export -f detect_pane_state
    discover_claude_panes() { echo ""; }
    export -f discover_claude_panes

    tmux() {
        case "$1" in
            capture-pane) printf '>\n' ;;
            *) tmux_calls+="$*;" ;;
        esac
    }
    export -f tmux

    trigger_conductor "test-session" "$(printf '%s\t%s\t%s\t%s\n' 'sess:0.0' 'agent-a' 'IDLE' '/tmp/a')"
    # Verify C-u was sent before the message
    [[ "$tmux_calls" == *"send-keys"*"C-u"*"send-keys"*"C-m"* ]]
}

@test "trigger message references trigger-pending file" {
    CONDUCTOR_PANE="1.0"
    local sent_message=""

    detect_pane_state() { echo "IDLE"; }
    export -f detect_pane_state
    discover_claude_panes() { echo ""; }
    export -f discover_claude_panes

    tmux() {
        case "$1" in
            send-keys)
                if [[ "$*" == *"trigger-pending"* ]]; then
                    sent_message="$*"
                fi ;;
            capture-pane) printf '>\n' ;;
            *) ;;
        esac
    }
    export -f tmux

    trigger_conductor "test-session" "$(printf '%s\t%s\t%s\t%s\n' 'sess:0.0' 'agent-a' 'IDLE' '/tmp/a')"
    [[ "$sent_message" == *"trigger-pending"* ]]
    [[ "$sent_message" == *"agents need attention"* ]]
}
