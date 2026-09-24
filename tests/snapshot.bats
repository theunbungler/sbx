#!/usr/bin/env bats

# Golden-file snapshots of everything a launch generates: bwrap's argument
# list, launch.sh, session.sh, the nft ruleset, podman confs and the join
# sidecar. They pin the launch exactly, so that moving profile reading into
# lib/resolve.sh can be shown to change nothing. Nothing is sandboxed:
# bwrap, pasta, unshare and ip are stubs that copy the generated files out
# and exit.
#
# After an intentional change to what a launch generates, regenerate with:
#   SBX_UPDATE_SNAPSHOTS=1 bats tests/snapshot.bats
# and review the diff of tests/snapshots/ like any other code change.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SBX="$REPO/sbx"
    SNAP_DIR="$BATS_TEST_DIRNAME/snapshots"
    # Short, like every suite that launches sbx: the session socket path
    # must stay under the Unix limit.
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    HOME_DIR="$ROOT/h"
    PROJ="$ROOT/proj"
    STUB="$ROOT/stub"
    CAP="$ROOT/cap"
    HOSTSRC="$ROOT/src"
    mkdir -p "$HOME_DIR/.config/sbx/profiles/fs" "$HOME_DIR/.config/sbx/profiles/cli" \
             "$HOME_DIR/.config/sbx/profiles/net" "$PROJ" "$STUB" "$CAP" "$HOSTSRC"
    write_stubs
    write_fixture_profiles
}

teardown() {
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]]; then
        rm -rf "$ROOT"
    fi
}

