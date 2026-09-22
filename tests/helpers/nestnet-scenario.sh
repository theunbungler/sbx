#!/bin/bash
# Test harness for lib/nestnet.sh. Runs inside a control namespace A made by
# `unshare --user --map-root-user --net`, sets up B the way launch.sh does,
# then sources the probe file given as $2. Probes print key=value lines.
#
# Granted host ports: tcp 18081, udp 18083. Not granted: tcp 18082.
# Stand-ins bind to the lo device (so-bindtodevice=lo), exactly as pasta's
# splice listeners do: that is what makes a DNAT onto A's loopback useless
# and the relay necessary.
LIBDIR="$1"
PROBE="$2"
source "$LIBDIR/userns.sh"
source "$LIBDIR/nestnet.sh"

cleanup() {
    kill $(jobs -p) 2>/dev/null
    sbx_nestnet_release
    sbx_userns_release "${SBX_B_PID:-}"
}
trap cleanup EXIT

ip link set lo up
sbx_userns_hold || { echo "setup=hold-failed"; exit 1; }
sbx_userns_map_identity "$SBX_B_PID" || { echo "setup=map-failed"; exit 1; }
sbx_nestnet_wire "$SBX_B_PID" || { echo "setup=wire-failed"; exit 1; }
{
    echo "table inet sbx_filter {"
    sbx_nestnet_a_rules true 18081 18083
    echo "}"
} | nft -f - || { echo "setup=a-rules-failed"; exit 1; }

socat TCP-LISTEN:18081,bind=127.0.0.1,so-bindtodevice=lo,fork,reuseaddr SYSTEM:'echo granted' &
socat TCP-LISTEN:18082,bind=127.0.0.1,so-bindtodevice=lo,fork,reuseaddr SYSTEM:'echo not-granted' &
socat UDP-RECVFROM:18083,bind=127.0.0.1,so-bindtodevice=lo,fork SYSTEM:'echo udp-granted' &
socat UDP-RECVFROM:53,bind="$SBX_NEST_A_ADDR",fork SYSTEM:'echo resolver' &
sleep 0.3

sbx_nestnet_relays 18081 18083 || { echo "setup=relays-failed"; exit 1; }
sbx_nestnet_b_rules "$SBX_B_PID" 127.0.0.2 18081 18083 || { echo "setup=b-rules-failed"; exit 1; }

# Run a command as root in B, holding B's full capability set: the
# strongest payload a session can have.
inb() {
    nsenter -t "$SBX_B_PID" -U -n --preserve-credentials -- "$@"
}
tcp_get() {   # <addr> <port>
    inb socat -T2 - "TCP:$1:$2" </dev/null 2>/dev/null
}
udp_get() {   # <addr> <port>
    echo q | inb socat -T2 - "UDP:$1:$2" 2>/dev/null
}
a_drops() {   # packets A's input chain has dropped from sbx-a
    nft list chain inet sbx_filter input | awk '/drop/ { for (i = 1; i <= NF; i++) if ($i == "packets") print $(i + 1) }'
}

echo "setup=ok"
source "$PROBE"
