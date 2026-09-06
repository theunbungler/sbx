#!/usr/bin/env bats

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/myproj"
    HOSTDIR="$ROOT/s"
    mkdir -p "$HOME" "$PROJ/.sbx/profiles/fs" "$HOSTDIR"
    export SBX_TRUST_PROJECT_PROFILES=1
    cat > "$PROJ/.sbx/profiles/fs/t.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
}

teardown() {
    [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]] && rm -rf "$ROOT"
}

run_sbx() {
    ( cd "$PROJ" && script -qec "$SBX $1 -- /bin/sh -c '$2'" /dev/null >/dev/null 2>&1 )
}

@test "a session is named after its launch directory" {
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo up > /out/up.txt; sleep 5'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/up.txt" ]] && break; sleep 0.25; done
    [ -d "$HOME/.local/state/sbx/sessions/myproj" ]
    wait $bg
}

@test "a session directory is removed on exit" {
    run_sbx "--fs t" "true"
    [ -z "$(find "$HOME/.local/state/sbx/sessions" -mindepth 1 2>/dev/null)" ]
}

@test "list-sessions is empty once every session has ended" {
    run_sbx "--fs t" "true"
    run bash -c "cd '$PROJ' && $SBX --list-sessions"
    [ "$status" -eq 0 ]
    [[ "$output" != *myproj* ]]
}

@test "a second concurrent session in the same directory gets a -2 suffix" {
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo a > /out/a.txt; sleep 6'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg1=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/a.txt" ]] && break; sleep 0.25; done
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo b > /out/b.txt; sleep 4'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg2=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/b.txt" ]] && break; sleep 0.25; done
    [ -d "$HOME/.local/state/sbx/sessions/myproj" ]
    [ -d "$HOME/.local/state/sbx/sessions/myproj-2" ]
    wait $bg1 $bg2
}

@test "a name is reusable after its session ends" {
    run_sbx "--fs t" "true"
    run_sbx "--fs t" "true"
    [ -z "$(find "$HOME/.local/state/sbx/sessions" -mindepth 1 2>/dev/null)" ]
}

# Crash residue: a session directory whose supervising pid is gone. It must
# not be listed as live, and its name must be reclaimable.
@test "a dead session directory is not listed and its name is reclaimed" {
    mkdir -p "$HOME/.local/state/sbx/sessions/myproj"
    cat > "$HOME/.local/state/sbx/sessions/myproj/session.json" <<EOF
{"id":"myproj","cwd":"$PROJ","pid":999999,"fs_profiles":[],"net_profiles":[],"cli_profile":null}
EOF
    run bash -c "cd '$PROJ' && $SBX --list-sessions"
    [[ "$output" != *myproj* ]]
    run_sbx "--fs t" "echo ok > /out/ok.txt"
    [ "$(cat "$HOSTDIR/ok.txt")" = "ok" ]
}

@test "list-sessions strips control characters from a live session's id" {
    # A raw control byte inside a JSON string literal is not valid JSON
    # (RFC 8259) and jq refuses to parse it at all, which would make the
    # fixture itself unreadable rather than exercising sanitization. Build
    # it with jq -n instead, the same way the original hardening.bats test
    # (jq --arg ... '.id = $c') produced a validly-escaped control char.
    mkdir -p "$HOME/.local/state/sbx/sessions/evil"
    jq -n --arg id "evil$(printf '\033')[31m" --arg cwd "$PROJ" --argjson pid "$$" \
        '{id:$id,cwd:$cwd,pid:$pid,fs_profiles:[],net_profiles:[],cli_profile:null}' \
        > "$HOME/.local/state/sbx/sessions/evil/session.json"
    run bash -c "cd '$PROJ' && $SBX --list-sessions"
    [ "$status" -eq 0 ]
    [[ "$output" == *evil* ]]
    [[ "$output" != *$'\033'* ]]
}
