#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/profiles.sh"
    W="$BATS_TEST_TMPDIR/w"
    PROJ="$W/proj"; CFG="$W/cfg"; GLOBAL="$W/global"
    mkdir -p "$PROJ/.sbx/profiles/fs" "$CFG/profiles/fs" "$CFG/profiles/net" "$GLOBAL/fs" "$GLOBAL/cli"
    echo '{}' > "$PROJ/.sbx/profiles/fs/shared.json"
    echo '{}' > "$CFG/profiles/fs/shared.json"
    echo '{}' > "$CFG/profiles/fs/mine.json"
    echo '{}' > "$CFG/profiles/net/web.json"
    echo '{}' > "$GLOBAL/fs/shared.json"
    echo '{}' > "$GLOBAL/fs/base.json"
    echo '{}' > "$GLOBAL/cli/dev.json"
    cd "$PROJ"
}

@test "resolve prefers the project over user over global" {
    run sbx_profile_resolve fs shared "$CFG" "$GLOBAL"
    [ "$status" -eq 0 ]
    [ "$output" = "./.sbx/profiles/fs/shared.json" ]
    run sbx_profile_resolve fs mine "$CFG" "$GLOBAL"
    [ "$output" = "$CFG/profiles/fs/mine.json" ]
    run sbx_profile_resolve fs base "$CFG" "$GLOBAL"
    [ "$output" = "$GLOBAL/fs/base.json" ]
}

@test "resolve strips a type prefix" {
    run sbx_profile_resolve cli cli/dev "$CFG" "$GLOBAL"
    [ "$output" = "$GLOBAL/cli/dev.json" ]
}

@test "resolve rejects anything that isn't a bare name" {
    echo '{}' > "$W/direct.json"
    local msg="is not a profile name. Profiles are loaded by name from ./.sbx/profiles, ~/.config/sbx/profiles or the global profiles directory."
    run sbx_profile_resolve fs "$W/direct.json" "$CFG" "$GLOBAL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$msg"* ]]
    run sbx_profile_resolve fs "shared.json" "$CFG" "$GLOBAL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$msg"* ]]
    run sbx_profile_resolve fs "/etc/passwd" "$CFG" "$GLOBAL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$msg"* ]]
    run sbx_profile_resolve fs "a/b/c" "$CFG" "$GLOBAL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$msg"* ]]
}

@test "resolve never picks up a same-named file in the launch directory" {
    echo '{"description":"launch-dir decoy"}' > "$PROJ/web.json"
    run sbx_profile_resolve net web "$CFG" "$GLOBAL"
    [ "$status" -eq 0 ]
    [ "$output" = "$CFG/profiles/net/web.json" ]
}

@test "resolve fails with the existing message" {
    run sbx_profile_resolve net nope "$CFG" "$GLOBAL"
    [ "$status" -eq 1 ]
    [ "$output" = "Error: Profile 'nope' of type 'net' not found." ]
}

@test "origin classifies each location" {
    run sbx_profile_origin ./.sbx/profiles/fs/shared.json "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "project" ]
    run sbx_profile_origin "$CFG/profiles/fs/mine.json" "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "user" ]
    run sbx_profile_origin "$GLOBAL/fs/base.json" "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "global" ]
    run sbx_profile_origin "$W/direct.json" "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "path" ]
}

@test "origin is not fooled by a sibling directory sharing a prefix" {
    mkdir -p "$W/proj/.sbxevil"
    echo '{}' > "$W/proj/.sbxevil/x.json"
    run sbx_profile_origin "$W/proj/.sbxevil/x.json" "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "path" ]
}

@test "a symlink inside .sbx/profiles pointing outside the repo still classifies as project" {
    mkdir -p "$W/outside"
    echo '{}' > "$W/outside/evil.json"
    ln -s "$W/outside/evil.json" "$PROJ/.sbx/profiles/fs/evil.json"
    run sbx_profile_origin ./.sbx/profiles/fs/evil.json "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "project" ]
}

@test "a symlinked type directory under .sbx/profiles still classifies as project" {
    mkdir -p "$W/elsewhere"
    echo '{}' > "$W/elsewhere/x.json"
    rm -rf "$PROJ/.sbx/profiles/fs"
    ln -s "$W/elsewhere" "$PROJ/.sbx/profiles/fs"
    run sbx_profile_origin "$PROJ/.sbx/profiles/fs/x.json" "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "project" ]
}

