# sbx nested user namespace design

**Date:** 2026-08-05
**Status:** approved, not yet implemented
**Supersedes:** the "`caps: keep` sessions retain the pre-hardening boundary"
residual risk in `2026-08-01-sbx-hardening-design.md`

## Problem

Sessions using a capability-retaining profile print:

```
Warning: profile 'podman' retains capabilities — this session's ro mounts and
egress firewall are NOT enforceable against code running inside it.
```

The 2026-08-01 design accepted this as the structural cost of supporting
podman, reasoning that "container workloads need nested user namespaces and
therefore capabilities."

That reasoning is wrong. Nested user namespaces need no capabilities at all.
The kernel sets `cap_bset = CAP_FULL_SET` in `set_cred_user_ns()` on every
`create_user_ns()`, so a process at zero capabilities becomes full root inside
a namespace it creates. Measured on Linux 6.12 / bubblewrap 0.11.2, inside a
capless bwrap with the bounding set emptied by `setpriv`:

```
OUTER:  CapEff: 0000000000000000  CapBnd: 0000000000000000
INNER:  CapEff: 000001ffffffffff  CapBnd: 000001ffffffffff   (uid 0)
```

This is why rootless podman works for an ordinary unprivileged host user, and
`podman info` does in fact run capless inside sbx today, reporting
`Rootless: true` and the correct graphroot.

What capabilities actually buy is narrower. Under `--net`, pasta creates the
user namespace and bwrap *joins* it, so the namespace's owner is host uid 1000
while the payload's euid inside is 0. The unprivileged single-extent `uid_map`
self-map requires those to match, so podman's re-exec fails:

```
unshare: write failed /proc/self/uid_map: Operation not permitted
```

Granting only `CAP_SETUID`, `CAP_SETGID` and `CAP_SETPCAP` (`CapEff: 1c0`) does
not fix this — verified. The capability that resolves it is `CAP_SYS_ADMIN`,
which is precisely the one that unlocks `ro` remounts. **Trimming the
capability set is therefore a dead end; the fix is to change where the payload
runs, not what it holds.**

## Solution: run the payload one user namespace deeper

Mounts inherited from a parent mount namespace are *locked*: `MS_RDONLY` cannot
be cleared even with `CAP_SYS_ADMIN` in a child user namespace. And a child
user namespace holds no authority over a network namespace owned by its parent.
So a payload nested below the boundary cannot undo the boundary, however
privileged it is inside its own namespace.

Verified end-to-end in a live `--fs podman --net` session:

```
uid=1000 CapEff:	0000000000000000
ro remount /usr: mount: /usr: must be superuser to use mount.
nft flush:       Error: Could not process rule: Operation not permitted
container run:   OK_CONTAINER_RAN
allowed egress:  resolves
blocked egress:  blocked
```

Containers run, and both guarantees the warning disclaims are restored.

### Rejected alternatives

**A second bwrap inside the first.** Would let the inner layer re-assert mounts
in bwrap's own argument language. Pointless: the outer layer's locked mounts
already enforce, and bwrap-in-bwrap `/proc` handling is fiddly.

**Reversing namespace ownership** — bwrap creates the user namespace and pasta
joins it via `--netns`. This attacks the root cause: with the payload's euid
matching the namespace owner, the unprivileged self-map is legal and **no
capabilities are needed anywhere, with no nesting at all**, extending the
capless behaviour that already holds in no-net mode. Strictly the better end
state, and recorded here as the intended future simplification. Not done now
because it inverts the launch sequence — `nft` and `dnsmasq` currently run
inside pasta's namespaces before bwrap starts, and would need reordering around
a namespace holder process. That is the part of sbx most likely to fail in ways
that look like a working firewall while not working. Implementing the nested
boundary first makes the reversal *testable*: the same assertions then say
whether a reordered launch preserves the boundary.

## Architecture

### Capability model

A `nested_userns` profile produces a two-layer session.

