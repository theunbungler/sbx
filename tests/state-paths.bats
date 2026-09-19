#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/copy-mounts.sh"
    source "$BATS_TEST_DIRNAME/../lib/state-paths.sh"
}

@test "session base lowercases and replaces unsafe characters" {
    run sbx_state_session_base "/tmp/x/My Project!"
    [ "$output" = "my-project" ]
}

@test "session base keeps dots, dashes and underscores" {
    run sbx_state_session_base "/tmp/x/a.b_c-d"
    [ "$output" = "a.b_c-d" ]
}

@test "session base is cut to 32 characters" {
    run sbx_state_session_base "/tmp/x/abcdefghijklmnopqrstuvwxyz0123456789"
    [ "$output" = "abcdefghijklmnopqrstuvwxyz012345" ]
}

@test "session base falls back to sbx for empty and dot-dot" {
    run sbx_state_session_base "/"
    [ "$output" = "sbx" ]
    run sbx_state_session_base "/tmp/x/-.."
    [ "$output" = "sbx" ]
}

@test "forked store path is keyed by profile, launch directory and destination" {
    run sbx_state_forked_store /s /home/u/proj pi /home/u/.pi
    [ "$output" = "/s/forked/pi/-home-u-proj/_home_u_.pi" ]
}

@test "socket probe is the widest tmux.sock path the claim loop can produce" {
    run sbx_state_socket_probe /s my-proj
    [ "$output" = "/s/sessions/my-proj-99/tmux.sock" ]
}

# A minimal Phase 2 plan with the given mounts (JSON array) and security flags.
plan() {   # <mounts json> [caps_keep] [userns_full] [docker_api] [gui]
    jq -cn --argjson mounts "$1" \
        --argjson ck "${2:-false}" --argjson uf "${3:-false}" --argjson da "${4:-false}" \
        --argjson gui "${5:-false}" \
        '{mounts: $mounts, security: {caps_keep: $ck, userns_full: $uf, docker_api: $da}, gui: $gui}'
}

mount() {   # <perm> <source> <dest> <present>
    jq -cn --arg perm "$1" --arg source "$2" --arg dest "$3" --argjson present "$4" \
        '{profile: "p", from: "fs/p", source: $source, dest: $dest, perm: $perm, present: $present}'
}

setup_writes() {
    W="$BATS_TEST_TMPDIR/w"
    STATE="$W/state"; LAUNCH="$W/My Proj"; SRC="$W/src"
    mkdir -p "$SRC/tree" "$LAUNCH"
    echo hi > "$SRC/tree/f"
}

@test "writes: a forked mount will seed, then exists" {
    setup_writes
    run sbx_state_writes "$(plan "[$(mount forked "$SRC/tree" /t true)]")" "$STATE" "$LAUNCH"
    [ "$status" -eq 0 ]
    store=$(sbx_state_forked_store "$STATE" "$LAUNCH" p /t)
    [ "$(jq -r '.[0].kind' <<< "$output")" = "persistent" ]
    [ "$(jq -r '.[0].path' <<< "$output")" = "$store" ]
    [ "$(jq -r '.[0].dest' <<< "$output")" = "/t" ]
    [[ "$(jq -r '.[0].note' <<< "$output")" == "will seed, "* ]]
    mkdir -p "$store"
    run sbx_state_writes "$(plan "[$(mount forked "$SRC/tree" /t true)]")" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[0].note' <<< "$output")" = "exists" ]
}

@test "writes: an absent forked source, a ro mount and an absent dev mount write nothing" {
    setup_writes
    run sbx_state_writes "$(plan "[$(mount forked "$SRC/gone" /g false),$(mount ro "$SRC/tree" /r true),$(mount dev /nonexistent /d false)]")" "$STATE" "$LAUNCH"
    [ "$(jq -r 'map(.kind) | join(",")' <<< "$output")" = "temporary,temporary" ]
}

@test "writes: record mounts get a working copy each and one archive" {
    setup_writes
    run sbx_state_writes "$(plan "[$(mount record "$SRC/tree" /a true),$(mount record "$SRC/tree" /b true)]")" "$STATE" "$LAUNCH"
    [ "$(jq -r 'map(.kind) | join(",")' <<< "$output")" = "temporary,temporary,archived,temporary,temporary" ]
    base=$(sbx_state_session_base "$LAUNCH")
    [ "$(jq -r '.[0].path' <<< "$output")" = "$STATE/work/$base/_a" ]
    [ "$(jq -r '.[2].path' <<< "$output")" = "$STATE/changes/$(sbx_copy_path_slug "$LAUNCH")/<stamp>-$base/" ]
}

