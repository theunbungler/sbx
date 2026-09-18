#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/copy-mounts.sh"
    source "$BATS_TEST_DIRNAME/../lib/state-paths.sh"
}

@test "session base lowercases and replaces unsafe characters" {
    run sbx_state_session_base "/tmp/x/My Project!"
    [ "$output" = "my-project" ]
}

@test "session base keeps dots, dashes and underscores" {
    run sbx_state_session_base "/tmp/x/a.b_c-d"
    [ "$output" = "a.b_c-d" ]
}

@test "session base is cut to 32 characters" {
    run sbx_state_session_base "/tmp/x/abcdefghijklmnopqrstuvwxyz0123456789"
    [ "$output" = "abcdefghijklmnopqrstuvwxyz012345" ]
}

@test "session base falls back to sbx for empty and dot-dot" {
    run sbx_state_session_base "/"
    [ "$output" = "sbx" ]
    run sbx_state_session_base "/tmp/x/-.."
    [ "$output" = "sbx" ]
}

@test "forked store path is keyed by profile, launch directory and destination" {
    run sbx_state_forked_store /s /home/u/proj pi /home/u/.pi
    [ "$output" = "/s/forked/pi/-home-u-proj/_home_u_.pi" ]
}
