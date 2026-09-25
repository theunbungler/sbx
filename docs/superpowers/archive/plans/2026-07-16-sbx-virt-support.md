# sbx virt support (podman + qemu) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `sbx` sessions run rootless podman (build/pull/run containers) and KVM-accelerated qemu, with container/VM image state persisting across sessions in `~/.local/state/sbx/virt/`.

**Architecture:** `sbx` is a single bash script (`sbx`) that assembles a `bwrap` argument array and launches it (optionally under `pasta` for networking). This plan adds one new mount permission (`dev` → `--dev-bind`, needed for `/dev/kvm` and `/dev/net/tun`), auto-creation of missing `rw` mount source directories (so persistent storage dirs self-create on first use), a small always-on block that writes podman config files into the already-bound `$SESSION_DIR` and points `CONTAINERS_CONF`/`CONTAINERS_STORAGE_CONF` at them, and two new composable `fs` profiles (`podman.json`, `qemu.json`).

**Tech Stack:** bash, bubblewrap (`bwrap` 0.11.2), `jq`, `envsubst`, `podman`, `qemu-system-x86_64`/`qemu-img`.

**Reference:** `docs/superpowers/specs/2026-07-16-sbx-virt-support-design.md` (approved design; this plan implements it, with the simplification noted below).

**Design simplification vs. the spec:** the spec's "write configs into `$SESSION_DIR`, point env vars at them" idea does not need any extra bind mount — `$SESSION_DIR` is already bound 1:1 into the sandbox by the base `BWRAP_ARGS` (`--bind "$SESSION_DIR" "$SESSION_DIR"`, `sbx:214`), so writing the config files there before launch is sufficient; no `files` mechanism, no extra `--ro-bind`, no touching `$HOME/.config/containers`.

## Global Constraints

- Podman is the container engine. Never bind the host's `/var/run/docker.sock` into a sandbox (host dockerd is root; that socket is a trivial full escape) — not done anywhere in this plan, and no future change should do it either.
- `bwrap` 0.11.2 (already installed) is required for `--dev-bind`; no version bump needed.
- Multi-UID container support is explicitly out of scope (phase 2, `--userns-full`, not part of this plan). `cgroup_manager = "cgroupfs"` and `cgroups = "disabled"` are hard-coded, not configurable — they are the only values that can work inside bwrap (no user systemd/dbus is reachable in the sandbox).
- Every task's `git add` MUST name only the files that task touches. **The working tree already has unrelated pending edits** (`M profiles/net/gemini.json`, `D profiles/net/test_net.json`, `M profiles/net/web.json`, `M sbx`, plus untracked `profiles/cli/claude.json` / `profiles/net/anthropic.json`). Since `sbx` itself already has pending unrelated edits, any commit that touches `sbx` in this plan will necessarily include those too — that's expected and fine (they're the user's own prior in-progress work, not something to discard), just don't `git add -A`/`git add .` and don't touch `profiles/net/*` or `profiles/cli/claude.json` at all in this plan.
- No automated test suite exists in this repo. "Tests" in this plan are real invocations of `./sbx` (or bare `bwrap`) with concrete expected output — verify each step by actually running it, per the project's existing manual-verification convention (see `.sbx/profiles/fs/test.json`, a gitignored scratch profile already used this way).
- Scratch/throwaway profiles used only for verification go under `.sbx/profiles/{fs,net}/` (gitignored, per `.gitignore:1`), never under the tracked `profiles/` directory.

---

### Task 1: `dev` mount permission + auto-mkdir for `rw` mount sources

**Files:**
- Modify: `sbx:232-269` (`apply_mounts` function)

**Interfaces:**
- Produces: mount profiles may now use `"perm": "dev"` (maps to `--dev-bind SRC DEST`, required for device nodes — a plain `--bind`/`--ro-bind` mounts `nodev` and device opens fail). `rw` mount sources that don't exist on the host are auto-created with `mkdir -p` before the bind, so a profile can point at a not-yet-existing persistent directory and have it self-create on first use.
- Consumes: nothing new (no prior task).

- [ ] **Step 1: Reproduce the current gap with a scratch profile**

Create a throwaway profile (not tracked by git):

