#!/bin/bash
# Networking between the control namespace A and the payload namespace B.
#
# sbx_nestnet_a_rules runs in sbx and prints nft text for A's ruleset. The
# other functions run in launch.sh, in A, after sbx_userns_hold. Sourced by
# sbx, launch.sh and tests/; constants and functions only, no side effects
# at source time. Uses iproute2 (ip, ss), nft, nsenter, socat, setpriv and
# setsid.
#
# B reaches A only where A's input chain says: the granted host ports and
# DNS, at A's veth address. Host ports cannot be DNATed onto A's loopback,
# because pasta binds its splice listener to the lo device
# (SO_BINDTODEVICE); a socat relay on A's veth address forwards to it
# instead. A never sets route_localnet, so nothing B sends is delivered to
# A's loopback. B's own rules only move the familiar addresses
# (127.0.0.1:<port>, the resolver's 127.0.0.2) onto A's veth address; a
# payload that deletes them loses those addresses and gains nothing.

SBX_NEST_A_IF=sbx-a
SBX_NEST_B_IF=sbx-b
# A carries two addresses. dnsmasq listens only on SBX_NEST_A_ADDR; the
# host-port relays bind only on SBX_NEST_RELAY_ADDR. A granted host port of
# 53 would otherwise collide with dnsmasq's own listener on the same
# address: so-bindtodevice separates a relay from pasta's lo-bound listener,
# but not from an unbound socket already on the address the relay wants to
# bind (measured 2026-09-23, both bind orders). Splitting the address is
# cheaper than trying to make one listener yield to the other.
SBX_NEST_A_ADDR=10.200.0.1
SBX_NEST_RELAY_ADDR=10.200.0.2
SBX_NEST_B_ADDR=10.200.0.3
SBX_NEST_PREFIX=29

# A's additions to `table inet sbx_filter`. input is the boundary for what B
# may reach on A itself; it matches iifname, so it loads before the veth
# exists. Its policy is accept, not drop, because A's own pasta-side traffic
# (the session's networking, unrelated to B) must keep working on that same
# hook; the explicit accepts plus a trailing iifname-"sbx-a" drop are enough,
# since nothing in the session can create another interface in A to dodge
# that match. postrouting masquerades B's traffic leaving A by pasta's
# interface: the spikes ran with it, and whether pasta would translate B's
# forwarded traffic on its own is untested.
sbx_nestnet_a_rules() {   # <dns true|false> <tcp csv> <udp csv>
    local dns="$1" tcp="$2" udp="$3"
    echo "    chain input {"
    echo "        type filter hook input priority 0; policy accept;"
    if [[ -n "$tcp" ]]; then
        echo "        iifname \"$SBX_NEST_A_IF\" ip daddr $SBX_NEST_RELAY_ADDR tcp dport { $tcp } accept"
    fi
    if [[ -n "$udp" ]]; then
        echo "        iifname \"$SBX_NEST_A_IF\" ip daddr $SBX_NEST_RELAY_ADDR udp dport { $udp } accept"
    fi
    if [[ "$dns" == "true" ]]; then
        echo "        iifname \"$SBX_NEST_A_IF\" ip daddr $SBX_NEST_A_ADDR udp dport 53 accept"
        echo "        iifname \"$SBX_NEST_A_IF\" ip daddr $SBX_NEST_A_ADDR tcp dport 53 accept"
    fi
    echo "        iifname \"$SBX_NEST_A_IF\" counter drop"
    echo "    }"
    echo "    chain postrouting {"
    echo "        type nat hook postrouting priority srcnat; policy accept;"
    echo "        ip saddr $SBX_NEST_B_ADDR oifname != \"$SBX_NEST_A_IF\" masquerade"
    echo "    }"
}

# A session without networking: B's network namespace is empty apart from
# its loopback, which starts down.
sbx_nestnet_lo_up() {   # <b pid>
    nsenter --net="/proc/$1/ns/net" -- ip link set lo up
}

# A creates the pair and moves B's end into B's network namespace: a process
# in A holds capabilities over namespaces owned by B, while B could never
# create an interface in A's. B then configures nothing itself.
sbx_nestnet_wire() {   # <b pid>
    local b="/proc/$1/ns/net"
    ip link add "$SBX_NEST_A_IF" type veth peer name "$SBX_NEST_B_IF" || return 1
    ip link set "$SBX_NEST_B_IF" netns "$1" || return 1
    ip addr add "$SBX_NEST_A_ADDR/$SBX_NEST_PREFIX" dev "$SBX_NEST_A_IF" || return 1
    ip addr add "$SBX_NEST_RELAY_ADDR/$SBX_NEST_PREFIX" dev "$SBX_NEST_A_IF" || return 1
    ip link set "$SBX_NEST_A_IF" up || return 1
    echo 1 > /proc/sys/net/ipv4/ip_forward || return 1
    nsenter --net="$b" -- ip link set lo up || return 1
    nsenter --net="$b" -- ip addr add "$SBX_NEST_B_ADDR/$SBX_NEST_PREFIX" dev "$SBX_NEST_B_IF" || return 1
    nsenter --net="$b" -- ip link set "$SBX_NEST_B_IF" up || return 1
    nsenter --net="$b" -- ip route add default via "$SBX_NEST_A_ADDR"
}

