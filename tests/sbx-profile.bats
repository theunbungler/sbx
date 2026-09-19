#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SBXP="$REPO/sbx-profile"
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/p"
    mkdir -p "$HOME/.config/sbx/profiles/fs" "$HOME/.config/sbx/profiles/net" "$PROJ"
    cd "$PROJ"
}

teardown() {
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]]; then
        rm -rf "$ROOT"
    fi
}

@test "ls matches sbx --list-profiles" {
    echo '{}' > "$HOME/.config/sbx/profiles/fs/sandbox.json"
    run "$SBXP" ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"  sandbox (User)"* ]]
    [[ "$output" == *"  sandbox (Global, shadowed by User)"* ]]
    local ls_out="$output"
    run "$REPO/sbx" --list-profiles
    [ "$output" = "$ls_out" ]
}

@test "check with no argument reports every visible profile and passes when none has errors" {
    run "$SBXP" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"fs/sandbox (global): ok"* ]]
    [[ "$output" == *"net/web (global): 1 warning"* ]]
    [[ "$output" == *"  warning: "*"*.google.com admits any address"* ]]
}

@test "check fails when a profile has errors, and names each problem" {
    echo '{"mount":[],"caps":"drop"}' > "$HOME/.config/sbx/profiles/fs/bad.json"
    run "$SBXP" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"fs/bad (user): 2 errors"* ]]
    [[ "$output" == *"  error:   $HOME/.config/sbx/profiles/fs/bad.json: .mount: unknown field for a fs profile"* ]]
    [[ "$output" == *"  error:   $HOME/.config/sbx/profiles/fs/bad.json: .caps: expected \"keep\", got \"drop\""* ]]
}

@test "check <type>/<name> resolves like a launch" {
    mkdir -p .sbx/profiles/fs
    echo '{"caps":"keep"}' > .sbx/profiles/fs/sandbox.json
    run "$SBXP" check fs/sandbox
    [ "$status" -eq 1 ]
    [[ "$output" == *"fs/sandbox (project): 1 error"* ]]
    [[ "$output" == *"project profiles may not set caps"* ]]
}

@test "check <path> takes the type from the parent directory" {
    echo '{"allow":["github.com"]}' > "$HOME/.config/sbx/profiles/net/gh.json"
    run "$SBXP" check "$HOME/.config/sbx/profiles/net/gh.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"net/gh (user): ok"* ]]
    mkdir -p "$ROOT/elsewhere"
    echo '{}' > "$ROOT/elsewhere/x.json"
    run "$SBXP" check "$ROOT/elsewhere/x.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"must be cli, fs or net"* ]]
}

@test "check treats a symlinked project profile as project even by absolute path" {
    mkdir -p .sbx/profiles/fs "$ROOT/outside"
    echo '{"caps":"drop"}' > "$ROOT/outside/evil.json"
    ln -s "$ROOT/outside/evil.json" .sbx/profiles/fs/evil.json
    run "$SBXP" check "$PWD/.sbx/profiles/fs/evil.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"fs/evil (project)"* ]]
    [[ "$output" == *"project profiles may not set caps"* ]]
}

@test "check <path> reports a clear error for a directory argument" {
    mkdir -p "$ROOT/somedir"
    run "$SBXP" check "$ROOT/somedir"
    [ "$status" -eq 2 ]
    [[ "$output" == *"is a directory, not a profile file"* ]]
}

@test "check <path> reports a clear error for a nonexistent, non type/name path" {
    run "$SBXP" check "$ROOT/nope/missing.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no profile file at"* ]]
}

@test "check sanitizes profile-authored text" {
    printf '{"workingDirectory":"/x\\u001b[2Kbad"}\n' > "$HOME/.config/sbx/profiles/fs/esc.json"
    run "$SBXP" check fs/esc
    if [[ "$output" == *$'\033'* ]]; then return 1; fi
    [[ "$output" == *"[2Kbad"* ]]
}

@test "usage errors exit 2; help exits 0" {
    run "$SBXP"
    [ "$status" -eq 2 ]
    run "$SBXP" frobnicate
    [ "$status" -eq 2 ]
    run "$SBXP" check a b
    [ "$status" -eq 2 ]
    run "$SBXP" check ssh/x
    [ "$status" -eq 2 ]
    run "$SBXP" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"new <type> <name>"* ]]
}
