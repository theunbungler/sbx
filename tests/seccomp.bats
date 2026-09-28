#!/usr/bin/env bats

# --seccomp: one compiled filter, loaded by the payload's bwrap. The filters
# here are hand-assembled BPF (no arch check, x86-64 syscall numbers), which
# is fine for a test and wrong for real use: build real ones with libseccomp
# or minijail, which add the architecture check.

setup() {
    if [[ "$(uname -m)" != x86_64 ]]; then
        skip "hand-assembled filters use x86-64 system-call numbers"
    fi
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/p"
    HOSTDIR="$ROOT/o"
    mkdir -p "$HOME/.config/sbx/profiles/fs" "$PROJ" "$HOSTDIR"
    cat > "$HOME/.config/sbx/profiles/fs/t.json" <<JSON
{"mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
JSON
}

teardown() {
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]]; then
        rm -rf "$ROOT"
    fi
}

# One struct sock_filter, little-endian: u16 code, u8 jt, u8 jf, u32 k.
insn() {   # <code> <jt> <jf> <k>
    local c=$1 t=$2 f=$3 k=$4
    printf "$(printf '\\x%02x' $((c & 255)) $((c >> 8 & 255)) "$t" "$f" \
        $((k & 255)) $((k >> 8 & 255)) $((k >> 16 & 255)) $((k >> 24 & 255)))"
}

# Returns <ret> for system call <nr>, allows everything else.
filter() {   # <out file> <nr> <ret>
    {
        insn 0x20 0 0 0            # ld  [0]   (seccomp_data.nr)
        insn 0x15 0 1 "$2"         # jeq #nr, next, skip
        insn 0x06 0 0 "$3"         # ret <ret>
        insn 0x06 0 0 0x7fff0000   # ret ALLOW
    } > "$1"
}

# Returns <ret> for system call <nr> when its first argument is <arg0>,
# allows everything else.
filter_arg0() {   # <out file> <nr> <arg0> <ret>
    {
        insn 0x20 0 0 0            # ld  [0]   (seccomp_data.nr)
        insn 0x15 0 3 "$2"         # jeq #nr, next, allow
        insn 0x20 0 0 16           # ld  [16]  (args[0], low 32 bits)
        insn 0x15 0 1 "$3"         # jeq #arg0, next, allow
        insn 0x06 0 0 "$4"         # ret <ret>
        insn 0x06 0 0 0x7fff0000   # ret ALLOW
    } > "$1"
}

# Bounded, so a filter that wedges the launch fails the test instead of
# hanging the suite.
run_sbx() {   # <sbx args...> -- via a pty
    run bash -c "cd '$PROJ' && timeout 120 script -qec \"$SBX $*\" /dev/null 2>&1 < /dev/null"
}

@test "a --seccomp filter reaches the payload" {
    filter "$ROOT/nosyncfs.bpf" 306 0x00050001   # syncfs -> EPERM
    run_sbx --fs t --seccomp "$ROOT/nosyncfs.bpf" -- /bin/sh -c "'grep ^Seccomp: /proc/self/status > /out/status; sync -f /out; echo \\\$? > /out/rc'"
    [[ "$(cat "$HOSTDIR/status")" == *2 ]]
    [ "$(cat "$HOSTDIR/rc")" != "0" ]
    run_sbx --fs t -- /bin/sh -c "'sync -f /out; echo \\\$? > /out/rc'"
    [ "$(cat "$HOSTDIR/rc")" = "0" ]
}

# setpriv drops each capability with prctl(PR_CAPBSET_DROP) and believes
# it worked; only session.sh's check of /proc/self/status can tell.
@test "a filter that fakes the bounding-set drop stops the session before the payload" {
    filter_arg0 "$ROOT/fakedrop.bpf" 157 24 0x00050000  # prctl(PR_CAPBSET_DROP) -> 0 without running
    run_sbx --fs t --seccomp "$ROOT/fakedrop.bpf" -- /bin/sh -c "'echo ran > /out/ran'"
    [ "$status" -ne 124 ]
    if [[ -e "$HOSTDIR/ran" ]]; then echo "the payload ran" >&2; return 1; fi
    [[ "$output" == *"bounding set is not empty"* ]]
}
