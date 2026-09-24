#!/bin/bash
# A session's egress configuration, generated from the plan's .net (see
# lib/net-merge.sh): dnsmasq's per-domain flags and the nftables ruleset for
# the control namespace A.
#
# Sourced by sbx and directly by tests/. Requires lib/nestnet.sh (A's input
# and postrouting chains). Functions only — no side effects at source time,
# no dependency on sbx globals.

# One --server and one --nftset per domain, naming the set for that domain's
# ports. A wildcard adds a catch-all pair on top rather than replacing them:
# dnsmasq prefers the more specific match, so a domain named on narrow ports
# keeps its own set alongside allow: ["*"].
sbx_egress_dnsmasq_args() {   # <net json>
    jq -r '. as $n
        | def set($p): $n.sets[] | select(.ports == $p) | .name;
          (.domains // {} | to_entries[]
             | "--server=/\(.key)/\(.value.upstream)",
               "--nftset=/\(.key)/inet#sbx_filter#\(set(.value.ports))"),
          (if .allow_all then "--server=\(.upstreams[0])", "--nftset=//inet#sbx_filter#\(set(.allow_all_ports))"
           else empty end)' <<< "$1"
}

# An accept for one destination, on the ports it was granted ("*" = any).
sbx_egress_dest_rule() {   # <dest> <port signature>
    if [[ "$2" == "*" ]]; then
        echo "        ip daddr $1 accept"
    else
        echo "        ip daddr $1 tcp dport { $2 } accept"
        echo "        ip daddr $1 udp dport { $2 } accept"
    fi
}

# The allow-list shared by the output and forward chains: each CIDR on its
# own ports, then one rule per set (dnsmasq --nftset fills the sets as
# answers arrive).
sbx_egress_allow_rules() {   # <net json>
    local dest sig
    while IFS=$'\t' read -r dest sig; do
        sbx_egress_dest_rule "$dest" "$sig"
    done < <(jq -r '(.cidrs // {} | to_entries[] | [.key, .value]),
                    (.sets // [] | .[] | ["@" + .name, .ports]) | @tsv' <<< "$1")
}

# The whole `table inet sbx_filter`, default-drop in both egress chains.
#
# output gates A's own traffic: dnsmasq's upstream queries, and loopback,
# which carries pasta's host-port splice (the allow-list for that is pasta's
# -T/-U, not this table). forward gates everything the payload sends, since
# it runs one namespace behind A, and rootful podman's bridge traffic under
# userns: full; it has neither the loopback nor the resolver accepts. IPv6
# is dropped in both. Without a net profile only loopback is open.
sbx_egress_rules() {   # <net json> <dns addr> <tcp csv> <udp csv>
    local net="$1" dns="$2" enabled name upstream
    enabled=$(jq -r '.enabled' <<< "$net")
    echo "table inet sbx_filter {"
    while IFS= read -r name; do
        echo "    set $name {"
        echo "        type ipv4_addr"
        echo "        flags timeout"
        echo "    }"
    done < <(jq -r '.sets // [] | .[].name' <<< "$net")
    echo "    chain output {"
    echo "        type filter hook output priority 0; policy drop;"
    echo "        oif \"lo\" accept"
    echo "        ct state established,related accept"
    if [[ "$enabled" == "true" ]]; then
        echo "        ip daddr $dns udp dport 53 accept"
        echo "        ip daddr $dns tcp dport 53 accept"
        while IFS= read -r upstream; do
            echo "        ip daddr $upstream udp dport 53 accept"
            echo "        ip daddr $upstream tcp dport 53 accept"
        done < <(jq -r '.upstreams[]' <<< "$net")
        sbx_egress_allow_rules "$net"
    fi
    echo "        meta nfproto ipv6 drop"
    echo "    }"
    echo "    chain forward {"
    echo "        type filter hook forward priority 0; policy drop;"
    echo "        ct state established,related accept"
    if [[ "$enabled" == "true" ]]; then
        sbx_egress_allow_rules "$net"
    fi
    echo "        meta nfproto ipv6 drop"
    echo "    }"
    sbx_nestnet_a_rules "$enabled" "$3" "$4"
    echo "}"
}
