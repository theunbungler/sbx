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

# --- --gc ---

@test "gc removes crash residue" {
    mkdir -p "$HOME/.local/state/sbx/sessions/dead" "$HOME/.local/state/sbx/join"
    echo 999999 > "$HOME/.local/state/sbx/join/dead.pid"
    run bash -c "cd '$PROJ' && $SBX --gc"
    [ "$status" -eq 0 ]
    [ ! -d "$HOME/.local/state/sbx/sessions/dead" ]
}

@test "gc leaves a live session alone" {
    mkdir -p "$HOME/.local/state/sbx/sessions/alive" "$HOME/.local/state/sbx/join"
    echo $$ > "$HOME/.local/state/sbx/join/alive.pid"
    mkdir -p "$HOME/.local/state/sbx/sessions/dead"
    echo 999999 > "$HOME/.local/state/sbx/join/dead.pid"
    run bash -c "cd '$PROJ' && $SBX --gc"
    [ "$status" -eq 0 ]
    [ -d "$HOME/.local/state/sbx/sessions/alive" ]
    if [ -d "$HOME/.local/state/sbx/sessions/dead" ]; then
        echo "gc collected nothing" >&2
        return 1
    fi
}

# session.json lives in a directory bound rw into the sandbox, so a payload
# can forge or delete it to make its own live session look dead. --gc must
# never trust it: liveness comes only from the out-of-band join/<name>.pid.
@test "gc ignores a forged session.json and trusts the out-of-band pid record" {
    mkdir -p "$HOME/.local/state/sbx/sessions/liar" "$HOME/.local/state/sbx/join"
    jq -n --argjson pid 999999 '{id:"liar",cwd:"/nope",pid:$pid}' \
        > "$HOME/.local/state/sbx/sessions/liar/session.json"
    echo $$ > "$HOME/.local/state/sbx/join/liar.pid"
    mkdir -p "$HOME/.local/state/sbx/sessions/dead"
    echo 999999 > "$HOME/.local/state/sbx/join/dead.pid"
    run bash -c "cd '$PROJ' && $SBX --gc"
    [ "$status" -eq 0 ]
    [ -d "$HOME/.local/state/sbx/sessions/liar" ]
    if [ -d "$HOME/.local/state/sbx/sessions/dead" ]; then
        echo "gc collected nothing" >&2
        return 1
    fi
}

@test "gc removes orphaned join sidecars but leaves a live session's alone" {
    mkdir -p "$HOME/.local/state/sbx/sessions/alive" "$HOME/.local/state/sbx/join"
    echo $$ > "$HOME/.local/state/sbx/join/alive.pid"
    echo '{}' > "$HOME/.local/state/sbx/join/alive.json"
    : > "$HOME/.local/state/sbx/join/alive.lock"
    # No sessions/ghost directory at all: pure orphan sidecars.
    echo 999999 > "$HOME/.local/state/sbx/join/ghost.pid"
    echo '{}' > "$HOME/.local/state/sbx/join/ghost.json"
    : > "$HOME/.local/state/sbx/join/ghost.lock"
    run bash -c "cd '$PROJ' && $SBX --gc"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.local/state/sbx/join/alive.pid" ]
    [ -f "$HOME/.local/state/sbx/join/alive.json" ]
    [ -f "$HOME/.local/state/sbx/join/alive.lock" ]
    [ ! -f "$HOME/.local/state/sbx/join/ghost.pid" ]
    [ ! -f "$HOME/.local/state/sbx/join/ghost.json" ]
    [ ! -f "$HOME/.local/state/sbx/join/ghost.lock" ]
}

@test "gc leaves claim.lock alone" {
    mkdir -p "$HOME/.local/state/sbx"
    : > "$HOME/.local/state/sbx/claim.lock"
    mkdir -p "$HOME/.local/state/sbx/sessions/dead" "$HOME/.local/state/sbx/join"
    echo 999999 > "$HOME/.local/state/sbx/join/dead.pid"
    run bash -c "cd '$PROJ' && $SBX --gc"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.local/state/sbx/claim.lock" ]
    if [ -d "$HOME/.local/state/sbx/sessions/dead" ]; then
        echo "gc collected nothing" >&2
        return 1
    fi
}

