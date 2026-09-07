#!/usr/bin/env bats

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"

    # NOT $BATS_TEST_TMPDIR — it embeds the test name, and sbx's session
    # socket at $HOME/.local/state/sbx/<session-id>/session.sock would blow
    # the ~108-char sun_path limit, failing with "create-session: File name
    # too long" before the command ever runs. Verified: a long HOME fails,
    # /tmp/sbxh.XXXXXX (66 chars total) works. Keep this path short.
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/p"
    HOSTDIR="$ROOT/s"
    mkdir -p "$HOME" "$PROJ/.sbx/profiles/cli" "$PROJ/.sbx/profiles/fs" "$HOSTDIR"

    # Every fixture below lives in ./.sbx/profiles; these are ours, so opt
    # out of the project-profile confirmation prompt for the whole suite.
    export SBX_TRUST_PROJECT_PROFILES=1

    # The store is keyed by profile name AND the external launch
    # directory (see lib/copy-mounts.sh:sbx_copy_path_slug), so every
    # store path assertion below needs this slug of $PROJ.
    PROJ_SLUG=$(echo "$PROJ" | tr '/' '-')
    echo hostfile > "$HOSTDIR/host.txt"

    FORKED_ROOT="$HOME/.local/state/sbx/forked"
    cat > "$PROJ/.sbx/profiles/cli/fk.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/fkmount","perm":"forked"}]}
EOF

    CHANGES_ROOT="$HOME/.local/state/sbx/changes"
    cat > "$PROJ/.sbx/profiles/fs/rec.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/recmount","perm":"record"}]}
EOF

    # File-source (not directory-source) mounts: both perms bind a single
    # host file, the untested branch in the seeding loops.
    FORKED_FILE_SRC="$HOSTDIR/hostfile.txt"
    echo filedata > "$FORKED_FILE_SRC"
    cat > "$PROJ/.sbx/profiles/cli/fkfile.json" <<EOF
{"description":"test","mounts":[{"source":"$FORKED_FILE_SRC","dest":"/tmp/fkfile","perm":"forked"}]}
EOF
    cat > "$PROJ/.sbx/profiles/fs/recfile.json" <<EOF
{"description":"test","mounts":[{"source":"$FORKED_FILE_SRC","dest":"/tmp/recfile","perm":"record"}]}
EOF
}

teardown() {
    [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]] && rm -rf "$ROOT"
}

# Run a shell command inside a sandbox. sbx runs its payload under a tmux
# server inside the sandbox, and a tmux client needs a pty; `script -qec`
# supplies one non-interactively.
run_sbx() {
    ( cd "$PROJ" && script -qec "$SBX $1 -- /bin/sh -c '$2'" /dev/null >/dev/null 2>&1 )
}

# Same as run_sbx, but launched from an arbitrary directory, so the store
# key's cwd slug can be varied across tests.
run_sbx_in() {
    ( cd "$1" && script -qec "$SBX $2 -- /bin/sh -c '$3'" /dev/null >/dev/null 2>&1 )
}

# The single archive directory produced by the most recent record session.
latest_archive() {
    find "$CHANGES_ROOT" -mindepth 2 -maxdepth 2 -type d 2>/dev/null |
        LC_ALL=C sort | tail -n1
}

@test "the copy perm is rejected with a message naming both replacements" {
    cat > "$PROJ/.sbx/profiles/fs/old.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/o","perm":"copy"}]}
EOF
    run bash -c "cd '$PROJ' && $SBX --fs old -- true 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *forked* ]]
    [[ "$output" == *record* ]]
}

@test "an unrecognized perm is rejected with a message naming it" {
    cat > "$PROJ/.sbx/profiles/fs/bogus.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/o","perm":"bogus"}]}
EOF
    run bash -c "cd '$PROJ' && $SBX --fs bogus -- true 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *bogus* ]]
}

@test "a mount missing perm entirely is rejected" {
    cat > "$PROJ/.sbx/profiles/fs/noperm.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/o"}]}
EOF
    run bash -c "cd '$PROJ' && $SBX --fs noperm -- true 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *null* ]]
}

