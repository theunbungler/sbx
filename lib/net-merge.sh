#!/bin/bash
# Composition of several net profiles into one set of egress grants.
#
# Sourced by sbx and directly by tests/. Defines functions only — no side
# effects at source time, no dependency on sbx globals.

# Union of two port signatures. "*" absorbs everything.
sbx_net_merge_ports() {   # <sig> <sig>
    local a="$1" b="$2"
    if [[ -z "$a" ]]; then
        echo "$b"
        return 0
    fi
    if [[ "$a" == "*" || "$b" == "*" ]]; then
        echo "*"
        return 0
    fi
    printf '%s\n%s\n' "${a//,/$'\n'}" "${b//,/$'\n'}" | sort -n -u | paste -sd, -
}

sbx_net_merge() {   # <net profile path>...
    # --- Composing several net profiles ---
    #
    # Each destination is paired with the ports of the profile that allowed
    # it, rather than every destination sharing one union of every profile's
    # ports. Stacking `--net web` (80,443) with `--net db` (5432) therefore
    # grants the web hosts 80,443 and the database host 5432 — not both hosts
    # on all three ports, which is what a flat union would produce and is
    # strictly more access than either profile asked for.
    #
    # Pairing is done by giving each distinct port list its own nftables set
    # and pointing each domain at the set for its ports. This is forced by
    # dnsmasq: a domain feeds exactly ONE nftset (verified — with two
    # --nftset options for one domain, only the first receives the answer),
    # so a domain cannot be gated two different ways at once. Hence the one
    # place a union is unavoidable: a domain named by several profiles gets
    # the union of their ports. That is also the right reading, since each
    # profile independently authorized it.
    #
    # An explicit CIDR needs no set — it is already an address — so it is
    # emitted as its own rule, gated by the same paired port list.
    local np np_upstream np_ports entry domain cidr k
    local -A domain_ports=() domain_upstream=() cidr_ports=()
    local allow_all=false allow_all_ports="" test_domain=""
    local -a upstreams=()

    for np in "$@"; do
        # DNS upstream must be a plain IP — dnsmasq does not speak DoH stamps.
        # If the profile supplies a stamp or leaves dns empty, fall back to
        # Cloudflare. Resolved per profile: each profile's domains are asked
        # of the resolver that profile named.
        np_upstream=$(jq -r '.dns // empty' "$np")
        if ! [[ "$np_upstream" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            np_upstream="1.1.1.1"
        fi
        upstreams+=("$np_upstream")

        # This profile's port signature, normalised once.
        if jq -e '.ports[]? | select(. == "*")' "$np" >/dev/null 2>&1; then
            np_ports="*"
        else
            np_ports=$(jq -r '.ports[]?' "$np" | sort -n -u | paste -sd, -)
            # Hostnames allowed but no ports specified -> default to web.
            if [[ -z "$np_ports" ]]; then
                np_ports="80,443"
            fi
        fi

        while IFS= read -r entry; do
            if [[ -z "$entry" ]]; then
                continue
            fi
            if [[ "$entry" == "*" ]]; then
                allow_all=true
                allow_all_ports=$(sbx_net_merge_ports "$allow_all_ports" "$np_ports")
                continue
            fi
            # Strips leading '*.' — dnsmasq --server=/domain/up matches the
            # apex plus all subdomains.
            domain="${entry#\*.}"
            domain_ports["$domain"]=$(sbx_net_merge_ports "${domain_ports[$domain]:-}" "$np_ports")
            if [[ -z "${domain_upstream[$domain]:-}" ]]; then
                domain_upstream["$domain"]="$np_upstream"
            fi
        done < <(jq -r '.allow[]? | select(type == "string" and test("^[a-zA-Z*]"))' "$np")

        while IFS= read -r cidr; do
            if [[ -z "$cidr" ]]; then
                continue
            fi
            cidr_ports["$cidr"]=$(sbx_net_merge_ports "${cidr_ports[$cidr]:-}" "$np_ports")
        done < <(jq -r '.allow[]? | select(type == "string" and test("^[0-9]"))' "$np")
    done

    # A wildcard profile authorizes every domain, including ones another
    # profile also named on narrower ports. Because a domain feeds exactly
    # one nftset, and dnsmasq prefers the more specific match, such a domain
    # would otherwise land in the narrow set and lose the access the
    # wildcard already granted — stacking a profile would REMOVE reach.
    # Folding the wildcard's ports into every named domain keeps the rule
    # that composing profiles only ever adds.
    if [[ "$allow_all" == "true" ]]; then
        for k in "${!domain_ports[@]}"; do
            domain_ports["$k"]=$(sbx_net_merge_ports "${domain_ports[$k]}" "$allow_all_ports")
        done
    fi

    # First hostname from any profile, for the readiness probe.
    for np in "$@"; do
        test_domain=$(jq -r '.allow[]? | select(type=="string" and test("^[a-zA-Z]"))' "$np" | head -n1)
        if [[ -n "$test_domain" ]]; then
            break
        fi
    done

    mapfile -t upstreams < <(printf '%s\n' "${upstreams[@]}" | sort -u)

    {
        for k in "${!domain_ports[@]}"; do
            printf 'd\t%s\t%s\t%s\n' "$k" "${domain_ports[$k]}" "${domain_upstream[$k]}"
        done
        for k in "${!cidr_ports[@]}"; do
            printf 'c\t%s\t%s\n' "$k" "${cidr_ports[$k]}"
        done
    } | jq -S -R -s \
        --argjson allow_all "$allow_all" \
        --arg allow_all_ports "$allow_all_ports" \
        --arg test_domain "$test_domain" \
        '(split("\n") | map(select(length > 0) | split("\t"))) as $rows
         | { upstreams: $ARGS.positional,
             domains: ([$rows[] | select(.[0] == "d") | {key: .[1], value: {ports: .[2], upstream: .[3]}}] | from_entries),
             cidrs: ([$rows[] | select(.[0] == "c") | {key: .[1], value: .[2]}] | from_entries),
             allow_all: $allow_all,
             allow_all_ports: $allow_all_ports,
             test_domain: $test_domain }' \
        --args "${upstreams[@]}"
}
