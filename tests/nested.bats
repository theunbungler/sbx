#!/usr/bin/env bats

# The payload runs in a user namespace B nested in the session's control
# namespace A (lib/userns.sh, lib/nestnet.sh). Real sessions: ro mounts and
# the egress firewall hold against a payload that keeps its capabilities,
# and host ports and DNS answer at the addresses they always have.
#
# Payloads are written to a file and run as `/bin/sh /out/t.sh`, so they can
# quote freely.

setup_file() {
    # One image tarball for the podman tests, made from the host's own store
    # before HOME is replaced. Absent image: those tests skip.
    if command -v podman >/dev/null 2>&1 && podman image exists docker.io/library/alpine:latest 2>/dev/null; then
        IMG_DIR="$(mktemp -d /tmp/sbximg.XXXXXX)"
        podman save -q -o "$IMG_DIR/alpine.tar" docker.io/library/alpine:latest && export IMG_DIR
    fi
}

teardown_file() {
    if [[ -n "${IMG_DIR:-}" && "$IMG_DIR" == /tmp/sbximg.* ]]; then
        rm -rf "$IMG_DIR"
    fi
}

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/p"
    HOSTDIR="$ROOT/o"
    RODIR="$ROOT/r"
    P="$HOME/.config/sbx/profiles"
    mkdir -p "$PROJ" "$HOSTDIR" "$RODIR" "$P/fs" "$P/net"
    echo readonly > "$RODIR/f.txt"
    # Host-owned profiles: caps and host_ports are refused from ./.sbx.
    cat > "$P/fs/keep.json" <<EOF
{"description":"test","caps":"keep","mounts":[
  {"source":"$HOSTDIR","dest":"/out","perm":"rw"},
  {"source":"$RODIR","dest":"/ro","perm":"ro"}]}
EOF
    cat > "$P/fs/drop.json" <<EOF
{"description":"test","mounts":[
  {"source":"$HOSTDIR","dest":"/out","perm":"rw"},
  {"source":"$RODIR","dest":"/ro","perm":"ro"}]}
EOF
    cat > "$P/net/nothing.json" <<'EOF'
{"description":"test: networking with nothing allowed","dns":"1.1.1.1","allow":[],"ports":[443]}
EOF
}

teardown() {
    local pid
    for pid in ${HOST_PIDS:-}; do
        kill "$pid" 2>/dev/null
    done
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]]; then
        # podman-full leaves files owned by subordinate uids behind.
        rm -rf "$ROOT" 2>/dev/null || unshare --map-auto --map-root-user -- rm -rf "$ROOT"
    fi
}

payload() {   # <sbx args as one string>; the payload script is read from stdin
    cat > "$HOSTDIR/t.sh"
    ( cd "$PROJ" && script -qec "$SBX $1 -- /bin/sh /out/t.sh" /dev/null >/dev/null 2>&1 )
}

requires_pasta() {
    command -v pasta >/dev/null 2>&1 || skip "pasta not installed"
}

requires_net() {
    requires_pasta
    ip route show default | grep -q . || skip "no default route"
}

requires_denied_target() {   # a destination the host reaches and no test profile allows
    curl -s -o /dev/null -m 5 http://1.1.1.1/ || skip "host cannot reach 1.1.1.1:80"
}

allowed_ip_profile() {   # net/allowip: example.com's address on 443, as a CIDR and a name
    ALLOWED_IP=$(getent ahostsv4 example.com | awk 'NR == 1 { print $1 }')
    [[ -n "$ALLOWED_IP" ]] || skip "cannot resolve example.com on the host"
    curl -sk -o /dev/null -m 5 --resolve "example.com:443:$ALLOWED_IP" https://example.com/ \
        || skip "host cannot reach example.com:443"
    cat > "$P/net/allowip.json" <<EOF
{"description":"test","dns":"1.1.1.1","allow":["$ALLOWED_IP/32","example.com"],"ports":[443]}
EOF
}

free_port() {
    local p
    while :; do
        p=$(( 20000 + RANDOM % 10000 ))
        [[ -z "$(ss -Htaun "sport = :$p")" ]] && { echo "$p"; return; }
    done
}

start_host_tcp() {   # sets TCP_PORT: a host service on 127.0.0.1 answering "host-tcp"
    TCP_PORT=$(free_port)
    socat "TCP-LISTEN:$TCP_PORT,bind=127.0.0.1,fork,reuseaddr" SYSTEM:'echo host-tcp' &
    HOST_PIDS="${HOST_PIDS:-} $!"
    sleep 0.3
}

