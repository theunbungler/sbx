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
    STORE_ROOT="$HOME/.local/state/sbx/profiles/cli"
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

    cat > "$PROJ/.sbx/profiles/cli/tst.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/tstmount","perm":"copy"}]}
EOF
    cat > "$PROJ/.sbx/profiles/fs/tstfs.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/tstmount","perm":"copy"}]}
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

@test "a cli copy mount persists a new file into the profile store" {
    run_sbx "--cli tst" "echo made > /tmp/tstmount/new.txt"
    [ "$(cat "$STORE_ROOT/tst/$PROJ_SLUG/_tmp_tstmount/new.txt")" = "made" ]
}

@test "a file created in one session is visible in the next" {
    run_sbx "--cli tst" "echo made > /tmp/tstmount/new.txt"
    run_sbx "--cli tst" "cp /tmp/tstmount/new.txt /tmp/tstmount/echoed.txt"
    [ "$(cat "$STORE_ROOT/tst/$PROJ_SLUG/_tmp_tstmount/echoed.txt")" = "made" ]
}

@test "a stored file survives a session that never touches it" {
    run_sbx "--cli tst" "echo made > /tmp/tstmount/new.txt"
    run_sbx "--cli tst" "true"
    [ -f "$STORE_ROOT/tst/$PROJ_SLUG/_tmp_tstmount/new.txt" ]
}

@test "host changes reach the sandbox for files it has not touched" {
    run_sbx "--cli tst" "echo made > /tmp/tstmount/new.txt"
    echo updated > "$HOSTDIR/host.txt"
    run_sbx "--cli tst" "cp /tmp/tstmount/host.txt /tmp/tstmount/seen.txt"
    [ "$(cat "$STORE_ROOT/tst/$PROJ_SLUG/_tmp_tstmount/seen.txt")" = "updated" ]
}

@test "the store shadows later host changes to the same file" {
    run_sbx "--cli tst" "echo sandbox > /tmp/tstmount/host.txt"
    echo updated > "$HOSTDIR/host.txt"
    run_sbx "--cli tst" "cp /tmp/tstmount/host.txt /tmp/tstmount/seen.txt"
    [ "$(cat "$STORE_ROOT/tst/$PROJ_SLUG/_tmp_tstmount/seen.txt")" = "sandbox" ]
}

@test "a file deleted in the sandbox returns on the next launch" {
    run_sbx "--cli tst" "rm /tmp/tstmount/host.txt"
    run_sbx "--cli tst" "test -f /tmp/tstmount/host.txt && echo back > /tmp/tstmount/back.txt"
    [ -f "$STORE_ROOT/tst/$PROJ_SLUG/_tmp_tstmount/back.txt" ]
}

@test "fs profile copy mounts stay ephemeral and create no store" {
    run_sbx "--fs tstfs" "echo made > /tmp/tstmount/new.txt"
    [ ! -d "$HOME/.local/state/sbx/profiles" ]
    run bash -c "find '$HOME/.local/state/sbx' -path '*/fs/_tmp_tstmount/new.txt'"
    [ -n "$output" ]
}

@test "the host source directory is never modified" {
    run_sbx "--cli tst" "echo sandbox > /tmp/tstmount/host.txt; echo x > /tmp/tstmount/new.txt"
    [ "$(cat "$HOSTDIR/host.txt")" = "hostfile" ]
    [ ! -f "$HOSTDIR/new.txt" ]
}

@test "different launch directories get independent cli-profile stores" {
    PROJ2="$ROOT/p2"
    mkdir -p "$PROJ2/.sbx/profiles/cli"
    cat > "$PROJ2/.sbx/profiles/cli/tst.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/tstmount","perm":"copy"}]}
EOF
    PROJ2_SLUG=$(echo "$PROJ2" | tr '/' '-')

    run_sbx "--cli tst" "echo fromproj1 > /tmp/tstmount/marker1.txt"
    run_sbx_in "$PROJ2" "--cli tst" "echo fromproj2 > /tmp/tstmount/marker2.txt"

    [ "$(cat "$STORE_ROOT/tst/$PROJ_SLUG/_tmp_tstmount/marker1.txt")" = "fromproj1" ]
    [ ! -f "$STORE_ROOT/tst/$PROJ_SLUG/_tmp_tstmount/marker2.txt" ]

    [ "$(cat "$STORE_ROOT/tst/$PROJ2_SLUG/_tmp_tstmount/marker2.txt")" = "fromproj2" ]
    [ ! -f "$STORE_ROOT/tst/$PROJ2_SLUG/_tmp_tstmount/marker1.txt" ]
}
