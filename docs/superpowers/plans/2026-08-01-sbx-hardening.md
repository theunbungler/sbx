# sbx Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make sbx hold against adversarial code and an adversarial project directory, by removing the capabilities that let a sandbox rewrite its own `ro` mounts and delete its own egress firewall.

**Architecture:** `launch.sh` becomes the privileged setup stage — it runs inside pasta's namespaces with capabilities and starts `nft` and `dnsmasq` there, outside the sandbox's PID and mount namespaces. The payload then runs under `bwrap --cap-drop ALL` plus a `setpriv` bounding-set drop. Profiles that genuinely need nested user namespaces (podman) opt back into capabilities explicitly and print a warning.

**Tech Stack:** bash, bubblewrap, pasta (passt), nftables, dnsmasq, util-linux (`setpriv`, `unshare`), jq, git, bats, shellcheck.

## Global Constraints

- **No custom code.** Stock tools only: `bwrap`, `pasta`, `nft`, `dnsmasq`, `abduco`/`dtach`, `jq`, `setpriv`, `unshare`, `git`. No new binaries, no compiled artifacts, no bespoke daemons. A fix requiring custom code is documented as a residual risk instead.
- **Spec:** `docs/superpowers/specs/2026-08-01-sbx-hardening-design.md`. Read it before Task 1.
- **Threat model:** both the code inside the sandbox and the project directory are adversarial. The host user account is the asset.
- **shellcheck must stay clean:** `shellcheck sbx lib/copy-mounts.sh` exits 0 after every task.
- **bats must stay green:** `bats tests/` passes after every task.
- **Short `HOME` in e2e tests.** Session sockets live at `$HOME/.local/state/sbx/<id>/session.sock` and blow the ~108-char `sun_path` limit under `$BATS_TEST_TMPDIR`. Always use `mktemp -d /tmp/sbxh.XXXXXX`. This is why the existing suites do it.
- **`set -e` is active in `sbx`.** A bare `[[ test ]] && action` as the last statement of a loop body or function makes the whole script exit when the test is false. Use explicit `if` blocks in every loop this plan adds.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `sbx` | All orchestration changes | 1–8 |
| `profiles/fs/podman.json`, `profiles/fs/podman-full.json` | Declare `"caps": "keep"` | 3 |
| `profiles/cli/claude.json` | Drop rw on `$HOME/.local`, `$HOME/.nvm` | 8 |
| `tests/hardening.bats` | **New.** Capabilities, environment, mount masks | 1, 2, 3, 4, 5 |
| `tests/project-profiles.bats` | **New.** Project-profile confirmation | 6 |
| `tests/persistent-cli.bats` | Trust variable so existing fixtures keep working | 6 |
| `README.md` | Threat model, `caps`/`passthrough` schema, residual risks | 9 |

`sbx` is a single 966-line script. It stays that way — the change is behavioural, not structural, and splitting it here would obscure the security review this work exists to enable.

---

### Task 1: Capless no-net sandbox and `--die-with-parent`

Establishes the cap-drop flags and the test harness on the branch where nothing can regress: no-net sandboxes are already capless, so this locks in current behaviour before Task 2 changes the net path.

**Files:**
- Modify: `sbx:320-325` (no-net branch)
- Create: `tests/hardening.bats`

**Interfaces:**
- Produces: `tests/hardening.bats` with `setup()`, `teardown()`, `run_sbx()`, and the `caps` fs profile fixture mounting `$HOSTDIR` rw at `/out` and `$RODIR` ro at `/ro`. Tasks 2–5 add tests to this same file and reuse these helpers unchanged.

- [ ] **Step 1: Write the failing test**

Create `tests/hardening.bats`:

```bash
#!/usr/bin/env bats

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"

    # NOT $BATS_TEST_TMPDIR — it embeds the test name, and sbx's session
    # socket at $HOME/.local/state/sbx/<session-id>/session.sock would blow
    # the ~108-char sun_path limit. Keep this path short.
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/p"
    HOSTDIR="$ROOT/o"
    RODIR="$ROOT/r"
    mkdir -p "$HOME" "$PROJ/.sbx/profiles/fs" "$PROJ/.sbx/profiles/net" "$HOSTDIR" "$RODIR"
    echo readonly > "$RODIR/f.txt"

    # Task 6 adds a confirmation prompt for ./.sbx profiles; these fixtures
    # are ours, so opt out of it for the whole suite.
    export SBX_TRUST_PROJECT_PROFILES=1

    cat > "$PROJ/.sbx/profiles/fs/caps.json" <<EOF
{"description":"test","mounts":[
  {"source":"$HOSTDIR","dest":"/out","perm":"rw"},
  {"source":"$RODIR","dest":"/ro","perm":"ro"}
]}
EOF
}

teardown() {
    [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]] && rm -rf "$ROOT"
}

# sbx ends in `abduco -c` (or the dtach fallback), which needs a pty;
# `script -qec` supplies one non-interactively.
run_sbx() {
    ( cd "$PROJ" && script -qec "$SBX $1 -- /bin/sh -c '$2'" /dev/null >/dev/null 2>&1 )
}

@test "a no-net sandbox holds no capabilities" {
    run_sbx "--fs caps" "grep '^CapEff' /proc/self/status > /out/caps.txt"
    [[ "$(cat "$HOSTDIR/caps.txt")" == *"0000000000000000" ]]
}

@test "a no-net sandbox holds an empty capability bounding set" {
    run_sbx "--fs caps" "grep '^CapBnd' /proc/self/status > /out/bnd.txt"
    [[ "$(cat "$HOSTDIR/bnd.txt")" == *"0000000000000000" ]]
}

@test "a ro mount cannot be remounted writable" {
    run_sbx "--fs caps" "mount -n -o remount,bind,rw /ro 2>/dev/null && echo BAD > /out/r.txt || echo GOOD > /out/r.txt"
    [ "$(cat "$HOSTDIR/r.txt")" = "GOOD" ]
}

@test "a ro mount source is not modified from inside" {
    run_sbx "--fs caps" "mount -n -o remount,bind,rw /ro 2>/dev/null; echo pwned > /ro/f.txt 2>/dev/null; true"
    [ "$(cat "$RODIR/f.txt")" = "readonly" ]
}
```

- [ ] **Step 2: Run the test to verify the bounding-set test fails**

Run: `bats tests/hardening.bats`

Expected: "a no-net sandbox holds no capabilities" PASSES (no-net was already capless), "holds an empty capability bounding set" FAILS — `CapBnd` is currently full because nothing drops it.

- [ ] **Step 3: Add the cap-drop flags to the no-net branch**

In `sbx`, replace the no-net branch (currently lines 320–325):

```bash
else
    # Without networking, bwrap creates its own namespaces.
    # No --uid/--gid: bwrap defaults to mapping the real UID/GID into the
    # new user namespace, so the sandbox sees the same user/HOME identity
    # as the host (matches what the --net branch already does via pasta).
    BWRAP_ARGS+=(--unshare-user --unshare-net)
fi
```

with:

