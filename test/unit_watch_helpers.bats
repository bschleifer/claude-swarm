#!/usr/bin/env bats
# Tests for extracted watch helper functions:
#   should_trigger_conductor(), auto_focus_pane(), scan_pane_states()

setup() {
    load 'test_helper/common'
    _common_setup
}

teardown() {
    _common_teardown
}

# ── should_trigger_conductor() ────────────────────────────────────────────

@test "should_trigger_conductor: returns 0 when actionable and interval elapsed" {
    local now
    now=$(date +%s)
    local last_trigger=$(( now - 60 ))
    run should_trigger_conductor true "$last_trigger" 30
    assert_success
}

@test "should_trigger_conductor: returns 1 when not actionable" {
    local now
    now=$(date +%s)
    local last_trigger=$(( now - 60 ))
    run should_trigger_conductor false "$last_trigger" 30
    assert_failure
}

@test "should_trigger_conductor: returns 1 when interval not elapsed" {
    local now
    now=$(date +%s)
    local last_trigger=$now
    run should_trigger_conductor true "$last_trigger" 30
    assert_failure
}

@test "should_trigger_conductor: returns 0 at exact interval boundary" {
    local now
    now=$(date +%s)
    local last_trigger=$(( now - 30 ))
    run should_trigger_conductor true "$last_trigger" 30
    assert_success
}

@test "should_trigger_conductor: returns 0 with zero interval" {
    local now
    now=$(date +%s)
    run should_trigger_conductor true "$now" 0
    assert_success
}

@test "should_trigger_conductor: returns 1 when not actionable despite elapsed interval" {
    local now
    now=$(date +%s)
    local last_trigger=$(( now - 120 ))
    run should_trigger_conductor false "$last_trigger" 30
    assert_failure
}

# ── auto_focus_pane() ─────────────────────────────────────────────────────

@test "auto_focus_pane: selects pane when single transition in active window" {
    local selected=""
    tmux() {
        case "$1" in
            display-message) echo "1" ;;
            select-pane) selected="$3" ;;
        esac
    }
    export -f tmux

    auto_focus_pane "test-session" "1.0"
    assert_equal "$selected" "test-session:1.0"
}

@test "auto_focus_pane: does nothing when multiple panes transitioned" {
    local selected=""
    tmux() {
        case "$1" in
            display-message) echo "1" ;;
            select-pane) selected="$3" ;;
        esac
    }
    export -f tmux

    auto_focus_pane "test-session" "1.0" "1.1"
    assert_equal "$selected" ""
}

@test "auto_focus_pane: does nothing when no panes transitioned" {
    local selected=""
    tmux() {
        case "$1" in
            display-message) echo "1" ;;
            select-pane) selected="$3" ;;
        esac
    }
    export -f tmux

    auto_focus_pane "test-session"
    assert_equal "$selected" ""
}

@test "auto_focus_pane: skips when transition is in different window" {
    local selected=""
    tmux() {
        case "$1" in
            display-message) echo "0" ;;
            select-pane) selected="$3" ;;
        esac
    }
    export -f tmux

    auto_focus_pane "test-session" "1.0"
    assert_equal "$selected" ""
}

# ── scan_pane_states() ────────────────────────────────────────────────────

@test "scan_pane_states: counts idle and total panes" {
    declare -A prev_state=()
    declare -A idle_confirm=()

    # Mock get_panes to return 2 pane targets
    get_panes() {
        printf '0.0\n0.1\n'
    }
    export -f get_panes

    # Mock detect_pane_state: first pane idle, second working
    detect_pane_state() {
        case "$1" in
            *0.0) echo "IDLE" ;;
            *0.1) echo "WORKING" ;;
        esac
    }
    export -f detect_pane_state

    tmux() { :; }
    export -f tmux

    # Pre-seed prev_state to avoid hysteresis issue (need 2 consecutive IDLE reads)
    prev_state["0.0"]="IDLE"

    local idle_count=0 total_count=0 has_actionable=false
    local -a transitioned_panes=()

    scan_pane_states "test-session" "" "false" \
        idle_count total_count has_actionable transitioned_panes

    assert_equal "$idle_count" 1
    assert_equal "$total_count" 2
    assert_equal "$has_actionable" "true"
}

