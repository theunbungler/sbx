# Setup UX: dependency checks, a resolve step, dry runs, and profile authoring

**Date:** 2026-09-16
**Status:** Designed, not implemented
**Branch:** `setup-ux` (experimental)

**Builds on:** `require_tools` at `sbx:665-693`, profile lookup at
`sbx:109-170` (`resolve_profile`, `list_profiles`), the project-profile confirmation at `sbx:615`, the mount
resolution in `apply_mounts` (`sbx:1163`), the forked/record seeding
(`sbx:1371-1430`), and the net profile merge (`sbx:1550-1660`).

## Goal

Make sbx easier to set up, then easier to configure:

1. **Know what is installed and what is missing**, with the exact fix for
   the detected distro — including the host settings that are not packages
   (unprivileged user namespaces, AppArmor, subordinate IDs).
2. **Catch profile mistakes as profile mistakes**, not as jq or bwrap
   errors deep in a launch.
3. **Show what a launch would do before doing it** — what is mounted, from
   which profile, what the environment and network look like, and where
   every write outside the sandbox lands.
4. **Make new profiles cheap to start**, in the right place, and make the
   network allow-list learnable rather than guessed.

Audience: Linux users on Arch, Debian/Ubuntu and Fedora families. sbx
prints commands; it never runs package managers or anything as root.

## Phases

Each phase is committed separately on `setup-ux`.

1. Dependencies (`lib/deps.sh`, launch preflight, `sbx --doctor`)
2. Resolve step and validation (`lib/resolve.sh`, `lib/profile-check.sh`,
   `lib/profiles.sh`) — a refactor with no user-visible change except
   earlier, better errors
3. `sbx --dry-run`, including where writes go
4. `sbx-profile` (`new`, `check`, `ls`)
5. Learning mode (`sbx --learn-net`)

Validation precedes authoring so that generated profiles are checked by
the same code that checks hand-written ones. The resolve step precedes
`--dry-run` so the preview and the launch cannot disagree.

## Phase 1: Dependencies

### The table

`lib/deps.sh` holds one table, one row per tool:

| field | example |
|---|---|
| tool | `pasta` |
| group | `core` · `net` · `gui` · `podman` |
| packages | `arch:passt debian:passt fedora:passt` |

Groups:

- `core` — bwrap, tmux, jq, envsubst, setpriv, flock, realpath,
  sha256sum, ip
- `net` — pasta, nft, dnsmasq
- `gui` — xpra
- `podman` — podman, newuidmap

### Distro detection

Read `ID` and `ID_LIKE` from `/etc/os-release` (overridable as
`SBX_OS_RELEASE` for tests). Map to a family: `arch` (Arch, Manjaro,
EndeavourOS…), `debian` (Debian, Ubuntu, Mint…), `fedora` (Fedora, RHEL
likes). An unknown family prints package names for all three.

### Host checks that are not packages

- **Unprivileged user namespaces.** Probe with
  `bwrap --unshare-user --ro-bind / / true` — a real test, measured at
  under 10ms, so it runs on every launch. On failure, report the most
  likely cause and its fix:
  - `kernel.apparmor_restrict_unprivileged_userns=1` (Ubuntu 24.04+): print
    an AppArmor profile for `bwrap` and `pasta` and where to install it.
  - `kernel.unprivileged_userns_clone=0`: print the sysctl.
  - `user.max_user_namespaces=0`: print the sysctl.
- **Subordinate IDs** (`podman` group): an entry for `$USER` in
  `/etc/subuid` and `/etc/subgid`. Fix: the `usermod --add-subuids` line
  already in the README.

### Launch preflight

`require_tools` is replaced by `deps_require <groups…>`. The groups come
from the resolved plan (Phase 2): `core` always; `net` when any net
profile is applied; `gui` for `--gui`; `podman` when a profile sets
`userns`, `docker_api` or `caps: keep`. The userns probe runs once `core`
passes. Messages name only the detected distro's command, e.g.
`sudo pacman -S passt`.

Until Phase 2 lands, the groups are chosen from the parsed flags and the
feature-field scan, as `require_tools` does today.

### `sbx --doctor`

Prints every group with ✓/✗, the detected distro, and one combined
install command for everything missing. Exits non-zero only if `core` or
the userns probe fails; optional groups are informational. `--doctor
--json` emits the same data for scripting.

### Tests

