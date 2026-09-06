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
    [ -z "$(find "$HOME/.local/state/sbx/sessions" -mindepth 1 2>/dev/null)" ]
    # The name has to be actually reused, not merely freed: assert the
    # second session holds "myproj" while it is live.
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo r > /out/r.txt; sleep 6'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/r.txt" ]] && break; sleep 0.25; done
    [ -d "$HOME/.local/state/sbx/sessions/myproj" ]
    wait $bg
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
    # The name at stake is "myproj" itself: bumping to "myproj-2" would also
    # produce a working launch, so assert the reclaim while the session lives.
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo ok > /out/ok.txt; sleep 6'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/ok.txt" ]] && break; sleep 0.25; done
    [ -d "$HOME/.local/state/sbx/sessions/myproj" ]
    [ ! -d "$HOME/.local/state/sbx/sessions/myproj-2" ]
    wait $bg
    [ "$(cat "$HOSTDIR/ok.txt")" = "ok" ]
}

@test "list-sessions strips control characters from a live session's id" {
    # A raw control byte inside a JSON string literal is not valid JSON
    # (RFC 8259) and jq refuses to parse it at all, which would make the
    # fixture itself unreadable rather than exercising sanitization. Build
    # it with jq -n instead, the same way the original hardening.bats test
    # (jq --arg ... '.id = $c') produced a validly-escaped control char.
    mkdir -p "$HOME/.local/state/sbx/sessions/evil" "$HOME/.local/state/sbx/join"
    echo $$ > "$HOME/.local/state/sbx/join/evil.pid"
    jq -n --arg id "evil$(printf '\033')[31m" --arg cwd "$PROJ" --argjson pid "$$" \
        '{id:$id,cwd:$cwd,pid:$pid,fs_profiles:[],net_profiles:[],cli_profile:null}' \
        > "$HOME/.local/state/sbx/sessions/evil/session.json"
    run bash -c "cd '$PROJ' && $SBX --list-sessions"
    [ "$status" -eq 0 ]
    [[ "$output" == *evil* ]]
    [[ "$output" != *$'\033'* ]]
}

# session.json lives in a directory bound rw into the sandbox, so its
# contents are attacker-authored — they may be truncated, empty, binary, or
# not JSON at all. One unreadable entry must not take out the listing for
# every other live session.
@test "a malformed session.json does not break list-sessions for other sessions" {
    mkdir -p "$HOME/.local/state/sbx/sessions/garbage"
    printf 'not json at all\0\xff' > "$HOME/.local/state/sbx/sessions/garbage/session.json"
    mkdir -p "$HOME/.local/state/sbx/sessions/goodproj" "$HOME/.local/state/sbx/join"
    echo $$ > "$HOME/.local/state/sbx/join/goodproj.pid"
    jq -n --arg cwd "$PROJ" --argjson pid "$$" \
        '{id:"goodproj", cwd:$cwd, pid:$pid, fs_profiles:[], net_profiles:[], cli_profile:null}' \
        > "$HOME/.local/state/sbx/sessions/goodproj/session.json"
    run bash -c "cd '$PROJ' && $SBX --list-sessions"
    [ "$status" -eq 0 ]
    [[ "$output" == *goodproj* ]]
    if [[ -z "$output" ]]; then
        echo "list-sessions produced no output at all" >&2
        return 1
    fi
}

# The claim window. A launch claims its name with mkdir long before it
# writes session.json — profile parsing, xpra setup and copy-mount seeding
# all happen in between. A competitor entering the loop in that window must
# not read "no session.json" as "crash residue" and delete a live session.
# Liveness is recorded in $STATE_DIR/join/<name>.pid, written under the
# claim lock immediately after the mkdir.
@test "a session claimed but not yet fully started is not treated as residue" {
    mkdir -p "$HOME/.local/state/sbx/sessions/myproj" "$HOME/.local/state/sbx/join"
    echo marker > "$HOME/.local/state/sbx/sessions/myproj/marker.txt"
    echo $$ > "$HOME/.local/state/sbx/join/myproj.pid"
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo c > /out/c.txt; sleep 6'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/c.txt" ]] && break; sleep 0.25; done
    [ -f "$HOME/.local/state/sbx/sessions/myproj/marker.txt" ]
    [ -d "$HOME/.local/state/sbx/sessions/myproj-2" ]
    wait $bg
}

# session.json lives inside a directory bound rw into the sandbox, so a
# payload can delete it. That must not make its own live session look like
# residue to the next launch, which would then rm -rf a running session.
@test "a payload deleting its own session.json cannot make its session reclaimable" {
    mkdir -p "$HOME/.local/state/sbx/sessions/myproj" "$HOME/.local/state/sbx/join"
    echo marker > "$HOME/.local/state/sbx/sessions/myproj/marker.txt"
    echo $$ > "$HOME/.local/state/sbx/join/myproj.pid"
    # No session.json at all: the record the sandbox controls is gone.
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo d > /out/d.txt; sleep 6'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/d.txt" ]] && break; sleep 0.25; done
    [ -f "$HOME/.local/state/sbx/sessions/myproj/marker.txt" ]
    [ ! -d "$HOME/.local/state/sbx/sessions/myproj/tmp" ]
    wait $bg
}

