# sbx virt support: podman containers + qemu VMs inside the sandbox

**Date:** 2026-07-16
**Status:** Implemented and verified (2026-07-17)

## Goal

Let an LLM agent running inside an sbx sandbox create/modify/run container
images (podman, docker-compatible) and qemu VM images during experiments,
with correct functionality and minimal ceremony. Network egress from
containers/VMs must remain subject to the sandbox's nftables allow-listing.

Podman is the container engine (not dockerd). Rootless dockerd inside bwrap
is fragile (rootlesskit, iptables, no_new_privs conflicts); podman builds and
runs standard OCI/Docker images and can expose a docker-compatible socket
later if needed.

## Empirically verified facts (2026-07-16, this host)

- Nested user namespaces work inside bwrap, but **single-UID only**:
  `newuidmap` fails (`Could not set caps`) because bwrap sets
  `no_new_privs`, which disables setuid helpers. Multi-UID mapping is
  impossible inside bwrap, full stop.
- Single-UID rootless podman works end-to-end inside bwrap (pull alpine,
  run container, working container networking via nested pasta) given:
  `/sys` ro-bound, a writable `/var/tmp`, `XDG_RUNTIME_DIR` +
  `/run/user/$UID`, `/etc/subuid`+`/etc/subgid` masked (else podman tries
  newuidmap and dies instead of falling back), `/dev/net/tun` dev-bound,
  writable storage dir, `cgroup_manager=cgroupfs` + `cgroups=disabled`.
- `qemu-img` and KVM-accelerated `qemu-system-x86_64` work inside bwrap
  with only `/dev/kvm` dev-bound (`--dev-bind`; plain `--bind` mounts
  `nodev` so device opens fail). TCG works with zero changes.
- `unshare --map-auto --map-root-user` before bwrap provides the full
  65536-UID subordinate range, and bwrap nests inside it (phase 2 basis).
- Podman leaves a `catatonit -P` pause process holding inherited fds; it
  kept the test pipeline from exiting. Watch for this in session teardown.
