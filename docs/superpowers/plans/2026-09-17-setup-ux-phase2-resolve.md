# Setup UX Phase 2: Resolve Step and Validation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every launch first turns its flags and profiles into a JSON plan — validated, side-effect free — and the rest of `sbx` builds the sandbox from that plan instead of re-reading profile files, with byte-identical generated output.

**Architecture:** Four new libraries: `lib/profiles.sh` (lookup, origin, listing), `lib/profile-check.sh` (one jq validation program), `lib/net-merge.sh` (net profile composition), and `lib/resolve.sh` (`sbx_resolve`, which calls the other three and prints the plan). `sbx` calls `sbx_resolve` right after the core dependency check, prints warnings, stops on errors, then *hydrates* the same global variables its launch code already uses (`CAPS_KEEP`, `FORKED_MOUNTS`, `DOMAIN_PORTS`, …) from the plan. The launch-generation code after hydration is not modified. A golden-file snapshot suite, written first against today's code, proves the generated launch is unchanged.

**Tech Stack:** bash 5, jq 1.7+, bats 1.14, shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-16-setup-ux-design.md` — "Phase 2: Resolve step and validation". Phase 1 (dependencies) is complete on this branch.

## Global Constraints

- `shellcheck -S error sbx lib/*.sh` must be silent. Pre-existing sub-error warnings in `sbx` are not a gate.
- The resolve step has **no side effects**: no directories created, nothing seeded, no session name claimed, no files written. Read-only commands (`jq`, `realpath -m`, `envsubst`, `git ls-files`) are allowed.
- After Task 6, `bats tests/snapshot.bats` passes **without** `SBX_UPDATE_SNAPSHOTS=1`: generated bwrap arguments, `launch.sh`, `session.sh`, `wrapper.sh`, `tmux.conf`, the nft ruleset, `resolv.conf`, podman confs, `session.json` and the join sidecar are byte-identical to the goldens committed in Task 1.
- Passthrough variables appear in the plan **by name only**, never by value.
- The plan is the only input the launch code reads about profiles after resolve. `sbx` must not call `jq` on a profile file after hydration.
- Library files define functions and constants only — no side effects at source time, no dependency on `sbx` globals (inputs arrive as arguments).
- Validation errors stop the launch and are **all** reported at once, each as `<file>: <json path>: <message>`. Warnings print and the launch continues.
- Messages existing tests assert must keep their asserted substrings: `may not set` (project profile restricted fields), `requires networking` (userns full without net), `retains capabilities` (caps keep warning).
- bats: `! cmd` is only an assertion on a test's last line; elsewhere use `if …; then return 1; fi`. Tests that run `sbx` use a short `mktemp -d /tmp/sbxh.XXXXXX` root, cleaned in `teardown`.
- In library code, use `if` statements, never `[[ … ]] && cmd`, as a loop body's last command or a function's last command: under `set -e` a false test there fails the caller.
- Comments that explain *why* move with the logic they explain (e.g. the host-port allow-list rationale moves into `lib/resolve.sh`, the net-composition rationale into `lib/net-merge.sh`).
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WWTpUZ8XwVF2wUzAUMreDD
  ```

## Decisions recorded for implementers

- **Env in the plan is an ordered list of assignments**, not a de-duplicated map: bwrap receives one `--setenv` per profile entry, in profile order, and the last one wins inside bwrap. Byte-identical output requires keeping every assignment. Phase 3 (`--dry-run`) derives the winners from this list.
- **Port signatures stay strings** (`"80,443"`, `"*"`) in `plan.net`, exactly as the current code builds them, so the nft ruleset and dnsmasq flags are unchanged. Phase 3 renders them.
- **The core dependency check stays before resolve**: resolve needs `jq`, `realpath`, `envsubst`.
- **The `--gui` path is not snapshotted**: `xpra start` waits for a real X11 socket. GUI bwrap arguments are added after the plan and do not come from profiles.
- **`plan.writes` is not built here**; Phase 3 adds it.
- **Env values go through `printf '%s'`, not `echo`**, before `envsubst`. The current `echo "$value"` swallows a value of `-n` or `-e`; this is an intentional fix. No shipped or fixture profile is affected.
- **Absent mount sources** become plan warnings (`… mount source not present on this host, skipped: <perm> <source>`) instead of the separate `Note:` block. An absent `rw` source is not a warning: the launch creates it, as today.

## File Structure

- Create `tests/snapshot.bats` and `tests/snapshots/<case>/…` — golden files of generated launch artifacts.
- Create `lib/profiles.sh` — `sbx_profile_resolve`, `sbx_profile_origin`, `sbx_profile_list`. Test: `tests/profiles.bats`.
- Create `lib/profile-check.sh` — `SBX_PROFILE_CHECK_JQ`, `sbx_profile_check`. Test: `tests/profile-check.bats`.
- Create `lib/net-merge.sh` — `sbx_net_merge_ports`, `sbx_net_merge`. Test: `tests/net-merge.bats`.
- Create `lib/resolve.sh` — `sbx_resolve` and two JSON array helpers. Test: `tests/resolve.bats`.
- Modify `sbx` — source the new libraries; replace `resolve_profile`/`list_profiles`/`profile_is_project` bodies (Task 2); replace the feature scan, host-port gathering, passthrough loop, `apply_mounts`, env/PATH parsing and net merge with resolve + hydration (Task 6).
- Modify `README.md` — a "Profile validation" subsection (Task 6).

---

### Task 1: Snapshot suite of today's generated launch

**Files:**
- Create: `tests/snapshot.bats`
- Create: `tests/snapshots/{plain,mounts,stacked-net,host-ports,podman,userns-full}/…` (generated)

**Interfaces:**
- Produces: `tests/snapshot.bats` with helpers `run_case <name> <sbx args…>` and `check_snapshot <name>`; env `SBX_UPDATE_SNAPSHOTS=1` rewrites goldens. Later tasks run it unchanged.

Nothing is sandboxed. Stubs placed first on `PATH` intercept the three places a launch leaves `sbx`: `bwrap` (no-net launches exec it from `launch.sh`), `pasta` (net and host-port launches), `unshare` (`userns: full` wraps pasta). `ip` is stubbed so pasta's host address arguments are fixed. Each capture stub copies the session's generated files out before `sbx`'s teardown deletes the session directory.

- [ ] **Step 1: Write the suite**

Create `tests/snapshot.bats`:

```bash
#!/usr/bin/env bats

# Golden-file snapshots of everything a launch generates: bwrap's argument
# list, launch.sh, session.sh, the nft ruleset, podman confs and the join
# sidecar. They pin the launch exactly, so that moving profile reading into
# lib/resolve.sh can be shown to change nothing. Nothing is sandboxed:
# bwrap, pasta, unshare and ip are stubs that copy the generated files out
# and exit.
#
# After an intentional change to what a launch generates, regenerate with:
#   SBX_UPDATE_SNAPSHOTS=1 bats tests/snapshot.bats
# and review the diff of tests/snapshots/ like any other code change.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SBX="$REPO/sbx"
    SNAP_DIR="$BATS_TEST_DIRNAME/snapshots"
    # Short, like every suite that launches sbx: the session socket path
    # must stay under the Unix limit.
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    HOME_DIR="$ROOT/h"
    PROJ="$ROOT/proj"
    STUB="$ROOT/stub"
    CAP="$ROOT/cap"
    HOSTSRC="$ROOT/src"
    mkdir -p "$HOME_DIR/.config/sbx/profiles/fs" "$HOME_DIR/.config/sbx/profiles/cli" \
             "$HOME_DIR/.config/sbx/profiles/net" "$PROJ" "$STUB" "$CAP" "$HOSTSRC"
    write_stubs
    write_fixture_profiles
}

teardown() {
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]]; then
        rm -rf "$ROOT"
    fi
}

write_stubs() {
    # Copies one session's generated files into $SBX_CAPTURE.
    cat > "$STUB/sbx-capture" <<'EOF'
#!/bin/bash
sdir="$1"
name=$(basename "$sdir")
mkdir -p "$SBX_CAPTURE"
for f in launch.sh session.sh wrapper.sh tmux.conf session.json \
         dns/rules.nft dns/resolv.conf virt/storage.conf virt/containers.conf; do
    if [[ -f "$sdir/$f" ]]; then
        cp "$sdir/$f" "$SBX_CAPTURE/${f//\//_}"
    fi
done
join="$(dirname "$(dirname "$sdir")")/join/$name.json"
if [[ -f "$join" ]]; then
    cp "$join" "$SBX_CAPTURE/join.json"
fi
exit 0
EOF
    cat > "$STUB/bwrap" <<'EOF'
#!/bin/bash
# The dependency preflight's user-namespace probe must pass.
if [[ "$*" == "--unshare-user --ro-bind / / true" ]]; then
    exit 0
fi
mkdir -p "$SBX_CAPTURE"
printf '%s\n' "$@" > "$SBX_CAPTURE/bwrap.args"
# bwrap's last argument is session.sh, inside the session directory.
exec "$(dirname "$0")/sbx-capture" "$(dirname "${@: -1}")"
EOF
    cat > "$STUB/pasta" <<'EOF'
#!/bin/bash
mkdir -p "$SBX_CAPTURE"
printf '%s\n' "$@" > "$SBX_CAPTURE/pasta.args"
# pasta's last argument is launch.sh, inside the session directory.
exec "$(dirname "$0")/sbx-capture" "$(dirname "${@: -1}")"
EOF
    cat > "$STUB/unshare" <<'EOF'
#!/bin/bash
while [[ $# -gt 0 && "$1" != "--" ]]; do
    shift
done
shift
exec "$@"
EOF
    cat > "$STUB/ip" <<'EOF'
#!/bin/bash
case "$*" in
    "route show default") echo "default via 10.99.0.1 dev snap0 proto static" ;;
    "addr show snap0")    echo "    inet 10.99.0.2/24 brd 10.99.0.255 scope global snap0" ;;
esac
exit 0
EOF
    chmod +x "$STUB"/*
}

write_fixture_profiles() {
    local P="$HOME_DIR/.config/sbx/profiles"
    mkdir -p "$HOSTSRC/rodir" "$HOSTSRC/rwdir" "$HOSTSRC/state" "$HOSTSRC/tree"
    echo ro > "$HOSTSRC/rodir/f"
    echo state > "$HOSTSRC/state/s"
    echo '{"k":1}' > "$HOSTSRC/state.json"
    echo t > "$HOSTSRC/tree/t"

    cat > "$P/fs/snapmounts.json" <<EOF
{"description":"snapshot mounts",
 "mounts":[
  {"source":"$HOSTSRC/rodir","dest":"/snap/ro","perm":"ro"},
  {"source":"$HOSTSRC/rwdir","dest":"/snap/deep/rw","perm":"rw"},
  {"source":"$HOSTSRC/newrw","dest":"/snap/newrw","perm":"rw"},
  {"source":"/dev/null","dest":"/snap/devnull","perm":"dev"},
  {"source":"$HOSTSRC/absent","dest":"/snap/absent","perm":"ro"},
  {"source":"$HOSTSRC/state","dest":"/snap/state","perm":"forked"},
  {"source":"$HOSTSRC/state.json","dest":"/snap/state.json","perm":"forked"},
  {"source":"$HOSTSRC/tree","dest":"/snap/tree","perm":"record"}
 ],
 "env":{"SNAP_FS":"fs-value","SNAP_SHARED":"from-fs","PATH":"/opt/snap/bin:/usr/bin"},
 "passthrough":["SBX_SNAP_TOKEN"]}
EOF
    cat > "$P/cli/snapcli.json" <<'EOF'
{"description":"snapshot cli",
 "env":{"SNAP_SHARED":"from-cli","SNAP_HOME":"$HOME/x","SNAP_NUM":7},
 "path":["$HOME/.snap/bin","/opt/tool/bin"],
 "mounts":[{"source":"$HOME/cli-ro","dest":"/cli/ro","perm":"ro"}]}
EOF
    cat > "$P/net/snapdb.json" <<'EOF'
{"description":"snapshot db","dns":"9.9.9.9",
 "allow":["db.internal.example","github.com","10.0.0.0/8"],
 "ports":[5432],"host_ports":[5433,"5353/udp"]}
EOF
    cat > "$P/net/snapwild.json" <<'EOF'
{"description":"snapshot wildcard","allow":["*"],"ports":["*"]}
EOF
    printf '%s:100000:65536\n' "$(id -un)" > "$ROOT/subuid"
    cp "$ROOT/subuid" "$ROOT/subgid"
}

# Host-specific values are replaced by placeholders so the goldens are
# portable: the temp root, the repo checkout, the uid/gid, the dnsmasq
# binary's location, the host's resolv.conf bind target and the pid.
normalize() {   # <capture dir>
    local dir="$1" f uid gid dnsmasq resolv_dest
    uid=$(id -u)
    gid=$(id -g)
    dnsmasq=$(command -v dnsmasq || echo /nonexistent)
    resolv_dest=/etc/resolv.conf
    if [[ -L /etc/resolv.conf ]]; then
        resolv_dest=$(readlink -f /etc/resolv.conf)
    fi
    for f in "$dir"/*; do
        sed -i -E \
            -e "s#$ROOT#@ROOT@#g" \
            -e "s#$REPO#@REPO@#g" \
            -e "s#$dnsmasq#@DNSMASQ@#g" \
            -e "s#(dns/resolv\\.conf\"?) (\"?)$resolv_dest(\"?)#\\1 \\2@RESOLV_DEST@\\3#g" \
            -e "s#/run/user/$uid#/run/user/@UID@#g" \
            -e "s#(_CONTAINERS_ROOTLESS_UID )$uid#\\1@UID@#g" \
            -e "s#(_CONTAINERS_ROOTLESS_GID )$gid#\\1@GID@#g" \
            -e 's#("pid": )[0-9]+#\1@PID@#' \
            "$f"
    done
    # bwrap.args holds one argument per line, so ids and the resolv.conf
    # target sit on the line after their key.
    if [[ -f "$dir/bwrap.args" ]]; then
        awk -v u="$uid" -v g="$gid" -v r="$resolv_dest" '
            prev == "_CONTAINERS_ROOTLESS_UID" && $0 == u { out = "@UID@" }
            prev == "_CONTAINERS_ROOTLESS_GID" && $0 == g { out = "@GID@" }
            prev ~ /dns\/resolv\.conf$/ && $0 == r        { out = "@RESOLV_DEST@" }
            { if (out == "") out = $0; print out; prev = $0; out = "" }
        ' "$dir/bwrap.args" > "$dir/bwrap.args.tmp"
        mv "$dir/bwrap.args.tmp" "$dir/bwrap.args"
    fi
}

run_case() {   # <case name> <sbx args...>
    local name="$1"; shift
    local cmd
    cmd="$(printf '%q ' "$SBX" "$@")-- /bin/true"
    ( cd "$PROJ" && env -i \
        PATH="$STUB:/usr/local/bin:/usr/bin:/bin" \
        HOME="$HOME_DIR" USER=snapuser LOGNAME=snapuser SHELL=/bin/bash \
        TERM=xterm LANG=C.UTF-8 \
        SBX_CAPTURE="$CAP/$name" \
        SBX_SUBUID="$ROOT/subuid" SBX_SUBGID="$ROOT/subgid" \
        SBX_SNAP_TOKEN=snaptoken \
        script -qec "$cmd" /dev/null < /dev/null > "$ROOT/$name.out" 2>&1 ) || true
    if [[ -d "$CAP/$name" ]]; then
        normalize "$CAP/$name"
    fi
}

check_snapshot() {   # <case name>
    local name="$1"
    local want="$SNAP_DIR/$name" got="$CAP/$name"
    if [[ ! -d "$got" || -z "$(ls -A "$got")" ]]; then
        echo "nothing captured for $name; sbx said:" >&2
        cat "$ROOT/$name.out" >&2
        return 1
    fi
    if [[ "${SBX_UPDATE_SNAPSHOTS:-}" == "1" ]]; then
        rm -rf "$want"
        mkdir -p "$want"
        cp "$got"/* "$want"/
        return 0
    fi
    diff -ru "$want" "$got"
}

@test "snapshot: plain fs profile, no network" {
    run_case plain --fs sandbox
    check_snapshot plain
}

@test "snapshot: every mount kind, env layering, passthrough, cli path, --wd" {
    mkdir -p "$HOME_DIR/cli-ro"
    run_case mounts --fs snapmounts --cli snapcli --wd /snap/ro
    check_snapshot mounts
}

@test "snapshot: stacked net profiles with a wildcard and profile host ports" {
    run_case stacked-net --net web --net snapdb --net snapwild
    check_snapshot stacked-net
}

@test "snapshot: host ports without a net profile" {
    run_case host-ports --host-port 8080 --host-port 5353/udp
    check_snapshot host-ports
}

@test "snapshot: caps keep and docker api" {
    run_case podman --fs podman --net web
    check_snapshot podman
}

@test "snapshot: userns full" {
    run_case userns-full --fs podman-full --net web
    check_snapshot userns-full
}

@test "snapshot capture is deterministic across launches" {
    mkdir -p "$HOME_DIR/cli-ro"
    run_case again-a --fs snapmounts --cli snapcli --net web --net snapdb
    run_case again-b --fs snapmounts --cli snapcli --net web --net snapdb
    if [[ ! -d "$CAP/again-a" ]]; then
        cat "$ROOT/again-a.out" >&2
        return 1
    fi
    diff -ru "$CAP/again-a" "$CAP/again-b"
}
```

- [ ] **Step 2: Generate the goldens from today's code**

Run: `SBX_UPDATE_SNAPSHOTS=1 bats tests/snapshot.bats`
Expected: 7 tests pass; `tests/snapshots/` holds six case directories. `plain` contains `bwrap.args`, `launch.sh`, `session.sh`, `session.json`, `join.json` and podman confs; `stacked-net`, `podman`, `userns-full` and `host-ports` contain `pasta.args` and `dns_rules.nft`.

If a case captured nothing, its `sbx` output is printed. Fix the stub or fixture, not `sbx`.

- [ ] **Step 3: Check the goldens are host-independent and meaningful**

Run:
```bash
grep -rlE "$(id -un)|/home/|/tmp/sbxh" tests/snapshots || echo clean
grep -c -- '--ro-bind-try' tests/snapshots/mounts/bwrap.args
grep -E 'allowed4_|5432|9\.9\.9\.9' tests/snapshots/stacked-net/dns_rules.nft | head
grep -E '(-T|-U)' -A1 tests/snapshots/host-ports/pasta.args
```
Expected: first prints `clean`. The mounts golden has ro binds; the stacked-net ruleset has several `allowed4_N` sets and port 5432; the host-ports pasta args show `8080` for `-T` and `5353` for `-U`.

If a host-specific string survives, add a normalization rule, regenerate, and re-check. Record each added rule in the report.

- [ ] **Step 4: Run without update to verify the comparison passes**

Run: `bats tests/snapshot.bats`
Expected: 7/7 pass.

- [ ] **Step 5: Prove the snapshot catches a change**

Temporarily edit `sbx`: change `--unshare-cgroup` in the `BWRAP_ARGS=(` base list to `--unshare-cgroup-try`. Run `bats tests/snapshot.bats`; expected: every case fails with a diff showing that line. Revert the edit (`git checkout sbx`) and re-run; expected 7/7 pass.

- [ ] **Step 6: Commit**

```bash
git add tests/snapshot.bats tests/snapshots
git commit -m "Snapshot every file a launch generates"
```

---

### Task 2: `lib/profiles.sh` — lookup, origin, listing

**Files:**
- Create: `lib/profiles.sh`
- Create: `tests/profiles.bats`
- Modify: `sbx` — source the library after `lib/deps.sh`; replace the bodies of `resolve_profile`, `list_profiles`, `profile_is_project`

**Interfaces:**
- Produces:
  - `sbx_profile_resolve <type> <name> <config_dir> <global_dir>` → prints the profile path, or prints `Error: Profile '<name>' of type '<type>' not found.` to stderr and returns 1. Output paths are exactly what today's `resolve_profile` prints (`realpath` for a direct file path; otherwise the unresolved candidate, e.g. `./.sbx/profiles/fs/x.json`).
  - `sbx_profile_origin <path> <launch_dir> <config_dir> <global_dir>` → prints `project` | `user` | `global` | `path`
  - `sbx_profile_list <config_dir> <global_dir>` → today's `--list-profiles` output, byte for byte

- [ ] **Step 1: Write the failing tests**

Create `tests/profiles.bats`:

```bash
#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/profiles.sh"
    W="$BATS_TEST_TMPDIR/w"
    PROJ="$W/proj"; CFG="$W/cfg"; GLOBAL="$W/global"
    mkdir -p "$PROJ/.sbx/profiles/fs" "$CFG/profiles/fs" "$CFG/profiles/net" "$GLOBAL/fs" "$GLOBAL/cli"
    echo '{}' > "$PROJ/.sbx/profiles/fs/shared.json"
    echo '{}' > "$CFG/profiles/fs/shared.json"
    echo '{}' > "$CFG/profiles/fs/mine.json"
    echo '{}' > "$CFG/profiles/net/web.json"
    echo '{}' > "$GLOBAL/fs/shared.json"
    echo '{}' > "$GLOBAL/fs/base.json"
    echo '{}' > "$GLOBAL/cli/dev.json"
    cd "$PROJ"
}

@test "resolve prefers the project over user over global" {
    run sbx_profile_resolve fs shared "$CFG" "$GLOBAL"
    [ "$status" -eq 0 ]
    [ "$output" = "./.sbx/profiles/fs/shared.json" ]
    run sbx_profile_resolve fs mine "$CFG" "$GLOBAL"
    [ "$output" = "$CFG/profiles/fs/mine.json" ]
    run sbx_profile_resolve fs base "$CFG" "$GLOBAL"
    [ "$output" = "$GLOBAL/fs/base.json" ]
}

@test "resolve strips a type prefix" {
    run sbx_profile_resolve cli cli/dev "$CFG" "$GLOBAL"
    [ "$output" = "$GLOBAL/cli/dev.json" ]
}

@test "resolve accepts a direct file path, with or without .json" {
    echo '{}' > "$W/direct.json"
    run sbx_profile_resolve fs "$W/direct.json" "$CFG" "$GLOBAL"
    [ "$output" = "$(realpath "$W/direct.json")" ]
    run sbx_profile_resolve fs "$W/direct" "$CFG" "$GLOBAL"
    [ "$output" = "$(realpath "$W/direct.json")" ]
}

@test "resolve fails with the existing message" {
    run sbx_profile_resolve net nope "$CFG" "$GLOBAL"
    [ "$status" -eq 1 ]
    [ "$output" = "Error: Profile 'nope' of type 'net' not found." ]
}

@test "origin classifies each location" {
    run sbx_profile_origin ./.sbx/profiles/fs/shared.json "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "project" ]
    run sbx_profile_origin "$CFG/profiles/fs/mine.json" "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "user" ]
    run sbx_profile_origin "$GLOBAL/fs/base.json" "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "global" ]
    run sbx_profile_origin "$W/direct.json" "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "path" ]
}

@test "origin is not fooled by a sibling directory sharing a prefix" {
    mkdir -p "$W/proj/.sbxevil"
    echo '{}' > "$W/proj/.sbxevil/x.json"
    run sbx_profile_origin "$W/proj/.sbxevil/x.json" "$PROJ" "$CFG" "$GLOBAL"
    [ "$output" = "path" ]
}

@test "list prints every profile with its source label" {
    run sbx_profile_list "$CFG" "$GLOBAL"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Available Profiles:" ]
    [[ "$output" == *"  shared (Project)"* ]]
    [[ "$output" == *"  mine (User)"* ]]
    [[ "$output" == *"  base (Global)"* ]]
    [[ "$output" == *"  web (User)"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/profiles.bats`
Expected: all fail — `lib/profiles.sh: No such file or directory`.

- [ ] **Step 3: Capture today's `--list-profiles` output for the regression check**

Run: `./sbx --list-profiles > /tmp/sbx-list-before.txt 2>&1`
Expected: the file lists cli, fs and net profiles.

- [ ] **Step 4: Write the library**

Create `lib/profiles.sh`:

```bash
#!/bin/bash
# Profile lookup, origin classification and listing, shared by sbx and the
# resolve step.
#
# Sourced by sbx and directly by tests/. Defines functions only — no side
# effects at source time, no dependency on sbx globals: every directory is
# an argument.

# Find a profile by name. Precedence is project (./.sbx/profiles, relative
# to the current directory), then user, then global. A name that is itself
# a file path is used directly.
sbx_profile_resolve() {   # <type> <name> <config_dir> <global_dir>
    local type="$1" name="$2" config_dir="$3" global_dir="$4" p

    if [[ -f "$name" ]]; then
        realpath "$name"
        return 0
    fi
    if [[ -f "$name.json" ]]; then
        realpath "$name.json"
        return 0
    fi

    # Strip the type prefix if it was included (e.g., "cli/dev" -> "dev")
    if [[ "$name" == "$type/"* ]]; then
        name="${name#"$type"/}"
    fi

    for p in "./.sbx/profiles/$type/$name.json" \
             "$config_dir/profiles/$type/$name.json" \
             "$global_dir/$type/$name.json"; do
        if [[ -f "$p" ]]; then
            echo "$p"
            return 0
        fi
    done

    echo "Error: Profile '$name' of type '$type' not found." >&2
    return 1
}

# Where a resolved profile came from. "project" is what matters for trust:
# a project profile arrived with the repository and is untrusted input.
sbx_profile_origin() {   # <path> <launch_dir> <config_dir> <global_dir>
    local abs
    abs=$(realpath -m "$1")
    if [[ "$abs" == "$(realpath -m "$2/.sbx")/"* ]]; then
        echo project
    elif [[ "$abs" == "$(realpath -m "$3/profiles")/"* ]]; then
        echo user
    elif [[ "$abs" == "$(realpath -m "$4")/"* ]]; then
        echo global
    else
        echo path
    fi
}

sbx_profile_list() {   # <config_dir> <global_dir>
    local config_dir="$1" global_dir="$2"
    local type src label path files profile found
    local sources=(
        "Project:./.sbx/profiles"
        "User:$config_dir/profiles"
        "Global:$global_dir"
    )

    echo "Available Profiles:"
    for type in cli fs net; do
        echo ""
        echo "${type^^} Profiles:"
        found=0
        for src in "${sources[@]}"; do
            label="${src%%:*}"
            path="${src#*:}"
            if [[ -d "$path/$type" ]]; then
                files=$(find "$path/$type" -name "*.json" | sed "s|$path/$type/||" | sed 's/\.json$//' | sort)
                if [[ -n "$files" ]]; then
                    while IFS= read -r profile; do
                        echo "  $profile ($label)"
                        found=1
                    done <<< "$files"
                fi
            fi
        done
        if [[ $found -eq 0 ]]; then
            echo "  (none)"
        fi
    done
}
```

- [ ] **Step 5: Run the unit tests**

Run: `bats tests/profiles.bats`
Expected: 7/7 pass.

- [ ] **Step 6: Delegate from `sbx`**

In `sbx`, after `source "$SCRIPT_DIR/lib/deps.sh"` add:

```bash
# shellcheck source=lib/profiles.sh
source "$SCRIPT_DIR/lib/profiles.sh"
```

Replace the entire `resolve_profile() { … }` and `list_profiles() { … }` function definitions with:

```bash
resolve_profile() {   # <type> <name>
    sbx_profile_resolve "$1" "$2" "$CONFIG_DIR" "$SCRIPT_DIR/profiles"
}

list_profiles() {
    sbx_profile_list "$CONFIG_DIR" "$SCRIPT_DIR/profiles"
}
```

Replace the body of `profile_is_project()` (keep its leading comment) with:

```bash
profile_is_project() {
    [[ "$(sbx_profile_origin "$1" "$PWD" "$CONFIG_DIR" "$SCRIPT_DIR/profiles")" == "project" ]]
}
```

`resolve_profile` used to `exit 1`; it now returns 1. Every caller is `X+=("$(resolve_profile …)")` or `X="$(resolve_profile …)"` under `set -e`, which still stops the script. Confirm with Step 7.

- [ ] **Step 7: Verify behavior is unchanged**

Run:
```bash
./sbx --list-profiles > /tmp/sbx-list-after.txt 2>&1; diff /tmp/sbx-list-before.txt /tmp/sbx-list-after.txt && echo same
./sbx --fs no-such-profile -- /bin/true; echo "exit=$?"
bats tests/snapshot.bats tests/project-profiles.bats tests/hardening.bats
shellcheck -S error sbx lib/*.sh
```
Expected: `same`; the error line `Error: Profile 'no-such-profile' of type 'fs' not found.` then `exit=1`; all suites pass; shellcheck silent.

- [ ] **Step 8: Commit**

```bash
git add lib/profiles.sh tests/profiles.bats sbx
git commit -m "Move profile lookup into lib/profiles.sh"
```

---

### Task 3: `lib/profile-check.sh` — validation

**Files:**
- Create: `lib/profile-check.sh`
- Create: `tests/profile-check.bats`

**Interfaces:**
- Produces:
  - `SBX_PROFILE_CHECK_JQ` — the jq program (string constant)
  - `sbx_profile_check <type> <file> <origin>` → prints zero or more lines `error<TAB><file>: <json path>: <message>` or `warning<TAB><file>: <json path>: <message>`; always returns 0. `<type>` is `cli|fs|net`; `<origin>` is `project|user|global|path`.

Allowed top-level fields (these come from what `sbx` honors today, which is slightly wider than the README tables: `userns` and `docker_api` are honored in cli profiles too):

| type | fields |
|---|---|
| cli | description, env, path, mounts, passthrough, caps, userns, docker_api, workingDirectory |
| fs | description, mounts, env, passthrough, caps, userns, docker_api, workingDirectory |
| net | description, dns, allow, ports, host_ports |

- [ ] **Step 1: Write the failing tests**

Create `tests/profile-check.bats`:

```bash
#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/profile-check.sh"
    F="$BATS_TEST_TMPDIR/p.json"
}

check() {   # <type> <origin> <json>
    printf '%s\n' "$3" > "$F"
    run sbx_profile_check "$1" "$F" "$2"
    [ "$status" -eq 0 ]
}

@test "a minimal valid profile of each type is clean" {
    check cli user '{"description":"d","env":{"A":"b","N":1},"path":["/x"],"passthrough":["TOKEN"],"mounts":[{"source":"/a","dest":"/b","perm":"ro"}]}'
    [ -z "$output" ]
    check fs user '{"mounts":[{"source":"/a","dest":"/b","perm":"forked"}],"caps":"keep","userns":"full","docker_api":true}'
    [ -z "$output" ]
    check net user '{"dns":"9.9.9.9","allow":["github.com","*","10.0.0.0/8","127.0.0.1"],"ports":[80,"*"],"host_ports":[5432,"53/udp","8080/tcp"]}'
    [ -z "$output" ]
}

@test "invalid JSON is one error naming the file" {
    check fs user '{"mounts": ['
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == "error"$'\t'"$F: invalid JSON: "* ]]
}

@test "a non-object top level is an error" {
    check fs user '[1,2]'
    [ "$output" = "error"$'\t'"$F: .: expected a JSON object at the top level" ]
}

@test "unknown fields are errors, per type" {
    check fs user '{"mount":[]}'
    [ "$output" = "error"$'\t'"$F: .mount: unknown field for a fs profile" ]
    check net user '{"env":{}}'
    [ "$output" = "error"$'\t'"$F: .env: unknown field for a net profile" ]
}

@test "mount problems name the exact entry" {
    check fs user '{"mounts":[{"source":"/a","dest":"/b","perm":"readonly"},{"dest":"/c","perm":"ro","extra":1},"x"]}'
    [[ "$output" == *"$F: .mounts[0].perm: expected one of ro, rw, dev, forked, record, got \"readonly\""* ]]
    [[ "$output" == *"$F: .mounts[1].source: required"* ]]
    [[ "$output" == *"$F: .mounts[1].extra: unknown mount field"* ]]
    [[ "$output" == *"$F: .mounts[2]: expected an object, got \"x\""* ]]
}

@test "perm copy explains the split" {
    check cli user '{"mounts":[{"source":"/a","dest":"/b","perm":"copy"}]}'
    [[ "$output" == *".mounts[0].perm: \"copy\" has been split: use \"forked\""*"\"record\""* ]]
}

@test "field types and fixed values" {
    check fs user '{"description":3,"env":{"A":{"x":1}},"caps":"drop","userns":"yes","docker_api":"true","passthrough":["OK",2,"BAD-NAME"]}'
    [[ "$output" == *".description: expected a string, got 3"* ]]
    [[ "$output" == *".env.A: expected a string or number, got {\"x\":1}"* ]]
    [[ "$output" == *".caps: expected \"keep\", got \"drop\""* ]]
    [[ "$output" == *".userns: expected \"full\", got \"yes\""* ]]
    [[ "$output" == *".docker_api: expected true or false, got \"true\""* ]]
    [[ "$output" == *".passthrough[1]: expected a variable name, got 2"* ]]
    [[ "$output" == *".passthrough[2]: expected a variable name, got \"BAD-NAME\""* ]]
}

@test "ports, host_ports and allow entries" {
    check net user '{"ports":["https",0,443],"host_ports":["80/sctp",70000],"allow":["ok.example","1password.com","300.1.1.1/8","10.0.0.0/33","bad_host!"]}'
    [[ "$output" == *".ports[0]: expected a port 1-65535 or \"*\", got \"https\""* ]]
    [[ "$output" == *".ports[1]: expected a port 1-65535 or \"*\", got 0"* ]]
    if [[ "$output" == *".ports[2]"* ]]; then return 1; fi
    [[ "$output" == *".host_ports[0]: expected N, \"N/tcp\" or \"N/udp\" with N 1-65535, got \"80/sctp\""* ]]
    [[ "$output" == *".host_ports[1]: expected N, \"N/tcp\" or \"N/udp\" with N 1-65535, got 70000"* ]]
    [[ "$output" == *".allow[1]: expected an IPv4 address or CIDR, got \"1password.com\" (entries starting with a digit are read as addresses)"* ]]
    [[ "$output" == *".allow[2]: expected an IPv4 address or CIDR, got \"300.1.1.1/8\""* ]]
    [[ "$output" == *".allow[3]: expected an IPv4 address or CIDR, got \"10.0.0.0/33\""* ]]
    [[ "$output" == *".allow[4]: expected a hostname, *.hostname, * or a CIDR, got \"bad_host!\""* ]]
    if [[ "$output" == *".allow[0]"* ]]; then return 1; fi
}

@test "warnings: workingDirectory, non-IPv4 dns, wildcard suffix" {
    check fs user '{"workingDirectory":"/src"}'
    [ "$output" = "warning"$'\t'"$F: .workingDirectory: no longer honored; pass --wd /src instead" ]
    check net user '{"dns":"sdns://abc","allow":["*.example.com"]}'
    [[ "$output" == *"warning"$'\t'"$F: .dns: not a bare IPv4 address, so 1.1.1.1 is used instead"* ]]
    [[ "$output" == *"warning"$'\t'"$F: .allow[0]: *.example.com admits any address published under that suffix (see README, Threat model)"* ]]
}

@test "project profiles may not set restricted fields" {
    check fs project '{"caps":"keep","userns":"full","docker_api":true}'
    [[ "$output" == *"$F: .caps: project profiles may not set caps; move the profile to ~/.config/sbx/profiles/ to grant it"* ]]
    [[ "$output" == *"$F: .userns: project profiles may not set userns"* ]]
    [[ "$output" == *"$F: .docker_api: project profiles may not set docker_api"* ]]
    check net project '{"host_ports":[5432]}'
    [[ "$output" == *"$F: .host_ports: project profiles may not set host_ports"* ]]
    check fs user '{"caps":"keep"}'
    [ -z "$output" ]
}

@test "every shipped profile validates clean" {
    local f type
    for f in "$BATS_TEST_DIRNAME"/../profiles/*/*.json; do
        type=$(basename "$(dirname "$f")")
        run sbx_profile_check "$type" "$f" global
        if [[ "$output" == *"error"$'\t'* ]]; then
            echo "$output" >&2
            return 1
        fi
    done
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/profile-check.bats`
Expected: all fail — `lib/profile-check.sh: No such file or directory`.

- [ ] **Step 3: Write the library**

Create `lib/profile-check.sh`:

```bash
#!/bin/bash
# Profile validation. One jq program checks a profile against the schema
# for its type and reports every problem at once, each naming the JSON path
# it is about.
#
# Sourced by sbx and directly by tests/. Defines a constant and a function
# only — no side effects at source time, no dependency on sbx globals.
#
# Unknown fields are errors, not ignored: a typo like "mount" would
# otherwise silently grant or withhold nothing. There is deliberately no
# comment convention.