```bash
else
    # Without networking, bwrap creates its own namespaces.
    # No --uid/--gid: bwrap defaults to mapping the real UID/GID into the
    # new user namespace, so the sandbox sees the same user/HOME identity
    # as the host (matches what the --net branch already does via pasta).
    BWRAP_ARGS+=(--unshare-user --unshare-net)
fi

# The payload never needs capabilities; only session setup does, and that
# happens outside the sandbox (see the launch-script generation below).
# --cap-drop ALL zeroes the effective set but leaves the bounding set full;
# setpriv in the wrapper empties that too. Both are applied because
# --cap-drop alone would let a setuid binary regain privilege if bwrap ever
# stopped setting no_new_privs.
if [[ "$CAPS_KEEP" != "true" ]]; then
    BWRAP_ARGS+=(--cap-drop ALL)
fi

# Reap the sandbox if sbx itself dies, rather than leaking a detached
# session with no supervisor.
BWRAP_ARGS+=(--die-with-parent)
```

`CAPS_KEEP` does not exist yet — Task 3 introduces it. Define it now, unset, so this branch is inert until then. Add immediately after `GUI_FLAG=false` (line 137):

```bash
CAPS_KEEP=false
```

- [ ] **Step 4: Add the setpriv drop to the no-net wrapper**

In `sbx`, replace the no-net wrapper generation (currently lines 926–932):

```bash
else
    cat > "$CAT_WRAPPER" <<EOF
#!/bin/bash
$DOCKER_API_START
$(printf "%q " "${COMMAND[@]}")
$DOCKER_API_STOP
EOF
fi
```

with:

```bash
elif [[ "$CAPS_KEEP" == "true" ]]; then
    cat > "$CAT_WRAPPER" <<EOF
#!/bin/bash
$DOCKER_API_START
$(printf "%q " "${COMMAND[@]}")
$DOCKER_API_STOP
EOF
else
    # setpriv empties the capability bounding set, which --cap-drop ALL
    # leaves intact. exec because a capless session has no docker-API
    # service to stop afterwards.
    cat > "$CAT_WRAPPER" <<EOF
#!/bin/bash
exec setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all -- \\
    $(printf "%q " "${COMMAND[@]}")
EOF
fi
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/hardening.bats`

Expected: all 4 tests PASS.

- [ ] **Step 6: Verify no regression and clean lint**

Run: `bats tests/ && shellcheck sbx lib/copy-mounts.sh`

Expected: all suites pass, shellcheck silent (exit 0).

- [ ] **Step 7: Commit**

```bash
git add sbx tests/hardening.bats
git commit -m "Drop capabilities and bounding set in no-net sandboxes"
```

---

### Task 2: Move privileged setup out of the sandbox

