# Setup UX Phase 1: Dependencies — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** sbx reports every missing dependency and broken host setting before it builds anything, with the install command for the user's distro, and `sbx --doctor` reports all of it on demand.

**Architecture:** A new side-effect-free library, `lib/deps.sh`, holds one dependency table plus distro detection, a real user-namespace probe with cause diagnosis, and a subordinate-ID check. `sbx` replaces its `require_tools` function with calls into the library — the core group before the project-profile confirmation, the optional groups after the feature-field scan — and gains `--doctor [--json]`.

**Tech Stack:** bash, bats 1.14, shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-16-setup-ux-design.md` (Phase 1 section). Phases 2–5 get their own plans, written when each starts.

## Global Constraints

- `shellcheck -S error sbx lib/copy-mounts.sh lib/deps.sh` must be silent. Pre-existing sub-error warnings in `sbx` are not a gate.
- sbx prints install commands; it never runs a package manager, `sysctl`, or anything as root.
- `lib/deps.sh` defines functions and one table only — no side effects at source time, no dependency on `sbx` globals. It uses only bash builtins plus `awk`, because it is what reports that other tools are missing.
- Distro families: `arch`, `debian`, `fedora`; anything else is `unknown` and gets hints for all three.
- Test hooks (environment variables, read only by `lib/deps.sh`): `SBX_OS_RELEASE` (default `/etc/os-release`), `SBX_PROC_SYS` (default `/proc/sys`), `SBX_SUBUID` (default `/etc/subuid`), `SBX_SUBGID` (default `/etc/subgid`). They affect only diagnostics, never the probe itself.
- bats tests: `! cmd` is only an assertion on a test's last line; use `if …; then return 1; fi` elsewhere. Tests that run `sbx` use a short `mktemp -d /tmp/sbxh.XXXXXX` root and clean it in `teardown`.
- Naming: library functions are prefixed `sbx_deps_`, matching `sbx_copy_` in `lib/copy-mounts.sh`. (The spec's `deps_require` is `sbx_deps_require`.)

## File Structure

- Create `lib/deps.sh` — dependency table, family detection, install hints, missing-tool detection, userns probe and diagnosis, subordinate-ID check, `sbx_deps_require`, `sbx_deps_doctor`.
- Create `tests/deps.bats` — unit tests of `lib/deps.sh`, no sandbox launch.
- Create `tests/preflight.bats` — runs `sbx` with stubbed `PATH` and fixtures; asserts it stops before creating a session.
- Modify `sbx` — source the library, remove `require_tools` (`sbx:661-693`), add the two preflight calls, remove the late xpra check (`sbx:1808-1811`), add `--doctor` to argument parsing and `usage`.
- Modify `README.md` — `--doctor` in the command table, and a short "Checking your setup" section.

---

### Task 1: Dependency table, distro family, install hints, missing tools

**Files:**
- Create: `lib/deps.sh`
- Test: `tests/deps.bats`

**Interfaces:**
- Produces:
  - `SBX_DEPS` — array of rows `"tool group arch-pkg debian-pkg fedora-pkg"`
  - `sbx_deps_family` → prints `arch|debian|fedora|unknown`
  - `sbx_deps_tools <group>...` → prints tool names in those groups, one per line, table order
  - `sbx_deps_missing <group>...` → prints tools in those groups not found by `command -v`
  - `sbx_deps_packages <family> <tool>...` → prints unique package names, first-seen order
  - `sbx_deps_install_hint <family> <tool>...` → known family: one line `sudo pacman -S a b`; `unknown`: three lines prefixed `arch:`, `debian:`, `fedora:`

- [ ] **Step 1: Write the failing tests**

Create `tests/deps.bats`:

```bash
#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/deps.sh"
    FIX="$BATS_TEST_TMPDIR/fix"
    mkdir -p "$FIX"
}

os_release() {   # <file> <ID> [<ID_LIKE>]
    printf 'NAME="Test"\nID=%s\n' "$2" > "$1"
    [[ -n "${3:-}" ]] && printf 'ID_LIKE="%s"\n' "$3" >> "$1"
    return 0
}

@test "family: manjaro maps to arch" {
    os_release "$FIX/os" manjaro arch
    SBX_OS_RELEASE="$FIX/os" run sbx_deps_family
    [ "$output" = "arch" ]
}

@test "family: ubuntu maps to debian through ID_LIKE" {
    os_release "$FIX/os" ubuntu debian
    SBX_OS_RELEASE="$FIX/os" run sbx_deps_family
    [ "$output" = "debian" ]
}

@test "family: rocky maps to fedora through ID_LIKE" {
    os_release "$FIX/os" rocky "rhel centos fedora"
    SBX_OS_RELEASE="$FIX/os" run sbx_deps_family
    [ "$output" = "fedora" ]
}

@test "family: a quoted ID is unquoted" {
    printf 'ID="fedora"\n' > "$FIX/os"
    SBX_OS_RELEASE="$FIX/os" run sbx_deps_family
    [ "$output" = "fedora" ]
}

@test "family: last line without a trailing newline is still read" {
    printf 'ID=arch' > "$FIX/os"
    SBX_OS_RELEASE="$FIX/os" run sbx_deps_family
    [ "$output" = "arch" ]
}

