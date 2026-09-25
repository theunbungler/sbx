#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/copy-mounts.sh"
    WORK="$BATS_TEST_TMPDIR/w"
    SRC="$WORK/src"; TMP="$WORK/tmp"; OUT="$WORK/out"
    mkdir -p "$SRC"
}

@test "mount_id flattens a destination path and digests it" {
    run sbx_copy_mount_id "/home/user/.claude"
    [[ "$output" == "_home_user_.claude."???????? ]]
    # Same path, same key, every time and on every machine.
    local first="$output"
    run sbx_copy_mount_id "/home/user/.claude"
    [ "$output" = "$first" ]
}

@test "path_slug dashes an absolute path Claude-Code style and digests it" {
    run sbx_copy_path_slug "/home/user/projA"
    [[ "$output" == "-home-user-projA."???????? ]]
}

@test "a deep path still fits a filename, and stays distinct" {
    local deep="/$(printf 'averyverylongcomponentname/%.0s' {1..40})leaf"
    run sbx_copy_mount_id "$deep"
    [ "${#output}" -le 255 ]
    local first="$output"
    run sbx_copy_mount_id "$deep/other"
    [ "$output" != "$first" ]
    [ "${#output}" -le 255 ]
}

# Two mounts that share a store directory mix their contents, and a record
# archive then attributes one mount's changes to the other. Two launch
# directories that share a forked store see and overwrite each other's
# sandbox-owned data. Both keys must therefore be injective.
@test "mount_id distinguishes a separator from a literal underscore" {
    run sbx_copy_mount_id "/data/cache"
    local slashed="$output"
    run sbx_copy_mount_id "/data_cache"
    [ "$output" != "$slashed" ]
    # The readable part is deliberately the same; the digest separates them.
    [[ "$slashed" == _data_cache.* ]]
    [[ "$output" == _data_cache.* ]]
}

@test "path_slug distinguishes a separator from a literal dash" {
    run sbx_copy_path_slug "/home/u/my/proj"
    local slashed="$output"
    run sbx_copy_path_slug "/home/u/my-proj"
    [ "$output" != "$slashed" ]
}

@test "paths naming the same file key the same store" {
    # // and a trailing / are the same path, so they must not fork the store.
    run sbx_copy_mount_id "/a/b"
    local plain="$output"
    run sbx_copy_mount_id "/a//b"
    [ "$output" = "$plain" ]
    run sbx_copy_mount_id "/a/b/"
    [ "$output" = "$plain" ]
    run sbx_copy_path_slug "/a//b/"
    local slug="$output"
    run sbx_copy_path_slug "/a/b"
    [ "$output" = "$slug" ]
    # Root survives normalisation rather than becoming the empty string.
    run sbx_copy_mount_id "/"
    [[ "$output" == "_."???????? ]]
}

@test "both keys stay injective across a set of awkward paths" {
    local -a paths=(
        /a/b /a_b /a__b /a/_b /a_/b
        /x-y /x/y /x--y /x/-y /x-/y
        "/p/__pycache__" "/p__/pycache__" "/p/q" "/p_q"
    )
    local p ids=() slugs=()
    for p in "${paths[@]}"; do
        ids+=("$(sbx_copy_mount_id "$p")")
        slugs+=("$(sbx_copy_path_slug "$p")")
    done
    # No duplicates: as many distinct keys as inputs.
    [ "$(printf '%s\n' "${ids[@]}" | sort -u | wc -l)" -eq "${#paths[@]}" ]
    [ "$(printf '%s\n' "${slugs[@]}" | sort -u | wc -l)" -eq "${#paths[@]}" ]
}

@test "seed_progress creates nothing when the source does not exist" {
    sbx_copy_seed_progress "$WORK/missing" "$TMP" test 2>/dev/null
    [ ! -e "$TMP" ]
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

@test "seed_progress copies a directory's contents" {
    mkdir -p "$SRC/sub"
    echo one > "$SRC/a.txt"
    echo two > "$SRC/sub/b.txt"
    sbx_copy_seed_progress "$SRC" "$TMP" "test" 2>/dev/null
    [ "$(cat "$TMP/a.txt")" = "one" ]
    [ "$(cat "$TMP/sub/b.txt")" = "two" ]
}

@test "seed_progress prints nothing when stderr is not a tty" {
    echo one > "$SRC/a.txt"
    run bash -c "source '$BATS_TEST_DIRNAME/../lib/copy-mounts.sh'; \
                 SBX_PROGRESS_DELAY=0 sbx_copy_seed_progress '$SRC' '$TMP' test 2>&1"
    [ -z "$output" ]
}

@test "seed_progress copies a single file" {
    echo hi > "$WORK/one.txt"
    sbx_copy_seed_progress "$WORK/one.txt" "$TMP" "test" 2>/dev/null
    [ "$(cat "$TMP/one.txt")" = "hi" ]
}

# A tree of many small files, rather than one big file: cp's per-file syscall
# overhead makes this reliably slower than the SBX_PROGRESS_DELAY=0 threshold
# even though the total content is only tens of MB, without needing a
# multi-GB fixture or depending on the filesystem lacking reflink support.
@test "seed_progress prints the label to a tty stderr" {
    for i in $(seq 1 20000); do echo "data $i" > "$SRC/f$i.txt"; done
    local typescript="$WORK/typescript"
    script -qec "bash -c \"source '$BATS_TEST_DIRNAME/../lib/copy-mounts.sh'; \
                 SBX_PROGRESS_DELAY=0 sbx_copy_seed_progress '$SRC' '$TMP' bigseed\"" \
        "$typescript" >/dev/null 2>&1
    grep -aq "bigseed" "$typescript"
}
