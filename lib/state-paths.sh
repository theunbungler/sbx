#!/bin/bash
# Where sbx keeps things on the host: the session name, forked stores, and
# (for --dry-run) the list of every host location a launch will write.
#
# The launch and --dry-run both call these, so what a dry run reports is
# what the launch uses. Requires lib/copy-mounts.sh (sbx_copy_path_slug,
# sbx_copy_mount_id). Defines functions only — no side effects at source
# time, no dependency on sbx globals: every directory is an argument.

# Session name. Derived from the launch directory's basename, because the
# thing a user types at --join should be recognisable; the old
# date-plus-random id was unique and unusable. Capped at 32 characters to
# keep the tmux socket at $SESSION_DIR/tmux.sock inside the ~108-byte Unix
# socket path limit; the cap alone does not guarantee that (a long $HOME
# still can), so the length is checked outright below.
#
# Uniqueness is established by mkdir succeeding — an atomic claim, so two
# simultaneous launches cannot both take a name. A directory whose
# supervising pid is gone is crash residue, not a session: it is removed and
# the name reclaimed.
sbx_state_session_base() {   # <launch_dir>
    local base
    base=$(printf '%s' "$(basename "$1")" |
           tr '[:upper:]' '[:lower:]' |
           tr -c 'a-z0-9._-' '-' |
           cut -c1-32)
    base="${base#-}"
    base="${base%-}"
    # "." and ".." are directory names too, and a launch directory called "-.."
    # trims to "..". $STATE_DIR/sessions/.. is $STATE_DIR itself, so teardown's
    # rm -rf would aim at all of sbx's state; it fails closed today only because
    # POSIX rm refuses to remove "." and "..", which no refactor is obliged to
    # preserve. Fall back to the default name, as the empty case does.
    if [[ -z "$base" || "$base" == "." || "$base" == ".." ]]; then
        base="sbx"
    fi
    printf '%s\n' "$base"
}

# Where a forked mount's store lives on the host. Both --reseed and the
# seeding loop below need this path, and they must never disagree about it:
# --reseed deleting anything other than what the next launch would use is
# either a no-op or a deletion of the wrong tree.
sbx_state_forked_store() {   # <state_dir> <launch_dir> <profile> <dest>
    printf '%s\n' "$1/forked/$3/$(sbx_copy_path_slug "$2")/$(sbx_copy_mount_id "$4")"
}

sbx_state_write_row() {   # <kind> <path> <detail> <dest> <note> <source>
    jq -cn --arg kind "$1" --arg path "$2" --arg detail "$3" --arg dest "$4" --arg note "$5" --arg source "$6" \
        '{kind: $kind, path: $path, detail: $detail, dest: $dest, note: $note, source: $source}'
}

# The widest tmux.sock path the session-name claim loop in sbx can produce
# (see the SOCK_PROBE check there): the loop appends -1, -2, ... on a name
# collision, and -99 is the widest suffix it tries before giving up. Both
# the launch's own too-long-socket check and --dry-run's "stops" entry
# build this same path from this one function, so they cannot disagree
# about what "too long" means.
sbx_state_socket_probe() {   # <state_dir> <session_base>
    printf '%s\n' "$1/sessions/$2-99/tmux.sock"
}

