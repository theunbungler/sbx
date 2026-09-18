# sbx (sandbox-gemini)

`sbx` is a command-line tool designed to manage isolated sandboxed environments. It allows users to spin up, manage, and join sessions with highly configurable environments using modular profiles for CLI, Filesystem, and Networking.

## Features

- **Modular Profiles**: Tailor your sandbox with specific configurations:
  - **CLI Profiles**: Set environment variables, paths, and mounts (e.g., `dev`, `gemini`, `pi`).
  - **Filesystem (FS) Profiles**: Define mounts and filesystem-level configurations (e.g., `chrome`, `sandbox`).
  - **Network (NET) Profiles**: Control network access and connectivity (e.g., `web`, `test_net`).
- **Session Management**: List active sessions, and open additional shells inside a running one.
- **GUI Support**: Enable isolated graphical interfaces using `xpra`.
- **Flexible Configuration**: Profiles can be stored locally, in your home directory, or in system-wide paths.

## Threat model

sbx assumes the code running inside a sandbox and the project directory it
was launched from are both adversarial. It is built to protect the host user
account from them.

What that buys you, in a session without `"caps": "keep"`:

- **`ro` mounts are read-only.** The payload holds no capabilities, so it
  cannot remount a bind read-write.
- **`--join` gets the same containment as the payload.** The drop is applied
  once, above the in-sandbox tmux server, so everything the session ever
  forks — the payload, a join, and any window or pane opened from inside one
  — starts with an empty bounding set. `--join` also takes no input from the
  sandbox: its command, `PATH` and working directory are built on the host.
- **The egress allow-list is not removable.** `nft` and `dnsmasq` run outside
  the sandbox's PID and mount namespaces; nothing inside can flush the
  ruleset or signal the resolver.
- **The host environment does not leak in.** The environment is cleared;
  variables arrive only via the base set or a profile's `passthrough`.
- **sbx's own state and config are masked**, so a sandbox cannot reach
  sibling sessions, persistent cli stores, or the profiles that configure the
  next launch.
- **Project-supplied profiles require confirmation**, and may never request
  `caps`, `userns`, or `docker_api`.

### What it does not protect against

- **Sessions with `"caps": "keep"`** — including `fs/podman` and
  `fs/podman-full`. Capabilities are required for the nested user namespaces
  podman needs, and with them `ro` mounts are writable and the firewall is
  removable. Such sessions print a warning at launch.
- **Kernel exploits.** There is no seccomp filter: `bwrap --seccomp` needs a
  compiled BPF blob, which is the kind of custom code this project avoids.
- **Wildcard `allow` entries.** `*.anthropic.com` admits any IP an attacker
  can publish under that suffix.
- **DNS as an exfiltration channel.** Query labels for allowed domains are
  forwarded upstream.
- **`"ports": ["*"]`** in `net/anthropic.json` and `net/gemini.json` — any
  allowed IP is reachable on any port. Narrowing to 443 would break `git push`
  over SSH to `github.com`.

## Checking your setup

Run `./sbx --doctor` first. It groups dependencies by what needs them —
`core` (every session), `net` (`--net`), `gui` (`--gui`) and `podman`
(`userns`, `caps` or `docker_api` profiles) — and prints one install
command for everything missing, for Arch, Debian/Ubuntu or Fedora
families.

It also checks that bwrap can actually create an unprivileged user
namespace, which is the setup failure that is hardest to recognise from
the error alone. On Ubuntu 24.04 and later this is blocked by AppArmor by
default; the doctor prints the profile that allows it.

A launch runs the same checks for just the groups it needs, and stops
before building a session.

## Usage

To see all available commands and options, run:

```bash
./sbx --help
```

### Common Commands

