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
    [[ "$output" == *"fs/sandbox (global, $REPO/profiles/fs/sandbox.json): ok"* ]]
    [[ "$output" == *"net/web (global, $REPO/profiles/net/web.json): 1 warning"* ]]
    [[ "$output" == *"  warning: "*"*.google.com admits any address"* ]]
}

@test "check fails when a profile has errors, and names each problem" {
    echo '{"mount":[],"caps":"drop"}' > "$HOME/.config/sbx/profiles/fs/bad.json"
    run "$SBXP" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"fs/bad (user, ~/.config/sbx/profiles/fs/bad.json): 2 errors"* ]]
    [[ "$output" == *"  error:   .mount: unknown field for a fs profile"* ]]
    [[ "$output" == *'  error:   .caps: expected "keep", got "drop"'* ]]
    # the path prefix that sbx_profile_check produces is stripped, not just hidden
    if [[ "$output" == *"$HOME/.config/sbx/profiles/fs/bad.json: .mount"* ]]; then return 1; fi
}

@test "check <type>/<name> resolves like a launch" {
    mkdir -p .sbx/profiles/fs
    echo '{"caps":"keep"}' > .sbx/profiles/fs/sandbox.json
    run "$SBXP" check fs/sandbox
    [ "$status" -eq 1 ]
    [[ "$output" == *"fs/sandbox (project, ./.sbx/profiles/fs/sandbox.json): 1 error"* ]]
    [[ "$output" == *"project profiles may not set caps"* ]]
}

@test "check <path> takes the type from the parent directory" {
    echo '{"allow":["github.com"]}' > "$HOME/.config/sbx/profiles/net/gh.json"
    run "$SBXP" check "$HOME/.config/sbx/profiles/net/gh.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"net/gh (user, ~/.config/sbx/profiles/net/gh.json): ok"* ]]
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
    [[ "$output" == *"fs/evil (project, $PWD/.sbx/profiles/fs/evil.json)"* ]]
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
    printf '{"x\\u001b[2Kbad": 1}\n' > "$HOME/.config/sbx/profiles/fs/esc.json"
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

@test "a read-only destination directory reports 'cannot', not 'already exists'" {
    chmod 555 "$HOME/.config/sbx/profiles/fs"
    run "$SBXP" new fs blocked --user
    chmod 755 "$HOME/.config/sbx/profiles/fs"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error: cannot write"* ]]
    if [[ "$output" == *"already exists"* ]]; then return 1; fi
    if [[ -e "$HOME/.config/sbx/profiles/fs/blocked.json" ]]; then return 1; fi
}

@test "a read-only config directory reports 'cannot create'" {
    rmdir "$HOME/.config/sbx/profiles/net"
    chmod 555 "$HOME/.config/sbx/profiles"
    run "$SBXP" new net blocked --user
    chmod 755 "$HOME/.config/sbx/profiles"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error: cannot create"* ]]
}

@test "a 201-character name is rejected" {
    local long
    long="$(printf 'a%.0s' $(seq 1 201))"
    run "$SBXP" new fs "$long" --user
    [ "$status" -eq 2 ]
}

@test "new never writes sbx's own global profile directory" {
    rm -rf "$HOME/.config/sbx/profiles"
    ln -s "$REPO/profiles" "$HOME/.config/sbx/profiles"
    run "$SBXP" new fs viaglobal --user
    [ "$status" -eq 1 ]
    [[ "$output" == *"is sbx's global profile directory; sbx-profile never writes there."* ]]
    if [[ -e "$REPO/profiles/fs/viaglobal.json" ]]; then return 1; fi
}

@test "--from copies a profile under a new description" {
    run "$SBXP" new net web2 --user --from web
    [ "$status" -eq 0 ]
    [ "$(jq -r .description "$HOME/.config/sbx/profiles/net/web2.json")" = "web2 (copied from net/web, global)" ]
    [ "$(jq -c .allow "$HOME/.config/sbx/profiles/net/web2.json")" = "$(jq -c .allow "$REPO/profiles/net/web.json")" ]
    [[ "$output" == *"warning: "* ]]
    [[ "$output" == *"Copied from $REPO/profiles/net/web.json (global)."* ]]
}

@test "--local --from refuses a profile with restricted fields" {
    run "$SBXP" new fs pod --local --from fs/podman
    [ "$status" -eq 1 ]
    [[ "$output" == *"sets caps docker_api, which a project profile may not set"* ]]
    if [[ -e "$PROJ/.sbx" ]]; then return 1; fi
}

@test "--from refuses a project-origin source with restricted fields, for --user too" {
    mkdir -p .sbx/profiles/fs
    echo '{"description":"mine","caps":"keep"}' > .sbx/profiles/fs/mine.json
    run "$SBXP" new fs copy --user --from fs/mine
    [ "$status" -eq 1 ]
    [[ "$output" == *"is a project profile and sets caps, which a project profile may not set; sbx-profile will not copy it into a profile that would allow them."* ]]
    if [[ -e "$HOME/.config/sbx/profiles/fs/copy.json" ]]; then return 1; fi
}

@test "--from a clean project-origin source is allowed and named (project)" {
    mkdir -p .sbx/profiles/fs
    echo '{"description":"clean"}' > .sbx/profiles/fs/clean.json
    run "$SBXP" new fs copy2 --user --from fs/clean
    [ "$status" -eq 0 ]
    [ "$(jq -r .description "$HOME/.config/sbx/profiles/fs/copy2.json")" = "copy2 (copied from fs/clean, project)" ]
    [[ "$output" == *"Copied from ./.sbx/profiles/fs/clean.json (project)."* ]]
}

@test "--from a user-origin source is named (user)" {
    "$SBXP" new fs usersrc --user > /dev/null
    run "$SBXP" new fs copy3 --user --from fs/usersrc
    [ "$status" -eq 0 ]
    [ "$(jq -r .description "$HOME/.config/sbx/profiles/fs/copy3.json")" = "copy3 (copied from fs/usersrc, user)" ]
    [[ "$output" == *"Copied from ~/.config/sbx/profiles/fs/usersrc.json (user)."* ]]
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

@test "check with no argument marks a shadowed profile and does not count its errors" {
    # global fs/sandbox.json is clean; shadow it with a user profile that
    # has an error. The shadowed (global) one must still print but not
    # gate the exit status; the shadowing (user) one is what a launch
    # actually uses and does gate it.
    echo '{"caps":"drop"}' > "$HOME/.config/sbx/profiles/fs/sandbox.json"
    run "$SBXP" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"fs/sandbox (user, ~/.config/sbx/profiles/fs/sandbox.json): 1 error"* ]]
    [[ "$output" == *"fs/sandbox (global, $REPO/profiles/fs/sandbox.json, shadowed by user): ok"* ]]
}

@test "--user --user is not an error; --user --local still is" {
    run "$SBXP" new fs dup --user --user
    [ "$status" -eq 0 ]
    [ -f "$HOME/.config/sbx/profiles/fs/dup.json" ]
    run "$SBXP" new fs dup2 --user --local
    [ "$status" -eq 2 ]
    [[ "$output" == *"choose one"* ]]
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
        [[ "$output" == *"$type/t$type (user, ~/.config/sbx/profiles/$type/t$type.json): ok"* ]]
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
