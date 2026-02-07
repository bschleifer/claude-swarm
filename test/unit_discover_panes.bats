#!/usr/bin/env bats
# Tests for discover_claude_panes() — pane discovery across sessions.

setup() {
    load 'test_helper/common'
    _common_setup
}

teardown() {
    _common_teardown
}

@test "panes with @swarm_name are included" {
    tmux() {
        case "$1" in
            list-sessions)
                echo "test-session"
                ;;
            list-panes)
                printf '0.0\n'
                ;;
            display-message)
                # Check which flag
                if [[ "$*" == *pane_current_command* ]]; then
                    echo "node"
                elif [[ "$*" == *pane_current_path* ]]; then
                    echo "/home/user/projects/test"
                fi
                ;;
            capture-pane)
                echo "> "
                ;;
            show)
                echo "my-agent"
                ;;
        esac
    }
    export -f tmux

    run discover_claude_panes
    assert_success
    assert_output --partial "my-agent"
    assert_output --partial "test-session:0.0"
}

@test "panes without @swarm_name are skipped" {
    tmux() {
        case "$1" in
            list-sessions)
                echo "test-session"
                ;;
            list-panes)
                printf '0.0\n'
                ;;
            display-message)
                if [[ "$*" == *pane_current_command* ]]; then
                    echo "node"
                elif [[ "$*" == *pane_current_path* ]]; then
                    echo "/tmp"
                fi
                ;;
            capture-pane)
                echo ""
                ;;
            show)
                # Simulate missing @swarm_name by returning failure
                return 1
                ;;
        esac
    }
    export -f tmux

    run discover_claude_panes
    assert_output ""
}

@test "multiple sessions are scanned" {
    tmux() {
        case "$1" in
            list-sessions)
                printf 'session-a\nsession-b\n'
                ;;
            list-panes)
                printf '0.0\n'
                ;;
            display-message)
                if [[ "$*" == *pane_current_command* ]]; then
                    echo "node"
                elif [[ "$*" == *pane_current_path* ]]; then
                    echo "/tmp"
                fi
                ;;
            capture-pane)
                echo "> "
                ;;
            show)
                echo "agent"
                ;;
        esac
    }
    export -f tmux

    run discover_claude_panes
    assert_output --partial "session-a:0.0"
    assert_output --partial "session-b:0.0"
}

@test "empty session list produces empty output" {
    tmux() {
        case "$1" in
            list-sessions)
                ;;
            *)
                ;;
        esac
    }
    export -f tmux

    run discover_claude_panes
    assert_output ""
}

@test "pane with empty @swarm_name is skipped" {
    tmux() {
        case "$1" in
            list-sessions)
                echo "test-session"
                ;;
            list-panes)
                printf '0.0\n'
                ;;
            display-message)
                if [[ "$*" == *pane_current_command* ]]; then
                    echo "node"
                elif [[ "$*" == *pane_current_path* ]]; then
                    echo "/tmp"
                fi
                ;;
            capture-pane)
                echo "> "
                ;;
            show)
                # Return empty string (swarm_name is empty)
                echo ""
                ;;
        esac
    }
    export -f tmux

    run discover_claude_panes
    assert_output ""
}

@test "output format is TARGET TAB NAME TAB STATE TAB PATH" {
    tmux() {
        case "$1" in
            list-sessions)
                echo "sess1"
                ;;
            list-panes)
                printf '0.0\n'
                ;;
            display-message)
                if [[ "$*" == *pane_current_command* ]]; then
                    echo "node"
                elif [[ "$*" == *pane_current_path* ]]; then
                    echo "/home/test"
                fi
                ;;
            capture-pane)
                echo "> "
                ;;
            show)
                echo "my-agent"
                ;;
        esac
    }
    export -f tmux

    run discover_claude_panes
    # Tab-separated: target, name, state, path
    local expected=$'sess1:0.0\tmy-agent\tIDLE\t/home/test'
    assert_output "$expected"
}

@test "multiple panes in one session all reported" {
    tmux() {
        case "$1" in
            list-sessions)
                echo "sess1"
                ;;
            list-panes)
                printf '0.0\n0.1\n'
                ;;
            display-message)
                if [[ "$*" == *pane_current_command* ]]; then
                    echo "node"
                elif [[ "$*" == *pane_current_path* ]]; then
                    echo "/tmp"
                fi
                ;;
            capture-pane)
                echo "> "
                ;;
            show)
                echo "agent"
                ;;
        esac
    }
    export -f tmux

    run discover_claude_panes
    local line_count
    line_count=$(echo "$output" | wc -l)
    assert_equal "$line_count" 2
}

@test "state detection works through discover_claude_panes" {
    tmux() {
        case "$1" in
            list-sessions)
                echo "sess1"
                ;;
            list-panes)
                printf '0.0\n'
                ;;
            display-message)
                if [[ "$*" == *pane_current_command* ]]; then
                    echo "bash"
                elif [[ "$*" == *pane_current_path* ]]; then
                    echo "/tmp"
                fi
                ;;
            capture-pane)
                echo "$ "
                ;;
            show)
                echo "exited-agent"
                ;;
        esac
    }
    export -f tmux

    run discover_claude_panes
    assert_output --partial "EXITED"
}
