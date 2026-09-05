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

@test "a window the tmux server forks is capless" {
    # The join's own first process is not the only thing the server forks:
    # new-window/split-window are default key bindings, and whatever they
    # start must be capless too, or the drop is one keystroke from gone.
    cat > "$HOSTDIR/probe.sh" <<'EOF'
#!/bin/sh
grep ^CapBnd /proc/self/status > /out/win.caps
EOF
    chmod +x "$HOSTDIR/probe.sh"

    start_bg_sbx "--fs caps" "$PARK"
    join_sbx "tmux new-window -d /out/probe.sh; for i in 1 2 3 4 5 6 7 8 9 10; do [ -s /out/win.caps ] && break; sleep 0.4; done"
    [ -s "$HOSTDIR/win.caps" ]
    [[ "$(cat "$HOSTDIR/win.caps")" == *"0000000000000000"* ]]
}

@test "a join is capless even after the sandbox tampers with the session dir" {
    # --join must not execute anything the sandbox can write. The session
    # directory is bound rw inside, so any on-disk join script there is
    # attacker-controlled.
    start_bg_sbx "--fs caps" "$PARK"

    # Nothing --join runs may live in the writable session directory.
    [ ! -e "$BG_SDIR/join_wrapper.sh" ]

    cat > "$HOSTDIR/tamper.sh" <<EOF
#!/bin/sh
printf '#!/bin/sh\necho TAMPERED > /out/tamper.txt\nexec "\$@"\n' > "$BG_SDIR/join_wrapper.sh"
chmod +x "$BG_SDIR/join_wrapper.sh"
echo ok > /out/tamper-installed
EOF
    chmod +x "$HOSTDIR/tamper.sh"

    join_sbx "/out/tamper.sh"
    # The tamper really did land: the directory is writable from inside,
    # so a passing test below is not vacuous.
    [ -s "$HOSTDIR/tamper-installed" ]

    join_sbx "grep ^CapBnd /proc/self/status > /out/join2.caps"
    [ -s "$HOSTDIR/join2.caps" ]
    [[ "$(cat "$HOSTDIR/join2.caps")" == *"0000000000000000"* ]]
    run test -e "$HOSTDIR/tamper.txt"
    [ "$status" -ne 0 ]
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
    # PATH is carried into a spawned pane by tmux itself, from the client,
    # independently of update-environment — so it needs its own canary.
    export PATH="/HOST/LEAK/MARKER:$PATH"
    start_bg_sbx "--fs caps" "$PARK"
    join_sbx "env > /out/join.env"
    [ -s "$HOSTDIR/join.env" ]
    run grep -q '/HOST/LEAK/MARKER' "$HOSTDIR/join.env"
    [ "$status" -ne 0 ]
    # Not merely "the marker is absent": the session's own PATH, with
    # $SESSION_DIR/bin (the docker shim) first, is what must be there.
    run grep -q "^PATH=$BG_SDIR/bin:" "$HOSTDIR/join.env"
    [ "$status" -eq 0 ]
    run grep -q '^DISPLAY=:99' "$HOSTDIR/join.env"
    [ "$status" -ne 0 ]
    run grep -q '^SSH_AUTH_SOCK=' "$HOSTDIR/join.env"
    [ "$status" -ne 0 ]
    run grep -q 'hunter2' "$HOSTDIR/join.env"
    [ "$status" -ne 0 ]
}

@test "writeback waits for a join that outlives the payload" {
    # A copy mount, not a plain rw bind: rw writes through immediately, so
    # it would pass regardless of when (or whether) writeback ran.
    cat > "$PROJ/.sbx/profiles/fs/cp.json" <<EOF
{"description":"test","mounts":[
  {"source":"$HOSTDIR","dest":"/out","perm":"rw"},
  {"source":"$ROOT/src","dest":"/copy","perm":"copy"}
]}
EOF
    mkdir -p "$ROOT/src"

    # Payload exits as soon as it is released; the join keeps running past
    # that point and writes only after the payload is gone.
    start_bg_sbx "--fs cp" "while [ ! -f /out/payload-go ]; do sleep 0.2; done"

    ( cd "$PROJ" && script -qec "$SBX --join $BG_SESSION -- /bin/sh -c 'while [ ! -f /out/join-go ]; do sleep 0.2; done; echo late > /copy/late.txt; echo done > /out/join-done'" /dev/null >/dev/null 2>&1 ) &
    local join_pid=$!

    # Wait for the join's session to actually exist before releasing the
    # payload. A fixed sleep races on a loaded machine: if the join has not
    # registered yet, the server briefly has zero sessions and exit-empty
    # tears it down, failing the socket assertion below spuriously.
    for _ in $(seq 100); do
        [[ "$(tmux -S "$BG_SDIR/tmux.sock" list-sessions 2>/dev/null | wc -l)" -ge 2 ]] && break
        sleep 0.1
    done
    touch "$HOSTDIR/payload-go"
    sleep 1

    # The session must still be alive with the payload gone — that is the
    # whole point of the PID-1 waiter.
    [ -S "$BG_SDIR/tmux.sock" ]

    touch "$HOSTDIR/join-go"
    wait "$join_pid" 2>/dev/null || true
    wait "$BG_PID" 2>/dev/null || true
    BG_PID=""

    [ -f "$HOSTDIR/join-done" ]
    [ "$(cat "$BG_SDIR/fs/_copy/late.txt")" = "late" ]
}

@test "attaching to a session that does not exist fails" {
    run bash -c "cd '$PROJ' && $SBX --attach nosuchsession 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "attach reaches the payload's own terminal" {
    # The payload prints a marker to its terminal and parks; an attach must
    # see that marker on its screen, which a fresh --join never would.
    start_bg_sbx "--fs caps" "echo PAYLOAD_MARKER; $PARK"
    sleep 1
    ( cd "$PROJ" && timeout 5 script -qec "$SBX --attach $BG_SESSION" /dev/null > "$HOSTDIR/attach.out" 2>&1 ) || true
    grep -q PAYLOAD_MARKER "$HOSTDIR/attach.out"
}
