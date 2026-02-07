#!/usr/bin/env bats
# Tests for update_window_names() — window renaming with idle counts.

setup() {
    load 'test_helper/common'
    _common_setup
}

teardown() {
    _common_teardown
}

@test "window renamed with idle count when panes are idle" {
    local renamed_to=""
    tmux() {
        case "$1" in
            list-windows)
                printf '0\tMyWindow\n'
                ;;
            list-panes)
                printf '0\n1\n'
                ;;
            show)
                echo "IDLE"
                ;;
            rename-window)
                renamed_to="$4"
                ;;
        esac
    }
    export -f tmux

    update_window_names "test-session"
    assert_equal "$renamed_to" "MyWindow (2 idle)"
}

@test "window not renamed when no panes are idle" {
    local renamed_called=false
    tmux() {
        case "$1" in
            list-windows)
                printf '0\tMyWindow\n'
                ;;
            list-panes)
                printf '0\n'
                ;;
            show)
                echo "WORKING"
                ;;
            rename-window)
                renamed_called=true
                ;;
        esac
    }
    export -f tmux

    update_window_names "test-session"
    assert_equal "$renamed_called" "false"
}

@test "conductor window is never renamed" {
    local renamed_called=false
    tmux() {
        case "$1" in
            list-windows)
                printf '0\tconductor\n'
                ;;
            list-panes)
                printf '0\n'
                ;;
            show)
                echo "IDLE"
                ;;
            rename-window)
                renamed_called=true
                ;;
        esac
    }
    export -f tmux

    update_window_names "test-session"
    assert_equal "$renamed_called" "false"
}

@test "existing idle suffix is stripped before re-adding" {
    local renamed_to=""
    tmux() {
        case "$1" in
            list-windows)
                printf '0\tMyWindow (1 idle)\n'
                ;;
            list-panes)
                printf '0\n1\n'
                ;;
            show)
                echo "IDLE"
                ;;
            rename-window)
                renamed_to="$4"
                ;;
        esac
    }
    export -f tmux

    update_window_names "test-session"
    assert_equal "$renamed_to" "MyWindow (2 idle)"
}

@test "idle suffix removed when all panes become working" {
    local renamed_to=""
    tmux() {
        case "$1" in
            list-windows)
                printf '0\tMyWindow (1 idle)\n'
                ;;
            list-panes)
                printf '0\n'
                ;;
            show)
                echo "WORKING"
                ;;
            rename-window)
                renamed_to="$4"
                ;;
        esac
    }
    export -f tmux

    update_window_names "test-session"
    assert_equal "$renamed_to" "MyWindow"
}

@test "multiple windows each get correct idle count" {
    local -A renames=()
    tmux() {
        case "$1" in
            list-windows)
                printf '0\tWinA\n1\tWinB\n'
                ;;
            list-panes)
                printf '0\n'
                ;;
            show)
                # All IDLE
                echo "IDLE"
                ;;
            rename-window)
                # Extract window target (e.g. "test-session:0")
                renames["$3"]="$4"
                ;;
        esac
    }
    export -f tmux

    update_window_names "test-session"
    assert_equal "${renames["test-session:0"]}" "WinA (1 idle)"
    assert_equal "${renames["test-session:1"]}" "WinB (1 idle)"
}

@test "no rename when name would be unchanged" {
    local rename_count=0
    tmux() {
        case "$1" in
            list-windows)
                printf '0\tMyWindow (1 idle)\n'
                ;;
            list-panes)
                printf '0\n'
                ;;
            show)
                echo "IDLE"
                ;;
            rename-window)
                rename_count=$((rename_count + 1))
                ;;
        esac
    }
    export -f tmux

    update_window_names "test-session"
    assert_equal "$rename_count" 0
}

@test "empty window list produces no renames" {
    local rename_count=0
    tmux() {
        case "$1" in
            list-windows)
                ;;
            rename-window)
                rename_count=$((rename_count + 1))
                ;;
        esac
    }
    export -f tmux

    update_window_names "test-session"
    assert_equal "$rename_count" 0
}
