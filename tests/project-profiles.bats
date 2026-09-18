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

@test "a tracked project profile is refused non-interactively" {
    git -C "$PROJ" init -q
    git -C "$PROJ" add -f .sbx/profiles/fs/tst.json
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

# An untracked profile cannot have arrived via clone or pull, so it is the
# user's own scratch config and confirm_project_profile raises no prompt --
# not even in a repo that has a remote. Stdin is closed so a regression that
# does prompt exits 1 here rather than blocking on /dev/tty.
@test "an untracked project profile launches without confirmation" {
    git -C "$PROJ" init -q
    git -C "$PROJ" remote add origin https://example.invalid/evil.git
    run bash -c "cd '$PROJ' && $SBX --fs tst -- /bin/sh -c 'echo ran > /out/untracked.txt' < /dev/null 2>&1"
    [ "$status" -eq 0 ]
    [ -f "$HOSTDIR/untracked.txt" ]
}

# A profile-authored warning (here, .workingDirectory, which is echoed
# verbatim into the warning text — see profile-check.sh) is attacker text:
# the launch directory and everything in it is untrusted. A control
# character in that text must never reach the terminal raw, and the
# message must be bounded in length.
@test "profile-authored warning text has control characters stripped and is length-capped" {
    jq -n --arg wd "$(printf 'bad\x1b[2K\x0dPWNED')" --arg src "$HOSTDIR" \
        '{description: "test", workingDirectory: $wd, mounts: [{source: $src, dest: "/out", perm: "rw"}]}' \
        > "$PROJ/.sbx/profiles/fs/tst.json"
    run bash -c "cd '$PROJ' && $SBX --fs tst -- /bin/true < /dev/null 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning:"* ]]
    [[ "$output" != *$'\x1b'* ]]
    [[ "$output" != *$'\x0d'* ]]

    local long
    long=$(printf 'x%.0s' {1..600})
    jq -n --arg wd "$long" --arg src "$HOSTDIR" \
        '{description: "test", workingDirectory: $wd, mounts: [{source: $src, dest: "/out", perm: "rw"}]}' \
        > "$PROJ/.sbx/profiles/fs/tst.json"
    run bash -c "cd '$PROJ' && $SBX --fs tst -- /bin/true < /dev/null 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"..."* ]]
    if [[ "$output" == *"$long"* ]]; then return 1; fi
}

# The trust prompt is the one control between a cloned repository and an
# arbitrary mount set. Before Phase 2, nothing profile-authored was echoed
# before it; this asserts the ordering holds with the resolve-step plan
# driving both the prompt and the warnings.
@test "a profile warning prints after the trust prompt, not before it" {
    git -C "$PROJ" init -q
    cat > "$PROJ/.sbx/profiles/fs/tst.json" <<EOF
{"description":"test","workingDirectory":"/src","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    git -C "$PROJ" add -f .sbx/profiles/fs/tst.json
    run bash -c "cd '$PROJ' && printf 'y\n' | script -qec \"$SBX --fs tst -- /bin/true\" /dev/null 2>&1"
    [ "$status" -eq 0 ]
    local prompt_line warn_line
    prompt_line=$(grep -n "This launch would use a profile tracked" <<< "$output" | head -n1 | cut -d: -f1)
    warn_line=$(grep -n "no longer honored" <<< "$output" | head -n1 | cut -d: -f1)
    [ -n "$prompt_line" ]
    [ -n "$warn_line" ]
    [ "$warn_line" -gt "$prompt_line" ]
}
