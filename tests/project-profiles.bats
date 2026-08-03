#!/usr/bin/env bats

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/p"
    HOSTDIR="$ROOT/o"
    mkdir -p "$HOME" "$PROJ/.sbx/profiles/fs" "$HOSTDIR"

    cat > "$PROJ/.sbx/profiles/fs/tst.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
}

teardown() {
    [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]] && rm -rf "$ROOT"
}

@test "a project profile is refused non-interactively" {
    run bash -c "cd '$PROJ' && $SBX --fs tst -- /bin/true < /dev/null 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"project profile"* ]]
}

@test "the trust variable allows a project profile" {
    run bash -c "cd '$PROJ' && SBX_TRUST_PROJECT_PROFILES=1 script -qec \"$SBX --fs tst -- /bin/sh -c 'echo ran > /out/ran.txt'\" /dev/null >/dev/null 2>&1"
    [ -f "$HOSTDIR/ran.txt" ]
}

@test "a host profile needs no confirmation" {
    mkdir -p "$HOME/.config/sbx/profiles/fs"
    cat > "$HOME/.config/sbx/profiles/fs/hostp.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    run bash -c "cd '$PROJ' && script -qec \"$SBX --fs hostp -- /bin/sh -c 'echo ran > /out/host.txt'\" /dev/null >/dev/null 2>&1"
    [ -f "$HOSTDIR/host.txt" ]
}

@test "the refusal names the tracking repo and its remote" {
    git -C "$PROJ" init -q
    git -C "$PROJ" remote add origin https://example.invalid/evil.git
    git -C "$PROJ" add -f .sbx/profiles/fs/tst.json
    run bash -c "cd '$PROJ' && $SBX --fs tst -- /bin/true < /dev/null 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"example.invalid"* ]]
}

@test "an untracked project profile is refused without a remote warning" {
    git -C "$PROJ" init -q
    git -C "$PROJ" remote add origin https://example.invalid/evil.git
    run bash -c "cd '$PROJ' && $SBX --fs tst -- /bin/true < /dev/null 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" != *"example.invalid"* ]]
}
