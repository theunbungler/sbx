# sbx virt support: podman containers + qemu VMs inside the sandbox

**Date:** 2026-07-16
**Status:** Approved design, pending implementation plan

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

The always-on config points storage at a path that isn't mounted rw, so
podman fails with an obvious permission error. No partial states.

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

## Verification plan

Run through the real sbx entry point, not bare bwrap:

1. `sbx --fs podman -- podman run --rm docker.io/library/alpine:latest
   sh -c 'echo ok'` (no net profile: expect pull to fail, run of cached
   image to succeed — documents offline behavior).
2. `sbx --fs podman --net web -- podman run --rm alpine wget -qO-
   http://example.com` — **key risk item:** the sandbox resolver is
   dnsmasq on `127.0.0.1`; podman/pasta must forward container DNS to a
   loopback resolver (pasta `--dns-forward`). Verify against the nftables
   rules; if broken, containers may need `--dns` pointing at the upstream
   or an nft rule tweak.
3. `podman build` of a Dockerfile with `RUN apt-get install` (expect:
   works with warnings) and one with `USER nobody` (expect: degraded —
   document).
4. `sbx --fs qemu -- qemu-img create` + short KVM boot
   (`timeout 4 qemu-system-x86_64 -accel kvm -display none ...` exiting
   via timeout = success).
5. Confirm session teardown is not hung by a surviving `catatonit`
   process; kill it in the wrapper's exit path if needed.
6. Regression: a plain `sbx -- bash -c 'true'` session and a
   `--net`/`--gui` session still work; chrome.json's `XDG_RUNTIME_DIR`
   overrides the new default.

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