@test "an absolute path to a symlinked project profile still classifies as project" {
    mkdir -p "$W/outside"
    echo '{}' > "$W/outside/evil.json"
    ln -s "$W/outside/evil.json" "$PROJ/.sbx/profiles/fs/evil.json"
    run sbx_profile_origin "$PROJ/.sbx/profiles/fs/evil.json" "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "project" ]
    # the sibling-prefix collision must still classify as "path" even
    # when passed as an absolute path, not just relative.
    mkdir -p "$W/proj/.sbxevil"
    echo '{}' > "$W/proj/.sbxevil/x.json"
    run sbx_profile_origin "$W/proj/.sbxevil/x.json" "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "path" ]
}

@test "an ordinary project profile still classifies as project" {
    run sbx_profile_origin ./.sbx/profiles/fs/shared.json "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "project" ]
}

@test "list prints every profile with its source label" {
    run sbx_profile_list "$CFG" "$GLOBAL"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Available Profiles:" ]
    [[ "$output" == *"  shared (Project)"* ]]
    [[ "$output" == *"  mine (User)"* ]]
    [[ "$output" == *"  base (Global)"* ]]
    [[ "$output" == *"  web (User)"* ]]
}

@test "valid types and names" {
    sbx_profile_valid_type cli
    sbx_profile_valid_type fs
    sbx_profile_valid_type net
    if sbx_profile_valid_type ssh; then return 1; fi
    sbx_profile_valid_name my-profile_1.2
    sbx_profile_valid_name _x
    for bad in "" ../evil a/b .hidden -dash "sp ace"; do
        if sbx_profile_valid_name "$bad"; then echo "accepted '$bad'" >&2; return 1; fi
    done
}

@test "templates are valid and grant nothing" {
    source "$BATS_TEST_DIRNAME/../lib/profile-check.sh"
    local type out
    for type in cli fs net; do
        sbx_profile_template "$type" "a $type profile" > "$W/t.json"
        out=$(sbx_profile_check "$type" "$W/t.json" project)
        if [[ -n "$out" ]]; then echo "$type template: $out" >&2; return 1; fi
    done
    [ "$(sbx_profile_template cli d | jq -c .)" = '{"description":"d","env":{},"passthrough":[],"mounts":[]}' ]
    [ "$(sbx_profile_template fs d | jq -c .)" = '{"description":"d","mounts":[]}' ]
    [ "$(sbx_profile_template net d | jq -c .)" = '{"description":"d","dns":"1.1.1.1","allow":[],"ports":[443]}' ]
    run sbx_profile_template ssh d
    [ "$status" -eq 1 ]
}

@test "restricted fields are listed in order" {
    echo '{"host_ports":[1],"caps":"keep","description":"x","docker_api":false}' > "$W/r.json"
    run sbx_profile_restricted_fields "$W/r.json"
    [ "$output" = "$(printf 'caps\ndocker_api\nhost_ports')" ]
    echo '{"description":"x"}' > "$W/r.json"
    run sbx_profile_restricted_fields "$W/r.json"
    [ -z "$output" ]
}

@test "shadowing relative to each location" {
    run sbx_profile_shadowing fs shared user "$CFG" "$GLOBAL"
    [ "${lines[0]}" = "shadowed-by project ./.sbx/profiles/fs/shared.json" ]
    [ "${lines[1]}" = "shadows global $GLOBAL/fs/shared.json" ]
    run sbx_profile_shadowing fs base project "$CFG" "$GLOBAL"
    [ "$output" = "shadows global $GLOBAL/fs/base.json" ]
    run sbx_profile_shadowing fs nothing user "$CFG" "$GLOBAL"
    [ -z "$output" ]
}

@test "list marks shadowed profiles" {
    run sbx_profile_list "$CFG" "$GLOBAL"
    [[ "$output" == *"  shared (Project)"* ]]
    [[ "$output" == *"  shared (User, shadowed by Project)"* ]]
    [[ "$output" == *"  shared (Global, shadowed by Project)"* ]]
    [[ "$output" == *"  mine (User)"* ]]
}