- **(Found during implementation, 2026-07-17)** Combining `--net` with
  `--fs podman` broke container *creation* (not pulls) with `crun: mount
  devpts to dev/pts: Invalid argument`. Root cause: `sbx`'s pre-existing
  net-profile branch doesn't `--unshare-user` — it joins pasta's
  namespaces and adds `--cap-add ALL`, so the sandboxed process looks like
  real root (`uid=0`, full capability bits) to podman. podman/crun decide
  rootless-vs-rootful by checking `geteuid()==0`, not actual privilege, so
  seeing uid=0 they skip the rootless single-UID-mapping fallback and
  attempt a devpts mount assuming a real system `gid=5` exists — which
  isn't valid in this still-single-identity-mapped namespace. Fixed by
  setting `_CONTAINERS_USERNS_CONFIGURED=done`,
  `_CONTAINERS_ROOTLESS_UID=$(id -u)`, `_CONTAINERS_ROOTLESS_GID=$(id -g)`
  in the net-profile branch only (these are documented
  `containers/common` overrides for exactly this "nested namespace where
  EUID==0 isn't real privilege" situation). Confirmed the fix doesn't
  touch networking (egress is still fully gated by the session's nftables
  allow-list) and confirmed it must stay net-profile-scoped (applying it
  unconditionally breaks the no-net path's already-correct native
  detection with an unrelated overlay-mount error).

## Design

### Always-on base plumbing in sbx

These apply to every session (each is harmless-to-beneficial generally):

1. Write `storage.conf` and `containers.conf` into `$SESSION_DIR/` (which
   is already bound into the sandbox) and set `CONTAINERS_STORAGE_CONF` /
   `CONTAINERS_CONF` env vars pointing at them. No mounts over
   `$HOME/.config/containers`; the host's own podman config is untouched.

   ```toml
   # storage.conf
   [storage]
   driver = "overlay"
   rootless_storage_path = "$HOME/.local/state/sbx/virt/containers"
   [storage.options.overlay]
   ignore_chown_errors = "true"

   # containers.conf
   [containers]
   cgroups = "disabled"
   [engine]
   cgroup_manager = "cgroupfs"
   events_logger = "file"
   ```

   `rootless_storage_path` supports `$HOME` expansion natively.
   cgroupfs/disabled are constants of the environment, not tunables: the
   systemd cgroup manager needs a user systemd instance over dbus, which
   cannot exist inside bwrap (`--unshare-ipc`, tmpfs `/run`), and rootless
   cgroup writes need systemd delegation.

2. Mask `/etc/subuid` and `/etc/subgid` by ro-binding an empty session
   file over each. Multi-UID cannot work under bwrap anyway; masking makes
   podman fall back cleanly to single mapping instead of erroring.

3. `--tmpfs /var` + `--dir /var/tmp`. The sandbox currently has no `/var`
   at all; container image pulls need `/var/tmp`, and other tools benefit.

4. `--dir /run/user/$UID` + default `--setenv XDG_RUNTIME_DIR
   /run/user/$UID`, emitted before profile env so profile values win
   (chrome.json already sets its own).

5. `--ro-bind /sys /sys` (podman needs cgroup mode detection).

6. **Net-profile-only:** when a `--net` profile is active, also set
   `_CONTAINERS_USERNS_CONFIGURED=done`, `_CONTAINERS_ROOTLESS_UID=$(id -u)`,
   `_CONTAINERS_ROOTLESS_GID=$(id -g)`. Not applied in the no-net path —
   see the devpts finding above for why this is scoped to the net branch.

### Profile schema changes (sbx)

- New mount perm `"dev"` → `--dev-bind` (device nodes; `ro`/`rw` mount
  `nodev`).
- Auto-`mkdir -p` missing **source** dirs for `rw` mounts, so persistent
  storage self-creates on first use.

The previously considered `tmpfs`, `mask`, and `files` profile concepts
are not needed and are not added.

### New fs profiles (pure mounts, composable)

`profiles/fs/podman.json`:

```json
{
    "description": "Rootless podman: container storage + nested-pasta networking",
    "mounts": [
        { "source": "/dev/net/tun", "dest": "/dev/net/tun", "perm": "dev" },
        { "source": "$HOME/.local/state/sbx/virt/containers",
          "dest": "$HOME/.local/state/sbx/virt/containers", "perm": "rw" }
    ]
}
```

`profiles/fs/qemu.json`:

```json
{
    "description": "QEMU with KVM acceleration + persistent VM image dir",
    "mounts": [
        { "source": "/dev/kvm", "dest": "/dev/kvm", "perm": "dev" },
        { "source": "$HOME/.local/state/sbx/virt/images",
          "dest": "$HOME/.local/state/sbx/virt/images", "perm": "rw" }
    ]
}
```

Usage: `sbx --fs sandbox --fs podman --fs qemu --net web --cli claude`.

### Persistence

`~/.local/state/sbx/virt/` is shared across sessions by design (images the
agent builds/pulls survive). It is only writable in sessions that apply
the corresponding profile. Cross-session contamination is accepted;
`podman system reset` inside a sandbox clears container state.

### Failure mode without the profile

**(Corrected after verification — the original assumption below was wrong.)**
The always-on config points storage at a path that isn't mounted rw, but
this does **not** produce a permission error. bwrap's synthetic `/` is a
writable tmpfs by default (nothing explicitly binds `/` itself), so
podman/containers-storage silently falls back to using that ephemeral
root instead. Pulls and runs succeed normally; nothing about the session
looks broken. The only difference is durability: none of it survives
session teardown, since it never touched the real
`~/.local/state/sbx/virt/containers` path at all. There is no explicit
error to catch this — an agent that forgets `--fs podman` gets working
but silently non-persistent container storage, not a failure.

## Security notes

- Always-on parts add no attack surface: nested single-UID userns was
  already reachable, and masking subuid *reduces* surface.
- The opt-in dev-binds are the only widenings: `/dev/kvm` exposes the KVM
  ioctl surface; `/dev/net/tun` exposes the tuntap driver. That is why
  they live in per-session profiles, not the base.
- Container/VM egress uses ordinary sockets from sandboxed processes
  (nested pasta / qemu user-mode net), so the sandbox nftables
  allow-listing still applies.
- Never bind the host's `/var/run/docker.sock` into a sandbox: host
  dockerd is root; that socket is a trivial full escape.

## Verification plan (results, 2026-07-17)

Run through the real sbx entry point, not bare bwrap. All items below
were executed against the actual implementation, not simulated.

1. ✅ Pull + run works both with and without a `--net` profile (the
   no-net case uses cached images only, per the corrected "Failure mode
   without the profile" section above).
2. ✅ **Key risk item resolved, non-issue:** DNS forwarding to the
   sandbox's dnsmasq resolver works correctly — image pulls always
   succeeded through `--net`. What actually blocked this step initially
   was the unrelated devpts bug (see Empirically verified facts), now
   fixed; with the fix, `podman run --rm alpine wget ... http://example.com`
   succeeds end-to-end under `--net`.
3. ✅ `USER`-based Dockerfile: confirmed the expected single-UID
   limitation cleanly (once separated from the devpts bug) — base image
   builds, `USER appuser` step succeeds, but a subsequent `RUN` as that
   user fails with `setresgid to \`1000\`: Invalid argument`. Matches the
   Known limitations section below exactly.
4. ✅ `sbx --fs qemu` — `qemu-img create` + KVM-accelerated boot via
   `timeout 4 qemu-system-x86_64 -accel kvm -display none ...`, killed by
   `timeout` (exit 124 = success, still running). Image persisted on host
   afterward.
5. ✅ Teardown confirmed clean (zero lingering `catatonit`/`pasta`
   processes) for a session that completes normally and undisturbed.
   Note: external tools wrapping `sbx` in their own `timeout` can SIGTERM
   the calling shell without propagating through the abduco/pasta/bwrap
   chain, orphaning processes — that's a caller-side hazard, not a defect
   in `sbx`'s own teardown path (which was independently confirmed clean).
6. ✅ Regression-checked: plain `sbx -- bash -c 'true'` session, a
   `--net`-only (no podman) session, and a `--gui` session (xpra started,
   `DISPLAY` set, torn down cleanly) all still work; chrome.json's
   `XDG_RUNTIME_DIR` still overrides the new default.
7. ✅ Cross-session persistence confirmed: a second, independent
   `sbx --fs podman` session's `podman images` lists a previously-pulled
   image without re-pulling.
8. ✅ **New finding, root-caused and fixed:** `--net` + `--fs podman`
   container creation failure (devpts/EINVAL) — see Empirically verified
   facts above for the full root cause and fix.

## Known limitations (accepted for phase 1)

- Single UID: Dockerfiles using `USER`, cross-user chown, or setuid
  installs degrade or fail (`ignore_chown_errors` fakes ownership).
- `sudo`/setuid inside containers cannot elevate (no_new_privs is
  inherited by everything under bwrap).
- IPv6 egress is dropped by the existing nftables rules; containers
  inherit that.

## Phase 2 (deferred, composes without rework)

- `--userns-full` flag: wrap the launch in `unshare --map-auto
  --map-root-user` → pasta → bwrap, giving podman the full subordinate-UID
  range (verified mechanism). Sandbox identity becomes ns-root; host files
  owned by other users appear as `nobody`; pasta/dnsmasq/nftables need
  re-verification inside the outer userns.
- Docker-compat shim: `podman system service` socket + `DOCKER_HOST`
  and/or a `docker` alias for agents that reach for the docker CLI.
