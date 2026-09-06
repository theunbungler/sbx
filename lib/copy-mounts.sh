#!/bin/bash
# Mount seeding and manifest diffing, shared by the forked and record perms.
#
# Sourced by sbx and directly by tests/. Defines functions only — no side
# effects at source time, no dependency on sbx globals.

# Translate a sandbox destination path into the flat identifier used for
# forked and record store directories.
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

# Populate a forked or record mount's working directory from the host source.
#
# --reflink=auto makes this metadata-only on btrfs/xfs when src and tmp
# share a filesystem, and silently falls back to a full copy otherwise. On
# the design host that is a 37x difference on 300MB (4ms vs 144ms). Callers
# that want a progress display for the slow fallback path should use
# sbx_copy_seed_progress below instead of calling this directly.
sbx_copy_seed() {
    local src="$1" tmp="$2"

    mkdir -p "$tmp"

    if [[ -d "$src" ]]; then
        cp -a --reflink=auto "$src/." "$tmp/"
    elif [[ -f "$src" ]]; then
        cp -a --reflink=auto "$src" "$tmp/"
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
# When a filename contains a backslash, sha256sum escapes it (prefixes the
# line with `\` and writes `\\` for each backslash in the name). This
# function normalizes such lines: strips the leading escape marker, unescapes
# backslashes, and strips the leading "./". Files with embedded newlines are
# skipped and a count is printed to stderr.
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
    ) | awk '
BEGIN {
    skipped = 0
}
/^\\/  {
    # This is an escaped line from sha256sum
    line = $0
    line = substr(line, 2)  # Strip leading \

    # Find double-space separator between hash and path
    idx = index(line, "  ")
    hash = substr(line, 1, idx - 1)
    path = substr(line, idx + 2)

    # Check for embedded newline (we cannot represent in a line-oriented format)
    if (index(path, "\\n") > 0) {
        skipped++
        next
    }

    # Unescape backslashes: replace \\ with single \. gsub advances past
    # each replacement instead of rescanning it, so overlapping runs of
    # backslashes are not double-consumed the way a match()-based loop
    # restarting from position 1 would.
    gsub(/\\\\/, "\\", path)

    # Strip leading ./
    if (substr(path, 1, 2) == "./") {
        path = substr(path, 3)
    }

    print hash "  " path
    next
}
{
    # Normal unescaped line
    idx = index($0, "  ")
    hash = substr($0, 1, idx - 1)
    path = substr($0, idx + 2)

    # Strip leading ./
    if (substr(path, 1, 2) == "./") {
        path = substr(path, 3)
    }

    print hash "  " path
}
END {
    if (skipped > 0) {
        print "warning: skipped " skipped " file(s) with newlines in name" > "/dev/stderr"
    }
}
' | LC_ALL=C sort > "$out"
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

# sbx_copy_seed, with a progress line for copies slow enough to look hung.
#
# Gated on BOTH a time threshold and stderr being a TTY, because the fast
# path needs no instrumentation at all: a 300MB same-filesystem btrfs seed
# is a reflink and completes in ~4ms, versus ~144ms with --reflink=never.
# Progress is only ever wanted where reflink is unavailable, which is
# exactly where it is slow. CI and pipelines print nothing.
#
# The numerator is rchar from /proc/<pid>/io — bytes the copy has consumed,
# obtained without walking the filesystem. The denominator needs du -sb,
# which is itself a full stat walk and can take seconds on a 9p mount like
# WSL2's /mnt/c, so it runs CONCURRENTLY: the display starts as
# bytes-plus-elapsed and upgrades to a percentage if and when du returns.
# rchar counts directory reads too and so overshoots slightly; the
# percentage is capped at 99 until the copy actually exits.
sbx_copy_seed_progress() {
    local src="$1" tmp="$2" label="$3"
    local delay="${SBX_PROGRESS_DELAY:-1}"

    mkdir -p "$tmp"
    [[ -e "$src" ]] || return 0

    local cp_pid du_pid du_out total="" start shown=0
    du_out=$(mktemp)

    if [[ -d "$src" ]]; then
        cp -a --reflink=auto "$src/." "$tmp/" & cp_pid=$!
    else
        cp -a --reflink=auto "$src" "$tmp/" & cp_pid=$!
    fi

    # Written to directly, not through a `| cut` pipe: piping would make
    # $! the pid of the pipe's last stage (cut), not du itself, and then
    # `kill "$du_pid"` below would leave du orphaned on a slow stat walk
    # instead of reaping it.
    du -sb "$src" > "$du_out" 2>/dev/null & du_pid=$!
    start=$SECONDS

    while kill -0 "$cp_pid" 2>/dev/null; do
        sleep 0.2
        [[ -t 2 ]] || continue
        (( SECONDS - start < delay )) && continue

        if [[ -z "$total" ]] && ! kill -0 "$du_pid" 2>/dev/null; then
            total=$(awk '{print $1}' "$du_out" 2>/dev/null) || true
            [[ "$total" =~ ^[0-9]+$ ]] || total="unknown"
        fi

        local done_b
        done_b=$(awk '/^rchar:/{print $2}' "/proc/$cp_pid/io" 2>/dev/null) || true
        shown=1
        if [[ -n "$total" && "$total" != unknown && -n "$done_b" && "$total" -gt 0 ]]; then
            local pct=$(( done_b * 100 / total ))
            (( pct > 99 )) && pct=99
            printf '\r\033[K  %s: %d%% (%ds)' "$label" "$pct" "$(( SECONDS - start ))" >&2
        elif [[ -n "$done_b" ]]; then
            printf '\r\033[K  %s: %s copied (%ds)' \
                "$label" "$(numfmt --to=iec "$done_b" 2>/dev/null || echo "$done_b B")" \
                "$(( SECONDS - start ))" >&2
        else
            # /proc/<pid>/io unreadable — hardened procfs, or not Linux.
            printf '\r\033[K  %s: working (%ds)' "$label" "$(( SECONDS - start ))" >&2
        fi
    done

    wait "$cp_pid"; local rc=$?
    kill "$du_pid" 2>/dev/null || true
    wait "$du_pid" 2>/dev/null || true
    rm -f "$du_out"
    (( shown )) && printf '\r\033[K' >&2
    return $rc
}
