#!/usr/bin/env bats

# lib/egress.sh: the dnsmasq flags and nft ruleset generated from a merged
# net config (lib/net-merge.sh). No sandbox is launched.

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    source "$LIB/nestnet.sh"
    source "$LIB/net-merge.sh"
    source "$LIB/egress.sh"
    W="$BATS_TEST_TMPDIR/w"
    mkdir -p "$W"
}

net() {   # <name> <json>: writes a net profile, echoes its path
    printf '%s\n' "$2" > "$W/$1.json"
    echo "$W/$1.json"
}

merged() {   # <profile path>...: the plan's .net for these profiles
    sbx_net_merge "$@" | jq -c '. + {enabled: true}'
}

@test "each distinct port signature gets its own set, in a fixed order" {
    local web db
    web=$(net web '{"allow":["web.example"],"ports":[80,443]}')
    db=$(net db '{"allow":["db.example"],"ports":[5432]}')
    [ "$(merged "$web" "$db" | jq -c .sets)" = '[{"name":"allowed4_1","ports":"5432"},{"name":"allowed4_2","ports":"80,443"}]' ]
}

@test "dnsmasq flags point each domain at the set for its ports" {
    local web db
    web=$(net web '{"allow":["web.example"],"ports":[80,443]}')
    db=$(net db '{"allow":["db.example"],"ports":[5432],"dns":"9.9.9.9"}')
    run sbx_egress_dnsmasq_args "$(merged "$web" "$db")"
    [ "$output" = "$(printf '%s\n' \
        --server=/db.example/9.9.9.9 --nftset=/db.example/inet#sbx_filter#allowed4_1 \
        --server=/web.example/1.1.1.1 --nftset=/web.example/inet#sbx_filter#allowed4_2)" ]
}

@test "a wildcard adds a catch-all pair beside the named domains" {
    local wild
    wild=$(net wild '{"allow":["*","a.example"],"ports":["*"]}')
    run sbx_egress_dnsmasq_args "$(merged "$wild")"
    [ "${lines[2]}" = "--server=1.1.1.1" ]
    [ "${lines[3]}" = "--nftset=//inet#sbx_filter#allowed4_1" ]
}

@test "rules gate each set and CIDR on its own ports in both chains" {
    local web
    web=$(net web '{"allow":["web.example","10.0.0.0/8"],"ports":[443]}')
    run sbx_egress_rules "$(merged "$web")" 127.0.0.2 "" ""
    [ "$(grep -c 'ip daddr 10.0.0.0/8 tcp dport { 443 } accept' <<< "$output")" -eq 2 ]
    [ "$(grep -c 'ip daddr @allowed4_1 tcp dport { 443 } accept' <<< "$output")" -eq 2 ]
    [[ "$output" == *"set allowed4_1 {"* ]]
    [[ "$output" == *"ip daddr 127.0.0.2 udp dport 53 accept"* ]]
    [[ "$output" == *"ip daddr 1.1.1.1 tcp dport 53 accept"* ]]
}

@test "without a net profile only loopback is open and no set exists" {
    run sbx_egress_rules '{"enabled":false}' 127.0.0.2 8080 ""
    [[ "$output" == *'oif "lo" accept'* ]]
    if [[ "$output" == *"dport 53"* || "$output" == *"set allowed4"* ]]; then
        echo "a host-ports-only ruleset opened DNS or declared a set" >&2
        return 1
    fi
    [[ "$output" == *"tcp dport { 8080 } accept"* ]]
}

@test "the ruleset loads in nft's own parser" {
    if ! command -v nft >/dev/null 2>&1 || ! unshare --user --map-root-user --net true 2>/dev/null; then
        skip "needs nft and an unprivileged network namespace"
    fi
    local web
    web=$(net web '{"allow":["web.example","10.0.0.0/8"],"ports":[443]}')
    sbx_egress_rules "$(merged "$web")" 127.0.0.2 8080 53 > "$W/rules.nft"
    unshare --user --map-root-user --net nft -c -f "$W/rules.nft"
}