- Stub `PATH`: a directory of symlinks to the real tools minus the ones
  under test.
- Fake `os-release` files per family, plus an unknown one.
- A fake `bwrap` that fails the probe with each cause's error text.
- Preflight selects the right groups for `--net`, `--gui`, and a
  `userns: full` profile.

## Phase 2: Resolve step and validation

### The plan

`lib/resolve.sh` exposes `sbx_resolve`: parsed flags in, one JSON plan
out, with **no side effects** — no directories created, nothing seeded,
no session name claimed.

```json
{
  "profiles": [{"type":"fs","name":"sandbox","path":"…","origin":"user|project|global"}],
  "errors": [], "warnings": [],
  "confirm": ["./.sbx/profiles/fs/tst.json"],
  "deps": ["core","net"],
  "security": {"caps":"drop","userns":null,"docker_api":false,"net_open":false},
  "mounts": [{"source":"/home/u/.pi","dest":"/home/u/.pi","perm":"forked",
              "from":"cli/pi","present":true}],
  "env": [{"name":"EDITOR","value":"vim","from":"cli/dev","overrides":["fs/x"]}],
  "path": ["…"],
  "passthrough": ["…"],
  "net": {"enabled":true,"dns":"1.1.1.1","domains":[{"name":"github.com","ports":[80,443]}],
          "cidrs":[],"allow_all":false,"host_ports":["5432/tcp"]},
  "writes": [],
  "gui": false,
  "wd": "/workspace"
}
```

JSON rather than bash arrays: jq already does the merging (env
last-wins, net profile stacking, port unions), bats can assert on a plan
without launching, and `--dry-run --json` is free.

### Launch flow after the refactor

parse → resolve → validate → *(dry-run: print, exit)* → confirm project
profiles → dependency preflight → execute.

Everything from the session-name claim onward reads the plan instead of
re-reading profile files: bwrap arguments, seeding, dnsmasq and nft
flags, the join sidecar, GUI setup. Side effects (`mkdir -p` of an absent
`rw` source, seeding) stay in execution; the plan only records that they
will happen. The `workingDirectory` warning and the skipped-mount note
move into `warnings`.

### Profile lookup

Lookup and location precedence (`./.sbx/profiles`, then
`~/.config/sbx/profiles`, then the global directory) move from `sbx` into
`lib/profiles.sh`, shared by `sbx` and `sbx-profile`.

### Validation rules

`lib/profile-check.sh`, one jq program per type. The README's schema
tables are the source of truth.

**Errors** (launch stops; all errors reported at once):

- Invalid JSON — file plus jq's line and column.
- Unknown fields. There is no comment convention; any field not in the
  schema is an error.
- Types and values:
  - `perm` ∈ `ro`, `rw`, `dev`, `forked`, `record`
  - `caps` = `"keep"`, `userns` = `"full"`, `docker_api` boolean
  - `ports` entries: integer 1–65535 or `"*"`
  - `host_ports` entries: `N`, `"N/tcp"`, `"N/udp"`
  - `allow` entries: hostname glob or valid CIDR
  - `env` values: string or number
  - mounts: string `source` and `dest`, both required
- Location: a project profile (`./.sbx`) using `caps`, `userns`,
  `docker_api` or `host_ports`. Same messages as today's launch-time
  rejection, reported earlier.

**Warnings** (launch continues):

- `workingDirectory` present (existing behavior).
- `dns` not a bare IPv4 address (silently falls back to 1.1.1.1 today).
- Mount `source` absent on this host (skipped today).
- `*.` wildcard in `allow`, pointing at the README caveat.

**Message format:** file, JSON path, expectation, actual value.

```
~/.config/sbx/profiles/net/api.json: .ports[1]: expected a port 1-65535 or "*", got "https"
```

### Rollout risk

Unknown-field errors can break existing personal profiles. Before
validation is wired into launch, run the checker over
`~/.config/sbx/profiles` and fix or report what it finds.

### Tests

- **Snapshot test, written before the refactor.** For a fixed set of
  profile combinations (plain, forked + record mounts, stacked net,
  host ports, `--gui`, `podman`), capture the generated bwrap argument
  list and `launch.sh`, with session IDs and paths normalized. The
  refactor must reproduce them exactly. **Feasibility to confirm first:**
  that generation can be captured without executing bwrap (e.g. an
  internal `SBX_EMIT_ONLY` stop point or a stub `bwrap` on `PATH`).