@test "change archives are pruned to the keep limit" {
    slug=$(echo "$PROJ" | tr '/' '-')
    for i in 1 2 3 4 5; do
        mkdir -p "$HOME/.local/state/sbx/changes/$slug/2026090$i-000000-myproj"
    done
    run bash -c "cd '$PROJ' && SBX_KEEP_CHANGES=2 $SBX --gc"
    [ "$(find "$HOME/.local/state/sbx/changes/$slug" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]
}

# --- --reseed ---

@test "reseed drops a forked store so the next launch re-reads the host" {
    mkdir -p "$PROJ/.sbx/profiles/cli"
    cat > "$PROJ/.sbx/profiles/cli/fk.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/fkmount","perm":"forked"}]}
EOF
    echo hostfile > "$HOSTDIR/host.txt"
    run_sbx "--cli fk --fs t" "echo owned > /tmp/fkmount/host.txt"
    echo refreshed > "$HOSTDIR/host.txt"
    run bash -c "cd '$PROJ' && $SBX --cli fk --reseed --yes"
    [ "$status" -eq 0 ]
    run_sbx "--cli fk --fs t" "cp /tmp/fkmount/host.txt /out/seen.txt"
    [ "$(cat "$HOSTDIR/seen.txt")" = "refreshed" ]
}

@test "reseed without --yes prompts and aborts by default" {
    mkdir -p "$PROJ/.sbx/profiles/cli"
    cat > "$PROJ/.sbx/profiles/cli/fk.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/fkmount","perm":"forked"}]}
EOF
    run bash -c "cd '$PROJ' && $SBX --cli fk --reseed </dev/null"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Aborted"* ]]
}

# --- --gc and the claim lock ---

make_fk_profile() {
    mkdir -p "$PROJ/.sbx/profiles/cli"
    cat > "$PROJ/.sbx/profiles/cli/fk.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/fkmount","perm":"forked"}]}
EOF
}

# The claim is two steps — mkdir sessions/<name>, then write join/<name>.pid —
# serialized by claim.lock precisely so nobody observes the gap. --gc is that
# observer: a directory with no pid record is exactly what it calls crash
# residue. Unlocked, it deletes a session that is mid-claim and very much
# alive. Simulated here by holding claim.lock while the pid record is still
# missing, then completing the claim before releasing.
@test "gc waits for the claim lock instead of collecting a mid-claim session" {
    mkdir -p "$HOME/.local/state/sbx/sessions/claiming" "$HOME/.local/state/sbx/join"
    : > "$HOME/.local/state/sbx/claim.lock"
    flock -x "$HOME/.local/state/sbx/claim.lock" \
        -c "sleep 3; echo $$ > '$HOME/.local/state/sbx/join/claiming.pid'" &
    local holder=$!
    # Let the holder actually acquire the lock before --gc reaches for it.
    sleep 0.5
    run bash -c "cd '$PROJ' && $SBX --gc"
    wait $holder
    [ "$status" -eq 0 ]
    [ -d "$HOME/.local/state/sbx/sessions/claiming" ]
    [ -f "$HOME/.local/state/sbx/join/claiming.pid" ]
}

# The orphaned-sidecar sweep has the same blind spot from the other side: a
# pid record whose session directory is not yet visible.
@test "gc waits for the claim lock before sweeping orphaned sidecars" {
    mkdir -p "$HOME/.local/state/sbx/join"
    : > "$HOME/.local/state/sbx/claim.lock"
    echo $$ > "$HOME/.local/state/sbx/join/claiming.pid"
    flock -x "$HOME/.local/state/sbx/claim.lock" \
        -c "sleep 3; mkdir -p '$HOME/.local/state/sbx/sessions/claiming'" &
    local holder=$!
    sleep 0.5
    run bash -c "cd '$PROJ' && $SBX --gc"
    wait $holder
    [ "$status" -eq 0 ]
    [ -f "$HOME/.local/state/sbx/join/claiming.pid" ]
}

@test "gc says nothing about forked stores when there are none" {
    mkdir -p "$HOME/.local/state/sbx/forked"
    run bash -c "cd '$PROJ' && $SBX --gc"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"Forked stores"* ]]; then
        echo "gc printed the forked-store header with nothing to report: $output" >&2
        return 1
    fi
}

# --- SBX_KEEP_CHANGES validation ---

