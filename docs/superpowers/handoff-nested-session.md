# Continue: the nested session environment (paste this into a new session)

State as of 2026-09-23, branch `podman-full-hardening` (19 commits ahead of
`main`, nothing merged, nothing pushed).

## Read these first

- Design (the authority): `docs/superpowers/specs/2026-09-20-nested-session-design.md`
- Plan, eight tasks: `docs/superpowers/plans/2026-09-21-nested-session.md`

## What this branch does

Every session's payload now runs in a user namespace **B**, nested inside a
control namespace **A**. bwrap runs in A, so every mount belongs to A and is
inherited by B locked: it cannot be remounted read-write or unmounted from
inside, whatever capabilities the payload holds. A keeps pasta, dnsmasq and the
nftables ruleset; B owns its own network namespace, joined to A by a veth pair.

This closes a real hole. A reviewer reproduced it on a throwaway copy: before
the change, a `--fs keep --net` payload ran `mount -o remount,bind,rw /ro` and
overwrote the host file. It is refused now, and the host file is intact.

Addresses (`lib/nestnet.sh`): `10.200.0.0/29`, A `10.200.0.1` for dnsmasq and
`10.200.0.2` for the host-port relays, B `10.200.0.3`. Two addresses because a
granted host port of 53 otherwise collides with dnsmasq — `so-bindtodevice`
separates a relay from pasta's `lo`-bound listener but not from an unbound
socket on the same address (measured, both bind orders).

Host ports reach the payload through one `socat` relay per granted port, because
pasta binds its splice listener to the `lo` device and nothing arriving on the
veth can match it. B carries DNAT rules so `127.0.0.1:<port>` and the resolver
at `127.0.0.2` answer where they always did; those rules are convenience only,
and a payload that deletes them loses nothing but its own shortcuts.

Tasks 1-7 are complete, each reviewed with its own fix rounds, plus a
whole-branch review and one fix wave. Suite: **394/394**, `shellcheck -S error
sbx sbx-profile lib/*.sh` silent.

## The one thing left: Task 8, on Ubuntu 24.04

**This is the merge gate.** Every session now creates a nested user namespace,
and a session without networking starts A with `unshare --user --map-root-user
--net` — an unconfined binary doing exactly what Ubuntu's
`apparmor_restrict_unprivileged_userns` refuses. Before this change no session
took that path; now every one does.

On a real Ubuntu 24.04 install (a VM — WSL2 usually does not enforce AppArmor,
so a green run there does not clear the gate):

```bash
sysctl kernel.apparmor_restrict_unprivileged_userns     # expect 1 on stock 24.04
unshare --user --map-root-user --net true && echo OK    # the new exposure
bwrap --unshare-user --ro-bind / / true && echo OK      # what sbx already needed
sudo aa-status | head
./sbx --doctor                                          # prints the apt line for what is missing
bats tests/userns.bats tests/nestnet.bats               # the mechanism, fast
bats tests/nested.bats tests/hardening.bats             # real sessions, minutes
bats tests/                                             # everything
```

If a check fails, capture the message and `sudo dmesg | grep -i apparmor | tail
-20`: the denial names the profile and operation a fix must target. Toggling
`kernel.apparmor_restrict_unprivileged_userns=0` separates "AppArmor blocked it"
from "something else broke" — a diagnostic, not a recommendation. The fix, if
needed, belongs in the AppArmor profile text `sbx --doctor` already prints.

Expect two harmless differences there: Ubuntu ships podman 4.9, not 6.1.1, so
the default-network DNS quirk Task 6 fixes may not exist (the fix is harmless
either way, but a failure is worth capturing); and the container tests skip
without a local alpine image.

## Follow-ups, none blocking

- `sbx_deps_veth_ok` can false-negative on a kernel with `veth` built in but no
  `modules.builtin`, which would block every networked launch with a misleading
  "reboot" hint. `modinfo -n veth` / `modprobe -qn veth` would ask the module
  system instead.
- For the two pasta-based session shapes, a SIGKILLed `sbx` kills pasta while
  its forked child survives, so the orphan is networkless rather than healthy;
  `--gc` already treats the session as dead. Pre-existing, narrowed by this
  branch, documented at the `setpriv --pdeathsig KILL` comment.
- `lib/deps.sh` duplicates the `mapfile`+index veth-explain pattern in
  `require` and `doctor`; fold into one helper when something else touches it.
- `sbx_nestnet_relays` assumes a caller without job control (stated in its
  comment); the plan file still shows the old `/30` numbering as a historical
  artifact.

## Decisions worth not relitigating

- **Uniform, not conditional.** The mechanism applies to every session rather
  than only `caps: keep` ones. The user chose this after host-port and DNS
  address parity was proven, because a boolean would have meant two
  environments to keep in step.
- **`caps: keep` sessions keep their capabilities inside B.** They can create
  further namespaces and hide paths from themselves with over-mounts; they
  cannot write `ro` mounts or change the firewall. The README says exactly that.
- **The podman default-network DNS fix (Task 6) was folded in on the user's
  instruction**, though it predates this branch: podman 6.x materialises
  whatever `containers.conf` names as `default_network` with DNS disabled and
  refuses to create it, so `userns: full` containers could resolve nothing.
  `sbx` now creates `sbx0` under a second generated config that omits the
  `[network]` section.
- **Payload DNS now goes through dnsmasq only.** The payload's egress crosses
  A's `forward` chain, which never carried the `output` chain's upstream-resolver
  accept, so a direct query to an upstream resolver from inside a session fails.
  A tightening, documented in the README.

## Moving the branch to a test machine

`sshd` runs on the development machine, so the simplest route is to fetch from
it:

```bash
git clone ssh://<user>@<dev-host>/home/<user>/git/sandbox-gemini sbx
cd sbx && git checkout podman-full-hardening
```

Or, with no network between them, `git bundle create sbx.bundle main
podman-full-hardening` and clone from the bundle. The repository also has a
GitHub remote, unused by this branch so far.
