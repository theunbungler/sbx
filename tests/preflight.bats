#!/usr/bin/env bats

# sbx must stop on a missing dependency before it builds anything. These
# tests remove one tool at a time from PATH and check both the message and
# that no session directory was created.

setup_file() {
    # A copy of /usr/bin as symlinks, so a test can delete exactly the tools
    # it wants absent while everything else sbx calls (cat, grep, git...)
    # still resolves. Built once per file; each test copies it.
    BASE_BIN="$BATS_FILE_TMPDIR/bin"
    mkdir -p "$BASE_BIN"
    local f
    for f in /usr/bin/* /usr/local/bin/*; do
        [[ -x "$f" && ! -e "$BASE_BIN/${f##*/}" ]] && ln -s "$f" "$BASE_BIN/${f##*/}"
    done
    export BASE_BIN
}

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    mkdir -p "$HOME" "$ROOT/bin" "$ROOT/p"
    cp -a "$BASE_BIN/." "$ROOT/bin/"
    printf 'ID=manjaro\nID_LIKE=arch\n' > "$ROOT/arch"
    printf 'ID=ubuntu\nID_LIKE=debian\n' > "$ROOT/ubuntu"
}

teardown() {
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]]; then
        rm -rf "$ROOT"
    fi
}

run_sbx() {   # <os-release> <args...>
    local os="$1"; shift
    run env PATH="$ROOT/bin" SBX_OS_RELEASE="$ROOT/$os" \
        bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$ROOT/p" "$SBX" "$@"
}

no_session_built() {
    if compgen -G "$HOME/.local/state/sbx/sessions/*" >/dev/null; then
        echo "a session directory was created" >&2
        return 1
    fi
}

@test "missing pasta with --net stops with the arch command" {
    rm "$ROOT/bin/pasta"
    run_sbx arch --net web -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"sudo pacman -S passt"* ]]
    no_session_built
}

@test "missing pasta with --net stops with the debian command" {
    rm "$ROOT/bin/pasta"
    run_sbx ubuntu --net web -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"sudo apt install passt"* ]]
    no_session_built
}

@test "missing pasta without --net is not reported" {
    rm "$ROOT/bin/pasta" "$ROOT/bin/bwrap"
    run_sbx arch -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"bubblewrap"* ]]
    if [[ "$output" == *passt* ]]; then return 1; fi
    no_session_built
}

@test "--doctor rejects an argument other than --json" {
    run_sbx arch --doctor junk
    [ "$status" -eq 2 ]
    [[ "$output" == *"--doctor takes only --json"* ]]
}

@test "missing pasta with --host-port alone stops with the arch command" {
    rm "$ROOT/bin/pasta"
    run_sbx arch --host-port 8080 -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"sudo pacman -S passt"* ]]
    no_session_built
}

@test "missing xpra with --gui stops before a display is built" {
    rm "$ROOT/bin/xpra"
    run_sbx arch --gui -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"sudo pacman -S xpra"* ]]
    no_session_built
}

@test "a failing userns probe stops the launch with a diagnosis" {
    rm "$ROOT/bin/bwrap"
    printf '#!/bin/sh\necho "bwrap: setting up uid map: Permission denied" >&2\nexit 1\n' > "$ROOT/bin/bwrap"
    chmod +x "$ROOT/bin/bwrap"
    mkdir -p "$ROOT/sys/kernel"
    echo 1 > "$ROOT/sys/kernel/apparmor_restrict_unprivileged_userns"
    run env PATH="$ROOT/bin" SBX_OS_RELEASE="$ROOT/ubuntu" SBX_PROC_SYS="$ROOT/sys" \
        bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$ROOT/p" "$SBX" -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"AppArmor"* ]]
    no_session_built
}

@test "a sandbox that cannot drop its bounding set stops the launch, blaming the policy" {
    # Ubuntu's shape: bwrap may create a user namespace, but nothing inside it
    # may hold a capability. Before this check the launch got as far as setpriv
    # and failed with "apply bounding set: Operation not permitted", naming the
    # wrong culprit and leaving a half-built session behind.
    rm "$ROOT/bin/bwrap"
    cat > "$ROOT/bin/bwrap" <<'EOF'
#!/bin/sh
for a in "$@"; do
    if [ "$a" = "--cap-add" ]; then
        echo "setpriv: apply bounding set: Operation not permitted" >&2
        exit 1
    fi
done
exit 0
EOF
    chmod +x "$ROOT/bin/bwrap"
    mkdir -p "$ROOT/sys/kernel"
    echo 1 > "$ROOT/sys/kernel/apparmor_restrict_unprivileged_userns"
    run env PATH="$ROOT/bin" SBX_OS_RELEASE="$ROOT/ubuntu" SBX_PROC_SYS="$ROOT/sys" \
        bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$ROOT/p" "$SBX" -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"bounding set cannot be emptied"* ]]
    [[ "$output" == *"unpriv_bwrap"* ]]
    no_session_built
}

@test "a session without networking stops when unshare may not create namespaces" {
    rm "$ROOT/bin/unshare"
    printf '#!/bin/sh\necho "unshare: unshare failed: Operation not permitted" >&2\nexit 1\n' > "$ROOT/bin/unshare"
    chmod +x "$ROOT/bin/unshare"
    run env PATH="$ROOT/bin" SBX_OS_RELEASE="$ROOT/ubuntu" SBX_PROC_SYS="$ROOT/sys" \
        bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$ROOT/p" "$SBX" -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"user and network namespace"* ]]
    no_session_built
}

@test "userns: full without a subordinate range stops with the usermod line" {
    mkdir -p "$HOME/.config/sbx/profiles/fs"
    echo '{"description":"t","userns":"full"}' > "$HOME/.config/sbx/profiles/fs/full.json"
    : > "$ROOT/subuid"; : > "$ROOT/subgid"
    run env PATH="$ROOT/bin" SBX_OS_RELEASE="$ROOT/arch" SBX_SUBUID="$ROOT/subuid" SBX_SUBGID="$ROOT/subgid" \
        bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$ROOT/p" "$SBX" --fs full --net web -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"usermod --add-subuids"* ]]
    no_session_built
}