# Bash arithmetic reads a non-numeric word as an unset variable, i.e. 0, so
# "+$((keep + 1))" becomes "tail -n +1" and every archive is pruned. A value
# inherited from a project .envrc must never be able to do that.
@test "a non-numeric SBX_KEEP_CHANGES prunes nothing and warns" {
    local slug
    slug=$(echo "$PROJ" | tr '/' '-')
    for i in 1 2 3 4 5; do
        mkdir -p "$HOME/.local/state/sbx/changes/$slug/2026090$i-000000-myproj"
    done
    run bash -c "cd '$PROJ' && SBX_KEEP_CHANGES=abc $SBX --gc"
    [ "$status" -eq 0 ]
    [ "$(find "$HOME/.local/state/sbx/changes/$slug" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 5 ]
    [[ "$output" == *"SBX_KEEP_CHANGES"* ]]
}

@test "a negative SBX_KEEP_CHANGES prunes nothing and warns" {
    local slug
    slug=$(echo "$PROJ" | tr '/' '-')
    for i in 1 2 3 4 5; do
        mkdir -p "$HOME/.local/state/sbx/changes/$slug/2026090$i-000000-myproj"
    done
    run bash -c "cd '$PROJ' && SBX_KEEP_CHANGES=-3 $SBX --gc"
    [ "$status" -eq 0 ]
    [ "$(find "$HOME/.local/state/sbx/changes/$slug" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 5 ]
    [[ "$output" != *"invalid number of lines"* ]]
}

# Bash evaluates command substitution inside an array subscript within
# $(( )), so an unvalidated SBX_KEEP_CHANGES is arbitrary host-side code.
@test "SBX_KEEP_CHANGES is never evaluated as arithmetic" {
    local marker="$ROOT/PWNED"
    run bash -c "cd '$PROJ' && SBX_KEEP_CHANGES='x[\$(touch $marker)]' $SBX --gc"
    if [[ -e "$marker" ]]; then
        echo "SBX_KEEP_CHANGES reached bash arithmetic and executed a command" >&2
        return 1
    fi
}

# The same unvalidated value reaches the teardown-time pruning, which runs on
# every ordinary launch — no --gc required.
@test "teardown pruning also ignores a non-numeric SBX_KEEP_CHANGES" {
    local slug
    slug=$(echo "$PROJ" | tr '/' '-')
    for i in 1 2 3 4 5; do
        mkdir -p "$HOME/.local/state/sbx/changes/$slug/2026090$i-000000-myproj"
    done
    mkdir -p "$PROJ/.sbx/profiles/fs"
    cat > "$PROJ/.sbx/profiles/fs/rec.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/rec","perm":"record"}]}
EOF
    ( cd "$PROJ" && SBX_KEEP_CHANGES=abc script -qec \
        "$SBX --fs rec -- /bin/sh -c 'echo x > /rec/x.txt'" /dev/null >/dev/null 2>&1 )
    # The session's own archive is added, so five pre-existing ones must all
    # still be there alongside it.
    [ "$(find "$HOME/.local/state/sbx/changes/$slug" -mindepth 1 -maxdepth 1 -type d -name '*-000000-myproj' | wc -l)" -eq 5 ]
}

# --- --reseed and live sessions ---

