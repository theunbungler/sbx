#!/bin/bash
# Starts a session. Runs in the control namespace A — pasta's user and
# network namespaces, or unshare's for a session without networking — and
# outlives bwrap, so its EXIT trap can release B, the relays and dnsmasq.
#
# Usage: launch.sh <session dir>/launch.env
#
# The same for every session: sbx writes what differs into launch.env
# (variables, see write_launch_env in sbx) and bwrap.args (NUL-separated)
# beside it. Order matters: B and A's veth address exist before dnsmasq
# binds that address, the ruleset is loaded before bwrap starts, and a
# failure anywhere stops the launch before the payload runs.

env_file="$1"
session_dir="${env_file%/*}"
lib="${BASH_SOURCE[0]%/*}"
# shellcheck source=/dev/null
source "$env_file"
# shellcheck source=lib/userns.sh
source "$lib/userns.sh"
# shellcheck source=lib/nestnet.sh
source "$lib/nestnet.sh"

fail() {
    echo "Error: $1" >&2
    exit 1
}

# Every teardown path meets here. Does not reach a SIGKILLed launch.sh —
# dnsmasq has no --pdeathsig, unlike B's holder and the relays.
trap 'sbx_nestnet_release; sbx_userns_release "${SBX_B_PID:-}"; [[ -n "${DNSMASQ_PID:-}" ]] && kill "$DNSMASQ_PID" 2>/dev/null' EXIT

# --- The payload namespace B (lib/userns.sh, lib/nestnet.sh) ---
sbx_userns_hold || fail "could not create the payload user namespace."
# IDENTITY (the plan's security.identity): "user" maps the host uid onto
# A's 0, so the payload is the user; "root" mirrors A's map, so it is A's 0.
if [[ "$IDENTITY" == "root" ]]; then
    sbx_userns_map_identity "$SBX_B_PID" || fail "could not map the payload user namespace."
else
    sbx_userns_map_outer_ids "$SBX_B_PID" || fail "could not map the payload user namespace."
fi
if [[ "$NET_MODE" == "none" ]]; then
    sbx_nestnet_lo_up "$SBX_B_PID" || fail "could not bring up the payload loopback."
else
    nest_dns=""
    if [[ "$NET_MODE" == "dns" ]]; then
        nest_dns="$SBX_DNS_ADDR"
    fi
    sbx_nestnet_wire "$SBX_B_PID" || fail "could not connect the payload network namespace. Is the veth module available? Run: sbx --doctor"
    sbx_nestnet_b_rules "$SBX_B_PID" "$nest_dns" "$NEST_TCP" "$NEST_UDP" || fail "could not load the payload loopback rules."
    sbx_nestnet_relays "$NEST_TCP" "$NEST_UDP" || fail "could not start the host-port relays."
fi

# bwrap moves the payload into B through this descriptor (--userns2). It is
# not close-on-exec, so the payload inherits it; that is harmless, since
# setns() back into B needs CAP_SYS_ADMIN in B, and B's capability sets are
# empty by the time session.sh runs.
exec {SBX_BFD}</proc/"$SBX_B_PID"/ns/user || fail "could not open the payload user namespace."

# --- Egress: A's ruleset, and the resolver that fills its sets ---
if [[ "$NET_MODE" != "none" ]]; then
    ip link set lo up >/dev/null 2>&1
    # A session must never come up with the egress table missing.
    if ! nft_err=$(nft -f "$session_dir/dns/rules.nft" 2>&1); then
        echo "Error: nftables rules failed to load — aborting." >&2
        echo "  nft: $nft_err" >&2
        exit 1
    fi
fi

if [[ "$NET_MODE" == "dns" ]]; then
    # Flags only, no config file: AppArmor's usr.sbin.dnsmasq profile limits
    # config paths to /etc/dnsmasq.d/*. --filter-AAAA: IPv6 is dropped anyway.
    # --nftset in DNSMASQ_ARGS adds each A answer to its domain's set.
    "$DNSMASQ_BIN" \
        --conf-file=/dev/null \
        -d \
        --port=53 \
        --listen-address="$SBX_DNS_ADDR" --listen-address="$SBX_NEST_A_ADDR" \
        --bind-interfaces \
        --no-resolv \
        --no-hosts \
        --filter-AAAA \
        "${DNSMASQ_ARGS[@]}" \
        > "$session_dir/dns/dnsmasq.log" 2>&1 &
    DNSMASQ_PID=$!

    # This script sees the host's /etc/resolv.conf, so the readiness probe
    # binds the session's own into a throwaway bwrap.
    probe_dns() {
        bwrap --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
            --symlink usr/lib64 /lib64 --ro-bind /etc /etc \
            --ro-bind "$session_dir/dns/resolv.conf" "$RESOLV_DEST" \
            --proc /proc --dev /dev \
            -- getent ahostsv4 "$TEST_DOMAIN" >/dev/null 2>&1
    }

    dns_ready=false
    for _ in {1..20}; do
        if ! kill -0 "$DNSMASQ_PID" 2>/dev/null; then
            echo "Error: dnsmasq failed to start:" >&2
            cat "$session_dir/dns/dnsmasq.log" >&2
            exit 1
        fi
        if [[ -z "$TEST_DOMAIN" ]] || probe_dns; then
            dns_ready=true
            break
        fi
        sleep 0.5
    done
    if [[ "$dns_ready" != "true" ]]; then
        echo "Error: dnsmasq did not become ready (could not resolve '$TEST_DOMAIN')." >&2
        cat "$session_dir/dns/dnsmasq.log" >&2
        exit 1
    fi
fi

# --- The sandbox ---
# bwrap starts in B's network namespace but A's user namespace, so every
# mount it makes belongs to A and is locked in B; --userns2 then moves the
# payload into B. (The man page pairs --userns2 with --userns; that form
# fails here.)
#
# bwrap's direct child empties every capability set and execs session.sh
# as PID 1, so the tmux server, the payload, every join and every pane is
# capless by construction. It spends the CAP_SETPCAP bwrap was told to
# keep; if setpriv fails, nothing runs. "caps": "keep" sessions are not
# dropped — that is the opt-out — and get a mount namespace B owns, so
# podman can mount.
if [[ "$CAPS_KEEP" == "true" ]]; then
    enter=(unshare --mount --)
else
    enter=(setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all --)
fi
mapfile -d '' -t bwrap_args < "$session_dir/bwrap.args"

# --seccomp: bwrap loads the filter just before it execs its command, so
# it covers the capability drop above session.sh too. A filter that makes
# that drop fail stops the launch; one that fakes its success is caught by
# session.sh, which refuses to start with a non-empty bounding set.
seccomp=()
if [[ -n "${SECCOMP_COPY:-}" ]]; then
    exec {SBX_SFD}<"$SECCOMP_COPY" || fail "could not open the seccomp filter $SECCOMP_COPY."
    seccomp=(--seccomp "$SBX_SFD")
fi
nsenter --net=/proc/"$SBX_B_PID"/ns/net -- \
    bwrap "${bwrap_args[@]}" "${seccomp[@]}" --userns2 "$SBX_BFD" "${enter[@]}" "$session_dir/session.sh"
