#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/net-merge.sh"
    D="$BATS_TEST_TMPDIR"
}

profile() {   # <name> <json>
    printf '%s\n' "$2" > "$D/$1.json"
}

@test "merge_ports unions, sorts and lets * absorb" {
    run sbx_net_merge_ports "" "80,443"
    [ "$output" = "80,443" ]
    run sbx_net_merge_ports "443,80" "22,80"
    [ "$output" = "22,80,443" ]
    run sbx_net_merge_ports "80" "*"
    [ "$output" = "*" ]
}

@test "one profile: domains and cidrs carry its ports; default ports are 80,443" {
    profile web '{"dns":"1.1.1.1","allow":["*.google.com","github.com","192.168.1.0/24"]}'
    run sbx_net_merge "$D/web.json"
    [ "$status" -eq 0 ]
    [ "$(jq -c .domains <<< "$output")" = '{"github.com":{"ports":"80,443","upstream":"1.1.1.1"},"google.com":{"ports":"80,443","upstream":"1.1.1.1"}}' ]
    [ "$(jq -c .cidrs <<< "$output")" = '{"192.168.1.0/24":"80,443"}' ]
    [ "$(jq -r .test_domain <<< "$output")" = "github.com" ]
    [ "$(jq -c .upstreams <<< "$output")" = '["1.1.1.1"]' ]
    [ "$(jq -r .allow_all <<< "$output")" = "false" ]
}

@test "stacked profiles pair each destination with its own ports" {
    profile web '{"allow":["github.com"],"ports":[80,443]}'
    profile db  '{"dns":"9.9.9.9","allow":["db.example","github.com","10.0.0.0/8"],"ports":[5432]}'
    run sbx_net_merge "$D/web.json" "$D/db.json"
    [ "$(jq -r '.domains["db.example"].ports' <<< "$output")" = "5432" ]
    [ "$(jq -r '.domains["github.com"].ports' <<< "$output")" = "80,443,5432" ]
    [ "$(jq -r '.cidrs["10.0.0.0/8"]' <<< "$output")" = "5432" ]
}

@test "a domain's upstream is the first profile's that named it" {
    profile a '{"dns":"9.9.9.9","allow":["x.example"]}'
    profile b '{"dns":"8.8.8.8","allow":["x.example","y.example"]}'
    run sbx_net_merge "$D/a.json" "$D/b.json"
    [ "$(jq -r '.domains["x.example"].upstream' <<< "$output")" = "9.9.9.9" ]
    [ "$(jq -r '.domains["y.example"].upstream' <<< "$output")" = "8.8.8.8" ]
    [ "$(jq -c .upstreams <<< "$output")" = '["8.8.8.8","9.9.9.9"]' ]
}

@test "a non-IPv4 or missing dns falls back to 1.1.1.1" {
    profile s '{"dns":"sdns://abc","allow":["x.example"]}'
    run sbx_net_merge "$D/s.json"
    [ "$(jq -r '.domains["x.example"].upstream' <<< "$output")" = "1.1.1.1" ]
}

@test "a wildcard folds its ports into every named domain" {
    profile narrow '{"allow":["db.example"],"ports":[5432]}'
    profile wild   '{"allow":["*"],"ports":["*"]}'
    run sbx_net_merge "$D/narrow.json" "$D/wild.json"
    [ "$(jq -r .allow_all <<< "$output")" = "true" ]
    [ "$(jq -r .allow_all_ports <<< "$output")" = "*" ]
    [ "$(jq -r '.domains["db.example"].ports' <<< "$output")" = "*" ]
}

@test "test_domain skips wildcard entries and comes from the first profile that has a hostname" {
    profile wild '{"allow":["*","10.0.0.0/8"]}'
    profile two  '{"allow":["*.skip.example","first.example","second.example"]}'
    run sbx_net_merge "$D/wild.json" "$D/two.json"
    [ "$(jq -r .test_domain <<< "$output")" = "first.example" ]
}