The core change. `nft` and `dnsmasq` move from `wrapper.sh` (inside the sandbox) to `launch.sh` (inside pasta's namespaces, outside bwrap), and the net-mode payload becomes capless.

**Files:**
- Modify: `sbx:290-318` (net branch), `sbx:860-947` (wrapper + launch generation), `sbx:949-962` (pasta invocation)
- Test: `tests/hardening.bats`

**Interfaces:**
- Consumes: `CAPS_KEEP` from Task 1.
- Produces: `NET_PRELUDE`, a shell fragment emitted into `launch.sh` that brings up `lo`, loads `$NFT_RULES`, starts dnsmasq and probes readiness, exporting `DNSMASQ_PID` for the teardown line appended after the bwrap call.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hardening.bats`:

```bash
# Networked tests need pasta and a usable default route; skip rather than
# fail on machines that have neither.
requires_net() {
    command -v pasta >/dev/null 2>&1 || skip "pasta not installed"
    ip route show default | grep -q . || skip "no default route"
}

net_fixture() {
    cat > "$PROJ/.sbx/profiles/net/tstnet.json" <<'EOF'
{"description":"test","dns":"1.1.1.1","allow":["example.com"],"ports":[443]}
EOF
}

@test "a networked sandbox holds no capabilities" {
    requires_net
    net_fixture
    run_sbx "--fs caps --net tstnet" "grep '^CapEff' /proc/self/status > /out/ncaps.txt"
    [[ "$(cat "$HOSTDIR/ncaps.txt")" == *"0000000000000000" ]]
}

@test "a networked sandbox cannot flush the egress firewall" {
    requires_net
    net_fixture
    run_sbx "--fs caps --net tstnet" "nft flush ruleset 2>/dev/null && echo BAD > /out/n.txt || echo GOOD > /out/n.txt"
    [ "$(cat "$HOSTDIR/n.txt")" = "GOOD" ]
}

@test "a networked sandbox cannot remount a ro mount writable" {
    requires_net
    net_fixture
    run_sbx "--fs caps --net tstnet" "mount -n -o remount,bind,rw /ro 2>/dev/null && echo BAD > /out/nr.txt || echo GOOD > /out/nr.txt"
    [ "$(cat "$HOSTDIR/nr.txt")" = "GOOD" ]
}

@test "a networked sandbox cannot see the dnsmasq process" {
    requires_net
    net_fixture
    run_sbx "--fs caps --net tstnet" "ps ax > /out/ps.txt 2>/dev/null || true"
    ! grep -q dnsmasq "$HOSTDIR/ps.txt"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/hardening.bats -f networked`

Expected: all 4 FAIL (or skip if the machine has no default route — in that case verify manually per Step 8 before continuing).

- [ ] **Step 3: Remove `--cap-add ALL` from the net branch**

In `sbx`, replace the net branch (currently lines 290–318) with:

```bash
if [[ -n "$NET_PROFILE" ]]; then
    # When networking is enabled, pasta creates the user and net namespaces.
    # bwrap joins them and provides filesystem isolation.
    #
    # pasta maps the host uid to 0 inside the namespace. bwrap does NOT drop
    # inherited capabilities when it is not the namespace's creator, so
    # without an explicit --cap-drop ALL the payload would run as uid 0 with
    # a full ambient set — able to remount every ro bind rw and to flush the
    # nftables ruleset. nft and dnsmasq now run in launch.sh, outside the
    # sandbox, so nothing in here needs privilege.
    if [[ "$CAPS_KEEP" == "true" ]]; then
        BWRAP_ARGS+=(--cap-add ALL)

        # podman/crun decide rootless-vs-rootful by checking geteuid()==0,
        # not actual privilege. --cap-add ALL above makes the sandboxed
        # process look like real root to podman, so it skips its normal
        # single-UID-mapping fallback and assumes a genuine system gid=5
        # exists for its default devpts mount — which fails with EINVAL.
        # These containers/common env vars are the documented override.
        # In userns-full mode they are exactly wrong: there podman MUST run
        # rootful-in-namespace, and forcing the rootless code path would
        # resurrect the single-UID limitation the outer userns removes.
        if [[ "$USERNS_FULL" != "true" ]]; then
            BWRAP_ARGS+=(
                --setenv _CONTAINERS_USERNS_CONFIGURED done
                --setenv _CONTAINERS_ROOTLESS_UID "$(id -u)"
                --setenv _CONTAINERS_ROOTLESS_GID "$(id -g)"
            )
        fi
    fi
else
```

Leave the `else` body from Task 1 unchanged.

- [ ] **Step 4: Build the setup prelude and emit it into `launch.sh`**

In `sbx`, replace the net-mode wrapper generation (currently lines 860–924, from `if [[ -n "$NET_PROFILE" ]]; then` through the `EOF` closing the net wrapper heredoc) with the prelude construction below. The wrapper keeps only the payload:

```bash
NET_PRELUDE=""
if [[ -n "$NET_PROFILE" ]]; then
    # Serialise per-domain flags for expansion inside the heredoc.
    if [[ "$ALLOW_ALL" == "true" ]]; then
        # Wildcard: forward everything, populate allowed4 for every answer.
        DNSMASQ_DOMAIN_FLAGS="--server=$DNS_UPSTREAM --nftset=//inet#sbx_filter#allowed4"
    else
        DNSMASQ_DOMAIN_FLAGS=$(printf '%s ' "${DNSMASQ_DOMAIN_ARGS[@]}")
    fi

    # Runs in launch.sh: inside pasta's namespaces, before bwrap, with the
    # capabilities nft and dnsmasq need. Everything started here lives
    # outside the sandbox's PID and mount namespaces, so the payload can
    # neither signal dnsmasq nor alter the ruleset.
    NET_PRELUDE=$(cat <<EOF
ip link set lo up >/dev/null 2>&1

# Hard-fail if nftables rules cannot be loaded — never proceed with open egress.
if ! NFT_ERR=\$(nft -f "$NFT_RULES" 2>&1); then
    echo "Error: nftables rules failed to load — aborting." >&2
    echo "  nft: \$NFT_ERR" >&2
    exit 1
fi

# dnsmasq on 127.0.0.1:53.
# All options are CLI flags: AppArmor's usr.sbin.dnsmasq profile restricts
# config-file paths to /etc/dnsmasq.d/*, making arbitrary paths unreadable.
# --conf-file=/dev/null  suppress any host /etc/dnsmasq.conf
# --filter-AAAA          return only A records; IPv6 egress is nft-dropped anyway
# --nftset               auto-populates @allowed4 from A-record answers
"$DNSMASQ_BIN" \\
    --conf-file=/dev/null \\
    -d \\
    --port=53 \\
    --listen-address=127.0.0.1 \\
    --bind-interfaces \\
    --no-resolv \\
    --no-hosts \\
    --filter-AAAA \\
    $DNSMASQ_DOMAIN_FLAGS \\
    > "$DNS_DIR/dnsmasq.log" 2>&1 &
DNSMASQ_PID=\$!

# The probe must query this session's dnsmasq, but launch.sh sees the host
# /etc/resolv.conf. A throwaway bwrap binds the session resolv.conf so the
# check is accurate and every setup failure still prints before the session
# multiplexer starts.
probe_dns() {
    bwrap --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \\
        --symlink usr/lib64 /lib64 --ro-bind /etc /etc \\
        --ro-bind "$DNS_DIR/resolv.conf" /etc/resolv.conf \\
        --proc /proc --dev /dev \\
        -- getent ahostsv4 "$TEST_DOMAIN" >/dev/null 2>&1
}

DNS_READY=false
for i in {1..20}; do
    if ! kill -0 \$DNSMASQ_PID 2>/dev/null; then
        echo "Error: dnsmasq failed to start:" >&2
        cat "$DNS_DIR/dnsmasq.log" >&2
        exit 1
    fi
    if [[ -z "$TEST_DOMAIN" ]] || probe_dns; then
        DNS_READY=true
        break
    fi
    sleep 0.5
done
if [[ "\$DNS_READY" != "true" ]]; then
    echo "Error: dnsmasq did not become ready (could not resolve '$TEST_DOMAIN')." >&2
    cat "$DNS_DIR/dnsmasq.log" >&2
    kill \$DNSMASQ_PID 2>/dev/null
    exit 1
fi
EOF
)
fi
```

- [ ] **Step 5: Reduce the wrapper to the payload**

Immediately after the block from Step 4, replace the remaining wrapper generation (the `if [[ -n "$NET_PROFILE" ]]` / `else` pair from Task 1 Step 4) with a single unconditional form — network setup no longer belongs here, so the wrapper is identical in both modes:

```bash
if [[ "$CAPS_KEEP" == "true" ]]; then
    cat > "$CAT_WRAPPER" <<EOF
#!/bin/bash
$USERNS_NET_SETUP
$DOCKER_API_START
$(printf "%q " "${COMMAND[@]}")
$DOCKER_API_STOP
EOF
else
    # setpriv empties the capability bounding set, which --cap-drop ALL
    # leaves intact. exec because a capless session has no docker-API
    # service to stop afterwards. USERNS_NET_SETUP and DOCKER_API_START are
    # both podman operations and are unreachable without capabilities, so
    # they are absent here by construction.
    cat > "$CAT_WRAPPER" <<EOF
#!/bin/bash
exec setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all -- \\
    $(printf "%q " "${COMMAND[@]}")
EOF
fi
chmod +x "$CAT_WRAPPER"
```

- [ ] **Step 6: Emit the prelude into `launch.sh` and reap dnsmasq**

In `sbx`, replace the launch-script generation (currently lines 936–947):

```bash
cat > "$LAUNCH_SCRIPT" <<EOF
#!/bin/bash
# Start the sandbox
EOF

printf "exec bwrap " >> "$LAUNCH_SCRIPT"
for arg in "${BWRAP_ARGS[@]}"; do
    printf "%q " "$arg" >> "$LAUNCH_SCRIPT"
done
printf "%q -c %q %q\n" "$SESSION_MUX" "$SESSION_SOCK" "$CAT_WRAPPER" >> "$LAUNCH_SCRIPT"

chmod +x "$LAUNCH_SCRIPT"
```

with:

```bash
{
    echo "#!/bin/bash"
    echo "# Start the sandbox"
    if [[ -n "$NET_PRELUDE" ]]; then
        echo "$NET_PRELUDE"
    fi
} > "$LAUNCH_SCRIPT"

# With networking the script must outlive bwrap to reap dnsmasq, so it
# cannot exec. Without networking there is nothing to clean up.
if [[ -n "$NET_PRELUDE" ]]; then
    printf "bwrap " >> "$LAUNCH_SCRIPT"
else
    printf "exec bwrap " >> "$LAUNCH_SCRIPT"
fi
for arg in "${BWRAP_ARGS[@]}"; do
    printf "%q " "$arg" >> "$LAUNCH_SCRIPT"
done
printf "%q -c %q %q\n" "$SESSION_MUX" "$SESSION_SOCK" "$CAT_WRAPPER" >> "$LAUNCH_SCRIPT"

if [[ -n "$NET_PRELUDE" ]]; then
    printf 'SBX_RC=$?\nkill $DNSMASQ_PID 2>/dev/null || true\nexit $SBX_RC\n' >> "$LAUNCH_SCRIPT"
fi

chmod +x "$LAUNCH_SCRIPT"
```

- [ ] **Step 7: Add `--no-map-gw` to both pasta invocations**

In `sbx`, in the launch block (currently lines 949–962), add `--no-map-gw` to both `pasta` calls. pasta defaults to translating the gateway address to the host's loopback, which would let the sandbox reach host-local services through `$HOST_GW`.

The userns-full call becomes:

```bash
        unshare --map-auto --map-root-user -- \
            pasta -f --config-net --netns-only --no-map-gw --interface "$HOST_IFACE" --no-ndp --no-dhcpv6 --no-ra -a "$HOST_IP" -g "$HOST_GW" -n "$HOST_MASK" -- "$LAUNCH_SCRIPT"
```

The plain net call becomes:

```bash
        pasta -f --config-net --no-map-gw --interface "$HOST_IFACE" --no-ndp --no-dhcpv6 --no-ra -a "$HOST_IP" -g "$HOST_GW" -n "$HOST_MASK" -- "$LAUNCH_SCRIPT"
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bats tests/hardening.bats`

Expected: all tests PASS. If the networked tests skip, verify manually:

```bash
cd /tmp && mkdir -p ptest/.sbx/profiles/net && cd ptest
cat > .sbx/profiles/net/t.json <<'EOF'
{"description":"t","dns":"1.1.1.1","allow":["example.com"],"ports":[443]}
EOF
SBX_TRUST_PROJECT_PROFILES=1 /path/to/sbx --net t -- /bin/sh -c \
  'grep ^CapEff /proc/self/status; nft flush ruleset && echo BAD || echo GOOD'
```

Expected: `CapEff: 0000000000000000` and `GOOD`.

- [ ] **Step 9: Verify egress filtering still works**

The point of the firewall is that it still filters. Run:

```bash
cd /tmp/ptest && SBX_TRUST_PROJECT_PROFILES=1 /path/to/sbx --net t -- /bin/sh -c \
  'getent ahostsv4 example.com >/dev/null && echo RESOLVE-OK || echo RESOLVE-FAIL;
   getent ahostsv4 github.com >/dev/null && echo LEAK || echo BLOCKED-OK'
```

Expected: `RESOLVE-OK` then `BLOCKED-OK`. A `RESOLVE-FAIL` means the readiness probe or dnsmasq relocation is broken; do not proceed until it passes.

- [ ] **Step 10: Verify no regression and clean lint**

Run: `bats tests/ && shellcheck sbx lib/copy-mounts.sh`

Expected: all suites pass, shellcheck silent.

- [ ] **Step 11: Commit**

```bash
git add sbx tests/hardening.bats
git commit -m "Move nft and dnsmasq setup outside the sandbox, drop payload caps"
```

---

### Task 3: Capability retention as an explicit, host-only opt-in

**Files:**
- Modify: `sbx:222-245` (profile feature-field scan), `profiles/fs/podman.json`, `profiles/fs/podman-full.json`
- Test: `tests/hardening.bats`

**Interfaces:**
- Consumes: `CAPS_KEEP` (Task 1), `USERNS_FULL`, `DOCKER_API`.
- Produces: `profile_is_project()` — takes a profile path, returns 0 when it resolves under `$PWD/.sbx`. Task 6 reuses it unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hardening.bats`:

```bash
@test "a profile with caps keep retains capabilities" {
    cat > "$PROJ/.sbx/profiles/fs/keep.json" <<EOF
{"description":"test","caps":"keep","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    # caps:keep is honoured only from host-owned profiles, so install it there.
    mkdir -p "$HOME/.config/sbx/profiles/fs"
    cp "$PROJ/.sbx/profiles/fs/keep.json" "$HOME/.config/sbx/profiles/fs/keep.json"
    rm "$PROJ/.sbx/profiles/fs/keep.json"

    run_sbx "--fs keep" "grep '^CapEff' /proc/self/status > /out/k.txt"
    [[ "$(cat "$HOSTDIR/k.txt")" != *"0000000000000000" ]]
}

@test "a caps keep session warns on stderr" {
    mkdir -p "$HOME/.config/sbx/profiles/fs"
    cat > "$HOME/.config/sbx/profiles/fs/keep.json" <<EOF
{"description":"test","caps":"keep","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    run bash -c "cd '$PROJ' && script -qec \"$SBX --fs keep -- /bin/true\" /dev/null 2>&1"
    [[ "$output" == *"retains capabilities"* ]]
}

@test "a project profile may not request caps" {
    cat > "$PROJ/.sbx/profiles/fs/evil.json" <<EOF
{"description":"test","caps":"keep","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    run bash -c "cd '$PROJ' && $SBX --fs evil -- /bin/true 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"may not set"* ]]
}

@test "a project profile may not request userns full" {
    cat > "$PROJ/.sbx/profiles/fs/evil2.json" <<EOF
{"description":"test","userns":"full","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    run bash -c "cd '$PROJ' && $SBX --fs evil2 -- /bin/true 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"may not set"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/hardening.bats -f "caps\|project profile may not"`

Expected: all 4 FAIL — `caps` is not read yet and project profiles are unrestricted.

- [ ] **Step 3: Add `profile_is_project` and rewrite the feature scan**

In `sbx`, add before the feature-field scan (before line 222):

```bash
# True when a resolved profile path lies inside the launch directory's
# .sbx tree — i.e. it was supplied by the project rather than by the user.
profile_is_project() {
    local abs proj
    abs=$(realpath -m "$1")
    proj=$(realpath -m "$PWD/.sbx")
    [[ "$abs" == "$proj/"* ]]
}
```

Then replace the feature-field scan (lines 222–245) with:

```bash
# --- Profile feature-field scan (phase 2 virt) ---
# Optional fields honored in any applied fs/cli profile:
#   "userns": "full"    -> run the whole session inside an outer user
#                          namespace carrying the user's full subordinate-
#                          UID range (multi-UID podman). Requires --net.
#                          Implies "caps": "keep".
#   "caps": "keep"      -> retain capabilities inside the sandbox. Needed
#                          for nested user namespaces (podman), and it
#                          costs the ro-mount and firewall guarantees.
#   "docker_api": true  -> start a podman docker-API socket for the session.
#
# None of these are honored from a project-supplied profile: a repository
# must never be able to talk its way back to the pre-hardening boundary,
# with or without the interactive confirmation added elsewhere.
USERNS_FULL=false
DOCKER_API=false
USERNS_PROFILE=""
CAPS_PROFILE=""
for profile in "${FS_PROFILES[@]}" "$CLI_PROFILE"; do
    [[ -z "$profile" ]] && continue

    p_userns=$(jq -r '.userns // empty' "$profile")
    p_caps=$(jq -r '.caps // empty' "$profile")
    p_docker=$(jq -r '.docker_api // false' "$profile")

    if profile_is_project "$profile"; then
        if [[ -n "$p_userns" || -n "$p_caps" || "$p_docker" == "true" ]]; then
            echo "Error: project profile '$profile' may not set 'userns', 'caps' or 'docker_api'." >&2
            echo "  Move it to $CONFIG_DIR/profiles/ if you intend to grant it." >&2
            exit 1
        fi
        continue
    fi

    if [[ "$p_userns" == "full" ]]; then
        USERNS_FULL=true
        USERNS_PROFILE="$profile"
        CAPS_KEEP=true
        CAPS_PROFILE="$profile"
    fi
    if [[ "$p_caps" == "keep" ]]; then
        CAPS_KEEP=true
        CAPS_PROFILE="$profile"
    fi
    if [[ "$p_docker" == "true" ]]; then
        DOCKER_API=true
    fi
done

if [[ "$USERNS_FULL" == "true" && -z "$NET_PROFILE" ]]; then
    echo "Error: profile '$USERNS_PROFILE' sets \"userns\": \"full\", which requires networking. Add --net <profile>." >&2
    exit 1
fi

if [[ "$CAPS_KEEP" == "true" ]]; then
    echo "Warning: profile '$(basename "$CAPS_PROFILE" .json)' retains capabilities — this session's" >&2
    echo "  ro mounts and egress firewall are NOT enforceable against code running inside it." >&2
fi
```

Remove the now-duplicated `CAPS_KEEP=false` initialiser added in Task 1 Step 3 only if it sits after this block; it must be initialised *before* the loop. Keep it at line 137 with the other flag defaults.

- [ ] **Step 4: Mark the podman profiles**

`profiles/fs/podman.json` — add `"caps": "keep"`:

```json
{
    "description": "Rootless podman (single-UID): persistent storage, tun, docker API socket",
    "caps": "keep",
    "docker_api": true,
    "mounts": [
        { "source": "/dev/net/tun", "dest": "/dev/net/tun", "perm": "dev" },
        { "source": "$HOME/.local/state/sbx/virt/containers", "dest": "$HOME/.local/state/sbx/virt/containers", "perm": "rw" }
    ]
}
```

`profiles/fs/podman-full.json` — add it explicitly too, even though `userns: full` implies it, so the cost is visible in the file:

```json
{
    "description": "Multi-UID podman (ns-root session; requires --net): full image fidelity, docker API socket",
    "userns": "full",
    "caps": "keep",
    "docker_api": true,
    "mounts": [
        { "source": "/dev/net/tun", "dest": "/dev/net/tun", "perm": "dev" },
        { "source": "$HOME/.local/state/sbx/virt/containers-full", "dest": "$HOME/.local/state/sbx/virt/containers-full", "perm": "rw" }
    ]
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/hardening.bats`

Expected: all tests PASS.

- [ ] **Step 6: Verify podman still works**

This is the functional risk the whole opt-in exists to manage. Run:

```bash
cd /tmp && /path/to/sbx --fs podman --net web -- podman run --rm docker.io/library/alpine echo container-ok
```

Expected: prints the capability warning, then `container-ok`. If the pull fails for network-policy reasons, `podman info` exiting 0 is an acceptable substitute — the point is that podman's userns setup succeeds.

- [ ] **Step 7: Verify no regression and clean lint**

Run: `bats tests/ && shellcheck sbx lib/copy-mounts.sh`

Expected: all suites pass, shellcheck silent.

- [ ] **Step 8: Commit**

```bash
git add sbx profiles/fs/podman.json profiles/fs/podman-full.json tests/hardening.bats
git commit -m "Gate capability retention behind an explicit host-only profile field"
```

---

### Task 4: Clear the environment, pass through by name

**Files:**
- Modify: `sbx:271-288` (after the base `BWRAP_ARGS` array)
- Test: `tests/hardening.bats`

**Interfaces:**
- Consumes: `BWRAP_ARGS`, `FS_PROFILES`, `CLI_PROFILE`.
- Produces: profile field `"passthrough": ["VAR", …]`, honoured on both fs and cli profiles.

**Deviation from the spec, deliberate:** the spec's ordering section says sbx-controlled variables win over profile `env`. Implementing that literally would break `profiles/fs/chrome.json`, which exists precisely to set `DISPLAY` and `XDG_RUNTIME_DIR`. The existing precedence (profile `env` overrides sbx defaults, `PATH` and `DOCKER_HOST` applied afterwards) is preserved; only `--clearenv` and the base allowlist are new. Update the spec's ordering list in Task 9.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hardening.bats`:

```bash
@test "a host secret does not reach the sandbox" {
    export SBX_TEST_SECRET=hunter2
    run_sbx "--fs caps" "printenv SBX_TEST_SECRET > /out/secret.txt 2>/dev/null; echo done > /out/done.txt"
    [ -f "$HOSTDIR/done.txt" ]
    [ ! -s "$HOSTDIR/secret.txt" ]
}

@test "the base environment set reaches the sandbox" {
    run_sbx "--fs caps" "printenv HOME > /out/home.txt"
    [ "$(cat "$HOSTDIR/home.txt")" = "$HOME" ]
}

@test "a profile passthrough entry forwards a host variable" {
    export SBX_TEST_SECRET=hunter2
    cat > "$PROJ/.sbx/profiles/fs/pass.json" <<EOF
{"description":"test","passthrough":["SBX_TEST_SECRET"],
 "mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    run_sbx "--fs pass" "printenv SBX_TEST_SECRET > /out/p.txt"
    [ "$(cat "$HOSTDIR/p.txt")" = "hunter2" ]
}

@test "an unset passthrough variable is not exported as empty" {
    unset SBX_TEST_ABSENT
    cat > "$PROJ/.sbx/profiles/fs/pass2.json" <<EOF
{"description":"test","passthrough":["SBX_TEST_ABSENT"],
 "mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    run_sbx "--fs pass2" "printenv SBX_TEST_ABSENT > /out/a.txt 2>/dev/null; echo done > /out/done2.txt"
    [ -f "$HOSTDIR/done2.txt" ]
    [ ! -s "$HOSTDIR/a.txt" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/hardening.bats -f "secret\|base environment\|passthrough"`

Expected: "a host secret does not reach the sandbox" FAILS (the secret is inherited); the passthrough tests FAIL (field unimplemented).

- [ ] **Step 3: Add the environment block**

In `sbx`, insert immediately after the base `BWRAP_ARGS` array definition (after line 288, before the `if [[ -n "$NET_PROFILE" ]]` branch):

```bash
# Environment policy: clear everything, then reintroduce by name.
# --clearenv is unconditional and has no opt-out — the host environment
# routinely carries API keys, tokens and SSH_AUTH_SOCK, none of which a
# sandbox should see unless a profile asks for them by name.
BWRAP_ARGS+=(--clearenv)

# Base set: what a shell needs to behave like a shell.
SBX_BASE_ENV=(HOME USER LOGNAME TERM COLORTERM LANG TZ SHELL)
for var in "${SBX_BASE_ENV[@]}"; do
    # Explicit if, not `[[ ]] &&`: under `set -e` a trailing false test on
    # the final iteration would exit the script.
    if [[ -n "${!var-}" ]]; then
        BWRAP_ARGS+=(--setenv "$var" "${!var}")
    fi
done

# Locale variables travel as a family; ${!LC_@} lists the set ones by name.
for var in ${!LC_@}; do
    if [[ -n "${!var-}" ]]; then
        BWRAP_ARGS+=(--setenv "$var" "${!var}")
    fi
done

# Profile-declared passthrough: forwards named host variables. Applied
# before the profile `env` block below, so an explicit `env` value wins.
for profile in "${FS_PROFILES[@]}" "$CLI_PROFILE"; do
    [[ -z "$profile" ]] && continue
    while IFS= read -r var; do
        [[ -z "$var" ]] && continue
        if [[ -n "${!var-}" ]]; then
            BWRAP_ARGS+=(--setenv "$var" "${!var}")
        fi
    done < <(jq -r '.passthrough[]?' "$profile")
done
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/hardening.bats`

Expected: all tests PASS.

- [ ] **Step 5: Verify an interactive shell is still usable**

`--clearenv` is the change most likely to degrade daily use in ways tests miss. Run:

```bash
cd /tmp && /path/to/sbx -- /bin/bash -c 'echo "TERM=$TERM HOME=$HOME PATH=$PATH"; ls >/dev/null && echo ls-ok'
```

Expected: `TERM` and `HOME` populated, `PATH` set by sbx, `ls-ok`.

- [ ] **Step 6: Verify no regression and clean lint**

Run: `bats tests/ && shellcheck sbx lib/copy-mounts.sh`

Expected: all suites pass, shellcheck silent. `${!LC_@}` is unquoted by design; if shellcheck raises SC2206-family noise, add a targeted `# shellcheck disable=` with a one-line reason rather than restructuring.

- [ ] **Step 7: Commit**

```bash
git add sbx tests/hardening.bats
git commit -m "Clear the sandbox environment and forward host vars by name"
```

---

### Task 5: Mask the state and config directories

**Files:**
- Modify: `sbx:287` (remove the early session bind), and after the GUI block (~line 775)
- Test: `tests/hardening.bats`

**Interfaces:**
- Consumes: `STATE_DIR`, `CONFIG_DIR`, `SESSION_DIR`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hardening.bats`:

```bash
@test "the sandbox sees only its own session directory" {
    mkdir -p "$HOME/.local/state/sbx/decoy-session"
    echo secret > "$HOME/.local/state/sbx/decoy-session/session.json"
    run_sbx "--fs caps" "ls '$HOME/.local/state/sbx' > /out/state.txt"
    ! grep -q decoy-session "$HOSTDIR/state.txt"
}

@test "the sandbox cannot see persistent cli stores" {
    mkdir -p "$HOME/.local/state/sbx/profiles/cli/other"
    run_sbx "--fs caps" "ls '$HOME/.local/state/sbx' > /out/state2.txt"
    ! grep -q profiles "$HOSTDIR/state2.txt"
}

@test "the sandbox cannot see the user profile directory" {
    mkdir -p "$HOME/.config/sbx/profiles/fs"
    echo marker > "$HOME/.config/sbx/marker.txt"
    run_sbx "--fs caps" "ls -a '$HOME/.config/sbx' > /out/cfg.txt"
    ! grep -q marker "$HOSTDIR/cfg.txt"
}

@test "the sandbox can still write its own session directory" {
    run_sbx "--fs caps" "ls '$HOME/.local/state/sbx' | wc -l > /out/count.txt"
    [ "$(cat "$HOSTDIR/count.txt")" = "1" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/hardening.bats -f "sandbox sees only\|persistent cli stores\|user profile directory"`

Expected: all FAIL — nothing masks these paths, and they are visible whenever a profile mounts a parent directory or `$HOME` itself.

- [ ] **Step 3: Remove the early session-directory bind**

In `sbx`, delete this line from the base `BWRAP_ARGS` array (line 287):

```bash
    --bind "$SESSION_DIR" "$SESSION_DIR"
```

It moves to the end, after profile mounts, in the next step.

- [ ] **Step 4: Append the masks last**

In `sbx`, insert after the GUI block closes (after line 775, immediately before `# Teardown Logic`):

```bash
# Masks, appended after every profile mount because bwrap applies mount
# arguments in order: a profile mounting $HOME or $HOME/.local would
# otherwise re-expose these. The sandbox gets its own session directory
# and nothing else — no sibling sessions, no persistent cli stores, and
# no ability to author the profiles that configure the next launch.
BWRAP_ARGS+=(--tmpfs "$STATE_DIR")
BWRAP_ARGS+=(--bind "$SESSION_DIR" "$SESSION_DIR")
BWRAP_ARGS+=(--tmpfs "$CONFIG_DIR")
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/hardening.bats`

Expected: all tests PASS.

- [ ] **Step 6: Verify copy-mount write-back still works**

The masks sit near the session directory that write-back depends on, so confirm the persistence suite specifically:

Run: `bats tests/persistent-cli.bats`

Expected: all 9 tests PASS.

- [ ] **Step 7: Verify no regression and clean lint**

Run: `bats tests/ && shellcheck sbx lib/copy-mounts.sh`

Expected: all suites pass, shellcheck silent.

- [ ] **Step 8: Commit**

```bash
git add sbx tests/hardening.bats
git commit -m "Mask sbx state and config directories from the sandbox"
```

---

### Task 6: Confirm project-supplied profiles

**Files:**
- Modify: `sbx` (after the argument-parsing loop, ~line 216), `tests/persistent-cli.bats:3-30`
- Create: `tests/project-profiles.bats`

**Interfaces:**
- Consumes: `profile_is_project()` from Task 3.
- Produces: `SBX_TRUST_PROJECT_PROFILES=1` environment escape hatch.

**Ordering note:** `tests/persistent-cli.bats` builds every fixture under `./.sbx/profiles/`, so its nine tests would block on the prompt forever. The test-helper change is part of this task, not a follow-up.

- [ ] **Step 1: Write the failing tests**

Create `tests/project-profiles.bats`:

```bash
#!/usr/bin/env bats

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/p"
    HOSTDIR="$ROOT/o"
    mkdir -p "$HOME" "$PROJ/.sbx/profiles/fs" "$HOSTDIR"

    cat > "$PROJ/.sbx/profiles/fs/tst.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
}

teardown() {
    [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]] && rm -rf "$ROOT"
}

@test "a project profile is refused non-interactively" {
    run bash -c "cd '$PROJ' && $SBX --fs tst -- /bin/true < /dev/null 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"project profile"* ]]
}

@test "the trust variable allows a project profile" {
    run bash -c "cd '$PROJ' && SBX_TRUST_PROJECT_PROFILES=1 script -qec \"$SBX --fs tst -- /bin/sh -c 'echo ran > /out/ran.txt'\" /dev/null >/dev/null 2>&1"
    [ -f "$HOSTDIR/ran.txt" ]
}

@test "a host profile needs no confirmation" {
    mkdir -p "$HOME/.config/sbx/profiles/fs"
    cat > "$HOME/.config/sbx/profiles/fs/hostp.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
    run bash -c "cd '$PROJ' && script -qec \"$SBX --fs hostp -- /bin/sh -c 'echo ran > /out/host.txt'\" /dev/null >/dev/null 2>&1"
    [ -f "$HOSTDIR/host.txt" ]
}

@test "the refusal names the tracking repo and its remote" {
    git -C "$PROJ" init -q
    git -C "$PROJ" remote add origin https://example.invalid/evil.git
    git -C "$PROJ" add -f .sbx/profiles/fs/tst.json
    run bash -c "cd '$PROJ' && $SBX --fs tst -- /bin/true < /dev/null 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"example.invalid"* ]]
}

@test "an untracked project profile is refused without a remote warning" {
    git -C "$PROJ" init -q
    git -C "$PROJ" remote add origin https://example.invalid/evil.git
    run bash -c "cd '$PROJ' && $SBX --fs tst -- /bin/true < /dev/null 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" != *"example.invalid"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/project-profiles.bats`

Expected: the refusal tests FAIL — project profiles are currently used silently.

- [ ] **Step 3: Add the confirmation function**

In `sbx`, insert after the argument-parsing `while` loop closes and after the `COMMAND` default is set (after line 216, before `find_session_mux`):

```bash
# A project directory is untrusted input: it can ship .sbx/profiles that
# mount anything anywhere. Using one is a decision the user makes
# explicitly, outside the repository.
confirm_project_profile() {
    local profile="$1"
    profile_is_project "$profile" || return 0
    [[ "${SBX_TRUST_PROJECT_PROFILES:-}" == "1" ]] && return 0

    local remote="" rname=""
    if git -C "$PWD" ls-files --error-unmatch "$profile" >/dev/null 2>&1; then
        rname=$(git -C "$PWD" remote 2>/dev/null | head -n1)
        if [[ -n "$rname" ]]; then
            remote=$(git -C "$PWD" remote get-url "$rname" 2>/dev/null || true)
        fi
    fi

    {
        echo ""
        echo "This launch would use a profile supplied by the project directory:"
        echo "  $profile"
        if [[ -n "$remote" ]]; then
            echo ""
            echo "  This profile is checked into a repo with remote $remote — it was"
            echo "  authored by whoever wrote that repository, not by you."
        fi
        echo ""
        sed 's/^/  | /' "$profile"
        echo ""
    } >&2

    if [[ ! -t 0 ]]; then
        echo "Error: refusing to use a project profile non-interactively." >&2
        echo "  Set SBX_TRUST_PROJECT_PROFILES=1 to allow it." >&2
        exit 1
    fi

    local answer=""
    printf "Use this project profile? [y/N] " >&2
    read -r answer < /dev/tty
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo "Aborted." >&2
        exit 1
    fi
}

for profile in "${FS_PROFILES[@]}" "$CLI_PROFILE" "$NET_PROFILE"; do
    [[ -z "$profile" ]] && continue
    confirm_project_profile "$profile"
done
```

`profile_is_project` is defined in Task 3 further down the file. Move that function definition up to sit immediately above `confirm_project_profile`, so both are defined before first use.

- [ ] **Step 4: Update the existing suite's helpers**

In `tests/persistent-cli.bats`, add to `setup()` after the `mkdir -p` line (line 16):

```bash
    # Every fixture below lives in ./.sbx/profiles; these are ours, so opt
    # out of the project-profile confirmation prompt for the whole suite.
    export SBX_TRUST_PROJECT_PROFILES=1
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/project-profiles.bats && bats tests/persistent-cli.bats`

Expected: all 5 new tests PASS, all 9 existing tests PASS.

- [ ] **Step 6: Verify the interactive path by hand**

Automated tests only cover the non-interactive refusal. Confirm the prompt itself works:

```bash
cd /tmp/ptest && /path/to/sbx --fs t -- /bin/true
```

Expected: the profile body prints, the prompt appears, `n` aborts with "Aborted.", `y` proceeds.

- [ ] **Step 7: Verify no regression and clean lint**

Run: `bats tests/ && shellcheck sbx lib/copy-mounts.sh`

Expected: all suites pass, shellcheck silent.

- [ ] **Step 8: Commit**

```bash
git add sbx tests/project-profiles.bats tests/persistent-cli.bats
git commit -m "Require confirmation before using a project-supplied profile"
```

---

### Task 7: Fix `--list-sessions`

**Files:**
- Modify: `sbx:146-161` (`--list-sessions`), `sbx:679-687` (`session.json`)
- Test: `tests/hardening.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/hardening.bats`:

```bash
@test "session.json records the supervising pid" {
    run_sbx "--fs caps" "true"
    run bash -c "jq -r '.pid' \"\$(find '$HOME/.local/state/sbx' -name session.json | head -n1)\""
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "list-sessions survives control characters in session.json" {
    run_sbx "--fs caps" "true"
    sfile=$(find "$HOME/.local/state/sbx" -name session.json | head -n1)
    jq --arg c "$(printf 'evil\033[31m')" '.cwd = $c' "$sfile" > "$sfile.tmp"
    mv "$sfile.tmp" "$sfile"
    run bash -c "cd '$PROJ' && $SBX --list-sessions"
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\033'* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/hardening.bats -f "supervising pid\|control characters"`

Expected: the pid test FAILS (`jq` returns `null`); the control-character test FAILS (the escape passes through).

- [ ] **Step 3: Record the pid**

In `sbx`, replace the `session.json` heredoc (lines 679–687) with:

```bash
cat > "$SESSION_DIR/session.json" <<EOF
{
    "id": "$SESSION_ID",
    "cwd": "$PWD",
    "pid": $$,
    "fs_profiles": $(printf '%s\n' "${FS_PROFILES[@]}" | jq -R . | jq -s .),
    "net_profile": $([[ -n "$NET_PROFILE" ]] && jq -R . <<< "$NET_PROFILE" || echo "null"),
    "cli_profile": $([[ -n "$CLI_PROFILE" ]] && jq -R . <<< "$CLI_PROFILE" || echo "null")
}
EOF
```

`$$` is sbx's own pid, which lives exactly as long as the session does.

- [ ] **Step 4: Sanitize the listing**

In `sbx`, replace the `--list-sessions` body (lines 146–161) with:

```bash
        --list-sessions)
            echo "Active Sessions (this directory):"
            for sdir in "$STATE_DIR"/*; do
                if [[ -d "$sdir" && -f "$sdir/session.json" ]]; then
                    # session.json sits inside the session directory, which
                    # is bound rw into the sandbox — treat every field as
                    # attacker-authored and strip control characters before
                    # echoing them to a terminal.
                    scwd=$(jq -r '.cwd' "$sdir/session.json" | tr -d '\000-\037')
                    if [[ "$scwd" == "$PWD" ]]; then
                        sid=$(jq -r '.id' "$sdir/session.json" | tr -d '\000-\037')
                        pid=$(jq -r '.pid // empty' "$sdir/session.json" | tr -d '\000-\037')
                        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
                            echo "  $sid (active, PID: $pid)"
                        else
                            echo "  $sid (inactive)"
                        fi
                    fi
                fi
            done
            exit 0
            ;;
```

The `[[ "$pid" =~ ^[0-9]+$ ]]` guard matters independently: an unvalidated `$pid` reaching `kill` is a signal sent somewhere the sandbox chose.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/hardening.bats`

Expected: all tests PASS.

- [ ] **Step 6: Verify a live session is reported active**

```bash
cd /tmp && /path/to/sbx -- /bin/sh -c 'sleep 30' &
sleep 3 && cd /tmp && /path/to/sbx --list-sessions
```

Expected: one entry marked `(active, PID: …)`. Previously every session read `(inactive)`.

- [ ] **Step 7: Verify no regression and clean lint**

Run: `bats tests/ && shellcheck sbx lib/copy-mounts.sh`

Expected: all suites pass, shellcheck silent.

- [ ] **Step 8: Commit**

```bash
git add sbx tests/hardening.bats
git commit -m "Record session pid and sanitize --list-sessions output"
```

---

### Task 8: Tighten `cli/claude.json`

Deliberately last: `ro` only became meaningful once Tasks 1–2 landed, and this is the change most likely to need adjustment from real use.

**Files:**
- Modify: `profiles/cli/claude.json`

- [ ] **Step 1: Flip the blanket mounts to ro**

Replace `profiles/cli/claude.json` with:

```json
{
    "description": "Standard Development Environment",
    "env": {
        "NO_BROWSER": 1,
        "NODE_OPTIONS": "--dns-result-order=ipv4first"
    },
    "path": [
        "$HOME/.local/bin"
    ],
    "mounts": [
        {"source": "$HOME/.nvm", "dest": "$HOME/.nvm", "perm": "ro"},
        {"source": "$HOME/.npm-global", "dest": "$HOME/.npm-global", "perm": "ro"},
        {"source": "$HOME/.npm", "dest": "$HOME/.npm", "perm": "rw"},
        {"source": "$HOME/.local", "dest": "$HOME/.local", "perm": "ro"},
        {"source": "$HOME/.claude", "dest": "$HOME/.claude", "perm": "copy"},
        {"source": "$HOME/.claude.json", "dest": "$HOME/.claude.json", "perm": "copy"}
    ]
}
```

`$HOME/.npm` stays `rw` as a build cache. `$HOME/.local` and `$HOME/.nvm` become `ro`: `~/.local/bin` is on the host PATH and `~/.local/share/systemd/user` executes on the host, so a writable mount there is a direct host-code-execution path.

- [ ] **Step 2: Verify the profile parses**

Run: `jq -e . profiles/cli/claude.json > /dev/null && echo parse-ok`

Expected: `parse-ok`.

- [ ] **Step 3: Verify a real session works**

Run:

```bash
cd /tmp && /path/to/sbx --cli claude --net anthropic -- /bin/sh -c 'command -v claude && node --version'
```

Expected: the `claude` binary resolves and node runs. If anything fails with a write error under `~/.local`, add a narrow `rw` or `copy` mount for that specific subpath rather than reverting the whole mount to `rw`, and note it in the commit message.

- [ ] **Step 4: Verify no regression and clean lint**

Run: `bats tests/ && shellcheck sbx lib/copy-mounts.sh`

Expected: all suites pass, shellcheck silent.

- [ ] **Step 5: Commit**

```bash
git add profiles/cli/claude.json
git commit -m "Make claude profile's .local and .nvm mounts read-only"
```

---

### Task 9: Document the threat model and residual risks

**Files:**
- Modify: `README.md`, `docs/superpowers/specs/2026-08-01-sbx-hardening-design.md`

- [ ] **Step 1: Add a threat-model section to README.md**

Insert after the "Features" list, before "## Usage":

```markdown
## Threat model

sbx assumes the code running inside a sandbox and the project directory it
was launched from are both adversarial. It is built to protect the host user
account from them.

What that buys you, in a session without `"caps": "keep"`:

- **`ro` mounts are read-only.** The payload holds no capabilities, so it
  cannot remount a bind read-write.
- **The egress allow-list is not removable.** `nft` and `dnsmasq` run outside
  the sandbox's PID and mount namespaces; nothing inside can flush the
  ruleset or signal the resolver.
- **The host environment does not leak in.** The environment is cleared;
  variables arrive only via the base set or a profile's `passthrough`.
- **sbx's own state and config are masked**, so a sandbox cannot reach
  sibling sessions, persistent cli stores, or the profiles that configure the
  next launch.
- **Project-supplied profiles require confirmation**, and may never request
  `caps`, `userns`, or `docker_api`.

### What it does not protect against

- **Sessions with `"caps": "keep"`** — including `fs/podman` and
  `fs/podman-full`. Capabilities are required for the nested user namespaces
  podman needs, and with them `ro` mounts are writable and the firewall is
  removable. Such sessions print a warning at launch.
- **Kernel exploits.** There is no seccomp filter: `bwrap --seccomp` needs a
  compiled BPF blob, which is the kind of custom code this project avoids.
- **Wildcard `allow` entries.** `*.anthropic.com` admits any IP an attacker
  can publish under that suffix.
- **DNS as an exfiltration channel.** Query labels for allowed domains are
  forwarded upstream.
- **`"ports": ["*"]`** in `net/anthropic.json` and `net/gemini.json` — any
  allowed IP is reachable on any port. Narrowing to 443 would break `git push`
  over SSH to `github.com`.
```

- [ ] **Step 2: Document the new profile fields**

In the CLI-profile and FS-profile schema tables, add:

```markdown
| `passthrough` | array | No | Host environment variables to forward into the sandbox by name. The environment is otherwise cleared. |
| `caps` | string | No | `"keep"` retains capabilities inside the sandbox. Required for nested user namespaces (podman); costs the read-only-mount and firewall guarantees. Ignored — and rejected — in project-supplied profiles. |
```

- [ ] **Step 3: Correct the spec's env ordering claim**

In `docs/superpowers/specs/2026-08-01-sbx-hardening-design.md`, in the Environment section, replace item 4 and the sentence after the list with:

```markdown
4. **Profile `"env"`** — existing behaviour, unchanged; overrides both the
   base set and `passthrough`

`PATH` and `DOCKER_HOST` are applied after profile `env` and win. Other
sbx-set variables (`XDG_RUNTIME_DIR`, `DISPLAY`, `CONTAINERS_*`) remain
overridable by a profile, because `profiles/fs/chrome.json` exists precisely
to set `DISPLAY` and `XDG_RUNTIME_DIR`. Secrets reach a sandbox only when a
profile names them.
```

- [ ] **Step 4: Verify the docs are accurate**

Run: `grep -n "cap-add ALL" README.md docs/superpowers/specs/2026-08-01-sbx-hardening-design.md`

Expected: matches only inside the spec's findings/history sections, never as a description of current behaviour.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/superpowers/specs/2026-08-01-sbx-hardening-design.md
git commit -m "Document the threat model, new profile fields and residual risks"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: capability model → 1, 2; readiness probe → 2 Step 4; capability retention → 3; environment → 4; mount integrity → 5; network `--no-map-gw` → 2 Step 7; project-profile confirmation → 6; shipped profile changes → 3 Step 4, 8; smaller fixes → 7; testing → tests in 1–7; residual risks → 9.

**Deviation flagged.** The spec's "sbx-controlled wins" env ordering is not implemented as written, because it would break `chrome.json`. Task 4 states this and Task 9 Step 3 corrects the spec.

**Naming consistency.** `CAPS_KEEP` is introduced in Task 1 Step 3 and read in Tasks 1, 2, 3 under that exact name. `profile_is_project()` is defined in Task 3 and reused in Task 6, which explicitly relocates the definition above its first use. `NET_PRELUDE` is built and consumed within Task 2. `run_sbx()`, `$HOSTDIR`, `$RODIR` and the `caps` fixture are defined in Task 1 and reused unchanged in Tasks 2–5, 7.

**Ordering risk closed.** Task 6 updates `tests/persistent-cli.bats` in the same commit as the confirmation prompt, so the existing suite never hangs.