# shellcheck disable=SC2016  # jq program: $vars are jq's, not the shell's
SBX_PROFILE_CHECK_JQ='
def known:
  { cli: ["description","env","path","mounts","passthrough","caps","userns","docker_api","workingDirectory"],
    fs:  ["description","mounts","env","passthrough","caps","userns","docker_api","workingDirectory"],
    net: ["description","dns","allow","ports","host_ports"] };
def restricted: ["caps","userns","docker_api","host_ports"];
def err($p; $m): {level: "error", path: $p, message: $m};
def warn($p; $m): {level: "warning", path: $p, message: $m};
def show: if type == "string" then . else tojson end;
def is_port: type == "number" and . == floor and . >= 1 and . <= 65535;
def is_ipv4: test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$") and (split(".") | all(tonumber <= 255));
def is_cidr:
  (split("/")) as $parts
  | if ($parts | length) == 1 then $parts[0] | is_ipv4
    elif ($parts | length) == 2 then ($parts[0] | is_ipv4) and ($parts[1] | test("^[0-9]{1,2}$") and (tonumber <= 32))
    else false end;
def is_host_glob:
  . == "*" or test("^(\\*\\.)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$");
def is_var_name: type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$");

if type != "object" then [err("."; "expected a JSON object at the top level")]
else
  . as $p
  | [ ( keys[] | . as $k | select(known[$type] | any(. == $k) | not)
        | err(".\($k)"; "unknown field for a \($type) profile") ),

      ( if has("description") and (.description | type) != "string"
        then err(".description"; "expected a string, got \(.description | tojson)") else empty end ),

      ( if has("env") then
          if (.env | type) != "object" then err(".env"; "expected an object, got \(.env | tojson)")
          else .env | to_entries[] | select(.value | type | IN("string", "number") | not)
               | err(".env.\(.key)"; "expected a string or number, got \(.value | tojson)")
          end
        else empty end ),

      ( if has("path") then
          if (.path | type) != "array" then err(".path"; "expected an array of strings, got \(.path | tojson)")
          else .path | to_entries[] | select(.value | type != "string")
               | err(".path[\(.key)]"; "expected a string, got \(.value | tojson)")
          end
        else empty end ),

      ( if has("passthrough") then
          if (.passthrough | type) != "array" then err(".passthrough"; "expected an array of variable names, got \(.passthrough | tojson)")
          else .passthrough | to_entries[] | select(.value | is_var_name | not)
               | err(".passthrough[\(.key)]"; "expected a variable name, got \(.value | tojson)")
          end
        else empty end ),

      ( if has("mounts") then
          if (.mounts | type) != "array" then err(".mounts"; "expected an array, got \(.mounts | tojson)")
          else .mounts | to_entries[] | .key as $i | .value as $m
               | if ($m | type) != "object" then err(".mounts[\($i)]"; "expected an object, got \($m | tojson)")
                 else
                   ( ($m | keys[] | select(IN("source", "dest", "perm") | not)
                        | err(".mounts[\($i)].\(.)"; "unknown mount field")),
                     ( ("source", "dest") as $f
                        | if ($m | has($f)) | not then err(".mounts[\($i)].\($f)"; "required")
                          elif ($m[$f] | type) != "string" then err(".mounts[\($i)].\($f)"; "expected a string, got \($m[$f] | tojson)")
                          else empty end ),
                     ( if ($m | has("perm")) | not then err(".mounts[\($i)].perm"; "required")
                       elif $m.perm == "copy" then err(".mounts[\($i)].perm"; "\"copy\" has been split: use \"forked\" if the sandbox owns the data (seeded from the host once), \"record\" if the host owns it (reseeded every launch, changes archived)")
                       elif ($m.perm | IN("ro", "rw", "dev", "forked", "record")) | not then err(".mounts[\($i)].perm"; "expected one of ro, rw, dev, forked, record, got \($m.perm | tojson)")
                       else empty end ) )
                 end
          end
        else empty end ),

      ( if has("caps") and .caps != "keep" then err(".caps"; "expected \"keep\", got \(.caps | tojson)") else empty end ),
      ( if has("userns") and .userns != "full" then err(".userns"; "expected \"full\", got \(.userns | tojson)") else empty end ),
      ( if has("docker_api") and (.docker_api | type) != "boolean" then err(".docker_api"; "expected true or false, got \(.docker_api | tojson)") else empty end ),

      ( if has("workingDirectory") then warn(".workingDirectory"; "no longer honored; pass --wd \(.workingDirectory | show) instead") else empty end ),

      ( if has("dns") then
          if (.dns | type) != "string" then err(".dns"; "expected a string, got \(.dns | tojson)")
          elif (.dns | is_ipv4) | not then warn(".dns"; "not a bare IPv4 address, so 1.1.1.1 is used instead")
          else empty end
        else empty end ),

      ( if has("allow") then
          if (.allow | type) != "array" then err(".allow"; "expected an array, got \(.allow | tojson)")
          else .allow | to_entries[] | .key as $i | .value as $a
               | if ($a | type) != "string" then err(".allow[\($i)]"; "expected a string, got \($a | tojson)")
                 elif ($a | test("^[0-9]")) then
                   ( if ($a | is_cidr) then empty
                     else err(".allow[\($i)]"; "expected an IPv4 address or CIDR, got \($a | tojson) (entries starting with a digit are read as addresses)") end )
                 elif ($a | is_host_glob) | not then err(".allow[\($i)]"; "expected a hostname, *.hostname, * or a CIDR, got \($a | tojson)")
                 elif ($a | startswith("*.")) then warn(".allow[\($i)]"; "\($a) admits any address published under that suffix (see README, Threat model)")
                 else empty end
          end
        else empty end ),

      ( if has("ports") then
          if (.ports | type) != "array" then err(".ports"; "expected an array, got \(.ports | tojson)")
          else .ports | to_entries[] | select((.value == "*") or (.value | is_port) | not)
               | err(".ports[\(.key)]"; "expected a port 1-65535 or \"*\", got \(.value | tojson)")
          end
        else empty end ),

      ( if has("host_ports") then
          if (.host_ports | type) != "array" then err(".host_ports"; "expected an array, got \(.host_ports | tojson)")
          else .host_ports | to_entries[]
               | select(.value
                   | (is_port)
                     or (type == "string" and test("^[0-9]+(/(tcp|udp))?$") and (split("/")[0] | tonumber | is_port))
                   | not)
               | err(".host_ports[\(.key)]"; "expected N, \"N/tcp\" or \"N/udp\" with N 1-65535, got \(.value | tojson)")
          end
        else empty end ),

      ( if $origin == "project" then
          restricted[] as $f
          | select(($p | has($f)) and (known[$type] | any(. == $f)))
          | err(".\($f)"; "project profiles may not set \($f); move the profile to ~/.config/sbx/profiles/ to grant it")
        else empty end )
    ]