# A forked store is bind-mounted rw into the running sandbox. rm -rf on the
# host empties it underneath the live process, destroying the auth tokens and
# conversation history it is using right now.
@test "the join sidecar records the forked stores the session mounted" {
    make_fk_profile
    ( cd "$PROJ" && script -qec \
        "$SBX --cli fk --fs t -- /bin/sh -c 'echo up > /out/up.txt; sleep 6'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    for _ in $(seq 1 60); do [[ -f "$HOSTDIR/up.txt" ]] && break; sleep 0.25; done
    local store
    store=$(find "$HOME/.local/state/sbx/forked" -mindepth 3 -maxdepth 3 -type d | head -n1)
    [ -n "$store" ]
    run jq -r '.forked_stores[]?' "$HOME/.local/state/sbx/join/myproj.json"
    wait $bg
    [[ "$output" == *"$store"* ]]
}

@test "reseed refuses while a live session lists the store in its sidecar" {
    make_fk_profile
    run_sbx "--cli fk --fs t" "true"
    local store
    store=$(find "$HOME/.local/state/sbx/forked" -mindepth 3 -maxdepth 3 -type d | head -n1)
    [ -n "$store" ]
    mkdir -p "$HOME/.local/state/sbx/sessions/holder" "$HOME/.local/state/sbx/join"
    echo $$ > "$HOME/.local/state/sbx/join/holder.pid"
    jq -n --arg s "$store" \
        '{path:"/usr/bin",workdir:"/tmp",caps_keep:false,forked_stores:[$s]}' \
        > "$HOME/.local/state/sbx/join/holder.json"
    run bash -c "cd '$PROJ' && $SBX --cli fk --reseed --yes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"holder"* ]]
    [ -d "$store" ]
}

# The sidecar json is written long after the pid claim, so a session caught in
# between is live with nothing recorded. Unknown must mean refuse: a refusal is
# recoverable, deleting a live session's auth store is not.
@test "reseed refuses when a live session has no sidecar yet" {
    make_fk_profile
    run_sbx "--cli fk --fs t" "true"
    local store
    store=$(find "$HOME/.local/state/sbx/forked" -mindepth 3 -maxdepth 3 -type d | head -n1)
    [ -n "$store" ]
    mkdir -p "$HOME/.local/state/sbx/sessions/starting" "$HOME/.local/state/sbx/join"
    echo $$ > "$HOME/.local/state/sbx/join/starting.pid"
    run bash -c "cd '$PROJ' && $SBX --cli fk --reseed --yes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"starting"* ]]
    [ -d "$store" ]
}

# The refusal must be about liveness, not about the sidecar existing: a dead
# session's leftovers must not wedge --reseed forever.
@test "reseed proceeds when the session listing the store is dead" {
    make_fk_profile
    run_sbx "--cli fk --fs t" "true"
    local store
    store=$(find "$HOME/.local/state/sbx/forked" -mindepth 3 -maxdepth 3 -type d | head -n1)
    [ -n "$store" ]
    mkdir -p "$HOME/.local/state/sbx/sessions/gone" "$HOME/.local/state/sbx/join"
    echo 999999 > "$HOME/.local/state/sbx/join/gone.pid"
    jq -n --arg s "$store" \
        '{path:"/usr/bin",workdir:"/tmp",caps_keep:false,forked_stores:[$s]}' \
        > "$HOME/.local/state/sbx/join/gone.json"
    run bash -c "cd '$PROJ' && $SBX --cli fk --reseed --yes"
    [ "$status" -eq 0 ]
    [ ! -d "$store" ]
}

# What --reseed deletes is the store, so the prompt has to name it — dest and
# source alone do not tell you what is about to go.
@test "the reseed prompt names the store path and its size" {
    make_fk_profile
    run_sbx "--cli fk --fs t" "true"
    local store
    store=$(find "$HOME/.local/state/sbx/forked" -mindepth 3 -maxdepth 3 -type d | head -n1)
    [ -n "$store" ]
    run bash -c "cd '$PROJ' && $SBX --cli fk --reseed </dev/null"
    [[ "$output" == *"$store"* ]]
}

# --reseed runs after the name claim but before the EXIT trap is installed, so
# it exits leaving a session directory and pid record nobody will ever clean up.
@test "reseed leaves no session claim behind" {
    make_fk_profile
    run bash -c "cd '$PROJ' && $SBX --cli fk --reseed --yes"
    [ "$status" -eq 0 ]
    if [[ -d "$HOME/.local/state/sbx/sessions/myproj" ]]; then
        echo "reseed left a session directory behind" >&2
        return 1
    fi
    if [[ -f "$HOME/.local/state/sbx/join/myproj.pid" ]]; then
        echo "reseed left a pid record behind" >&2
        return 1
    fi
}

@test "an aborted reseed leaves no session claim behind" {
    make_fk_profile
    run bash -c "cd '$PROJ' && $SBX --cli fk --reseed </dev/null"
    [ "$status" -ne 0 ]
    if [[ -d "$HOME/.local/state/sbx/sessions/myproj" ]]; then
        echo "an aborted reseed left a session directory behind" >&2
        return 1
    fi
    if [[ -f "$HOME/.local/state/sbx/join/myproj.pid" ]]; then
        echo "an aborted reseed left a pid record behind" >&2
        return 1
    fi
}

# --- work-tree residue ---

# Only teardown removed $STATE_DIR/work/<name>/, so a session killed by
# SIGKILL, OOM or power loss stranded it. --gc advertises crash-residue
# collection and has to reclaim it too, on exactly the same liveness rule as
# the session and sidecar sweeps.
@test "gc collects a stranded work tree but leaves a live session's alone" {
    mkdir -p "$HOME/.local/state/sbx/join" \
             "$HOME/.local/state/sbx/work/dead/_tmp_x" \
             "$HOME/.local/state/sbx/work/alive/_tmp_x" \
             "$HOME/.local/state/sbx/sessions/alive"
    echo 999999 > "$HOME/.local/state/sbx/join/dead.pid"
    echo $$ > "$HOME/.local/state/sbx/join/alive.pid"
    run bash -c "cd '$PROJ' && $SBX --gc"
    [ "$status" -eq 0 ]
    [ -d "$HOME/.local/state/sbx/work/alive" ]
    if [ -d "$HOME/.local/state/sbx/work/dead" ]; then
        echo "gc left a dead session's work tree behind" >&2
        return 1
    fi
}

# A work tree whose session was never even claimed (no pid record at all) is
# residue by the same rule the sidecar sweep already uses.
@test "gc collects a work tree with no liveness record at all" {
    mkdir -p "$HOME/.local/state/sbx/join" "$HOME/.local/state/sbx/work/orphan/_tmp_x"
    run bash -c "cd '$PROJ' && $SBX --gc"
    [ "$status" -eq 0 ]
    if [ -d "$HOME/.local/state/sbx/work/orphan" ]; then
        echo "gc left an orphaned work tree behind" >&2
        return 1
    fi
}

# --- name reclaim vs. --gc ---

# The claim loop reclaimed only join/<name>.pid while --gc reclaims .pid,
# .json and .lock. A crashed session therefore left a stale join/<name>.json
# that outlived its name: the successor is live from the moment its pid is
# written but does not overwrite that sidecar until ~850 lines later, and in
# that window --reseed reads the PREDECESSOR's forked_stores list. If that
# stale list does not name the store --reseed is targeting, the "live pid
# but unknown mounts -> refuse" guard is bypassed and --reseed deletes a
# store the starting session has already seeded and is about to --bind.
#
# --reseed goes through the same claim loop and then releases the name
# without ever writing a sidecar of its own, which makes the reclaim
# observable on its own.
@test "a name reclaim removes the predecessor's json and lock, not just its pid" {
    make_fk_profile
    mkdir -p "$HOME/.local/state/sbx/sessions/myproj" "$HOME/.local/state/sbx/join"
    echo 999999 > "$HOME/.local/state/sbx/join/myproj.pid"
    echo '{"forked_stores":["/nowhere/ghost-store"]}' \
        > "$HOME/.local/state/sbx/join/myproj.json"
    : > "$HOME/.local/state/sbx/join/myproj.lock"
    run bash -c "cd '$PROJ' && $SBX --cli fk --reseed --yes"
    [ "$status" -eq 0 ]
    if [ -f "$HOME/.local/state/sbx/join/myproj.json" ]; then
        echo "a reclaimed name kept the predecessor's forked_stores sidecar" >&2
        return 1
    fi
    if [ -f "$HOME/.local/state/sbx/join/myproj.lock" ]; then
        echo "a reclaimed name kept the predecessor's join lock" >&2
        return 1
    fi
}

# The same reclaim on the launch path: a live session must never be
# describable by its predecessor's sidecar.
@test "a launch that reclaims a name does not inherit the predecessor's sidecar" {
    mkdir -p "$HOME/.local/state/sbx/sessions/myproj" "$HOME/.local/state/sbx/join"
    echo 999999 > "$HOME/.local/state/sbx/join/myproj.pid"
    echo '{"forked_stores":["/nowhere/ghost-store"],"stale":true}' \
        > "$HOME/.local/state/sbx/join/myproj.json"
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo up > /out/up.txt; sleep 5'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    # Poll from the instant the name is reclaimed: the pid record is
    # rewritten under claim.lock immediately after the reclaim, long before
    # the successor writes its own sidecar.
    local seen=""
    for _ in $(seq 1 400); do
        if [[ -f "$HOME/.local/state/sbx/join/myproj.pid" ]] &&
           [[ "$(cat "$HOME/.local/state/sbx/join/myproj.pid")" != 999999 ]]; then
            seen=$(cat "$HOME/.local/state/sbx/join/myproj.json" 2>/dev/null || true)
            break
        fi
        sleep 0.02
    done
    wait $bg
    [ -f "$HOSTDIR/up.txt" ]
    if [[ "$seen" == *stale* ]]; then
        echo "a newly claimed session was described by its predecessor's sidecar: $seen" >&2
        return 1
    fi
}

