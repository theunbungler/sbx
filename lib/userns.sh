#!/bin/bash
# The payload namespace B: a user namespace nested in the session's control
# namespace A, owning its own network namespace.
#
# Sourced at run time by launch.sh, which runs in A, and by tests/.
# Functions only; no side effects at source time. Uses util-linux
# (unshare, setpriv) and coreutils (dd, sleep, readlink).
#
# Why B exists: bwrap runs in A, so every mount it makes belongs to A, and a
# mount inherited across a user-namespace boundary is MNT_LOCKED. From B it
# cannot be remounted or unmounted, whatever capabilities B holds. A's nft
# ruleset lives in A's network namespace, which B cannot see.

# Starts B's holder and sets SBX_B_PID. The holder is a sleep in a new user
# namespace and a new network namespace owned by it; B lives as long as the
# holder does. --pdeathsig ties the holder to the calling shell, so a
# SIGKILLed launch.sh does not leak it (the signal survives the unshare:
# verified 2026-09-21). The maps are written separately, by the caller.
sbx_userns_hold() {
    local mine theirs
    mine=$(readlink /proc/self/ns/user)
    setpriv --pdeathsig KILL -- unshare --user --net -- sleep infinity \
        </dev/null >/dev/null 2>&1 &
    SBX_B_PID=$!
    for _ in {1..250}; do
        theirs=$(readlink "/proc/$SBX_B_PID/ns/user" 2>/dev/null) || return 1
        if [[ "$theirs" != "$mine" ]]; then
            return 0
        fi
        sleep 0.02
    done
    return 1
}

# The kernel accepts exactly one write(2) to a uid_map or gid_map. printf
# and echo may split a multi-line map across writes, and the second write
# then fails with EINVAL, which reads as "multi-range maps are impossible".
# dd with iflag=fullblock collects the whole input before its single write.
sbx_userns_write_map() {   # <map file> <map text>
    printf '%s\n' "$2" | dd of="$1" bs=65536 iflag=fullblock status=none
}

# B mirrors the caller's ranges as an identity map: every id A can represent
# means the same id in B. Networked and userns: full sessions, whose payload
# has always run as A's 0.
sbx_userns_map_identity() {   # <pid>
    local kind map inside outside count
    for kind in uid gid; do
        map=""
        while read -r inside outside count; do
            map+="${map:+$'\n'}$inside $inside $count"
        done < "/proc/self/${kind}_map"
        sbx_userns_write_map "/proc/$1/${kind}_map" "$map" || return 1
    done
}

# B maps the host id that A's 0 stands for onto A's 0, so the payload sees
# the identity a bwrap-created namespace gave it before B existed: sessions
# without networking, where A comes from `unshare --map-root-user`.
sbx_userns_map_outer_ids() {   # <pid>
    local kind inside outside count
    for kind in uid gid; do
        while read -r inside outside count; do
            if [[ "$inside" == 0 ]]; then
                break
            fi
        done < "/proc/self/${kind}_map"
        [[ "$inside" == 0 ]] || return 1
        sbx_userns_write_map "/proc/$1/${kind}_map" "$outside 0 1" || return 1
    done
}

sbx_userns_release() {   # <pid>
    if [[ -n "${1:-}" ]]; then
        kill "$1" 2>/dev/null
        wait "$1" 2>/dev/null
    fi
    return 0
}