end
| .[] | "\(.level)\t\(.path): \(.message)"
'

sbx_profile_check() {   # <type> <file> <origin>
    local type="$1" file="$2" origin="$3" out level rest
    if ! out=$(jq -r --arg type "$type" --arg origin "$origin" "$SBX_PROFILE_CHECK_JQ" "$file" 2>&1); then
        printf 'error\t%s: invalid JSON: %s\n' "$file" "${out%%$'\n'*}"
        return 0
    fi
    while IFS=$'\t' read -r level rest; do
        if [[ -n "$level" ]]; then
            printf '%s\t%s: %s\n' "$level" "$file" "$rest"
        fi
    done <<< "$out"
    return 0
}
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/profile-check.bats`
Expected: 11/11 pass. If the jq program fails to compile, every test reports `invalid JSON: jq: error: …` — fix the program, not the tests.

- [ ] **Step 5: Rollout check against the user's own profiles (read-only)**

Run:
```bash
bash -c 'source lib/profile-check.sh; for f in ~/.config/sbx/profiles/*/*.json; do t=$(basename "$(dirname "$f")"); sbx_profile_check "$t" "$f" user; done'
```
Record the full output in the report. Do **not** edit any file outside the repository. Known today (from the controller): `cli/pi.json` uses `"perm": "copy"` and `fs/media.json` is not valid JSON — both already fail to launch before this change. Report anything *else* as a concern: it would be a launch that works today and fails after Task 6.

- [ ] **Step 6: Shellcheck and commit**

Run: `shellcheck -S error lib/profile-check.sh` — expected silent.

```bash
git add lib/profile-check.sh tests/profile-check.bats
git commit -m "Validate profiles against their schema"
```

---

### Task 4: `lib/net-merge.sh` — net profile composition

**Files:**
- Create: `lib/net-merge.sh`
- Create: `tests/net-merge.bats`

**Interfaces:**
- Produces:
  - `sbx_net_merge_ports <sig> <sig>` → union of two port signatures (`""`, `"*"`, or comma list); `*` absorbs
  - `sbx_net_merge <net profile path>...` (at least one) → one JSON object, keys sorted:
    ```json
    {"allow_all": false, "allow_all_ports": "",
     "cidrs": {"192.168.1.0/24": "80,443"},
     "domains": {"github.com": {"ports": "80,443", "upstream": "1.1.1.1"}},
     "test_domain": "github.com",
     "upstreams": ["1.1.1.1"]}
    ```

This is today's logic from `sbx` (the `--- Composing several net profiles ---` block through the `TEST_DOMAIN` loop), moved verbatim into a function with local variables, emitting JSON instead of setting globals. Move the explanatory comments with it.

- [ ] **Step 1: Write the failing tests**

Create `tests/net-merge.bats`:

```bash
#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/net-merge.sh"
    D="$BATS_TEST_TMPDIR"
}

