#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/copy-mounts.sh"
    WORK="$BATS_TEST_TMPDIR/w"
    SRC="$WORK/src"; TMP="$WORK/tmp"; OUT="$WORK/out"; STORE="$WORK/store"
    mkdir -p "$SRC"
}

@test "mount_id flattens a destination path" {
    run sbx_copy_mount_id "/home/user/.claude"
    [ "$output" = "_home_user_.claude" ]
}

@test "path_slug dashes an absolute path Claude-Code style" {
    run sbx_copy_path_slug "/home/user/projA"
    [ "$output" = "-home-user-projA" ]
}

@test "seed copies a directory's contents from the host" {
    echo hello > "$SRC/a.txt"
    sbx_copy_seed "$SRC" "$TMP"
    [ "$(cat "$TMP/a.txt")" = "hello" ]
}

@test "seed copies a single file into the working directory" {
    echo hi > "$WORK/one.txt"
    sbx_copy_seed "$WORK/one.txt" "$TMP"
    [ "$(cat "$TMP/one.txt")" = "hi" ]
}

@test "seed is a no-op when the source does not exist" {
    sbx_copy_seed "$WORK/missing" "$TMP"
    [ -d "$TMP" ]
    [ -z "$(ls -A "$TMP")" ]
}

@test "writeback captures a file the sandbox created" {
    echo hello > "$SRC/a.txt"
    sbx_copy_seed "$SRC" "$TMP"
    echo new > "$TMP/b.txt"
    sbx_copy_writeback "$SRC" "$TMP" "$OUT"
    [ "$(cat "$OUT/b.txt")" = "new" ]
}

@test "writeback captures a file the sandbox modified" {
    echo hello > "$SRC/a.txt"
    sbx_copy_seed "$SRC" "$TMP"
    echo changed-and-longer > "$TMP/a.txt"
    sbx_copy_writeback "$SRC" "$TMP" "$OUT"
    [ "$(cat "$OUT/a.txt")" = "changed-and-longer" ]
}

@test "writeback ignores a file the sandbox did not touch" {
    echo hello > "$SRC/a.txt"
    sbx_copy_seed "$SRC" "$TMP"
    sbx_copy_writeback "$SRC" "$TMP" "$OUT"
    [ ! -f "$OUT/a.txt" ]
}

@test "writeback never modifies the host source" {
    echo hello > "$SRC/a.txt"
    sbx_copy_seed "$SRC" "$TMP"
    echo clobbered > "$TMP/a.txt"
    echo new > "$TMP/b.txt"
    sbx_copy_writeback "$SRC" "$TMP" "$OUT"
    [ "$(cat "$SRC/a.txt")" = "hello" ]
    [ ! -f "$SRC/b.txt" ]
}

@test "writeback handles a single-file source deleted in the sandbox" {
    echo hi > "$WORK/one.txt"
    sbx_copy_seed "$WORK/one.txt" "$TMP"
    rm "$TMP/one.txt"
    run sbx_copy_writeback "$WORK/one.txt" "$TMP" "$OUT"
    [ "$status" -eq 0 ]
}

@test "seed overlays store entries on top of the host copy" {
    echo host > "$SRC/a.txt"
    mkdir -p "$STORE"
    echo stored > "$STORE/a.txt"
    sbx_copy_seed "$SRC" "$TMP" "$STORE"
    [ "$(cat "$TMP/a.txt")" = "stored" ]
}

@test "seed brings through host files absent from the store" {
    echo host > "$SRC/a.txt"
    echo hostonly > "$SRC/b.txt"
    mkdir -p "$STORE"
    echo stored > "$STORE/a.txt"
    sbx_copy_seed "$SRC" "$TMP" "$STORE"
    [ "$(cat "$TMP/b.txt")" = "hostonly" ]
}

@test "seed brings through store files absent from the host" {
    echo host > "$SRC/a.txt"
    mkdir -p "$STORE"
    echo storeonly > "$STORE/c.txt"
    sbx_copy_seed "$SRC" "$TMP" "$STORE"
    [ "$(cat "$TMP/c.txt")" = "storeonly" ]
}

@test "seed tolerates a store that does not exist yet" {
    echo host > "$SRC/a.txt"
    sbx_copy_seed "$SRC" "$TMP" "$WORK/no-such-store"
    [ "$(cat "$TMP/a.txt")" = "host" ]
}

@test "seed overlays nested store paths" {
    mkdir -p "$SRC/sub"
    echo host > "$SRC/sub/a.txt"
    mkdir -p "$STORE/sub"
    echo stored > "$STORE/sub/a.txt"
    sbx_copy_seed "$SRC" "$TMP" "$STORE"
    [ "$(cat "$TMP/sub/a.txt")" = "stored" ]
}