@test "writes: rw and dev binds are host writes; an absent rw source is created at launch" {
    setup_writes
    run sbx_state_writes "$(plan "[$(mount rw "$SRC/tree" /w true),$(mount rw "$SRC/new" /n false),$(mount dev /dev/null /dn true)]")" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[0] | [.kind, .path, .note] | join("|")' <<< "$output")" = "host|$SRC/tree|" ]
    [ "$(jq -r '.[1].note' <<< "$output")" = "created at launch" ]
    [ "$(jq -r '.[2].path' <<< "$output")" = "/dev/null" ]
}

@test "writes: podman stores follow caps, docker api and userns full" {
    setup_writes
    run sbx_state_writes "$(plan '[]' true false false)" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[0].path' <<< "$output")" = "$STATE/virt/containers" ]
    run sbx_state_writes "$(plan '[]' false false true)" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[0].path' <<< "$output")" = "$STATE/virt/containers" ]
    run sbx_state_writes "$(plan '[]' true true false)" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[0].path' <<< "$output")" = "$STATE/virt/containers-full" ]
    [ "$(jq -r 'length' <<< "$output")" = "3" ]
}

@test "writes: the session directory is always last, named like the launch" {
    setup_writes
    run sbx_state_writes "$(plan '[]')" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[-1].path' <<< "$output")" = "$STATE/sessions/my-proj/" ]
}

@test "writes: a mount row carries its source; the session directory's source is empty" {
    setup_writes
    run sbx_state_writes "$(plan "[$(mount forked "$SRC/tree" /t true)]")" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[0].source' <<< "$output")" = "$SRC/tree" ]
    run sbx_state_writes "$(plan '[]')" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[-1].source' <<< "$output")" = "" ]
}

@test "writes: session bookkeeping is a temporary row right before the session directory" {
    setup_writes
    run sbx_state_writes "$(plan '[]')" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[-2].path' <<< "$output")" = "$STATE/join/my-proj.{pid,json,lock}" ]
    [ "$(jq -r '.[-2].kind' <<< "$output")" = "temporary" ]
}

@test "writes: a slow forked-source du is bounded by a timeout" {
    setup_writes
    cat > "$BATS_TEST_TMPDIR/du" <<'EOF'
#!/bin/bash
sleep 6
EOF
    chmod +x "$BATS_TEST_TMPDIR/du"
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR:$PATH"
    run sbx_state_writes "$(plan "[$(mount forked "$SRC/tree" /t true)]")" "$STATE" "$LAUNCH"
    PATH="$old_path"
    [ "$(jq -r '.[0].note' <<< "$output")" = "will seed, size unknown" ]
}

@test "writes: gui true adds the xauthority and X11 socket rows; gui false adds neither" {
    setup_writes
    run sbx_state_writes "$(plan '[]' false false false true)" "$STATE" "$LAUNCH" "$W/.Xauthority"
    [ "$(jq -r '.[-4] | [.kind, .path, .detail] | join("|")' <<< "$output")" = "host|$W/.Xauthority|xpra adds a display cookie; left in place" ]
    [ "$(jq -r '.[-3] | [.kind, .path, .detail] | join("|")' <<< "$output")" = "temporary|/tmp/.X11-unix/X<N>|xpra display socket; removed when the display stops" ]
    [ "$(jq -r '.[-2].path' <<< "$output")" = "$STATE/join/my-proj.{pid,json,lock}" ]
    [ "$(jq -r '.[-1].path' <<< "$output")" = "$STATE/sessions/my-proj/" ]

    run sbx_state_writes "$(plan '[]')" "$STATE" "$LAUNCH" "$W/.Xauthority"
    if [[ "$output" == *"Xauthority"* || "$output" == *"X11-unix"* ]]; then return 1; fi
}

@test "writes: computing the list creates nothing" {
    setup_writes
    run sbx_state_writes "$(plan "[$(mount forked "$SRC/tree" /t true),$(mount rw "$SRC/new" /n false),$(mount record "$SRC/tree" /r true)]")" "$STATE" "$LAUNCH"
    [ "$status" -eq 0 ]
    [ ! -e "$STATE" ]
    [ ! -e "$SRC/new" ]
}
