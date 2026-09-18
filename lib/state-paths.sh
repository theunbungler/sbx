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
