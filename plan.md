This document serves as the final technical specification for the sandbox orchestrator. It integrates the core goals, the finalized technical stack, and the mechanical requirements needed for an implementation phase.

---

# Specification: Portable Unprivileged Sandbox Orchestrator

## 1. Project Overview

* **Goal:** Create a lightweight, profile-based sandbox to restrict LLM coding assistants' access to the filesystem and network.
* **Design Philosophy:**
1. **Security First:** Ensure restricted environments are strictly enforced.
2. **Elegance & Simplicity:** Use a Bash script to compose existing tools; avoid "over-engineering."
3. **No Bespoke Code:** Rely on standard open-source tools; custom logic is restricted to the orchestrator script and dynamic configuration generation.


* **Threat Model:** Protection against unintentional filesystem modifications, credential theft, or unauthorized network access by automated agents. Not intended to stop sophisticated 0-day escapes.

## 2. Technical Component Stack

The orchestrator composes the following tools to provide an unprivileged, rootless environment:

| Component | Tool | Purpose |
| --- | --- | --- |
| **Sandbox Engine** | `bubblewrap` (`bwrap`) | Creates unprivileged user, mount, and network namespaces. |
| **Session Manager** | `abduco` | Manages session persistence and terminal attachment/detachment. |
| **Network Stack** | `pasta` | Provides L2/L3 user-mode networking without NAT or root privileges. |
| **DNS Filter** | `dnscrypt-proxy` | Enforces wildcard hostname restrictions (e.g., `*.google.com`). |
| **Logic/Parsing** | `bash` & `jq` | Orchestrates the lifecycle and parses JSON profile configurations. |

## 3. Functional Specifications

### 3.1 Profile Resolution

Profiles are resolved based on the following priority (first match wins):

1. **Project:** `./.sbx/profiles/` (relative to current working directory).
2. **User:** `$HOME/.config/sbx/profiles/`.
3. **Global:** `$(dirname $0)/profiles/` (location of the orchestrator script).

### 3.2 Filesystem & "Copy-Out" Persistence

The sandbox supports three mount permissions: `ro` (read-only), `rw` (read-write), and `copy`.

* **The `copy` Logic:**
* **Ingress:** At startup, files from the `source` are copied into a `tmpfs` at the `dest`.
* **Egress:** Upon session termination, the script performs a diff. Any file in the `tmpfs` with a later **Last Write Time** or a different **File Size** than the original source is copied to `~/.local/state/sbx/<session_id>/fs/<path>`.


* **Coordination:** `abduco` sockets are bind-mounted into the sandbox to allow external processes to attach via the `--join` flag.

### 3.3 Networking & Wildcard DNS

* **Stack:** `pasta` initializes the namespace networking.
* **DNS Interception:** The script dynamically generates an `allowed-names.txt` blocklist for `dnscrypt-proxy` based on the network profile.
* **Restriction:** Only traffic to IPs/CIDRs or hostnames matching the profile (including wildcards like `*.github.com`) is permitted.

## 4. Implementation Mechanics

### 4.1 State Management

All active session data is stored in `~/.local/state/sbx/`.

* **Directory Structure:** Each session gets a folder named by its ID containing:
* `session.json`: Tracks the primary `bwrap` PID, `abduco` socket path, and used profiles.
* `fs/`: The persistence layer for "copy" mounts.


* **Listing:** `--list-sessions` reads these directories to display active sandboxes associated with the current working directory.

### 4.2 Execution Flow

1. **Validation:** Verify all dependencies (`bwrap`, `abduco`, `pasta`, `dnscrypt-proxy`, `jq`) are in `$PATH`.
2. **Profile Merging:** Resolve requested profiles. If multiple profiles conflict on a path, the **last profile specified** on the command line takes precedence.
3. **Pre-flight:** Generate dynamic DNS blocklists and temporary mount directories.
4. **Launch:** Execute `pasta` to bridge the namespace, then launch `bwrap` wrapping an `abduco` session.
5. **Teardown:** On exit, the script kills all remaining processes in the namespace, performs the "copy-out" sync, and clears temporary state files.

### 4.3 Error Handling

* **JSON Errors:** Syntax or schema errors in profiles must cause the script to exit immediately, reporting the filename and line number of the error.
* **Dependency Failures:** If a tool like `pasta` fails to initialize, the script must report the error and prevent the sandbox from starting in an insecure (unfiltered) state.

## 5. Command-Line Interface

* `--list-profiles`: Show available profiles grouped by source (Project/User/Global).
* `--list-sessions`: Show active sessions started from the current directory.
* `--join <session>`: Attach to an existing `abduco` session.
* `--fs <profile>`: Apply a filesystem profile (can be used multiple times).
* `--net <profile>`: Apply a network profile.
* `--cli <profile>`: Apply a CLI/environment profile.

---

## 6. Profile Schema Examples

### Filesystem JSON

```json
{
    "description": "Project-specific sources",
    "mounts": [
        { "source": "./src", "dest": "/home/user/src", "perm": "copy" },
        { "source": "/usr/include", "dest": "/usr/include", "perm": "ro" }
    ]
}

```

### Network JSON

```json
{
    "description": "Limited Web Access",
    "allow": [
        "*.google.com",
        "github.com",
        "192.168.1.0/24"
    ],
    "ports": [80, 443]
}

```

### CLI JSON

```json
{
    "description": "Standard Development Environment",
    "env": {
        "EDITOR": "vim",
        "PATH": "/usr/local/bin:/usr/bin"
    },
    "workingDirectory": "/home/user/src",
    "mounts": [
        { "source": "./src", "dest": "/home/user/src", "perm": "copy" }
    ]
}
```
