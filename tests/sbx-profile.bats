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

@test "new --user writes the template and says what to do next" {
    run "$SBXP" new net api --user
    [ "$status" -eq 0 ]
    [ "$(jq -c . "$HOME/.config/sbx/profiles/net/api.json")" = '{"description":"api","dns":"1.1.1.1","allow":[],"ports":[443]}' ]
    [[ "$output" == *"Created ~/.config/sbx/profiles/net/api.json"* ]]
    [[ "$output" == *"allow        hostnames"* ]]
    [[ "$output" == *"Next: sbx --dry-run --net api"* ]]
}

@test "new --local writes under ./.sbx and explains the trust rule" {
    run "$SBXP" new fs work --local
    [ "$status" -eq 0 ]
    [ -f "$PROJ/.sbx/profiles/fs/work.json" ]
    [[ "$output" == *"untracked ./.sbx profile without asking"* ]]
}

@test "without a location flag: an error off a terminal, a prompt on one" {
    run bash -c "cd '$PROJ' && '$SBXP' new fs x < /dev/null 2>&1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--user"*"--local"* ]]
    if [[ -e "$PROJ/.sbx" || -e "$HOME/.config/sbx/profiles/fs/x.json" ]]; then return 1; fi
    run bash -c "cd '$PROJ' && printf 'l\n' | script -qec \"'$SBXP' new fs x\" /dev/null"
    [ "$status" -eq 0 ]
    [ -f "$PROJ/.sbx/profiles/fs/x.json" ]
}

@test "new never overwrites" {
    "$SBXP" new fs keep --user > /dev/null
    echo '{"description":"mine"}' > "$HOME/.config/sbx/profiles/fs/keep.json"
    run "$SBXP" new fs keep --user
    [ "$status" -eq 1 ]
    [[ "$output" == *"already exists"* ]]
    [ "$(jq -r .description "$HOME/.config/sbx/profiles/fs/keep.json")" = "mine" ]
}

@test "--from copies a profile under a new description" {
    run "$SBXP" new net web2 --user --from web
    [ "$status" -eq 0 ]
    [ "$(jq -r .description "$HOME/.config/sbx/profiles/net/web2.json")" = "web2 (copied from net/web)" ]
    [ "$(jq -c .allow "$HOME/.config/sbx/profiles/net/web2.json")" = "$(jq -c .allow "$REPO/profiles/net/web.json")" ]
    [[ "$output" == *"warning: "* ]]
}

@test "--local --from refuses a profile with restricted fields" {
    run "$SBXP" new fs pod --local --from fs/podman
    [ "$status" -eq 1 ]
    [[ "$output" == *"sets caps docker_api, which a project profile may not set"* ]]
    if [[ -e "$PROJ/.sbx" ]]; then return 1; fi
}

@test "--from must match the type" {
    run "$SBXP" new fs x --user --from net/web
    [ "$status" -eq 2 ]
}

@test "shadowing is reported both ways" {
    run "$SBXP" new fs sandbox --user
    [[ "$output" == *"Note: this profile hides the global profile"* ]]
    mkdir -p .sbx/profiles/fs
    echo '{}' > .sbx/profiles/fs/mine.json
    run bash -c "cd '$PROJ' && '$SBXP' new fs mine --user 2>&1"
    [[ "$output" == *"Warning: the project profile ./.sbx/profiles/fs/mine.json takes precedence"* ]]
}

@test "bad types and names are refused and write nothing" {
    run "$SBXP" new ssh x --user
    [ "$status" -eq 2 ]
    run "$SBXP" new fs ../evil --user
    [ "$status" -eq 2 ]
    run "$SBXP" new fs x --user --local
    [ "$status" -eq 2 ]
    run "$SBXP" new fs x --user --bogus
    [ "$status" -eq 2 ]
    if [[ -e "$HOME/.config/sbx/evil.json" || -e "$HOME/.config/sbx/profiles/fs/x.json" ]]; then return 1; fi
}

@test "every created profile validates" {
    local type
    for type in cli fs net; do
        "$SBXP" new "$type" "t$type" --user > /dev/null
        run "$SBXP" check "$type/t$type"
        [ "$status" -eq 0 ]
        [[ "$output" == *"$type/t$type (user): ok"* ]]
    done
}

@test "--local refuses when ./.sbx is a symlink" {
    mkdir -p "$ROOT/outside"
    ln -s "$ROOT/outside" .sbx
    run "$SBXP" new fs x --local
    [ "$status" -eq 1 ]
    [[ "$output" == *"./.sbx is a symbolic link"* ]]
    if [[ -e "$ROOT/outside/x.json" || -e "$ROOT/outside/profiles/fs/x.json" ]]; then return 1; fi
}

@test "--local refuses when ./.sbx/profiles/<type> is a symlink" {
    mkdir -p "$ROOT/outside" .sbx/profiles
    ln -s "$ROOT/outside" .sbx/profiles/fs
    run "$SBXP" new fs x --local
    [ "$status" -eq 1 ]
    [[ "$output" == *"./.sbx/profiles/fs is a symbolic link"* ]]
    if [[ -e "$ROOT/outside/x.json" ]]; then return 1; fi
}

@test "--user still writes through a symlinked config directory" {
    mkdir -p "$ROOT/elsewhere"
    rm -rf "$HOME/.config/sbx/profiles"
    ln -s "$ROOT/elsewhere" "$HOME/.config/sbx/profiles"
    run "$SBXP" new fs sym --user
    [ "$status" -eq 0 ]
    [ -f "$ROOT/elsewhere/fs/sym.json" ]
}

@test "--from sanitizes an escape-laden source name in error messages" {
    # An escape-laden --from argument fails the name check in
    # sbx_profile_resolve before any file is ever looked at; the escape
    # must not leak into the (sanitized) error either way.
    run "$SBXP" new fs y --user --from $'fs/\x1b[2Kbad'
    [ "$status" -eq 1 ]
    if [[ "$output" == *$'\033'* ]]; then return 1; fi
    [[ "$output" == *"[2Kbad"* ]]
    [[ "$output" == *"is not a profile name"* ]]
    if [[ -e "$HOME/.config/sbx/profiles/fs/y.json" ]]; then return 1; fi
}
