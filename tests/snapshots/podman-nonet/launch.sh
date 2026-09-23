#!/bin/bash
# Start the sandbox
# The payload namespace B, nested in this one (lib/userns.sh, lib/nestnet.sh).
source @REPO@/lib/userns.sh
source @REPO@/lib/nestnet.sh
nest_fail() {
    echo "Error: $1" >&2
    exit 1
}
trap 'sbx_nestnet_release; sbx_userns_release "$SBX_B_PID"; [[ -n "${DNSMASQ_PID:-}" ]] && kill "$DNSMASQ_PID" 2>/dev/null' EXIT
sbx_userns_hold || nest_fail "could not create the payload user namespace."
sbx_userns_map_outer_ids "$SBX_B_PID" || nest_fail "could not map the payload user namespace."
sbx_nestnet_lo_up "$SBX_B_PID" || nest_fail "could not bring up the payload loopback."
# bwrap moves the payload into B through this descriptor (--userns2 below).
# Guarded: a failed exec here is only redirections, so it would otherwise
# print an error, leave SBX_BFD unset, and let control reach bwrap with
# --userns2 "" — bwrap would still refuse it, but by its own argument
# parser rather than this script's contract.
exec {SBX_BFD}</proc/$SBX_B_PID/ns/user || nest_fail "could not open the payload user namespace."
nsenter --net=/proc/"$SBX_B_PID"/ns/net -- bwrap --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup --new-session --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run --ro-bind /usr /usr --ro-bind /opt /opt --ro-bind /etc /etc --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 --clearenv --setenv HOME @ROOT@/h --setenv USER snapuser --setenv LOGNAME snapuser --setenv TERM xterm --setenv LANG C.UTF-8 --setenv SHELL /bin/bash --cap-add ALL --die-with-parent --tmpfs /var --dir /var/tmp --dir /run/user/@UID@ --ro-bind /sys /sys --ro-bind @ROOT@/h/.local/state/sbx/sessions/proj/virt/empty /etc/subuid --ro-bind @ROOT@/h/.local/state/sbx/sessions/proj/virt/empty /etc/subgid --setenv XDG_RUNTIME_DIR /run/user/@UID@ --setenv CONTAINERS_STORAGE_CONF @ROOT@/h/.local/state/sbx/sessions/proj/virt/storage.conf --setenv CONTAINERS_CONF @ROOT@/h/.local/state/sbx/sessions/proj/virt/containers.conf --setenv DOCKER_HOST unix:///run/user/@UID@/podman/podman.sock --dir /dev --dir /dev/net --dev-bind-try /dev/net/tun /dev/net/tun --dir /tmp --dir @ROOT@ --dir @ROOT@/h --dir @ROOT@/h/.local --dir @ROOT@/h/.local/state --dir @ROOT@/h/.local/state/sbx --dir @ROOT@/h/.local/state/sbx/virt --bind-try @ROOT@/h/.local/state/sbx/virt/containers @ROOT@/h/.local/state/sbx/virt/containers --setenv PATH @ROOT@/h/.local/state/sbx/sessions/proj/bin:/usr/local/bin:/usr/bin:/bin --tmpfs @ROOT@/h/.local/state/sbx --bind @ROOT@/h/.local/state/sbx/sessions/proj @ROOT@/h/.local/state/sbx/sessions/proj --tmpfs @ROOT@/h/.config/sbx --userns2 "$SBX_BFD" unshare --mount -- @ROOT@/h/.local/state/sbx/sessions/proj/session.sh
