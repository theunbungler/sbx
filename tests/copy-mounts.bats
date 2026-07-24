#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/copy-mounts.sh"
    WORK="$BATS_TEST_TMPDIR/w"
    SRC="$WORK/src"; TMP="$WORK/tmp"; OUT="$WORK/out"
    mkdir -p "$SRC"
}

@test "mount_id flattens a destination path" {
    run sbx_copy_mount_id "/home/user/.claude"
    [ "$output" = "_home_user_.claude" ]
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