profile() {   # <name> <json>
    printf '%s\n' "$2" > "$D/$1.json"
}

@test "merge_ports unions, sorts and lets * absorb" {
    run sbx_net_merge_ports "" "80,443"
    [ "$output" = "80,443" ]
    run sbx_net_merge_ports "443,80" "22,80"
    [ "$output" = "22,80,443" ]
    run sbx_net_merge_ports "80" "*"
    [ "$output" = "*" ]
}

@test "one profile: domains and cidrs carry its ports; default ports are 80,443" {
    profile web '{"dns":"1.1.1.1","allow":["*.google.com","github.com","192.168.1.0/24"]}'
    run sbx_net_merge "$D/web.json"
    [ "$status" -eq 0 ]
    [ "$(jq -c .domains <<< "$output")" = '{"github.com":{"ports":"80,443","upstream":"1.1.1.1"},"google.com":{"ports":"80,443","upstream":"1.1.1.1"}}' ]
    [ "$(jq -c .cidrs <<< "$output")" = '{"192.168.1.0/24":"80,443"}' ]
    [ "$(jq -r .test_domain <<< "$output")" = "github.com" ]
    [ "$(jq -c .upstreams <<< "$output")" = '["1.1.1.1"]' ]
    [ "$(jq -r .allow_all <<< "$output")" = "false" ]
}

