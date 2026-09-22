#!/usr/bin/env bats

# lib/nestnet.sh in real namespaces, without pasta: tests/helpers/
# nestnet-scenario.sh builds A and B and stands in for pasta and dnsmasq.
# Egress through pasta is covered end to end in tests/nested.bats.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    for t in socat nft nsenter; do
        command -v "$t" >/dev/null 2>&1 || skip "$t not installed"
    done
    unshare --user --map-root-user --net -- ip link add t0 type veth peer name t1 2>/dev/null \
        || skip "veth unavailable to the running kernel"
}

scenario() {   # <probe script text>
    printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/probe.sh"
    run unshare --user --map-root-user --net -- \
        bash "$REPO/tests/helpers/nestnet-scenario.sh" "$REPO/lib" "$BATS_TEST_TMPDIR/probe.sh"
    if [[ "$output" != *"setup=ok"* ]]; then
        echo "$output" >&2
        return 1
    fi
}

@test "a_rules prints an input chain that names only the granted ports and DNS" {
    source "$REPO/lib/nestnet.sh"
    run sbx_nestnet_a_rules true 5433 5353
    [ "$status" -eq 0 ]
    [[ "$output" == *'iifname "sbx-a" ip daddr 10.200.0.1 tcp dport { 5433 } accept'* ]]
    [[ "$output" == *'iifname "sbx-a" ip daddr 10.200.0.1 udp dport { 5353 } accept'* ]]
    [[ "$output" == *'iifname "sbx-a" ip daddr 10.200.0.1 udp dport 53 accept'* ]]
    [[ "$output" == *'iifname "sbx-a" counter drop'* ]]
    [[ "$output" == *'ip saddr 10.200.0.2 oifname != "sbx-a" masquerade'* ]]
}

@test "a_rules without DNS or host ports still drops everything from B" {
    source "$REPO/lib/nestnet.sh"
    run sbx_nestnet_a_rules false "" ""
    [[ "$output" != *dport* ]]
    [[ "$output" == *'iifname "sbx-a" counter drop'* ]]
}

@test "a granted TCP host port answers at 127.0.0.1 in B" {
    scenario 'echo "r=$(tcp_get 127.0.0.1 18081)"'
    [[ "$output" == *"r=granted"* ]]
}

@test "a granted UDP host port answers at 127.0.0.1 in B" {
    scenario 'echo "r=$(udp_get 127.0.0.1 18083)"'
    [[ "$output" == *"r=udp-granted"* ]]
}

@test "DNS at 127.0.0.2 in B reaches the resolver on A's veth address" {
    scenario 'echo "r=$(udp_get 127.0.0.2 53)"'
    [[ "$output" == *"r=resolver"* ]]
}

@test "a host port that was not granted is unreachable from B" {
    scenario 'echo "lo=$(tcp_get 127.0.0.1 18082)"; echo "veth=$(tcp_get 10.200.0.1 18082)"'
    [[ "$output" == *"veth="* ]]
    [[ "$output" != *not-granted* ]]
}

@test "B's own DNAT to a port that was not granted is dropped by A" {
    scenario 'before=$(a_drops)
        inb nft add rule ip sbx_nest output ip daddr 127.0.0.1 tcp dport 18082 dnat to 10.200.0.1
        echo "r=$(tcp_get 127.0.0.1 18082)"
        echo "rose=$(( $(a_drops) > before ))"'
    [[ "$output" != *not-granted* ]]
    [[ "$output" == *"rose=1"* ]]
}

@test "rerouting 127.0.0.0/8 out of the veth reaches nothing on A's loopback" {
    scenario 'inb ip route del local 127.0.0.1 dev lo table local
        inb ip route del local 127.0.0.0/8 dev lo table local
        inb ip route add 127.0.0.0/8 via 10.200.0.1 dev sbx-b src 10.200.0.2
        echo "r=$(tcp_get 127.0.0.1 18082)"'
    [[ "$output" != *not-granted* ]]
}

@test "after B flushes its ruleset only its own shortcuts are gone" {
    scenario 'inb nft flush ruleset
        echo "lo=$(tcp_get 127.0.0.1 18081)"
        echo "veth=$(tcp_get 10.200.0.1 18081)"
        echo "other=$(tcp_get 10.200.0.1 18082)"'
    [[ "$output" != *"lo=granted"* ]]
    [[ "$output" == *"veth=granted"* ]]
    [[ "$output" != *not-granted* ]]
}

@test "relays report failure when a port on A's veth address is taken" {
    scenario 'sbx_nestnet_release
        socat TCP-LISTEN:18090,bind=10.200.0.1,so-bindtodevice=sbx-a,reuseaddr SYSTEM:true &
        sleep 0.3
        if sbx_nestnet_relays 18090 ""; then echo "relays=ok"; else echo "relays=failed"; fi'
    [[ "$output" == *"relays=failed"* ]]
}
