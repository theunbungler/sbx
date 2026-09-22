# One session environment: payload in a nested namespace

**Date:** 2026-09-20 (revised 2026-09-21: uniform for every session)
**Status:** Designed, not implemented
**Branch:** `podman-full-hardening`

**Builds on:** the namespace and capability setup in `sbx` (`sbx:963-1035`),
the virt plumbing (`sbx:1054-1092`), the network setup and nft ruleset
(`sbx:1392-1580`), the dnsmasq prelude (`sbx:1903`), the launch-script
assembly (`sbx:2061-2105`) and the pasta/unshare launch (`sbx:2150-2170`).
No change to profile schemas or the resolve step.

## The problem

`fs/podman` sets `"caps": "keep"`; `fs/podman-full` additionally sets
`"userns": "full"`, which implies it. Capabilities are needed because podman
decides rootless-vs-rootful by `geteuid()` and because nested user namespaces
need them. The README states the cost:

> **Sessions with `"caps": "keep"`** — including `fs/podman` and
> `fs/podman-full`. Capabilities are required for the nested user namespaces
> podman needs, and with them `ro` mounts are writable and the firewall is
> removable.

Both halves are real. In a namespace holding capabilities,
`mount -o remount,bind,rw` on a `ro` bind succeeds and overwrites the host
file, and `nft flush ruleset` empties the session's egress rules.

Every other session keeps those guarantees today by one mechanism only: an
empty capability set.

## What the spikes established

Four spikes (kernel 6.12.104 and 6.12.108 Manjaro, bwrap 0.12.0, podman
6.1.1, pasta 2026_07_28).

1. **Mounts.** Mounts made in a user namespace A and inherited by a nested
   namespace B are `MNT_LOCKED`: from B they cannot be remounted read-write or
   unmounted, even with a full effective capability set. Verified: write,
   `remount,bind,rw` and `umount` all refused, host file byte-intact. A tmpfs
   *over*mount still succeeds, which hides the path inside B but cannot alter
   the host.
2. **`bwrap --userns2 <fd>`** is the vehicle: run bwrap **inside A**, so mounts
   are made in A, and bwrap `setns`es to B before exec. It takes an inherited
   **fd number**, not a path.
3. **B needs its own mount namespace to mount anything.** bwrap's mount
   namespace is owned by A, so podman in B fails with "mount --make-rshared
   /run/netns failed" and "failed to mount shm tmpfs". `unshare --mount` inside
   B fixes that; inherited mounts stay locked.
4. **Networking.** B cannot create interfaces in A's network namespace (EPERM).
   The reverse works: **A can create a veth pair and move one end into a
   network namespace owned by B**, because a process holds capabilities over
   objects owned by descendant user namespaces.
5. **Podman in that shape:** netavark builds its bridge, `podman network
   create` works, aardvark DNS resolves between containers (a second container
   ran `psql -h pg` and got a row back), container egress is filtered by A's
   `forward` chain, `--user 1000:1000` works, and `postgres:16-alpine` reaches
   "ready to accept connections" (which needs a working UID switch). A's
   ruleset is invisible from B and cannot be added to.
6. **`nft flush ruleset` from B returns success** — it flushes B's own network
   namespace — and A's filtering is untouched. Tests must assert the
   filtering, never the exit status.
7. **Same addresses as today (2026-09-21).** From B, `127.0.0.1:PORT` reaches a
   granted host port (TCP and UDP) and `127.0.0.2:53` reaches dnsmasq (UDP and
   TCP). Not-granted host ports, a private listener on A's loopback, and
   non-allowed egress stayed unreachable, including after B added its own DNAT
   rules, rerouted `127.0.0.0/8` out of the veth, and flushed its ruleset. A's
   input drop counter confirmed A's rules did the refusing.
8. **DNAT onto A's loopback cannot work.** pasta binds its host-port splice
   listener to the `lo` device (`*%lo:PORT`, `SO_BINDTODEVICE`), so a packet
   arriving on `sbx-a` is refused whatever it is translated to. pasta cannot
   bind on `sbx-a` instead: it binds before the veth exists.