@test "family: unrecognised or absent os-release is unknown" {
    os_release "$FIX/os" gentoo
    SBX_OS_RELEASE="$FIX/os" run sbx_deps_family
    [ "$output" = "unknown" ]
    SBX_OS_RELEASE="$FIX/nope" run sbx_deps_family
    [ "$output" = "unknown" ]
}

@test "tools lists a group in table order" {
    run sbx_deps_tools net
    [ "$output" = "$(printf 'pasta\nnft\ndnsmasq')" ]
}

@test "missing reports only absent tools of the requested groups" {
    mkdir -p "$FIX/bin"
    ln -s "$(command -v nft)" "$FIX/bin/nft"
    PATH="$FIX/bin" run sbx_deps_missing net
    [ "$output" = "$(printf 'pasta\ndnsmasq')" ]
}

@test "packages dedupes tools that share a package" {
    run sbx_deps_packages arch setpriv flock realpath
    [ "$output" = "$(printf 'util-linux\ncoreutils')" ]
}

@test "packages uses the family's own names" {
    run sbx_deps_packages debian envsubst newuidmap
    [ "$output" = "$(printf 'gettext-base\nuidmap')" ]
}

@test "install hint for a known family is one command" {
    run sbx_deps_install_hint fedora pasta ip
    [ "$output" = "sudo dnf install passt iproute" ]
}

@test "install hint for an unknown family covers all three" {
    run sbx_deps_install_hint unknown bwrap
    [ "${lines[0]}" = "arch:   sudo pacman -S bubblewrap" ]
    [ "${lines[1]}" = "debian: sudo apt install bubblewrap" ]
    [ "${lines[2]}" = "fedora: sudo dnf install bubblewrap" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/deps.bats`
Expected: every test fails — `lib/deps.sh: No such file or directory`.

- [ ] **Step 3: Write the implementation**

Create `lib/deps.sh`:

```bash
#!/bin/bash
# Dependency table and host checks, shared by sbx's launch preflight and
# `sbx --doctor`.
#
# Sourced by sbx and directly by tests/. Defines functions and one table
# only — no side effects at source time, no dependency on sbx globals.
# Uses bash builtins plus awk and nothing else: this file is what reports
# that the rest of the toolchain is missing.

# tool       group   arch        debian        fedora
SBX_DEPS=(
    "bwrap      core    bubblewrap  bubblewrap    bubblewrap"
    "tmux       core    tmux        tmux          tmux"
    "jq         core    jq          jq            jq"
    "envsubst   core    gettext     gettext-base  gettext-envsubst"
    "setpriv    core    util-linux  util-linux    util-linux-core"
    "flock      core    util-linux  util-linux    util-linux-core"
    "realpath   core    coreutils   coreutils     coreutils"
    "sha256sum  core    coreutils   coreutils     coreutils"
    "ip         core    iproute2    iproute2      iproute"
    "pasta      net     passt       passt         passt"
    "nft        net     nftables    nftables      nftables"
    "dnsmasq    net     dnsmasq     dnsmasq       dnsmasq"
    "xpra       gui     xpra        xpra          xpra"
    "podman     podman  podman      podman        podman"
    "newuidmap  podman  shadow      uidmap        shadow-utils"
    "unshare    podman  util-linux  util-linux    util-linux-core"
)

# Map /etc/os-release to a package family. ID is tried before ID_LIKE, so
# a derivative that names itself (manjaro) and its parent (arch) resolves
# the same either way.
sbx_deps_family() {
    local file="${SBX_OS_RELEASE:-/etc/os-release}" key val id="" like="" word
    if [[ -r "$file" ]]; then
        while IFS='=' read -r key val || [[ -n "$key" ]]; do
            val="${val#[\"\']}"
            val="${val%[\"\']}"
            case "$key" in
                ID)      id="$val" ;;
                ID_LIKE) like="$val" ;;
            esac
        done < "$file"
    fi
    # shellcheck disable=SC2086  # ID_LIKE is a space-separated list
    for word in $id $like; do
        case "$word" in
            arch|manjaro|endeavouros|garuda|artix)           echo arch;   return 0 ;;
            debian|ubuntu|linuxmint|pop|raspbian|kali)       echo debian; return 0 ;;
            fedora|rhel|centos|rocky|almalinux|ol)           echo fedora; return 0 ;;
        esac
    done
    echo unknown
}

sbx_deps_tools() {
    local row tool group rest g
    for row in "${SBX_DEPS[@]}"; do
        read -r tool group rest <<< "$row"
        for g in "$@"; do
            [[ "$group" == "$g" ]] && echo "$tool"
        done
    done
    return 0
}

sbx_deps_missing() {
    local tool
    while IFS= read -r tool; do
        command -v "$tool" >/dev/null 2>&1 || echo "$tool"
    done < <(sbx_deps_tools "$@")
    return 0
}

