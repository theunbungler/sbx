# Continue: the nested session environment (paste this into a new session)

State as of 2026-09-23. Two branches, neither merged into `main`:

- **`podman-full-hardening`** — the nested session environment. Checked out in
  the main working copy while the user tests it in place; a copy exists on the
  GitHub remote. 394 tests.
- **`ubuntu-apparmor`** — branched from it, in `.claude/worktrees/`. Adds the
  preflight diagnosis for the policies that block a session (see Task 8 below).
  407 tests.

`git log main..<branch>` is the authority on what each carries.

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

## Task 8 is done: Ubuntu works, with two AppArmor allowances

Measured on an Ubuntu 26.04.1 VM (kernel 7.0), 2026-09-23. Ubuntu needs exactly
two policy allowances; with them in place, **in enforce mode, not complain**:
`nested.bats` 26/26, `hardening.bats` 24/24, `sessions.bats` 43/43,
`join.bats` 12/12, and `sbx --doctor` exits 0 with every line ticked.

What Ubuntu's policy does, and what answers it:

1. **pasta could not exec the generated launch script.** Its profile grants
   exec only under `/bin` and `/usr/bin` (`/{usr/,}bin/** Ux`) and gives `$HOME`
   write without exec. **Fixed in code on the nested-session branch:** pasta is
   handed `/bin/bash <launch script>`, which lands inside that allowance, and
   `Ux` still runs the script unconfined.
2. **`unpriv_bwrap` carries `audit deny capability`**, so the `setpriv`
   bounding-set drop that every session performs fails, and `caps: keep` cannot
   hold capabilities at all. A `local/` include cannot relax it — AppArmor's
   deny beats a later allow — so Ubuntu's bwrap profile has to be retired in
   favour of a permissive one. That re-allows capabilities inside every bwrap
   sandbox on the machine, which is the cost `--doctor` states out loud.
3. **A binary that creates its own user namespace lands in
   `unprivileged_userns`**, which denies the capabilities that namespace needs.
   That hits `unshare`, which builds the control namespace for a session with
   no networking and for every `userns: full` session, so `unshare` needs a
   profile of its own.

The `ubuntu-apparmor` branch adds the diagnosis rather than working around any
of it: two probes that run exactly what a launch runs (the bounding-set drop
inside a sandbox; `unshare` creating a user + network namespace together), a
preflight that refuses before building a session, `--doctor` reporting both with
the remedy and its cost, and the dry run showing them as `sandbox caps` and
`unshare ns`. Verified on stock policy: the launch exits 1 naming the policy and
leaves no session state behind.

**Decision on record (the user's, 2026-09-23): never skip a hardening step.**
sbx does not adapt by dropping the bounding-set drop where the platform forbids
it — a session either gets the guarantee or does not start. A test asserts the
remedy text never offers to skip, ignore, bypass or disable it.

Not diagnosed, because it turned out not to exist: an apparent "tmux layer"
failure in the first Ubuntu run was `TERM=dumb` in a non-interactive SSH
session — the tmux *client* could not attach, so a session that had in fact run
its payload looked dead from outside. Use a real `TERM` when driving sbx over
SSH.

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