9. **Gates run on 2026-09-21**, in all three launch shapes (no networking,
   networked, `userns: full`), with bwrap run in A and `--userns2`:
   - `--userns2 <fd>` **alone** works. The man page's `--userns <A> --userns2
     <B>` form fails ("Joining the specified user namespace failed"); do not
     use it.
   - Capability-dropping sessions (today's `--cap-drop ALL --cap-add
     CAP_SETPCAP` plus `setpriv`) end with empty effective, bounding and
     ambient sets. `caps: keep` sessions end with full ones.
   - `ro` write, remount and umount are refused in every shape, including
     `caps: keep`; the host file is intact.
   - Overlay: a kernel overlay mount works inside B's own mount namespace in
     all shapes, and real podman 6.1.1 on sbx's overlay `storage.conf` loads an
     image and runs containers in both podman modes. `podman-full` keeps
     `--user 1000:1000` and in-container `chown`; single-uid `fs/podman` fails
     both exactly as it does today (measured in today's shape too).
   - B's loopback starts down; A must bring it up.
   - `setpriv --pdeathsig KILL` survives `unshare --user`: B's holder dies
     when the script that started it is SIGKILLed.

**Still open:** Ubuntu 24.04's AppArmor userns restriction. Sessions without
networking now create A with `unshare`, which Ubuntu's default policy may
refuse for an unconfined binary, and B is created from inside A. This blocks
merging, not starting, and is checked on a real machine.

## Design

### One environment

Every session has the same shape:

- **A, the control namespace.** A user namespace and a network namespace.
  pasta, dnsmasq and the nft ruleset live here, and bwrap runs here, so every
  mount the sandbox makes belongs to A.
- **B, the payload namespace.** A user namespace nested in A, owning its own
  network namespace. The payload runs here and can neither alter A's mounts
  nor see A's ruleset, whatever capabilities it holds. `caps: keep` payloads
  additionally run under `unshare --mount`, so podman can mount in a
  namespace B owns; a capability-dropping payload could not run `unshare
  --mount` and has no use for it.

For networked sessions A is what pasta creates today. **Sessions without
networking get an A too**, from `unshare --user --map-root-user --net`, and
`bwrap` stops creating the user and network namespaces itself (`--unshare-user
--unshare-net` at `sbx:1006` goes). launch.sh runs in A for every session.

Capability-dropping sessions keep `--cap-drop ALL` and `setpriv`, now as a
second guard behind the nesting rather than the only one. `caps: keep`
sessions keep their capabilities, now scoped to B.

What remains conditional describes what a profile *grants*, and exists today:

- whether A's network namespace has a route out (net profiles, host ports), and
  so whether a veth is wired into B;
- the single-uid or subuid map (`userns: full`);
- whether capabilities are dropped.

There is no second environment and no parity to maintain between two.

### Identity inside B

B's map reproduces what the payload sees today, measured on 2026-09-21:

| Shape | A's map (inside → host) | Payload today | B's map |
|---|---|---|---|
| no networking | `0 → uid` (from `unshare`) | real uid | `uid 0 1` |
| networked | `0 → uid` (pasta) | 0 | `0 0 1` |
| `userns: full` | `0 → uid`, `1.. → subuids` | 0 | A's ranges, identity |

The last two are the same rule: B mirrors A's map as an identity. The
difference between the first two exists today; unifying it would be a
separate decision. Tests pin `id -u` per shape.

### New library: `lib/userns.sh`

No new external dependency for the namespace itself. `newuidmap`/`newgidmap`
write a multi-range map in one syscall; `dd` writes a single-range map. A plain
`printf > /proc/PID/uid_map` must NOT be used: it retries a short write and the
retry fails with `EINVAL` once the map is set.

```
sbx_userns_hold                                    -> prints "<holder pid>"
    A holder process in a new user namespace AND a new network namespace
    (unshare --user --net), no map yet. Lives until sbx_userns_release.

sbx_userns_map_single <pid> <inside> <outside>      # one line, one write
sbx_userns_map_full   <pid> <subuid start> <count>  # 0 0 1 + 1 <start> <count>

