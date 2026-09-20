# Restoring `ro` and firewall enforcement for `caps: keep` sessions

**Date:** 2026-09-20
**Status:** Designed, not implemented
**Branch:** `podman-full-hardening`

**Builds on:** the `caps: keep` / `userns: full` handling in `sbx` — the
capability decision (`sbx:1036`), the virt plumbing (`sbx:1054-1092`), the
network setup and nft ruleset (`sbx:1392-1580`), and the launch assembly
(`sbx:1856-1900`). No change to profile schemas, the resolve step, or
`--dry-run` beyond what is listed under "Surfaces that change".

## The problem

`fs/podman` sets `"caps": "keep"`; `fs/podman-full` additionally sets
`"userns": "full"`, which implies it. Capabilities are needed because podman
decides rootless-vs-rootful by `geteuid()` and because nested user namespaces
need them. The cost is stated in the README today:

> **Sessions with `"caps": "keep"`** — including `fs/podman` and
> `fs/podman-full`. Capabilities are required for the nested user namespaces
> podman needs, and with them `ro` mounts are writable and the firewall is
> removable.

Both halves are real, not theoretical. In a namespace holding capabilities,
`mount -o remount,bind,rw` on a `ro` bind succeeds and the host file is
overwritten; `nft flush ruleset` empties the session's egress rules.

## What the spikes established

Three spikes (kernel 6.12.104 and 6.12.108 Manjaro, bwrap 0.12.0, podman 6.1.1,
pasta 2026_07_28) verified that both guarantees are restorable **without giving
up any podman functionality**, including container-to-container DNS.

1. **Mounts.** Mounts made in a user namespace A and inherited by a nested
   namespace B are `MNT_LOCKED`: from B they cannot be remounted read-write or
   unmounted, even with a full effective capability set. Verified: write,
   `remount,bind,rw` and `umount` all refused, host file byte-intact. A tmpfs
   *over*mount still succeeds, which hides the path inside B but cannot alter
   the host.
2. **`bwrap --userns2 <fd>`** is the vehicle: run bwrap **inside A**, so mounts
   are made in A, and bwrap `setns`es to B before exec. It takes an inherited
   **fd number**, not a path.
3. **B must get its own mount namespace.** bwrap's mount namespace is owned by
   A, so B cannot mount at all and podman fails with
   "mount --make-rshared /run/netns failed" and "failed to mount shm tmpfs".
   The payload runs `unshare --mount` inside B; inherited mounts stay locked.
4. **Networking.** B cannot create interfaces in A's network namespace (EPERM)
   — the original blocker. The reverse works: **A can create a veth pair and
   move one end into a network namespace owned by B**, because a process holds
   capabilities over objects owned by descendant user namespaces. B then owns a
   network namespace it can configure freely.
5. **Consequences verified in that shape:** netavark builds its bridge,
   `podman network create` works, and aardvark DNS resolves between containers
   (a second container ran `psql -h pg` and got a row back). A's ruleset is
   invisible from B and cannot be added to. Container egress is filtered by A's
   `forward` chain: an allowed address reachable, a dropped address blocked,
   both from the payload and from inside containers. `--user 1000:1000` works
   and `postgres:16-alpine` reaches "ready to accept connections", which only
   happens when the UID switch works.
6. **A subtlety to keep in the code comments:** `nft flush ruleset` from B
   *returns success* — it flushes B's own empty network namespace. Egress stays
   filtered afterwards. A test must assert the filtering, not the exit status.

## Design

### Shape

A becomes explicitly the **control namespace** (pasta, dnsmasq, the nft
ruleset), and B the **payload namespace**. For a `--net` session A already
exists today; this design adds B, and a veth between them.

Two mechanisms, deliberately separable:

| | Mechanism | Cost |
|---|---|---|
| 1 | Nested user namespace, payload in B (`--userns2`) | small, self-contained |
| 2 | Payload in a network namespace B owns, veth to A | touches DNS and host ports |

**Both are implemented unconditionally in libraries, with their own tests, and
engaged from `sbx` behind one boolean.** That boolean is `CAPS_KEEP` for now.
Sessions that drop capabilities keep today's path, because their guarantees
already hold: the payload has an empty bounding set and can neither remount a
`ro` bind nor reach nft. Applying the mechanisms there would buy defence in
depth at the cost of a `veth` dependency on every launch, a second NAT hop, and
a rewrite of the DNS and host-port plumbing — see "Follow-up: going uniform".

### New library: `lib/userns.sh`

No new external dependency. `newuidmap`/`newgidmap` (already required by the
`podman` dependency group) write a multi-range map in one syscall; `dd` is the
fallback for the single-range case. A plain `printf > /proc/PID/uid_map`
must NOT be used: it retries a short write and the retry fails with `EINVAL`
once the map is set, which reads as "multi-range maps are impossible".

```
sbx_userns_hold                       -> prints "<holder pid>"
    Starts a holder process in a new user namespace (unshare --user), with no
    map yet. The holder outlives the call and is killed by sbx_userns_release.

sbx_userns_map_identity <pid>          # single-range: 0 0 1
sbx_userns_map_full <pid> <subuid start> <count>   # 0 0 1 + 1 <start> <count>
    Writes uid_map and gid_map in one write each.

sbx_userns_netns <pid>                 # holder creates its own netns
    -> the holder unshares CLONE_NEWNET so the netns is owned by B.

sbx_userns_release <pid>               # kill the holder; netns and veth go with it
```

