#!/usr/bin/env bats

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"

    # NOT $BATS_TEST_TMPDIR — it embeds the test name, and sbx's tmux
    # socket at $HOME/.local/state/sbx/<session-id>/tmux.sock would blow
    # the ~108-char sun_path limit. Keep this path short.
    ROOT="$(mktemp -d /tmp/sbxj.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/p"
    HOSTDIR="$ROOT/o"
    mkdir -p "$HOME" "$PROJ/.sbx/profiles/fs" "$HOSTDIR"
    export SBX_TRUST_PROJECT_PROFILES=1

    cat > "$PROJ/.sbx/profiles/fs/caps.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
}

teardown() {
    # Release any payload still parked on the marker, so a failed
    # assertion cannot leave a sandbox running past the test.
    touch "$HOSTDIR/stop" 2>/dev/null || true
    [[ -n "$BG_PID" ]] && wait "$BG_PID" 2>/dev/null || true
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxj.* ]]; then
        rm -rf "$ROOT"
    fi
}

# Launch a sandbox in the background and wait for its tmux socket to
# appear. $1 = sbx args, $2 = payload shell command. A tmux client needs a
# pty, so `script -qec` supplies one.
start_bg_sbx() {
    ( cd "$PROJ" && script -qec "$SBX $1 -- /bin/sh -c '$2'" /dev/null >/dev/null 2>&1 ) &
    BG_PID=$!
    local sock
    for _ in $(seq 100); do
        sock=$(find "$HOME/.local/state/sbx" -maxdepth 2 -name tmux.sock 2>/dev/null | head -n1)
        if [[ -S "$sock" ]]; then
            BG_SDIR=$(dirname "$sock")
            BG_SESSION=$(basename "$BG_SDIR")
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# Run a command in a fresh join and wait for it to finish.
join_sbx() {
    ( cd "$PROJ" && script -qec "$SBX --join $BG_SESSION -- /bin/sh -c '$1'" /dev/null >/dev/null 2>&1 )
}

# A payload that parks until the test releases it.
PARK='while [ ! -f /out/stop ]; do sleep 0.2; done'

@test "a join runs inside the payload's namespaces" {
    start_bg_sbx "--fs caps" "readlink /proc/self/ns/pid > /out/payload.ns; $PARK"
    join_sbx "readlink /proc/self/ns/pid > /out/join.ns"
    [ -s "$HOSTDIR/join.ns" ]
    [ "$(cat "$HOSTDIR/join.ns")" = "$(cat "$HOSTDIR/payload.ns")" ]
    [ "$(cat "$HOSTDIR/join.ns")" != "$(readlink /proc/self/ns/pid)" ]
}

@test "a join sees the sandbox mount namespace, not the host's" {
    start_bg_sbx "--fs caps" "$PARK"
    join_sbx "readlink /proc/self/ns/mnt > /out/join.mnt"
    [ -s "$HOSTDIR/join.mnt" ]
    [ "$(cat "$HOSTDIR/join.mnt")" != "$(readlink /proc/self/ns/mnt)" ]
}

@test "a join has an empty capability bounding set" {
    start_bg_sbx "--fs caps" "$PARK"
    join_sbx "grep ^CapBnd /proc/self/status > /out/join.caps"
    [[ "$(cat "$HOSTDIR/join.caps")" == *"0000000000000000"* ]]
}

@test "a join gets its own pty, separate from the payload's" {
    start_bg_sbx "--fs caps" "tty > /out/payload.tty; $PARK"
    join_sbx "tty > /out/join.tty"
    [ -s "$HOSTDIR/join.tty" ]
    [ "$(cat "$HOSTDIR/join.tty")" != "$(cat "$HOSTDIR/payload.tty")" ]
}

@test "joining a session that does not exist fails" {
    run bash -c "cd '$PROJ' && $SBX --join nosuchsession 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "the host environment does not reach a join" {
    # tmux clients ship their environment to the server; update-environment
    # decides how much of it lands in new sessions. DISPLAY is on tmux's
    # default list, so it is the canary. SBX_TEST_SECRET stands in for the
    # API keys and tokens --clearenv exists to keep out.
    export DISPLAY=":99"
    export SSH_AUTH_SOCK="/tmp/fake-agent.sock"
    export SBX_TEST_SECRET=hunter2
    start_bg_sbx "--fs caps" "$PARK"
    join_sbx "env > /out/join.env"
    [ -s "$HOSTDIR/join.env" ]
    ! grep -q '^DISPLAY=:99' "$HOSTDIR/join.env"
    ! grep -q '^SSH_AUTH_SOCK=' "$HOSTDIR/join.env"
    ! grep -q 'hunter2' "$HOSTDIR/join.env"
}