# Every host location a launch of this plan writes, for --dry-run. Reads
# the disk (does a forked store exist yet? how big is the source it would
# be seeded from?) and writes nothing. The session name is already known
# (sbx_state_session_base), so record/archive rows use it directly; the
# only thing still unknown at this point is the archive's timestamp and
# whether a name collision will append -N to the session directory (see
# the caveat on that row below).
sbx_state_writes() {   # <plan json> <state_dir> <launch_dir> [<xauthority file>]
    local plan="$1" state="$2" launch="$3" xauth="${4:-}" slug base
    local profile source dest perm present from store size note record_seen=false
    local -a rows=()
    slug=$(sbx_copy_path_slug "$launch")
    base=$(sbx_state_session_base "$launch")

    while IFS= read -r -d '' profile && IFS= read -r -d '' source &&
          IFS= read -r -d '' dest && IFS= read -r -d '' perm &&
          IFS= read -r -d '' present && IFS= read -r -d '' from; do
        # This perm switch mirrors the one in sbx that actually performs
        # the mounts (the FORKED_MOUNTS/RECORD_MOUNTS case statement); a
        # change to what a perm does at launch belongs in both places.
        case "$perm" in
            forked)
                # An absent source is skipped outright at launch: no store.
                if [[ "$present" != "true" ]]; then
                    continue
                fi
                store=$(sbx_state_forked_store "$state" "$launch" "$profile" "$dest")
                if [[ -e "$store" ]]; then
                    note="exists"
                elif size=$(timeout 5 du -sxh "$source" 2>/dev/null); then
                    size=$(cut -f1 <<< "$size")
                    note="will seed, ${size:-unknown size}"
                elif [[ $? -eq 124 ]]; then
                    note="will seed, size unknown"
                else
                    note="will seed, unknown size"
                fi
                rows+=("$(sbx_state_write_row persistent "$store" \
                    "forked store for $dest from $from; kept until --reseed" "$dest" "$note" "$source")")
                ;;
            record)
                rows+=("$(sbx_state_write_row temporary "$state/work/$base/$(sbx_copy_mount_id "$dest")" \
                    "record working copy of $source; removed at teardown" "$dest" "" "$source")")
                record_seen=true
                ;;
            rw)
                note=""
                if [[ "$present" != "true" ]]; then
                    note="created at launch"
                fi
                rows+=("$(sbx_state_write_row host "$source" "read-write bind at $dest from $from" "$dest" "$note" "$source")")
                ;;
            dev)
                if [[ "$present" == "true" ]]; then
                    rows+=("$(sbx_state_write_row host "$source" "device bind at $dest from $from" "$dest" "" "$source")")
                fi
                ;;
        esac
    done < <(jq -j 'def nul: [0] | implode;
        .mounts[] | .profile, nul, .source, nul, .dest, nul, .perm, nul, (.present | tostring), nul, .from, nul' <<< "$plan")

    if [[ "$record_seen" == "true" ]]; then
        rows+=("$(sbx_state_write_row archived "$state/changes/$slug/<stamp>-$base/" \
            "files the session created or changed in record mounts; the newest SBX_KEEP_CHANGES (default 10) are kept" "" "" "")")
    fi

    if [[ "$(jq -r '.security.userns_full' <<< "$plan")" == "true" ]]; then
        rows+=("$(sbx_state_write_row persistent "$state/virt/containers-full" \
            "podman image and container store (userns full)" "" "" "")")
    elif [[ "$(jq -r '.security.caps_keep or .security.docker_api' <<< "$plan")" == "true" ]]; then
        rows+=("$(sbx_state_write_row persistent "$state/virt/containers" \
            "podman image and container store" "" "" "")")
    fi

    # xpra's host writes: a display cookie merged into the host Xauthority
    # (left in place — it is small, keyed by display, and other displays'
    # entries share the file) and the display socket it creates for the
    # session (see the GUI Setup block in sbx, which is what actually does
    # this at launch).
    if [[ "$(jq -r '.gui // false' <<< "$plan")" == "true" ]]; then
        rows+=("$(sbx_state_write_row host "$xauth" \
            "xpra adds a display cookie; left in place" "" "" "")")
        rows+=("$(sbx_state_write_row temporary "/tmp/.X11-unix/X<N>" \
            "xpra display socket; removed when the display stops" "" "" "")")
    fi

    rows+=("$(sbx_state_write_row temporary "$state/join/$base.{pid,json,lock}" \
        "session bookkeeping (pid, join sidecar, lock); removed at teardown" "" "" "")")

    rows+=("$(sbx_state_write_row temporary "$state/sessions/$base/" \
        "session directory; removed at teardown (-N is appended if the name is in use)" "" "" "")")

    printf '%s\n' "${rows[@]}" | jq -cs .
}
