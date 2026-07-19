# sbx virt phase 2 (userns:full + docker compat) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Profile-driven multi-UID podman (`"userns": "full"` → outer userns with the full subordinate-UID range) and docker compatibility (always-on `docker` shim + `DOCKER_HOST`, opt-in `podman system service` socket via `"docker_api": true`), per the approved spec.

**Architecture:** `sbx` is a single bash script that assembles a `bwrap` argument array and launches it (under `pasta` when networking is on). This plan adds: a profile-field scan setting `$USERNS_FULL`/`$DOCKER_API`; an alternate launch chain `unshare --map-auto --map-root-user → pasta --netns-only → bwrap` plus a rootful `storage.conf` variant when `$USERNS_FULL`; an always-written `docker` exec-shim in `$SESSION_DIR/bin` with `DOCKER_HOST` set; a wrapper-script block that starts/stops `podman system service` when `$DOCKER_API`; and a new `profiles/fs/podman-full.json`.

**Tech Stack:** bash, bubblewrap 0.11.2, util-linux `unshare` (needs `--map-auto`, util-linux ≥ 2.38), `pasta`, `jq`, `podman`, `curl`.

**Reference:** `docs/superpowers/specs/2026-07-19-sbx-virt-phase2-design.md` (approved). Phase 1 background: `docs/superpowers/specs/2026-07-16-sbx-virt-support-design.md`.

## Global Constraints

- **The git index already carries an unrelated staged deletion (`D profiles/fs/qemu.json`) and the tree has untracked `test-*.ts` files — these are the user's separate in-progress work. NEVER touch them, and NEVER run a bare `git commit` (it would commit the staged deletion). Every commit in this plan MUST use the pathspec form: `git add <files>` then `git commit -m "..." -- <files>`.**
- Never bind a host-side container-engine socket (docker or podman) into a sandbox — the socket is the privilege; containers must run inside the sandbox so nftables egress gating applies (spec Security notes).
- No automated test suite exists. "Tests" are real `./sbx` invocations with concrete expected output — run each one. Scratch profiles go under `.sbx/profiles/{fs,net}/` (gitignored), never under tracked `profiles/`.
- Heredoc quoting in `sbx` is load-bearing: quoted delimiters (`<<'CONFEOF'`) suppress expansion, unquoted ones expand at write time. Copy the code blocks below exactly, including quoting and `\$` escapes.
- The socket path is always the sbx-computed `/run/user/$(id -u)/podman/podman.sock` (`$PODMAN_SOCK`), never runtime `$XDG_RUNTIME_DIR` (a profile may override that and diverge from `DOCKER_HOST`).
- End commit messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Profile feature-field scan + `userns`/`--net` validation

**Files:**
- Modify: `sbx:187-189` (insert after the `COMMAND=("/bin/bash")` default block)

**Interfaces:**
- Consumes: `$FS_PROFILES`, `$CLI_PROFILE`, `$NET_PROFILE` (already set by arg parsing above the insertion point).
- Produces: shell vars `USERNS_FULL` (`true`/`false`), `DOCKER_API` (`true`/`false`), `USERNS_PROFILE` (path of the profile that set userns, for error text). Tasks 2 and 3 branch on these exact names. Also produces the hard error: `userns: full` without `--net` exits 1 before any session state is created.

- [ ] **Step 1: Create scratch profiles used throughout this plan**

```bash
mkdir -p .sbx/profiles/fs .sbx/profiles/net
cat > .sbx/profiles/net/_virttest.json <<'EOF'
{
    "description": "scratch: phase 2 verification (permissive)",
    "dns": "1.1.1.1",
    "allow": ["*"],
    "ports": ["*"]
}
EOF
cat > .sbx/profiles/fs/_usernstest.json <<'EOF'
{
    "description": "scratch: userns field scan test",
    "userns": "full",
    "mounts": []
}
EOF
```

- [ ] **Step 2: Reproduce the current gap**

```bash
./sbx --fs _usernstest -- true; echo "exit=$?"
```

Expected (current, wrong behavior): the session runs normally and prints `exit=0` — the `userns` field is silently ignored, no validation exists.

- [ ] **Step 3: Insert the scan + validation block**

Current code (`sbx:187-191`):

```bash
if [[ ${#COMMAND[@]} -eq 0 ]]; then
    COMMAND=("/bin/bash")
fi

# Session Initialization
```

Use Edit:

```
old_string:
if [[ ${#COMMAND[@]} -eq 0 ]]; then
    COMMAND=("/bin/bash")
fi

# Session Initialization

new_string:
if [[ ${#COMMAND[@]} -eq 0 ]]; then
    COMMAND=("/bin/bash")
fi

# --- Profile feature-field scan (phase 2 virt) ---
# Optional fields honored in any applied fs/cli profile:
#   "userns": "full"    -> run the whole session inside an outer user
#                          namespace carrying the user's full subordinate-
#                          UID range (multi-UID podman). Requires --net.
#   "docker_api": true  -> start a podman docker-API socket for the session.
USERNS_FULL=false
DOCKER_API=false
USERNS_PROFILE=""
for profile in "${FS_PROFILES[@]}" "$CLI_PROFILE"; do
    [[ -z "$profile" ]] && continue
    if [[ "$(jq -r '.userns // empty' "$profile")" == "full" ]]; then
        USERNS_FULL=true
        USERNS_PROFILE="$profile"
    fi
    if [[ "$(jq -r '.docker_api // false' "$profile")" == "true" ]]; then
        DOCKER_API=true
    fi
done

if [[ "$USERNS_FULL" == "true" && -z "$NET_PROFILE" ]]; then
    echo "Error: profile '$USERNS_PROFILE' sets \"userns\": \"full\", which requires networking. Add --net <profile>." >&2
    exit 1
fi

# Session Initialization
```