# Genuine residue, both shapes: no pid record at all, and a pid record
# naming a process that is gone. Both must be reclaimed under the SAME name.
@test "residue with no pid record is reclaimed under the same name" {
    mkdir -p "$HOME/.local/state/sbx/sessions/myproj"
    echo marker > "$HOME/.local/state/sbx/sessions/myproj/marker.txt"
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo e > /out/e.txt; sleep 6'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/e.txt" ]] && break; sleep 0.25; done
    [ -d "$HOME/.local/state/sbx/sessions/myproj" ]
    [ ! -d "$HOME/.local/state/sbx/sessions/myproj-2" ]
    [ ! -f "$HOME/.local/state/sbx/sessions/myproj/marker.txt" ]
    wait $bg
}

@test "residue whose pid record names a dead process is reclaimed under the same name" {
    mkdir -p "$HOME/.local/state/sbx/sessions/myproj" "$HOME/.local/state/sbx/join"
    echo 999999 > "$HOME/.local/state/sbx/join/myproj.pid"
    echo marker > "$HOME/.local/state/sbx/sessions/myproj/marker.txt"
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo f > /out/f.txt; sleep 6'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/f.txt" ]] && break; sleep 0.25; done
    [ -d "$HOME/.local/state/sbx/sessions/myproj" ]
    [ ! -d "$HOME/.local/state/sbx/sessions/myproj-2" ]
    [ ! -f "$HOME/.local/state/sbx/sessions/myproj/marker.txt" ]
    wait $bg
}

# --list-sessions must take liveness from the pid record outside the
# sandbox, not from the attacker-authored session.json inside it.
@test "list-sessions ignores a session.json pid and uses the out-of-band record" {
    mkdir -p "$HOME/.local/state/sbx/sessions/liar" "$HOME/.local/state/sbx/join"
    jq -n --arg cwd "$PROJ" --argjson pid "$$" \
        '{id:"liar",cwd:$cwd,pid:$pid,fs_profiles:[],net_profiles:[],cli_profile:null}' \
        > "$HOME/.local/state/sbx/sessions/liar/session.json"
    echo 999999 > "$HOME/.local/state/sbx/join/liar.pid"
    run bash -c "cd '$PROJ' && $SBX --list-sessions"
    [ "$status" -eq 0 ]
    [[ "$output" != *liar* ]]
}

# A launch directory named "-.." derives the session name "..", and
# "$STATE_DIR/sessions/.." is $STATE_DIR itself. POSIX rm refuses to remove
# ".." so this currently fails closed by accident; reject the name instead.
@test "a launch directory deriving . or .. falls back to the default name" {
    local weird="$ROOT/-.."
    mkdir -p "$weird/.sbx/profiles/fs"
    cat > "$weird/.sbx/profiles/fs/t.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    ( cd "$weird" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo g > /out/g.txt; sleep 6'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/g.txt" ]] && break; sleep 0.25; done
    [ -d "$HOME/.local/state/sbx/sessions/sbx" ]
    [ -d "$HOME/.local/state/sbx/sessions" ]
    wait $bg
}

# --join and --attach names are typed by hand and interpolated into a path.
@test "join and attach reject traversal and dot session names" {
    run bash -c "cd '$PROJ' && $SBX --join ../x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid session name"* ]]
    run bash -c "cd '$PROJ' && $SBX --attach .."
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid session name"* ]]
    run bash -c "cd '$PROJ' && $SBX --join 'a b'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid session name"* ]]
}

# The tmux socket path fails quietly with "File name too long" past ~108
# bytes; a long $HOME must produce a loud error, not a mystery.
@test "an oversized tmux socket path is rejected loudly" {
    local deep="$ROOT/$(printf 'd%.0s' $(seq 1 60))/$(printf 'e%.0s' $(seq 1 60))"
    mkdir -p "$deep"
    run bash -c "cd '$PROJ' && HOME='$deep' $SBX --fs t -- true"
    [ "$status" -ne 0 ]
    # sbx's own up-front check, not tmux's late "error connecting ... (File
    # name too long)" after a session directory has already been created.
    [[ "$output" == *"session socket path is too long"* ]]
    [[ "$output" != *"error connecting"* ]]
}

# The claim lock is meant to fail loudly, never silently. `flock -x 8`
# failing already warns; but `exec 8>>"$CLAIM_LOCK"` failing is a distinct
# failure path that must warn just as loudly, or a launch proceeds unlocked
# with no sign anything is wrong — silently reintroducing the exact race
# the lock exists to prevent. Make the open fail (not the flock) by
# pre-creating claim.lock as a directory: `exec 8>>` on a directory fails
# with EISDIR while $STATE_DIR itself stays writable, so the rest of the
# launch can still proceed.
@test "a launch still succeeds and warns when the claim lock cannot be opened" {
    mkdir -p "$HOME/.local/state/sbx"
    mkdir -p "$HOME/.local/state/sbx/claim.lock"
    # script merges the wrapped command's stdout and stderr into the pty it
    # drives, so redirecting script's own fd 2 does not capture the
    # child's stderr — only the typescript file does.
    local typescript="$ROOT/typescript.txt"
    ( cd "$PROJ" && script -qec "$SBX --fs t -- /bin/sh -c 'echo up > /out/up.txt'" "$typescript" \
        >/dev/null 2>&1 )
    [ -f "$HOSTDIR/up.txt" ]
    grep -aq "claim.lock" "$typescript"
    grep -aqi "warning" "$typescript"
}
