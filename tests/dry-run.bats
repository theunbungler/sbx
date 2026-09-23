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
    mkdir -p "$ROOT/sysmod/veth"
    export SBX_SYS_MODULE_DIR="$ROOT/sysmod"
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

# M5: a missing NON-required core tool (anything but jq/realpath/envsubst)
# must not stop the dry run before the report — it belongs in Needs, and
# .proceed is what goes false, not an early exit.
@test "a missing non-required core tool still produces the report, with exit 1" {
    mkdir -p "$ROOT/bin"
    cp -a "$BASE_BIN/." "$ROOT/bin/"
    rm "$ROOT/bin/tmux"
    run env PATH="$ROOT/bin" SBX_OS_RELEASE="$ROOT/arch" \
        bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --dry-run --fs sandbox
    [ "$status" -eq 1 ]
    [[ "$output" == *"core ✗ missing tmux"* ]]
    [[ "$output" == *"Result     the launch would stop"* ]]
    nothing_created
}

# I1: jq's default output leaves C1 controls (U+0080-U+009F) and DEL
# unescaped in UTF-8 output; some terminals act on those bytes.
@test "--json escapes C1 controls and DEL instead of printing them raw" {
    printf '{"env":{"BAD":"a\xc2\x9bb\x7fc"}}' > "$HOME/.config/sbx/profiles/fs/badenv.json"
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>/dev/null' _ "$PROJ" "$SBX" --dry-run --json --fs badenv
    [ "$status" -eq 0 ]
    esc_c1=$(printf '\\u009b')
    esc_del=$(printf '\\u007f')
    [[ "$output" == *"$esc_c1"* ]]
    [[ "$output" == *"$esc_del"* ]]
    if [[ "$output" == *$'\xc2\x9b'* ]]; then return 1; fi
    if [[ "$output" == *$'\x7f'* ]]; then return 1; fi
}

# I2: a launch this HOME would actually refuse (session socket path over
# the 100-byte limit) must be reported as a stop, not "would proceed".
@test "a HOME long enough to exceed the socket limit is reported as a stop" {
    local longhome="$ROOT/$(printf 'a%.0s' {1..80})/h"
    mkdir -p "$longhome"
    run env HOME="$longhome" \
        bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --dry-run --fs sandbox
    [ "$status" -eq 1 ]
    [[ "$output" == *"session socket path is too long"* ]]
    [[ "$output" == *"the launch would stop"* ]]
    if [[ -e "$longhome/.local/state/sbx" ]]; then
        echo "dry run created $longhome/.local/state/sbx:" >&2
        return 1
    fi
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

@test "env values are shown unexpanded, in text and --json, so host secrets are never printed" {
    echo '{"env":{"TOK":"$SBX_DRY_TOKEN"}}' > "$HOME/.config/sbx/profiles/fs/envtok.json"
    export SBX_DRY_TOKEN=hunter2
    dry --fs envtok
    [[ "$output" == *'TOK=$SBX_DRY_TOKEN'* ]]
    if [[ "$output" == *hunter2* ]]; then return 1; fi

    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>/dev/null' _ "$PROJ" "$SBX" --dry-run --json --fs envtok
    [ "$status" -eq 0 ]
    [ "$(jq -r '.env[0].raw' <<< "$output")" = '$SBX_DRY_TOKEN' ]
    [ "$(jq -r '.env[0] | has("value")' <<< "$output")" = "false" ]
    if [[ "$output" == *hunter2* ]]; then return 1; fi
}

@test "the PATH env value is shown unexpanded, in text and --json, so host secrets are never printed" {
    echo '{"env":{"PATH":"$SBX_DRY_PATHSECRET:/usr/bin"}}' > "$HOME/.config/sbx/profiles/fs/envpath.json"
    export SBX_DRY_PATHSECRET=hunter2path
    dry --fs envpath
    [[ "$output" == *'$SBX_DRY_PATHSECRET:/usr/bin'* ]]
    if [[ "$output" == *hunter2path* ]]; then return 1; fi

    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>/dev/null' _ "$PROJ" "$SBX" --dry-run --json --fs envpath
    [ "$status" -eq 0 ]
    if [[ "$output" == *hunter2path* ]]; then return 1; fi
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

@test "a --list-sessions run still initializes state" {
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --list-sessions
    [ -d "$HOME/.local/state/sbx" ]
}

@test "--dry-run --help prints usage, exits 0 and creates nothing" {
    dry --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    nothing_created
}

@test "--help --dry-run prints usage, exits 0 and creates nothing" {
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --help --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    nothing_created
}

@test "an unrecognized --option is rejected before it can become the payload" {
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --dryrun --fs sandbox
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown option '--dryrun'"* ]]
    nothing_created
}

@test "--json before --dry-run is not a recognized option and is rejected" {
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --json --dry-run --fs sandbox
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown option '--json'"* ]]
    nothing_created
}

@test "a payload after -- that starts with -- is not rejected" {
    dry --fs sandbox -- --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"Result     the launch would proceed"* ]]
    nothing_created
}

@test "a payload command word followed by a --flag is not rejected" {
    dry --fs sandbox mytool --flag
    [ "$status" -eq 0 ]
    [[ "$output" == *"Result     the launch would proceed"* ]]
    nothing_created
}
