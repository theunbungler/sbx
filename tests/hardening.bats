#!/usr/bin/env bats

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"

    # NOT $BATS_TEST_TMPDIR — it embeds the test name, and sbx's session
    # socket at $HOME/.local/state/sbx/<session-id>/session.sock would blow
    # the ~108-char sun_path limit. Keep this path short.
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/p"
    HOSTDIR="$ROOT/o"
    RODIR="$ROOT/r"
    mkdir -p "$HOME" "$PROJ/.sbx/profiles/fs" "$PROJ/.sbx/profiles/net" "$HOSTDIR" "$RODIR"
    echo readonly > "$RODIR/f.txt"

    # Task 6 adds a confirmation prompt for ./.sbx profiles; these fixtures
    # are ours, so opt out of it for the whole suite.
    export SBX_TRUST_PROJECT_PROFILES=1

    cat > "$PROJ/.sbx/profiles/fs/caps.json" <<EOF
{"description":"test","mounts":[
  {"source":"$HOSTDIR","dest":"/out","perm":"rw"},
  {"source":"$RODIR","dest":"/ro","perm":"ro"}
]}
EOF
}

teardown() {
    [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]] && rm -rf "$ROOT"
}

# sbx ends in `abduco -c` (or the dtach fallback), which needs a pty;
# `script -qec` supplies one non-interactively.
run_sbx() {
    ( cd "$PROJ" && script -qec "$SBX $1 -- /bin/sh -c '$2'" /dev/null >/dev/null 2>&1 )
}

# CANARY — keep this first. Every other test in this file asserts that
# something is DENIED inside the sandbox, so all of them pass vacuously if
# the sandbox fails to launch at all. This one fails loudly instead.
@test "a sandbox command actually runs" {
    run_sbx "--fs caps" "echo ran > /out/ran.txt"
    [ "$(cat "$HOSTDIR/ran.txt")" = "ran" ]
}

# REGRESSION GUARDS, not a red-green cycle: bwrap zeroes every capability
# set — effective and bounding — whenever it creates the user namespace
# itself, which is what the no-net path does. So both capability tests
# below pass before the change as well as after. They are here because
# Task 2 rewrites capability handling for both modes and nothing else
# would catch the no-net path regressing. The red for the capability
# work lives in Task 2's networked tests, where bwrap joins pasta's
# namespace instead and leaves every set full. Deliberate — do not
# "fix" these into failing-first tests.
@test "a no-net sandbox holds no capabilities" {
    run_sbx "--fs caps" "grep '^CapEff' /proc/self/status > /out/caps.txt"
    [[ "$(cat "$HOSTDIR/caps.txt")" == *"0000000000000000" ]]
}

@test "a no-net sandbox holds an empty capability bounding set" {
    run_sbx "--fs caps" "grep '^CapBnd' /proc/self/status > /out/bnd.txt"
    [[ "$(cat "$HOSTDIR/bnd.txt")" == *"0000000000000000" ]]
}

@test "a ro mount cannot be remounted writable" {
    run_sbx "--fs caps" "mount -n -o remount,bind,rw /ro 2>/dev/null && echo BAD > /out/r.txt || echo GOOD > /out/r.txt"
    [ "$(cat "$HOSTDIR/r.txt")" = "GOOD" ]
}

@test "a ro mount source is not modified from inside" {
    run_sbx "--fs caps" "mount -n -o remount,bind,rw /ro 2>/dev/null; echo pwned > /ro/f.txt 2>/dev/null; true"
    [ "$(cat "$RODIR/f.txt")" = "readonly" ]
}
