#!/bin/bash
# Copy-mount seeding and write-back.
#
# Sourced by sbx and directly by tests/. Defines functions only — no side
# effects at source time, no dependency on sbx globals.

# Translate a sandbox destination path into the flat identifier used for
# tmp_mounts/, per-session egress, and persistent store directories.
#   /home/user/.claude -> _home_user_.claude
sbx_copy_mount_id() {
    echo "$1" | tr '/' '_'
}

# Translate an absolute path into a dashed slug, Claude-Code style, used
# to key a persistent store by the external directory sbx was launched
# from.
#   /home/user/projA -> -home-user-projA
sbx_copy_path_slug() {
    echo "$1" | tr '/' '-'
}

# Populate a copy mount's working directory.
#   $1 src   - host source path (file or directory)
#   $2 tmp   - working directory to populate
#   $3 store - optional persistent store, overlaid on top of the host copy
#
# --reflink=auto makes this metadata-only on btrfs/xfs when src and tmp
# share a filesystem, and silently falls back to a full copy otherwise.
sbx_copy_seed() {
    local src="$1" tmp="$2" store="${3:-}"

    mkdir -p "$tmp"

    if [[ -d "$src" ]]; then
        cp -a --reflink=auto "$src/." "$tmp/"
    elif [[ -f "$src" ]]; then
        cp -a --reflink=auto "$src" "$tmp/"
    fi

    # Store entries win over the host copy, per file. Applied after the
    # host copy, so the store is the upper layer.
    if [[ -n "$store" && -d "$store" ]]; then
        cp -a --reflink=auto "$store/." "$tmp/"
    fi
}

# Copy files that differ from the host source into an output directory.
#   $1 src - host source path; the diff baseline, never modified
#   $2 tmp - the session's working copy
#   $3 out - destination for changed files
#
# Never prunes $out: entries it does not write are left alone.
#
# "Differs" is decided by CONTENT, not by size-and-mtime. The cheap check
# these paths used to make compares mtime at whole-second granularity, so a
# file rewritten in-sandbox to the same length within the same wall-clock
# second as the seed copy looked identical and was silently dropped — the
# exact shape of a small JSON state file a tool rewrites the moment it
# starts (a token, a counter, an id of unchanged width). That is data loss
# in the persistence path behind --cli, so all three comparisons below are
# content-based: --checksum for rsync, cmp for the fallbacks.
sbx_copy_writeback() {
    local src="$1" tmp="$2" out="$3"

    mkdir -p "$out"

    if [[ -d "$src" ]]; then
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --checksum --compare-dest="$src/" "$tmp/" "$out/"
        else
            (
                cd "$tmp" || exit 0
                find . -type f -print0 | while IFS= read -r -d '' rel_path; do
                    rel_path="${rel_path#./}"
                    local file="$tmp/$rel_path"
                    local orig_file="$src/$rel_path"

                    local needs_copy=0
                    if [[ ! -f "$orig_file" ]]; then
                        needs_copy=1
                    elif ! cmp -s "$file" "$orig_file"; then
                        needs_copy=1
                    fi

                    if [[ $needs_copy -eq 1 ]]; then
                        mkdir -p "$(dirname "$out/$rel_path")"
                        cp -a "$file" "$out/$rel_path"
                    fi
                done
            )
        fi
    elif [[ -f "$src" ]]; then
        local filename file
        filename=$(basename "$src")
        file="$tmp/$filename"

        # The sandbox may have deleted it; nothing to write back if so.
        [[ -f "$file" ]] || return 0

        if ! cmp -s "$file" "$src"; then
            cp -a "$file" "$out/$filename"
        fi
    fi
}

# Manifest of a tree's file contents, used as the diff baseline for a
# `record` mount.
#
# One line per regular file: "<sha256>  <relpath>" — exactly sha256sum's
# own output format, with the leading "./" stripped, sorted bytewise.
#
# Content only, no mode. The single batched `find -exec sha256sum {} +` is
# what keeps this affordable on a large tree; collecting modes as well needs
# a second walk or a per-file subshell, and a mode-only change with
# byte-identical content is not worth either. Such a change is not detected.
#
# LC_ALL=C throughout: the sort order only has to be *stable between the two
# manifests* being compared, and a locale-dependent collation that differs
# between the launch and teardown environments would silently desynchronize
# comm(1) below.
sbx_manifest_build() {
    local tree="$1" out="$2"

    : > "$out"
    [[ -d "$tree" ]] || return 0

    (
        cd "$tree" || exit 0
        find . -type f -exec sha256sum {} + 2>/dev/null
    ) | sed 's|^\(\w*\)  \./|\1  |' | LC_ALL=C sort > "$out"
}

# Relative paths of the files in $2 that are absent from, or differ in
# content from, $1. comm on whole lines: a differing hash makes the whole
# line unique to $2, which is exactly "added or modified".
sbx_manifest_changed() {
    LC_ALL=C comm -13 "$1" "$2" | cut -d' ' -f3-
}

# Relative paths present in $1 and absent from $2. Compares path columns
# only, so a file that merely changed content is not reported here.
sbx_manifest_deleted() {
    LC_ALL=C comm -23 \
        <(cut -d' ' -f3- "$1" | LC_ALL=C sort) \
        <(cut -d' ' -f3- "$2" | LC_ALL=C sort)
}