@test "stacked profiles pair each destination with its own ports" {
    profile web '{"allow":["github.com"],"ports":[80,443]}'
    profile db  '{"dns":"9.9.9.9","allow":["db.example","github.com","10.0.0.0/8"],"ports":[5432]}'
    run sbx_net_merge "$D/web.json" "$D/db.json"
    [ "$(jq -r '.domains["db.example"].ports' <<< "$output")" = "5432" ]
    [ "$(jq -r '.domains["github.com"].ports' <<< "$output")" = "80,443,5432" ]
    [ "$(jq -r '.cidrs["10.0.0.0/8"]' <<< "$output")" = "5432" ]
}

@test "a domain's upstream is the first profile's that named it" {
    profile a '{"dns":"9.9.9.9","allow":["x.example"]}'
    profile b '{"dns":"8.8.8.8","allow":["x.example","y.example"]}'
    run sbx_net_merge "$D/a.json" "$D/b.json"
    [ "$(jq -r '.domains["x.example"].upstream' <<< "$output")" = "9.9.9.9" ]
    [ "$(jq -r '.domains["y.example"].upstream' <<< "$output")" = "8.8.8.8" ]
    [ "$(jq -c .upstreams <<< "$output")" = '["8.8.8.8","9.9.9.9"]' ]
}

@test "a non-IPv4 or missing dns falls back to 1.1.1.1" {
    profile s '{"dns":"sdns://abc","allow":["x.example"]}'
    run sbx_net_merge "$D/s.json"
    [ "$(jq -r '.domains["x.example"].upstream' <<< "$output")" = "1.1.1.1" ]
}

@test "a wildcard folds its ports into every named domain" {
    profile narrow '{"allow":["db.example"],"ports":[5432]}'
    profile wild   '{"allow":["*"],"ports":["*"]}'
    run sbx_net_merge "$D/narrow.json" "$D/wild.json"
    [ "$(jq -r .allow_all <<< "$output")" = "true" ]
    [ "$(jq -r .allow_all_ports <<< "$output")" = "*" ]
    [ "$(jq -r '.domains["db.example"].ports' <<< "$output")" = "*" ]
}