| Command | Description |
|---------|-------------|
| `--doctor [--json]` | Check that required tools are installed and that unprivileged user namespaces work. Prints the install command for your distro. Exits non-zero only if something every session needs is missing. |
| `--dry-run [--json]` | Show everything this launch would do — profiles, mounts, environment, network grants, every host location it would write, missing dependencies, confirmations, warnings and errors — without creating, prompting or launching anything. Exits 1 if the real launch would stop. |
| `--list-profiles` | Show all available CLI, FS, and NET profiles. |
| `--list-sessions` | List all currently active sandbox sessions. |
| `--join <session>` | Open a new shell inside a running sandbox session, with its own terminal. Append `-- <cmd>` to run a command instead. |
| `--attach <session>` | Reattach to a running session's original terminal (the one `sbx` started it on). |
| `--wd <path>` | Start the session in this directory inside the sandbox. |
| `--host-port <spec>` | Reach a service running on the host's `127.0.0.1:<port>` from inside the sandbox. `<spec>` is `<port>[/tcp\|/udp]`; a bare number means TCP. Repeatable. |
| `--gui` | Start a session with isolated GUI support via `xpra`. |
| `--changes [<id>]` | Show what the most recent (or a named) `record`-mount session changed, for the current directory. |
| `--reseed` | Discard this directory's `forked` stores for the selected profiles, so the next launch seeds them from the host again. Asks first; refuses while a session holding one of those stores is still running. |
| `--gc` | Remove crash residue — session directories and working copies left by a session that never got to shut down — and trim old change archives. Never removes a `forked` store; it reports them instead. |
| `--yes` | Answer the confirmation prompts (`--reseed`, project-local profiles) with yes. |

### Applying Profiles

You can combine multiple profiles to build your desired environment:

```bash
# Start a session with a specific CLI, FS, and Network profile
./sbx --cli dev --fs chrome --net web
```

## Constructing Profiles

Profiles are JSON files organized into three categories — **CLI**, **Filesystem (FS)**, and **Network (NET)** — and stored under `profiles/<type>/<name>.json`. Each type has its own schema.

### Profile Locations

`sbx` searches for profiles in the following directories (in order):

1. `./.sbx/profiles/` (Local to the current directory)
2. `$HOME/.config/sbx/profiles/` (User-specific configuration)
3. Global profiles in the profiles directory with sbx


### CLI Profiles (`profiles/cli/<name>.json`)

CLI profiles configure the shell environment inside the sandbox. They control environment variables, PATH entries, and additional filesystem mounts.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | string | No | Human-readable label for the profile |
| `env` | object | No | Key-value pairs of environment variables to set |
| `path` | array of strings | No | Directories to prepend to the sandbox `PATH` |
| `mounts` | array of objects | No | Filesystem mounts (same structure as FS mounts below) |
| `passthrough` | array | No | Host environment variables to forward into the sandbox by name. The environment is otherwise cleared. |
| `caps` | string | No | `"keep"` retains capabilities inside the sandbox. Required for nested user namespaces (podman); costs the read-only-mount and firewall guarantees. Ignored — and rejected — in project-supplied profiles. |

**Example — minimal:**

```json
{
    "description": "Standard Development Environment",
    "env": {
        "EDITOR": "vim",
        "PATH": "/usr/local/bin:/usr/bin"
    }
}
```

**Example — with mounts and extra PATH:**

```json
{
    "description": "Pi environment",
    "env": {
        "NO_BROWSER": 1,
        "NODE_OPTIONS": "--dns-result-order=ipv4first"
    },
    "path": [
        "$HOME/.nvm/versions/node/v24.13.1/bin"
    ],
    "mounts": [
        {"source": "$HOME/.nvm", "dest": "$HOME/.nvm", "perm": "ro"},
        {"source": "$HOME/.npm-global", "dest": "$HOME/.npm-global", "perm": "ro"},
        {"source": "$HOME/.pi", "dest": "$HOME/.pi", "perm": "forked"}
    ]
}
```

### Filesystem (FS) Profiles (`profiles/fs/<name>.json`)

