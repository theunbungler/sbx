#!/usr/bin/env bats

# sbx --dry-run: what a launch would do, without doing any of it.

setup_file() {
    # A copy of /usr/bin as symlinks, so a test can remove one tool.
    BASE_BIN="$BATS_FILE_TMPDIR/bin"
    mkdir -p "$BASE_BIN"
    local f
    for f in /usr/bin/* /usr/local/bin/*; do
        if [[ -x "$f" && ! -e "$BASE_BIN/${f##*/}" ]]; then
            ln -s "$f" "$BASE_BIN/${f##*/}"
        fi
    done
    export BASE_BIN
}

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/proj"
    mkdir -p "$HOME/.config/sbx/profiles/fs" "$HOME/.config/sbx/profiles/cli" "$PROJ" "$ROOT/src"
    echo data > "$ROOT/src/f"
    printf 'ID=manjaro\nID_LIKE=arch\n' > "$ROOT/arch"
}

teardown() {
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]]; then
        rm -rf "$ROOT"
    fi
}

dry() {   # <sbx args...>
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --dry-run "$@"
}

nothing_created() {
    if [[ -e "$HOME/.local/state/sbx" ]]; then
        echo "dry run created $HOME/.local/state/sbx:" >&2
        find "$HOME/.local/state/sbx" >&2
        return 1
    fi
}

@test "a clean dry run reports the plan, creates nothing and exits 0" {
    dry --fs sandbox
    [ "$status" -eq 0 ]
    [[ "$output" == *"Profiles   fs/sandbox (global)"* ]]
    [[ "$output" == *"Result     the launch would proceed"* ]]
    nothing_created
}

@test "--json prints one parseable document with writes and needs" {
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>/dev/null' _ "$PROJ" "$SBX" --dry-run --json --fs sandbox
    [ "$status" -eq 0 ]
    [ "$(jq -r '.needs.ok' <<< "$output")" = "true" ]
    [ "$(jq -r '.writes[-1].kind' <<< "$output")" = "temporary" ]
    [ "$(jq -r '.profiles[0].name' <<< "$output")" = "sandbox" ]
    nothing_created
}

@test "a validation error is reported and exits 1" {
    echo '{"mount":[]}' > "$HOME/.config/sbx/profiles/fs/bad.json"
    dry --fs bad
    [ "$status" -eq 1 ]
    [[ "$output" == *".mount: unknown field for a fs profile"* ]]
    [[ "$output" == *"Result     the launch would stop"* ]]
    nothing_created
}

@test "a missing dependency is reported with the install command and exits 1" {
    mkdir -p "$ROOT/bin"
    cp -a "$BASE_BIN/." "$ROOT/bin/"
    rm "$ROOT/bin/pasta"
    run env PATH="$ROOT/bin" SBX_OS_RELEASE="$ROOT/arch" \
        bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --dry-run --net web
    [ "$status" -eq 1 ]
    [[ "$output" == *"net ✗ missing pasta"* ]]
    [[ "$output" == *"install: sudo pacman -S passt"* ]]
    nothing_created
}

@test "a forked mount shows will seed, then exists" {
    cat > "$HOME/.config/sbx/profiles/cli/keep.json" <<EOF
{"mounts":[{"source":"$ROOT/src","dest":"/data","perm":"forked"}]}
EOF
    dry --cli keep
    [ "$status" -eq 0 ]
    [[ "$output" == *"forked  $ROOT/src → /data  (will seed, "* ]]
    nothing_created
    slug=$(printf '%s' "$PROJ" | tr '/' '-')
    mkdir -p "$HOME/.local/state/sbx/forked/keep/$slug/_data"
    dry --cli keep
    [[ "$output" == *"forked  $ROOT/src → /data  (exists)"* ]]
}

@test "passthrough values never appear" {
    echo '{"passthrough":["SBX_DRY_SECRET"]}' > "$HOME/.config/sbx/profiles/fs/pt.json"
    export SBX_DRY_SECRET=hunter2
    dry --fs pt
    [[ "$output" == *"Passthru   SBX_DRY_SECRET"* ]]
    if [[ "$output" == *hunter2* ]]; then return 1; fi
}

@test "a tracked project profile does not prompt" {
    mkdir -p "$PROJ/.sbx/profiles/fs"
    echo '{"description":"t"}' > "$PROJ/.sbx/profiles/fs/t.json"
    git -C "$PROJ" init -q
    git -C "$PROJ" add -f .sbx/profiles/fs/t.json
    dry --fs t
    [ "$status" -eq 0 ]
    [[ "$output" == *"Confirm    ./.sbx/profiles/fs/t.json would prompt"* ]]
    if [[ "$output" == *"refusing to use a project profile"* ]]; then return 1; fi
    nothing_created
}

@test "--dry-run refuses to combine with state commands, in either order" {
    dry --gc
    [ "$status" -eq 2 ]
    [[ "$output" == *"--dry-run applies only to a launch"* ]]
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --gc --dry-run
    [ "$status" -eq 2 ]
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --fs sandbox --reseed --dry-run
    [ "$status" -eq 2 ]
    nothing_created
}

@test "a real launch still initializes state" {
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --list-sessions
    [ -d "$HOME/.local/state/sbx" ]
}