start_host_udp() {   # sets UDP_PORT: a host service on 127.0.0.1 answering "host-udp"
    UDP_PORT=$(free_port)
    socat "UDP-RECVFROM:$UDP_PORT,bind=127.0.0.1,fork" SYSTEM:'echo host-udp' &
    HOST_PIDS="${HOST_PIDS:-} $!"
    sleep 0.3
}

requires_podman_image() {
    [[ -n "${IMG_DIR:-}" ]] || skip "podman or the alpine image is not available on the host"
    cat > "$P/fs/img.json" <<EOF
{"description":"test","mounts":[{"source":"$IMG_DIR","dest":"/img","perm":"ro"}]}
EOF
}

# CANARY. Every test below asserts something is denied; all of them pass
# vacuously if a caps: keep session fails to launch.
@test "a caps keep session runs" {
    payload "--fs keep" <<'EOF'
echo ran > /out/ran.txt
EOF
    [ "$(cat "$HOSTDIR/ran.txt")" = "ran" ]
}

@test "caps keep: the payload still holds capabilities" {
    payload "--fs keep" <<'EOF'
grep '^CapEff' /proc/self/status > /out/caps.txt
EOF
    [ -s "$HOSTDIR/caps.txt" ]
    [[ "$(cat "$HOSTDIR/caps.txt")" != *"0000000000000000" ]]
}

# These three (no --net) pass whether or not the payload runs nested in B:
# without networking, bwrap already creates its own user namespace here, so
# its ro binds are already MNT_LOCKED against this same process either way.
# They are not evidence the payload runs in B — the podman-nonet snapshot
# golden is what pins that shape. The networked variants below are the ones
# this task exists to fix (bwrap joins pasta's user namespace there, so
# without nesting its ro binds are not locked against the payload).
@test "caps keep: a ro mount cannot be remounted writable" {
    payload "--fs keep" <<'EOF'
if mount -o remount,bind,rw /ro 2>/dev/null; then echo BAD; else echo GOOD; fi > /out/r.txt
EOF
    [ "$(cat "$HOSTDIR/r.txt")" = "GOOD" ]
}

@test "caps keep: a ro mount cannot be unmounted" {
    payload "--fs keep" <<'EOF'
if umount /ro 2>/dev/null; then echo BAD; else echo GOOD; fi > /out/u.txt
EOF
    [ "$(cat "$HOSTDIR/u.txt")" = "GOOD" ]
}

@test "caps keep: a ro mount's host file survives an attack" {
    payload "--fs keep" <<'EOF'
mount -o remount,bind,rw /ro 2>/dev/null
umount /ro 2>/dev/null
echo pwned > /ro/f.txt 2>/dev/null
true
EOF
    [ "$(cat "$RODIR/f.txt")" = "readonly" ]
}

@test "caps keep with networking: a ro mount cannot be remounted writable" {
    requires_net
    payload "--fs keep --net nothing" <<'EOF'
if mount -o remount,bind,rw /ro 2>/dev/null; then echo BAD; else echo GOOD; fi > /out/r.txt
EOF
    [ "$(cat "$HOSTDIR/r.txt")" = "GOOD" ]
}

@test "caps keep with networking: a ro mount cannot be unmounted" {
    requires_net
    payload "--fs keep --net nothing" <<'EOF'
if umount /ro 2>/dev/null; then echo BAD; else echo GOOD; fi > /out/u.txt
EOF
    [ "$(cat "$HOSTDIR/u.txt")" = "GOOD" ]
}

@test "caps keep with networking: a ro mount's host file survives an attack" {
    requires_net
    payload "--fs keep --net nothing" <<'EOF'
mount -o remount,bind,rw /ro 2>/dev/null
umount /ro 2>/dev/null
echo pwned > /ro/f.txt 2>/dev/null
true
EOF
    [ "$(cat "$RODIR/f.txt")" = "readonly" ]
}

@test "caps keep without networking: the payload sees the host uid" {
    payload "--fs keep" <<'EOF'
id -u > /out/id.txt
EOF
    [ "$(cat "$HOSTDIR/id.txt")" = "$(id -u)" ]
}

@test "caps keep with networking: the payload sees uid 0, as before" {
    requires_net
    payload "--fs keep --net nothing" <<'EOF'
id -u > /out/id.txt
EOF
    [ "$(cat "$HOSTDIR/id.txt")" = "0" ]
}

@test "caps keep with networking: egress stays filtered after nft flush ruleset" {
    requires_net
    requires_denied_target
    allowed_ip_profile
    payload "--fs keep --net allowip" <<EOF
nft flush ruleset 2>/dev/null
if curl -s -o /dev/null -m 5 http://1.1.1.1/; then echo BAD; else echo GOOD; fi > /out/denied.txt
curl -sk -o /dev/null -m 5 -w '%{http_code}' --resolve example.com:443:$ALLOWED_IP https://example.com/ > /out/allowed.txt
EOF
    [ "$(cat "$HOSTDIR/denied.txt")" = "GOOD" ]
    [ "$(cat "$HOSTDIR/allowed.txt")" != "000" ]
}