The **outer layer** is unchanged: bwrap with `--cap-add ALL`, the ro binds, the
mount masks, and under `--net` pasta's namespaces with the nftables allow-list
and dnsmasq already established outside it. The payload no longer runs here.

The **inner layer** is created by the generated wrapper's first act:

```bash
exec unshare -Um --map-user=1000 --map-group=1000 \
    env -u _CONTAINERS_USERNS_CONFIGURED \
        -u _CONTAINERS_ROOTLESS_UID \
        -u _CONTAINERS_ROOTLESS_GID \
    <wrapper body>
```

Three properties, each measured:

**The uid is expanded at wrapper-generation time from the host's `id -u`, never
evaluated inside the sandbox.** Under `--net` the sandbox's own `id -u` is 0,
and mapping 0→0 is the `unshare -Ur` case, which fails: netavark dies with
`invalid namespace path`. Mapping to the host uid puts podman on its ordinary
rootless path and makes bind-mounted file ownership read correctly rather than
appearing root-owned. In no-net mode the id is already the host uid, so the
same literal is a self-map and both modes take an identical path.

**The three `_CONTAINERS_*` overrides are deleted, not relocated.** They exist
only to force podman off the rootful path that `--cap-add ALL` tricked it onto.
With the nested mapping podman detects rootless correctly; leaving them set
reproduces `Internal error, failed to re-exec podman into user namespace`
followed by a nil-pointer panic.

**The whole wrapper body moves inside**, `USERNS_NET_SETUP` and
`DOCKER_API_START` included — both are podman operations needing the inner
identity. Outer capabilities are therefore held by `unshare` alone, across a
single `exec`.

`unshare` and `setpriv` both ship in util-linux, and `--map-user` has existed
since util-linux 2.38 (2022). No new dependency, satisfying the no-custom-code
constraint the 2026-08-01 design set.

### Mode symmetry

Both modes take the nested path, even though no-net mode could instead drop
capabilities entirely (bwrap creates the user namespace there, so the payload
is capless-capable already). One capability story, one code path, one set of
tests, in place of two privilege shapes each needing separate reasoning. The
namespace the no-net path does not strictly need costs nothing measurable.

### Residual risks

- `CapBnd` stays full in the inner layer: dropping it needs `CAP_SETPCAP`,
  which the inner layer deliberately lacks. Accepted, because a full bounding
  set grants nothing — any nested user namespace resets `cap_bset` to
  `CAP_FULL_SET` regardless, which is the same kernel behaviour this design
  rests on.
- podman's containers hold capabilities inside their own namespaces, exactly as
  on a normal rootless host.
- Every residual risk from the 2026-08-01 design that is not about capability
  retention still stands: no seccomp filter, wildcard `allow` entries, DNS as
  an exfiltration channel, `"ports": ["*"]`, copy-mount write-back.

## Profile field

`"caps": "keep"` is replaced by `"nested_userns": true` on fs profiles, set by
`fs/podman.json` and `fs/podman-full.json`.

- Host-owned profiles only. A `./.sbx` profile setting it is rejected outright,
  joining `userns` and `docker_api` in the existing check.
- `"userns": "full"` continues to imply it.
- A profile still carrying `"caps"` is a hard error naming the replacement. No
  silent compatibility shim, so a stale profile cannot land on a boundary that
  no longer exists.
- The launch warning is deleted. There is nothing left to warn about.

The rename is the point: a field called `caps: keep` that no longer weakens
anything misleads whoever reads the profile next.

## Container store relocation

The persistent container store moves from `$HOME/.local/state/sbx/virt/` to
`$HOME/.local/share/sbx/virt/`, keeping the existing `containers` /
`containers-full` split.

This fixes a live regression. `--tmpfs "$STATE_DIR"` (from commit a81d213)
shadows the store, so every podman session starts with an empty image store and
loses pulls at teardown:

```
$ stat -f -c %T $HOME/.local/state/sbx/virt/containers
tmpfs
```

`--cap-add ALL` let podman paper over it, so it surfaced only as an empty image
list; under a reduced capability set it becomes an outright failure,
`overlay is not supported over tmpfs`.