@test "every shipped profile loads" {
    for p in "$BATS_TEST_DIRNAME"/../profiles/*/*.json; do
        run jq -e '[.mounts[]?.perm] | all(. == "ro" or . == "rw" or . == "dev" or . == "forked" or . == "record")' "$p"
        [ "$status" -eq 0 ]
    done
}

@test "a pre-migration cli store is carried over to the forked layout" {
    mkdir -p "$HOME/.local/state/sbx/profiles/cli/fk/$PROJ_SLUG/_tmp_fkmount"
    echo carried > "$HOME/.local/state/sbx/profiles/cli/fk/$PROJ_SLUG/_tmp_fkmount/old.txt"
    run_sbx "--cli fk" "cp /tmp/fkmount/old.txt /tmp/fkmount/seen.txt"
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/seen.txt")" = "carried" ]
    [ ! -d "$HOME/.local/state/sbx/profiles" ]
}

@test "a migration interrupted partway resumes on the next launch" {
    # Simulate an interrupt after one profile's store already moved: forked/
    # exists (with "moved" already in it) while a second store, "fk", is
    # still stranded under profiles/cli/.
    mkdir -p "$HOME/.local/state/sbx/forked/moved/$PROJ_SLUG/_tmp_fkmount"
    echo already > "$HOME/.local/state/sbx/forked/moved/$PROJ_SLUG/_tmp_fkmount/x.txt"
    mkdir -p "$HOME/.local/state/sbx/profiles/cli/fk/$PROJ_SLUG/_tmp_fkmount"
    echo carried > "$HOME/.local/state/sbx/profiles/cli/fk/$PROJ_SLUG/_tmp_fkmount/old.txt"
    run_sbx "--cli fk" "cp /tmp/fkmount/old.txt /tmp/fkmount/seen.txt"
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/seen.txt")" = "carried" ]
    [ "$(cat "$FORKED_ROOT/moved/$PROJ_SLUG/_tmp_fkmount/x.txt")" = "already" ]
    [ ! -d "$HOME/.local/state/sbx/profiles" ]
}

@test "a store present in both old and new locations is not destroyed, and warns" {
    mkdir -p "$HOME/.local/state/sbx/forked/fk/$PROJ_SLUG/_tmp_fkmount"
    echo new_store > "$HOME/.local/state/sbx/forked/fk/$PROJ_SLUG/_tmp_fkmount/marker.txt"
    OLD_STORE="$HOME/.local/state/sbx/profiles/cli/fk/$PROJ_SLUG/_tmp_fkmount"
    mkdir -p "$OLD_STORE"
    echo old_store > "$OLD_STORE/marker.txt"
    OUT="$ROOT/collision.out"
    ( cd "$PROJ" && script -qec "$SBX --cli fk -- /bin/sh -c true" /dev/null >"$OUT" 2>&1 )
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/marker.txt")" = "new_store" ]
    [ "$(cat "$OLD_STORE/marker.txt")" = "old_store" ]
    grep -qF "$HOME/.local/state/sbx/profiles/cli/fk" "$OUT"
}

@test "a forked mount is seeded from the host on first launch" {
    run_sbx "--cli fk" "cp /tmp/fkmount/host.txt /tmp/fkmount/seen.txt"
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/seen.txt")" = "hostfile" ]
}

@test "a forked mount carries a new file into the next launch" {
    run_sbx "--cli fk" "echo made > /tmp/fkmount/new.txt"
    run_sbx "--cli fk" "cp /tmp/fkmount/new.txt /tmp/fkmount/echoed.txt"
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/echoed.txt")" = "made" ]
}

@test "a forked mount stops seeing host edits after the first launch" {
    run_sbx "--cli fk" "true"
    echo edited > "$HOSTDIR/host.txt"
    run_sbx "--cli fk" "cp /tmp/fkmount/host.txt /tmp/fkmount/seen.txt"
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/seen.txt")" = "hostfile" ]
}

@test "a file deleted in a forked mount stays deleted" {
    run_sbx "--cli fk" "rm /tmp/fkmount/host.txt"
    [ -d "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount" ]
    run_sbx "--cli fk" "test -f /tmp/fkmount/host.txt && echo back > /tmp/fkmount/back.txt"
    [ ! -f "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/back.txt" ]
}

@test "a forked mount never modifies the host source" {
    run_sbx "--cli fk" "echo sandbox > /tmp/fkmount/host.txt; echo x > /tmp/fkmount/new.txt"
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/host.txt")" = "sandbox" ]
    [ "$(cat "$HOSTDIR/host.txt")" = "hostfile" ]
    [ ! -f "$HOSTDIR/new.txt" ]
}

@test "forked stores are keyed by launch directory" {
    OTHER="$ROOT/o"; mkdir -p "$OTHER"
    OTHER_SLUG=$(echo "$OTHER" | tr '/' '-')
    cp -a "$PROJ/.sbx" "$OTHER/.sbx"
    run_sbx "--cli fk" "echo here > /tmp/fkmount/where.txt"
    run_sbx_in "$OTHER" "--cli fk" "echo there > /tmp/fkmount/where.txt"
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/where.txt")" = "here" ]
    [ "$(cat "$FORKED_ROOT/fk/$OTHER_SLUG/_tmp_fkmount/where.txt")" = "there" ]
}

@test "a record mount archives a file the sandbox created" {
    run_sbx "--fs rec" "echo made > /tmp/recmount/new.txt"
    [ "$(cat "$(latest_archive)/_tmp_recmount/new.txt")" = "made" ]
}

@test "a record mount archives a file the sandbox modified" {
    run_sbx "--fs rec" "echo changed > /tmp/recmount/host.txt"
    [ "$(cat "$(latest_archive)/_tmp_recmount/host.txt")" = "changed" ]
}

@test "a record mount does not archive an untouched file" {
    run_sbx "--fs rec" "echo made > /tmp/recmount/new.txt"
    [ "$(cat "$(latest_archive)/_tmp_recmount/new.txt")" = "made" ]
    [ ! -f "$(latest_archive)/_tmp_recmount/host.txt" ]
}

@test "a record mount lists a deleted file and does not archive it" {
    run_sbx "--fs rec" "rm /tmp/recmount/host.txt"
    [ "$(cat "$(latest_archive)/_tmp_recmount.deleted")" = "host.txt" ]
    [ ! -f "$(latest_archive)/_tmp_recmount/host.txt" ]
}

@test "a record mount resets to host state on the next launch" {
    run_sbx "--fs rec" "echo made > /tmp/recmount/new.txt"
    run_sbx "--fs rec" "test -f /tmp/recmount/new.txt && echo leaked > /tmp/recmount/leak.txt || echo absent > /tmp/recmount/gone.txt"
    [ "$(cat "$(latest_archive)/_tmp_recmount/gone.txt")" = "absent" ]
    [ ! -f "$(latest_archive)/_tmp_recmount/leak.txt" ]
}

@test "a record mount never modifies the host source" {
    run_sbx "--fs rec" "echo sandbox > /tmp/recmount/host.txt; rm -f /tmp/recmount/host.txt; echo x > /tmp/recmount/new.txt"
    [ "$(cat "$(latest_archive)/_tmp_recmount/new.txt")" = "x" ]
    [ "$(cat "$HOSTDIR/host.txt")" = "hostfile" ]
    [ ! -f "$HOSTDIR/new.txt" ]
}

# The regression test for the defect this design exists to fix. Against the
# old sbx_copy_writeback, which diffed against the live host source at
# teardown, a host edit made mid-session shows up in the egress as though
# the sandbox had made it. The manifest baseline is captured at launch, so
# it cannot.
@test "a host edit during the session is not attributed to the sandbox" {
    ( cd "$PROJ" && script -qec \
        "$SBX --fs rec -- /bin/sh -c 'echo ready > /tmp/recmount/ready.txt; sleep 5'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    for _ in $(seq 1 40); do
        [[ -n "$(find "$HOME/.local/state/sbx/work" -name 'ready.txt' 2>/dev/null)" ]] && break
        sleep 0.25
    done
    if [[ -z "$(find "$HOME/.local/state/sbx/work" -name 'ready.txt' 2>/dev/null)" ]]; then
        echo "sandbox never wrote the marker; test cannot be meaningful" >&2
        return 1
    fi
    echo "edited-by-host" > "$HOSTDIR/host.txt"
    wait $bg
    [ ! -f "$(latest_archive)/_tmp_recmount/host.txt" ]
}

@test "the work directory is removed at teardown" {
    run_sbx "--fs rec" "echo made > /tmp/recmount/new.txt"
    [ "$(cat "$(latest_archive)/_tmp_recmount/new.txt")" = "made" ]
    [ -z "$(find "$HOME/.local/state/sbx/work" -mindepth 1 2>/dev/null)" ]
}

@test "a file-source forked mount is seeded and persists a modification across two launches" {
    local store="$FORKED_ROOT/fkfile/$PROJ_SLUG/_tmp_fkfile/hostfile.txt"
    run_sbx "--cli fkfile" "true"
    [ "$(cat "$store")" = "filedata" ]
    run_sbx "--cli fkfile" "echo modified > /tmp/fkfile"
    [ "$(cat "$store")" = "modified" ]
    run_sbx "--cli fkfile" "true"
    [ "$(cat "$store")" = "modified" ]
}

@test "a file-source record mount archives a modification" {
    run_sbx "--fs recfile" "echo changed > /tmp/recfile"
    [ "$(cat "$(latest_archive)/_tmp_recfile/hostfile.txt")" = "changed" ]
}

# A session killed by SIGKILL, OOM or power loss never runs teardown, so its
# $STATE_DIR/work/<name>/ tree survives. The next launch from the same
# directory reclaims the same name and points RECORD_WORK_DIR at that same
# path — and sbx_copy_seed's `cp -a "$src/." "$tmp/"` MERGES into a
# non-empty destination rather than replacing it. The ghost files then get
# hashed into the launch-time baseline, so they read as unchanged: the
# sandbox sees files the host does not have, and --changes never mentions
# them. The work tree must be removed before seeding.
@test "a stale work tree does not leak into the next session of the same name" {
    local work="$HOME/.local/state/sbx/work/p/_tmp_recmount"
    mkdir -p "$work"
    echo ghost > "$work/ghost.txt"
    run_sbx "--fs rec" "test -f /tmp/recmount/ghost.txt && echo saw > /tmp/recmount/saw.txt || echo clean > /tmp/recmount/clean.txt"
    [ -f "$(latest_archive)/_tmp_recmount/clean.txt" ]
    if [ -f "$(latest_archive)/_tmp_recmount/saw.txt" ]; then
        echo "the sandbox saw a ghost file from a crashed session's work tree" >&2
        return 1
    fi
}

# The other half of the same defect. sbx_manifest_build runs over the
# merged tree, so a ghost file is hashed into the BASELINE and reads as
# host state that was always there. Removing it inside the sandbox is then
# archived as the sandbox deleting a host file that never existed.
@test "a stale work tree's files are not folded into the next session's baseline" {
    local work="$HOME/.local/state/sbx/work/p/_tmp_recmount"
    mkdir -p "$work"
    echo ghost > "$work/ghost.txt"
    run_sbx "--fs rec" "rm -f /tmp/recmount/ghost.txt; echo made > /tmp/recmount/new.txt"
    [ "$(cat "$(latest_archive)/_tmp_recmount/new.txt")" = "made" ]
    local deleted
    deleted=$(cat "$(latest_archive)/_tmp_recmount.deleted" 2>/dev/null || true)
    if [[ "$deleted" == *ghost.txt* ]]; then
        echo "a ghost file was folded into the baseline and archived as a deletion: $deleted" >&2
        return 1
    fi
}

# A forked mount whose host source does not exist used to create the store
# as an empty directory anyway, then bind that directory at a destination
# that wants a FILE — and because the store now exists, the
# [[ ! -e "$f_store" ]] guard never fires again, so it stayed wrong even
# after the host file appeared. The trigger is ordinary: `sbx --cli claude`
# before Claude Code has ever written ~/.claude.json.
@test "a forked mount whose file source is absent creates no store" {
    cat > "$PROJ/.sbx/profiles/cli/fkabs.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR/absent.txt","dest":"/tmp/fkabsent","perm":"forked"}]}
EOF
    run_sbx "--cli fkabs" "true"
    if [ -e "$FORKED_ROOT/fkabs/$PROJ_SLUG/_tmp_fkabsent" ]; then
        echo "an absent source left a store behind: $(ls -la "$FORKED_ROOT/fkabs/$PROJ_SLUG/_tmp_fkabsent")" >&2
        return 1
    fi
}

@test "a forked mount whose file source appears later is seeded as a file" {
    cat > "$PROJ/.sbx/profiles/cli/fkabs.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR/absent.txt","dest":"/tmp/fkabsent","perm":"forked"}]}
EOF
    run_sbx "--cli fkabs" "true"
    echo appeared > "$HOSTDIR/absent.txt"
    run_sbx "--cli fkabs" "test -f /tmp/fkabsent && echo yes >> /tmp/fkabsent"
    local store="$FORKED_ROOT/fkabs/$PROJ_SLUG/_tmp_fkabsent/absent.txt"
    [ -f "$store" ]
    [ "$(cat "$store")" = "$(printf 'appeared\nyes')" ]
}