write_stubs() {
    # Copies one session's generated files into $SBX_CAPTURE.
    cat > "$STUB/sbx-capture" <<'EOF'
#!/bin/bash
sdir="$1"
name=$(basename "$sdir")
mkdir -p "$SBX_CAPTURE"
for f in launch.sh session.sh wrapper.sh tmux.conf session.json \
         dns/rules.nft dns/resolv.conf virt/storage.conf virt/containers.conf \
         virt/containers-bootstrap.conf; do
    if [[ -f "$sdir/$f" ]]; then
        cp "$sdir/$f" "$SBX_CAPTURE/${f//\//_}"
    fi
done
join="$(dirname "$(dirname "$sdir")")/join/$name.json"
if [[ -f "$join" ]]; then
    cp "$join" "$SBX_CAPTURE/join.json"
fi
exit 0
EOF
    cat > "$STUB/bwrap" <<'EOF'
#!/bin/bash
# The dependency preflight's user-namespace probe must pass.
if [[ "$*" == "--unshare-user --ro-bind / / true" ]]; then
    exit 0
fi
# So must the capability probe, which is the one bwrap invocation whose last
# argument is /bin/true (a real launch ends with session.sh).
if [[ "${*: -1}" == "/bin/true" ]]; then
    exit 0
fi
mkdir -p "$SBX_CAPTURE"
printf '%s\n' "$@" > "$SBX_CAPTURE/bwrap.args"
# bwrap's last argument is session.sh, inside the session directory.
exec "$(dirname "$0")/sbx-capture" "$(dirname "${@: -1}")"
EOF
    cat > "$STUB/pasta" <<'EOF'
#!/bin/bash
mkdir -p "$SBX_CAPTURE"
printf '%s\n' "$@" > "$SBX_CAPTURE/pasta.args"
# pasta's last argument is launch.sh, inside the session directory.
exec "$(dirname "$0")/sbx-capture" "$(dirname "${@: -1}")"
EOF
    cat > "$STUB/unshare" <<'EOF'
#!/bin/bash
# The preflight probe for "can unshare make a user + network namespace".
if [[ "$*" == "--user --map-root-user --net /bin/true" ]]; then
    exit 0
fi
args=("$@")
while [[ $# -gt 0 && "$1" != "--" ]]; do
    shift
done
shift
if [[ "$1" == */launch.sh ]]; then
    mkdir -p "$SBX_CAPTURE"
    printf '%s\n' "${args[@]}" > "$SBX_CAPTURE/unshare.args"
    exec "$(dirname "$0")/sbx-capture" "$(dirname "$1")"
fi
exec "$@"
EOF
    cat > "$STUB/ip" <<'EOF'
#!/bin/bash
case "$*" in
    "route show default") echo "default via 10.99.0.1 dev snap0 proto static" ;;
    "addr show snap0")    echo "    inet 10.99.0.2/24 brd 10.99.0.255 scope global snap0" ;;
esac
exit 0
EOF
    printf '#!/bin/bash\nexit 0\n' > "$STUB/socat"
    mkdir -p "$ROOT/sysmod/veth"
    chmod +x "$STUB"/*
}

write_fixture_profiles() {
    local P="$HOME_DIR/.config/sbx/profiles"
    mkdir -p "$HOSTSRC/rodir" "$HOSTSRC/rwdir" "$HOSTSRC/state" "$HOSTSRC/tree"
    echo ro > "$HOSTSRC/rodir/f"
    echo state > "$HOSTSRC/state/s"
    echo '{"k":1}' > "$HOSTSRC/state.json"
    echo t > "$HOSTSRC/tree/t"

    cat > "$P/fs/snapmounts.json" <<EOF
{"description":"snapshot mounts",
 "mounts":[
  {"source":"$HOSTSRC/rodir","dest":"/snap/ro","perm":"ro"},
  {"source":"$HOSTSRC/rwdir","dest":"/snap/deep/rw","perm":"rw"},
  {"source":"$HOSTSRC/newrw","dest":"/snap/newrw","perm":"rw"},
  {"source":"/dev/null","dest":"/snap/devnull","perm":"dev"},
  {"source":"$HOSTSRC/absent","dest":"/snap/absent","perm":"ro"},
  {"source":"$HOSTSRC/state","dest":"/snap/state","perm":"forked"},
  {"source":"$HOSTSRC/state.json","dest":"/snap/state.json","perm":"forked"},
  {"source":"$HOSTSRC/tree","dest":"/snap/tree","perm":"record"}
 ],
 "env":{"SNAP_FS":"fs-value","SNAP_SHARED":"from-fs","PATH":"/opt/snap/bin:/usr/bin"},
 "passthrough":["SBX_SNAP_TOKEN"]}
EOF
    cat > "$P/cli/snapcli.json" <<'EOF'
{"description":"snapshot cli",
 "env":{"SNAP_SHARED":"from-cli","SNAP_HOME":"$HOME/x","SNAP_NUM":7},
 "path":["$HOME/.snap/bin","/opt/tool/bin"],
 "mounts":[{"source":"$HOME/cli-ro","dest":"/cli/ro","perm":"ro"}]}
EOF
    cat > "$P/net/snapdb.json" <<'EOF'
{"description":"snapshot db","dns":"9.9.9.9",
 "allow":["db.internal.example","github.com","10.0.0.0/8"],
 "ports":[5432],"host_ports":[5433,"5353/udp"]}
EOF
    cat > "$P/net/snapwild.json" <<'EOF'
{"description":"snapshot wildcard","allow":["*"],"ports":["*"]}
EOF
    printf '%s:100000:65536\n' "$(id -un)" > "$ROOT/subuid"
    cp "$ROOT/subuid" "$ROOT/subgid"
}

# Host-specific values are replaced by placeholders so the goldens are
# portable: the temp root, the repo checkout, the uid/gid, the dnsmasq
# binary's location, the host's resolv.conf bind target and the pid.
normalize() {   # <capture dir>
    local dir="$1" f uid gid dnsmasq resolv_dest root_slug
    uid=$(id -u)
    gid=$(id -g)
    dnsmasq=$(command -v dnsmasq || echo /nonexistent)
    resolv_dest=/etc/resolv.conf
    if [[ -L /etc/resolv.conf ]]; then
        resolv_dest=$(readlink -f /etc/resolv.conf)
    fi
    # sbx_copy_path_slug() (lib/copy-mounts.sh) turns a forked/record mount's
    # $PWD into a store directory name by replacing "/" with "-", so the temp
    # root also survives inside forked-store and change-archive paths in that
    # mangled form; strip it too.
    root_slug=$(printf '%s' "$ROOT" | tr '/' '-')
    for f in "$dir"/*; do
        sed -i -E \
            -e "s#$ROOT#@ROOT@#g" \
            -e "s#$root_slug#@ROOT_SLUG@#g" \
            -e "s#$REPO#@REPO@#g" \
            -e "s#$dnsmasq#@DNSMASQ@#g" \
            -e "s#(dns/resolv\\.conf\"?) (\"?)$resolv_dest(\"?)#\\1 \\2@RESOLV_DEST@\\3#g" \
            -e "s#/run/user/$uid#/run/user/@UID@#g" \
            -e "s#(_CONTAINERS_ROOTLESS_UID )$uid#\\1@UID@#g" \
            -e "s#(_CONTAINERS_ROOTLESS_GID )$gid#\\1@GID@#g" \
            -e 's#("pid": )[0-9]+#\1@PID@#' \
            "$f"
    done
    # bwrap.args holds one argument per line, so ids and the resolv.conf
    # target sit on the line after their key.
    if [[ -f "$dir/bwrap.args" ]]; then
        awk -v u="$uid" -v g="$gid" -v r="$resolv_dest" '
            prev == "_CONTAINERS_ROOTLESS_UID" && $0 == u { out = "@UID@" }
            prev == "_CONTAINERS_ROOTLESS_GID" && $0 == g { out = "@GID@" }
            prev ~ /dns\/resolv\.conf$/ && $0 == r        { out = "@RESOLV_DEST@" }
            { if (out == "") out = $0; print out; prev = $0; out = "" }
        ' "$dir/bwrap.args" > "$dir/bwrap.args.tmp"
        mv "$dir/bwrap.args.tmp" "$dir/bwrap.args"
    fi
}

run_case() {   # <case name> <sbx args...>
    local name="$1"; shift
    local cmd
    cmd="$(printf '%q ' "$SBX" "$@")-- /bin/true"
    ( cd "$PROJ" && env -i \
        PATH="$STUB:/usr/local/bin:/usr/bin:/bin" \
        HOME="$HOME_DIR" USER=snapuser LOGNAME=snapuser SHELL=/bin/bash \
        TERM=xterm LANG=C.UTF-8 \
        SBX_CAPTURE="$CAP/$name" \
        SBX_SUBUID="$ROOT/subuid" SBX_SUBGID="$ROOT/subgid" \
        SBX_SYS_MODULE_DIR="$ROOT/sysmod" \
        SBX_SNAP_TOKEN=snaptoken \
        script -qec "$cmd" /dev/null < /dev/null > "$ROOT/$name.out" 2>&1 ) || true
    if [[ -d "$CAP/$name" ]]; then
        normalize "$CAP/$name"
    fi
}

check_snapshot() {   # <case name>
    local name="$1"
    local want="$SNAP_DIR/$name" got="$CAP/$name"
    if [[ ! -d "$got" || -z "$(ls -A "$got")" ]]; then
        echo "nothing captured for $name; sbx said:" >&2
        cat "$ROOT/$name.out" >&2
        return 1
    fi
    if [[ "${SBX_UPDATE_SNAPSHOTS:-}" == "1" ]]; then
        rm -rf "$want"
        mkdir -p "$want"
        cp "$got"/* "$want"/
        return 0
    fi
    diff -ru "$want" "$got"
}

@test "snapshot: plain fs profile, no network" {
    run_case plain --fs sandbox
    check_snapshot plain
}

@test "snapshot: every mount kind, env layering, passthrough, cli path, --wd" {
    mkdir -p "$HOME_DIR/cli-ro"
    run_case mounts --fs snapmounts --cli snapcli --wd /snap/ro
    check_snapshot mounts
}

@test "snapshot: stacked net profiles with a wildcard and profile host ports" {
    run_case stacked-net --net web --net snapdb --net snapwild
    check_snapshot stacked-net
}

@test "snapshot: host ports without a net profile" {
    run_case host-ports --host-port 8080 --host-port 5353/udp
    check_snapshot host-ports
}

@test "snapshot: caps keep and docker api" {
    run_case podman --fs podman --net web
    check_snapshot podman
}

@test "snapshot: userns full" {
    run_case userns-full --fs podman-full --net web
    check_snapshot userns-full
}

@test "snapshot: caps keep without networking" {
    run_case podman-nonet --fs podman
    check_snapshot podman-nonet
}

@test "snapshot capture is deterministic across launches" {
    mkdir -p "$HOME_DIR/cli-ro"
    run_case again-a --fs snapmounts --cli snapcli --net web --net snapdb
    run_case again-b --fs snapmounts --cli snapcli --net web --net snapdb
    if [[ ! -d "$CAP/again-a" ]]; then
        cat "$ROOT/again-a.out" >&2
        return 1
    fi
    diff -ru "$CAP/again-a" "$CAP/again-b"
}