`sbx` opens the namespace fd itself, so nothing else needs to pass file
descriptors around:

```bash
exec {SBX_BFD}</proc/$B_PID/ns/user
```

### Network wiring (extends the existing net section)

When engaged and a network namespace exists:

- A creates `veth-a` / `veth-b`, moves `veth-b` into B's namespace, and
  addresses both ends from a fixed `/30` (each session has its own pair of
  namespaces, so no allocation is needed and the same addresses are reused).
- `ip_forward` on in A. A `postrouting masquerade` rule is emitted for the veth
  subnet; note in a comment that pasta appears to translate forwarded traffic
  anyway, so this is belt-and-braces (the spike worked with and without it).
- **DNS** moves from `SBX_DNS_ADDR=127.0.0.2` to A's veth address for engaged
  sessions: dnsmasq binds it, and the sandbox's `resolv.conf` names it. The
  `--nftset` population is unchanged, because dnsmasq is still the resolver
  every lookup goes through.
- **The `forward` chain already exists** in the ruleset (it was added for the
  netavark bridge under `userns: full`) and is what filters container and
  payload egress. The `oif "lo" accept` rule stays for A's own traffic.
- **Host ports** (`--host-port`, and profile `host_ports`) are the one feature
  that does not work unchanged: pasta splices host services onto A's loopback,
  which B cannot reach. Two steps, in this order:
  1. Refuse the combination with a clear error, so no session silently loses
     host-port access.
  2. Then implement it: `route_localnet` on `veth-a` plus a `dnat` rule per
     granted port, and lift the refusal. This is the riskiest piece of the
     design; it deliberately opens A's loopback to B for named ports only.

### Launch assembly

Today, `launch.sh` runs nft and dnsmasq in A and then `bwrap … session.sh`.
When engaged it becomes: create and map B, wire the veth, then

```
nsenter --net=/proc/<B>/ns/net -- bwrap … --userns2 <fd> \
    unshare --mount -- setpriv … session.sh
```

`setpriv` keeps its current role and position: with `caps: keep` it is not
applied, exactly as now.

### Teardown

The holder is a child of `launch.sh` with a trap, so a normal exit kills it.
B's network namespace dies with the holder, and `veth-b` with the namespace;
`veth-a` lives in A's namespace, which dies with pasta. `--gc` needs no change,
and no new state lands on disk.

### Surfaces that change

- **`--doctor` and the launch preflight** gain a check in the `podman` group:
  `veth` must be loadable. This is not hypothetical — a kernel upgrade without a
  reboot leaves the running kernel's module tree empty, and `ip link add … type
  veth` then fails with "Unknown device type" inside a user namespace. Report it
  as "reboot after a kernel upgrade" rather than a package to install. (Once the
  module is available, autoload from inside the namespace works; no root needed.)
- **`--dry-run`** gains one line in the Security section for engaged sessions:
  that `ro` and the firewall are enforced through a nested namespace, so the
  preview stops implying they are lost.
- **README** rewrites the `caps: keep` entry under "What it does not protect
  against". What remains true for such sessions: the payload holds capabilities
  inside B, so it can create nested namespaces and hide paths from itself with
  over-mounts. What is no longer true: writable `ro` mounts and a removable
  firewall.
- **Snapshot goldens** change for the `podman` and `userns-full` cases only, and
  are regenerated deliberately in the task that engages the mechanism. The other
  cases must not change — that is the evidence that capability-dropping sessions
  are untouched.

## Testing

- **Unit (`lib/userns.sh`):** hold, map (single and multi-range), netns
  ownership, release; a map written by the forbidden `printf` route fails, which
  pins the gotcha.
- **Integration, engaged session:** `ro` write/remount/umount refused; the host
  file unchanged afterwards; A's ruleset invisible; **egress still filtered
  after B runs `nft flush ruleset`**; the payload reaches an allowed address and
  not a denied one.
- **Container-level (needs podman, `veth` loadable, network access):** marked
  skippable, since CI may have none of the three. `podman network create`, two
  containers resolving each other by name, container egress filtered, and
  `--user 1000:1000`.
- **Unchanged sessions:** the full existing suite, with snapshot goldens
  untouched for non-`caps: keep` cases.

## Non-goals and open questions

- **The `overlay` storage driver is unverified.** Every spike used `vfs`. If
  overlay needs mounts that B cannot make, the fallback is documenting `vfs`
  for these sessions.
- **`--network=pasta` for containers** also works and needs no veth, but loses
  bridge networking and aardvark DNS. Keep it as a documented fallback, not the
  default.
- **Follow-up: going uniform.** Engaging both mechanisms for every session is a
  one-line change to the boolean plus the DNS and host-port rework described
  above. Worth revisiting once this path has proven itself, and only with
  evidence that the `veth` dependency is safe on the machines that matter: today
  a kernel upgrade without a reboot would take down every session rather than
  only podman ones.
- **Nested namespace depth** is not configurable: one level, A and B.