FS profiles define the sandbox's filesystem layout — which directories are mounted and FS-level environment variables. The starting directory is not a profile field; pass `--wd <path>` on the command line.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | string | No | Human-readable label for the profile |
| `mounts` | array of objects | No | Filesystem mount specifications (see below) |
| `env` | object | No | Key-value pairs of environment variables to set |
| `userns` | string | No | `"full"` runs the entire session inside an outer user namespace carrying your full subordinate-UID range (multi-UID podman). Requires `--net`; the session identity becomes namespace-root. See [Multi-UID containers](#multi-uid-containers-podman-full). |
| `docker_api` | boolean | No | `true` starts a podman docker-API socket for the session (see [Docker compatibility](#docker-compatibility)). Honored in CLI profiles too. |
| `passthrough` | array | No | Host environment variables to forward into the sandbox by name. The environment is otherwise cleared. |
| `caps` | string | No | `"keep"` retains capabilities inside the sandbox. Required for nested user namespaces (podman); costs the read-only-mount and firewall guarantees. Ignored — and rejected — in project-supplied profiles. |

#### Mount Object

Each entry in the `mounts` array has these fields:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | string | Yes | Host path. Supports `$HOME`, `$PWD`, and other environment variables via `envsubst`. |
| `dest` | string | Yes | Destination path inside the sandbox. Also supports variable substitution. |
| `perm` | string | Yes | Mount permission: one of `ro` (read-only bind), `rw` (read-write bind), `dev` (device bind, for files under `/dev`), `forked` (sandbox-owned, seeded from the host once — see below), or `record` (host-owned, reseeded every launch, changes archived — see below) |

**Permission modes explained:**

- **`ro`** — Read-only bind mount. The sandbox sees the host directory but cannot modify it.
- **`rw`** — Read-write bind mount. Changes made inside the sandbox are reflected on the host.
- **`forked`** — Sandbox-owned. The first time a given profile/mount is launched from a given directory, the source is copied into a persistent store at `~/.local/state/sbx/forked/<profile-name>/<cwd-slug>/<mount_id>/`, which is then bound straight into the sandbox. After that first seed, the host source is never consulted again — the store *is* the tree, edits and deletions inside the sandbox persist there across launches, and later changes to the host original have no effect on it. This is what lets `sbx --cli claude` keep the sessions, history, and auth it accumulated last time. `<cwd-slug>` is the launch directory (`$PWD`) with slashes dashed, so each project gets its own store.
- **`record`** — Host-owned. A private working copy is seeded fresh from the host source on *every* launch, and bound into the sandbox; the sandbox never touches the host original. At teardown, files the session created or modified (relative to that launch's seed) are archived to `~/.local/state/sbx/changes/<cwd-slug>/<stamp>-<session-id>/<mount_id>/`, and deletions are listed in a sibling `<mount_id>.deleted` file — see [Forked and Record Mounts](#forked-and-record-mounts) below and `--changes`.
- **`dev`** — Device bind mount (`--dev-bind`). Like `rw`, but allows device-node access (a plain `ro`/`rw` bind mounts `nodev`, so opening a device file would fail). Used for things like `/dev/kvm` and `/dev/net/tun`.

**Example:**

```json
{
    "description": "Project workspace",
    "mounts": [
        { "source": "$PWD", "dest": "/workspace", "perm": "rw" },
        { "source": "/usr/include", "dest": "/usr/include", "perm": "ro" }
    ],
    "env": {
        "USER": "user",
        "DISPLAY": ":0"
    }
}
```

### Network (NET) Profiles (`profiles/net/<name>.json`)

NET profiles control network access inside the sandbox. Like FS profiles, they stack — `--net` may be given more than once, and the grants combine (see [Stacking network profiles](#stacking-network-profiles)). When a network profile is applied, the sandbox uses `pasta` for user-mode networking, `dnsmasq` for DNS resolution (with per-domain forwarding and domain allowlisting), and `nftables` for egress filtering keyed on the IPs dnsmasq resolves. `dnsmasq` and `nft` are started outside the sandbox, so nothing running inside can signal the resolver or alter the ruleset.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | string | No | Human-readable label for the profile |
| `dns` | string | No | Upstream DNS server as a plain **IP address** (e.g., `"1.1.1.1"`). dnsmasq does not speak DoH stamps; anything that is not a bare IPv4 address falls back to `1.1.1.1` |
| `allow` | array of strings | No | Allowed destinations. Supports **hostname globs** (e.g., `"*.google.com"`, `"github.com"`) and **CIDR notation** (e.g., `"192.168.1.0/24"`) |
| `ports` | array | No | Allowed ports. Can be a list of port numbers (`[80, 443]`) or the wildcard `["*"]` to allow all ports |
| `host_ports` | array | No | Host services to expose inside the sandbox at `127.0.0.1:<port>`. Entries are `<port>` (TCP) or `"<port>/tcp"` / `"<port>/udp"`. Not honored in project-supplied profiles. |

**How filtering works:**

Egress is enforced at the **IP layer by `nftables`**, not just at DNS resolution. The output chain defaults to `drop`; a connection is only permitted if its destination IP is explicitly allowed. This closes the bypass where a process connects straight to a raw IP (or a public DNS provider) and skips the filtered resolver entirely.

1. **Domain allowlisting** — Each hostname entry in `allow` (those matching `^[a-zA-Z*]`) becomes a `--server=/<domain>/<upstream>` flag, with any leading `*.` stripped: dnsmasq matches the apex and all subdomains. Only those domains have an upstream to forward to; every other query gets no answer.
2. **Dynamic IP allowlisting** — The same domains get a `--nftset=/<domain>/inet#sbx_filter#allowed4` flag, so dnsmasq adds every A-record answer it returns straight to the `nftables` set `allowed4`. `nftables` then permits connections to exactly those IPs (subject to the port filter). An IP the resolver never returned is dropped. `--filter-AAAA` keeps answers to A records; IPv6 egress is dropped regardless.
3. **CIDR allowlisting** — IP/CIDR entries in `allow` (those matching `^[0-9]`) become `nftables` rules that accept outbound traffic to those address ranges (any port).
4. **Port filtering** — `nftables` rules restrict the allowed TCP/UDP destination ports for resolved hosts. If only hostnames are listed without explicit ports, TCP 80 and 443 are allowed by default.
5. **Default policy** — The egress chain default is `drop`. The only fixed exceptions are loopback, established/related flows, and the upstream resolver on port 53 (the IP set via `dns`, default `1.1.1.1`). All outbound IPv6 is dropped. A `forward` chain carries the same rules, because rootful podman under `userns: full` uses the netavark bridge backend, whose container traffic traverses the forward hook and would otherwise be ungated.

> **Note:** because the upstream resolver is reachable, a process could still perform DNS lookups against it, but it cannot *connect* anywhere the resolver didn't hand back for an allowed domain — egress is gated on `nftables`, not on resolution.

**Example — web browsing profile:**

```json
{
    "description": "Limited Web Access",
    "dns": "1.1.1.1",
    "allow": [
        "*.google.com",
        "github.com",
        "192.168.1.0/24"
    ],
    "ports": [80, 443]
}
```

**Example — full access with custom DNS stamp:**

```json
{
    "description": "Full network access with encrypted DNS",
    "dns": "sdns://AgcAAAAAAAAABzEuMS4xLjEAEmRucy5jbG91ZGZsYXJlLmNvbQovZG5zLXF1ZXJ5",
    "allow": ["*"],
    "ports": ["*"]
}
```

### Applying Profiles

Profiles are applied via the `--cli`, `--fs`, and `--net` flags. Multiple `--fs` flags can be stacked:

```bash
# Combine profiles from different categories
./sbx --cli dev --fs sandbox --net web

# Stack multiple filesystem profiles
./sbx --fs sandbox --fs chrome

# Stack multiple network profiles
./sbx --net web --net internal-db
```

When multiple profiles set the same environment variable, the **last one wins**.

The starting directory is deliberately not part of this: a per-profile `workingDirectory` resolved last-one-wins, so `--fs a --fs b` and `--fs b --fs a` mounted the same tree but started the session in different places. Use `--wd` instead, which says once, explicitly, where the session begins:

```bash
./sbx --fs sandbox --wd /workspace
```

Without `--wd`, bwrap picks the start directory itself: the directory you launched from if that path also exists inside the sandbox, otherwise `$HOME`, otherwise `/`. Since most profiles do not mount the launch directory at its host path, this usually lands in `$HOME` — pass `--wd` whenever the session should begin somewhere specific.

A profile that still carries `workingDirectory` is not honored; sbx warns and names the `--wd` to pass instead.

### Creating Custom Profiles

1. Pick a profile type (`cli`, `fs`, or `net`).
2. Choose a location (see [Profile Locations](#profile-locations) above). Project-local profiles (`.sbx/profiles/`) are useful for team-shared config, while user-level (`~/.config/sbx/profiles/`) ones are for personal preferences.
3. Create a JSON file at `<location>/<type>/<name>.json`.
4. Verify it appears with `./sbx --list-profiles`.

### Profile validation

Every profile a launch uses is checked before anything is built, and every
problem is reported at once:

    ~/.config/sbx/profiles/net/api.json: .ports[1]: expected a port 1-65535 or "*", got "https"

**Errors stop the launch.** Invalid JSON; a field that is not in the schema
for the profile's type (there is no comment syntax — a misspelt field would
otherwise be silently ignored); a wrong type or value (`perm`, `caps`,
`userns`, `docker_api`, `ports`, `host_ports`, `allow`, `passthrough`
names, `env` values); and, in a project profile, `caps`, `userns`,
`docker_api` or `host_ports`. This checks whether the field is *present*,
not what it's set to — a project profile with `"docker_api": false` is
rejected the same as `"docker_api": true`; if you don't want to grant it,
omit the field rather than setting it to `false`. An `allow` entry that
starts with a digit is read as an address, so a hostname like
`1password.com` is rejected rather than silently treated as a malformed
CIDR.

**Warnings are printed and the launch continues:** a `workingDirectory`
field, a `dns` value that is not a bare IPv4 address (1.1.1.1 is used), a
mount whose source does not exist on this host (the mount is skipped), and
a `*.` wildcard in `allow`.

### Previewing a launch

`--dry-run` takes the same flags as a launch and prints what that launch
would do, without doing any of it:

    ./sbx --dry-run --cli claude --fs sandbox --net anthropic

It shows the security settings, every mount (with forked stores marked
*will seed* or *exists*), the environment with which profile won each
variable, the network grants, and a **Writes** section listing every host
location the session would write: forked stores, record working copies and
change archives, read-write binds, podman stores and the session directory.
It runs the dependency check in report-only form, lists project profiles
that would ask for confirmation (without asking), and ends with whether the
launch would proceed. `--dry-run --json` prints the same information as one
JSON document.

Passthrough variables are listed by name, never by value. The preview
describes what is mounted, not what the mounted trees contain.

## Forked and Record Mounts

`forked` and `record` mounts both isolate the sandbox from the host — the original host directory is never modified by either — but they disagree about who owns the data afterward.

**`forked` — sandbox-owned.** The first launch of a given profile/mount from a given directory copies the host source into a persistent store at `~/.local/state/sbx/forked/<profile-name>/<cwd-slug>/<mount_id>/` and binds that store straight into the sandbox. Every later launch of the same profile from the same directory reuses that store directly — the host source is never re-read, so host-side edits made after the first seed simply don't show up, and deletions made inside the sandbox stay deleted. This is what lets `sbx --cli claude` keep the sessions, history, and auth tokens it accumulated last time. `<cwd-slug>` is the launch directory (`$PWD`) with slashes dashed, so each project keeps its own store; `<mount_id>` is the sandbox destination path, also slashes-to-underscores.

To start a profile over from a clean host copy, run `./sbx --cli <name> --reseed` from the same directory. It lists the stores it is about to delete, with their sizes, and asks before removing them; the next launch seeds them from the host again. Other directories' stores for the same profile are unaffected.

Use `--reseed` rather than deleting the store directory by hand: a store is bind-mounted read-write into its session for as long as that session runs, so removing one under a live sandbox destroys the auth tokens and history it is using at that moment. `--reseed` checks for that and refuses.

**`record` — host-owned.** A private working copy is seeded fresh from the host source on *every* launch (in `~/.local/state/sbx/work/<session-id>/`, removed at teardown), so the sandbox always starts from current host state. At teardown, `sbx` diffs the working copy against a manifest taken right after that launch's seed — not against the live host source, so a host-side edit made while the session was running can never be misattributed to the sandbox. Files the session created or modified are archived to `~/.local/state/sbx/changes/<cwd-slug>/<stamp>-<session-id>/<mount_id>/`, and anything the session deleted is listed (one path per line) in a sibling `<mount_id>.deleted` file. Nothing is replayed into the next launch — `record` mounts always start clean from the host.

Use `./sbx --changes [<id>]` to inspect the most recent (or a named) archive for the current directory; it prints the archive path followed by each changed file (`+`) and deleted path (`-`).

A session that is killed outright — `SIGKILL`, the OOM killer, power loss — never reaches teardown, so its working copy and session directory stay on disk. The next launch from that directory clears its own working copy before seeding, so nothing carries over; `./sbx --gc` is what reclaims the rest, and also trims change archives beyond the newest `SBX_KEEP_CHANGES` (default 10) per directory.

Both permissions use `rsync --compare-dest` for the diff when available, falling back to a file-by-file size and timestamp comparison otherwise.

**Example directory structure:**

```
~/.local/state/sbx/
  work/
    20260627-143000-0001/           # a record mount's working copy, live only for the session
      _tmp_recmount/
  changes/
    -home-user-projA/               # record archives, keyed by launch directory
      20260627-143512-20260627-143000-0001/
        _tmp_recmount/
          new.txt
        _tmp_recmount.deleted
  forked/
    claude/
      -home-user-projA/             # store for `--cli claude` launched from ~/projA
        _home_user_.claude/
        _home_user_.claude.json
      -home-user-projB/             # independent store for the same profile in ~/projB
        _home_user_.claude/
```

## GUI Attachment

When using the `--gui` flag, you can attach to the Xpra session using:

```bash
xpra attach :<N>
```
*(Where `<N>` is the display number provided by `sbx`)*

## Virt: Podman Containers and QEMU VMs

Every session gets rootless-podman-friendly plumbing for free: a
generated `storage.conf`/`containers.conf` (overlay driver, cgroupfs
manager — the only manager that can work inside bwrap), `/etc/subuid`
and `/etc/subgid` masked (so podman falls back to single-UID mapping
instead of failing outright — bwrap's `no_new_privs` blocks the setuid
`newuidmap` helper multi-UID mapping needs), and a writable `/var/tmp`.

Three `fs` profiles add device access and persistent storage:

- `--fs podman` — single-UID rootless podman: `/dev/net/tun` plus a
  persistent container store at `~/.local/state/sbx/virt/containers`.
  Composes with everything (real-user identity), works offline with
  cached images. Images that switch UIDs (`USER` directives, service
  images like postgres/nginx that drop privileges) will fail — use
  `podman-full` for those.
- `--fs podman-full` — multi-UID podman with full image fidelity: the
  whole session runs inside an outer user namespace carrying your
  subordinate-UID range (`/etc/subuid`), with its own persistent store
  at `~/.local/state/sbx/virt/containers-full`. Requires `--net`.
- `--fs qemu` — `/dev/kvm` (KVM acceleration) plus a persistent VM image
  directory at `~/.local/state/sbx/virt/images`.

```bash
# Root-only containers, composes with anything (real-user identity)
./sbx --fs sandbox --fs podman --net web --cli claude

# Full image fidelity (postgres/USER images), ns-root session
./sbx --fs sandbox --fs podman-full --net web

# KVM-accelerated VMs, with disk images persisting across sessions
./sbx --fs sandbox --fs qemu --cli claude
```

### Multi-UID containers (podman-full)

`"userns": "full"` sessions run as **namespace-root**: `id` reports
uid 0, host files you own appear owned by root, other users' files
appear as `nobody`, and files created by container-interior UIDs land on
the host owned by your subordinate range. This grants no authority
beyond what `/etc/subuid` already delegates to you — but euid 0 changes
program *behavior*: chromium refuses to run as root without
`--no-sandbox`, Claude Code refuses `--dangerously-skip-permissions` as
root, and installers take we-are-root paths. Don't compose `podman-full`
with the chrome profile or root-averse agent CLIs; use plain `podman`
there. If `unshare` fails with a mapping error, your user has no
`/etc/subuid`/`/etc/subgid` range — add one (e.g.
`sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER`).

The two container stores are intentionally separate (single-UID and
multi-UID ownership layouts are incompatible); an image used in both
modes is pulled twice. `containers-full` contents are owned by
subordinate UIDs on the host — clean up with `podman system reset`
inside a `podman-full` session, not bare `rm -rf`.

Note: userns-full networked launches print harmless pasta warnings
(`Couldn't write to /proc/self/uid_map` / `Couldn't configure user
mappings`) — pasta tries to write a UID map the outer `unshare` already
configured. This is expected noise, not a failure.

**Container egress is filtered the same as any other sandboxed
process** — an allowed destination is reachable, a disallowed one is
network-blocked, whether the destination is given as a CIDR or a
hostname in the net profile's `allow` list. Hostname-based entries
additionally require **`netavark` and `aardvark-dns` installed on the
host**: podman-full routes containers through a dedicated,
DNS-enabled network so container hostname lookups transit the
sandbox's own resolver (and its allow-list) exactly like a
sandbox-process lookup does. Without those packages, hostname lookups
from inside a container simply fail to resolve (blocked, not leaked);
CIDR-based `allow` entries are unaffected either way.

### Docker compatibility

Every session gets a `docker` CLI (a shim that execs `podman`) and a
`DOCKER_HOST` pointing at the session's podman API socket path. The
socket itself is served by `podman system service` only in sessions
whose profile sets `"docker_api": true` (both podman profiles do), so
docker SDKs, `docker compose`, and testcontainers work there; in other
sessions socket clients fail with a clear connection error while the
CLI shim still works. Host-side docker/podman sockets are never exposed
inside a sandbox — containers must run inside the session so its
nftables egress allow-listing applies.

**Known limitations:** `sudo`/setuid elevation inside a container cannot
work under either profile (`no_new_privs` is inherited from bwrap).
Container/VM network egress still flows through the session's `--net`
profile and its nftables allow-listing — there is no way for a container
to bypass it (verified: a container under a restrictive allow-list can
reach an allowed host but is blocked from a disallowed one, same as any
other sandboxed process).

**Known issue:** `--fs podman` sessions started *without* a `--net`
profile currently leak an orphaned process pair (`bwrap` + podman's
`catatonit -P` network-namespace pause process) on teardown — confirmed
via repeated testing, not yet root-caused. Sessions that also use `--net`
tear down cleanly every time. Since a session without `--net` can only
run already-cached images anyway (no image pulls are possible without
network access), this only affects the offline-only workflow; if you hit
it, `pkill catatonit` cleans up the stragglers.

## License

[LICENSE](LICENSE)

## Reaching Host Services

A service running on the host's loopback — a dev server, a database, a local model endpoint — is not reachable from a sandbox by default. Name its port and it appears inside the sandbox at the same address:

```bash
# with internet, per the net profile
./sbx --net anthropic --host-port 8080

# no internet at all: the host service and nothing else
./sbx --host-port 8080 -- claude
```

Or in a net profile:

```json
{ "allow": ["github.com"], "ports": ["*"], "host_ports": [8080, 5432, "5353/udp"] }
```

The second form is the useful one for an agent you want kept off the network but still pointed at your local stack. It needs no `--net` profile: sbx creates a network namespace, forwards exactly the named ports, and loads a default-drop ruleset, so the session reaches those host services and no other destination.

**Addressing.** A named host port answers at `127.0.0.1:<port>` inside the sandbox, the same number it uses on the host, so tools that hardcode `localhost` work unchanged.

**TCP and UDP are granted separately.** A bare `8080` means TCP; write `8080/udp` for UDP, and name the port twice to get both:

```bash
./sbx --host-port 8080/tcp --host-port 8080/udp
```

The two are independent all the way down — forwarding a TCP port does not open its UDP twin. That matters for a port like `53`: a session reaches a host resolver only if it asks for `53/udp` by name, and doing so does not disturb the session's own DNS, which runs on a different loopback address.

**Ports the sandbox binds itself are unaffected**, as long as they are not also forwarded. A sandbox can serve on `127.0.0.1:10000` while reaching the host's service on `127.0.0.1:10001`. The one case to avoid is naming a port the sandbox also wants to bind: the forwarded host service owns that port inside the sandbox, and the sandbox's own `bind()` fails with `EADDRINUSE`.

**Only named ports are forwarded.** This is deliberate, and it is not what the underlying tooling does by default: pasta's `-T auto` forwards *every* port bound on the host, including ports bound after the session starts and ports bound by other users. sbx passes an explicit list instead, so host access is an allow-list like egress rather than a side effect of having networking at all.

**`host_ports` is ignored in project-supplied profiles** and rejected with an error, on the same grounds as `userns`, `caps` and `docker_api`: a cloned repository must not be able to open a path from its own sandbox to a service on the machine running it. Move the profile to `$HOME/.config/sbx/profiles/` to grant it.

## Stacking Network Profiles

`--net` may be given more than once. Composing profiles only ever **adds** reach: no combination takes away access that one of the profiles on its own would have granted.

**Ports stay paired with the hosts they were granted for**, rather than pooling into one list that every destination shares. Stacking a web profile with a database profile:

```json
// web.json                                    // db.json
{ "allow": ["example.com"], "ports": [80,443] } { "allow": ["db.internal"], "ports": [5432] }
```

```bash
./sbx --net web --net db
```

gives `example.com` ports 80 and 443, and `db.internal` port 5432. It does **not** give `example.com` port 5432 — which is what a flat union of all ports would produce, and is more access than either profile asked for.

Pairing is implemented by giving each distinct port list its own nftables set and routing each domain to the set matching its ports. That structure is forced by dnsmasq: a domain can feed exactly one nftset, so a single domain cannot be gated two different ways at once.

That constraint produces the one place a union is unavoidable:

- **A host named by several profiles gets the union of their ports.** If one profile allows `github.com` on 443 and another on 22, it is reachable on both. Each profile authorized it independently, so this is also the correct reading.
- **A wildcard profile (`allow: ["*"]`) widens every named host.** Its ports fold into every other profile's hosts, so adding a narrow profile next to a wildcard one never removes reach the wildcard already granted.

Other fields:

- **`dns` is per profile.** Each profile's hosts are resolved through the resolver that profile named, and every named resolver is permitted on port 53.
- **`allow` CIDR entries** are gated by the ports of the profile that listed them, the same as hostnames. A CIDR is already an address, so it needs no set of its own.
- **`host_ports` accumulate** across every applied profile and the `--host-port` flag, keeping TCP and UDP separate.
