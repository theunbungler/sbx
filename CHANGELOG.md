# Changelog

Notable changes to sbx, newest first. sbx has no numbered releases yet, so
entries are grouped by milestone and dated by the day the work landed. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Changes marked **Breaking** need something done by hand: a flag, a profile
or a directory to update.

## [Unreleased]

On `main` since the nested-sessions milestone; not yet part of a numbered
release.

### Added
- **Workspaces** (2026-09-27): `--workspace <name>` applies a saved
  `{fs, net, wd, gui}` from `./.sbx/<name>.json` or
  `~/.config/sbx/<name>.json`; the most local wins. A git-tracked project
  workspace is confirmed before use, and the prompt names any workspace of
  yours it shadows. `--list-profiles` lists workspaces.
- **`"gui": true` profile field** (2026-09-26): a profile can ask for the
  xpra display. The field, `--gui` and a workspace all combine into one
  display per session. `fs/chrome` sets it. Project profiles may set it too.
- **`path` in fs profiles** (2026-09-26): each profile's entries go on
  `PATH`, a later profile's in front of an earlier one's.
- `CLAUDE.md`, with the commands, architecture and security invariants for
  working on sbx.

### Changed
- **Breaking: cli profiles are now fs profiles** (2026-09-26). The `cli`
  type is gone and the bundled `claude`, `dev`, `gemini` and `pi` profiles
  moved to `profiles/fs/`. `--cli <name>` still works, as an alias that
  applies an fs profile after every `--fs` one, and it can now be repeated.
  Nothing is read from a `cli/` directory any more: move your own
  `~/.config/sbx/profiles/cli/*.json` into `fs/`. sbx warns about leftover
  `cli/` directories, and names a cli profile that a same-named fs profile
  replaced. `forked` stores are keyed by profile name, so moved profiles
  keep theirs.
- xpra runs with clipboard sharing off, so an attached viewer never gives a
  session your host clipboard.
- `fs/chrome` no longer sets `DISPLAY` and `WAYLAND_DISPLAY` to sockets the
  sandbox never had.
- `session.json` no longer has `cli_profile`; `fs_profiles` lists every
  applied profile in order.
- sbx is restructured into subcommands, launch phases and `main`. Sessions
  run from fixed scripts in `lib/` instead of generated ones (2026-09-24).
- `forked` and `record` stores are keyed by a digest of the mount path, so
  two mounts can never share one (2026-09-24).
- `--reseed` runs before a session name is claimed (2026-09-24).

### Security
- A session never sees the launch directory's `.sbx`, which configures the
  next launch. An empty tmpfs covers it wherever a writable mount would
  expose it (2026-09-24).

## 2026-09-23: Nested sessions and Ubuntu support

### Changed
- **Every session's payload runs in a nested user namespace (B)** inside the
  control namespace (A). Mounts made in A are locked in B, and A's nftables
  ruleset is out of B's reach. So `ro` mounts and the egress firewall now
  hold even for `caps: keep` sessions (`fs/podman`, `fs/podman-full`),
  which previously gave up both.
- Host ports and DNS keep the same addresses inside hardened sessions,
  through socat relays on a second veth address in A.
- `podman-full` containers get DNS on the default network again.
- New core dependencies: socat, nsenter, unshare. Networked sessions need
  the `veth` kernel module to be loadable; `--doctor` checks for it.

### Added
- Ubuntu support. sbx detects the AppArmor policies that would block a
  session and refuses before building anything, and `--doctor` prints the
  two allowances Ubuntu needs, including what each costs. A session either
  gets every hardening step or does not start.

## 2026-09-20: Setup and authoring (setup-ux)

### Added
- `sbx --doctor [--json]`: grouped dependency checks with a one-line
  install command for Arch, Debian/Ubuntu or Fedora, plus a real
  user-namespace probe that explains why it failed.
- A launch checks exactly the dependencies its profiles need, and stops
  before building a session.
- `sbx --dry-run [--json]`: everything a launch would do, without doing it:
  profiles, mounts, environment (values unexpanded, so host secrets are not
  printed), network grants, every host location written, missing
  dependencies, prompts, warnings and errors.
- Profile schema validation: every problem is reported at once, and unknown
  fields are errors.
- `sbx-profile ls | check | new`, for listing, validating and creating
  profiles. `ls` marks shadowed profiles.