# B's convenience rules. Locally generated connections to 127.0.0.1:<granted
# port> and to the resolver are DNATed to A's veth address; route_localnet
# lets a loopback-sourced packet leave by sbx-b, and the masquerade gives it
# B's address. Loaded from A, before the payload starts.
sbx_nestnet_b_rules() {   # <b pid> <dns addr or ""> <tcp csv> <udp csv>
    local b="/proc/$1/ns/net" dns="$2" tcp="$3" udp="$4"
    if [[ -z "$dns" && -z "$tcp" && -z "$udp" ]]; then
        return 0
    fi
    nsenter --net="$b" -- sh -c "echo 1 > /proc/sys/net/ipv4/conf/$SBX_NEST_B_IF/route_localnet" || return 1
    {
        echo "table ip sbx_nest {"
        echo "    chain output {"
        echo "        type nat hook output priority -100; policy accept;"
        if [[ -n "$tcp" ]]; then
            echo "        ip daddr 127.0.0.1 tcp dport { $tcp } dnat to $SBX_NEST_RELAY_ADDR"
        fi
        if [[ -n "$udp" ]]; then
            echo "        ip daddr 127.0.0.1 udp dport { $udp } dnat to $SBX_NEST_RELAY_ADDR"
        fi
        if [[ -n "$dns" ]]; then
            echo "        ip daddr $dns udp dport 53 dnat to $SBX_NEST_A_ADDR"
            echo "        ip daddr $dns tcp dport 53 dnat to $SBX_NEST_A_ADDR"
        fi
        echo "    }"
        echo "    chain postrouting {"
        echo "        type nat hook postrouting priority srcnat; policy accept;"
        echo "        oifname \"$SBX_NEST_B_IF\" ip saddr 127.0.0.0/8 masquerade"
        echo "    }"
        echo "}"
    } | nsenter --net="$b" -- nft -f -
}

# One relay per granted port and protocol, from A's relay address to
# pasta's splice listener on A's loopback. so-bindtodevice lets the relay
# share the port number with that listener, which pasta binds to the lo
# device. Each relay carries --pdeathsig, like B's holder; socat's own
# fork() for each UDP peer does not inherit that pdeathsig (a Linux
# prctl(2) rule: it is cleared across fork), so setsid gives the relay its
# own process group and sbx_nestnet_release kills the whole group, reaching
# those children too.
#
# This assumes a caller without job control: `$!` after `setsid socat & ` is
# the setsid process itself only because there is no shell job control to
# report it separately. Under job control, `$!` would name the exited
# `setsid` rather than the socat it started, and this function would fail
# closed (the readiness loop's `kill -0` would find it already gone).
#
# ss's plain `src ADDR:PORT` filter matches any listener on that tuple, not
# specifically ours: when the port is already taken, it reports the other
# listener as "ready" while our own relay is still failing its bind, a race
# this function would otherwise win by accident. `-p` and a `pid=<pid>,`
# match on our own recorded pid close that gap; verified against both a
# free port and one already held by another listener.
# Returns once every relay is listening, or 1 if one exits first (a taken
# port, a missing socat).
sbx_nestnet_relays() {   # <tcp csv> <udp csv>
    local -a tcp udp
    local p pid ready i
    IFS=, read -ra tcp <<< "$1"
    IFS=, read -ra udp <<< "$2"
    SBX_NEST_RELAY_PIDS=()
    for p in "${tcp[@]}"; do
        setpriv --pdeathsig KILL -- setsid socat \
            "TCP-LISTEN:$p,bind=$SBX_NEST_RELAY_ADDR,so-bindtodevice=$SBX_NEST_A_IF,fork,reuseaddr" \
            "TCP:127.0.0.1:$p" </dev/null >/dev/null 2>&1 &
        SBX_NEST_RELAY_PIDS+=("$!")
    done
    for p in "${udp[@]}"; do
        setpriv --pdeathsig KILL -- setsid socat \
            "UDP-RECVFROM:$p,bind=$SBX_NEST_RELAY_ADDR,so-bindtodevice=$SBX_NEST_A_IF,fork,reuseaddr" \
            "UDP:127.0.0.1:$p" </dev/null >/dev/null 2>&1 &
        SBX_NEST_RELAY_PIDS+=("$!")
    done
    for _ in {1..100}; do
        for pid in "${SBX_NEST_RELAY_PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null || return 1
        done
        ready=true
        for i in "${!tcp[@]}"; do
            [[ "$(ss -Hltnp "src $SBX_NEST_RELAY_ADDR:${tcp[$i]}")" == *"pid=${SBX_NEST_RELAY_PIDS[$i]},"* ]] \
                || ready=false
        done
        for i in "${!udp[@]}"; do
            [[ "$(ss -Hlunp "src $SBX_NEST_RELAY_ADDR:${udp[$i]}")" \
                == *"pid=${SBX_NEST_RELAY_PIDS[$((${#tcp[@]} + i))]},"* ]] \
                || ready=false
        done
        if [[ "$ready" == "true" ]]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

sbx_nestnet_release() {
    local pid
    for pid in "${SBX_NEST_RELAY_PIDS[@]:-}"; do
        # SIGKILL, not the default TERM: socat's forked UDP handler defers
        # or ignores TERM while blocked reading, so it survives its own
        # process group being sent that signal.
        kill -9 -- "-$pid" 2>/dev/null
    done
    return 0
}