sbx_userns_release <pid>        # kill the holder; its netns and sbx-b go too
```

launch.sh opens the namespace fd itself: `exec {SBX_BFD}</proc/$B_PID/ns/user`.

### New library: `lib/nestnet.sh`

Generates launch.sh fragments; `sbx` does not hand-assemble them.

- **Wiring** (networked sessions): `sbx-a`/`sbx-b`, `sbx-b` moved into B's
  network namespace, the fixed subnet `10.200.0.0/30` (A `10.200.0.1`, B
  `10.200.0.2`; every session has its own pair of namespaces, so the same
  addresses are reused without allocation), `ip_forward` in A, default route
  in B via A. The wiring happens before the ruleset and dnsmasq, because
  dnsmasq binds A's veth address; rules still match `iifname`, which does not
  depend on the order.
- **A's ruleset additions**, in the existing `table inet sbx_filter`:
  - `postrouting masquerade` for B's address leaving by any interface other
    than `sbx-a`. The spikes ran with it; whether pasta would translate B's
    forwarded traffic on its own is untested, so it stays;
  - an **`input` chain matching only `iif "sbx-a"`**: accept granted host
    ports and DNS on A's veth address, then drop. This is the boundary for
    what B may reach on A itself.
  - The existing `output` chain (A's own traffic, including dnsmasq's upstream
    queries) and `forward` chain (everything B and its containers send
    outward) are unchanged in content. The payload's own egress moves from
    `output` to `forward`; both chains already carry the same allow rules.
- **DNS:** dnsmasq additionally listens on A's veth address. `resolv.conf`
  still names `127.0.0.2`.
- **Host ports:** one `socat` relay per granted port and protocol, listening on
  A's veth address, bound to `sbx-a` with `so-bindtodevice` (which lets it
  share the port number with pasta's own listener), forwarding to
  `127.0.0.1:PORT`. Its outbound leg is A's loopback traffic, already accepted
  by `oif "lo" accept`. A does NOT set `route_localnet`: nothing B sends can be
  delivered to A's loopback.
- **B's convenience rules**, installed in B's network namespace before the
  payload starts: `nat output` DNATs `127.0.0.1:PORT` (each granted port and
  protocol) and `127.0.0.2:53` to A's veth address; `route_localnet` on
  `sbx-b`; `nat postrouting` masquerades loopback-sourced packets leaving
  `sbx-b`. A `caps: keep` payload can delete them. That is acceptable by
  construction: they grant nothing A does not already allow at its veth
  address, so deleting them costs the payload only its own convenient
  addresses.

### Launch assembly

launch.sh, run in A for every session:

1. the existing network prelude (nft, dnsmasq) for networked sessions;
2. hold and map B; wire the veth and relays when networked; install B's
   convenience rules;
3. `nsenter --net=/proc/<B>/ns/net -- bwrap … --userns2 <fd> unshare --mount --
   [setpriv …] session.sh`;
4. on exit, release B and reap dnsmasq and the relays.

`setpriv` keeps its place and its reason: bwrap's direct child empties every
capability set before session.sh, so the tmux server, the payload and every
join are capless by construction. Joins are panes of that tmux server, so they
run in B with no change to `--join`.

### Teardown

B's holder, the relays and dnsmasq are children of launch.sh, reaped by a trap
on normal exit; the holder and relays carry `setpriv --pdeathsig KILL`, so
they die with launch.sh even when it is SIGKILLed (`--die-with-parent` keeps its
role for bwrap). B's network namespace dies with the holder and `sbx-b` with
the namespace; A's namespaces die with pasta or the `unshare`. `--gc` needs no
change, and no new state lands on disk.

### Surfaces that change

- **Dependencies.** `socat` joins the `net` group (package `socat` on all three
  families); the groups are coarse, and `dnsmasq` is already required the same
  way for host-ports-only sessions that never start it. `unshare` moves from
  `podman` to `core` and `nsenter` joins `core`, since every session now runs
  both. (`ip` is already in `core`.)
- **Payload DNS goes through dnsmasq only.** The payload's egress now crosses
  A's `forward` chain, which never carried the `output` chain's "upstream DNS
  on port 53" accepts. A payload that queried the upstream resolver directly
  used to succeed; it now fails. dnsmasq's own upstream queries are A's
  traffic and are unaffected.
- **Binding a forwarded port inside the sandbox** used to fail with
  `EADDRINUSE`, because pasta's listener held it. In B the bind succeeds, but
  the payload's own connections to `127.0.0.1:<port>` still reach the host
  service (B's DNAT applies to them). The README's "Reaching Host Services"
  paragraph is updated to say so.
- **`--doctor` and the launch preflight:** `veth` must be loadable for any
  networked session. A kernel upgrade without a reboot leaves the running
  kernel's module tree empty, and `ip link add … type veth` then fails with
  "Unknown device type". Report it as "reboot after a kernel upgrade". Once the
  module is available, autoload from inside the namespace works; no root
  needed.
- **`--dry-run`:** the Security section states that mounts and the firewall are
  enforced from a separate namespace, and no longer says `caps: keep` loses
  them.
- **README:** the `caps: keep` entry under "What it does not protect against"
  is rewritten. What remains: a `caps: keep` payload holds capabilities in B,
  so it can create nested namespaces and hide paths from itself with
  over-mounts. What goes: writable `ro` mounts and a removable firewall. The
  dependency list gains `socat` and the `veth` note.
- **Snapshot goldens** all change, because every launch.sh changes. The plan
  regenerates them in dedicated tasks, and each regeneration's diff is reviewed
  as a deliverable, never waved through.

## Sequencing (for the plan)

The branch ends uniform. The order keeps "podman works" and "nothing else
broke" separately verifiable:

1. **Spikes that gate the rest:** overlay in B, and capability sets after
   `--userns2` for both modes.
2. **Libraries** (`lib/userns.sh`, `lib/nestnet.sh`) with unit tests. Nothing
   in `sbx` uses them yet; goldens untouched.
3. **Checkpoint: engage for `caps: keep` sessions only.** Podman integration
   tests must pass; only the podman goldens change, and every other golden is
   untouched — the evidence that nothing else moved.
4. **Go uniform:** remove the condition, add A for sessions without
   networking, regenerate the remaining goldens as a reviewed diff. The full
   suite must pass.
5. **Surfaces:** dependencies, `--doctor`, `--dry-run`, README.
6. **Before merge:** the Ubuntu 24.04 AppArmor check on a real machine.

## Testing

- **Unit:** hold, map (single and multi-range), netns ownership, release; a map
  written by the forbidden `printf` route fails, pinning the gotcha.
- **Every session:** `ro` write/remount/umount refused and the host file
  unchanged; the payload's capability sets match the mode; `id` and `$HOME`
  ownership match what they were.
- **Networked sessions:** a granted TCP and UDP host port at `127.0.0.1`,
  `localhost` for TCP, a lookup through `resolv.conf`, an allowed address
  reachable and a denied one not, a not-granted host port refused.
- **Attacks from a `caps: keep` payload:** its own DNAT to A's veth address on a
  not-granted port, `127.0.0.0/8` rerouted out of the veth, `nft flush
  ruleset`. Each must leave not-granted ports, A-private listeners and denied
  egress unreachable, with A's input drop counter rising; afterwards the
  granted port still answers at A's veth address.
- **Containers** (needs podman, `veth` and network access; skippable):
  `podman network create`, two containers resolving each other by name,
  container egress filtered, `--user 1000:1000`, overlay storage.
- **The existing suite** passes throughout.

## Non-goals and open questions

- **`--network=pasta` for containers** also works and needs no veth, but loses
  bridge networking and aardvark DNS. A documented fallback, not the default.
- **Nested namespace depth** is fixed: one level, A and B.
- **If overlay fails in B**, podman sessions document `vfs`; the rest of the
  design is unaffected.
- **If Ubuntu's AppArmor blocks the nested namespace**, the fix is an addition
  to the AppArmor profile text `sbx` already prints, verified on that machine.
