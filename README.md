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

#### Mount Object

Each entry in the `mounts` array has these fields:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | string | Yes | Host path. Supports `$HOME`, `$PWD`, and other environment variables via `envsubst`. |
| `dest` | string | Yes | Destination path inside the sandbox. Also supports variable substitution. |
| `perm` | string | Yes | Mount permission: one of `ro` (read-only bind), `rw` (read-write bind), or `copy` (writable snapshot) |

**Permission modes explained:**

- **`ro`** — Read-only bind mount. The sandbox sees the host directory but cannot modify it.
- **`rw`** — Read-write bind mount. Changes made inside the sandbox are reflected on the host.
- **`copy`** — Writable snapshot. The directory is copied into a tmpfs at session start. Changes inside the sandbox are **not** written back to the host. Instead, on session teardown, only **modified or new files** are compared against the original host source and saved to `~/.local/state/sbx/<session-id>/fs/<mount_id>/`. The original host directory is never modified.

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

When using `copy` mounts (permission `"copy"`), the sandbox isolates changes from the host. At session teardown, `sbx` automatically handles **egress** — it compares the temporary copies inside the sandbox against the original host source and saves only the files that were **new or modified** to `~/.local/state/sbx/<session-id>/fs/<mount_id>/`.

This means:
- The **original host directory is never modified** during the session.
- Only **changed files** are preserved in the state directory.
- The egress uses `rsync --compare-dest` when available (efficient diff-based sync), otherwise falls back to a file-by-file size and timestamp comparison.
- The temporary tmpfs copies are cleaned up after egress.

**Example directory structure:**

```
~/.local/state/sbx/20260627-143000-0001/
  session.json
  fs/
    _home_user_myproject/   # egressed files from copy mount /home/user/myproject
```

## GUI Attachment

When using the `--gui` flag, you can attach to the Xpra session using:

```bash
xpra attach :<N>
```
*(Where `<N>` is the display number provided by `sbx`)*

## License

[LICENSE](LICENSE)
