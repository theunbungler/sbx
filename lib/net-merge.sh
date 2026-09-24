#!/bin/bash
# Composition of several net profiles into one set of egress grants.
#
# Sourced by sbx and directly by tests/. Defines a constant and functions
# only — no side effects at source time, no dependency on sbx globals.
#
# Each destination is paired with the ports of the profile that allowed it,
# rather than every destination sharing one union of every profile's ports.
# Stacking `--net web` (80,443) with `--net db` (5432) grants the web hosts
# 80,443 and the database host 5432 — not both hosts all three, which would
# be more access than either profile asked for.
#
# Pairing gives each distinct port list its own nftables set and points each
# domain at the set for its ports. dnsmasq forces that shape: a domain feeds
# exactly ONE nftset (with two --nftset options for one domain, only the
# first receives the answer). Hence the one union that cannot be avoided: a
# domain named by several profiles gets the union of their ports, which is
# also the right reading, since each profile authorized it. An explicit CIDR
# needs no set; it becomes its own rule on its own ports.

# shellcheck disable=SC2016  # jq program: $vars are jq's, not the shell's
SBX_NET_MERGE_JQ='
# A profile'"'"'s port signature: "*", or its ports sorted, comma-joined;
# hostnames with no ports default to web.
def sig:
  if any(.ports[]?; . == "*") then "*"
  else ([.ports[]?] | unique | map(tostring) | join(",")) as $s
       | if $s == "" then "80,443" else $s end
  end;
# Union of two signatures; "*" absorbs everything.
def union($a; $b):
  if $a == "" or $a == null then $b
  elif $a == "*" or $b == "*" then "*"
  else ($a / ",") + ($b / ",") | map(tonumber) | unique | map(tostring) | join(",")
  end;
# dnsmasq does not speak DoH stamps: anything but a bare IPv4 address falls
# back to Cloudflare. Per profile: its domains are asked of its resolver.
def upstream:
  (.dns // "") as $d
  | if ($d | type) == "string" and ($d | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) then $d else "1.1.1.1" end;

[inputs] as $profiles
| reduce ($profiles[] | {sig: sig, up: upstream, allow: [.allow[]? | strings]}) as $p
    ({domains: {}, cidrs: {}, allow_all: false, allow_all_ports: "", upstreams: []};
     .upstreams += [$p.up]
     | reduce $p.allow[] as $a (.;
         if $a == "*" then
           .allow_all = true | .allow_all_ports = union(.allow_all_ports; $p.sig)
         elif ($a | test("^[a-zA-Z*]")) then
           # dnsmasq --server=/domain/ matches the apex and every subdomain.
           ($a | sub("^\\*\\."; "")) as $d
           | .domains[$d].ports = union(.domains[$d].ports; $p.sig)
           | .domains[$d].upstream //= $p.up
         elif ($a | test("^[0-9]")) then
           .cidrs[$a] = union(.cidrs[$a]; $p.sig)
         else . end))
# A wildcard authorizes every domain, including ones another profile named
# on narrower ports; since dnsmasq prefers the more specific match, such a
# domain would otherwise lose reach by being stacked. Composing profiles
# only ever adds.
| if .allow_all then .allow_all_ports as $all | .domains |= map_values(.ports = union(.ports; $all)) else . end
| .upstreams |= unique
# The first hostname from any profile, for the readiness probe.
| .test_domain = ([$profiles[] | .allow[]? | strings | select(test("^[a-zA-Z]"))] | .[0] // "")
# One nftables set per distinct port signature, named in a fixed order:
# domains by name, then the wildcard.
| .sets = ( [ (.domains | to_entries | sort_by(.key)[] | .value.ports),
              (if .allow_all then .allow_all_ports else empty end) ]
            | reduce .[] as $s ([]; if any(.[]; . == $s) then . else . + [$s] end)
            | to_entries | map({name: "allowed4_\(.key + 1)", ports: .value}) )
'

sbx_net_merge() {   # <net profile path>...
    jq -n -S "$SBX_NET_MERGE_JQ" "$@"
}
