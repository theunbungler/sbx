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

@test "resolve accepts a direct file path, with or without .json" {
    echo '{}' > "$W/direct.json"
    run sbx_profile_resolve fs "$W/direct.json" "$CFG" "$GLOBAL"
    [ "$output" = "$(realpath "$W/direct.json")" ]
    run sbx_profile_resolve fs "$W/direct" "$CFG" "$GLOBAL"
    [ "$output" = "$(realpath "$W/direct.json")" ]
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

@test "list prints every profile with its source label" {
    run sbx_profile_list "$CFG" "$GLOBAL"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Available Profiles:" ]
    [[ "$output" == *"  shared (Project)"* ]]
    [[ "$output" == *"  mine (User)"* ]]
    [[ "$output" == *"  base (Global)"* ]]
    [[ "$output" == *"  web (User)"* ]]
}
