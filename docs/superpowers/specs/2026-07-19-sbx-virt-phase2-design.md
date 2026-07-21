# sbx virt phase 2: multi-UID podman (`userns: full`) + docker compat

**Date:** 2026-07-19
**Status:** Implemented and verified (2026-07-20)

**Builds on:** `2026-07-16-sbx-virt-support-design.md` (phase 1, implemented
and verified). Phase 1's always-on plumbing, `dev` mount perm, and the
single-UID `podman`/`qemu` fs profiles are unchanged by this design.

## Goal

1. Make images that switch UIDs work: `USER` directives, and official
   service images (postgres, mysql, nginx, redis, …) that start as root
   and drop to a service user — the single most common failure of the
   phase 1 single-UID setup (`setresgid to '1000': Invalid argument`).
2. Make agents that reach for docker work: a `docker` CLI and a
   docker-API socket (docker-py, docker compose, testcontainers).

Hard requirement carried over from phase 1: container/VM network egress
must remain subject to the session's nftables allow-listing. Containers
must therefore run *inside* the sandbox — never via a host-side daemon
socket (see Security notes).

## Design decisions (with rationale)

- **No new CLI flags.** Activation is entirely profile-driven, matching
  sbx's "profiles shape the session" philosophy. Two new *optional*
  profile fields, honored in any applied fs/cli profile:
  - `"userns": "full"` — run the session inside an outer user namespace
    with the user's full subordinate-UID range.
  - `"docker_api": true` — start a podman docker-API socket for the
    session.
- **Two podman profiles, not one.** `podman.json` stays single-UID: it
  works offline, and composes with chrome/`--gui`/agent CLIs because the
  session keeps its real-user identity. New `podman-full.json` opts into
  `userns: full` for image fidelity. The euid-0 behavioral quirks
  (below) are confined to sessions that chose them.
- **Docker shim split by cost.** The `docker` exec-shim and `DOCKER_HOST`
  are free and always on. The background `podman system service` is the
  only costly piece, so it is opt-in via `docker_api`.

## `userns: full` — mechanism

Why ns-root: multi-UID mapping inside bwrap is impossible (phase 1
finding: `no_new_privs` disables the setuid `newuidmap` helper, full
stop). The outer namespace claims the user's `/etc/subuid` range *before*
bwrap applies `no_new_privs` (via `unshare`, where the setuid helper
still works). Inside, the session is ns-root; podman sees euid 0 and
runs "rootful-in-namespace", writing container UID maps directly with
its own in-namespace CAP_SETUID — no setuid helpers needed.

This grants no authority beyond what `/etc/subuid` already delegates to
the user: the host kernel never sees anything but the user's own uid
plus their subordinate range — the same range rootless podman uses via
`newuidmap` on any normal host. (There is no podman analog of the docker
group: docker-group delegation works by handing users the socket of an
already-root daemon; podman is daemonless, and its delegation mechanism
*is* `newuidmap` + `/etc/subuid`.)

Behavior when any applied profile sets `"userns": "full"`:

- **Requires `--net`.** Hard error, before launch, if no net profile is
  active. (Rationale: multi-UID podman is nearly useless offline — no
  pulls — and the no-net podman path has a known teardown leak.)
- **Launch chain:** `unshare --map-auto --map-root-user → pasta
  --netns-only → bwrap → abduco → wrapper.sh`. pasta, dnsmasq, and
  nftables now run as ns-root inside the outer userns — re-verified by
  the verification plan, not assumed. `--netns-only` is **required**:
  confirmed empirically that without it, pasta's own namespace setup
  collapses `/proc/self/uid_map` back to a single-line (single-UID)
  mapping, silently discarding the outer `unshare`'s 65536-UID range.
  With the flag, the range survives, but pasta prints harmless stderr
  noise on every launch (`Couldn't write to /proc/self/uid_map` /
  `Couldn't configure user mappings`) — it's attempting to write a
  mapping the outer `unshare` already configured. Expected, not a
  failure.
- **Composes with `--gui`:** xpra stays host-side; the X socket bind and
  FamilyWild cookie don't involve uid. Verified, not assumed.
- **Mode-conditional storage config:** sbx writes a *different*
  `storage.conf` for these sessions:

  ```toml
  [storage]
  driver = "overlay"
  graphroot = "<expanded $HOME>/.local/state/sbx/virt/containers-full"
  ```

  `graphroot` (rootful) instead of `rootless_storage_path`; expanded at
  write time by sbx (HOME inside the sandbox equals host HOME). No
  `ignore_chown_errors` — ownership is real in this mode. `runroot`
  stays default (`/run` is a writable tmpfs); if podman objects during
  implementation, set it explicitly under `/run`.
