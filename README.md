# sbx (sandbox-gemini)

`sbx` is a command-line tool designed to manage isolated sandboxed environments. It allows users to spin up, manage, and join sessions with highly configurable environments using modular profiles for CLI, Filesystem, and Networking.

## Features

- **Modular Profiles**: Tailor your sandbox with specific configurations:
  - **CLI Profiles**: Set environment variables, paths, and mounts (e.g., `dev`, `gemini`, `pi`).
  - **Filesystem (FS) Profiles**: Define mounts and filesystem-level configurations (e.g., `chrome`, `sandbox`).
  - **Network (NET) Profiles**: Control network access and connectivity (e.g., `web`, `test_net`).
- **Session Management**: List active sessions and easily join existing ones.
- **GUI Support**: Enable isolated graphical interfaces using `xpra`.
- **Flexible Configuration**: Profiles can be stored locally, in your home directory, or in system-wide paths.

## Usage

To see all available commands and options, run:

```bash
./sbx --help
```

### Common Commands

| Command | Description |
|---------|-------------|
| `--list-profiles` | Show all available CLI, FS, and NET profiles. |
| `--list-sessions` | List all currently active sandbox sessions. |
| `--join <session>` | Attach to an existing sandbox session. |
| `--gui` | Start a session with isolated GUI support via `xpra`. |

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
        {"source": "$HOME/.pi", "dest": "$HOME/.pi", "perm": "copy"}
    ]
}
```

### Filesystem (FS) Profiles (`profiles/fs/<name>.json`)

FS profiles define the sandbox's filesystem layout — which directories are mounted, where the working directory is, and FS-level environment variables.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | string | No | Human-readable label for the profile |
| `workingDirectory` | string | No | Initial working directory inside the sandbox (last one wins when multiple FS profiles are stacked) |
| `mounts` | array of objects | No | Filesystem mount specifications (see below) |
| `env` | object | No | Key-value pairs of environment variables to set |
| `userns` | string | No | `"full"` runs the entire session inside an outer user namespace carrying your full subordinate-UID range (multi-UID podman). Requires `--net`; the session identity becomes namespace-root. See [Multi-UID containers](#multi-uid-containers-podman-full). |
| `docker_api` | boolean | No | `true` starts a podman docker-API socket for the session (see [Docker compatibility](#docker-compatibility)). Honored in CLI profiles too. |

#### Mount Object

Each entry in the `mounts` array has these fields:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | string | Yes | Host path. Supports `$HOME`, `$PWD`, and other environment variables via `envsubst`. |
| `dest` | string | Yes | Destination path inside the sandbox. Also supports variable substitution. |
| `perm` | string | Yes | Mount permission: one of `ro` (read-only bind), `rw` (read-write bind), `dev` (device bind, for files under `/dev`), or `copy` (writable snapshot — see below; behavior differs between fs and cli profiles) |

**Permission modes explained:**

- **`ro`** — Read-only bind mount. The sandbox sees the host directory but cannot modify it.
- **`rw`** — Read-write bind mount. Changes made inside the sandbox are reflected on the host.
- **`copy`** — Writable snapshot. The source is copied into a session-local working directory at start and bound into the sandbox; the original host path is never modified. What happens to the changes depends on the profile type:
  - In an **fs** profile, changes are **ephemeral**. At teardown, new or modified files are saved to `~/.local/state/sbx/<session-id>/fs/<mount_id>/` and nothing is carried into the next session.
  - In a **cli** profile, changes are **persistent**. They are saved to `~/.local/state/sbx/profiles/cli/<profile-name>/<cwd-slug>/<mount_id>/` and replayed on top of the host copy the next time that profile is used *from the same directory*, so a CLI tool's sessions, history, and local config survive across sandboxes. `<cwd-slug>` is the directory you launched `sbx` from, so each project keeps its own persistent state.
- **`dev`** — Device bind mount (`--dev-bind`). Like `rw`, but allows device-node access (a plain `ro`/`rw` bind mounts `nodev`, so opening a device file would fail). Used for things like `/dev/kvm` and `/dev/net/tun`.

**Example:**

```json
{
    "description": "Project workspace",
    "workingDirectory": "/workspace",
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

NET profiles control network access inside the sandbox. When a network profile is applied, the sandbox uses `pasta` for user-mode networking, `dnscrypt-proxy` for DNS resolution (with domain allowlisting), a small DNS sniffer (`sbx-dns-sniffer.py`) that records resolved IPs, and `nftables` for egress filtering keyed on those IPs.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | string | No | Human-readable label for the profile |
| `dns` | string | No | DNS server configuration. Can be an **IP address** (e.g., `"1.1.1.1"`) which is used as a forwarding target, or a **dnscrypt stamp** string for encrypted DNS |
| `allow` | array of strings | No | Allowed destinations. Supports **hostname globs** (e.g., `"*.google.com"`, `"github.com"`) and **CIDR notation** (e.g., `"192.168.1.0/24"`) |
| `ports` | array | No | Allowed ports. Can be a list of port numbers (`[80, 443]`) or the wildcard `["*"]` to allow all ports |

**How filtering works:**

Egress is enforced at the **IP layer by `nftables`**, not just at DNS resolution. The output chain defaults to `drop`; a connection is only permitted if its destination IP is explicitly allowed. This closes the bypass where a process connects straight to a raw IP (or a public DNS provider) and skips the filtered resolver entirely.

1. **Domain allowlisting** — Hostname entries in `allow` (those matching `^[a-zA-Z*]`) are written to a file consumed by `dnscrypt-proxy`, which uses a catch-all `*.*` blocklist exempted by the allow list. Only DNS queries for matching domains resolve; all others are refused.
2. **Dynamic IP allowlisting** — The DNS sniffer sits on `127.0.0.1:53`, forwards queries to `dnscrypt-proxy`, and adds every IP it sees in an allowed-domain answer to the `nftables` set `allowed4`. `nftables` then permits connections to exactly those IPs (subject to the port filter). An IP the resolver never returned is dropped.
3. **CIDR allowlisting** — IP/CIDR entries in `allow` (those matching `^[0-9]`) become `nftables` rules that accept outbound traffic to those address ranges (any port).
4. **Port filtering** — `nftables` rules restrict the allowed TCP/UDP destination ports for resolved hosts. If only hostnames are listed without explicit ports, ports 80 and 443 are allowed by default.
5. **Default policy** — The egress chain default is `drop`. The only fixed exceptions are loopback, established/related flows, and the single upstream resolver (Cloudflare DoH on `1.1.1.1`/`1.0.0.1:443`, or the plain-DNS IP set via `dns`). All outbound IPv6 is dropped.

> **Note:** because the upstream resolver is reachable, a process could still perform DNS lookups against it, but it cannot *connect* anywhere the resolver didn't hand back for an allowed domain — egress is gated on `nftables`, not on resolution. A custom `dns` stamp pointing at a non-Cloudflare resolver must add that resolver's IP as a CIDR in `allow`.

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
```

When multiple profiles set the same environment variable or `workingDirectory`, the **last one wins**.

### Creating Custom Profiles

1. Pick a profile type (`cli`, `fs`, or `net`).
2. Choose a location (see [Profile Locations](#profile-locations) above). Project-local profiles (`.sbx/profiles/`) are useful for team-shared config, while user-level (`~/.config/sbx/profiles/`) ones are for personal preferences.
3. Create a JSON file at `<location>/<type>/<name>.json`.
4. Verify it appears with `./sbx --list-profiles`.

## Copy Mount Egress

With `copy` mounts, the sandbox isolates changes from the host. At teardown, `sbx` compares the working copy against the **original host source** and saves only the files that are **new or modified**. Where they are saved depends on the profile the mount was declared in.

**fs profiles — ephemeral.** Changes go to `~/.local/state/sbx/<session-id>/fs/<mount_id>/` and stay there. Each session starts from the host's state.

**cli profiles — persistent.** Changes go to `~/.local/state/sbx/profiles/cli/<profile-name>/<cwd-slug>/<mount_id>/`, and the next session using that profile *from the same directory* overlays this store on top of a fresh copy of the host source. This is what lets `sbx --cli claude` resume with the sessions and history it accumulated last time. `<cwd-slug>` is the launch directory (`$PWD`) with slashes dashed, so different projects get independent stores.

In both cases:
- The **original host directory is never modified**.
- Only **changed files** are written; the comparison baseline is always the host source, never the store.
- The egress uses `rsync --compare-dest` when available, otherwise a file-by-file size and timestamp comparison.
- The session's temporary working copies are cleaned up afterwards.

**Persistent store behavior.** Two consequences follow from the overlay model and are intentional:

- **Deletions do not persist.** A file deleted inside the sandbox is restored from the host on the next launch — the host directory is the floor. If you want it gone, delete it from the store.
- **Written files shadow the host.** Once a session writes a given file, the store's version wins on every later launch, so subsequent host-side edits to *that file* are not seen. Host changes to files the sandbox has never touched still come through normally. To start over, delete this directory's store (`~/.local/state/sbx/profiles/cli/<profile-name>/<cwd-slug>/`); other directories' stores for the same profile are unaffected.

The store key is the profile name plus the launch directory: `sbx --cli claude` resumes only when re-run from the same directory, and two directories keep independent stores. Concurrent sessions from the same directory are allowed and are not locked — write-back is per file, and the last session to tear down wins for any file it changed. This matches how the CLI tools already behave across concurrent sessions on the host.

**Example directory structure:**

```
~/.local/state/sbx/
  20260627-143000-0001/
    session.json
    fs/
      _home_user_myproject/    # ephemeral egress from an fs profile copy mount
  profiles/
    cli/
      claude/
        -home-user-projA/          # store for `--cli claude` launched from ~/projA
          _home_user_.claude/
          _home_user_.claude.json
        -home-user-projB/          # independent store for the same profile in ~/projB
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