- Existing suites and the shellcheck gate pass unchanged.
- One bad fixture per validation rule, asserting its message.
- Every shipped profile in `profiles/` validates clean.
- Plan assertions via jq: env override attribution, stacked net merge,
  absent-source mounts marked `present: false`.

## Phase 3: `sbx --dry-run`

Takes the same flags as a launch. Resolves, validates, runs the
dependency check in report-only form, prints the plan, exits. Never
prompts, never creates anything. Exit status is non-zero when the real
launch would stop (validation errors, missing required dependencies).
`--dry-run --json` prints the plan document.

### Writes

The plan's `writes` list names every host location the session writes:

| Kind | Path | Lifetime |
|---|---|---|
| `forked` store | `~/.local/state/sbx/forked/<profile>/<cwd-slug>/<mount-id>` | Persistent until `--reseed`; marked *exists* or *will seed* with source size |
| `record` working copy | `~/.local/state/sbx/work/<session-id>/<mount-id>` | Removed at teardown |
| `record` change archive | `~/.local/state/sbx/changes/<cwd-slug>/<stamp>-<session-id>/` | Newest `SBX_KEEP_CHANGES` (default 10) kept |
| `rw` / `dev` bind | the host source | Direct |
| podman store | `~/.local/state/sbx/virt/containers` or `containers-full` | Persistent |
| qemu images | `~/.local/state/sbx/virt/images` | Persistent |
| session directory | `~/.local/state/sbx/sessions/<name>/` | Removed at teardown; `--gc` after a crash |
| learning report | `~/.local/state/sbx/learn/<cwd-slug>/<stamp>-<session-id>/` | Persistent (Phase 5) |

Session IDs are assigned at launch and print as `<session-id>`.

### Output

```
Profiles   cli/pi (user)  fs/sandbox (global)  net/web (global)
Security   capabilities dropped · no userns · no docker API
Mounts     ro      ~/.nvm          → ~/.nvm                    cli/pi
           forked  ~/.pi           → ~/.pi   (store exists)    cli/pi
           rw      ~/proj          → /workspace                fs/sandbox
           skip    /opt/missing    → /opt/x  (source absent)   fs/sandbox
Env        EDITOR=vim  (cli/dev; overrides fs/x)
Passthru   ANTHROPIC_API_KEY
Network    dns 1.1.1.1 · ports 80,443 · github.com, *.google.com · 192.168.1.0/24
Writes     persistent  ~/.local/state/sbx/forked/pi/-home-u-proj/_home_u_.pi   (will seed, 412M)
           host        ~/proj  ← rw from /workspace
           archived    ~/.local/state/sbx/changes/-home-u-proj/<stamp>-<session-id>/
           temporary   ~/.local/state/sbx/work/<session-id>/, sessions/<name>/
Needs      core ✓ · net ✗ pasta missing → sudo pacman -S passt
Confirm    ./.sbx/profiles/fs/tst.json would prompt
Warnings   …
```

Passthrough variables are listed by name, never by value.

The plan describes what is mounted, not what the mounted trees contain.

### Tests

- `--dry-run` creates nothing under `$STATE_DIR` (compare a tree listing
  before and after).
- Exit codes for clean, validation error, missing dependency.
- Writes section for each mount kind, including *will seed* vs *exists*.
- A project profile does not prompt under `--dry-run`.

## Phase 4: `sbx-profile`

A separate script beside `sbx`, locating the repo the same way
(`SCRIPT_DIR`) and sourcing `lib/profiles.sh` and `lib/profile-check.sh`.
Everything that takes launch flags stays in `sbx`; `sbx-profile` works on
profile files.

### `sbx-profile new <type> <name> [--user|--local] [--from <type>/<name> | --from-learn <dir|latest>]`

- **Location.** `--user` → `~/.config/sbx/profiles/<type>/`; `--local` →
  `./.sbx/profiles/<type>/`. With neither: prompt on a TTY; otherwise exit
  with an error naming both flags. Never writes the global directory.
- **No overwrite.** An existing file is refused; there is no `--force`.
- **Shadowing.** Warn when the new profile hides one of the same name at a
  lower-precedence location.
- **Templates** — minimal and valid, with empty grants so a template
  cannot open access by accident:
  - cli: `description`, `env {}`, `passthrough []`, `mounts []`
  - fs: `description`, `mounts []`
  - net: `description`, `dns "1.1.1.1"`, `allow []`, `ports [443]`
