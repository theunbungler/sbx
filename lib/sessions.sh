#!/bin/bash
# Session bookkeeping on the host: liveness, removal, name checks and
# change-archive pruning.
#
# Sourced by sbx and directly by tests/. Defines functions only — no side
# effects at source time, no dependency on sbx globals: the state directory
# is an argument.
#
# Liveness comes only from join/<name>.pid, never from session.json. That
# file lives in the session directory, which is bound rw into the sandbox,
# so a payload could forge or delete it to make a live session look dead —
# and a dead session gets deleted. join/ is masked inside the sandbox.

# Prints the session's supervising pid and succeeds if it is alive. The pid
# is checked numeric before kill: an unchecked value signals whoever it
# names.
sbx_session_live_pid() {   # <state_dir> <name>
    local pid="" f="$1/join/$2.pid"
    if [[ -f "$f" ]]; then
        read -r pid < "$f" || true
    fi
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        printf '%s\n' "$pid"
        return 0
    fi
    return 1
}

sbx_session_alive() {   # <state_dir> <name>
    sbx_session_live_pid "$1" "$2" >/dev/null
}

# Everything a session leaves under $STATE_DIR apart from its work tree and
# archives: the session directory and every join/ sidecar. All of them go
# together — a stale join/<name>.json outliving its session would describe
# the next session to claim the name.
sbx_session_remove() {   # <state_dir> <name>
    rm -rf "${1:?}/sessions/${2:?}"
    rm -f "$1/join/$2.json" "$1/join/$2.lock" "$1/join/$2.pid" "$1/join/$2.seccomp"
}

# A session name is typed by hand at --join and --attach and interpolated
# into paths under $STATE_DIR. Same character set the launch derives
# (sbx_state_session_base), minus "." and "..", which name directories.
sbx_session_name_valid() {   # <name>
    [[ "$1" =~ ^[a-z0-9._-]+$ && "$1" != "." && "$1" != ".." ]]
}

# SBX_KEEP_CHANGES comes from the environment — plausibly a project .envrc —
# and reaches $(( )). Bash arithmetic reads a non-numeric word as 0, which
# would prune every archive, and expands command substitution inside an
# array subscript. Nothing reaches the arithmetic unvalidated.
sbx_keep_changes() {
    local keep="${SBX_KEEP_CHANGES:-10}"
    if [[ ! "$keep" =~ ^[0-9]+$ ]]; then
        echo "Warning: ignoring non-numeric SBX_KEEP_CHANGES='$keep'; using 10." >&2
        keep=10
    fi
    printf '%s\n' "$keep"
}

# Keeps the newest <keep> archives in one launch directory's changes/ dir.
# Archive names start with a timestamp, so a bytewise sort is chronological.
sbx_prune_changes() {   # <changes dir for one launch dir> <keep>
    find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
        LC_ALL=C sort -r | tail -n "+$(($2 + 1))" |
        while IFS= read -r old; do rm -rf "${old:?}"; done
}