- [ ] **Step 4: Verify the error path and the no-op paths**

```bash
./sbx --fs _usernstest -- true; echo "exit=$?"
./sbx --fs _usernstest --net _virttest -- sh -c 'echo WITH-NET-OK'
./sbx -- sh -c 'echo PLAIN-OK'
```

Expected: first command prints the error naming `.sbx/profiles/fs/_usernstest.json` and `exit=1` (and does NOT print "Starting session"); second runs and prints `WITH-NET-OK` (the flag has no launch effect yet — that's Task 2); third prints `PLAIN-OK` unchanged.

- [ ] **Step 5: Commit**

```bash
git add sbx
git commit -m "Add profile feature-field scan (userns, docker_api) with --net validation

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- sbx
```

---

### Task 2: `userns: full` launch chain + rootful storage config

**Files:**
- Modify: `sbx` net-profile branch (the `_CONTAINERS_*` setenv block, currently `sbx:235-239`)
- Modify: `sbx` virt plumbing `storage.conf` heredoc (currently `sbx:256-266`)
- Modify: `sbx` launch invocation (currently `sbx:769-775`)

**Interfaces:**
- Consumes: `$USERNS_FULL` from Task 1.
- Produces: sessions whose profiles set `"userns": "full"` run as ns-root with the full subordinate-UID range; podman in them runs rootful-in-namespace against `~/.local/state/sbx/virt/containers-full`. No behavior change when `$USERNS_FULL` is `false`.

- [ ] **Step 1: Preconditions + reproduce the current gap**

```bash
unshare --help | grep -e '--map-auto' || echo "FATAL: unshare lacks --map-auto"
grep -c "$(id -un)" /etc/subuid /etc/subgid
cat > .sbx/profiles/fs/_fulltest.json <<'EOF'
{
    "description": "scratch: full-userns podman (mirrors future podman-full.json)",
    "userns": "full",
    "mounts": [
        { "source": "/dev/net/tun", "dest": "/dev/net/tun", "perm": "dev" },
        { "source": "$HOME/.local/state/sbx/virt/containers-full", "dest": "$HOME/.local/state/sbx/virt/containers-full", "perm": "rw" }
    ]
}
EOF
./sbx --fs _fulltest --net _virttest -- id
```

Expected: `unshare` supports `--map-auto`; `/etc/subuid` and `/etc/subgid` each have an entry for you (if not, STOP and report — the feature cannot work without a subordinate range). The `id` output currently shows uid 0 **but** that is pasta's fake single-mapped root (phase 1 behavior) — confirm with `./sbx --fs _fulltest --net _virttest -- cat /proc/self/uid_map`, which currently shows a single-line map (one UID mapped), not a 65536 range.

- [ ] **Step 2: Skip the `_CONTAINERS_*` overrides in userns-full mode**

Current code (`sbx:235-239`):

```bash
    BWRAP_ARGS+=(
        --setenv _CONTAINERS_USERNS_CONFIGURED done
        --setenv _CONTAINERS_ROOTLESS_UID "$(id -u)"
        --setenv _CONTAINERS_ROOTLESS_GID "$(id -g)"
    )
```

Use Edit:

```
old_string:
    BWRAP_ARGS+=(
        --setenv _CONTAINERS_USERNS_CONFIGURED done
        --setenv _CONTAINERS_ROOTLESS_UID "$(id -u)"
        --setenv _CONTAINERS_ROOTLESS_GID "$(id -g)"
    )

new_string:
    # In userns-full mode these overrides are exactly wrong: there podman
    # MUST run rootful-in-namespace (euid 0 backed by a real multi-UID
    # mapping), and forcing the rootless code path would resurrect the
    # single-UID limitation the outer userns exists to remove.
    if [[ "$USERNS_FULL" != "true" ]]; then
        BWRAP_ARGS+=(
            --setenv _CONTAINERS_USERNS_CONFIGURED done
            --setenv _CONTAINERS_ROOTLESS_UID "$(id -u)"
            --setenv _CONTAINERS_ROOTLESS_GID "$(id -g)"
        )
    fi
```

- [ ] **Step 3: Mode-conditional `storage.conf`**

Current code (`sbx:256-266`):

```bash
# rootless_storage_path expands $HOME using podman's own runtime env (sbx
# doesn't clear or override HOME, so it resolves to the same value inside
# the sandbox as outside). Written literally — do not let bash expand it.
cat > "$VIRT_DIR/storage.conf" <<'CONFEOF'
[storage]
driver = "overlay"
rootless_storage_path = "$HOME/.local/state/sbx/virt/containers"

[storage.options.overlay]
ignore_chown_errors = "true"
CONFEOF
```

Use Edit (note: the userns-full heredoc delimiter is deliberately UNQUOTED so `$HOME` expands at write time; the single-UID one stays QUOTED):

```
old_string:
# rootless_storage_path expands $HOME using podman's own runtime env (sbx
# doesn't clear or override HOME, so it resolves to the same value inside
# the sandbox as outside). Written literally — do not let bash expand it.
cat > "$VIRT_DIR/storage.conf" <<'CONFEOF'
[storage]
driver = "overlay"
rootless_storage_path = "$HOME/.local/state/sbx/virt/containers"

[storage.options.overlay]
ignore_chown_errors = "true"
CONFEOF

new_string:
if [[ "$USERNS_FULL" == "true" ]]; then
    # userns-full sessions run podman rootful-in-namespace: rootful podman
    # reads graphroot, not rootless_storage_path. Expanded at write time
    # (HOME inside the sandbox equals host HOME). No ignore_chown_errors:
    # ownership is real in this mode (full subordinate-UID range). This
    # store is separate from the single-UID one by design — the ownership
    # layouts are incompatible.
    cat > "$VIRT_DIR/storage.conf" <<CONFEOF
[storage]
driver = "overlay"
graphroot = "$HOME/.local/state/sbx/virt/containers-full"
CONFEOF
else
    # rootless_storage_path expands $HOME using podman's own runtime env (sbx
    # doesn't clear or override HOME, so it resolves to the same value inside
    # the sandbox as outside). Written literally — do not let bash expand it.
    cat > "$VIRT_DIR/storage.conf" <<'CONFEOF'
[storage]
driver = "overlay"
rootless_storage_path = "$HOME/.local/state/sbx/virt/containers"

[storage.options.overlay]
ignore_chown_errors = "true"
CONFEOF
fi
```

- [ ] **Step 4: Wrap the launch in `unshare` for userns-full sessions**

Current code (`sbx:769-775`, end of file):

```bash
if [[ -n "$NET_PROFILE" ]]; then
    echo "Starting session $SESSION_ID with networking..."
    pasta -f --config-net --interface "$HOST_IFACE" --no-ndp --no-dhcpv6 --no-ra -a "$HOST_IP" -g "$HOST_GW" -n "$HOST_MASK" -- "$LAUNCH_SCRIPT"
else
    echo "Starting session $SESSION_ID..."
    "$LAUNCH_SCRIPT"
fi
```

Use Edit:

```
old_string:
if [[ -n "$NET_PROFILE" ]]; then
    echo "Starting session $SESSION_ID with networking..."
    pasta -f --config-net --interface "$HOST_IFACE" --no-ndp --no-dhcpv6 --no-ra -a "$HOST_IP" -g "$HOST_GW" -n "$HOST_MASK" -- "$LAUNCH_SCRIPT"
else
    echo "Starting session $SESSION_ID..."
    "$LAUNCH_SCRIPT"
fi

new_string:
if [[ -n "$NET_PROFILE" ]]; then
    if [[ "$USERNS_FULL" == "true" ]]; then
        echo "Starting session $SESSION_ID with networking (full userns)..."
        # unshare claims the user's /etc/subuid range up front, via the
        # setuid newuidmap helper — still permitted here because bwrap's
        # no_new_privs only applies further down the chain. pasta must
        # then NOT create its own user namespace (that would discard the
        # multi-UID mapping): --netns-only.
        unshare --map-auto --map-root-user -- \
            pasta -f --config-net --netns-only --interface "$HOST_IFACE" --no-ndp --no-dhcpv6 --no-ra -a "$HOST_IP" -g "$HOST_GW" -n "$HOST_MASK" -- "$LAUNCH_SCRIPT"
    else
        echo "Starting session $SESSION_ID with networking..."
        pasta -f --config-net --interface "$HOST_IFACE" --no-ndp --no-dhcpv6 --no-ra -a "$HOST_IP" -g "$HOST_GW" -n "$HOST_MASK" -- "$LAUNCH_SCRIPT"
    fi
else
    echo "Starting session $SESSION_ID..."
    "$LAUNCH_SCRIPT"
fi
```

- [ ] **Step 5: Verify identity and the UID range**

```bash
./sbx --fs _fulltest --net _virttest -- id
./sbx --fs _fulltest --net _virttest -- cat /proc/self/uid_map
```

Expected: `id` reports `uid=0(root) gid=0(root)`. `uid_map` shows the full range — two lines of the shape `0 <your-uid> 1` and `1 <subuid-base> 65536` (exact inner start may differ; the requirement is a total of ≥ 65536 mapped UIDs, NOT a single-line single-UID map). **If pasta errors on `--netns-only`** (older pasta), record the exact error, retry without `--netns-only`, and re-check `uid_map`: if the range survives, drop the flag and note it for spec reconciliation (Task 5); if the map collapses to a single line, STOP and report — do not paper over it.

- [ ] **Step 6: Acceptance test — the phase-1-failing `USER` Dockerfile builds**

```bash
mkdir -p /tmp/sbx-usertest && cat > /tmp/sbx-usertest/Dockerfile <<'EOF'
FROM alpine
RUN adduser -D appuser
USER appuser
RUN touch /home/appuser/marker
EOF
./sbx --fs _fulltest --net _virttest -- podman build -t sbx-usertest /tmp/sbx-usertest 2>&1 | tail -5
```

Expected: build completes (`COMMIT sbx-usertest` in output). Under phase 1 this exact Dockerfile failed at the post-`USER` RUN step with `setresgid to '1000': Invalid argument`. Also confirm the storage landed in the new store: `ls ~/.local/state/sbx/virt/containers-full/` is non-empty, and `ls -ln` there shows subordinate-range owners (e.g. 100000+) — that is correct and expected.

- [ ] **Step 7: Regression — single-UID podman path unchanged**

```bash
./sbx --fs podman --net _virttest -- podman run --rm docker.io/library/alpine:latest echo SINGLE-UID-OK 2>&1 | tail -1
./sbx --fs podman --net _virttest -- sh -c 'cat $CONTAINERS_STORAGE_CONF | head -3'
```

Expected: `SINGLE-UID-OK`; storage.conf still shows `rootless_storage_path` (the else-branch heredoc).

- [ ] **Step 8: Commit**

```bash
git add sbx
git commit -m "Add userns:full launch chain with rootful-in-namespace podman storage

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- sbx
```

---

### Task 3: `docker` shim + `DOCKER_HOST` (always-on) and opt-in API service

**Files:**
- Modify: `sbx` — insert shim/DOCKER_HOST block right after the virt-plumbing `BWRAP_ARGS+=( ... )` block (currently ends `sbx:292`, just before `COPY_MOUNTS=()`)
- Modify: `sbx` — the final `PATH` setenv (currently `sbx:414`)
- Modify: `sbx` — service start/stop blocks around wrapper generation (currently `sbx:682-751`)
- Modify: `profiles/fs/podman.json` (gains `"docker_api": true`)

**Interfaces:**
- Consumes: `$DOCKER_API` from Task 1; `$SESSION_DIR`, `$VIRT_DIR` from phase 1.
- Produces: `$PODMAN_SOCK` shell var (`/run/user/<uid>/podman/podman.sock`); `docker` command on PATH in every session; `DOCKER_HOST` env in every session; live API socket in sessions whose profiles set `docker_api`. Task 4's profile and README rely on the field name `docker_api` and the socket path exactly as defined here.

- [ ] **Step 1: Reproduce the current gap**

```bash
./sbx -- sh -c 'command -v docker || echo NO-DOCKER; echo "DOCKER_HOST=[$DOCKER_HOST]"'
```

Expected (current behavior): `NO-DOCKER` (unless the host has real docker installed, in which case it resolves to the host binary — either way, no shim) and `DOCKER_HOST=[]`.

- [ ] **Step 2: Insert the always-on shim + DOCKER_HOST block**

Current code (`sbx:282-294`):

```bash
BWRAP_ARGS+=(
    --tmpfs /var
    --dir /var/tmp
    --dir "/run/user/$(id -u)"
    --ro-bind /sys /sys
    --ro-bind "$VIRT_DIR/empty" /etc/subuid
    --ro-bind "$VIRT_DIR/empty" /etc/subgid
    --setenv XDG_RUNTIME_DIR "/run/user/$(id -u)"
    --setenv CONTAINERS_STORAGE_CONF "$VIRT_DIR/storage.conf"
    --setenv CONTAINERS_CONF "$VIRT_DIR/containers.conf"
)

COPY_MOUNTS=() # Array of "source:dest"
```

Use Edit:

```
old_string:
    --setenv CONTAINERS_STORAGE_CONF "$VIRT_DIR/storage.conf"
    --setenv CONTAINERS_CONF "$VIRT_DIR/containers.conf"
)

COPY_MOUNTS=() # Array of "source:dest"

new_string:
    --setenv CONTAINERS_STORAGE_CONF "$VIRT_DIR/storage.conf"
    --setenv CONTAINERS_CONF "$VIRT_DIR/containers.conf"
)

# Docker compat: a `docker` CLI shim (execs podman) and DOCKER_HOST are
# always on — both are free (no processes; $SESSION_DIR is already bound
# into every sandbox). The socket DOCKER_HOST points at only exists when
# a profile sets "docker_api": true (see wrapper generation). The path is
# pinned to the sbx-computed /run/user/<uid> — deliberately NOT
# $XDG_RUNTIME_DIR, which a profile may override and silently diverge
# from DOCKER_HOST.
PODMAN_SOCK="/run/user/$(id -u)/podman/podman.sock"
mkdir -p "$SESSION_DIR/bin"
cat > "$SESSION_DIR/bin/docker" <<'SHIMEOF'
#!/bin/sh
exec podman "$@"
SHIMEOF
chmod +x "$SESSION_DIR/bin/docker"
BWRAP_ARGS+=(--setenv DOCKER_HOST "unix://$PODMAN_SOCK")

COPY_MOUNTS=() # Array of "source:dest"
```

- [ ] **Step 3: Prepend the shim dir to the sandbox PATH**

Current code (`sbx`, end of the PATH-handling section, currently line 414):

```bash
BWRAP_ARGS+=(--setenv PATH "$SANDBOX_PATH")
```

Use Edit:

```
old_string:
BWRAP_ARGS+=(--setenv PATH "$SANDBOX_PATH")

new_string:
# $SESSION_DIR/bin holds the docker shim; first on PATH so `docker` always
# resolves to it (the host docker socket is never reachable in a sandbox).
BWRAP_ARGS+=(--setenv PATH "$SESSION_DIR/bin:$SANDBOX_PATH")
```

- [ ] **Step 4: Build the service start/stop blocks and splice them into both wrappers**

Current code (`sbx:679-684`):

```bash
ABDUCO_SOCK="$SESSION_DIR/abduco.sock"
LAUNCH_SCRIPT="$SESSION_DIR/launch.sh"
CAT_WRAPPER="$SESSION_DIR/wrapper.sh"
DNSMASQ_BIN=$(which dnsmasq)

if [[ -n "$NET_PROFILE" ]]; then
```

Use Edit (escaping note: `DOCKER_API_START` is built with an UNQUOTED heredoc — `$PODMAN_SOCK`/`$SESSION_DIR` expand now, `\$!` stays literal for runtime. `DOCKER_API_STOP` is single-quoted — heredoc expansion of `$DOCKER_API_STOP` inserts its contents literally without re-expanding, so `$PODMAN_API_PID` survives to wrapper runtime):

```
old_string:
CAT_WRAPPER="$SESSION_DIR/wrapper.sh"
DNSMASQ_BIN=$(which dnsmasq)

if [[ -n "$NET_PROFILE" ]]; then

new_string:
CAT_WRAPPER="$SESSION_DIR/wrapper.sh"
DNSMASQ_BIN=$(which dnsmasq)

# Opt-in podman docker-API service ("docker_api": true in any profile).
# Startup failure is a WARNING, not fatal — the docker CLI shim works
# without the service (contrast: nft/dnsmasq failures stay hard errors;
# egress safety is never best-effort). Killed when the command exits.
DOCKER_API_START=""
DOCKER_API_STOP=""
if [[ "$DOCKER_API" == "true" ]]; then
    DOCKER_API_START=$(cat <<APIEOF
mkdir -p "$(dirname "$PODMAN_SOCK")"
podman system service --time=0 "unix://$PODMAN_SOCK" > "$SESSION_DIR/podman-api.log" 2>&1 &
PODMAN_API_PID=\$!
for i in {1..10}; do
    [[ -S "$PODMAN_SOCK" ]] && break
    sleep 0.5
done
if [[ ! -S "$PODMAN_SOCK" ]]; then
    echo "Warning: podman API socket did not appear at $PODMAN_SOCK; docker SDK clients will fail (the docker CLI shim still works)." >&2
    cat "$SESSION_DIR/podman-api.log" >&2 || true
fi
APIEOF
)
    DOCKER_API_STOP='[[ -n "$PODMAN_API_PID" ]] && kill $PODMAN_API_PID 2>/dev/null || true'
fi

if [[ -n "$NET_PROFILE" ]]; then
```

Then splice into the **net** wrapper. Current code (`sbx:743-745`, tail of the net-wrapper heredoc):

```
$(printf "%q " "${COMMAND[@]}")
kill \$DNSMASQ_PID 2>/dev/null || true
EOF
```

Use Edit:

```
old_string:
$(printf "%q " "${COMMAND[@]}")
kill \$DNSMASQ_PID 2>/dev/null || true
EOF

new_string:
$DOCKER_API_START
$(printf "%q " "${COMMAND[@]}")
$DOCKER_API_STOP
kill \$DNSMASQ_PID 2>/dev/null || true
EOF
```

Then the **no-net** wrapper. Current code (`sbx:746-751`):

```bash
else
    cat > "$CAT_WRAPPER" <<EOF
#!/bin/bash
$(printf "%q " "${COMMAND[@]}")
EOF
fi
```

Use Edit:

```
old_string:
else
    cat > "$CAT_WRAPPER" <<EOF
#!/bin/bash
$(printf "%q " "${COMMAND[@]}")
EOF
fi

new_string:
else
    cat > "$CAT_WRAPPER" <<EOF
#!/bin/bash
$DOCKER_API_START
$(printf "%q " "${COMMAND[@]}")
$DOCKER_API_STOP
EOF
fi
```

- [ ] **Step 5: Add `docker_api` to the podman profile**

Current content of `profiles/fs/podman.json`:

```json
{
    "description": "Rootless podman: persistent container storage + tun for pasta networking",
    "mounts": [
        { "source": "/dev/net/tun", "dest": "/dev/net/tun", "perm": "dev" },
        { "source": "$HOME/.local/state/sbx/virt/containers", "dest": "$HOME/.local/state/sbx/virt/containers", "perm": "rw" }
    ]
}
```

Replace with (Write the whole file):

```json
{
    "description": "Rootless podman (single-UID): persistent storage, tun, docker API socket",
    "docker_api": true,
    "mounts": [
        { "source": "/dev/net/tun", "dest": "/dev/net/tun", "perm": "dev" },
        { "source": "$HOME/.local/state/sbx/virt/containers", "dest": "$HOME/.local/state/sbx/virt/containers", "perm": "rw" }
    ]
}
```

- [ ] **Step 6: Verify shim, env, socket, absence, and teardown**

```bash
./sbx -- docker --version
./sbx -- sh -c 'echo "DOCKER_HOST=$DOCKER_HOST"; test -S /run/user/$(id -u)/podman/podman.sock || echo NO-SOCKET'
./sbx --fs podman -- sh -c 'curl -s --unix-socket /run/user/$(id -u)/podman/podman.sock http://d/_ping; echo'
sleep 1; pgrep -af 'podman system service' || echo SERVICE-CLEAN
```

Expected: line 1 prints `podman version ...` (the shim resolved first on PATH); line 2 prints `DOCKER_HOST=unix:///run/user/<uid>/podman/podman.sock` and `NO-SOCKET` (plain session: env set, no service); line 3 prints `OK` (docker API ping through the socket in a `--fs podman` session); line 4 prints `SERVICE-CLEAN` (no service outlives its session). Note: the phase-1 no-net podman teardown leak (`catatonit`) is a known pre-existing issue — `SERVICE-CLEAN` is about `podman system service` specifically.

- [ ] **Step 7: Commit**

```bash
git add sbx profiles/fs/podman.json
git commit -m "Add docker CLI shim, DOCKER_HOST, and opt-in podman API service

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- sbx profiles/fs/podman.json
```

---

### Task 4: `podman-full` profile + README docs

**Files:**
- Create: `profiles/fs/podman-full.json`
- Modify: `README.md` (FS-profile field table + Virt section)

**Interfaces:**
- Consumes: `userns`/`docker_api` field semantics (Tasks 1-3), `containers-full` storage path (Task 2).
- Produces: `--fs podman-full` usable by users/agents; documented schema fields.

- [ ] **Step 1: Create `profiles/fs/podman-full.json`**

```json
{
    "description": "Multi-UID podman (ns-root session; requires --net): full image fidelity, docker API socket",
    "userns": "full",
    "docker_api": true,
    "mounts": [
        { "source": "/dev/net/tun", "dest": "/dev/net/tun", "perm": "dev" },
        { "source": "$HOME/.local/state/sbx/virt/containers-full", "dest": "$HOME/.local/state/sbx/virt/containers-full", "perm": "rw" }
    ]
}
```

- [ ] **Step 2: Verify discovery and validation**

```bash
./sbx --list-profiles | grep podman
./sbx --fs podman-full -- true; echo "exit=$?"
```

Expected: `podman (Global)` and `podman-full (Global)` listed; second command errors naming the podman-full profile path (requires `--net`), `exit=1`.

- [ ] **Step 3: README — FS field table gains the two new fields**

Current text (`README.md:101-106`):

```
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | string | No | Human-readable label for the profile |
| `workingDirectory` | string | No | Initial working directory inside the sandbox (last one wins when multiple FS profiles are stacked) |
| `mounts` | array of objects | No | Filesystem mount specifications (see below) |
| `env` | object | No | Key-value pairs of environment variables to set |
```

Use Edit:

```
old_string:
| `mounts` | array of objects | No | Filesystem mount specifications (see below) |
| `env` | object | No | Key-value pairs of environment variables to set |

new_string:
| `mounts` | array of objects | No | Filesystem mount specifications (see below) |
| `env` | object | No | Key-value pairs of environment variables to set |
| `userns` | string | No | `"full"` runs the entire session inside an outer user namespace carrying your full subordinate-UID range (multi-UID podman). Requires `--net`; the session identity becomes namespace-root. See [Multi-UID containers](#multi-uid-containers-podman-full). |
| `docker_api` | boolean | No | `true` starts a podman docker-API socket for the session (see [Docker compatibility](#docker-compatibility)). Honored in CLI profiles too. |
```

- [ ] **Step 4: README — rewrite the Virt section's podman parts**

Current text (`README.md`, in "## Virt: Podman Containers and QEMU VMs"):

```
Two `fs` profiles add the actual device access and persistent storage:

- `--fs podman` — `/dev/net/tun` (for pasta-based container networking)
  plus a persistent container storage directory at
  `~/.local/state/sbx/virt/containers`.
- `--fs qemu` — `/dev/kvm` (KVM acceleration) plus a persistent VM image
  directory at `~/.local/state/sbx/virt/images`.

```bash
# Build and run containers, with images persisting across sessions
./sbx --fs sandbox --fs podman --net web --cli claude

# KVM-accelerated VMs, with disk images persisting across sessions
./sbx --fs sandbox --fs qemu --cli claude
```

**Known limitations (single-UID only):** images relying on `USER`,
cross-user `chown`, or setuid installs may degrade or fail. `sudo`/setuid
elevation inside a container cannot work (`no_new_privs` is inherited
from bwrap). Container/VM network egress still flows through the
session's `--net` profile and its nftables allow-listing — there is no
way for a container to bypass it (verified: a container under a
restrictive allow-list can reach an allowed host but is blocked from a
disallowed one, same as any other sandboxed process).
```

Use Edit (keep the "Known issue" no-net teardown paragraph below it untouched):

````
old_string:
Two `fs` profiles add the actual device access and persistent storage:

- `--fs podman` — `/dev/net/tun` (for pasta-based container networking)
  plus a persistent container storage directory at
  `~/.local/state/sbx/virt/containers`.
- `--fs qemu` — `/dev/kvm` (KVM acceleration) plus a persistent VM image
  directory at `~/.local/state/sbx/virt/images`.

```bash
# Build and run containers, with images persisting across sessions
./sbx --fs sandbox --fs podman --net web --cli claude

# KVM-accelerated VMs, with disk images persisting across sessions
./sbx --fs sandbox --fs qemu --cli claude
```

**Known limitations (single-UID only):** images relying on `USER`,
cross-user `chown`, or setuid installs may degrade or fail. `sudo`/setuid
elevation inside a container cannot work (`no_new_privs` is inherited
from bwrap). Container/VM network egress still flows through the
session's `--net` profile and its nftables allow-listing — there is no
way for a container to bypass it (verified: a container under a
restrictive allow-list can reach an allowed host but is blocked from a
disallowed one, same as any other sandboxed process).

new_string:
Three `fs` profiles add device access and persistent storage:

- `--fs podman` — single-UID rootless podman: `/dev/net/tun` plus a
  persistent container store at `~/.local/state/sbx/virt/containers`.
  Composes with everything (real-user identity), works offline with
  cached images. Images that switch UIDs (`USER` directives, service
  images like postgres/nginx that drop privileges) will fail — use
  `podman-full` for those.
- `--fs podman-full` — multi-UID podman with full image fidelity: the
  whole session runs inside an outer user namespace carrying your
  subordinate-UID range (`/etc/subuid`), with its own persistent store
  at `~/.local/state/sbx/virt/containers-full`. Requires `--net`.
- `--fs qemu` — `/dev/kvm` (KVM acceleration) plus a persistent VM image
  directory at `~/.local/state/sbx/virt/images`.

```bash
# Root-only containers, composes with anything (real-user identity)
./sbx --fs sandbox --fs podman --net web --cli claude

# Full image fidelity (postgres/USER images), ns-root session
./sbx --fs sandbox --fs podman-full --net web

# KVM-accelerated VMs, with disk images persisting across sessions
./sbx --fs sandbox --fs qemu --cli claude
```

### Multi-UID containers (podman-full)

`"userns": "full"` sessions run as **namespace-root**: `id` reports
uid 0, host files you own appear owned by root, other users' files
appear as `nobody`, and files created by container-interior UIDs land on
the host owned by your subordinate range. This grants no authority
beyond what `/etc/subuid` already delegates to you — but euid 0 changes
program *behavior*: chromium refuses to run as root without
`--no-sandbox`, Claude Code refuses `--dangerously-skip-permissions` as
root, and installers take we-are-root paths. Don't compose `podman-full`
with the chrome profile or root-averse agent CLIs; use plain `podman`
there. If `unshare` fails with a mapping error, your user has no
`/etc/subuid`/`/etc/subgid` range — add one (e.g.
`sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER`).

The two container stores are intentionally separate (single-UID and
multi-UID ownership layouts are incompatible); an image used in both
modes is pulled twice. `containers-full` contents are owned by
subordinate UIDs on the host — clean up with `podman system reset`
inside a `podman-full` session, not bare `rm -rf`.

### Docker compatibility

Every session gets a `docker` CLI (a shim that execs `podman`) and a
`DOCKER_HOST` pointing at the session's podman API socket path. The
socket itself is served by `podman system service` only in sessions
whose profile sets `"docker_api": true` (both podman profiles do), so
docker SDKs, `docker compose`, and testcontainers work there; in other
sessions socket clients fail with a clear connection error while the
CLI shim still works. Host-side docker/podman sockets are never exposed
inside a sandbox — containers must run inside the session so its
nftables egress allow-listing applies.

**Known limitations:** `sudo`/setuid elevation inside a container cannot
work under either profile (`no_new_privs` is inherited from bwrap).
Container/VM network egress still flows through the session's `--net`
profile and its nftables allow-listing — there is no way for a container
to bypass it (verified: a container under a restrictive allow-list can
reach an allowed host but is blocked from a disallowed one, same as any
other sandboxed process).
````

- [ ] **Step 5: Commit**

```bash
git add profiles/fs/podman-full.json README.md
git commit -m "Add podman-full profile and phase 2 docs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- profiles/fs/podman-full.json README.md
```

---

### Task 5: End-to-end verification + spec reconciliation

**Files:**
- Modify: `docs/superpowers/specs/2026-07-19-sbx-virt-phase2-design.md` (Status line + any empirical corrections)

**Interfaces:**
- Consumes: everything from Tasks 1-4, exercised through the real `./sbx` and the tracked profiles (not scratch fs profiles — this validates what ships).
- Produces: verified feature; spec updated to observed reality.

- [ ] **Step 1: Service-image acceptance test (privilege drop)**

```bash
./sbx --fs podman-full --net _virttest -- sh -c \
  'timeout 90 podman run --rm -e POSTGRES_PASSWORD=x docker.io/library/postgres:16-alpine 2>&1 | grep -m1 "ready to accept connections" && echo PG-OK'
```

Expected: `... ready to accept connections` then `PG-OK` — postgres starts as root and successfully drops to the `postgres` user, the canonical multi-UID operation. (First run pulls the image; 90s allows for that.)

- [ ] **Step 2: nftables egress verified inside a container under userns-full**

```bash
cat > .sbx/profiles/net/_restrict.json <<'EOF'
{
    "description": "scratch: restrictive allow-list",
    "dns": "1.1.1.1",
    "allow": ["example.com", "*.docker.io", "*.docker.com", "*.cloudflare.docker.com"],
    "ports": ["*"]
}
EOF
./sbx --fs podman-full --net _restrict -- podman run --rm docker.io/library/alpine:latest sh -c \
  'wget -qO- -T 5 http://example.com >/dev/null && echo ALLOWED-OK; wget -qO- -T 5 http://google.com >/dev/null 2>&1 && echo LEAK-FAIL || echo BLOCKED-OK'
```

Expected: `ALLOWED-OK` and `BLOCKED-OK`. `LEAK-FAIL` means containers bypass nftables under the outer userns — a release blocker; STOP and root-cause (alpine is served from the podman-full store pulled in Task 2/Step 1; the docker.io entries cover a re-pull if needed).

- [ ] **Step 3: `--gui` composes with userns-full**

```bash
./sbx --gui --fs podman-full --net _virttest -- sh -c 'xdpyinfo >/dev/null 2>&1 && echo GUI-OK || echo GUI-FAIL'
```

Expected: `GUI-OK` (X server reachable through the bound socket as ns-root). If `xdpyinfo` is not installed, substitute `timeout 3 xeyes` and treat exit 124 as GUI-OK.

- [ ] **Step 4: Cross-session persistence + store isolation**

```bash
./sbx --fs podman-full --net _virttest -- podman images --format '{{.Repository}}'
./sbx --fs podman --net _virttest -- podman images --format '{{.Repository}}'
```

Expected: first (full store) lists `docker.io/library/postgres` (and alpine) **without pulling**; second (single-UID store) does NOT list postgres — the stores are isolated in both directions.

- [ ] **Step 5: Full regression sweep**

```bash
./sbx -- bash -c 'true' && echo PLAIN-OK
./sbx --net _virttest -- sh -c 'echo NET-OK'
./sbx --gui -- sh -c 'echo GUI-SESSION-OK'
./sbx --fs podman --net _virttest -- podman run --rm docker.io/library/alpine:latest echo SINGLE-UID-OK 2>&1 | tail -1
./sbx --fs chrome -- sh -c 'echo XDG=$XDG_RUNTIME_DIR'
sleep 1; pgrep -af 'pasta|podman system service' || echo NO-STRAGGLERS
```

Expected: `PLAIN-OK`, `NET-OK`, `GUI-SESSION-OK`, `SINGLE-UID-OK`, `XDG=/run/user/1000` (chrome profile env still wins over the sbx default), `NO-STRAGGLERS`. (A leftover `catatonit` would only appear after a *no-net* podman session — the known phase-1 issue, unchanged and out of scope.)

- [ ] **Step 6: Clean up scratch files**

```bash
rm -f .sbx/profiles/fs/_usernstest.json .sbx/profiles/fs/_fulltest.json
rm -f .sbx/profiles/net/_virttest.json .sbx/profiles/net/_restrict.json
rm -rf /tmp/sbx-usertest
```

- [ ] **Step 7: Reconcile the spec with observed behavior**

Edit `docs/superpowers/specs/2026-07-19-sbx-virt-phase2-design.md`:
- Change `**Status:** Approved design, not yet implemented` to `**Status:** Implemented and verified (<today's date>)`.
- Record the empirically observed `uid_map` layout and whether `pasta --netns-only` was required (Task 2 Step 5's finding) in the "`userns: full` — mechanism" section.
- If any verification step diverged from the spec's stated expectations (e.g. service startup quirks, storage path behavior), correct the spec's wording to the observed reality — do not leave assumptions uncorrected. If everything matched, only the Status line and the netns-only note change.

- [ ] **Step 8: Commit**

```bash
git add docs/superpowers/specs/2026-07-19-sbx-virt-phase2-design.md
git commit -m "Reconcile phase 2 spec with observed behavior

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- docs/superpowers/specs/2026-07-19-sbx-virt-phase2-design.md
```

---

## Self-Review Notes

- **Spec coverage:** field scan + validation → Task 1; launch chain, `_CONTAINERS_*` skip, rootful storage.conf, masked-subuid unchanged → Task 2; shim/DOCKER_HOST always-on, opt-in service with warn-not-fail and kill-on-exit, `podman.json` gains `docker_api` → Task 3; `podman-full.json`, README schema + Virt/docker sections, subuid-missing remedy, cleanup guidance → Task 4; spec verification items 1-11 → Task 2 Steps 5-7 (items 1, 2, 9-partial via Step 4 of Task 4) + Task 3 Step 6 (items 7, 8) + Task 4 Step 2 (item 9) + Task 5 (items 3, 4, 5, 6, 10, 11); spec reconciliation → Task 5 Step 7. Out-of-scope items (qemu, services framework) have no tasks — correct.
- **Placeholder scan:** none; every code step carries complete code; every verify step has a command and expected output.
- **Name consistency:** `USERNS_FULL`, `DOCKER_API`, `USERNS_PROFILE`, `PODMAN_SOCK`, `DOCKER_API_START`, `DOCKER_API_STOP` defined once (Tasks 1, 3) and used identically thereafter; `containers-full` path identical in Task 2 storage.conf, Task 2/4 profile mounts, and README.
- **Known empirical risk, handled in-plan:** `pasta --netns-only` behavior under the outer userns is the one unverified assumption; Task 2 Step 5 contains the exact decision procedure (check `uid_map`, try without the flag, STOP if the range collapses) and Task 5 Step 7 records the outcome in the spec.
