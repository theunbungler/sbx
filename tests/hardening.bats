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
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]]; then
        rm -rf "$ROOT"
    fi
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

# Networked sessions need pasta and a usable default route; skip rather
# than fail where neither exists. Tasks 2 onward reuse both helpers.
requires_net() {
    command -v pasta >/dev/null 2>&1 || skip "pasta not installed"
    ip route show default | grep -q . || skip "no default route"
}

net_fixture() {
    cat > "$PROJ/.sbx/profiles/net/tstnet.json" <<'NETEOF'
{"description":"test","dns":"1.1.1.1","allow":["example.com"],"ports":[443]}
NETEOF
}

# SECOND CANARY. Networked mode is Task 2's scope, but THIS task is the
# one that can break it: the capability flags are appended to a single
# global BWRAP_ARGS array, so a cap-drop meant for no-net silently
# applies to --net too. Until Task 2 relocates them, the --net wrapper
# runs nft and dnsmasq inside the sandbox and needs CAP_NET_ADMIN;
# without this test the breakage is invisible, because nothing else in
# tests/ launches a networked session.
@test "a networked session still runs" {
    requires_net
    net_fixture
    run_sbx "--fs caps --net tstnet" "echo netran > /out/netran.txt"
    [ "$(cat "$HOSTDIR/netran.txt")" = "netran" ]
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

# The red-green pair for the relocation. Under --net, bwrap joins pasta's
# user namespace instead of creating it, so every capability set arrives
# full; these four fail until nft and dnsmasq move to launch.sh and the
# payload can be run capless.
@test "a networked sandbox holds no capabilities" {
    requires_net
    net_fixture
    run_sbx "--fs caps --net tstnet" "grep '^CapEff' /proc/self/status > /out/ncaps.txt"
    [[ "$(cat "$HOSTDIR/ncaps.txt")" == *"0000000000000000" ]]
}

@test "a networked sandbox cannot flush the egress firewall" {
    requires_net
    net_fixture
    run_sbx "--fs caps --net tstnet" "nft flush ruleset 2>/dev/null && echo BAD > /out/n.txt || echo GOOD > /out/n.txt"
    [ "$(cat "$HOSTDIR/n.txt")" = "GOOD" ]
}

@test "a networked sandbox cannot remount a ro mount writable" {
    requires_net
    net_fixture
    run_sbx "--fs caps --net tstnet" "mount -n -o remount,bind,rw /ro 2>/dev/null && echo BAD > /out/nr.txt || echo GOOD > /out/nr.txt"
    [ "$(cat "$HOSTDIR/nr.txt")" = "GOOD" ]
}

# dnsmasq now lives outside the sandbox's PID namespace, so the payload
# cannot signal it — the resolver is unreachable, not merely unwritable.
@test "a networked sandbox cannot see the dnsmasq process" {
    requires_net
    net_fixture
    run_sbx "--fs caps --net tstnet" "ps ax > /out/ps.txt 2>/dev/null || true"
    ! grep -q dnsmasq "$HOSTDIR/ps.txt"
}

@test "a profile with caps keep retains capabilities" {
    cat > "$PROJ/.sbx/profiles/fs/keep.json" <<EOF
{"description":"test","caps":"keep","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    # caps:keep is honoured only from host-owned profiles, so install it there.
    mkdir -p "$HOME/.config/sbx/profiles/fs"
    cp "$PROJ/.sbx/profiles/fs/keep.json" "$HOME/.config/sbx/profiles/fs/keep.json"
    rm "$PROJ/.sbx/profiles/fs/keep.json"

    run_sbx "--fs keep" "grep '^CapEff' /proc/self/status > /out/k.txt"
    [[ "$(cat "$HOSTDIR/k.txt")" != *"0000000000000000" ]]
}

@test "a caps keep session warns on stderr" {
    mkdir -p "$HOME/.config/sbx/profiles/fs"
    cat > "$HOME/.config/sbx/profiles/fs/keep.json" <<EOF
{"description":"test","caps":"keep","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    run bash -c "cd '$PROJ' && script -qec \"$SBX --fs keep -- /bin/true\" /dev/null 2>&1"
    [[ "$output" == *"retains capabilities"* ]]
}

@test "a project profile may not request caps" {
    cat > "$PROJ/.sbx/profiles/fs/evil.json" <<EOF
{"description":"test","caps":"keep","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    run bash -c "cd '$PROJ' && $SBX --fs evil -- /bin/true 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"may not set"* ]]
}

@test "a project profile may not request userns full" {
    cat > "$PROJ/.sbx/profiles/fs/evil2.json" <<EOF
{"description":"test","userns":"full","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    run bash -c "cd '$PROJ' && $SBX --fs evil2 -- /bin/true 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"may not set"* ]]
}