@test "caps keep with networking: DNS answers through resolv.conf" {
    requires_net
    allowed_ip_profile
    payload "--fs keep --net allowip" <<'EOF'
getent ahostsv4 example.com > /out/dns.txt
EOF
    [ -s "$HOSTDIR/dns.txt" ]
}

@test "caps keep: a granted TCP host port answers at 127.0.0.1 and localhost" {
    requires_pasta
    start_host_tcp
    payload "--fs keep --host-port $TCP_PORT" <<EOF
socat -T2 - TCP:127.0.0.1:$TCP_PORT </dev/null > /out/ip.txt
socat -T2 - TCP:localhost:$TCP_PORT </dev/null > /out/name.txt
EOF
    [ "$(cat "$HOSTDIR/ip.txt")" = "host-tcp" ]
    [ "$(cat "$HOSTDIR/name.txt")" = "host-tcp" ]
}

@test "caps keep: a granted UDP host port answers at 127.0.0.1" {
    requires_pasta
    start_host_udp
    payload "--fs keep --host-port $UDP_PORT/udp" <<EOF
echo q | socat -T2 - UDP:127.0.0.1:$UDP_PORT > /out/udp.txt
EOF
    # This host's socat ",fork" UDP responder answers a single client
    # datagram twice (confirmed with no sandbox at all, via strace on the
    # client showing exactly one sendto and SOCAT_PEERPORT logging on the
    # responder showing two hits from that same port); check only that the
    # relay actually delivered the answer, not how many times it arrived.
    [ "$(head -1 "$HOSTDIR/udp.txt")" = "host-udp" ]
}

@test "caps keep: a host port that was not granted stays unreachable, even through the payload's own DNAT" {
    requires_pasta
    start_host_tcp
    local granted=$TCP_PORT
    start_host_tcp
    local other=$TCP_PORT
    payload "--fs keep --host-port $granted" <<EOF
socat -T2 - TCP:127.0.0.1:$other </dev/null > /out/direct.txt 2>/dev/null
nft add table ip attack
nft add chain ip attack out '{ type nat hook output priority -150; }'
nft add rule ip attack out ip daddr 127.0.0.1 tcp dport $other dnat to 10.200.0.1
socat -T2 - TCP:127.0.0.1:$other </dev/null > /out/dnat.txt 2>/dev/null
true
EOF
    [ ! -s "$HOSTDIR/direct.txt" ]
    [ ! -s "$HOSTDIR/dnat.txt" ]
}

@test "fs/podman runs a container on overlay storage" {
    requires_podman_image
    payload "--fs podman --fs img --fs keep" <<'EOF'
podman load -q -i /img/alpine.tar >/dev/null 2>&1
podman info --format '{{.Store.GraphDriverName}}' > /out/driver.txt 2>&1
podman run --rm --network=none docker.io/library/alpine:latest echo hi > /out/run.txt 2>&1
EOF
    [ "$(tail -1 "$HOSTDIR/driver.txt")" = "overlay" ]
    [ "$(tail -1 "$HOSTDIR/run.txt")" = "hi" ]
}

@test "fs/podman-full keeps multi-uid fidelity and container DNS on an explicit network" {
    requires_net
    requires_podman_image
    # DNS runs on an explicitly created network, not the containers.conf
    # default_network ("sbx0"): podman 6.x disables aardvark DNS on
    # whatever network is named as default_network, regardless of how
    # that network was created. That is a pre-existing sbx issue
    # (containers.conf's default_network choice), unrelated to nesting,
    # and out of scope here — this test instead proves what the nested
    # architecture itself claims: aardvark DNS resolves between
    # containers in B on an ordinary user-created network.
    payload "--fs podman-full --fs img --fs keep --net nothing" <<'EOF'
podman load -q -i /img/alpine.tar >/dev/null 2>&1
podman run --rm --network=none --user 1000:1000 docker.io/library/alpine:latest id -u > /out/uid.txt 2>&1
podman network create sbxdnstest >/dev/null 2>&1
podman run -d --name pg --network sbxdnstest docker.io/library/alpine:latest sleep 60 >/dev/null 2>&1
podman run --rm --network sbxdnstest docker.io/library/alpine:latest nslookup pg > /out/dns.txt 2>&1
podman rm -f pg >/dev/null 2>&1
EOF
    [ "$(tail -1 "$HOSTDIR/uid.txt")" = "1000" ]
    grep -q '^Name:' "$HOSTDIR/dns.txt"
}
