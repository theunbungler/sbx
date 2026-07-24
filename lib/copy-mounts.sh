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
sbx_copy_writeback() {
    local src="$1" tmp="$2" out="$3"

    mkdir -p "$out"

    if [[ -d "$src" ]]; then
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --compare-dest="$src/" "$tmp/" "$out/"
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
                    elif [[ $(stat -c %s "$file") -ne $(stat -c %s "$orig_file") ]] || \
                         [[ $(stat -c %Y "$file") -gt $(stat -c %Y "$orig_file") ]]; then
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

        if [[ $(stat -c %s "$file") -ne $(stat -c %s "$src") ]] || \
           [[ $(stat -c %Y "$file") -gt $(stat -c %Y "$src") ]]; then
            cp -a "$file" "$out/$filename"
        fi
    fi
}