sbx_deps_packages() {
    local family="$1"; shift
    local want row tool group arch debian fedora pkg seen=" "
    for want in "$@"; do
        for row in "${SBX_DEPS[@]}"; do
            read -r tool group arch debian fedora <<< "$row"
            [[ "$tool" == "$want" ]] || continue
            case "$family" in
                arch)   pkg="$arch" ;;
                debian) pkg="$debian" ;;
                fedora) pkg="$fedora" ;;
                *)      return 1 ;;
            esac
            if [[ "$seen" != *" $pkg "* ]]; then
                echo "$pkg"
                seen+="$pkg "
            fi
        done
    done
    return 0
}

sbx_deps_package_manager() {
    case "$1" in
        arch)   echo "sudo pacman -S" ;;
        debian) echo "sudo apt install" ;;
        fedora) echo "sudo dnf install" ;;
    esac
}

sbx_deps_install_hint() {
    local family="$1"; shift
    local f
    local -a pkgs
    case "$family" in
        arch|debian|fedora)
            mapfile -t pkgs < <(sbx_deps_packages "$family" "$@")
            echo "$(sbx_deps_package_manager "$family") ${pkgs[*]}"
            ;;
        *)
            for f in arch debian fedora; do
                mapfile -t pkgs < <(sbx_deps_packages "$f" "$@")
                printf '%-7s %s %s\n' "$f:" "$(sbx_deps_package_manager "$f")" "${pkgs[*]}"
            done
            ;;
    esac
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/deps.bats`
Expected: 12 tests, 0 failures.

- [ ] **Step 5: Shellcheck**

Run: `shellcheck -S error lib/deps.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/deps.sh tests/deps.bats
git commit -m "Add a dependency table with per-distro install hints"
```

---

### Task 2: User-namespace probe and subordinate-ID check

**Files:**
- Modify: `lib/deps.sh` (append)
- Test: `tests/deps.bats` (append)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `sbx_deps_userns_check` → returns 0 if `bwrap --unshare-user --ro-bind / / true` succeeds; otherwise prints an `Error:` line plus cause and fix to **stdout** and returns 1
  - `sbx_deps_userns_explain <bwrap-stderr>` → prints `Cause:` / `Fix:` lines to stdout
  - `sbx_deps_subids_ok` → returns 0 if the current user (name or numeric UID) has an entry in both subuid and subgid files

The probe is the real operation, not a sysctl read: distributions restrict user namespaces in several independent ways, and only running bwrap sees all of them. Sysctls are read afterwards only to explain a failure, in order of how often each is the cause.

- [ ] **Step 1: Write the failing tests**

Append to `tests/deps.bats`:

```bash
fake_bwrap() {   # <exit-status> [<stderr>]
    mkdir -p "$FIX/bin"
    printf '#!/bin/sh\necho "%s" >&2\nexit %s\n' "${2:-}" "$1" > "$FIX/bin/bwrap"
    chmod +x "$FIX/bin/bwrap"
}

fake_sysctl() {   # <relative path under /proc/sys> <value>
    mkdir -p "$FIX/sys/$(dirname "$1")"
    echo "$2" > "$FIX/sys/$1"
}

@test "userns check passes when bwrap succeeds" {
    fake_bwrap 0
    PATH="$FIX/bin:$PATH" run sbx_deps_userns_check
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userns check blames AppArmor when Ubuntu's restriction is on" {
    fake_bwrap 1 "bwrap: setting up uid map: Permission denied"
    fake_sysctl kernel/apparmor_restrict_unprivileged_userns 1
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"AppArmor"* ]]
    [[ "$output" == *"userns,"* ]]
    [[ "$output" == *"apparmor_parser -r"* ]]
}

@test "userns check blames unprivileged_userns_clone when it is 0" {
    fake_bwrap 1 "bwrap: No permissions to create new namespace"
    fake_sysctl kernel/apparmor_restrict_unprivileged_userns 0
    fake_sysctl kernel/unprivileged_userns_clone 0
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"kernel.unprivileged_userns_clone=1"* ]]
}

@test "userns check blames max_user_namespaces when it is 0" {
    fake_bwrap 1 "bwrap: No space left on device"
    fake_sysctl user/max_user_namespaces 0
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"user.max_user_namespaces"* ]]
}

@test "userns check with no known cause shows bwrap's own message" {
    fake_bwrap 1 "bwrap: something unexpected"
    mkdir -p "$FIX/sys"
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"bwrap: something unexpected"* ]]
}

@test "subids ok when the user has both ranges" {
    printf '%s:100000:65536\n' "$(id -un)" > "$FIX/subuid"
    printf '%s:100000:65536\n' "$(id -u)"  > "$FIX/subgid"
    SBX_SUBUID="$FIX/subuid" SBX_SUBGID="$FIX/subgid" run sbx_deps_subids_ok
    [ "$status" -eq 0 ]
}

@test "subids not ok when one file lacks the user" {
    printf '%s:100000:65536\n' "$(id -un)" > "$FIX/subuid"
    printf 'someoneelse:100000:65536\n'   > "$FIX/subgid"
    SBX_SUBUID="$FIX/subuid" SBX_SUBGID="$FIX/subgid" run sbx_deps_subids_ok
    [ "$status" -eq 1 ]
}