@test "test_domain skips wildcard entries and comes from the first profile that has a hostname" {
    profile wild '{"allow":["*","10.0.0.0/8"]}'
    profile two  '{"allow":["*.skip.example","first.example","second.example"]}'
    run sbx_net_merge "$D/wild.json" "$D/two.json"
    [ "$(jq -r .test_domain <<< "$output")" = "first.example" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/net-merge.bats`
Expected: all fail — `lib/net-merge.sh: No such file or directory`.

- [ ] **Step 3: Write the library**

Create `lib/net-merge.sh`. Move the explanatory comment block that begins `# --- Composing several net profiles ---` in `sbx` (and the wildcard-folding comment) to the top of `sbx_net_merge`, verbatim.

```bash
#!/bin/bash
# Composition of several net profiles into one set of egress grants.
#
# Sourced by sbx and directly by tests/. Defines functions only — no side
# effects at source time, no dependency on sbx globals.

# Union of two port signatures. "*" absorbs everything.
sbx_net_merge_ports() {   # <sig> <sig>
    local a="$1" b="$2"
    if [[ -z "$a" ]]; then
        echo "$b"
        return 0
    fi
    if [[ "$a" == "*" || "$b" == "*" ]]; then
        echo "*"
        return 0
    fi
    printf '%s\n%s\n' "${a//,/$'\n'}" "${b//,/$'\n'}" | sort -n -u | paste -sd, -
}

sbx_net_merge() {   # <net profile path>...
    # [moved comment block: "--- Composing several net profiles ---" … ]
    local np np_upstream np_ports entry domain cidr k
    local -A domain_ports=() domain_upstream=() cidr_ports=()
    local allow_all=false allow_all_ports="" test_domain=""
    local -a upstreams=()

    for np in "$@"; do
        # DNS upstream must be a plain IP — dnsmasq does not speak DoH stamps.
        # If the profile supplies a stamp or leaves dns empty, fall back to
        # Cloudflare. Resolved per profile: each profile's domains are asked
        # of the resolver that profile named.
        np_upstream=$(jq -r '.dns // empty' "$np")
        if ! [[ "$np_upstream" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            np_upstream="1.1.1.1"
        fi
        upstreams+=("$np_upstream")

        # This profile's port signature, normalised once.
        if jq -e '.ports[]? | select(. == "*")' "$np" >/dev/null 2>&1; then
            np_ports="*"
        else
            np_ports=$(jq -r '.ports[]?' "$np" | sort -n -u | paste -sd, -)
            # Hostnames allowed but no ports specified -> default to web.
            if [[ -z "$np_ports" ]]; then
                np_ports="80,443"
            fi
        fi

        while IFS= read -r entry; do
            if [[ -z "$entry" ]]; then
                continue
            fi
            if [[ "$entry" == "*" ]]; then
                allow_all=true
                allow_all_ports=$(sbx_net_merge_ports "$allow_all_ports" "$np_ports")
                continue
            fi
            # Strips leading '*.' — dnsmasq --server=/domain/up matches the
            # apex plus all subdomains.
            domain="${entry#\*.}"
            domain_ports["$domain"]=$(sbx_net_merge_ports "${domain_ports[$domain]:-}" "$np_ports")
            if [[ -z "${domain_upstream[$domain]:-}" ]]; then
                domain_upstream["$domain"]="$np_upstream"
            fi
        done < <(jq -r '.allow[]? | select(type == "string" and test("^[a-zA-Z*]"))' "$np")

        while IFS= read -r cidr; do
            if [[ -z "$cidr" ]]; then
                continue
            fi
            cidr_ports["$cidr"]=$(sbx_net_merge_ports "${cidr_ports[$cidr]:-}" "$np_ports")
        done < <(jq -r '.allow[]? | select(type == "string" and test("^[0-9]"))' "$np")
    done

    # [moved comment: wildcard folding rationale]
    if [[ "$allow_all" == "true" ]]; then
        for k in "${!domain_ports[@]}"; do
            domain_ports["$k"]=$(sbx_net_merge_ports "${domain_ports[$k]}" "$allow_all_ports")
        done
    fi

    # First hostname from any profile, for the readiness probe.
    for np in "$@"; do
        test_domain=$(jq -r '.allow[]? | select(type=="string" and test("^[a-zA-Z]"))' "$np" | head -n1)
        if [[ -n "$test_domain" ]]; then
            break
        fi
    done

    mapfile -t upstreams < <(printf '%s\n' "${upstreams[@]}" | sort -u)

    {
        for k in "${!domain_ports[@]}"; do
            printf 'd\t%s\t%s\t%s\n' "$k" "${domain_ports[$k]}" "${domain_upstream[$k]}"
        done
        for k in "${!cidr_ports[@]}"; do
            printf 'c\t%s\t%s\n' "$k" "${cidr_ports[$k]}"
        done
    } | jq -S -R -s \
        --argjson allow_all "$allow_all" \
        --arg allow_all_ports "$allow_all_ports" \
        --arg test_domain "$test_domain" \
        '(split("\n") | map(select(length > 0) | split("\t"))) as $rows
         | { upstreams: $ARGS.positional,
             domains: ([$rows[] | select(.[0] == "d") | {key: .[1], value: {ports: .[2], upstream: .[3]}}] | from_entries),
             cidrs: ([$rows[] | select(.[0] == "c") | {key: .[1], value: .[2]}] | from_entries),
             allow_all: $allow_all,
             allow_all_ports: $allow_all_ports,
             test_domain: $test_domain }' \
        --args "${upstreams[@]}"
}
```

Replace the two `[moved comment …]` placeholders with the actual comment text from `sbx` (the "Composing several net profiles" block and the "A wildcard profile authorizes every domain…" block). Do not delete them from `sbx` yet — Task 6 does that.

- [ ] **Step 4: Run the tests**

Run: `bats tests/net-merge.bats`
Expected: 7/7 pass.

- [ ] **Step 5: Shellcheck and commit**

Run: `shellcheck -S error lib/net-merge.sh` — expected silent.

```bash
git add lib/net-merge.sh tests/net-merge.bats
git commit -m "Extract net profile composition into lib/net-merge.sh"
```

---

### Task 5: `lib/resolve.sh` — the plan

**Files:**
- Create: `lib/resolve.sh`
- Create: `tests/resolve.bats`

**Interfaces:**
- Consumes: `sbx_profile_origin` (Task 2), `sbx_profile_check` (Task 3), `sbx_net_merge` (Task 4). `lib/resolve.sh` requires those libraries to be sourced first.
- Produces:
  - `sbx_resolve --launch-dir DIR --config-dir DIR --global-dir DIR [--fs PATH]... [--cli PATH] [--net PATH]... [--host-port N/tcp|N/udp]... [--wd PATH] [--gui]` → prints the plan JSON; returns 0 (problems are in `.errors`), or 2 for an unknown argument.
  - Plan shape (every key always present):
    ```json
    {
      "profiles": [{"type":"fs","name":"sandbox","path":"…","origin":"global"}],
      "errors": ["<file>: <path>: <message>"],
      "warnings": ["<file>: <path>: <message>"],
      "confirm": ["./.sbx/profiles/fs/x.json"],
      "deps": ["core","net","gui","podman"],
      "security": {"caps_keep": false, "caps_profile": "", "userns_full": false,
                   "userns_profile": "", "docker_api": false},
      "mounts": [{"profile":"sandbox","from":"fs/sandbox","source":"/abs","dest":"/workspace",
                  "perm":"rw","present":true}],
      "passthrough": ["TOKEN"],
      "env": [{"name":"EDITOR","value":"vim","from":"cli/dev"}],
      "path": "/usr/local/bin:/usr/bin:/bin",
      "wd": "",
      "gui": false,
      "host_ports": {"tcp": [8080], "udp": []},
      "netns": true,
      "net": {"enabled": false}
    }
    ```
    When `.net.enabled` is true, `.net` also carries every key of `sbx_net_merge`'s output.
  - When `.errors` is non-empty, `security`, `mounts`, `passthrough`, `env`, `host_ports` and `net` keep their empty defaults; `path` is `""`; `deps` is `["core"]`.

Ordering rules (they are what keep the launch byte-identical):
- `mounts`, `passthrough`, `env`: fs profiles in flag order, then the cli profile; within a profile, file order.
- `security`: scanned over fs then cli, skipping project profiles; the *last* profile setting `caps`/`userns` names the `*_profile`.
- `host_ports`: flags plus non-project net profiles' `host_ports`, de-duplicated and sorted numerically.

- [ ] **Step 1: Write the failing tests**

Create `tests/resolve.bats`:

```bash
#!/usr/bin/env bats

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    source "$LIB/profiles.sh"
    source "$LIB/profile-check.sh"
    source "$LIB/net-merge.sh"
    source "$LIB/resolve.sh"
    W="$BATS_TEST_TMPDIR/w"
    PROJ="$W/proj"; CFG="$W/cfg"; GLOBAL="$W/global"; SRC="$W/src"
    mkdir -p "$PROJ/.sbx/profiles/fs" "$PROJ/.sbx/profiles/net" \
             "$CFG/profiles/fs" "$CFG/profiles/cli" "$CFG/profiles/net" "$GLOBAL/fs" "$SRC/present"
    cd "$PROJ"
}

user() {   # <type> <name> <json>
    printf '%s\n' "$3" > "$CFG/profiles/$1/$2.json"
    echo "$CFG/profiles/$1/$2.json"
}

resolve() {   # <args...>
    run sbx_resolve --launch-dir "$PROJ" --config-dir "$CFG" --global-dir "$GLOBAL" "$@"
    [ "$status" -eq 0 ]
    PLAN="$output"
}

q() { jq -c "$1" <<< "$PLAN"; }
r() { jq -r "$1" <<< "$PLAN"; }

@test "an empty launch has core deps, the default PATH and no network" {
    resolve
    [ "$(q .deps)" = '["core"]' ]
    [ "$(r .path)" = "/usr/local/bin:/usr/bin:/bin" ]
    [ "$(r .netns)" = "false" ]
    [ "$(q .net)" = '{"enabled":false}' ]
    [ "$(q .errors)" = '[]' ]
}

@test "unknown arguments return 2" {
    run sbx_resolve --bogus
    [ "$status" -eq 2 ]
}

@test "mounts are expanded, absolutised, attributed, and absence is reported" {
    local fs cli
    export SNAPVAR="$SRC"
    fs=$(user fs m '{"mounts":[{"source":"$SNAPVAR/present","dest":"$HOME/p","perm":"ro"},{"source":"'"$SRC"'/gone","dest":"/g","perm":"ro"},{"source":"'"$SRC"'/newrw","dest":"/n","perm":"rw"}]}')
    cli=$(user cli c '{"mounts":[{"source":"'"$SRC"'/present","dest":"/c","perm":"forked"}]}')
    resolve --fs "$fs" --cli "$cli"
    [ "$(q '.mounts[0]')" = "{\"profile\":\"m\",\"from\":\"fs/m\",\"source\":\"$SRC/present\",\"dest\":\"$HOME/p\",\"perm\":\"ro\",\"present\":true}" ]
    [ "$(r '.mounts[1].present')" = "false" ]
    [ "$(r '.mounts[3].from')" = "cli/c" ]
    [[ "$(r '.warnings[]')" == *"fs/m: mount source not present on this host, skipped: ro $SRC/gone"* ]]
    if [[ "$(r '.warnings[]')" == *"newrw"* ]]; then return 1; fi
}

@test "resolving creates nothing" {
    local fs
    fs=$(user fs m '{"mounts":[{"source":"'"$SRC"'/newrw","dest":"/n","perm":"rw"}]}')
    resolve --fs "$fs"
    [ ! -e "$SRC/newrw" ]
}

@test "env is every assignment in profile order; PATH layers env, cli path and the default" {
    local fs cli
    fs=$(user fs e '{"env":{"SHARED":"fs","PATH":"/fs/bin","N":7}}')
    cli=$(user cli e '{"env":{"SHARED":"cli","HOMEY":"$HOME/x"},"path":["/cli/bin","$HOME/b"]}')
    resolve --fs "$fs" --cli "$cli"
    [ "$(q '[.env[] | [.name, .value, .from]]')" = "[[\"SHARED\",\"fs\",\"fs/e\"],[\"PATH\",\"/fs/bin\",\"fs/e\"],[\"N\",\"7\",\"fs/e\"],[\"SHARED\",\"cli\",\"cli/e\"],[\"HOMEY\",\"$HOME/x\",\"cli/e\"]]" ]
    [ "$(r .path)" = "/cli/bin:$HOME/b:/fs/bin:/usr/local/bin:/usr/bin:/bin" ]
}

@test "env values beginning with a dash survive" {
    local fs
    fs=$(user fs d '{"env":{"FLAG":"-n"}}')
    resolve --fs "$fs"
    [ "$(r '.env[0].value')" = "-n" ]
}

@test "passthrough carries names, never values" {
    local fs
    export SBX_RESOLVE_SECRET=hunter2
    fs=$(user fs p '{"passthrough":["SBX_RESOLVE_SECRET"]}')
    resolve --fs "$fs"
    [ "$(q .passthrough)" = '["SBX_RESOLVE_SECRET"]' ]
    if [[ "$PLAN" == *hunter2* ]]; then return 1; fi
}

@test "caps keep and docker_api set security and the podman dep group" {
    local fs
    fs=$(user fs k '{"caps":"keep","docker_api":true}')
    resolve --fs "$fs"
    [ "$(r .security.caps_keep)" = "true" ]
    [ "$(r .security.caps_profile)" = "$fs" ]
    [ "$(r .security.docker_api)" = "true" ]
    [ "$(q .deps)" = '["core","podman"]' ]
}

@test "userns full without a net profile is an error" {
    local fs
    fs=$(user fs u '{"userns":"full"}')
    resolve --fs "$fs"
    [[ "$(r '.errors[0]')" == *"requires networking"* ]]
}

@test "userns full with net sets caps too" {
    local fs net
    fs=$(user fs u '{"userns":"full"}')
    net=$(user net n '{"allow":["github.com"]}')
    resolve --fs "$fs" --net "$net"
    [ "$(r .security.userns_full)" = "true" ]
    [ "$(r .security.caps_keep)" = "true" ]
    [ "$(r .security.userns_profile)" = "$fs" ]
    [ "$(q .deps)" = '["core","net","podman"]' ]
}

@test "a project profile asking for caps is an error and nothing else is resolved" {
    printf '%s\n' '{"caps":"keep","mounts":[{"source":"/a","dest":"/b","perm":"ro"}]}' > .sbx/profiles/fs/evil.json
    resolve --fs ./.sbx/profiles/fs/evil.json
    [[ "$(r '.errors[0]')" == *"may not set caps"* ]]
    [ "$(q .mounts)" = '[]' ]
    [ "$(r .security.caps_keep)" = "false" ]
    [ "$(r '.profiles[0].origin')" = "project" ]
}

@test "validation errors from every profile are collected" {
    local a b
    a=$(user fs a '{"mount":[]}')
    b=$(user net b '{"ports":["https"]}')
    resolve --fs "$a" --net "$b"
    [ "$(r '.errors | length')" = "2" ]
}

@test "confirm lists only git-tracked project profiles, unless trusted" {
    printf '{}\n' > .sbx/profiles/fs/tracked.json
    printf '{}\n' > .sbx/profiles/fs/loose.json
    git init -q .
    git add -f .sbx/profiles/fs/tracked.json
    resolve --fs ./.sbx/profiles/fs/tracked.json --fs ./.sbx/profiles/fs/loose.json
    [ "$(q .confirm)" = '["./.sbx/profiles/fs/tracked.json"]' ]
    SBX_TRUST_PROJECT_PROFILES=1 resolve --fs ./.sbx/profiles/fs/tracked.json
    [ "$(q .confirm)" = '[]' ]
}

@test "host ports merge flags and profiles, sorted and de-duplicated" {
    local net
    net=$(user net h '{"allow":["x.example"],"host_ports":[5433,"53/udp",8080]}')
    resolve --net "$net" --host-port 8080/tcp --host-port 22/tcp
    [ "$(q .host_ports)" = '{"tcp":[22,5433,8080],"udp":[53]}' ]
    [ "$(r .netns)" = "true" ]
    [ "$(r .net.enabled)" = "true" ]
    [ "$(r '.net.domains["x.example"].ports')" = "80,443" ]
}

@test "host ports alone make a network namespace without a net profile" {
    resolve --host-port 8080/tcp
    [ "$(r .netns)" = "true" ]
    [ "$(r .net.enabled)" = "false" ]
    [ "$(q .deps)" = '["core","net"]' ]
}

@test "--wd and --gui pass through" {
    resolve --wd /work --gui
    [ "$(r .wd)" = "/work" ]
    [ "$(r .gui)" = "true" ]
    [ "$(q .deps)" = '["core","gui"]' ]
}

@test "workingDirectory surfaces as a warning" {
    local fs
    fs=$(user fs w '{"workingDirectory":"/src"}')
    resolve --fs "$fs"
    [[ "$(r '.warnings[0]')" == *".workingDirectory: no longer honored; pass --wd /src instead"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/resolve.bats`
Expected: all fail — `lib/resolve.sh: No such file or directory`.

- [ ] **Step 3: Write the library**

Create `lib/resolve.sh`. When moving logic, bring the rationale comments from `sbx` for: the feature-field scan (`--- Profile feature-field scan (phase 2 virt) ---`), host-service access (`--- Host-service access ---`), and the "rw mounts may point at a persistent host directory" note where relevant.

```bash
#!/bin/bash
# The resolve step: flags and profiles in, one JSON launch plan out.
#
# Everything a launch decides about profiles is decided here, and nothing
# here touches the disk: no directory is created, nothing is seeded, no
# session name is claimed. sbx builds the sandbox from the plan, and
# --dry-run (phase 3) prints it, so the two cannot disagree.
#
# Requires lib/profiles.sh, lib/profile-check.sh and lib/net-merge.sh to be
# sourced first. Defines functions only — no side effects at source time,
# no dependency on sbx globals.

sbx_resolve_strings() {   # <string>... -> JSON array
    if [[ $# -eq 0 ]]; then
        echo '[]'
        return 0
    fi
    jq -cn '$ARGS.positional' --args "$@"
}

sbx_resolve_objects() {   # <json object>... -> JSON array
    if [[ $# -eq 0 ]]; then
        echo '[]'
        return 0
    fi
    printf '%s\n' "$@" | jq -cs .
}

sbx_resolve() {
    local launch_dir="" config_dir="" global_dir="" wd="" gui=false cli=""
    local -a fs=() net=() flag_ports=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --launch-dir) launch_dir="$2"; shift 2 ;;
            --config-dir) config_dir="$2"; shift 2 ;;
            --global-dir) global_dir="$2"; shift 2 ;;
            --fs)         fs+=("$2"); shift 2 ;;
            --cli)        cli="$2"; shift 2 ;;
            --net)        net+=("$2"); shift 2 ;;
            --host-port)  flag_ports+=("$2"); shift 2 ;;
            --wd)         wd="$2"; shift 2 ;;
            --gui)        gui=true; shift ;;
            *)
                echo "sbx_resolve: unknown argument '$1'" >&2
                return 2
                ;;
        esac
    done

    # Every profile in the order the launch applies them: fs, cli, net.
    local -a types=() paths=() origins=()
    local p i
    for p in "${fs[@]}"; do types+=(fs); paths+=("$p"); done
    if [[ -n "$cli" ]]; then
        types+=(cli); paths+=("$cli")
    fi
    for p in "${net[@]}"; do types+=(net); paths+=("$p"); done

    local -a profiles=() errors=() warnings=() confirm=()
    local type origin name level msg
    for i in "${!paths[@]}"; do
        type="${types[$i]}"
        p="${paths[$i]}"
        name=$(basename "$p" .json)
        origin=$(sbx_profile_origin "$p" "$launch_dir" "$config_dir" "$global_dir")
        origins+=("$origin")
        profiles+=("$(jq -cn --arg type "$type" --arg name "$name" --arg path "$p" --arg origin "$origin" \
            '{type: $type, name: $name, path: $path, origin: $origin}')")

        while IFS=$'\t' read -r level msg; do
            case "$level" in
                error)   errors+=("$msg") ;;
                warning) warnings+=("$msg") ;;
            esac
        done < <(sbx_profile_check "$type" "$p" "$origin")

        # A version-controlled project profile arrived with the repository;
        # using it is the user's explicit decision (see confirm_project_profile
        # in sbx). An untracked one is the user's own scratch config.
        if [[ "$origin" == "project" && "${SBX_TRUST_PROJECT_PROFILES:-}" != "1" ]] &&
           git -C "$launch_dir" ls-files --error-unmatch "$p" >/dev/null 2>&1; then
            confirm+=("$p")
        fi
    done

    local caps_keep=false caps_profile="" userns_full=false userns_profile="" docker_api=false
    local -a mounts=() passthrough=() env=() tcp=() udp=()
    local sandbox_path="" netns=false net_json='{"enabled":false}'
    local -a deps=(core)

    if [[ ${#errors[@]} -eq 0 ]]; then
        # [moved comment: feature-field scan rationale]
        for i in "${!paths[@]}"; do
            if [[ "${types[$i]}" == "net" || "${origins[$i]}" == "project" ]]; then
                continue
            fi
            p="${paths[$i]}"
            if [[ "$(jq -r '.userns // empty' "$p")" == "full" ]]; then
                userns_full=true
                userns_profile="$p"
                caps_keep=true
                caps_profile="$p"
            fi
            if [[ "$(jq -r '.caps // empty' "$p")" == "keep" ]]; then
                caps_keep=true
                caps_profile="$p"
            fi
            if [[ "$(jq -r '.docker_api // false' "$p")" == "true" ]]; then
                docker_api=true
            fi
        done
        if [[ "$userns_full" == "true" && ${#net[@]} -eq 0 ]]; then
            errors+=("profile '$userns_profile' sets \"userns\": \"full\", which requires networking. Add --net <profile>.")
        fi
    fi

    if [[ ${#errors[@]} -eq 0 ]]; then
        local m source dest perm present from key value var extra
        for i in "${!paths[@]}"; do
            if [[ "${types[$i]}" == "net" ]]; then
                continue
            fi
            p="${paths[$i]}"
            name=$(basename "$p" .json)
            from="${types[$i]}/$name"

            while IFS= read -r m; do
                if [[ -z "$m" ]]; then
                    continue
                fi
                source=$(jq -r '.source' <<< "$m" | envsubst)
                source=$(realpath -m "$source")
                dest=$(jq -r '.dest' <<< "$m" | envsubst)
                perm=$(jq -r '.perm' <<< "$m")
                present=false
                if [[ -e "$source" ]]; then
                    present=true
                fi
                mounts+=("$(jq -cn --arg profile "$name" --arg from "$from" --arg source "$source" \
                    --arg dest "$dest" --arg perm "$perm" --argjson present "$present" \
                    '{profile: $profile, from: $from, source: $source, dest: $dest, perm: $perm, present: $present}')")
                # An absent rw source is created by the launch, so it is not
                # skipped and not worth a warning.
                if [[ "$present" == "false" && "$perm" != "rw" ]]; then
                    warnings+=("$from: mount source not present on this host, skipped: $perm $source")
                fi
            done < <(jq -c '.mounts[]?' "$p")

            while IFS= read -r var; do
                if [[ -n "$var" ]]; then
                    passthrough+=("$var")
                fi
            done < <(jq -r '.passthrough[]?' "$p")

            # NUL-separated so a value may hold any character, newlines included.
            while IFS= read -r -d '' key && IFS= read -r -d '' value; do
                if [[ -z "$key" ]]; then
                    continue
                fi
                value=$(printf '%s' "$value" | envsubst)
                env+=("$(jq -cn --arg name "$key" --arg value "$value" --arg from "$from" \
                    '{name: $name, value: $value, from: $from}')")
                if [[ "$key" == "PATH" ]]; then
                    sandbox_path="$value"
                fi
            done < <(jq -j 'def nul: [0] | implode; .env // {} | to_entries[] | .key, nul, (.value | tostring), nul' "$p")
        done

        # A cli profile's path entries go in front of any PATH an env block
        # set, and the default always closes the list.
        local default_path="/usr/local/bin:/usr/bin:/bin"
        extra=""
        if [[ -n "$cli" ]]; then
            extra=$(jq -r '.path[]?' "$cli" | envsubst | paste -sd: -)
        fi
        if [[ -n "$extra" ]]; then
            if [[ -n "$sandbox_path" ]]; then
                sandbox_path="$extra:$sandbox_path:$default_path"
            else
                sandbox_path="$extra:$default_path"
            fi
        elif [[ -z "$sandbox_path" ]]; then
            sandbox_path="$default_path"
        fi

        # [moved comment: host-service access rationale]
        local spec port proto
        local -a specs=("${flag_ports[@]}")
        for i in "${!paths[@]}"; do
            if [[ "${types[$i]}" != "net" || "${origins[$i]}" == "project" ]]; then
                continue
            fi
            while IFS= read -r spec; do
                if [[ -n "$spec" ]]; then
                    specs+=("$spec")
                fi
            done < <(jq -r '.host_ports[]? | tostring' "${paths[$i]}")
        done
        for spec in "${specs[@]}"; do
            port="${spec%%/*}"
            proto=tcp
            if [[ "$spec" == */* ]]; then
                proto="${spec#*/}"
            fi
            case "${proto,,}" in
                tcp) tcp+=("$port") ;;
                udp) udp+=("$port") ;;
            esac
        done
        if [[ ${#tcp[@]} -gt 0 ]]; then
            mapfile -t tcp < <(printf '%s\n' "${tcp[@]}" | sort -n -u)
        fi
        if [[ ${#udp[@]} -gt 0 ]]; then
            mapfile -t udp < <(printf '%s\n' "${udp[@]}" | sort -n -u)
        fi

        if [[ ${#net[@]} -gt 0 ]]; then
            net_json=$(sbx_net_merge "${net[@]}" | jq -cS '. + {enabled: true}')
        fi
        if [[ ${#net[@]} -gt 0 || ${#tcp[@]} -gt 0 || ${#udp[@]} -gt 0 ]]; then
            netns=true
            deps+=(net)
        fi
        if [[ "$gui" == "true" ]]; then
            deps+=(gui)
        fi
        if [[ "$caps_keep" == "true" || "$userns_full" == "true" || "$docker_api" == "true" ]]; then
            deps+=(podman)
        fi
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        sandbox_path=""
    fi

    jq -n \
        --argjson profiles "$(sbx_resolve_objects "${profiles[@]}")" \
        --argjson errors "$(sbx_resolve_strings "${errors[@]}")" \
        --argjson warnings "$(sbx_resolve_strings "${warnings[@]}")" \
        --argjson confirm "$(sbx_resolve_strings "${confirm[@]}")" \
        --argjson deps "$(sbx_resolve_strings "${deps[@]}")" \
        --argjson caps_keep "$caps_keep" --arg caps_profile "$caps_profile" \
        --argjson userns_full "$userns_full" --arg userns_profile "$userns_profile" \
        --argjson docker_api "$docker_api" \
        --argjson mounts "$(sbx_resolve_objects "${mounts[@]}")" \
        --argjson passthrough "$(sbx_resolve_strings "${passthrough[@]}")" \
        --argjson env "$(sbx_resolve_objects "${env[@]}")" \
        --arg path "$sandbox_path" --arg wd "$wd" --argjson gui "$gui" \
        --argjson tcp "$(sbx_resolve_strings "${tcp[@]}" | jq -c 'map(tonumber)')" \
        --argjson udp "$(sbx_resolve_strings "${udp[@]}" | jq -c 'map(tonumber)')" \
        --argjson netns "$netns" --argjson net "$net_json" \
        '{profiles: $profiles, errors: $errors, warnings: $warnings, confirm: $confirm, deps: $deps,
          security: {caps_keep: $caps_keep, caps_profile: $caps_profile,
                     userns_full: $userns_full, userns_profile: $userns_profile,
                     docker_api: $docker_api},
          mounts: $mounts, passthrough: $passthrough, env: $env, path: $path,
          wd: $wd, gui: $gui, host_ports: {tcp: $tcp, udp: $udp},
          netns: $netns, net: $net}'
}
```

Replace the three `[moved comment …]` placeholders with the corresponding comment text from `sbx`.

- [ ] **Step 4: Run the tests**

Run: `bats tests/resolve.bats`
Expected: 17/17 pass.

- [ ] **Step 5: Resolve today's fixtures end to end**

Run:
```bash
bash -c 'cd /tmp && source '"$PWD"'/lib/profiles.sh && source '"$PWD"'/lib/profile-check.sh && source '"$PWD"'/lib/net-merge.sh && source '"$PWD"'/lib/resolve.sh && sbx_resolve --launch-dir /tmp --config-dir "$HOME/.config/sbx" --global-dir '"$PWD"'/profiles --fs '"$PWD"'/profiles/fs/sandbox.json --net '"$PWD"'/profiles/net/web.json --net '"$PWD"'/profiles/net/anthropic.json' | jq '{errors, warnings, deps, netns, domains: (.net.domains | keys)}'
```
Expected: no errors; the `*.anthropic.com`, `*.claude.ai`, `*.npmjs.org`, `*.google.com` wildcard warnings; deps `["core","net"]`; netns `true`; a domain list including `github.com`, `anthropic.com`, `localhost`.

- [ ] **Step 6: Shellcheck and commit**

Run: `shellcheck -S error lib/resolve.sh` — expected silent.

```bash
git add lib/resolve.sh tests/resolve.bats
git commit -m "Resolve flags and profiles into a JSON launch plan"
```

---

### Task 6: Launch from the plan

**Files:**
- Modify: `sbx` (sections named below by their current comments/code)
- Modify: `README.md`

**Interfaces:**
- Consumes: `sbx_resolve` and its plan shape (Task 5). `tests/snapshot.bats` goldens (Task 1).
- Produces: no new interface. After this task, `sbx` reads profile content only through `$PLAN`.

The approach is **hydration**: after resolve, set the exact globals the untouched launch code already reads. Do not modify anything from `# Session Initialization` downward except the four blocks listed in Steps 4–7.

- [ ] **Step 1: Confirm the baseline**

Run: `bats tests/snapshot.bats && bats tests/`
Expected: all pass (record the count; it was 179 before Phase 2 plus Tasks 1–5's new tests).

- [ ] **Step 2: Source the libraries**

After the `lib/profiles.sh` source line, add:

```bash
# shellcheck source=lib/profile-check.sh
source "$SCRIPT_DIR/lib/profile-check.sh"
# shellcheck source=lib/net-merge.sh
source "$SCRIPT_DIR/lib/net-merge.sh"
# shellcheck source=lib/resolve.sh
source "$SCRIPT_DIR/lib/resolve.sh"
```

- [ ] **Step 3: Resolve, report, confirm, hydrate**

Replace everything from the line after `sbx_deps_require core || exit 1` down to (not including) the `if [[ "$CAPS_KEEP" == "true" ]]; then` line that prints `retains capabilities` — that is: the confirmation loop, the whole `--- Profile feature-field scan ---` block, the `userns full requires networking` check, the `--- Dependency preflight: optional groups ---` block, the `--- Host-service access ---` block including its loop and de-duplication, and the `SBX_NETNS` computation — with:

```bash
# --- Resolve ---
# Every decision about profiles is made here, from the flags and the profile
# files, without touching the disk (see lib/resolve.sh). Everything after
# this point reads the plan, never a profile file.
RESOLVE_ARGS=(--launch-dir "$PWD" --config-dir "$CONFIG_DIR" --global-dir "$SCRIPT_DIR/profiles")
for profile in "${FS_PROFILES[@]}"; do
    RESOLVE_ARGS+=(--fs "$profile")
done
if [[ -n "$CLI_PROFILE" ]]; then
    RESOLVE_ARGS+=(--cli "$CLI_PROFILE")
fi
for profile in "${NET_PROFILES[@]}"; do
    RESOLVE_ARGS+=(--net "$profile")
done
for port in "${HOST_PORTS_TCP[@]}"; do
    RESOLVE_ARGS+=(--host-port "$port/tcp")
done
for port in "${HOST_PORTS_UDP[@]}"; do
    RESOLVE_ARGS+=(--host-port "$port/udp")
done
if [[ -n "$WORKDIR" ]]; then
    RESOLVE_ARGS+=(--wd "$WORKDIR")
fi
if [[ "$GUI_FLAG" == "true" ]]; then
    RESOLVE_ARGS+=(--gui)
fi
PLAN=$(sbx_resolve "${RESOLVE_ARGS[@]}")

plan_get() {
    jq -r "$1" <<< "$PLAN"
}

while IFS= read -r msg; do
    if [[ -n "$msg" ]]; then
        echo "Warning: $msg" >&2
    fi
done < <(plan_get '.warnings[]')

if [[ "$(plan_get '.errors | length')" != "0" ]]; then
    while IFS= read -r msg; do
        echo "Error: $msg" >&2
    done < <(plan_get '.errors[]')
    exit 1
fi

for profile in "${FS_PROFILES[@]}" "$CLI_PROFILE" "${NET_PROFILES[@]}"; do
    [[ -z "$profile" ]] && continue
    confirm_project_profile "$profile"
done

USERNS_FULL=$(plan_get '.security.userns_full')
USERNS_PROFILE=$(plan_get '.security.userns_profile')
CAPS_KEEP=$(plan_get '.security.caps_keep')
CAPS_PROFILE=$(plan_get '.security.caps_profile')
DOCKER_API=$(plan_get '.security.docker_api')
mapfile -t HOST_PORTS_TCP < <(plan_get '.host_ports.tcp[]')
mapfile -t HOST_PORTS_UDP < <(plan_get '.host_ports.udp[]')
SBX_NETNS=$(plan_get '.netns')

# --- Dependency preflight: optional groups ---
mapfile -t DEP_GROUPS < <(plan_get '.deps[] | select(. != "core")')
if [[ ${#DEP_GROUPS[@]} -gt 0 ]]; then
    sbx_deps_require "${DEP_GROUPS[@]}" || exit 1
fi
if [[ "$USERNS_FULL" == "true" ]] && ! sbx_deps_subids_ok; then
    echo "Error: profile '$USERNS_PROFILE' sets \"userns\": \"full\", which needs a subordinate UID and GID range for $(id -un)." >&2
    echo "  Add one:  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)" >&2
    echo "  (choose a range not already used by another user in /etc/subuid)" >&2
    exit 1
fi
```

(The subid check is the existing block, kept verbatim; the confirmation loop is the existing loop, now after validation so a rejected profile never prompts.)

- [ ] **Step 4: Passthrough from the plan**

Replace the `# Profile-declared passthrough:` loop (the `for profile in "${FS_PROFILES[@]}" "$CLI_PROFILE"` loop reading `.passthrough[]?`), keeping its comment, with:

```bash
while IFS= read -r var; do
    if [[ -n "$var" && -n "${!var-}" ]]; then
        BWRAP_ARGS+=(--setenv "$var" "${!var}")
    fi
done < <(plan_get '.passthrough[]')
```

(Validation guarantees each name matches `^[A-Za-z_][A-Za-z0-9_]*$`, so `${!var}` is safe.)

- [ ] **Step 5: Mounts from the plan**

Replace from `SKIPPED_MOUNTS=()` through the end of the `if [[ ${#SKIPPED_MOUNTS[@]} -gt 0 ]]; then … fi` note block — i.e. the array declarations, `apply_mounts()`, both calls to it, and the skipped-mount note — with the following. Keep the `-try` rationale comment and the "rw mounts may point at…" comment in place, attached to the same code.

```bash
FORKED_MOUNTS=()   # "profile<TAB>source<TAB>dest" — sandbox-owned, seeded once
FORKED_STORES=()   # host store path per forked mount, filled by the seeding loop
RECORD_MOUNTS=()   # "source<TAB>dest" — host-owned, reseeded, changes archived

while IFS= read -r -d '' profile_name && IFS= read -r -d '' source &&
      IFS= read -r -d '' dest && IFS= read -r -d '' perm; do
    # rw mounts may point at a persistent host directory that doesn't
    # exist yet (e.g. first-ever use of a profile's storage dir).
    if [[ "$perm" == "rw" && ! -e "$source" ]]; then
        mkdir -p "$source"
    fi

    # Ensure parent directories exist in the sandbox
    parent=$(dirname "$dest")
    if [[ "$parent" != "/" ]]; then
        IFS='/' read -ra ADDR <<< "$parent"
        curr=""
        for i in "${ADDR[@]}"; do
            if [[ -n "$i" ]]; then
                curr="$curr/$i"
                BWRAP_ARGS+=(--dir "$curr")
            fi
        done
    fi

    # [keep the existing "-try variants" comment here, verbatim]
    case "$perm" in
        ro)     BWRAP_ARGS+=(--ro-bind-try "$source" "$dest") ;;
        rw)     BWRAP_ARGS+=(--bind-try "$source" "$dest") ;;
        dev)    BWRAP_ARGS+=(--dev-bind-try "$source" "$dest") ;;
        forked) FORKED_MOUNTS+=("$profile_name"$'\t'"$source"$'\t'"$dest") ;;
        record) RECORD_MOUNTS+=("$source"$'\t'"$dest") ;;
    esac
done < <(jq -j 'def nul: [0] | implode; .mounts[] | .profile, nul, .source, nul, .dest, nul, .perm, nul' <<< "$PLAN")
```

The `copy` and unknown-perm errors are gone from here: validation reports them before anything runs. The skipped-mount note is replaced by the plan warnings printed in Step 3.

- [ ] **Step 6: Env and PATH from the plan**

Replace from `# Parse Environment from all profiles` through the `BWRAP_ARGS+=(--setenv PATH "$SESSION_DIR/bin:$SANDBOX_PATH")` line with:

```bash
# Environment from profiles: every assignment, in profile order. bwrap keeps
# the last --setenv for a name, which is what makes a later profile win.
while IFS= read -r -d '' key && IFS= read -r -d '' val; do
    BWRAP_ARGS+=(--setenv "$key" "$val")
done < <(jq -j 'def nul: [0] | implode; .env[] | .name, nul, .value, nul' <<< "$PLAN")

if [[ -n "$WORKDIR" ]]; then
    BWRAP_ARGS+=(--chdir "$WORKDIR")
fi

SANDBOX_PATH=$(plan_get '.path')
# $SESSION_DIR/bin holds the docker shim; first on PATH so `docker` always
# resolves to it (the host docker socket is never reachable in a sandbox).
BWRAP_ARGS+=(--setenv PATH "$SESSION_DIR/bin:$SANDBOX_PATH")
```

The `workingDirectory` warning is now a plan warning (Step 3).

- [ ] **Step 7: Net grants from the plan**

Inside `if [[ ${#NET_PROFILES[@]} -gt 0 ]]; then`, replace everything from the `# --- Composing several net profiles ---` comment through the end of the `# First hostname from any profile, for the readiness probe.` loop — **except** the `# Assign every distinct port signature its own set name…` block, which stays — with the hydration below, placed where the declarations were. The comments moved to `lib/net-merge.sh` in Task 4; leave a one-line pointer.

```bash
    # Composition rules for stacked net profiles live in lib/net-merge.sh.
    declare -A DOMAIN_PORTS=()      # domain -> port signature ("*" or "80,443")
    declare -A DOMAIN_UPSTREAM=()   # domain -> resolver that profile chose
    declare -A CIDR_PORTS=()        # cidr   -> port signature
    while IFS=$'\t' read -r domain sig upstream; do
        DOMAIN_PORTS["$domain"]="$sig"
        DOMAIN_UPSTREAM["$domain"]="$upstream"
    done < <(plan_get '.net.domains | to_entries[] | [.key, .value.ports, .value.upstream] | @tsv')
    while IFS=$'\t' read -r cidr sig; do
        CIDR_PORTS["$cidr"]="$sig"
    done < <(plan_get '.net.cidrs | to_entries[] | [.key, .value] | @tsv')
    ALLOW_ALL=$(plan_get '.net.allow_all')
    ALLOW_ALL_PORTS=$(plan_get '.net.allow_all_ports')
    mapfile -t DNS_UPSTREAMS < <(plan_get '.net.upstreams[]')
    DNS_UPSTREAM="${DNS_UPSTREAMS[0]}"
    TEST_DOMAIN=$(plan_get '.net.test_domain')
```

The `PORTS_SETNAME` block and the `resolv.conf` write that follow stay unchanged. Delete the in-`sbx` `merge_ports()` function — nothing calls it now. The host-ports-only `else` branch stays as it is.

- [ ] **Step 8: Verify no profile is read after resolve**

Run:
```bash
awk '/^PLAN=\$\(sbx_resolve/ {found=1} found' sbx | grep -nE 'jq [^<]*"\$(profile|np|CLI_PROFILE|p)"' || echo "no profile reads after resolve"
grep -nE 'apply_mounts|merge_ports|require_tools|p_userns|p_caps|SKIPPED_MOUNTS' sbx || echo "old code gone"
```
Expected: `no profile reads after resolve` (the `--reseed` block reads join sidecars, which are not profiles; if its `jq -r '.forked_stores[]?'` line appears, that is correct and expected) and `old code gone`.

- [ ] **Step 9: Snapshots must be identical**

Run: `bats tests/snapshot.bats`
Expected: 7/7 pass with **no** `SBX_UPDATE_SNAPSHOTS`. A diff here is a behavior change: find which hydrated value differs (compare `jq` of the plan against what the old block computed) and fix the hydration or the resolver — never regenerate the goldens in this task.

- [ ] **Step 10: Full suite and shellcheck**

Run: `bats tests/ && shellcheck -S error sbx lib/*.sh`
Expected: everything passes; shellcheck silent. Particular suites to watch: `hardening.bats` ("may not set"), `project-profiles.bats` (prompt still raised for a tracked valid profile, refused non-interactively), `persistent-cli.bats` and `copy-mounts.bats` (forked/record), `join.bats` (sidecar path/workdir).

- [ ] **Step 11: Behavior checks by hand**

Run:
```bash
mkdir -p /tmp/sbxv && cd /tmp/sbxv
mkdir -p .sbx/profiles/fs .sbx/profiles/net
echo '{"mount":[],"caps":"keep"}' > .sbx/profiles/fs/bad.json
echo '{"ports":["https"]}' > .sbx/profiles/net/bad.json
SBX_TRUST_PROJECT_PROFILES=1 ~/git/sandbox-gemini/sbx --fs bad --net bad -- /bin/true; echo "exit=$?"
ls ~/.local/state/sbx/sessions/ 2>/dev/null | grep -c sbxv || true
cd / && rm -rf /tmp/sbxv
```
Expected: three `Error:` lines — `.mount: unknown field for a fs profile`, `.caps: project profiles may not set caps; …`, `.ports[0]: expected a port 1-65535 or "*", got "https"` — each prefixed with its file, then `exit=1`, and `0` sessions named `sbxv`.

- [ ] **Step 12: Document validation**

In `README.md`, directly after the `### Creating Custom Profiles` list, add:

```markdown
### Profile validation

Every profile a launch uses is checked before anything is built, and every
problem is reported at once:

    ~/.config/sbx/profiles/net/api.json: .ports[1]: expected a port 1-65535 or "*", got "https"

**Errors stop the launch.** Invalid JSON; a field that is not in the schema
for the profile's type (there is no comment syntax — a misspelt field would
otherwise be silently ignored); a wrong type or value (`perm`, `caps`,
`userns`, `docker_api`, `ports`, `host_ports`, `allow`, `passthrough`
names, `env` values); and, in a project profile, `caps`, `userns`,
`docker_api` or `host_ports`. An `allow` entry that starts with a digit is
read as an address, so a hostname like `1password.com` is rejected rather
than silently treated as a malformed CIDR.

**Warnings are printed and the launch continues:** a `workingDirectory`
field, a `dns` value that is not a bare IPv4 address (1.1.1.1 is used), a
mount whose source does not exist on this host (the mount is skipped), and
a `*.` wildcard in `allow`.
```

- [ ] **Step 13: Commit**

```bash
git add sbx README.md
git commit -m "Launch from the resolved plan instead of re-reading profiles"
```

---

## Open items outside this plan

- `--dry-run` (Phase 3) will print the plan and add `plan.writes`; it needs the env winners derived from `plan.env` and port signatures rendered for display.
- The `--gui` path has no snapshot. If Phase 3 changes GUI argument assembly, add a stubbed xpra that creates a real Unix socket under a private `/tmp/.X11-unix` bind — out of scope here.
- `sbx-profile check` (Phase 4) will call `sbx_profile_check` directly.