```bash
mkdir -p .sbx/profiles/fs
cat > .sbx/profiles/fs/_devtest.json <<'EOF'
{
    "description": "scratch: dev perm smoke test",
    "mounts": [
        { "source": "/dev/kvm", "dest": "/dev/kvm", "perm": "dev" }
    ]
}
EOF
./sbx --fs _devtest -- sh -c 'test -e /dev/kvm && echo HAVE-NODE; qemu-img create -f qcow2 /tmp/x.qcow2 1M >/dev/null && timeout 2 qemu-system-x86_64 -accel kvm -display none -serial none -monitor none -drive file=/tmp/x.qcow2,format=qcow2 2>&1 | tail -3'
```

Expected (current, broken behavior): the `case "$perm" in ro|rw|copy)` statement in `apply_mounts` has no `dev)` branch, so a mount with `perm: "dev"` is silently dropped — no bind happens at all. `test -e /dev/kvm` fails, so you see no `HAVE-NODE` line, and the qemu invocation errors (`No such file or directory` opening `/dev/kvm` or `-accel kvm` failing).

- [ ] **Step 2: Add the `dev` case and auto-mkdir for `rw` sources**

Current code (`sbx:232-269`):

```bash
apply_mounts() {
    local profile="$1"
    # Use jq to extract mounts
    mounts=$(jq -c '.mounts[]?' "$profile")
    [[ -z "$mounts" ]] && return

    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        source=$(echo "$m" | jq -r '.source' | envsubst)
        source=$(realpath -m "$source")
        dest=$(echo "$m" | jq -r '.dest' | envsubst)
        perm=$(echo "$m" | jq -r '.perm')

        # Ensure parent directories exist in the sandbox
        parent=$(dirname "$dest")
        if [[ "$parent" != "/" ]]; then
            IFS='/' read -ra ADDR <<< "$parent"
            curr=""
            for i in "${ADDR[@]}"; do
                if [[ -n "$i" ]]; then
                    curr="$curr/$i"
                    BWRAP_ARGS+=(--dir "$curr")
                fi
            done
        fi

        case "$perm" in
            ro)
                BWRAP_ARGS+=(--ro-bind "$source" "$dest")
                ;;
            rw)
                BWRAP_ARGS+=(--bind "$source" "$dest")
                ;;
            copy)
                COPY_MOUNTS+=("$source:$dest")
                ;;
        esac
    done <<< "$mounts"
}
```

Use Edit to apply this change:

```
old_string:
        perm=$(echo "$m" | jq -r '.perm')

        # Ensure parent directories exist in the sandbox

new_string:
        perm=$(echo "$m" | jq -r '.perm')

        # rw mounts may point at a persistent host directory that doesn't
        # exist yet (e.g. first-ever use of a profile's storage dir).
        if [[ "$perm" == "rw" && ! -e "$source" ]]; then
            mkdir -p "$source"
        fi

        # Ensure parent directories exist in the sandbox
```

```
old_string:
            rw)
                BWRAP_ARGS+=(--bind "$source" "$dest")
                ;;
            copy)

new_string:
            rw)
                BWRAP_ARGS+=(--bind "$source" "$dest")
                ;;
            dev)
                BWRAP_ARGS+=(--dev-bind "$source" "$dest")
                ;;
            copy)
```

- [ ] **Step 3: Re-run the scratch profile to verify the fix**

```bash
./sbx --fs _devtest -- sh -c 'test -e /dev/kvm && echo HAVE-NODE; qemu-img create -f qcow2 /tmp/x.qcow2 1M >/dev/null && timeout 2 qemu-system-x86_64 -accel kvm -display none -serial none -monitor none -drive file=/tmp/x.qcow2,format=qcow2 2>&1 | tail -3'
```

Expected: prints `HAVE-NODE`, `qemu-img` creates the image with no error, and the qemu invocation is killed by `timeout` after 2s (no `Could not access KVM` / `Permission denied` / `No such file` errors) — a clean timeout kill is success (it means the VM booted and kept running until we killed it).

- [ ] **Step 4: Verify the auto-mkdir behavior**

```bash
rm -rf /tmp/sbx-mkdir-test
cat > .sbx/profiles/fs/_rwtest.json <<'EOF'
{
    "description": "scratch: rw auto-mkdir smoke test",
    "mounts": [
        { "source": "/tmp/sbx-mkdir-test", "dest": "/tmp/sbx-mkdir-test", "perm": "rw" }
    ]
}
EOF
./sbx --fs _rwtest -- sh -c 'echo hello > /tmp/sbx-mkdir-test/f && cat /tmp/sbx-mkdir-test/f'
cat /tmp/sbx-mkdir-test/f  # confirm it persisted to the host path
rm -rf /tmp/sbx-mkdir-test .sbx/profiles/fs/_rwtest.json .sbx/profiles/fs/_devtest.json /tmp/x.qcow2
```