### Changed
- **Breaking:** profiles are loaded by name only. File-path arguments to
  `--fs`, `--net` and `--cli` are rejected, and the launch directory itself
  is never searched.
- **Breaking:** transition logic and compatibility for old profile
  conventions are removed.
- Launches are built from one resolved JSON plan, so `--dry-run` and the
  launch cannot disagree.
- Unknown `--options` are rejected instead of being taken as the payload
  command.

## 2026-09-06: Mount authority and ephemeral sessions

### Added
- `forked` mount perm: seeded from the host once, then sandbox-owned and
  persistent per profile and launch directory.
- `record` mount perm: a fresh working copy every launch. What the session
  changed is archived at teardown; see it with `--changes [<id>]`.
- `--gc` removes crash residue and trims old change archives. `--reseed`
  discards a directory's forked stores, after confirmation, and refuses
  while a session uses them.
- Progress reporting for slow mount seeds.

### Changed
- **Breaking:** the `copy` perm is retired in favour of `forked` and
  `record`. A profile using it is rejected with an error naming both.
- Sessions are ephemeral and named after the launch directory. Name claiming
  is serialized, and liveness is tracked outside the sandbox, where a
  payload cannot forge it.

## 2026-09-05: tmux sessions, `--join` and `--attach`

### Changed
- **Breaking:** the payload runs under an in-sandbox tmux server instead of
  abduco/dtach.

### Added
- `--join <session>` opens a new shell inside a running sandbox, with its
  own terminal and the same containment as the payload.
- `--attach <session>` reaches a session's original terminal.

### Fixed
- tmux no longer carries the host environment into a join.

## 2026-08-28: Stackable network profiles and host services

### Added
- `--net` can be given more than once. Each destination keeps only the
  ports of the profile that granted it.
- `--host-port <port>[/tcp|/udp]` and the `host_ports` net-profile field
  reach a service on the host's loopback from inside a sandbox.
- UDP support.
- `--wd <path>` sets the starting directory.

### Changed
- **Breaking:** the profile field `workingDirectory` is no longer honored;
  sbx warns and names the `--wd` to pass instead.

### Fixed
- localhost reachability.
- WSL/Ubuntu bugs in the copy step (`rcopy`) and with absent mount points.

## 2026-08-02: Hardening

### Security
- Sandboxes are capless: the capability bounding set is emptied, and `nft`
  and `dnsmasq` run outside the sandbox, where nothing inside can signal or
  change them.
- The environment is cleared. Host variables arrive only through a
  profile's `passthrough`.
- sbx's state and config directories are masked inside the sandbox.
- A project-supplied profile needs confirmation before use, and may not
  request `caps`.
- `--list-sessions` output is sanitized.
- The README documents the threat model and its residual risks.

### Added
- `"caps": "keep"`, a user-profile field for sessions that need
  capabilities (podman).

### Changed
- The claude profile's `.local` and `.nvm` mounts are read-only.

## 2026-07-30

### Added
- dtach as an alternative to abduco, which Debian dropped.

## 2026-07-24: Persistent CLI profile state

### Added
- `copy` mounts in cli profiles persist across launches, in a store per
  profile and launch directory. This is what let `--cli claude` keep its
  sessions and auth. (Superseded by `forked` on 2026-09-06.)

## 2026-07-20: Containers, part 2

### Added
- `"userns": "full"`: multi-UID podman, with the user's whole subordinate-ID
  range. Requires `--net`.
- A `docker` CLI shim, `DOCKER_HOST`, and an opt-in podman API socket
  (`"docker_api": true`).
- The `podman-full` profile.

### Fixed
- Container egress through the netavark bridge is filtered by the
  allow-list, and container DNS goes through a DNS-enabled network so
  hostname allow-listing applies.

## 2026-07-17: Podman and QEMU inside the sandbox

### Added
- Rootless podman plumbing in every session, plus `podman` and `qemu` fs
  profiles (KVM-accelerated VMs).
- `dev` mount perm. An absent `rw` mount source is created.

### Fixed
- A devpts error when combining `--net` with podman container creation.

## 2026-06-28

### Changed
- DNS allow-listing uses dnsmasq's nftset integration instead of dnscrypt
  plus a sniffer.

## 2026-06-27: First version

### Added
- `sbx`: bwrap sandboxes built from composable cli, fs and net profiles,
  with network egress limited to allowed domains.
- `--gui`: an isolated display through xpra.
- The `chrome` profile.