- **Skips the `_CONTAINERS_*` overrides** (`_CONTAINERS_USERNS_CONFIGURED`
  etc. from phase 1's net branch): they force podman onto the rootless
  single-UID path, which is exactly wrong here. Rootful-in-ns podman
  needs no override — euid 0 is now backed by a real multi-UID mapping.
  (Side benefit: sessions in this mode don't depend on those fragile
  internal env vars at all.)
- **`/etc/subuid`/`/etc/subgid` stay masked** (phase 1 always-on
  plumbing): rootful podman doesn't consult them.

### Container egress under `userns: full` (found and fixed during implementation)

**This corrects an assumption the original design got wrong.** The Goal
and Security notes below stated the phase-1 nftables table would continue
to gate container egress under `userns: full` without changes. Task 5's
end-to-end verification found this false and release-blocking: rootful
podman under `userns: full` uses netavark's **bridge** network backend
(not the user-mode networking phase 1's single-UID podman uses), so
container traffic is bridge-forwarded and traverses the kernel's
`forward` hook — never `output`. Phase 1's `sbx_filter` table only hooked
`output`, so it never saw this traffic at all: a `podman-full` container
could reach any host, completely bypassing the net profile's allow-list,
regardless of what the profile said. Confirmed with a restrictive
allow-list: an explicitly disallowed host was reachable from inside a
container while the sandbox's own process-level egress was correctly
gated.

**Fix 1 — forward-chain filtering.** `sbx_filter` gains a second chain:

```
chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    <same CIDR/allowed4/port rules as output>
    meta nfproto ipv6 drop
}
```

The CIDR/`allowed4`/port-gating logic is shared with the `output` chain
via a new `emit_egress_allow_rules` function (extracted, not duplicated).
The forward chain deliberately omits `output`'s lo/DNS-to-127.0.0.1/
DNS-to-upstream accepts — see Fix 2 for why those aren't needed there.
Verified in both directions: an allowed CIDR destination is reachable
from inside a container (received a real HTTP response); a disallowed
one is dropped at the network layer, not merely application-rejected.

**Fix 2 — hostname-based allow-listing needs a DNS-enabled network.**
Fixing the leak surfaced a second, non-security gap: hostname-based
`allow` entries (e.g. `"allow": ["example.com"]`) didn't resolve for
`podman-full` containers *at all*, even under a fully permissive
`"allow": ["*"]` profile. Root cause: podman's **implicit default**
bridge network ships with `dns_enabled=false`; only an **explicitly
created** custom network defaults to `dns_enabled=true`. Without it,
container DNS queries go straight to public resolvers (podman's
built-in fallback, e.g. `8.8.8.8`) — traffic the new forward chain
correctly drops (no leak) but which also means hostnames never resolve,
since that public-DNS traffic was never allow-listed either.

The fix: sbx now creates a dedicated `sbx0` podman network (DNS-enabled
by construction) and points `containers.conf`'s `default_network` at it,
both gated on `userns: full`:

- `containers.conf` gains, only in this mode:
  ```toml
  [network]
  default_network = "sbx0"
  ```
- The wrapper idempotently runs `podman network create sbx0` before the
  user's command (harmless "already exists" on repeat sessions; stderr
  is appended to `$VIRT_DIR/network-create.log` rather than discarded,
  so a genuine creation failure — disk full, permissions — leaves a
  trace; empirically confirmed podman fails loudly downstream, `Error:
  ... network not found`, exit 125, if the network is ever actually
  missing, rather than silently falling back to an unfiltered network).

On a DNS-enabled network, podman/netavark runs `aardvark-dns` as the
container-facing resolver; it inherits the *sandbox's own*
`/etc/resolv.conf` (127.0.0.1 → sbx's own dnsmasq) as its upstream. So a
container's hostname lookup now transits dnsmasq's existing `--nftset`
mechanism exactly like a sandbox-process lookup does, populating the same
`allowed4` nftables set the forward chain gates on. Verified end-to-end:
under a restrictive hostname-based profile, an allowed hostname resolves
and connects; a disallowed one is blocked — fully automatic, no manual
`--network` flag needed.

**New host prerequisite:** `netavark` and `aardvark-dns` must be
installed on the host for hostname-based `allow` entries to work for
`podman-full` containers. CIDR-based `allow` entries work regardless
(no DNS dependency). If these packages are absent, `podman network
create sbx0` still succeeds (network objects don't require them), but
the resulting network's DNS won't function — container hostname
lookups will fail to resolve (dropped by the forward chain, same as
today, not a leak) rather than silently succeeding unfiltered.

### Identity consequences (accepted, documented)

In-session identity is `root` (uid 0). `HOME` and env pass through
unchanged. Host files the user owns appear owned by root; files owned by
other host users appear as `nobody`; files created in the sandbox map
back to the user's uid on the host — except files created as
container-interior UIDs, which land on the host owned by the user's
subordinate range.

Known euid-0 behavioral breakages (why this is opt-in per profile):
chromium refuses to run as root without `--no-sandbox`; Claude Code
refuses `--dangerously-skip-permissions` as root; pip/npm/installers
take we-are-root paths. Do not compose `podman-full` with the chrome
profile or root-averse agent CLIs; use plain `podman` there.

## Docker compat

### Always on (every session, both modes)

- sbx writes `$SESSION_DIR/bin/docker` at session start:

  ```sh
  #!/bin/sh
  exec podman "$@"
  ```

  and prepends `$SESSION_DIR/bin` to the sandbox PATH. `$SESSION_DIR`
  is already bound into every sandbox — no new mounts. (The host docker
  socket is never bound in — phase 1 security rule — so shadowing the
  `docker` name cannot hide a legitimate docker.)
- `DOCKER_HOST=unix:///run/user/<uid>/podman/podman.sock` is set in
  every session. podman honors `CONTAINER_HOST`, not `DOCKER_HOST`, so
  this never redirects the local podman CLI; it only serves docker
  SDKs/compose/testcontainers.

Cost of always-on: zero processes; in sessions without a service the
socket path simply doesn't exist and socket clients fail with a clear
connection error.

### Opt-in service (`"docker_api": true`)

If any applied fs/cli profile sets `"docker_api": true`, `wrapper.sh`
gains a pre-command block. The socket path is the sbx-computed
`/run/user/<uid>/podman/podman.sock` — the same literal path baked into
`DOCKER_HOST` — *not* the runtime `$XDG_RUNTIME_DIR`, which a profile
may override and would silently diverge from `DOCKER_HOST`:

1. `mkdir -p /run/user/<uid>/podman`
2. `podman system service --time=0 unix:///run/user/<uid>/podman/podman.sock &`
3. Poll for the socket (up to ~5s). If it never appears: print a
   **warning** and continue — the exec-shim still works without the
   service. (Contrast: nft/dnsmasq failures remain hard errors;
   egress safety is never best-effort.)
4. After the user command exits, kill the service (same pattern as the
   dnsmasq pid handling).

Identical in both modes; the explicit socket URI sidesteps podman's
rootful-vs-rootless default socket path split.

## Profile changes

`profiles/fs/podman.json` (existing) — gains `"docker_api": true`,
mounts unchanged:

```json
{
    "description": "Rootless podman (single-UID): persistent storage, tun, docker API socket",
    "docker_api": true,
    "mounts": [
        { "source": "/dev/net/tun", "dest": "/dev/net/tun", "perm": "dev" },
        { "source": "$HOME/.local/state/sbx/virt/containers",
          "dest": "$HOME/.local/state/sbx/virt/containers", "perm": "rw" }
    ]
}
```

`profiles/fs/podman-full.json` (new):

```json
{
    "description": "Multi-UID podman (ns-root session; requires --net): full image fidelity, docker API socket",
    "userns": "full",
    "docker_api": true,
    "mounts": [
        { "source": "/dev/net/tun", "dest": "/dev/net/tun", "perm": "dev" },
        { "source": "$HOME/.local/state/sbx/virt/containers-full",
          "dest": "$HOME/.local/state/sbx/virt/containers-full", "perm": "rw" }
    ]
}
```

Phase 1's rw-source auto-mkdir creates `containers-full` on first use.
Unknown profile fields are ignored by phase 1 sbx, so these profiles
degrade safely on an older script.

Usage:

```bash
# Root-only containers, composes with anything (real-user identity):
sbx --fs sandbox --fs podman --net web --cli claude

# Full image fidelity (postgres/USER images), ns-root session:
sbx --fs sandbox --fs podman-full --net web
```

### Storage separation

Single-UID (`containers`) and multi-UID (`containers-full`) stores never
mix — podman's own rootful/rootless separation exists for the same
reason (ownership layouts are incompatible). An image used in both modes
is pulled twice; accepted. Host-side: `containers-full` contents are
owned by subordinate UIDs — clean up with `podman system reset` inside a
`podman-full` session (or `unshare --map-auto --map-root-user rm -rf`
on the host), not bare `rm -rf`.

## Error handling

- `userns: full` in any applied profile without `--net` → hard error
  with a message naming the profile, before launch.
- `unshare --map-auto` failure (user has no `/etc/subuid` range) →
  unshare's own loud error, surfaced as-is; README notes the fix
  (add a subuid/subgid range for the user).
- API service startup failure → warning, session continues.
- nftables/dnsmasq failure behavior unchanged from phase 1 (hard fail).

## Security notes

- The outer userns adds no authority beyond the user's existing
  `/etc/subuid` delegation (see Mechanism). Ns-root capabilities are
  confined to the namespace.
- **Container egress under `userns: full` required a real fix, not just
  re-verification** — see "Container egress under `userns: full`"
  above. The original assumption (phase 1's output-only nftables table
  would keep gating container traffic unchanged) was wrong: rootful
  podman's bridge-networking backend bypasses `output` entirely. This
  was caught by the plan's own verification step before merge, not
  shipped and found later — but it means the Goal's hard requirement
  ("container/VM network egress must remain subject to the session's
  nftables allow-listing") was *not* met by the initial implementation
  and needed the forward-chain addition to actually hold.
- Never expose a host-side container-engine socket (docker *or* podman)
  inside a sandbox: containers would run on the host, bypassing the
  session's nftables egress allow-list, and volume mounts would grant
  arbitrary host-path access — i.e. the socket is the privilege. The
  in-sandbox `podman system service` socket does not have this problem:
  the service itself runs inside the sandbox's namespaces and its
  containers inherit the session's egress gating.
- The always-on `docker` shim and `DOCKER_HOST` add no attack surface:
  the shim execs an already-reachable binary; the env var points at a
  path that only exists when a profile opted into the service.

## Verification plan

Manual invocations through the real `./sbx` entry point, per repo
convention. Scratch profiles under `.sbx/profiles/` (gitignored).

1. `sbx --fs podman-full --net <test>` → `id` reports uid 0;
   `cat /proc/self/uid_map` shows the 65536-range mapping: two lines,
   `0 <uid> 1` (the caller's own uid) and `1 <subuid-base> 65536` (the
   subordinate range from `/etc/subuid`) — confirmed on this host.
2. **Acceptance test:** the phase-1 failing `USER appuser` Dockerfile
   builds and runs to completion under `podman-full`.
3. **Service-image test:** `podman run docker.io/library/postgres` (with
   required env) reaches "ready to accept connections" under
   `podman-full` — proves the root→service-user privilege drop works.
4. nftables re-verified inside the outer userns — **found a real gap,
   not a rubber stamp**: initial testing found container egress
   completely unfiltered (bridge-forwarded traffic bypassed the
   output-only table entirely). Fixed with a forward chain (see
   "Container egress under `userns: full`" above); re-verified after
   the fix with both CIDR-based and hostname-based restrictive
   profiles, from both the sandbox shell and inside a container: in
   every case an allowed destination is reachable and a disallowed one
   is network-layer blocked.
5. dnsmasq/pasta re-verified: image pull succeeds under `podman-full`.
6. `--gui` + `--net` + `podman-full`: an X app starts under xpra.
7. Shim: plain `sbx -- docker --version` prints podman's version.
8. Socket: in a `--fs podman` session,
   `curl --unix-socket /run/user/$(id -u)/podman/podman.sock http://d/_ping`
   returns `OK`; after session exit, no `podman system service` process
   remains on the host.
9. `userns: full` without `--net` → clean hard error naming the profile.
10. Persistence: a second `podman-full` session lists the image pulled
    in step 5 without re-pulling; the single-UID store is untouched by
    `podman-full` sessions and vice versa.
11. Regressions: plain session, `--net`-only, `--gui`, single-UID
    `--fs podman` (net and no-net), chrome `XDG_RUNTIME_DIR` override —
    all unchanged; `--net` teardown still clean.

## Known limitations (accepted)

- `podman-full` cannot run offline (requires `--net` by design).
- `podman-full` sessions run everything as ns-root — incompatible with
  chromium and root-averse agent CLIs (use plain `podman` alongside
  those instead).
- Two container stores; duplicate pulls across modes.
- Phase 1's no-net podman teardown leak is unchanged (out of scope).
- The phase-1 `_CONTAINERS_*` internal-env dependency remains on the
  plain `podman` + `--net` path (unused by `podman-full`).
- **New:** `netavark` + `aardvark-dns` must be installed on the host for
  hostname-based `allow` entries to work for `podman-full` containers
  (see "Container egress under `userns: full`" above). CIDR-based
  `allow` entries work regardless. Without these packages, hostname
  lookups from inside a `podman-full` container fail to resolve —
  cleanly (dropped, not leaked), but the profile's hostname entries are
  effectively inert for container traffic until the packages are
  present.

## Out of scope

- qemu is untouched by phase 2 (`/dev/kvm` needs no UID range).
- A generic profile `services` framework — `docker_api` is a single
  boolean; refactor into a framework only if a second service appears.