Expected: `/tmp/sbx-mkdir-test` did not exist beforehand; `sbx` created it (no "No such file or directory" error from `bwrap`'s `--bind`), the file write succeeds inside the sandbox, and `hello` is visible from the host afterward, confirming persistence. Clean up the scratch profiles afterward — they were only for this verification.

- [ ] **Step 5: Commit**

```bash
git add sbx
git commit -m "Add dev mount perm and auto-mkdir for rw mount sources"
```

---

### Task 2: Always-on podman config plumbing

**Files:**
- Modify: `sbx:228-230` (insert new block between the end of the net-profile branch and `COPY_MOUNTS=()`)

**Interfaces:**
- Produces: every session gets `$SESSION_DIR/virt/storage.conf`, `$SESSION_DIR/virt/containers.conf`, `$SESSION_DIR/virt/empty`; `CONTAINERS_STORAGE_CONF` and `CONTAINERS_CONF` env vars point at the first two; `/etc/subuid`/`/etc/subgid` are masked with the empty file (podman falls back to single-UID mapping instead of failing on `newuidmap`, which bwrap's `no_new_privs` blocks); `/var` is a tmpfs with `/var/tmp` present; `/run/user/$(id -u)` exists with `XDG_RUNTIME_DIR` defaulted to it (profile `env` still wins — the profile env loop at `sbx:301-319` runs after this block and appends later `--setenv` calls, so its output is honored last, matching bwrap's process-environment semantics); `/sys` is ro-bound.
- Consumes: `$SESSION_DIR` (already created at `sbx:193-195` before this point).

- [ ] **Step 1: Reproduce the current gap**

```bash
./sbx -- sh -c 'echo HOME=$HOME; test -d /var && echo HAS-VAR || echo NO-VAR; test -f /etc/subuid && echo HAS-SUBUID; env | grep -c XDG_RUNTIME_DIR'
```

Expected (current behavior): `NO-VAR` (no `/var` at all today — base `BWRAP_ARGS` never creates it), `/etc/subuid` is whatever the ro-bound host `/etc` provides (not masked), and `XDG_RUNTIME_DIR` is not set by sbx (count is 0 unless inherited from the host shell).

- [ ] **Step 2: Insert the always-on block**

Current code around the insertion point (`sbx:217-230`):

```bash
if [[ -n "$NET_PROFILE" ]]; then
    # When networking is enabled, pasta creates the user and net namespaces.
    # bwrap joins them and provides filesystem isolation.
    # We need to keep capabilities to allow dnscrypt-proxy and nftables to work.
    BWRAP_ARGS+=(--cap-add ALL)
else
    # Without networking, bwrap creates its own namespaces.
    # No --uid/--gid: bwrap defaults to mapping the real UID/GID into the
    # new user namespace, so the sandbox sees the same user/HOME identity
    # as the host (matches what the --net branch already does via pasta).
    BWRAP_ARGS+=(--unshare-user --unshare-net)
fi

COPY_MOUNTS=() # Array of "source:dest"
```

Use Edit to insert the new block between the `fi` and `COPY_MOUNTS=()`:

```
old_string:
    BWRAP_ARGS+=(--unshare-user --unshare-net)
fi

COPY_MOUNTS=() # Array of "source:dest"

new_string:
    BWRAP_ARGS+=(--unshare-user --unshare-net)
fi

# --- Virt (podman/qemu) base plumbing ---
# Always applied: adds no attack surface (nested single-UID userns was
# already reachable; masking subuid/subgid only reduces surface). The
# actual device access (/dev/kvm, /dev/net/tun) stays opt-in via the
# podman/qemu fs profiles.
VIRT_DIR="$SESSION_DIR/virt"
mkdir -p "$VIRT_DIR"

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

# cgroupfs/disabled are the only values that can work inside bwrap: the
# systemd cgroup manager needs a user systemd instance over dbus, which
# can't exist here (--unshare-ipc, /run is tmpfs).
cat > "$VIRT_DIR/containers.conf" <<'CONFEOF'
[containers]
cgroups = "disabled"

[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
CONFEOF

: > "$VIRT_DIR/empty"

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

- [ ] **Step 3: Re-run to verify**

```bash
./sbx -- sh -c 'echo HOME=$HOME; test -d /var/tmp && echo HAS-VAR-TMP; wc -c < /etc/subuid; echo XDG=$XDG_RUNTIME_DIR; cat $CONTAINERS_CONF'
```

Expected: `HAS-VAR-TMP` prints, `/etc/subuid` is 0 bytes (masked), `XDG_RUNTIME_DIR` is `/run/user/<your-uid>`, and `$CONTAINERS_CONF` prints the `[containers]`/`[engine]` block written above.

- [ ] **Step 4: Verify profile env still overrides the default (regression check)**

```bash
./sbx --fs chrome -- sh -c 'echo XDG=$XDG_RUNTIME_DIR'
```

Expected: `XDG=/run/user/1000` (chrome.json's own `env.XDG_RUNTIME_DIR` value, `profiles/fs/chrome.json:7`) — confirms the new default doesn't clobber an explicit profile setting, since the profile env loop (`sbx:301-319`) runs after this new block and its `--setenv` wins.

- [ ] **Step 5: Commit**

```bash
git add sbx
git commit -m "Add always-on podman config plumbing (storage.conf, containers.conf, subuid masking, /var, XDG_RUNTIME_DIR)"
```

---

### Task 3: `podman` and `qemu` fs profiles + docs

**Files:**
- Create: `profiles/fs/podman.json`
- Create: `profiles/fs/qemu.json`
- Modify: `README.md` (Mount Object table + new "Virt (podman/qemu)" section)

**Interfaces:**
- Consumes: `"perm": "dev"` and rw-source auto-mkdir from Task 1; `CONTAINERS_STORAGE_CONF`/`CONTAINERS_CONF` plumbing from Task 2 (specifically, `storage.conf`'s `rootless_storage_path` must equal the `dest` used here: `$HOME/.local/state/sbx/virt/containers`).
- Produces: `--fs podman` and `--fs qemu` flags usable by any `--cli`/`--net` combination.

- [ ] **Step 1: Create `profiles/fs/podman.json`**

```json
{
    "description": "Rootless podman: persistent container storage + tun for pasta networking",
    "mounts": [
        { "source": "/dev/net/tun", "dest": "/dev/net/tun", "perm": "dev" },
        { "source": "$HOME/.local/state/sbx/virt/containers", "dest": "$HOME/.local/state/sbx/virt/containers", "perm": "rw" }
    ]
}
```

- [ ] **Step 2: Create `profiles/fs/qemu.json`**

```json
{
    "description": "QEMU with KVM acceleration + persistent VM image directory",
    "mounts": [
        { "source": "/dev/kvm", "dest": "/dev/kvm", "perm": "dev" },
        { "source": "$HOME/.local/state/sbx/virt/images", "dest": "$HOME/.local/state/sbx/virt/images", "perm": "rw" }
    ]
}
```

- [ ] **Step 3: Verify profile discovery**

```bash
./sbx --list-profiles | grep -A3 'FS PROFILES'
```

Expected: `podman (Global)` and `qemu (Global)` appear alongside `chrome`, `default`, `sandbox`.

- [ ] **Step 4: Smoke-test podman profile (offline, no net profile)**

```bash
./sbx --fs podman -- podman info --format '{{.Store.GraphRoot}}'
```

Expected: prints `/home/<you>/.local/state/sbx/virt/containers/...` (podman initializes its storage there, not in an ephemeral tmpfs path) — confirms the profile's mount + Task 2's `storage.conf` agree on the same path.

- [ ] **Step 5: Update README Mount Object table**

Current text (`README.md`, Permission modes section):

```
- **`ro`** — Read-only bind mount. The sandbox sees the host directory but cannot modify it.
- **`rw`** — Read-write bind mount. Changes made inside the sandbox are reflected on the host.
- **`copy`** — Writable snapshot. The directory is copied into a tmpfs at session start. Changes inside the sandbox are **not** written back to the host. Instead, on session teardown, only **modified or new files** are compared against the original host source and saved to `~/.local/state/sbx/<session-id>/fs/<mount_id>/`. The original host directory is never modified.
```

Use Edit to append a fourth bullet:

```
old_string:
- **`copy`** — Writable snapshot. The directory is copied into a tmpfs at session start. Changes inside the sandbox are **not** written back to the host. Instead, on session teardown, only **modified or new files** are compared against the original host source and saved to `~/.local/state/sbx/<session-id>/fs/<mount_id>/`. The original host directory is never modified.

new_string:
- **`copy`** — Writable snapshot. The directory is copied into a tmpfs at session start. Changes inside the sandbox are **not** written back to the host. Instead, on session teardown, only **modified or new files** are compared against the original host source and saved to `~/.local/state/sbx/<session-id>/fs/<mount_id>/`. The original host directory is never modified.
- **`dev`** — Device bind mount (`--dev-bind`). Like `rw`, but allows device-node access (a plain `ro`/`rw` bind mounts `nodev`, so opening a device file would fail). Used for things like `/dev/kvm` and `/dev/net/tun`.
```

Also update the `perm` field row in the Mount Object table:

```
old_string:
| `perm` | string | Yes | Mount permission: one of `ro` (read-only bind), `rw` (read-write bind), or `copy` (writable snapshot) |

new_string:
| `perm` | string | Yes | Mount permission: one of `ro` (read-only bind), `rw` (read-write bind), `dev` (device bind, for files under `/dev`), or `copy` (writable snapshot) |
```

- [ ] **Step 6: Add a "Virt (podman/qemu)" README section**

Insert after the "Copy Mount Egress" section (end of `README.md`):

```markdown

## Virt: Podman Containers and QEMU VMs

Every session gets rootless-podman-friendly plumbing for free: a
generated `storage.conf`/`containers.conf` (overlay driver, cgroupfs
manager — the only manager that can work inside bwrap), `/etc/subuid`
and `/etc/subgid` masked (so podman falls back to single-UID mapping
instead of failing outright — bwrap's `no_new_privs` blocks the setuid
`newuidmap` helper multi-UID mapping needs), and a writable `/var/tmp`.

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
way for a container to bypass it.
```

- [ ] **Step 7: Commit**

```bash
git add profiles/fs/podman.json profiles/fs/qemu.json README.md
git commit -m "Add podman and qemu fs profiles with docs"
```

---

### Task 4: End-to-end verification and spec reconciliation

**Files:**
- Modify: `docs/superpowers/specs/2026-07-16-sbx-virt-support-design.md` (only if the empirical results below diverge from what it currently says — see Step 3)

**Interfaces:**
- Consumes: everything from Tasks 1-3, run through the real `./sbx` entry point (not bare `bwrap`), against real workloads.
- Produces: a verified, working feature; no new interfaces for later tasks (this is the last task).

- [ ] **Step 1: Container pull + run, with network profile (DNS-forwarding risk item)**

```bash
mkdir -p .sbx/profiles/net
cat > .sbx/profiles/net/_virttest.json <<'EOF'
{
    "description": "scratch: virt verification",
    "dns": "1.1.1.1",
    "allow": ["*"],
    "ports": ["*"]
}
EOF
./sbx --fs sandbox --fs podman --net _virttest -- \
  podman run --rm docker.io/library/alpine:latest \
  sh -c 'wget -qO- -T 5 http://example.com >/dev/null && echo NET-OK || echo NET-FAIL'
```

Expected: `NET-OK`. This is the spec's flagged risk item — the sandbox's own resolver is dnsmasq on `127.0.0.1`, and the container is on a *nested* pasta network one level down, so container DNS has to actually reach that resolver. If you see `NET-FAIL`, capture `podman run ... sh -c 'cat /etc/resolv.conf'` output and diagnose before proceeding to later steps — don't paper over it.

- [ ] **Step 2: Confirm persistence across two separate sessions**

```bash
./sbx --fs sandbox --fs podman -- podman run --rm docker.io/library/alpine:latest sh -c 'echo persisted > /tmp/marker; podman --version' 2>&1 | tail -1
# second, independent session:
./sbx --fs sandbox --fs podman -- podman images --format '{{.Repository}}:{{.Tag}}'
```

Expected: the second session's `podman images` lists `docker.io/library/alpine:latest` without re-pulling (confirms `~/.local/state/sbx/virt/containers` persisted between sessions).

- [ ] **Step 3: Confirm behavior WITHOUT the podman profile (reconcile with spec)**

```bash
./sbx --fs sandbox -- podman run --rm docker.io/library/alpine:latest echo hi 2>&1 | tail -5
```

The design spec currently states this should fail with "an obvious permission error." Run it and see what actually happens (it may instead succeed using ephemeral, non-persistent storage in the sandbox's tmpfs root, since `/` inside bwrap is a writable synthetic tmpfs unless explicitly bound elsewhere). Whichever it is, update the spec's "Failure mode without the profile" section to state the real observed behavior — do not leave the earlier assumption uncorrected.

- [ ] **Step 4: `USER`-based Dockerfile (documents the single-UID limitation)**

```bash
mkdir -p /tmp/sbx-dockerfile-test && cat > /tmp/sbx-dockerfile-test/Dockerfile <<'EOF'
FROM alpine
RUN adduser -D appuser
USER appuser
RUN touch /home/appuser/marker
EOF
./sbx --fs sandbox --fs podman -- sh -c 'cd /tmp/sbx-dockerfile-test 2>/dev/null || cd $(mktemp -d) && cp /tmp/sbx-dockerfile-test/Dockerfile . 2>/dev/null; podman build -t sbx-usertest /tmp/sbx-dockerfile-test' 2>&1 | tail -15
```

Expected: either succeeds (with `ignore_chown_errors` papering over ownership) or fails at the `USER appuser` / subsequent `RUN` step. Record which, in the spec's "Known limitations" section, replacing the current speculative wording with the real observed failure (or lack thereof).

- [ ] **Step 5: QEMU KVM boot through the real profile**

```bash
./sbx --fs sandbox --fs qemu -- sh -c '
  qemu-img create -f qcow2 ~/.local/state/sbx/virt/images/test.qcow2 1G
  timeout 4 qemu-system-x86_64 -accel kvm -display none -serial none -monitor none -drive file=$HOME/.local/state/sbx/virt/images/test.qcow2,format=qcow2
  echo "exit=$?"
'
ls -la ~/.local/state/sbx/virt/images/  # confirm image persisted on host
```

Expected: `exit=124` (killed by `timeout`, meaning it booted and ran), and `test.qcow2` is visible on the host afterward.

- [ ] **Step 6: Teardown / lingering-process check**

```bash
./sbx --fs sandbox --fs podman -- podman run --rm docker.io/library/alpine:latest echo done
sleep 1
pgrep -af 'catatonit|pasta' | grep -v grep || echo "NO-LINGERING-PROCESSES"
```

Expected: `NO-LINGERING-PROCESSES` (bwrap's `--unshare-pid`, already present in the base args at `sbx:200`, means the sandbox's pid-1 reaper tears down the whole pid namespace — including any podman pause/catatonit process — the moment the session's own command exits; this was confirmed to matter during design-phase testing, where a *host-side* pipe around a bare `bwrap` invocation hung on a lingering `catatonit` holding an inherited fd open). If this check fails (a `catatonit` or `pasta` process from this session is still running after it exits), that's a real regression — do not proceed to Step 7 until root-caused.

- [ ] **Step 7: Regression check on existing session types**

```bash
./sbx -- bash -c 'true' && echo PLAIN-OK
./sbx --net _virttest -- sh -c 'echo NET-SESSION-OK'
./sbx --gui -- sh -c 'echo GUI-SESSION-OK' &
sleep 3; jobs -l  # confirm the --gui session started without error, then Ctrl-D or let it finish
```

Expected: all three print their `*-OK` marker; no errors from the always-on virt plumbing (masked subuid, `/var` tmpfs, etc.) leaking into unrelated session types.

- [ ] **Step 8: Clean up scratch files**

```bash
rm -f .sbx/profiles/net/_virttest.json
rm -rf /tmp/sbx-dockerfile-test
```

(`.sbx/` is gitignored — nothing to unstage — but remove the scratch files so they don't confuse future ad hoc testing.)

- [ ] **Step 9: Commit spec reconciliation (if Step 3 or Step 4 changed its wording)**

```bash
git add docs/superpowers/specs/2026-07-16-sbx-virt-support-design.md
git commit -m "Reconcile virt design spec with empirically observed behavior"
```

If nothing in the spec needed correction, skip this commit.

## Self-Review Notes

- **Spec coverage:** always-on plumbing (spec §"Always-on base plumbing") → Task 2; schema changes (`dev` perm, auto-mkdir) → Task 1; `fs/podman.json`/`fs/qemu.json` → Task 3; persistence → Task 3 Step 4 + Task 4 Step 2; security notes → Global Constraints + README Step 6; verification plan (all 6 numbered items in the spec) → Task 4 Steps 1-7; phase 2 (`--userns-full`, docker-compat shim) → explicitly out of scope, not a gap.
- **Placeholder scan:** no TBDs; every step has runnable commands and, where code changes, complete diffs.
- **Type/name consistency:** `VIRT_DIR`, `CONTAINERS_STORAGE_CONF`, `CONTAINERS_CONF` names are introduced once in Task 2 and referenced identically in Task 3's profile paths and Task 4's verification commands.