@test "scan_pane_states: hysteresis requires 2 consecutive IDLE readings" {
    declare -A prev_state=(["0.0"]="WORKING")
    declare -A idle_confirm=()

    get_panes() { printf '0.0\n'; }
    export -f get_panes

    detect_pane_state() { echo "IDLE"; }
    export -f detect_pane_state

    local tmux_state=""
    tmux() {
        if [[ "$1" == "set" ]]; then
            # Capture the state being set
            tmux_state="${@: -1}"
        fi
    }
    export -f tmux

    local idle_count=0 total_count=0 has_actionable=false
    local -a transitioned_panes=()

    # First call: IDLE but hysteresis blocks it → should stay WORKING
    scan_pane_states "test-session" "" "false" \
        idle_count total_count has_actionable transitioned_panes

    assert_equal "$idle_count" 0
    assert_equal "$tmux_state" "WORKING"
}

@test "scan_pane_states: WORKING→IDLE transition rings bell and records pane" {
    declare -A prev_state=(["0.0"]="WORKING")
    declare -A idle_confirm=(["0.0"]=1)

    get_panes() { printf '0.0\n'; }
    export -f get_panes

    detect_pane_state() { echo "IDLE"; }
    export -f detect_pane_state

    local bell_sent=false
    tmux() {
        case "$1" in
            set) ;;
            list-clients) echo "/dev/null" ;;
        esac
    }
    export -f tmux

    local idle_count=0 total_count=0 has_actionable=false
    local -a transitioned_panes=()

    scan_pane_states "test-session" "" "false" \
        idle_count total_count has_actionable transitioned_panes

    assert_equal "$idle_count" 1
    assert_equal "${#transitioned_panes[@]}" 1
    assert_equal "${transitioned_panes[0]}" "0.0"
}

@test "scan_pane_states: conductor pane excluded from actionable" {
    declare -A prev_state=(["0.0"]="IDLE")
    declare -A idle_confirm=()

    get_panes() { printf '0.0\n'; }
    export -f get_panes

    detect_pane_state() { echo "IDLE"; }
    export -f detect_pane_state

    tmux() { :; }
    export -f tmux

    local idle_count=0 total_count=0 has_actionable=false
    local -a transitioned_panes=()

    # Mark 0.0 as the conductor pane
    scan_pane_states "test-session" "0.0" "true" \
        idle_count total_count has_actionable transitioned_panes

    assert_equal "$has_actionable" "false"
}

@test "scan_pane_states: EXITED pane is actionable" {
    declare -A prev_state=()
    declare -A idle_confirm=()

    get_panes() { printf '0.0\n'; }
    export -f get_panes

    detect_pane_state() { echo "EXITED"; }
    export -f detect_pane_state

    tmux() { :; }
    export -f tmux

    local idle_count=0 total_count=0 has_actionable=false
    local -a transitioned_panes=()

    scan_pane_states "test-session" "" "false" \
        idle_count total_count has_actionable transitioned_panes

    assert_equal "$has_actionable" "true"
    assert_equal "$idle_count" 0
}

@test "scan_pane_states: empty pane list yields zero counts" {
    declare -A prev_state=()
    declare -A idle_confirm=()

    get_panes() { :; }
    export -f get_panes

    tmux() { :; }
    export -f tmux

    local idle_count=0 total_count=0 has_actionable=false
    local -a transitioned_panes=()

    scan_pane_states "test-session" "" "false" \
        idle_count total_count has_actionable transitioned_panes

    assert_equal "$idle_count" 0
    assert_equal "$total_count" 0
    assert_equal "$has_actionable" "false"
}