# The round trip: a store-only file must reach the working copy, and must
# still be in the store after a session that never modified it. The
# mid-test assertion is what makes this depend on the overlay — without it
# the test passes even with the overlay removed entirely.
@test "a stored file survives a session that never touches it" {
    echo host > "$SRC/a.txt"
    mkdir -p "$STORE"
    echo stored > "$STORE/b.txt"
    sbx_copy_seed "$SRC" "$TMP" "$STORE"
    # The overlay reached the working copy.
    [ "$(cat "$TMP/b.txt")" = "stored" ]
    sbx_copy_writeback "$SRC" "$TMP" "$STORE"
    # Write-back left an untouched store entry alone.
    [ "$(cat "$STORE/b.txt")" = "stored" ]
}

@test "manifest_build records a hash per file" {
    mkdir -p "$SRC/sub"
    echo one > "$SRC/a.txt"
    echo two > "$SRC/sub/b.txt"
    sbx_manifest_build "$SRC" "$WORK/m"
    [ "$(wc -l < "$WORK/m")" -eq 2 ]
    grep -q ' a.txt$' "$WORK/m"
    grep -q ' sub/b.txt$' "$WORK/m"
}

@test "manifest_build on a missing tree yields an empty manifest" {
    sbx_manifest_build "$WORK/nope" "$WORK/m"
    [ -f "$WORK/m" ]
    [ ! -s "$WORK/m" ]
}

@test "manifest_build handles spaces in filenames" {
    echo hi > "$SRC/two words.txt"
    sbx_manifest_build "$SRC" "$WORK/m"
    grep -q ' two words.txt$' "$WORK/m"
}

@test "manifest_changed reports an added file" {
    echo one > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    echo new > "$SRC/b.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_changed "$WORK/base" "$WORK/cur"
    [ "$output" = "b.txt" ]
}

@test "manifest_changed reports a modified file" {
    echo one > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    echo changed > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_changed "$WORK/base" "$WORK/cur"
    [ "$output" = "a.txt" ]
}

@test "manifest_changed ignores an untouched file" {
    echo one > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_changed "$WORK/base" "$WORK/cur"
    [ -z "$output" ]
}

@test "manifest_changed does not report a deleted file" {
    echo one > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    rm "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_changed "$WORK/base" "$WORK/cur"
    [ -z "$output" ]
}

@test "manifest_deleted reports a removed file" {
    echo one > "$SRC/a.txt"
    echo two > "$SRC/b.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    rm "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_deleted "$WORK/base" "$WORK/cur"
    [ "$output" = "a.txt" ]
}

@test "manifest_deleted is silent when a file only changed" {
    echo one > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    echo changed > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_deleted "$WORK/base" "$WORK/cur"
    [ -z "$output" ]
}

@test "manifest_build records a file with a backslash in its name" {
    touch "$SRC/back\\slash.txt"
    sbx_manifest_build "$SRC" "$WORK/m"
    grep -q ' back\\slash.txt$' "$WORK/m"
}

@test "manifest_changed reports a modified file with spaces in the name" {
    echo one > "$SRC/two words.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    echo changed > "$SRC/two words.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_changed "$WORK/base" "$WORK/cur"
    [ "$output" = "two words.txt" ]
}

@test "manifest_changed reports a modified file with a backslash in the name" {
    echo one > "$SRC/back\\slash.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    echo changed > "$SRC/back\\slash.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_changed "$WORK/base" "$WORK/cur"
    [ "$output" = "back\\slash.txt" ]
    [ -f "$SRC/$output" ]
}

@test "manifest_deleted reports a removed file with spaces in the name" {
    echo one > "$SRC/two words.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    rm "$SRC/two words.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_deleted "$WORK/base" "$WORK/cur"
    [ "$output" = "two words.txt" ]
}

@test "manifest_deleted reports a removed file with a backslash in the name" {
    echo one > "$SRC/back\\slash.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    rm "$SRC/back\\slash.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_deleted "$WORK/base" "$WORK/cur"
    [ "$output" = "back\\slash.txt" ]
}

@test "manifest_build records a file with two consecutive backslashes in its name" {
    touch "$SRC/double\\\\slash.txt"
    sbx_manifest_build "$SRC" "$WORK/m"
    grep -q ' double\\\\slash.txt$' "$WORK/m"
}

@test "manifest_changed reports a modified file with two consecutive backslashes in the name" {
    echo one > "$SRC/double\\\\slash.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    echo changed > "$SRC/double\\\\slash.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_changed "$WORK/base" "$WORK/cur"
    [ "$output" = "double\\\\slash.txt" ]
    [ -f "$SRC/$output" ]
}