- **`--from`** copies an existing profile with a new `description`. With
  `--local`, refused if the source uses `caps`, `userns`, `docker_api` or
  `host_ports`, naming which.
- **`--from-learn`** (net only) uses a learning report's `suggested.json`
  (Phase 5). `latest` is the newest report for the current directory.
- The result is validated before it is written.
- **Output:** the path written, a short field guide for the type, the
  README section, and the next step: `sbx --dry-run --<type> <name>`.

### `sbx-profile check [<type>/<name> | <path>]`

Runs Phase 2 validation. With no argument, checks every profile visible
from the current directory and labels each with its origin.

### `sbx-profile ls`

Lists profiles with origin, marking shadowed ones. `sbx --list-profiles`
stays as an alias over the same library function.

### Tests

Temporary `HOME` and project directory, as `tests/project-profiles.bats`
does.

- TTY prompt vs non-TTY error when no location flag is given.
- Refuses to overwrite.
- `--local --from` a profile with restricted fields is refused.
- Every template validates.
- Shadowing warning.
- `--from-learn latest` picks the newest report for the directory.

## Phase 5: Learning mode

### Usage

`sbx --learn-net [--open] <launch flags>` runs a normal session and
records network use. Requires at least one `--net` profile, or `--open`.

### Modes

- **Default: enforce.** The selected net profiles apply as usual.
  Denied lookups and dropped connections are recorded. May take several
  rounds, since software often stops at its first failure.
- **`--open`.** Adds an allow-all grant (`*`, all ports). The launch
  banner and `--dry-run` show `network: OPEN (learning)`; launching asks
  for confirmation (`--yes` skips it). This deliberately relaxes the
  threat model for trusted software.

### Collection (all outside the sandbox)

- **DNS.** dnsmasq gains `--log-queries --log-facility=<session>/dns.log`:
  queries, refusals, and the A records returned.
- **Connections.** An nft rule placed before the drop verdict adds
  `ip daddr . <proto> dport` to a dynamic set `seen4`, recording ports in
  use and raw-IP attempts whether allowed or dropped. A set is used
  instead of the `log` statement because packet logging is disabled
  outside the initial network namespace by default.
  **Feasibility to confirm first:** dynamic set updates from the output
  hook in the pasta namespace, with the nft version and invocation sbx
  already uses.

### Teardown

Before the ruleset goes away, dump `seen4`. Join IPs to hostnames through
the DNS answers; attach ports to hostnames. Write to
`~/.local/state/sbx/learn/<cwd-slug>/<stamp>-<session-id>/`:
`dns.log`, `seen.json`, `report.json`, `suggested.json`. Print:

```
Learned network use (enforcing net/web):
  allowed   github.com            443
  DENIED    api.openai.com        (lookup refused)
  DENIED    140.82.112.3:22       (raw IP, no lookup)
Suggested: ~/.local/state/sbx/learn/-home-u-proj/20260916-…/suggested.json
Adopt:     sbx-profile new net myapp --user --from-learn latest
```

### Suggested profile

- Exact hostnames only; never synthesize `*.` wildcards.
- Ports as observed; a lookup with no observed connection defaults to 443.
- Enforce mode: current grants plus denied entries. `--open`: everything
  observed.
- Raw-IP destinations are included only as `/32` CIDRs, with a warning in
  the report: connecting to an IP no lookup returned is often an attempt
  to avoid the resolver.
- It is a suggestion. Nothing edits an existing profile.

### Hostile input

Names in `dns.log` are chosen by the sandbox. Strip control characters
before printing; admit into `suggested.json` only names matching a strict
hostname pattern. Cap at 500 distinct names and 500 distinct IP:port
pairs; the report states when a cap was hit.

### Tests

- Parser and merge against captured `dns.log` / `seen4` fixtures,
  including control characters, an invalid hostname, and cap overflow.
- Suggested profile validates, for both modes.
- End-to-end (short `HOME`, per the e2e convention): `getent hosts
  github.com` under `--learn-net --net <profile allowing github.com>`
  produces a report listing it.

## Non-goals

- Running package managers, sysctl, or AppArmor changes on the user's
  behalf.
- An interactive profile wizard.
- Comments inside profile JSON.
- Showing the contents of mounted trees in `--dry-run`.
- Learning filesystem access (which paths a program reads) — network
  only.
- Seccomp.
