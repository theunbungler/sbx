# Nested Session Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run every session's payload in a user namespace B nested in a control namespace A, so `ro` mounts and the egress firewall hold even against a payload that keeps its capabilities, while host ports and DNS keep their addresses.

**Architecture:** Two new runtime libraries, sourced by the generated `launch.sh` running in A: `lib/userns.sh` creates and maps B, and `lib/nestnet.sh` wires a veth from A into a network namespace B owns, adds A's `input`/`postrouting` chains, B's convenience DNAT rules and one `socat` relay per granted host port. `sbx` engages them behind one variable, first for `caps: keep` sessions (Task 4, a checkpoint), then for every session with the variable removed (Task 5).

**Tech Stack:** bash, bubblewrap 0.12 (`--userns2`), util-linux (`unshare`, `nsenter`, `setpriv`), iproute2 (`ip`, `ss`), nftables, dnsmasq, pasta, socat, bats 1.14, shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-20-nested-session-design.md`. Read it first: it records what the spikes measured and why each mechanism has the shape it has.

## Global Constraints

- Worktree: `.claude/worktrees/podman-full-hardening`, branch `podman-full-hardening`. Run every command from the worktree root.
- `shellcheck -S error sbx sbx-profile lib/*.sh` must print nothing after every task.
- The full suite `bats tests/` passes after every task (338 tests at the start of this plan, plus the tests each task adds).
- **Snapshot goldens (`tests/snapshots/`) are regenerated only where a task says so**, with `SBX_UPDATE_SNAPSHOTS=1` and a `-f` filter naming exactly the cases that task changes, and the resulting `git diff tests/snapshots/` is read line by line and summarised in the commit message. Never regenerate to make an unexplained diff go away.
- End-to-end tests use a short throwaway HOME: `ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"`, never `$BATS_TEST_TMPDIR` (the session socket path would exceed 108 bytes). Drive `sbx` with `script -qec "<cmd>" /dev/null`.
- In bats, `! cmd` fails a test only on the test's last line. Elsewhere write `if cmd; then echo "why" >&2; return 1; fi`.
- Any manual `sbx` run outside the test suites uses `--dry-run` under `HOME=$(mktemp -d /tmp/sbxh.XXXXXX)/h`, with every argument as a separate word. Never start a real session by hand.
- Fixed names and addresses (spec, "New library: `lib/nestnet.sh`"): A's veth end `sbx-a` = `10.200.0.1`, B's end `sbx-b` = `10.200.0.2`, prefix `/30`. `resolv.conf` keeps naming `127.0.0.2` (`SBX_DNS_ADDR`); host ports keep answering at `127.0.0.1:<port>`.
- Never pass `bwrap --userns`. B is entered with `--userns2 <fd>` alone (the paired form fails: spec, "What the spikes established", item 9).
- Never write a `uid_map`/`gid_map` with `printf`/`echo` redirection; use `sbx_userns_write_map` (Task 1).
- Firewall tests assert filtering (a connection fails), never the exit status of `nft flush ruleset`: in B that command succeeds and changes nothing that matters.
- The only new external dependency is `socat`.
- A commit hook rejects the user's login name in tracked files; write paths as `~/…` or `$HOME/…`.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WWTpUZ8XwVF2wUzAUMreDD
  ```
  Implementers on another model write that model's name in the `Co-Authored-By` line, never a model they are not.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `lib/userns.sh` | new | Create B (holder process), write its maps, release it. Runtime only (sourced by `launch.sh` and tests). |
| `lib/nestnet.sh` | new | A↔B networking: A's extra nft chains (text generator, used by `sbx`), veth wiring, B's loopback rules, host-port relays (runtime, used by `launch.sh`). |
| `lib/deps.sh` | modify | Table (`socat`, `nsenter`, `unshare` → core), `veth` check in `require`/`doctor`/`status`. |
| `lib/render.sh` | modify | Needs line shows `veth`; Security line wording. |
| `sbx` | modify | Source `lib/nestnet.sh`; generate the nested prelude and launch line; add A's chains; start A for sessions without networking. |
| `tests/userns.bats` | new | Unit tests for `lib/userns.sh` in real namespaces. |
| `tests/nestnet.bats` + `tests/helpers/nestnet-scenario.sh` | new | Unit tests for `lib/nestnet.sh` in real namespaces, no pasta. |
| `tests/nested.bats` | new | End-to-end: real sessions, `caps: keep` and capability-dropping, with and without networking, podman. |
| `tests/deps.bats`, `tests/render.bats`, `tests/dry-run.bats`, `tests/snapshot.bats`, `tests/hardening.bats` | modify | As each task says. |
| `README.md` | modify | Threat model, caveats, profile tables, setup check, host-services addressing. |

---

### Task 1: `lib/userns.sh` — create, map and release B

**Files:**
- Create: `lib/userns.sh`
- Test: `tests/userns.bats`

**Interfaces:**
- Consumes: nothing.
- Produces (all run inside A; A is any user namespace whose uid 0 has capabilities):
  - `sbx_userns_hold` → sets global `SBX_B_PID`; returns 0 once the holder is in a new user namespace, 1 otherwise.
  - `sbx_userns_write_map <file> <map text>` → one `write(2)` of `<map text>\n`.
  - `sbx_userns_map_identity <pid>` → B's uid/gid maps mirror the caller's ranges as identity (`inside inside count`).
  - `sbx_userns_map_outer_ids <pid>` → B maps the host id that the caller's 0 stands for onto the caller's 0 (`<outside-of-0> 0 1`), for uid and gid.
  - `sbx_userns_release <pid>` → kills the holder, reaps it, always returns 0.

- [ ] **Step 1: Write the failing tests**

Create `tests/userns.bats`:

```bash
#!/usr/bin/env bats

# lib/userns.sh in real namespaces. Each test plays the part of launch.sh:
# `unshare --user --map-root-user --net` is the control namespace A, and the
# library creates the payload namespace B inside it.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/lib/userns.sh"
}

in_a() {   # <script>: run in a single-uid A, like pasta's namespace
    unshare --user --map-root-user --net -- bash -c "source '$LIB'; $1"
}

in_full_a() {   # <script>: run in an A carrying the subordinate range, like userns: full
    awk -F: -v u="$(id -un)" -v i="$(id -u)" '$1 == u || $1 == i { f = 1 } END { exit !f }' /etc/subuid 2>/dev/null \
        || skip "no subordinate uid range for this user"
    unshare --map-auto --map-root-user --net -- bash -c "source '$LIB'; $1"
}

@test "hold puts B in a new user namespace and a new network namespace" {
    run in_a 'sbx_userns_hold || exit 1
        [[ $(readlink /proc/$SBX_B_PID/ns/user) != $(readlink /proc/self/ns/user) ]] && echo user-ok
        [[ $(readlink /proc/$SBX_B_PID/ns/net) != $(readlink /proc/self/ns/net) ]] && echo net-ok
        sbx_userns_release "$SBX_B_PID"'
    [ "$status" -eq 0 ]
    [[ "$output" == *user-ok* ]]
    [[ "$output" == *net-ok* ]]
}

@test "B owns its network namespace" {
    # Only the owner of a network namespace may configure it, so root in B
    # bringing up B's loopback proves the ownership.
    run in_a 'sbx_userns_hold && sbx_userns_map_identity "$SBX_B_PID" || exit 1
        nsenter -t "$SBX_B_PID" -U -n --preserve-credentials -- ip link set lo up && echo configured
        sbx_userns_release "$SBX_B_PID"'
    [[ "$output" == *configured* ]]
}

@test "identity map mirrors a single-range A" {
    run in_a 'sbx_userns_hold && sbx_userns_map_identity "$SBX_B_PID" || exit 1
        tr -s " " < /proc/$SBX_B_PID/uid_map; tr -s " " < /proc/$SBX_B_PID/gid_map
        sbx_userns_release "$SBX_B_PID"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = " 0 0 1" ]
    [ "${lines[1]}" = " 0 0 1" ]
}

@test "identity map mirrors a multi-range A" {
    run in_full_a 'sbx_userns_hold && sbx_userns_map_identity "$SBX_B_PID" || exit 1
        tr -s " " < /proc/$SBX_B_PID/uid_map
        sbx_userns_release "$SBX_B_PID"'
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = " 0 0 1" ]
    [[ "${lines[1]}" == " 1 1 "* ]]
}

@test "outer-id map shows the payload the host uid and gid" {
    run in_a 'sbx_userns_hold && sbx_userns_map_outer_ids "$SBX_B_PID" || exit 1
        nsenter -t "$SBX_B_PID" -U --preserve-credentials -- sh -c "id -u; id -g"
        sbx_userns_release "$SBX_B_PID"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$(id -u)" ]
    [ "${lines[1]}" = "$(id -g)" ]
}

@test "a map split across two writes is refused, which is why write_map exists" {
    run in_full_a 'sbx_userns_hold || exit 1
        if { echo "0 0 1"; echo "1 1 10"; } > /proc/$SBX_B_PID/uid_map 2>/dev/null; then echo accepted; else echo refused; fi
        sbx_userns_release "$SBX_B_PID"'
    [[ "$output" == *refused* ]]
}

@test "the holder dies when the shell that started it is killed" {
    local f="$BATS_TEST_TMPDIR/holder"
    run in_a "( sbx_userns_hold; echo \$SBX_B_PID > '$f'; exec sleep 60 ) &
        s=\$!
        for _ in \$(seq 1 50); do [[ -s '$f' ]] && break; sleep 0.1; done
        kill -9 \$s; sleep 0.5
        if kill -0 \$(cat '$f') 2>/dev/null; then echo alive; else echo gone; fi"
    [[ "$output" == *gone* ]]
}

@test "release ends B" {
    run in_a 'sbx_userns_hold || exit 1
        p=$SBX_B_PID
        sbx_userns_release "$p"
        if kill -0 "$p" 2>/dev/null; then echo alive; else echo gone; fi'
    [[ "$output" == *gone* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/userns.bats`
Expected: every test FAILS (`lib/userns.sh` does not exist; `source` errors), except the two that `skip` without a subordinate range.

- [ ] **Step 3: Write `lib/userns.sh`**

```bash
#!/bin/bash
# The payload namespace B: a user namespace nested in the session's control
# namespace A, owning its own network namespace.
#
# Sourced at run time by launch.sh, which runs in A, and by tests/.
# Functions only; no side effects at source time. Uses util-linux
# (unshare, setpriv) and coreutils (dd, sleep, readlink).
#
# Why B exists: bwrap runs in A, so every mount it makes belongs to A, and a
# mount inherited across a user-namespace boundary is MNT_LOCKED. From B it
# cannot be remounted or unmounted, whatever capabilities B holds. A's nft
# ruleset lives in A's network namespace, which B cannot see.

# Starts B's holder and sets SBX_B_PID. The holder is a sleep in a new user
# namespace and a new network namespace owned by it; B lives as long as the
# holder does. --pdeathsig ties the holder to the calling shell, so a
# SIGKILLed launch.sh does not leak it (the signal survives the unshare:
# verified 2026-09-21). The maps are written separately, by the caller.
sbx_userns_hold() {
    local mine theirs
    mine=$(readlink /proc/self/ns/user)
    setpriv --pdeathsig KILL -- unshare --user --net -- sleep infinity \
        </dev/null >/dev/null 2>&1 &
    SBX_B_PID=$!
    for _ in {1..250}; do
        theirs=$(readlink "/proc/$SBX_B_PID/ns/user" 2>/dev/null) || return 1
        if [[ "$theirs" != "$mine" ]]; then
            return 0
        fi
        sleep 0.02
    done
    return 1
}

# The kernel accepts exactly one write(2) to a uid_map or gid_map. printf
# and echo may split a multi-line map across writes, and the second write
# then fails with EINVAL, which reads as "multi-range maps are impossible".
# dd with iflag=fullblock collects the whole input before its single write.
sbx_userns_write_map() {   # <map file> <map text>
    printf '%s\n' "$2" | dd of="$1" bs=65536 iflag=fullblock status=none
}

# B mirrors the caller's ranges as an identity map: every id A can represent
# means the same id in B. Networked and userns: full sessions, whose payload
# has always run as A's 0.
sbx_userns_map_identity() {   # <pid>
    local kind map inside outside count
    for kind in uid gid; do
        map=""
        while read -r inside outside count; do
            map+="${map:+$'\n'}$inside $inside $count"
        done < "/proc/self/${kind}_map"
        sbx_userns_write_map "/proc/$1/${kind}_map" "$map" || return 1
    done
}

# B maps the host id that A's 0 stands for onto A's 0, so the payload sees
# the identity a bwrap-created namespace gave it before B existed: sessions
# without networking, where A comes from `unshare --map-root-user`.
sbx_userns_map_outer_ids() {   # <pid>
    local kind inside outside count
    for kind in uid gid; do
        while read -r inside outside count; do
            if [[ "$inside" == 0 ]]; then
                break
            fi
        done < "/proc/self/${kind}_map"
        [[ "$inside" == 0 ]] || return 1
        sbx_userns_write_map "/proc/$1/${kind}_map" "$outside 0 1" || return 1
    done
}

sbx_userns_release() {   # <pid>
    if [[ -n "${1:-}" ]]; then
        kill "$1" 2>/dev/null
        wait "$1" 2>/dev/null
    fi
    return 0
}
```

Note on `sbx_userns_map_outer_ids`: in A, `/proc/self/uid_map` reads `0 <host uid> 1`, so `outside` is the host uid and B's map becomes `<host uid> 0 1`. `count` is read but unused because only A's 0 is remapped; keep it in the `read` so `outside` does not swallow the rest of the line.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/userns.bats`
Expected: 8 tests, all `ok` (the two `in_full_a` tests may `skip` on a machine without a subordinate range; on this machine they run).

Run: `shellcheck -S error lib/userns.sh`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add lib/userns.sh tests/userns.bats
git commit -m "Add lib/userns.sh: create, map and release the payload namespace

<body: what the functions do, the single-write map rule, pdeathsig, trailers>"
```

---

### Task 2: `lib/nestnet.sh` — A↔B networking

**Files:**
- Create: `lib/nestnet.sh`
- Create: `tests/helpers/nestnet-scenario.sh`
- Test: `tests/nestnet.bats`

**Interfaces:**
- Consumes: `lib/userns.sh` (Task 1) in tests: `sbx_userns_hold`, `sbx_userns_map_identity`, `sbx_userns_release`, `SBX_B_PID`.
- Produces:
  - Constants `SBX_NEST_A_IF=sbx-a`, `SBX_NEST_B_IF=sbx-b`, `SBX_NEST_A_ADDR=10.200.0.1`, `SBX_NEST_B_ADDR=10.200.0.2`, `SBX_NEST_PREFIX=30`.
  - `sbx_nestnet_a_rules <dns true|false> <tcp csv> <udp csv>` → prints two nft chains (`input`, `postrouting`) for insertion inside `table inet sbx_filter { … }`. Pure text; runs in `sbx`.
  - `sbx_nestnet_lo_up <b pid>` → B's loopback up (sessions without networking).
  - `sbx_nestnet_wire <b pid>` → veth, addresses, B's loopback, B's default route, `ip_forward` in A.
  - `sbx_nestnet_b_rules <b pid> <dns addr or ""> <tcp csv> <udp csv>` → B's `table ip sbx_nest` (DNAT of `127.0.0.1:<port>` and `<dns addr>:53` to A's veth address) plus `route_localnet` on `sbx-b`. No-op when all three are empty.
  - `sbx_nestnet_relays <tcp csv> <udp csv>` → one `socat` per port, pids in global array `SBX_NEST_RELAY_PIDS`; returns 0 once every relay listens, 1 if one dies or times out.
  - `sbx_nestnet_release` → kills the relays; always 0.

- [ ] **Step 1: Write the scenario helper**

The tests need a whole A/B pair set up before each probe. Create `tests/helpers/nestnet-scenario.sh` (make it executable). It runs inside A and plays the parts of pasta (listeners bound to the `lo` device, exactly as pasta's splice listeners are) and dnsmasq (a responder on A's veth address):

```bash
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
```

- [ ] **Step 2: Write the failing tests**

Create `tests/nestnet.bats`:

```bash
#!/usr/bin/env bats

# lib/nestnet.sh in real namespaces, without pasta: tests/helpers/
# nestnet-scenario.sh builds A and B and stands in for pasta and dnsmasq.
# Egress through pasta is covered end to end in tests/nested.bats.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    for t in socat nft nsenter; do
        command -v "$t" >/dev/null 2>&1 || skip "$t not installed"
    done
    unshare --user --map-root-user --net -- ip link add t0 type veth peer name t1 2>/dev/null \
        || skip "veth unavailable to the running kernel"
}

scenario() {   # <probe script text>
    printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/probe.sh"
    run unshare --user --map-root-user --net -- \
        bash "$REPO/tests/helpers/nestnet-scenario.sh" "$REPO/lib" "$BATS_TEST_TMPDIR/probe.sh"
    if [[ "$output" != *"setup=ok"* ]]; then
        echo "$output" >&2
        return 1
    fi
}

@test "a_rules prints an input chain that names only the granted ports and DNS" {
    source "$REPO/lib/nestnet.sh"
    run sbx_nestnet_a_rules true 5433 5353
    [ "$status" -eq 0 ]
    [[ "$output" == *'iifname "sbx-a" ip daddr 10.200.0.1 tcp dport { 5433 } accept'* ]]
    [[ "$output" == *'iifname "sbx-a" ip daddr 10.200.0.1 udp dport { 5353 } accept'* ]]
    [[ "$output" == *'iifname "sbx-a" ip daddr 10.200.0.1 udp dport 53 accept'* ]]
    [[ "$output" == *'iifname "sbx-a" counter drop'* ]]
    [[ "$output" == *'ip saddr 10.200.0.2 oifname != "sbx-a" masquerade'* ]]
}

@test "a_rules without DNS or host ports still drops everything from B" {
    source "$REPO/lib/nestnet.sh"
    run sbx_nestnet_a_rules false "" ""
    [[ "$output" != *dport* ]]
    [[ "$output" == *'iifname "sbx-a" counter drop'* ]]
}

@test "a granted TCP host port answers at 127.0.0.1 in B" {
    scenario 'echo "r=$(tcp_get 127.0.0.1 18081)"'
    [[ "$output" == *"r=granted"* ]]
}

@test "a granted UDP host port answers at 127.0.0.1 in B" {
    scenario 'echo "r=$(udp_get 127.0.0.1 18083)"'
    [[ "$output" == *"r=udp-granted"* ]]
}

@test "DNS at 127.0.0.2 in B reaches the resolver on A's veth address" {
    scenario 'echo "r=$(udp_get 127.0.0.2 53)"'
    [[ "$output" == *"r=resolver"* ]]
}

@test "a host port that was not granted is unreachable from B" {
    scenario 'echo "lo=$(tcp_get 127.0.0.1 18082)"; echo "veth=$(tcp_get 10.200.0.1 18082)"'
    [[ "$output" == *"veth="* ]]
    [[ "$output" != *not-granted* ]]
}

@test "B's own DNAT to a port that was not granted is dropped by A" {
    scenario 'before=$(a_drops)
        inb nft add rule ip sbx_nest output ip daddr 127.0.0.1 tcp dport 18082 dnat to 10.200.0.1
        echo "r=$(tcp_get 127.0.0.1 18082)"
        echo "rose=$(( $(a_drops) > before ))"'
    [[ "$output" != *not-granted* ]]
    [[ "$output" == *"rose=1"* ]]
}

@test "rerouting 127.0.0.0/8 out of the veth reaches nothing on A's loopback" {
    scenario 'inb ip route del local 127.0.0.1 dev lo table local
        inb ip route del local 127.0.0.0/8 dev lo table local
        inb ip route add 127.0.0.0/8 via 10.200.0.1 dev sbx-b src 10.200.0.2
        echo "r=$(tcp_get 127.0.0.1 18082)"'
    [[ "$output" != *not-granted* ]]
}

@test "after B flushes its ruleset only its own shortcuts are gone" {
    scenario 'inb nft flush ruleset
        echo "lo=$(tcp_get 127.0.0.1 18081)"
        echo "veth=$(tcp_get 10.200.0.1 18081)"
        echo "other=$(tcp_get 10.200.0.1 18082)"'
    [[ "$output" != *"lo=granted"* ]]
    [[ "$output" == *"veth=granted"* ]]
    [[ "$output" != *not-granted* ]]
}

@test "relays report failure when a port on A's veth address is taken" {
    scenario 'sbx_nestnet_release
        socat TCP-LISTEN:18090,bind=10.200.0.1,so-bindtodevice=sbx-a,reuseaddr SYSTEM:true &
        sleep 0.3
        if sbx_nestnet_relays 18090 ""; then echo "relays=ok"; else echo "relays=failed"; fi'
    [[ "$output" == *"relays=failed"* ]]
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats tests/nestnet.bats`
Expected: every test FAILS (`lib/nestnet.sh` does not exist), unless setup skips for a missing tool or veth, which it should not on this machine.

- [ ] **Step 4: Write `lib/nestnet.sh`**

```bash
#!/bin/bash
# Networking between the control namespace A and the payload namespace B.
#
# sbx_nestnet_a_rules runs in sbx and prints nft text for A's ruleset. The
# other functions run in launch.sh, in A, after sbx_userns_hold. Sourced by
# sbx, launch.sh and tests/; constants and functions only, no side effects
# at source time. Uses iproute2 (ip, ss), nft, nsenter and socat.
#
# B reaches A only where A's input chain says: the granted host ports and
# DNS, at A's veth address. Host ports cannot be DNATed onto A's loopback,
# because pasta binds its splice listener to the lo device
# (SO_BINDTODEVICE); a socat relay on A's veth address forwards to it
# instead. A never sets route_localnet, so nothing B sends is delivered to
# A's loopback. B's own rules only move the familiar addresses
# (127.0.0.1:<port>, the resolver's 127.0.0.2) onto A's veth address; a
# payload that deletes them loses those addresses and gains nothing.

SBX_NEST_A_IF=sbx-a
SBX_NEST_B_IF=sbx-b
SBX_NEST_A_ADDR=10.200.0.1
SBX_NEST_B_ADDR=10.200.0.2
SBX_NEST_PREFIX=30

# A's additions to `table inet sbx_filter`. input is the boundary for what B
# may reach on A itself; it matches iifname, so it loads before the veth
# exists. postrouting masquerades B's traffic leaving A by pasta's
# interface: the spikes ran with it, and whether pasta would translate B's
# forwarded traffic on its own is untested.
sbx_nestnet_a_rules() {   # <dns true|false> <tcp csv> <udp csv>
    local dns="$1" tcp="$2" udp="$3"
    echo "    chain input {"
    echo "        type filter hook input priority 0; policy accept;"
    if [[ -n "$tcp" ]]; then
        echo "        iifname \"$SBX_NEST_A_IF\" ip daddr $SBX_NEST_A_ADDR tcp dport { $tcp } accept"
    fi
    if [[ -n "$udp" ]]; then
        echo "        iifname \"$SBX_NEST_A_IF\" ip daddr $SBX_NEST_A_ADDR udp dport { $udp } accept"
    fi
    if [[ "$dns" == "true" ]]; then
        echo "        iifname \"$SBX_NEST_A_IF\" ip daddr $SBX_NEST_A_ADDR udp dport 53 accept"
        echo "        iifname \"$SBX_NEST_A_IF\" ip daddr $SBX_NEST_A_ADDR tcp dport 53 accept"
    fi
    echo "        iifname \"$SBX_NEST_A_IF\" counter drop"
    echo "    }"
    echo "    chain postrouting {"
    echo "        type nat hook postrouting priority srcnat; policy accept;"
    echo "        ip saddr $SBX_NEST_B_ADDR oifname != \"$SBX_NEST_A_IF\" masquerade"
    echo "    }"
}

# A session without networking: B's network namespace is empty apart from
# its loopback, which starts down.
sbx_nestnet_lo_up() {   # <b pid>
    nsenter --net="/proc/$1/ns/net" -- ip link set lo up
}

# A creates the pair and moves B's end into B's network namespace: a process
# in A holds capabilities over namespaces owned by B, while B could never
# create an interface in A's. B then configures nothing itself.
sbx_nestnet_wire() {   # <b pid>
    local b="/proc/$1/ns/net"
    ip link add "$SBX_NEST_A_IF" type veth peer name "$SBX_NEST_B_IF" || return 1
    ip link set "$SBX_NEST_B_IF" netns "$1" || return 1
    ip addr add "$SBX_NEST_A_ADDR/$SBX_NEST_PREFIX" dev "$SBX_NEST_A_IF" || return 1
    ip link set "$SBX_NEST_A_IF" up || return 1
    echo 1 > /proc/sys/net/ipv4/ip_forward || return 1
    nsenter --net="$b" -- ip link set lo up || return 1
    nsenter --net="$b" -- ip addr add "$SBX_NEST_B_ADDR/$SBX_NEST_PREFIX" dev "$SBX_NEST_B_IF" || return 1
    nsenter --net="$b" -- ip link set "$SBX_NEST_B_IF" up || return 1
    nsenter --net="$b" -- ip route add default via "$SBX_NEST_A_ADDR"
}

# B's convenience rules. Locally generated connections to 127.0.0.1:<granted
# port> and to the resolver are DNATed to A's veth address; route_localnet
# lets a loopback-sourced packet leave by sbx-b, and the masquerade gives it
# B's address. Loaded from A, before the payload starts.
sbx_nestnet_b_rules() {   # <b pid> <dns addr or ""> <tcp csv> <udp csv>
    local b="/proc/$1/ns/net" dns="$2" tcp="$3" udp="$4"
    if [[ -z "$dns" && -z "$tcp" && -z "$udp" ]]; then
        return 0
    fi
    nsenter --net="$b" -- sh -c "echo 1 > /proc/sys/net/ipv4/conf/$SBX_NEST_B_IF/route_localnet" || return 1
    {
        echo "table ip sbx_nest {"
        echo "    chain output {"
        echo "        type nat hook output priority -100; policy accept;"
        if [[ -n "$tcp" ]]; then
            echo "        ip daddr 127.0.0.1 tcp dport { $tcp } dnat to $SBX_NEST_A_ADDR"
        fi
        if [[ -n "$udp" ]]; then
            echo "        ip daddr 127.0.0.1 udp dport { $udp } dnat to $SBX_NEST_A_ADDR"
        fi
        if [[ -n "$dns" ]]; then
            echo "        ip daddr $dns udp dport 53 dnat to $SBX_NEST_A_ADDR"
            echo "        ip daddr $dns tcp dport 53 dnat to $SBX_NEST_A_ADDR"
        fi
        echo "    }"
        echo "    chain postrouting {"
        echo "        type nat hook postrouting priority srcnat; policy accept;"
        echo "        oifname \"$SBX_NEST_B_IF\" ip saddr 127.0.0.0/8 masquerade"
        echo "    }"
        echo "}"
    } | nsenter --net="$b" -- nft -f -
}

# One relay per granted port and protocol, from A's veth address to pasta's
# splice listener on A's loopback. so-bindtodevice lets the relay share the
# port number with that listener, which pasta binds to the lo device. Each
# relay carries --pdeathsig, like B's holder. Returns once every relay is
# listening, or 1 if one exits first (a taken port, a missing socat).
sbx_nestnet_relays() {   # <tcp csv> <udp csv>
    local -a tcp udp
    local p pid ready
    IFS=, read -ra tcp <<< "$1"
    IFS=, read -ra udp <<< "$2"
    SBX_NEST_RELAY_PIDS=()
    for p in "${tcp[@]}"; do
        setpriv --pdeathsig KILL -- socat \
            "TCP-LISTEN:$p,bind=$SBX_NEST_A_ADDR,so-bindtodevice=$SBX_NEST_A_IF,fork,reuseaddr" \
            "TCP:127.0.0.1:$p" </dev/null >/dev/null 2>&1 &
        SBX_NEST_RELAY_PIDS+=("$!")
    done
    for p in "${udp[@]}"; do
        setpriv --pdeathsig KILL -- socat \
            "UDP-RECVFROM:$p,bind=$SBX_NEST_A_ADDR,so-bindtodevice=$SBX_NEST_A_IF,fork,reuseaddr" \
            "UDP:127.0.0.1:$p" </dev/null >/dev/null 2>&1 &
        SBX_NEST_RELAY_PIDS+=("$!")
    done
    for _ in {1..100}; do
        for pid in "${SBX_NEST_RELAY_PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null || return 1
        done
        ready=true
        for p in "${tcp[@]}"; do
            [[ -n "$(ss -Hltn "src $SBX_NEST_A_ADDR:$p")" ]] || ready=false
        done
        for p in "${udp[@]}"; do
            [[ -n "$(ss -Hlun "src $SBX_NEST_A_ADDR:$p")" ]] || ready=false
        done
        if [[ "$ready" == "true" ]]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

sbx_nestnet_release() {
    local pid
    for pid in "${SBX_NEST_RELAY_PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
    return 0
}
```

If `ss`'s `src ADDR:PORT` filter does not match a socket bound to a device (it prints as `10.200.0.1%sbx-a:18081`), switch the readiness test to `ss -Hltn "sport = :$p"` and match the address with `[[ "$(…)" == *"$SBX_NEST_A_ADDR"* ]]`. Verify which one works by running the relay tests; do not guess.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/nestnet.bats`
Expected: 10 tests, all `ok`.

Run: `shellcheck -S error lib/nestnet.sh tests/helpers/nestnet-scenario.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/nestnet.sh tests/nestnet.bats tests/helpers/nestnet-scenario.sh
git commit -m "Add lib/nestnet.sh: veth, relays and loopback rules between A and B

<body: A's input chain as the boundary, the lo-bound pasta listener that
makes a relay necessary, B's rules as convenience only, trailers>"
```

---

### Task 3: Dependencies — `socat`, `nsenter`, `unshare`, and the `veth` check

**Files:**
- Modify: `lib/deps.sh` (table at lines 13-30; `sbx_deps_require` ~253; `sbx_deps_doctor` ~288; `sbx_deps_status` ~381)
- Modify: `lib/render.sh:104-107` (Needs line)
- Modify: `tests/snapshot.bats` (`write_stubs`, `run_case`)
- Modify: `tests/dry-run.bats` (setup)
- Test: `tests/deps.bats`, `tests/render.bats`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `sbx_deps_kernel_release` → prints the running kernel release (`SBX_KERNEL_RELEASE` overrides `/proc/sys/kernel/osrelease`).
  - `sbx_deps_veth_ok` → 0 if `veth` is loaded, built in, or present in the running kernel's module tree. Overrides for tests: `SBX_SYS_MODULE_DIR` (default `/sys/module`), `SBX_LIB_MODULES` (default `/lib/modules`), `SBX_KERNEL_RELEASE`.
  - `sbx_deps_require … net …` additionally fails with a `veth` message.
  - `sbx_deps_doctor` prints a `veth` line under `net`; `--json` gains `"veth": true|false`.
  - `sbx_deps_status` JSON gains `"veth": null|true|false` (null unless `net` is requested); `.ok` is false when it is false.
  - Render: Needs line shows `veth ✓` / `veth ✗` when `.needs.veth` is not null.

- [ ] **Step 1: Write the failing tests**

In `tests/deps.bats`, add fixture helpers after `os_release()`:

```bash
veth_loaded() {   # a /sys/module fixture where veth is loaded
    mkdir -p "$FIX/sysmod/veth"
    export SBX_SYS_MODULE_DIR="$FIX/sysmod"
}

veth_absent() {   # no veth anywhere: not loaded, no module file, not built in
    mkdir -p "$FIX/sysmod" "$FIX/modules/6.0.0-test"
    export SBX_SYS_MODULE_DIR="$FIX/sysmod" SBX_LIB_MODULES="$FIX/modules" SBX_KERNEL_RELEASE=6.0.0-test
}
```

Update the two existing tests whose expected text changes because `socat` joins `net`:

```bash
@test "tools lists a group in table order" {
    run sbx_deps_tools net
    [ "$output" = "$(printf 'pasta\nnft\ndnsmasq\nsocat')" ]
}
```

and in "require names missing tools and the distro's command":

```bash
    [[ "${lines[0]}" == "Error: sbx requires pasta nft dnsmasq socat, which are not on PATH." ]]
    [[ "$output" == *"sudo apt install passt nftables dnsmasq socat"* ]]
```

In "require passes silently when nothing is missing", "require skips the userns probe for optional groups", and every `status:` test that requests `net`, add `veth_loaded` as the first line, so they do not depend on the machine running them.

Add new tests:

```bash
@test "veth ok when the module is loaded" {
    veth_loaded
    run sbx_deps_veth_ok
    [ "$status" -eq 0 ]
}

@test "veth ok when the running kernel has the module file" {
    veth_absent
    mkdir -p "$FIX/modules/6.0.0-test/kernel/drivers/net"
    : > "$FIX/modules/6.0.0-test/kernel/drivers/net/veth.ko.zst"
    run sbx_deps_veth_ok
    [ "$status" -eq 0 ]
}

@test "veth ok when it is built into the running kernel" {
    veth_absent
    echo "kernel/drivers/net/veth.ko" > "$FIX/modules/6.0.0-test/modules.builtin"
    run sbx_deps_veth_ok
    [ "$status" -eq 0 ]
}

@test "veth not ok when the running kernel's module tree lacks it" {
    veth_absent
    run sbx_deps_veth_ok
    [ "$status" -eq 1 ]
}

@test "require net fails with a reboot hint when veth is unavailable" {
    veth_absent
    fake_bwrap 0
    PATH="$FIX/bin:$PATH" run sbx_deps_require net
    [ "$status" -eq 1 ]
    [[ "$output" == *"veth kernel module is not available to the running kernel (6.0.0-test)"* ]]
    [[ "$output" == *reboot* ]]
}

@test "require core does not check veth" {
    veth_absent
    fake_bwrap 0
    PATH="$FIX/bin:$PATH" run sbx_deps_require core
    [ "$status" -eq 0 ]
}

@test "doctor reports veth under net" {
    doctor_bin bwrap
    fake_bwrap 0
    veth_absent
    PATH="$FIX/bin" run sbx_deps_doctor
    [[ "$output" == *"✗ veth kernel module"* ]]
    PATH="$FIX/bin" run sbx_deps_doctor --json
    [ "$(jq -r .veth <<< "$output")" = "false" ]
}

@test "status: veth is null without net and false when net needs it" {
    doctor_bin bwrap
    fake_bwrap 0
    veth_absent
    PATH="$FIX/bin" run sbx_deps_status core
    [ "$(jq -r .veth <<< "$output")" = "null" ]
    PATH="$FIX/bin" run sbx_deps_status core net
    [ "$(jq -r .veth <<< "$output")" = "false" ]
    [ "$(jq -r .ok <<< "$output")" = "false" ]
}
```

`doctor_bin` links every tool the table names, so once `socat` and `nsenter` join the table it links them too; nothing else to change there. The doctor's JSON test "doctor --json is parseable and matches the text report" gains no assertion, but add `veth_loaded` to it and to "doctor: all present exits 0 and reports each group".

In `tests/render.bats` (its `doc`/`render`/`line` helpers build a complete dry-run document and patch it with a jq expression), add after "writes, needs, confirm and result":

```bash
@test "needs shows veth only when it was checked" {
    render '.needs = {groups:{core:[], net:[]}, userns:true, subids:null, veth:false, install:[], ok:false}'
    [ "$(line Needs)" = "Needs      core ✓ · net ✓ · userns ✓ · veth ✗" ]
    render '.needs = {groups:{core:[]}, userns:true, subids:null, veth:null, install:[], ok:true}'
    [ "$(line Needs)" = "Needs      core ✓ · userns ✓" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/deps.bats tests/render.bats`
Expected: the new tests and the two updated `net` text tests FAIL; everything else passes.

- [ ] **Step 3: Implement**

Table in `lib/deps.sh` becomes (only these rows change or appear):

```
    "unshare    core    util-linux  util-linux    util-linux-core"
    "nsenter    core    util-linux  util-linux    util-linux-core"
    ...
    "socat      net     socat       socat         socat"
```

Place `unshare` and `nsenter` after `flock` (keeping core rows together), `socat` after `dnsmasq`, and delete the old `unshare podman …` row. Update the file's header comment where it states what each group is for, if it lists tools.

After `sbx_deps_subids_ok`, add:

```bash
sbx_deps_kernel_release() {
    local rel="${SBX_KERNEL_RELEASE:-}"
    if [[ -z "$rel" ]]; then
        read -r rel < /proc/sys/kernel/osrelease
    fi
    echo "$rel"
}

# Every networked session joins its payload namespace to the control
# namespace with a veth pair. veth is a kernel module, not a binary: the
# RUNNING kernel must have it loaded, built in, or in its module tree. After
# a kernel upgrade without a reboot the running kernel's tree is often gone,
# and `ip link add ... type veth` then fails with "Unknown device type".
sbx_deps_veth_ok() {
    local mods="${SBX_LIB_MODULES:-/lib/modules}" rel f
    [[ -d "${SBX_SYS_MODULE_DIR:-/sys/module}/veth" ]] && return 0
    rel=$(sbx_deps_kernel_release)
    for f in "$mods/$rel/kernel/drivers/net/veth.ko"*; do
        [[ -e "$f" ]] && return 0
    done
    awk '/\/veth\.ko$/ { found = 1 } END { exit !found }' "$mods/$rel/modules.builtin" 2>/dev/null
}

sbx_deps_veth_explain() {
    echo "veth kernel module is not available to the running kernel ($(sbx_deps_kernel_release))."
    echo "  After a kernel upgrade, reboot so the running kernel matches its modules."
}
```

In `sbx_deps_require`, after the userns block and before `return 0`:

```bash
    if [[ " $* " == *" net "* ]] && ! sbx_deps_veth_ok; then
        {
            echo "Error: the $(sbx_deps_veth_explain | head -1)"
            sbx_deps_veth_explain | tail -n +2
        } >&2
        return 1
    fi
```

In `sbx_deps_doctor`: declare `local veth=false`; after the subids check add `if sbx_deps_veth_ok; then veth=true; fi`. JSON: change the final `printf` to include `"veth":%s` right after `"subids":%s` (pass `"$veth"`). Text: add a `net)` arm to the `case "$group"`:

```bash
            net)
                if [[ "$veth" == "true" ]]; then
                    echo "         ✓ veth kernel module"
                else
                    echo "         ✗ $(sbx_deps_veth_explain | head -1)"
                    echo "           $(sbx_deps_veth_explain | tail -n +2 | sed 's/^  //')"
                fi
                ;;
```

The doctor's exit status does not change for `veth`, the same as for a missing `net` tool: it is an optional group.

In `sbx_deps_status`: `local veth=null`; after the userns block:

```bash
    if [[ " $* " == *" net "* ]]; then
        if sbx_deps_veth_ok; then
            veth=true
        else
            veth=false
            ok=false
        fi
    fi
```

and add `"veth":%s` after `"subids":%s` in its `printf`. Update the comment above the function to mention `veth`.

`lib/render.sh`, Needs line, after the `subids` element:

```
            (if $d.needs.veth == null then empty else "veth \(mark($d.needs.veth))" end),
```

(Mind the comma placement: every element but the last in that array ends with a comma.)

Snapshot hermeticity (`tests/snapshot.bats`): in `write_stubs`, add a `socat` stub (it is never executed; it must only exist on PATH) and create the veth fixture:

```bash
    printf '#!/bin/bash\nexit 0\n' > "$STUB/socat"
    mkdir -p "$ROOT/sysmod/veth"
```

(before the final `chmod +x "$STUB"/*`), and in `run_case`'s `env -i` list add `SBX_SYS_MODULE_DIR="$ROOT/sysmod" \`.

`tests/dry-run.bats`: in `setup()`, create `mkdir -p "$ROOT/sysmod/veth"` (use that suite's own root variable) and `export SBX_SYS_MODULE_DIR=…` so its `--net` cases do not depend on the machine. If a dry-run test asserts the exact Needs line of a `--net` launch, update it to include ` · veth ✓` where the renderer now puts it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/deps.bats tests/render.bats tests/dry-run.bats tests/snapshot.bats tests/preflight.bats`
Expected: all `ok`. The snapshot suite passes **without** regeneration (nothing a launch generates changed).

Run: `bats tests/ && shellcheck -S error sbx sbx-profile lib/*.sh`
Expected: all tests pass; shellcheck silent.

- [ ] **Step 5: Commit**

```bash
git add lib/deps.sh lib/render.sh tests/deps.bats tests/render.bats tests/dry-run.bats tests/snapshot.bats
git commit -m "Dependencies for nested sessions: socat, nsenter, unshare in core, veth check

<body, trailers>"
```

---

### Task 4: Checkpoint — nest `caps: keep` sessions

Every `caps: keep` session (`fs/podman` with or without `--net`, `fs/podman-full`) runs its payload in B. Capability-dropping sessions are untouched, and the snapshot goldens prove it.

**Files:**
- Modify: `sbx` (lib sourcing ~line 12-27; mode variables after line 795; namespace section ~963-1007; nft ruleset ~1537-1579; dnsmasq heredoc ~1914; new nested prelude before the launch-script block ~2061; launch-script assembly ~2061-2105; launch ~2150-2170)
- Modify: `tests/snapshot.bats` (unshare stub; a new case)
- Create: `tests/nested.bats`
- Regenerate: `tests/snapshots/podman/`, `tests/snapshots/userns-full/`; create `tests/snapshots/podman-nonet/`

**Interfaces:**
- Consumes: Task 1 (`sbx_userns_hold`, `sbx_userns_map_identity`, `sbx_userns_map_outer_ids`, `sbx_userns_release`, `SBX_B_PID`), Task 2 (`SBX_NEST_*` constants, `sbx_nestnet_a_rules`, `sbx_nestnet_lo_up`, `sbx_nestnet_wire`, `sbx_nestnet_b_rules`, `sbx_nestnet_relays`, `sbx_nestnet_release`), Task 3 (preflight requires `socat` and `veth` for `net`).
- Produces: `SBX_NESTED` in `sbx` (removed again in Task 5); launch.sh variables `SBX_B_PID`, `SBX_BFD`; `tests/nested.bats` helpers reused by Task 5: `payload`, `requires_pasta`, `requires_net`, `requires_denied_target`, `allowed_ip_profile`, `start_host_tcp`, `start_host_udp`, `requires_podman_image`.

- [ ] **Step 1: Write the failing end-to-end tests**

Create `tests/nested.bats`:

```bash
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
    [[ "$(cat "$HOSTDIR/caps.txt")" != *"0000000000000000" ]]
}

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
    [ "$(cat "$HOSTDIR/udp.txt")" = "host-udp" ]
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

@test "fs/podman-full keeps multi-uid fidelity and container DNS" {
    requires_net
    requires_podman_image
    payload "--fs podman-full --fs img --fs keep --net nothing" <<'EOF'
podman load -q -i /img/alpine.tar >/dev/null 2>&1
podman run --rm --network=none --user 1000:1000 docker.io/library/alpine:latest id -u > /out/uid.txt 2>&1
podman run -d --name pg docker.io/library/alpine:latest sleep 60 >/dev/null 2>&1
podman run --rm docker.io/library/alpine:latest nslookup pg > /out/dns.txt 2>&1
podman rm -f pg >/dev/null 2>&1
EOF
    [ "$(tail -1 "$HOSTDIR/uid.txt")" = "1000" ]
    grep -q '^Name:' "$HOSTDIR/dns.txt"
}
```

`--fs keep` stacks with `--fs podman` to add the `/out` and `/ro` mounts: the resolver (`lib/resolve.sh` ~134-152) accepts several `caps` profiles and only records the last one's name for the warning.

- [ ] **Step 2: Run the tests to verify which fail**

Run: `bats tests/nested.bats`
Expected FAIL (red): "a ro mount cannot be remounted writable", "cannot be unmounted", "host file survives an attack", "egress stays filtered after nft flush ruleset", "a host port that was not granted stays unreachable…" (the payload's own DNAT test may already pass; that is fine). Expected PASS already (guards): the canary, capabilities held, both identity tests, DNS, both host-port tests, both podman tests. Record the actual list in your report.

- [ ] **Step 3: Source the library and add the mode variable**

In `sbx`, beside the other `source "$SCRIPT_DIR/lib/…"` lines (following their comment style), add `source "$SCRIPT_DIR/lib/nestnet.sh"` with a one-line comment: A's extra chains and the A/B addresses.

After `SBX_NETNS=$(plan_get '.netns')` (~line 795):

```bash
# The payload runs in a user namespace B nested in the session's control
# namespace A (lib/userns.sh, lib/nestnet.sh): mounts made in A are locked
# in B, and A's ruleset is out of B's reach. caps:keep sessions first.
SBX_NESTED=$CAPS_KEEP
NEST_TCP=$(IFS=,; echo "${HOST_PORTS_TCP[*]}")
NEST_UDP=$(IFS=,; echo "${HOST_PORTS_UDP[*]}")
DNSMASQ_NEST_LISTEN=""
if [[ "$SBX_NESTED" == "true" ]]; then
    DNSMASQ_NEST_LISTEN="--listen-address=$SBX_NEST_A_ADDR"
fi
```

- [ ] **Step 4: Namespaces, ruleset and dnsmasq**

Namespace section, the `else` branch (~line 1001-1007) becomes:

```bash
else
    if [[ "$SBX_NESTED" != "true" ]]; then
        # With neither a net profile nor host ports, bwrap creates its own
        # namespaces and the session has no network stack at all.
        # No --uid/--gid: bwrap defaults to mapping the real UID/GID into the
        # new user namespace, so the sandbox sees the same user/HOME identity
        # as the host (matches what the --net branch already does via pasta).
        BWRAP_ARGS+=(--unshare-user --unshare-net)
    fi
    # A nested session's control namespace comes from unshare instead (see
    # the launch at the end), and bwrap joins it, as on the networked path.
fi
```

Ruleset: in the `NFT_RULES` block, immediately before the table's closing `echo "}"` (after the forward chain's closing `echo "    }"`):

```bash
        # A's side of the nested payload: what B may reach on A, and the
        # masquerade for B's egress (lib/nestnet.sh).
        if [[ "$SBX_NESTED" == "true" ]]; then
            sbx_nestnet_a_rules "$([[ ${#NET_PROFILES[@]} -gt 0 ]] && echo true || echo false)" "$NEST_TCP" "$NEST_UDP"
        fi
```

dnsmasq heredoc (~line 1914): change the line `    --listen-address=$SBX_DNS_ADDR \\` to

```
    --listen-address=$SBX_DNS_ADDR${DNSMASQ_NEST_LISTEN:+ $DNSMASQ_NEST_LISTEN} \\
```

An empty `DNSMASQ_NEST_LISTEN` leaves the generated line byte-identical, which is what keeps the capability-dropping goldens unchanged.

- [ ] **Step 5: The nested prelude**

Immediately before the comment `# Generate the launch script with properly escaped BWRAP_ARGS.` (~line 2061), add:

```bash
# The payload namespace B, set up by launch.sh in A before anything else, so
# that A's veth address exists when dnsmasq binds it. See lib/userns.sh and
# lib/nestnet.sh for what each step is for.
NEST_PRELUDE=""
if [[ "$SBX_NESTED" == "true" ]]; then
    if [[ "$SBX_NETNS" == "true" ]]; then
        NEST_MAP='sbx_userns_map_identity "$SBX_B_PID"'
        NEST_B_DNS=""
        if [[ ${#NET_PROFILES[@]} -gt 0 ]]; then
            NEST_B_DNS="$SBX_DNS_ADDR"
        fi
        NEST_NET=$(cat <<EOF
sbx_nestnet_wire "\$SBX_B_PID" || nest_fail "could not connect the payload network namespace. Is the veth module available? Run: sbx --doctor"
sbx_nestnet_b_rules "\$SBX_B_PID" "$NEST_B_DNS" "$NEST_TCP" "$NEST_UDP" || nest_fail "could not load the payload loopback rules."
sbx_nestnet_relays "$NEST_TCP" "$NEST_UDP" || nest_fail "could not start the host-port relays."
EOF
)
    else
        NEST_MAP='sbx_userns_map_outer_ids "$SBX_B_PID"'
        NEST_NET='sbx_nestnet_lo_up "$SBX_B_PID" || nest_fail "could not bring up the payload loopback."'
    fi
    NEST_PRELUDE=$(cat <<EOF
# The payload namespace B, nested in this one (lib/userns.sh, lib/nestnet.sh).
source $(printf '%q' "$SCRIPT_DIR/lib/userns.sh")
source $(printf '%q' "$SCRIPT_DIR/lib/nestnet.sh")
nest_fail() {
    echo "Error: \$1" >&2
    exit 1
}
trap 'sbx_nestnet_release; sbx_userns_release "\$SBX_B_PID"' EXIT
sbx_userns_hold || nest_fail "could not create the payload user namespace."
$NEST_MAP || nest_fail "could not map the payload user namespace."
$NEST_NET
# bwrap moves the payload into B through this descriptor (--userns2 below).
exec {SBX_BFD}</proc/\$SBX_B_PID/ns/user
EOF
)
fi
```

`sbx_nestnet_relays "" ""` starts nothing and returns 0 at once; `sbx_nestnet_b_rules` with all three empty returns 0 without touching B. So the three lines are safe for sessions with no host ports or no DNS.

- [ ] **Step 6: Launch-script assembly**

Replace the block from `{` `echo "#!/bin/bash"` through the `printf "%q\n" "$SESSION_SCRIPT" >> "$LAUNCH_SCRIPT"` line with (keep the long setpriv comment exactly where it is, above the `if [[ "$CAPS_KEEP" != "true" ]]`):

```bash
{
    echo "#!/bin/bash"
    echo "# Start the sandbox"
    if [[ -n "$NEST_PRELUDE" ]]; then
        echo "$NEST_PRELUDE"
    fi
    if [[ -n "$NET_PRELUDE" ]]; then
        echo "$NET_PRELUDE"
    fi
} > "$LAUNCH_SCRIPT"

# With a net profile the script must outlive bwrap to reap dnsmasq, and with
# a nested payload to release B and the relays, so it cannot exec. A
# host-ports-only session without nesting has nothing to reap, so it can.
if [[ "$SBX_NESTED" == "true" ]]; then
    # bwrap starts in B's network namespace but A's user namespace, so every
    # mount it makes belongs to A; --userns2 then moves the payload into B.
    printf 'nsenter --net=/proc/"$SBX_B_PID"/ns/net -- bwrap ' >> "$LAUNCH_SCRIPT"
elif [[ ${#NET_PROFILES[@]} -gt 0 ]]; then
    printf "bwrap " >> "$LAUNCH_SCRIPT"
else
    printf "exec bwrap " >> "$LAUNCH_SCRIPT"
fi
for arg in "${BWRAP_ARGS[@]}"; do
    printf "%q " "$arg" >> "$LAUNCH_SCRIPT"
done
if [[ "$SBX_NESTED" == "true" ]]; then
    # --userns2 alone. The man page pairs it with --userns; that form fails
    # here ("Joining the specified user namespace failed").
    printf -- '--userns2 "$SBX_BFD" ' >> "$LAUNCH_SCRIPT"
fi
# (existing setpriv comment, unchanged)
if [[ "$CAPS_KEEP" != "true" ]]; then
    printf "setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all -- " >> "$LAUNCH_SCRIPT"
elif [[ "$SBX_NESTED" == "true" ]]; then
    # A mount namespace B owns, so podman can mount; the mounts inherited
    # from A stay locked. A capability-dropping payload could not run this
    # and has no use for it.
    printf "unshare --mount -- " >> "$LAUNCH_SCRIPT"
fi
printf "%q\n" "$SESSION_SCRIPT" >> "$LAUNCH_SCRIPT"
```

shellcheck will flag the single-quoted `$SBX_B_PID`/`$SBX_BFD` (SC2016, info level, not an error); they are meant literally. Leave them.

- [ ] **Step 7: Start A for sessions without networking**

In the launch at the end (~line 2167), the final `else` branch becomes:

```bash
else
    echo "Starting session $SESSION_ID..."
    if [[ "$SBX_NESTED" == "true" ]]; then
        # The control namespace A for a session without networking: this user
        # mapped to 0 in a new user namespace, and an empty network namespace.
        # B gives the payload its host identity back (sbx_userns_map_outer_ids).
        unshare --user --map-root-user --net -- "$LAUNCH_SCRIPT"
    else
        "$LAUNCH_SCRIPT"
    fi
fi
```

- [ ] **Step 8: Snapshot harness — capture at unshare, and a new case**

In `tests/snapshot.bats`, replace the `unshare` stub with one that captures when its command is launch.sh (a session without networking) and passes through otherwise (userns: full's `unshare … -- pasta …`):

```bash
    cat > "$STUB/unshare" <<'EOF'
#!/bin/bash
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
```

Add a case after "snapshot: caps keep and docker api":

```bash
@test "snapshot: caps keep without networking" {
    run_case podman-nonet --fs podman
    check_snapshot podman-nonet
}
```

- [ ] **Step 9: Run everything and review the goldens**

Run: `bats tests/nested.bats`
Expected: all `ok` (podman tests may `skip` only if the host lacks podman or the alpine image; on this machine they run).

Run: `bats tests/snapshot.bats`
Expected: exactly three tests fail — "caps keep and docker api", "userns full", and the new "caps keep without networking" (no golden yet). Every other case passes unregenerated. If any other case fails, stop: a capability-dropping launch changed, which this task must not do.

Regenerate only those three:

```bash
SBX_UPDATE_SNAPSHOTS=1 bats tests/snapshot.bats -f 'caps keep|userns full'
git diff --stat tests/snapshots/
git diff tests/snapshots/
```

Expected diff, and nothing else: in `podman/` and `userns-full/`, `launch.sh` gains the nested prelude (with `@REPO@/lib/…` paths), `nsenter --net=… -- bwrap`, `--userns2 "$SBX_BFD"`, `unshare --mount --`, and dnsmasq's second `--listen-address=10.200.0.1`; `dns_rules.nft` gains the `input` and `postrouting` chains. `tests/snapshots/podman-nonet/` is new and holds `unshare.args` (`--user --map-root-user --net -- …/launch.sh`) and a launch.sh with `sbx_userns_map_outer_ids`. Put this summary in the commit message.

Run: `bats tests/ && shellcheck -S error sbx sbx-profile lib/*.sh`
Expected: all pass; shellcheck silent.

- [ ] **Step 10: Commit**

```bash
git add sbx tests/snapshot.bats tests/nested.bats tests/snapshots/
git commit -m "Nest caps: keep sessions: payload in B, ro and firewall enforced from A

<body: what changes for caps: keep sessions, the red tests that now pass,
the golden diff summary, trailers>"
```

---

### Task 5: Every session nested — remove the condition

**Files:**
- Modify: `sbx` (every `SBX_NESTED` branch; comments listed below)
- Modify: `tests/nested.bats` (capability-dropping twins)
- Modify: `tests/hardening.bats` (a stale comment)
- Regenerate: `tests/snapshots/plain/`, `mounts/`, `stacked-net/`, `host-ports/`

**Interfaces:**
- Consumes: everything from Task 4.
- Produces: `sbx` without `SBX_NESTED`. `DNSMASQ_NEST_LISTEN` is removed too (dnsmasq always listens on both addresses).

- [ ] **Step 1: Write the failing tests**

Append to `tests/nested.bats` the capability-dropping twins. They use `--fs drop`, which has the same mounts as `keep` without `caps`:

```bash
@test "capless: the payload holds no capabilities" {
    payload "--fs drop" <<'EOF'
grep -E '^Cap(Eff|Bnd|Amb)' /proc/self/status > /out/caps.txt
EOF
    [ "$(grep -c '0000000000000000' "$HOSTDIR/caps.txt")" -eq 3 ]
}

@test "capless without networking: the payload sees the host uid" {
    payload "--fs drop" <<'EOF'
id -u > /out/id.txt
EOF
    [ "$(cat "$HOSTDIR/id.txt")" = "$(id -u)" ]
}

@test "capless with networking: the payload sees uid 0, as before" {
    requires_net
    payload "--fs drop --net nothing" <<'EOF'
id -u > /out/id.txt
EOF
    [ "$(cat "$HOSTDIR/id.txt")" = "0" ]
}

@test "capless without networking: the payload is in its own user namespace, nested" {
    payload "--fs drop" <<'EOF'
cat /proc/self/uid_map > /out/map.txt
EOF
    # B's map is "<host uid> 0 1": the payload's uid maps to A's 0, not to
    # the host's uid directly, as it did when bwrap created the namespace.
    [ "$(tr -s ' ' < "$HOSTDIR/map.txt" | sed 's/^ //')" = "$(id -u) 0 1" ]
}

@test "capless: a granted TCP host port answers at 127.0.0.1 and localhost" {
    requires_pasta
    start_host_tcp
    payload "--fs drop --host-port $TCP_PORT" <<EOF
socat -T2 - TCP:127.0.0.1:$TCP_PORT </dev/null > /out/ip.txt
socat -T2 - TCP:localhost:$TCP_PORT </dev/null > /out/name.txt
EOF
    [ "$(cat "$HOSTDIR/ip.txt")" = "host-tcp" ]
    [ "$(cat "$HOSTDIR/name.txt")" = "host-tcp" ]
}

@test "capless: a granted UDP host port answers at 127.0.0.1" {
    requires_pasta
    start_host_udp
    payload "--fs drop --host-port $UDP_PORT/udp" <<EOF
echo q | socat -T2 - UDP:127.0.0.1:$UDP_PORT > /out/udp.txt
EOF
    [ "$(cat "$HOSTDIR/udp.txt")" = "host-udp" ]
}

@test "capless with networking: DNS answers through resolv.conf and a denied target stays denied" {
    requires_net
    requires_denied_target
    allowed_ip_profile
    payload "--fs drop --net allowip" <<'EOF'
getent ahostsv4 example.com > /out/dns.txt
if curl -s -o /dev/null -m 5 http://1.1.1.1/; then echo BAD; else echo GOOD; fi > /out/denied.txt
EOF
    [ -s "$HOSTDIR/dns.txt" ]
    [ "$(cat "$HOSTDIR/denied.txt")" = "GOOD" ]
}
```

- [ ] **Step 2: Run to see the red**

Run: `bats tests/nested.bats`
Expected FAIL: "capless without networking: the payload is in its own user namespace, nested" (today bwrap maps `<host uid> <host uid> 1`). The other new tests are parity guards and pass before and after; say so in the report.

- [ ] **Step 3: Remove the condition**

In `sbx`:

1. Delete `SBX_NESTED=$CAPS_KEEP` and the `DNSMASQ_NEST_LISTEN` block (keep `NEST_TCP`/`NEST_UDP`). Update the comment above them to drop "caps:keep sessions first".
2. dnsmasq heredoc line becomes `    --listen-address=$SBX_DNS_ADDR --listen-address=$SBX_NEST_A_ADDR \\`.
3. Ruleset: the `if [[ "$SBX_NESTED" == "true" ]]` around `sbx_nestnet_a_rules` goes; the call stays.
4. Namespace section: the whole `else` branch that added `--unshare-user --unshare-net` goes. The `if [[ "$SBX_NETNS" == "true" ]]; then … fi` remains for the `_CONTAINERS_*` variables; rewrite its opening comment: every session's user and network namespaces now come from A (pasta's, or `unshare`'s without networking), and bwrap joins A without creating a user namespace.
5. `NEST_PRELUDE`: the outer `if [[ "$SBX_NESTED" == "true" ]]` goes; its body always runs.
6. Launch-script assembly: the `exec bwrap`/`bwrap` branches go. It always prints the `nsenter … -- bwrap ` prefix and `--userns2 "$SBX_BFD" `. The capability tail becomes `if [[ "$CAPS_KEEP" != "true" ]]; then setpriv …; else unshare --mount -- ; fi`. Rewrite the "cannot exec" comment: launch.sh always outlives bwrap, to release B and the relays (and dnsmasq with a net profile).
7. Launch: the no-networking branch always runs `unshare --user --map-root-user --net -- "$LAUNCH_SCRIPT"`.

Then update comments that the change makes false (read each; rewrite only what is now wrong):
- `sbx` ~line 963-972: "When a network namespace is used, pasta creates the user and net namespaces. bwrap joins them" — now true of every session, with `unshare` standing in for pasta without networking.
- `sbx` ~1010-1034, the CAP_SETPCAP comment: "bwrap leaves full whenever it JOINS an existing user namespace instead of creating one — i.e. the --net path" → every path now; and "The "caps": "keep" opt-out needs --cap-add ALL in BOTH modes … Where bwrap creates the user namespace itself (the no-net path)…" → bwrap no longer creates one on any path; `--cap-add ALL` is needed because bwrap otherwise drops nothing it joins with… state what is true now: with `--userns2`, bwrap enters B holding B's full set, and `--cap-add ALL` / `--cap-drop ALL` decide what the payload keeps (measured 2026-09-21).
- `sbx` ~2061-2063: "pasta runs this inside the session's user and net namespaces" → launch.sh runs in A: pasta's namespaces, or `unshare`'s for a session without networking.
- `tests/hardening.bats` ~line 76-85, the "REGRESSION GUARDS" comment: "bwrap zeroes every capability set … whenever it creates the user namespace itself, which is what the no-net path does" → no path has bwrap create the user namespace any more; these tests now guard `--cap-drop ALL` plus `setpriv` on the no-net path.

- [ ] **Step 4: Run and regenerate the remaining goldens**

Run: `bats tests/nested.bats tests/hardening.bats tests/sessions.bats tests/join.bats tests/persistent-cli.bats tests/copy-mounts.bats`
Expected: all `ok`.

Run: `bats tests/snapshot.bats`
Expected: "plain", "every mount kind…", "stacked net profiles…", "host ports without a net profile" fail; the three caps-keep cases and the determinism test pass. Nothing else.

```bash
SBX_UPDATE_SNAPSHOTS=1 bats tests/snapshot.bats -f 'plain fs profile|every mount kind|stacked net|host ports without'
git diff --stat tests/snapshots/
git diff tests/snapshots/
```

Expected diff: `plain/` and `mounts/` lose `bwrap.args` (launch.sh is no longer executed; the unshare stub captures first) and gain `unshare.args`; their launch.sh loses `--unshare-user --unshare-net` and `exec`, and gains the prelude with `sbx_userns_map_outer_ids`, the `nsenter` prefix and `--userns2`. `stacked-net/` and `host-ports/` launch.sh gain the prelude with `sbx_userns_map_identity`, wiring, B's rules and (host ports) relays; their `dns_rules.nft` gains `input`/`postrouting`; `stacked-net`'s dnsmasq gains the second listen address. Summarise this in the commit message.

Run: `bats tests/ && shellcheck -S error sbx sbx-profile lib/*.sh && grep -n SBX_NESTED sbx`
Expected: all tests pass, shellcheck silent, and the grep prints nothing.

- [ ] **Step 5: Commit**

```bash
git add sbx tests/nested.bats tests/hardening.bats tests/snapshots/
git commit -m "Nest every session's payload; remove the caps: keep condition

<body: one environment, what changed for capability-dropping sessions
(nested identity map, payload DNS only through dnsmasq, a forwarded port's
bind now succeeds), golden diff summary, trailers>"
```

---

### Task 6: Surfaces — warning, dry run, README

**Files:**
- Modify: `sbx:809-812` (caps-keep launch warning)
- Modify: `lib/render.sh:54` (Security line)
- Modify: `lib/resolve.sh:122-131` (the comment describing `caps`/`userns`)
- Modify: `README.md` (threat model ~26-53, profile tables ~157 and ~203, "Checking your setup" ~80-93, "Reaching Host Services" ~562)
- Test: `tests/hardening.bats`, `tests/render.bats`

**Interfaces:**
- Consumes: the behaviour from Tasks 4-5.
- Produces: user-facing text only.

- [ ] **Step 1: Write the failing tests**

`tests/hardening.bats`, "a caps keep session warns on stderr": keep the existing assertion and add, before it,

```bash
    if [[ "$output" == *"NOT enforceable"* ]]; then
        echo "the warning still claims ro and the firewall are lost" >&2
        return 1
    fi
```

`tests/render.bats`, test "profiles and security": its second Security assertion becomes

```bash
    [ "$(line Security)" = "Security   capabilities KEPT in the payload namespace (~/.config/sbx/profiles/fs/k.json) · userns full · docker API" ]
```

If `tests/dry-run.bats` asserts the old `capabilities KEPT (` text anywhere (`grep -n "capabilities KEPT" tests/*.bats`), update it the same way.

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/hardening.bats -f 'warns'; bats tests/render.bats -f 'profiles and security'`
Expected: both FAIL.

- [ ] **Step 3: Implement the text**

`sbx` warning:

```bash
if [[ "$CAPS_KEEP" == "true" ]]; then
    echo "Note: profile '$(basename "$CAPS_PROFILE" .json)' retains capabilities inside the payload's own namespace." >&2
    echo "  ro mounts and the egress firewall are still enforced from outside it; the payload can" >&2
    echo "  create further namespaces and hide paths from itself." >&2
fi
```

(The hardening test matches `retains capabilities`; keep that phrase.)

`lib/render.sh:54`: `"capabilities KEPT (…)"` → `"capabilities KEPT in the payload namespace (\($d.security.caps_profile | tilde))"`.

`lib/resolve.sh` comment on `"caps": "keep"`: replace any claim that it costs `ro`/firewall enforcement with: capabilities are held inside the payload namespace B; mounts and the ruleset belong to A and stay out of reach.

README:

- Threat model, replace "In sessions (without `"caps": "keep"`), this means:" with "In every session, this means:".
- Replace the `ro` bullet with:
  ```
  - **`ro` mounts are read-only.** bwrap makes every mount in the session's
    control namespace and runs the payload in a user namespace nested inside
    it. A mount inherited across that boundary is locked: it cannot be
    remounted or unmounted from inside, whatever capabilities the payload
    holds.
  ```
- Replace the firewall bullet with:
  ```
  - **The egress allow-list is not removable.** `nft` and `dnsmasq` run in
    the control namespace, outside the sandbox's PID and mount namespaces.
    The payload has its own network namespace behind a veth pair; it cannot
    see the ruleset, change it, or signal the resolver.
  ```
- Caveats: replace the `caps: keep` bullet with:
  ```
  - **Sessions with `"caps": "keep"`** — including `fs/podman` and
    `fs/podman-full` — hold capabilities inside the payload's own namespace.
    They can create further namespaces and hide paths from themselves with
    over-mounts; they cannot write `ro` mounts or change the firewall. Such
    sessions print a note at launch.
  ```
- Both profile tables' `caps` row: replace "costs the read-only-mount and firewall guarantees" with "capabilities stay inside the payload's namespace; `ro` mounts and the firewall still hold".
- "Checking your setup", after the paragraph on user namespaces, add:
  ```
  For networked sessions it also checks that the running kernel can load the
  `veth` module, which joins the sandbox's network namespace to the one that
  holds its firewall. After a kernel upgrade that check fails until you
  reboot.
  ```
- "Reaching Host Services", replace the "Ports the sandbox binds itself are unaffected…" paragraph with:
  ```
  **Ports the sandbox binds itself are unaffected**, as long as they are not
  also forwarded. A sandbox can serve on `127.0.0.1:10000` while reaching the
  host's service on `127.0.0.1:10001`. If it binds a port it also forwards,
  the bind succeeds, but its own connections to `127.0.0.1:<port>` still
  reach the host service, not its own listener.
  ```

- [ ] **Step 4: Run to verify**

Run: `bats tests/ && shellcheck -S error sbx sbx-profile lib/*.sh`
Expected: all pass; shellcheck silent.

- [ ] **Step 5: Commit**

```bash
git add sbx lib/render.sh lib/resolve.sh README.md tests/hardening.bats tests/render.bats
git commit -m "Say what nested sessions guarantee: warning, dry run, README

<body, trailers>"
```

---

### Task 7 (manual, the user): Ubuntu 24.04 before merging

Not for a subagent: it needs an Ubuntu 24.04 machine. On one, with this branch checked out:

1. `./sbx --doctor` — record the output.
2. `bats tests/userns.bats tests/nestnet.bats tests/nested.bats tests/hardening.bats`.
3. If sessions without networking fail at `unshare --user --map-root-user --net` (AppArmor's `apparmor_restrict_unprivileged_userns`), or B cannot be created inside A, record the exact error. The fix is an addition to the AppArmor profile text `sbx --doctor` already prints, verified on that machine before merging.

## Self-Review

- **Spec coverage.** One environment (Tasks 4-5); identity per shape (Task 1 `map_identity`/`map_outer_ids`, tests in Tasks 4-5); `unshare --mount` for `caps: keep` only (Task 4 Step 6); `lib/userns.sh` (Task 1); `lib/nestnet.sh` wiring, A's input and postrouting chains, DNS on both addresses, relays, B's convenience rules (Task 2, engaged in Task 4); launch order with wiring before dnsmasq (Task 4 Step 6: NEST_PRELUDE before NET_PRELUDE); teardown with trap and pdeathsig (Tasks 1, 2, 4); dependencies and `veth` in doctor, preflight and dry run (Task 3); dry-run Security wording, README, launch note (Task 6); goldens regenerated only in Tasks 4 and 5 with reviewed diffs; sequencing checkpoint then uniform (Tasks 4, 5); Ubuntu gate (Task 7). Testing section: unit (Tasks 1-2), every-session ro/caps/identity (Tasks 4-5), networked parity (Tasks 4-5), attacks from B (Task 2 in-namespace, Task 4 end-to-end), containers incl. overlay (Task 4).
- **Deviation from the spec, recorded there:** `socat` is in the `net` group, required for every networked session rather than only those granting host ports (the design's "Surfaces that change" was updated to match).
- **Names.** `SBX_B_PID`, `SBX_BFD`, `SBX_NEST_RELAY_PIDS`, `SBX_NEST_A_IF`/`B_IF`/`A_ADDR`/`B_ADDR`/`PREFIX`, `sbx_userns_{hold,write_map,map_identity,map_outer_ids,release}`, `sbx_nestnet_{a_rules,lo_up,wire,b_rules,relays,release}`, `sbx_deps_{kernel_release,veth_ok,veth_explain}`, `SBX_NESTED` (Task 4 only), `NEST_TCP`/`NEST_UDP`/`NEST_PRELUDE`/`NEST_MAP`/`NEST_NET`/`NEST_B_DNS`/`DNSMASQ_NEST_LISTEN` — used consistently across tasks.
