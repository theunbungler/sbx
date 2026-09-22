#!/usr/bin/env bats

# lib/userns.sh in real namespaces. Each test plays the part of launch.sh:
# `unshare --user --map-root-user --net` is the control namespace A, and the
# library creates the payload namespace B inside it.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/lib/userns.sh"
}

in_a() {   # <script>: run in a single-uid A, like pasta's namespace
    unshare --user --map-root-user --net -- bash -c "source '$LIB'; $1"
}

in_full_a() {   # <script>: run in an A carrying the subordinate range, like userns: full
    awk -F: -v u="$(id -un)" -v i="$(id -u)" '$1 == u || $1 == i { f = 1 } END { exit !f }' /etc/subuid 2>/dev/null \
        || skip "no subordinate uid range for this user"
    unshare --map-auto --map-root-user --net -- bash -c "source '$LIB'; $1"
}

@test "hold puts B in a new user namespace and a new network namespace" {
    run in_a 'sbx_userns_hold || exit 1
        [[ $(readlink /proc/$SBX_B_PID/ns/user) != $(readlink /proc/self/ns/user) ]] && echo user-ok
        [[ $(readlink /proc/$SBX_B_PID/ns/net) != $(readlink /proc/self/ns/net) ]] && echo net-ok
        sbx_userns_release "$SBX_B_PID"'
    [ "$status" -eq 0 ]
    [[ "$output" == *user-ok* ]]
    [[ "$output" == *net-ok* ]]
}

@test "B owns its network namespace" {
    # Only the owner of a network namespace may configure it, so root in B
    # bringing up B's loopback proves the ownership.
    run in_a 'sbx_userns_hold && sbx_userns_map_identity "$SBX_B_PID" || exit 1
        nsenter -t "$SBX_B_PID" -U -n --preserve-credentials -- ip link set lo up && echo configured
        sbx_userns_release "$SBX_B_PID"'
    [[ "$output" == *configured* ]]
}

@test "identity map mirrors a single-range A" {
    run in_a 'sbx_userns_hold && sbx_userns_map_identity "$SBX_B_PID" || exit 1
        tr -s " " < /proc/$SBX_B_PID/uid_map; tr -s " " < /proc/$SBX_B_PID/gid_map
        sbx_userns_release "$SBX_B_PID"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = " 0 0 1" ]
    [ "${lines[1]}" = " 0 0 1" ]
}

@test "identity map mirrors a multi-range A" {
    run in_full_a 'sbx_userns_hold && sbx_userns_map_identity "$SBX_B_PID" || exit 1
        tr -s " " < /proc/$SBX_B_PID/uid_map
        sbx_userns_release "$SBX_B_PID"'
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = " 0 0 1" ]
    [[ "${lines[1]}" == " 1 1 "* ]]
}

@test "outer-id map shows the payload the host uid and gid" {
    run in_a 'sbx_userns_hold && sbx_userns_map_outer_ids "$SBX_B_PID" || exit 1
        nsenter -t "$SBX_B_PID" -U --preserve-credentials -- sh -c "id -u; id -g"
        sbx_userns_release "$SBX_B_PID"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$(id -u)" ]
    [ "${lines[1]}" = "$(id -g)" ]
}

@test "a map split across two writes is refused, which is why write_map exists" {
    run in_full_a 'sbx_userns_hold || exit 1
        if { echo "0 0 1"; echo "1 1 10"; } > /proc/$SBX_B_PID/uid_map 2>/dev/null; then echo accepted; else echo refused; fi
        sbx_userns_release "$SBX_B_PID"'
    [[ "$output" == *refused* ]]
}

@test "the holder dies when the shell that started it is killed" {
    local f="$BATS_TEST_TMPDIR/holder"
    run in_a "( sbx_userns_hold; echo \$SBX_B_PID > '$f'; exec sleep 60 ) &
        s=\$!
        for _ in \$(seq 1 50); do [[ -s '$f' ]] && break; sleep 0.1; done
        kill -9 \$s; sleep 0.5
        if kill -0 \$(cat '$f') 2>/dev/null; then echo alive; else echo gone; fi"
    [[ "$output" == *gone* ]]
}

@test "release ends B" {
    run in_a 'sbx_userns_hold || exit 1
        p=$SBX_B_PID
        sbx_userns_release "$p"
        if kill -0 "$p" 2>/dev/null; then echo alive; else echo gone; fi'
    [[ "$output" == *gone* ]]
}