@test "subids not ok when a name merely starts with the user's" {
    printf '%sx:100000:65536\n' "$(id -un)" > "$FIX/subuid"
    cp "$FIX/subuid" "$FIX/subgid"
    SBX_SUBUID="$FIX/subuid" SBX_SUBGID="$FIX/subgid" run sbx_deps_subids_ok
    [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/deps.bats`
Expected: the 8 new tests fail with `sbx_deps_userns_check: command not found` (or `sbx_deps_subids_ok`); Task 1's 12 still pass.

- [ ] **Step 3: Write the implementation**

Append to `lib/deps.sh`:

```bash
# Read one sysctl value, or nothing if the knob does not exist on this
# kernel (unprivileged_userns_clone is a Debian/Arch patch, the AppArmor
# knob is Ubuntu's).
sbx_deps_sysctl() {
    local v=""
    read -r v < "${SBX_PROC_SYS:-/proc/sys}/$1" 2>/dev/null || true
    echo "$v"
}

sbx_deps_userns_explain() {
    local bwrap_err="$1" bw
    if [[ "$(sbx_deps_sysctl kernel/apparmor_restrict_unprivileged_userns)" == "1" ]]; then
        bw=$(command -v bwrap || echo /usr/bin/bwrap)
        cat <<EOF
Cause: AppArmor restricts unprivileged user namespaces
  (kernel.apparmor_restrict_unprivileged_userns = 1, the Ubuntu 24.04+ default).
Fix: allow bwrap to create them. As root, create /etc/apparmor.d/sbx-bwrap:

  abi <abi/4.0>,
  include <tunables/global>

  profile sbx-bwrap $bw flags=(unconfined) {
    userns,
  }

then load it:  sudo apparmor_parser -r /etc/apparmor.d/sbx-bwrap
EOF
        return 0
    fi
    if [[ "$(sbx_deps_sysctl kernel/unprivileged_userns_clone)" == "0" ]]; then
        cat <<EOF
Cause: the kernel disallows unprivileged user namespaces
  (kernel.unprivileged_userns_clone = 0).
Fix:  sudo sysctl -w kernel.unprivileged_userns_clone=1
  To keep it across reboots:
  echo 'kernel.unprivileged_userns_clone = 1' | sudo tee /etc/sysctl.d/90-sbx-userns.conf
EOF
        return 0
    fi
    if [[ "$(sbx_deps_sysctl user/max_user_namespaces)" == "0" ]]; then
        cat <<EOF
Cause: user namespaces are capped at zero (user.max_user_namespaces = 0).
Fix:  sudo sysctl -w user.max_user_namespaces=10000
  To keep it across reboots:
  echo 'user.max_user_namespaces = 10000' | sudo tee /etc/sysctl.d/90-sbx-userns.conf
EOF
        return 0
    fi
    echo "Cause: not one sbx recognises. bwrap reported:"
    echo "  $bwrap_err"
}

sbx_deps_userns_check() {
    local err
    if err=$(bwrap --unshare-user --ro-bind / / true 2>&1 >/dev/null); then
        return 0
    fi
    echo "Error: bwrap cannot create an unprivileged user namespace, which every sbx session needs."
    sbx_deps_userns_explain "$err"
    return 1
}

# userns: full maps the user's subordinate range through newuidmap, which
# refuses outright without an entry. Entries may name the user or the UID.
sbx_deps_subids_ok() {
    local user uid f
    user=$(id -un)
    uid=$(id -u)
    for f in "${SBX_SUBUID:-/etc/subuid}" "${SBX_SUBGID:-/etc/subgid}"; do
        awk -F: -v u="$user" -v i="$uid" '$1 == u || $1 == i { found = 1 } END { exit !found }' "$f" 2>/dev/null \
            || return 1
    done
    return 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/deps.bats`
Expected: 20 tests, 0 failures.

- [ ] **Step 5: Probe the real host**

Run: `bash -c 'source lib/deps.sh; sbx_deps_userns_check && echo userns-ok; sbx_deps_subids_ok && echo subids-ok || echo no-subids'`
Expected: `userns-ok`, then `subids-ok` or `no-subids` matching `grep "^$(id -un):" /etc/subuid /etc/subgid`.

- [ ] **Step 6: Shellcheck and commit**

Run: `shellcheck -S error lib/deps.sh` — expected no output.

```bash
git add lib/deps.sh tests/deps.bats
git commit -m "Probe user namespaces for real and explain why they fail"
```

---

### Task 3: Launch preflight in `sbx`

**Files:**
- Modify: `lib/deps.sh` (append `sbx_deps_require`)
- Modify: `sbx:9-12` (source), `sbx:661-693` (remove `require_tools`, add core preflight before the confirmation loop at `sbx:656`), after `sbx:747` (optional-group preflight), `sbx:1808-1811` (remove late xpra check)
- Test: `tests/deps.bats` (append), create `tests/preflight.bats`

**Interfaces:**
- Consumes: `sbx_deps_family`, `sbx_deps_missing`, `sbx_deps_install_hint` (Task 1); `sbx_deps_userns_check`, `sbx_deps_subids_ok` (Task 2).
- Produces: `sbx_deps_require <group>...` → returns 0, or prints an `Error:` block to **stderr** and returns 1. Runs the userns check only when `core` is among the groups and no core tool is missing.

- [ ] **Step 1: Write the failing unit tests**

Append to `tests/deps.bats`:

```bash
@test "require passes silently when nothing is missing" {
    fake_bwrap 0
    PATH="$FIX/bin:$PATH" run sbx_deps_require core net
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "require names missing tools and the distro's command" {
    os_release "$FIX/os" ubuntu debian
    mkdir -p "$FIX/bin"
    PATH="$FIX/bin" SBX_OS_RELEASE="$FIX/os" run sbx_deps_require net
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" == "Error: sbx requires pasta nft dnsmasq, which are not on PATH." ]]
    [[ "$output" == *"sudo apt install passt nftables dnsmasq"* ]]
    if [[ "$output" == *pacman* ]]; then return 1; fi
}

@test "require skips the userns probe for optional groups" {
    fake_bwrap 1 "should not run"
    PATH="$FIX/bin:$PATH" run sbx_deps_require net
    [ "$status" -eq 0 ]
}

@test "require runs the userns probe with core" {
    fake_bwrap 1 "bwrap: nope"
    mkdir -p "$FIX/sys"
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" run sbx_deps_require core
    [ "$status" -eq 1 ]
    [[ "$output" == *"unprivileged user namespace"* ]]
}
```

Note: "require passes silently" and "require skips the userns probe" assume every tool in `core` and `net` is installed on the test host, which the existing e2e suites already require.

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/deps.bats`
Expected: 4 new failures, `sbx_deps_require: command not found`.

- [ ] **Step 3: Implement `sbx_deps_require`**

Append to `lib/deps.sh`:

```bash
sbx_deps_require() {
    local -a missing
    local line
    mapfile -t missing < <(sbx_deps_missing "$@")
    if [[ ${#missing[@]} -gt 0 ]]; then
        {
            if [[ ${#missing[@]} -eq 1 ]]; then
                echo "Error: sbx requires ${missing[0]}, which is not on PATH."
            else
                echo "Error: sbx requires ${missing[*]}, which are not on PATH."
            fi
            echo "  Install with:"
            while IFS= read -r line; do
                echo "    $line"
            done < <(sbx_deps_install_hint "$(sbx_deps_family)" "${missing[@]}")
        } >&2
        return 1
    fi
    if [[ " $* " == *" core "* ]]; then
        sbx_deps_userns_check >&2 || return 1
    fi
    return 0
}
```

- [ ] **Step 4: Run the unit tests to verify they pass**

Run: `bats tests/deps.bats`
Expected: 24 tests, 0 failures.

- [ ] **Step 5: Write the failing integration tests**

Create `tests/preflight.bats`:

```bash
#!/usr/bin/env bats

# sbx must stop on a missing dependency before it builds anything. These
# tests remove one tool at a time from PATH and check both the message and
# that no session directory was created.

setup_file() {
    # A copy of /usr/bin as symlinks, so a test can delete exactly the tools
    # it wants absent while everything else sbx calls (cat, grep, git...)
    # still resolves. Built once per file; each test copies it.
    BASE_BIN="$BATS_FILE_TMPDIR/bin"
    mkdir -p "$BASE_BIN"
    local f
    for f in /usr/bin/* /usr/local/bin/*; do
        [[ -x "$f" && ! -e "$BASE_BIN/${f##*/}" ]] && ln -s "$f" "$BASE_BIN/${f##*/}"
    done
    export BASE_BIN
}

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    mkdir -p "$HOME" "$ROOT/bin" "$ROOT/p"
    cp -a "$BASE_BIN/." "$ROOT/bin/"
    printf 'ID=manjaro\nID_LIKE=arch\n' > "$ROOT/arch"
    printf 'ID=ubuntu\nID_LIKE=debian\n' > "$ROOT/ubuntu"
}

teardown() {
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]]; then
        rm -rf "$ROOT"
    fi
}

run_sbx() {   # <os-release> <args...>
    local os="$1"; shift
    run env PATH="$ROOT/bin" SBX_OS_RELEASE="$ROOT/$os" \
        bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$ROOT/p" "$SBX" "$@"
}

no_session_built() {
    if compgen -G "$HOME/.local/state/sbx/sessions/*" >/dev/null; then
        echo "a session directory was created" >&2
        return 1
    fi
}

@test "missing pasta with --net stops with the arch command" {
    rm "$ROOT/bin/pasta"
    run_sbx arch --net web -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"sudo pacman -S passt"* ]]
    no_session_built
}

@test "missing pasta with --net stops with the debian command" {
    rm "$ROOT/bin/pasta"
    run_sbx ubuntu --net web -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"sudo apt install passt"* ]]
    no_session_built
}

@test "missing pasta without --net is not reported" {
    rm "$ROOT/bin/pasta" "$ROOT/bin/bwrap"
    run_sbx arch -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"bubblewrap"* ]]
    if [[ "$output" == *passt* ]]; then return 1; fi
    no_session_built
}

@test "missing xpra with --gui stops before a display is built" {
    rm "$ROOT/bin/xpra"
    run_sbx arch --gui -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"sudo pacman -S xpra"* ]]
    no_session_built
}

@test "a failing userns probe stops the launch with a diagnosis" {
    rm "$ROOT/bin/bwrap"
    printf '#!/bin/sh\necho "bwrap: setting up uid map: Permission denied" >&2\nexit 1\n' > "$ROOT/bin/bwrap"
    chmod +x "$ROOT/bin/bwrap"
    mkdir -p "$ROOT/sys/kernel"
    echo 1 > "$ROOT/sys/kernel/apparmor_restrict_unprivileged_userns"
    run env PATH="$ROOT/bin" SBX_OS_RELEASE="$ROOT/ubuntu" SBX_PROC_SYS="$ROOT/sys" \
        bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$ROOT/p" "$SBX" -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"AppArmor"* ]]
    no_session_built
}

@test "userns: full without a subordinate range stops with the usermod line" {
    mkdir -p "$HOME/.config/sbx/profiles/fs"
    echo '{"description":"t","userns":"full"}' > "$HOME/.config/sbx/profiles/fs/full.json"
    : > "$ROOT/subuid"; : > "$ROOT/subgid"
    run env PATH="$ROOT/bin" SBX_OS_RELEASE="$ROOT/arch" SBX_SUBUID="$ROOT/subuid" SBX_SUBGID="$ROOT/subgid" \
        bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$ROOT/p" "$SBX" --fs full --net web -- /bin/true
    [ "$status" -ne 0 ]
    [[ "$output" == *"usermod --add-subuids"* ]]
    no_session_built
}
```

- [ ] **Step 6: Run them to verify the current state**

Run: `bats tests/preflight.bats`
Expected: "debian command", "arch command", "missing xpra" (message differs) and the userns and subid tests FAIL; "missing pasta without --net" may pass on its `bubblewrap` assertion, since `require_tools` already hints it.

- [ ] **Step 7: Wire the library into `sbx`**

In `sbx`, after the existing source line (`sbx:11-12`), add:

```bash
# shellcheck source=lib/deps.sh
source "$SCRIPT_DIR/lib/deps.sh"
```

Delete the whole `require_tools` block at `sbx:661-693` — the comment starting `# Same reasoning for the rest of the toolchain.`, the function, and the two calls after it.

Immediately **before** the confirmation loop (`for profile in "${FS_PROFILES[@]}" "$CLI_PROFILE" "${NET_PROFILES[@]}"; do` / `confirm_project_profile`, `sbx:656`), insert:

```bash
# --- Dependency preflight: core ---
# Everything below this point may exec a core tool — the confirmation uses
# realpath and the feature scan uses jq — so the core group is checked
# first, along with whether bwrap can create a user namespace at all.
# bwrap used to be discovered only when launch.sh tried to exec it, which
# reported nothing but "bwrap: not found" after a session directory, an
# xpra display and a pasta namespace had already been built.
sbx_deps_require core || exit 1
```

Immediately **after** the `userns: full requires networking` check that ends the feature-field scan (the `fi` before `# --- Host-service access ---`, `sbx:747`), insert:

```bash
# --- Dependency preflight: optional groups ---
# Chosen from what the flags and the feature scan above turned on.
DEP_GROUPS=()
[[ ${#NET_PROFILES[@]} -gt 0 ]] && DEP_GROUPS+=(net)
[[ "$GUI_FLAG" == "true" ]] && DEP_GROUPS+=(gui)
if [[ "$USERNS_FULL" == "true" || "$CAPS_KEEP" == "true" || "$DOCKER_API" == "true" ]]; then
    DEP_GROUPS+=(podman)
fi
if [[ ${#DEP_GROUPS[@]} -gt 0 ]]; then
    sbx_deps_require "${DEP_GROUPS[@]}" || exit 1
fi
if [[ "$USERNS_FULL" == "true" ]] && ! sbx_deps_subids_ok; then
    echo "Error: profile '$USERNS_PROFILE' sets \"userns\": \"full\", which needs a subordinate UID and GID range for $(id -un)." >&2
    echo "  Add one:  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)" >&2
    exit 1
fi
```

In the GUI setup (`sbx:1807-1811`), delete the now-redundant check:

```bash
    if ! command -v xpra >/dev/null 2>&1; then
        echo "Error: xpra is not installed. Cannot use --gui mode." >&2
        exit 1
    fi
```

Leave the inline `tmux` checks in `--join` and `--attach` (`sbx:451`, `sbx:536`) as they are: those paths need only tmux, not the core group or a userns probe.

- [ ] **Step 8: Run the new tests to verify they pass**

Run: `bats tests/preflight.bats tests/deps.bats`
Expected: 30 tests, 0 failures.

- [ ] **Step 9: Run the full suite and shellcheck**

Run: `bats tests/ && shellcheck -S error sbx lib/copy-mounts.sh lib/deps.sh`
Expected: all tests pass; shellcheck silent. A regression here most likely means a launch path now runs the core check where it previously did not need bwrap (e.g. `--list-sessions`, `--gc`) — those exit during argument parsing, before the preflight, so none should be affected.

- [ ] **Step 10: Commit**

```bash
git add sbx lib/deps.sh tests/deps.bats tests/preflight.bats
git commit -m "Check dependencies and user namespaces before building a session"
```

---

### Task 4: `sbx --doctor`

**Files:**
- Modify: `lib/deps.sh` (append `sbx_deps_doctor`)
- Modify: `sbx` argument parsing (new case beside `--list-profiles`, `sbx:220`), `usage` (`sbx:76-107`)
- Modify: `README.md` (command table and a new section)
- Test: `tests/deps.bats` (append)

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: `sbx_deps_doctor [--json]` → prints the report to stdout; returns 1 if a `core` tool is missing or the userns probe fails, else 0.

Text format:

```
sbx doctor — distro family: arch

core     ✓ bwrap tmux jq envsubst setpriv flock realpath sha256sum ip
         ✓ unprivileged user namespaces
net      ✗ missing: pasta
gui      ✓ xpra
podman   ✓ podman newuidmap unshare
         ✗ no subordinate UID/GID range for alice (needed by "userns": "full")
           sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 alice

Install missing packages:
  sudo pacman -S passt
```

When bwrap itself is missing, the userns line reads `? unprivileged user namespaces (needs bwrap)`. When the probe fails, its `Error:`/`Cause:`/`Fix:` text follows, indented by 11 spaces.

JSON format (one line; shown pretty here):

```json
{"family":"arch","ok":true,
 "groups":{"core":[],"net":["pasta"],"gui":[],"podman":[]},
 "userns":true,"subids":false,
 "install":["sudo pacman -S passt"]}
```

`userns` is `null` when bwrap is missing. All strings come from the table, the family name, or the package-manager prefixes, so no escaping is needed; `jq` is deliberately not used, since `--doctor` must work when jq is the thing that's missing.

- [ ] **Step 1: Write the failing tests**

Append to `tests/deps.bats`:

```bash
doctor_bin() {   # <tool to omit>...: a PATH holding every table tool except those named
    mkdir -p "$FIX/bin"
    local tool skip
    while IFS= read -r tool; do
        for skip in "$@"; do [[ "$tool" == "$skip" ]] && continue 2; done
        ln -sf "$(command -v "$tool")" "$FIX/bin/$tool"
    done < <(sbx_deps_tools core net gui podman)
    # id and awk are used by the subid check
    ln -sf "$(command -v id)" "$FIX/bin/id"
    ln -sf "$(command -v awk)" "$FIX/bin/awk"
}

@test "doctor: all present exits 0 and reports each group" {
    doctor_bin bwrap
    fake_bwrap 0
    os_release "$FIX/os" manjaro arch
    PATH="$FIX/bin" SBX_OS_RELEASE="$FIX/os" run sbx_deps_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"distro family: arch"* ]]
    [[ "$output" == *"✓ unprivileged user namespaces"* ]]
    if [[ "$output" == *"Install missing packages"* ]]; then return 1; fi
}

@test "doctor: a missing optional tool is reported but exits 0" {
    doctor_bin bwrap pasta
    fake_bwrap 0
    os_release "$FIX/os" fedora
    PATH="$FIX/bin" SBX_OS_RELEASE="$FIX/os" run sbx_deps_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"✗ missing: pasta"* ]]
    [[ "$output" == *"sudo dnf install passt"* ]]
}

@test "doctor: a missing core tool exits 1" {
    doctor_bin bwrap jq
    fake_bwrap 0
    PATH="$FIX/bin" run sbx_deps_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"✗ missing: jq"* ]]
}

@test "doctor: missing bwrap marks userns unknown" {
    doctor_bin bwrap
    PATH="$FIX/bin" run sbx_deps_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"? unprivileged user namespaces (needs bwrap)"* ]]
}

@test "doctor: a failing probe exits 1 and includes the diagnosis" {
    doctor_bin bwrap
    fake_bwrap 1 "bwrap: nope"
    fake_sysctl kernel/unprivileged_userns_clone 0
    PATH="$FIX/bin" SBX_PROC_SYS="$FIX/sys" run sbx_deps_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"kernel.unprivileged_userns_clone=1"* ]]
}

@test "doctor --json is parseable and matches the text report" {
    doctor_bin bwrap pasta
    fake_bwrap 0
    os_release "$FIX/os" ubuntu debian
    : > "$FIX/subuid"; : > "$FIX/subgid"
    PATH="$FIX/bin" SBX_OS_RELEASE="$FIX/os" SBX_SUBUID="$FIX/subuid" SBX_SUBGID="$FIX/subgid" \
        run sbx_deps_doctor --json
    [ "$status" -eq 0 ]
    [ "$(jq -r .family <<< "$output")" = "debian" ]
    [ "$(jq -c .groups.net <<< "$output")" = '["pasta"]' ]
    [ "$(jq -r .userns <<< "$output")" = "true" ]
    [ "$(jq -r .subids <<< "$output")" = "false" ]
    [ "$(jq -r '.install[0]' <<< "$output")" = "sudo apt install passt" ]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/deps.bats`
Expected: 6 new failures, `sbx_deps_doctor: command not found`.

- [ ] **Step 3: Implement `sbx_deps_doctor`**

Append to `lib/deps.sh`:

```bash
sbx_deps_json_list() {
    local first=1 x
    printf '['
    for x in "$@"; do
        [[ $first -eq 1 ]] || printf ','
        printf '"%s"' "$x"
        first=0
    done
    printf ']'
}

sbx_deps_doctor() {
    local json=false
    [[ "${1:-}" == "--json" ]] && json=true

    local family group rc=0 userns=null userns_msg="" subids=false user line
    local -a missing tools all_missing=() hint=()
    local -A group_missing=()

    family=$(sbx_deps_family)
    user=$(id -un)
    for group in core net gui podman; do
        mapfile -t missing < <(sbx_deps_missing "$group")
        group_missing[$group]="${missing[*]}"
        all_missing+=("${missing[@]}")
    done
    if [[ -n "${group_missing[core]}" ]]; then
        rc=1
    fi
    if command -v bwrap >/dev/null 2>&1; then
        if userns_msg=$(sbx_deps_userns_check); then
            userns=true
        else
            userns=false
            rc=1
        fi
    fi
    if sbx_deps_subids_ok; then
        subids=true
    fi
    if [[ ${#all_missing[@]} -gt 0 ]]; then
        mapfile -t hint < <(sbx_deps_install_hint "$family" "${all_missing[@]}")
    fi

    if $json; then
        printf '{"family":"%s","ok":%s,"groups":{' "$family" "$([[ $rc -eq 0 ]] && echo true || echo false)"
        local first=1
        for group in core net gui podman; do
            [[ $first -eq 1 ]] || printf ','
            # shellcheck disable=SC2086  # the stored list is space-separated
            printf '"%s":%s' "$group" "$(sbx_deps_json_list ${group_missing[$group]})"
            first=0
        done
        printf '},"userns":%s,"subids":%s,"install":%s}\n' "$userns" "$subids" "$(sbx_deps_json_list "${hint[@]}")"
        return $rc
    fi

    echo "sbx doctor — distro family: $family"
    echo
    for group in core net gui podman; do
        if [[ -z "${group_missing[$group]}" ]]; then
            mapfile -t tools < <(sbx_deps_tools "$group")
            printf '%-8s ✓ %s\n' "$group" "${tools[*]}"
        else
            printf '%-8s ✗ missing: %s\n' "$group" "${group_missing[$group]}"
        fi
        case "$group" in
            core)
                case "$userns" in
                    true)  echo "         ✓ unprivileged user namespaces" ;;
                    null)  echo "         ? unprivileged user namespaces (needs bwrap)" ;;
                    false)
                        echo "         ✗ unprivileged user namespaces"
                        while IFS= read -r line; do
                            echo "           $line"
                        done <<< "$userns_msg"
                        ;;
                esac
                ;;
            podman)
                if [[ "$subids" == "false" ]]; then
                    echo "         ✗ no subordinate UID/GID range for $user (needed by \"userns\": \"full\")"
                    echo "           sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $user"
                fi
                ;;
        esac
    done
    if [[ ${#hint[@]} -gt 0 ]]; then
        echo
        echo "Install missing packages:"
        for line in "${hint[@]}"; do
            echo "  $line"
        done
    fi
    return $rc
}
```

- [ ] **Step 4: Run the unit tests to verify they pass**

Run: `bats tests/deps.bats`
Expected: 30 tests, 0 failures.

- [ ] **Step 5: Add `--doctor` to `sbx`**

In the argument loop, directly above `--list-profiles)` (`sbx:220`), add:

```bash
        --doctor)
            doctor_rc=0
            sbx_deps_doctor "${2:-}" || doctor_rc=$?
            exit "$doctor_rc"
            ;;
```

In `usage`, after the `--list-sessions` line, add:

```
  --doctor [--json]      Check dependencies and host setup, with install commands
```

- [ ] **Step 6: Verify end to end**

Run: `./sbx --doctor; echo "exit=$?"; ./sbx --doctor --json | jq .ok`
Expected: a report with all four groups ✓ on this host (subids line depends on `/etc/subuid`), `exit=0`, then `true`.

- [ ] **Step 7: Document**

In `README.md`, add a row to the Common Commands table, first in the table:

```markdown
| `--doctor [--json]` | Check that required tools are installed and that unprivileged user namespaces work. Prints the install command for your distro. Exits non-zero only if something every session needs is missing. |
```

Add a section directly before `## Usage`:

```markdown
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
before creating anything.
```

- [ ] **Step 8: Full suite, shellcheck, commit**

Run: `bats tests/ && shellcheck -S error sbx lib/copy-mounts.sh lib/deps.sh`
Expected: all pass, shellcheck silent.

```bash
git add sbx lib/deps.sh tests/deps.bats README.md
git commit -m "Add sbx --doctor"
```

---

## Open items outside this plan

- **Ubuntu 24.04 verification.** The AppArmor diagnosis and printed profile cannot be exercised on this Manjaro host. Before merging `setup-ux`, run `./sbx --doctor` and a `--net` launch on an Ubuntu 24.04 VM. In `--net` sessions pasta, not bwrap, creates the user namespace (`sbx:2345`); if Ubuntu's own passt AppArmor profile blocks that, add a pasta probe to the `net` group and extend the printed profile.
- **Fedora package names** (`gettext-envsubst`, `util-linux-core`, `shadow-utils`, `iproute`) are from Fedora 38+ packaging and should be spot-checked with `dnf provides` on a Fedora host.
- `resolve_profile` calls `realpath` during argument parsing for path-style profile arguments, before the core preflight. A host without coreutils fails there with a shell error. Not addressed: coreutils is effectively universal.
