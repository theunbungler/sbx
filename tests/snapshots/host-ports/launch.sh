#!/bin/bash
# Start the sandbox
# The payload namespace B, nested in this one (lib/userns.sh, lib/nestnet.sh).
source @REPO@/lib/userns.sh
source @REPO@/lib/nestnet.sh
nest_fail() {
    echo "Error: $1" >&2
    exit 1
}
trap 'sbx_nestnet_release; sbx_userns_release "$SBX_B_PID"; kill "${DNSMASQ_PID:-}" 2>/dev/null' EXIT
sbx_userns_hold || nest_fail "could not create the payload user namespace."
sbx_userns_map_identity "$SBX_B_PID" || nest_fail "could not map the payload user namespace."
sbx_nestnet_wire "$SBX_B_PID" || nest_fail "could not connect the payload network namespace. Is the veth module available? Run: sbx --doctor"
sbx_nestnet_b_rules "$SBX_B_PID" "" "8080" "5353" || nest_fail "could not load the payload loopback rules."
sbx_nestnet_relays "8080" "5353" || nest_fail "could not start the host-port relays."
# bwrap moves the payload into B through this descriptor (--userns2 below).
exec {SBX_BFD}</proc/$SBX_B_PID/ns/user
ip link set lo up >/dev/null 2>&1

if ! NFT_ERR=$(nft -f "@ROOT@/h/.local/state/sbx/sessions/proj/dns/rules.nft" 2>&1); then
    echo "Error: nftables rules failed to load — aborting." >&2
    echo "  nft: $NFT_ERR" >&2
    exit 1
fi
nsenter --net=/proc/"$SBX_B_PID"/ns/net -- bwrap --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup --new-session --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run --ro-bind /usr /usr --ro-bind /opt /opt --ro-bind /etc /etc --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 --clearenv --setenv HOME @ROOT@/h --setenv USER snapuser --setenv LOGNAME snapuser --setenv TERM xterm --setenv LANG C.UTF-8 --setenv SHELL /bin/bash --cap-drop ALL --cap-add CAP_SETPCAP --die-with-parent --tmpfs /var --dir /var/tmp --dir /run/user/@UID@ --ro-bind /sys /sys --ro-bind @ROOT@/h/.local/state/sbx/sessions/proj/virt/empty /etc/subuid --ro-bind @ROOT@/h/.local/state/sbx/sessions/proj/virt/empty /etc/subgid --setenv XDG_RUNTIME_DIR /run/user/@UID@ --setenv CONTAINERS_STORAGE_CONF @ROOT@/h/.local/state/sbx/sessions/proj/virt/storage.conf --setenv CONTAINERS_CONF @ROOT@/h/.local/state/sbx/sessions/proj/virt/containers.conf --setenv DOCKER_HOST unix:///run/user/@UID@/podman/podman.sock --setenv PATH @ROOT@/h/.local/state/sbx/sessions/proj/bin:/usr/local/bin:/usr/bin:/bin --ro-bind @ROOT@/h/.local/state/sbx/sessions/proj/dns/resolv.conf @RESOLV_DEST@ --tmpfs @ROOT@/h/.local/state/sbx --bind @ROOT@/h/.local/state/sbx/sessions/proj @ROOT@/h/.local/state/sbx/sessions/proj --tmpfs @ROOT@/h/.config/sbx --userns2 "$SBX_BFD" setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all -- @ROOT@/h/.local/state/sbx/sessions/proj/session.sh