Relocating rather than exempting keeps `STATE_DIR` masking absolute — no
exceptions to keep correct as profiles change. Container images are user data,
not sbx control state, so `share` is where they belonged.

Paths change in three places: the two profiles' mounts, and the `graphroot` /
`rootless_storage_path` lines of the generated `storage.conf`.

**Migration:** none. If the old directory exists, sbx prints once that it is
stale and can be removed, and never touches it. A podman graphroot records
absolute paths internally (`db.sql`, the overlay link farm), so relocating one
risks a subtly broken store in exchange for avoiding a cheap re-pull.

## Failure modes

All closed, per the existing `setpriv` precedent:

- `unshare` missing, or refusing to write the map → `exec` fails, the payload
  never runs, the session exits non-zero.
- The capless branch keeps its current `setpriv` wrapper unchanged.

The two branches now differ only in which util-linux tool they exec through.

## Testing

New suite `tests/nested-userns.bats`. Conventions, per the existing suites:
fake `$HOME` from `mktemp -d /tmp/sbxh.XXXXXX` (not `$BATS_TEST_TMPDIR` — the
session socket path exceeds the ~108-char limit and fails *quietly*); sessions
driven with `script -qec` for the pty; `export SBX_TRUST_PROJECT_PROFILES=1` in
`setup()`; negative assertions written long-hand (`if grep -q …; then return 1;
fi`), because `! grep` is a no-op anywhere but a test's last line.
`shellcheck -S error sbx lib/copy-mounts.sh` stays silent; the four
pre-existing sub-error warnings are not regressions.

**Boundary.** A fixture profile with `nested_userns` and one `ro` mount, run
under `--net`, asserting inside the session that `CapEff` is zero, that
`mount -o remount,rw,bind` on the ro mount fails, and that `nft flush ruleset`
fails — then from the host after teardown that the ruleset was still intact.
The inside-view assertion alone cannot distinguish "refused" from "succeeded
silently".

**Wrapper shape.** The generated wrapper's first `exec` is `unshare` carrying
the host uid as a literal, and bwrap passes no `_CONTAINERS_*` variable. This
catches someone "fixing" the uid into a runtime `$(id -u)`, which would break
`--net` in a way the boundary tests would not notice.

**Store regression.** Inside a session, the store path's `stat -f -c %T` is not
`tmpfs`; and a file written there is present at the host path in a later
session. This pair fails today.

**Rejection.** A `./.sbx` profile setting `nested_userns` is refused; a profile
still setting `caps` errors and names the replacement.

**podman functional.** `podman info` reports rootless, and
`podman run --pull=never` on a locally-present image runs. Skipped when the
image is absent, so the suite never depends on Docker Hub.

**Manual, documented rather than automated:** container-level egress filtering
(allowed domain resolves, blocked domain blocked), verified by hand during
design. Keeping it out of the suite keeps the suite off the network.

**`podman-full` is a verification task with a recorded outcome, not a pass/fail
gate.** It runs rootful-in-namespace against a real multi-UID range, so its
inner mapping is probably uid 0 backed by that range rather than the host uid —
a different wrapper shape. Three acceptable outcomes: it works as designed and
takes the same assertions; it needs its own mapping, which the implementation
plan then specifies; or it cannot be nested, in which case it alone keeps a
warning, the README says so plainly, and `fs/podman.json` still gets the
hardened boundary.

**Known verification risk.** The docker API socket at
`/run/user/<uid>/podman/podman.sock` is created by `DOCKER_API_START`, which now
runs one namespace deeper. A "socket did not appear" warning was observed during
a reduced-capability experiment, so this needs an explicit test rather than an
assumption. If the socket cannot be published from the inner layer, that is a
finding for the plan, not something to design around blind.

## Documentation updates

- `README.md`: both `caps` rows become `nested_userns`, describing what it does
  rather than what it costs.
- `2026-08-01-sbx-hardening-design.md`: the capability-retention residual risk
  is marked superseded, pointing here.
