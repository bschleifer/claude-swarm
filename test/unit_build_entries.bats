#!/usr/bin/env bats
# Tests for build_entries() — picker and pane array construction.

setup() {
    load 'test_helper/common'
    _common_setup

    # Reset all arrays that build_entries populates
    PICKER_LABELS=()
    PICKER_META=()
    PICKER_PANES=()
    PANE_LABELS=()
    PANE_PATHS=()
    PANE_BANNERS=()
    PANE_GROUP=()

    PROJECTS_DIR="/tmp/test-projects"
}

teardown() {
    _common_teardown
}

@test "individual agents create one picker entry per agent" {
    AGENTS=("repo-a" "repo-b")
    AGENT_GROUPS=()

    build_entries

    assert_equal "${#PICKER_LABELS[@]}" 2
    assert_equal "${PICKER_LABELS[0]}" "repo-a"
    assert_equal "${PICKER_LABELS[1]}" "repo-b"
}

@test "individual agents have empty meta" {
    AGENTS=("repo-a")
    AGENT_GROUPS=()

    build_entries

    assert_equal "${PICKER_META[0]}" ""
}

@test "individual agent pane path uses PROJECTS_DIR" {
    AGENTS=("repo-a")
    AGENT_GROUPS=()

    build_entries

    assert_equal "${PANE_PATHS[0]}" "/tmp/test-projects/repo-a"
}

@test "group creates single picker entry for multiple repos" {
    AGENTS=()
    AGENT_GROUPS=("MyGroup|repo-a,repo-b,repo-c")

    build_entries

    assert_equal "${#PICKER_LABELS[@]}" 1
    assert_equal "${PICKER_LABELS[0]}" "MyGroup"
    assert_equal "${PICKER_META[0]}" "(group: 3 repos)"
}

@test "group creates one pane per member repo" {
    AGENTS=()
    AGENT_GROUPS=("MyGroup|repo-a,repo-b")

    build_entries

    assert_equal "${#PANE_LABELS[@]}" 2
    assert_equal "${PANE_LABELS[0]}" "repo-a"
    assert_equal "${PANE_LABELS[1]}" "repo-b"
}

@test "group pane indices are space-separated in PICKER_PANES" {
    AGENTS=()
    AGENT_GROUPS=("MyGroup|repo-a,repo-b")

    build_entries

    # PICKER_PANES[0] should contain "0 1 " (space-separated pane indices)
    assert_equal "${PICKER_PANES[0]}" "0 1 "
}

@test "grouped repos excluded from individual list" {
    AGENTS=("repo-a" "repo-b" "repo-c")
    AGENT_GROUPS=("Group|repo-a,repo-b")

    build_entries

    # Group adds 1 picker entry, individual adds repo-c only (repo-a, repo-b excluded)
    assert_equal "${#PICKER_LABELS[@]}" 2
    assert_equal "${PICKER_LABELS[0]}" "Group"
    assert_equal "${PICKER_LABELS[1]}" "repo-c"
}

@test "pane group set to group label for grouped repos" {
    AGENTS=()
    AGENT_GROUPS=("MyGroup|repo-a")

    build_entries

    assert_equal "${PANE_GROUP[0]}" "MyGroup"
}

@test "pane group set to repo name for individual repos" {
    AGENTS=("solo-repo")
    AGENT_GROUPS=()

    build_entries

    assert_equal "${PANE_GROUP[0]}" "solo-repo"
}

@test "multiple groups and individuals interleave correctly" {
    AGENTS=("individual")
    AGENT_GROUPS=("G1|r1,r2" "G2|r3")

    build_entries

    # Picker: G1, G2, individual
    assert_equal "${#PICKER_LABELS[@]}" 3
    assert_equal "${PICKER_LABELS[0]}" "G1"
    assert_equal "${PICKER_LABELS[1]}" "G2"
    assert_equal "${PICKER_LABELS[2]}" "individual"

    # Panes: r1, r2 (from G1), r3 (from G2), individual
    assert_equal "${#PANE_LABELS[@]}" 4
    assert_equal "${PANE_LABELS[0]}" "r1"
    assert_equal "${PANE_LABELS[1]}" "r2"
    assert_equal "${PANE_LABELS[2]}" "r3"
    assert_equal "${PANE_LABELS[3]}" "individual"
}

@test "empty agents and groups produce empty arrays" {
    AGENTS=()
    AGENT_GROUPS=()

    build_entries

    assert_equal "${#PICKER_LABELS[@]}" 0
    assert_equal "${#PANE_LABELS[@]}" 0
}

@test "banner includes agent name" {
    AGENTS=("my-repo")
    AGENT_GROUPS=()

    build_entries

    [[ "${PANE_BANNERS[0]}" == *"my-repo"* ]]
}
