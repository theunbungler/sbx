#!/bin/bash
# Start the sandbox
ip link set lo up >/dev/null 2>&1

# Hard-fail if nftables rules cannot be loaded — never proceed with open egress.
if ! NFT_ERR=$(nft -f "@ROOT@/h/.local/state/sbx/sessions/proj/dns/rules.nft" 2>&1); then
    echo "Error: nftables rules failed to load — aborting." >&2
    echo "  nft: $NFT_ERR" >&2
    exit 1
fi

# dnsmasq on 127.0.0.2:53 (see SBX_DNS_ADDR above).
# All options are CLI flags: AppArmor's usr.sbin.dnsmasq profile restricts
# config-file paths to /etc/dnsmasq.d/*, making arbitrary paths unreadable.
# --conf-file=/dev/null  suppress any host /etc/dnsmasq.conf
# --filter-AAAA          return only A records; IPv6 egress is nft-dropped anyway
# --nftset               auto-populates @allowed4 from A-record answers —
#                        no bespoke sniffer needed
"@DNSMASQ@" \
    --conf-file=/dev/null \
    -d \
    --port=53 \
    --listen-address=127.0.0.2 \
    --bind-interfaces \
    --no-resolv \
    --no-hosts \
    --filter-AAAA \
    --server=/github.com/1.1.1.1 --nftset=/github.com/inet#sbx_filter#allowed4_1 --server=/google.com/1.1.1.1 --nftset=/google.com/inet#sbx_filter#allowed4_1  \
    > "@ROOT@/h/.local/state/sbx/sessions/proj/dns/dnsmasq.log" 2>&1 &
DNSMASQ_PID=$!

# The probe must query this session's dnsmasq, but launch.sh sees the host
# /etc/resolv.conf. A throwaway bwrap binds the session resolv.conf so the
# check is accurate and every setup failure still prints before the session
# multiplexer starts.
probe_dns() {
    bwrap --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
        --symlink usr/lib64 /lib64 --ro-bind /etc /etc \
        --ro-bind "@ROOT@/h/.local/state/sbx/sessions/proj/dns/resolv.conf" "@RESOLV_DEST@" \
        --proc /proc --dev /dev \
        -- getent ahostsv4 "github.com" >/dev/null 2>&1
}

DNS_READY=false
for i in {1..20}; do
    if ! kill -0 $DNSMASQ_PID 2>/dev/null; then
        echo "Error: dnsmasq failed to start:" >&2
        cat "@ROOT@/h/.local/state/sbx/sessions/proj/dns/dnsmasq.log" >&2
        exit 1
    fi
    if [[ -z "github.com" ]] || probe_dns; then
        DNS_READY=true
        break
    fi
    sleep 0.5
done
if [[ "$DNS_READY" != "true" ]]; then
    echo "Error: dnsmasq did not become ready (could not resolve 'github.com')." >&2
    cat "@ROOT@/h/.local/state/sbx/sessions/proj/dns/dnsmasq.log" >&2
    kill $DNSMASQ_PID 2>/dev/null
    exit 1
fi
bwrap --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup --new-session --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run --ro-bind /usr /usr --ro-bind /opt /opt --ro-bind /etc /etc --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 --clearenv --setenv HOME @ROOT@/h --setenv USER snapuser --setenv LOGNAME snapuser --setenv TERM xterm --setenv LANG C.UTF-8 --setenv SHELL /bin/bash --cap-add ALL --die-with-parent --tmpfs /var --dir /var/tmp --dir /run/user/@UID@ --ro-bind /sys /sys --ro-bind @ROOT@/h/.local/state/sbx/sessions/proj/virt/empty /etc/subuid --ro-bind @ROOT@/h/.local/state/sbx/sessions/proj/virt/empty /etc/subgid --setenv XDG_RUNTIME_DIR /run/user/@UID@ --setenv CONTAINERS_STORAGE_CONF @ROOT@/h/.local/state/sbx/sessions/proj/virt/storage.conf --setenv CONTAINERS_CONF @ROOT@/h/.local/state/sbx/sessions/proj/virt/containers.conf --setenv DOCKER_HOST unix:///run/user/@UID@/podman/podman.sock --dir /dev --dir /dev/net --dev-bind-try /dev/net/tun /dev/net/tun --dir /tmp --dir @ROOT@ --dir @ROOT@/h --dir @ROOT@/h/.local --dir @ROOT@/h/.local/state --dir @ROOT@/h/.local/state/sbx --dir @ROOT@/h/.local/state/sbx/virt --bind-try @ROOT@/h/.local/state/sbx/virt/containers-full @ROOT@/h/.local/state/sbx/virt/containers-full --setenv PATH @ROOT@/h/.local/state/sbx/sessions/proj/bin:/usr/local/bin:/usr/bin:/bin --ro-bind @ROOT@/h/.local/state/sbx/sessions/proj/dns/resolv.conf @RESOLV_DEST@ --tmpfs @ROOT@/h/.local/state/sbx --bind @ROOT@/h/.local/state/sbx/sessions/proj @ROOT@/h/.local/state/sbx/sessions/proj --tmpfs @ROOT@/h/.config/sbx @ROOT@/h/.local/state/sbx/sessions/proj/session.sh
SBX_RC=$?
kill $DNSMASQ_PID 2>/dev/null || true
exit $SBX_RC
