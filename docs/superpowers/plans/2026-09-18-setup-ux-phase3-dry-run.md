# Setup UX Phase 3: `sbx --dry-run` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `sbx --dry-run [--json] <launch flags>` shows everything a launch would do — profiles, security, mounts, environment, network, every host location it writes, missing dependencies, confirmations, warnings and errors — without creating anything, prompting, or launching, and exits non-zero when the real launch would stop.

**Architecture:** The resolve step (Phase 2) already builds the plan. This phase adds three read-only pieces around it: `lib/state-paths.sh` (the forked-store path, the session name, and the list of host writes, shared with the launch so the two cannot disagree), `sbx_deps_status` in `lib/deps.sh` (a report-only form of the dependency check), and `lib/render.sh` (one jq program that turns plan + writes + needs into text). `sbx` gains a `--dry-run` flag that exits right after resolve, before any state directory, confirmation prompt or session exists.

**Tech Stack:** bash 5, jq 1.7+, bats 1.14, shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-16-setup-ux-design.md` — "Phase 3: `sbx --dry-run`". Phases 1 and 2 are complete on this branch.

## Global Constraints

- `shellcheck -S error sbx lib/*.sh` must be silent. Pre-existing sub-error warnings in `sbx` are not a gate.
- `bats tests/snapshot.bats` must pass WITHOUT `SBX_UPDATE_SNAPSHOTS=1` after every task. This phase must not change anything a real launch generates.
- `--dry-run` creates nothing: not `$STATE_DIR` (`~/.local/state/sbx`), not a forked store, not an absent `rw` source, not a session. It never prompts, never runs the one-time store migration, never starts xpra, pasta or bwrap (other than the read-only user-namespace probe).
- Exit status of `--dry-run`: `0` when the real launch would proceed; `1` when it would stop (validation errors, missing required tools, failed user-namespace probe, missing subordinate IDs for `userns: full`); `2` for misuse (`--dry-run` combined with `--gc`, `--reseed`, `--join`, `--attach`, `--changes`, `--list-sessions`, `--list-profiles` or `--doctor`).
- Dry-run output goes to stdout. `--dry-run --json` prints one JSON document: the plan plus `writes` and `needs`.
- Passthrough variables are shown by name only, never by value.
- Profile-authored text (paths, env names and values, domains, warnings, errors) is printed with C0 control characters, DEL and C1 control characters removed. UTF-8 text is kept.
- Library files define functions and constants only — no side effects at source time, no dependency on `sbx` globals (inputs arrive as arguments).
- In library code, use `if` statements, never `[[ … ]] && cmd`, as a loop body's last command or a function's last command.
- bats: `! cmd` is only an assertion on a test's last line; elsewhere use `if …; then return 1; fi`. Tests that run `sbx` use a short `mktemp -d /tmp/sbxh.XXXXXX` root, cleaned in `teardown`.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WWTpUZ8XwVF2wUzAUMreDD
  ```

## Decisions recorded for implementers

- **`writes` is computed outside `sbx_resolve`**, by `sbx_state_writes`, and only for a dry run. A launch does not need it, and sizing a forked source with `du` on every launch would slow launches down.
- **The spec's "qemu images" row is dropped.** No code in `sbx` writes `virt/images`; a qemu profile's image directory is its own `rw` mount and appears as a host write. **The "learning report" row belongs to Phase 5.**
- **Deferred Phase 2 suggestions not done here:** collapsing `sbx`'s `${#NET_PROFILES[@]}` branches onto the plan, and splitting `sbx_resolve`. Neither is needed for the dry run, and the first would touch snapshot-guarded launch code for no feature.
- **`PATH` is shown on its own line**, not in the env list: the launch overwrites any profile `PATH` with the computed one.
- **`--dry-run` is parsed like any other flag.** Anything after the command word or after `--` belongs to the payload, so `sbx --fs x mytool --dry-run` still passes `--dry-run` to `mytool`, as today.

## File Structure

- Create `lib/state-paths.sh` — `sbx_state_session_base`, `sbx_state_forked_store` (Task 1), `sbx_state_write_row`, `sbx_state_writes` (Task 3). Test: `tests/state-paths.bats`.
- Modify `lib/deps.sh` — add `sbx_deps_status` (Task 2). Test: `tests/deps.bats`.
- Create `lib/render.sh` — `sbx_sanitize_message` (moved from `sbx`), `SBX_RENDER_JQ`, `sbx_render_plan` (Task 4). Test: `tests/render.bats`.
- Modify `sbx` — use the state-path functions (Task 1); source `lib/render.sh` and drop its own `sbx_sanitize_message` (Task 4); state init as a function, `--dry-run` flag, dry-run exit point, usage (Task 5). Test: `tests/dry-run.bats`.
- Modify `README.md` — `--dry-run` (Task 5).

---

### Task 1: `lib/state-paths.sh` — session name and forked-store path

**Files:**
- Create: `lib/state-paths.sh`
- Create: `tests/state-paths.bats`
- Modify: `sbx` — source the library after `lib/copy-mounts.sh`; replace the `SESSION_BASE=…` computation and the body of `sbx_forked_store`

**Interfaces:**
- Consumes: `sbx_copy_path_slug`, `sbx_copy_mount_id` from `lib/copy-mounts.sh`.
- Produces:
  - `sbx_state_session_base <launch_dir>` → prints the session name base (lowercased basename, characters outside `a-z0-9._-` replaced by `-`, cut to 32, leading/trailing `-` trimmed, `sbx` if empty, `.` or `..`)
  - `sbx_state_forked_store <state_dir> <launch_dir> <profile> <dest>` → prints `<state_dir>/forked/<profile>/<slug of launch_dir>/<mount id of dest>`

This is a move. Both values are already computed in `sbx`; making them library functions lets `--dry-run` print exactly what a launch would use.

- [ ] **Step 1: Write the failing tests**

Create `tests/state-paths.bats`:

```bash
#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/copy-mounts.sh"
    source "$BATS_TEST_DIRNAME/../lib/state-paths.sh"
}

@test "session base lowercases and replaces unsafe characters" {
    run sbx_state_session_base "/tmp/x/My Project!"
    [ "$output" = "my-project" ]
}

@test "session base keeps dots, dashes and underscores" {
    run sbx_state_session_base "/tmp/x/a.b_c-d"
    [ "$output" = "a.b_c-d" ]
}

@test "session base is cut to 32 characters" {
    run sbx_state_session_base "/tmp/x/abcdefghijklmnopqrstuvwxyz0123456789"
    [ "$output" = "abcdefghijklmnopqrstuvwxyz012345" ]
}

@test "session base falls back to sbx for empty and dot-dot" {
    run sbx_state_session_base "/"
    [ "$output" = "sbx" ]
    run sbx_state_session_base "/tmp/x/-.."
    [ "$output" = "sbx" ]
}

@test "forked store path is keyed by profile, launch directory and destination" {
    run sbx_state_forked_store /s /home/u/proj pi /home/u/.pi
    [ "$output" = "/s/forked/pi/-home-u-proj/_home_u_.pi" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/state-paths.bats`
Expected: all fail — `lib/state-paths.sh: No such file or directory`.

- [ ] **Step 3: Write the library**

Create `lib/state-paths.sh`. Move the explanatory comment above `SESSION_BASE=` in `sbx` (from `# Session name. Derived from the launch directory's basename` through `# the name reclaimed.`, and the `"." and ".."` comment) onto `sbx_state_session_base`, and the comment above `sbx_forked_store` onto `sbx_state_forked_store`. Leave a one-line pointer in `sbx` in their place.

```bash
#!/bin/bash
# Where sbx keeps things on the host: the session name, forked stores, and
# (for --dry-run) the list of every host location a launch will write.
#
# The launch and --dry-run both call these, so what a dry run reports is
# what the launch uses. Requires lib/copy-mounts.sh (sbx_copy_path_slug,
# sbx_copy_mount_id). Defines functions only — no side effects at source
# time, no dependency on sbx globals: every directory is an argument.

# [moved comment: session name rationale]
sbx_state_session_base() {   # <launch_dir>
    local base
    base=$(printf '%s' "$(basename "$1")" |
           tr '[:upper:]' '[:lower:]' |
           tr -c 'a-z0-9._-' '-' |
           cut -c1-32)
    base="${base#-}"
    base="${base%-}"
    # [moved comment: "." and ".." fall back to the default name]
    if [[ -z "$base" || "$base" == "." || "$base" == ".." ]]; then
        base="sbx"
    fi
    printf '%s\n' "$base"
}

# [moved comment: forked store path must never disagree with --reseed]
sbx_state_forked_store() {   # <state_dir> <launch_dir> <profile> <dest>
    printf '%s\n' "$1/forked/$3/$(sbx_copy_path_slug "$2")/$(sbx_copy_mount_id "$4")"
}
```

Replace each `[moved comment …]` placeholder with the actual comment text from `sbx`.

The algorithm must match today's `sbx` exactly — the snapshot suite depends on it. Do not "improve" it.

- [ ] **Step 4: Run the unit tests**

Run: `bats tests/state-paths.bats`
Expected: 5/5 pass.

- [ ] **Step 5: Use the library from `sbx`**

After `source "$SCRIPT_DIR/lib/copy-mounts.sh"` add:

```bash
# shellcheck source=lib/state-paths.sh
source "$SCRIPT_DIR/lib/state-paths.sh"
```

Replace the block from `SESSION_BASE=$(printf '%s' "$(basename "$PWD")" |` through the closing `fi` of the `"." and ".."` fallback with:

```bash
# Naming rules live in lib/state-paths.sh, shared with --dry-run.
SESSION_BASE=$(sbx_state_session_base "$PWD")
```

Replace the body of `sbx_forked_store()` with:

```bash
sbx_forked_store() {   # <profile> <dest>
    sbx_state_forked_store "$STATE_DIR" "$PWD" "$1" "$2"
}
```

- [ ] **Step 6: Verify nothing a launch generates changed**

Run: `bats tests/snapshot.bats tests/state-paths.bats tests/sessions.bats tests/persistent-cli.bats && shellcheck -S error sbx lib/*.sh`
Expected: all pass (snapshots unchanged, no regeneration); shellcheck silent.

- [ ] **Step 7: Commit**

```bash
git add lib/state-paths.sh tests/state-paths.bats sbx
git commit -m "Move session naming and forked-store paths into lib/state-paths.sh"
```

---

### Task 2: `sbx_deps_status` — a report-only dependency check

**Files:**
- Modify: `lib/deps.sh` (append)
- Modify: `tests/deps.bats` (append)

**Interfaces:**
- Consumes: `sbx_deps_missing`, `sbx_deps_install_hint`, `sbx_deps_family`, `sbx_deps_userns_check`, `sbx_deps_subids_ok`, `sbx_deps_json_list` (all existing in `lib/deps.sh`).
- Produces: `sbx_deps_status [--subids] <group>...` → prints one line of JSON and returns 0:
  ```json
  {"groups":{"core":[],"net":["pasta"]},"userns":true,"subids":null,"install":["sudo pacman -S passt"],"ok":false}
  ```
  - `groups`: the requested groups, each with its missing tools.
  - `userns`: `true`/`false` from the probe when `core` is requested and `bwrap` is on PATH; otherwise `null`.
  - `subids`: `true`/`false` when `--subids` is given; otherwise `null`.
  - `install`: install command lines for everything missing (one line for a known family, three for unknown).
  - `ok`: `false` if anything is missing, `userns` is `false`, or `subids` is `false`.

`lib/deps.sh` must keep its contract: bash builtins plus `awk` and `id` only — no `jq`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/deps.bats` (it already defines `os_release`, `fake_bwrap`, `fake_sysctl`, `doctor_bin` and `$FIX`):

```bash
@test "status: everything present is ok" {
    doctor_bin bwrap
    fake_bwrap 0
    PATH="$FIX/bin" run sbx_deps_status core net
    [ "$status" -eq 0 ]
    [ "$(jq -c .groups <<< "$output")" = '{"core":[],"net":[]}' ]
    [ "$(jq -r .userns <<< "$output")" = "true" ]
    [ "$(jq -r .subids <<< "$output")" = "null" ]
    [ "$(jq -c .install <<< "$output")" = '[]' ]
    [ "$(jq -r .ok <<< "$output")" = "true" ]
}

@test "status: a missing tool is listed with the distro's command, and returns 0" {
    doctor_bin bwrap pasta
    fake_bwrap 0
    os_release "$FIX/os" manjaro arch
    PATH="$FIX/bin" SBX_OS_RELEASE="$FIX/os" run sbx_deps_status core net
    [ "$status" -eq 0 ]
    [ "$(jq -c .groups.net <<< "$output")" = '["pasta"]' ]
    [ "$(jq -r '.install[0]' <<< "$output")" = "sudo pacman -S passt" ]
    [ "$(jq -r .ok <<< "$output")" = "false" ]
}

@test "status: a failing probe is reported, not printed" {
    doctor_bin bwrap
    fake_bwrap 1 "bwrap: nope"
    mkdir -p "$FIX/sys"
    PATH="$FIX/bin" SBX_PROC_SYS="$FIX/sys" run sbx_deps_status core
    [ "$status" -eq 0 ]
    [ "$(jq -r .userns <<< "$output")" = "false" ]
    [ "$(jq -r .ok <<< "$output")" = "false" ]
}

@test "status: the probe does not run without core" {
    doctor_bin bwrap
    fake_bwrap 1 "bwrap: nope"
    PATH="$FIX/bin" run sbx_deps_status net
    [ "$(jq -r .userns <<< "$output")" = "null" ]
    [ "$(jq -r .ok <<< "$output")" = "true" ]
}

@test "status: --subids reports a missing range" {
    doctor_bin bwrap
    fake_bwrap 0
    : > "$FIX/subuid"; : > "$FIX/subgid"
    PATH="$FIX/bin" SBX_SUBUID="$FIX/subuid" SBX_SUBGID="$FIX/subgid" run sbx_deps_status --subids core podman
    [ "$(jq -r .subids <<< "$output")" = "false" ]
    [ "$(jq -r .ok <<< "$output")" = "false" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/deps.bats`
Expected: the 5 new tests fail with `sbx_deps_status: command not found`; the existing ones still pass.

- [ ] **Step 3: Implement**

Append to `lib/deps.sh`:

```bash
# Report-only form of sbx_deps_require, for --dry-run: which of the given
# groups' tools are missing, whether the user-namespace probe passes (only
# when core is requested and bwrap exists), and whether subordinate IDs
# exist (only with --subids). Prints one JSON object and returns 0 either
# way — .ok carries the verdict, so the caller can show everything before
# deciding its exit status.
sbx_deps_status() {   # [--subids] <group>...
    local want_subids=false group ok=true userns=null subids=null groups_json=""
    local -a missing all_missing=() hint=()
    if [[ "${1:-}" == "--subids" ]]; then
        want_subids=true
        shift
    fi
    for group in "$@"; do
        mapfile -t missing < <(sbx_deps_missing "$group")
        if [[ -n "$groups_json" ]]; then
            groups_json+=","
        fi
        groups_json+="\"$group\":$(sbx_deps_json_list "${missing[@]}")"
        all_missing+=("${missing[@]}")
    done
    if [[ ${#all_missing[@]} -gt 0 ]]; then
        ok=false
        mapfile -t hint < <(sbx_deps_install_hint "$(sbx_deps_family)" "${all_missing[@]}")
    fi
    if [[ " $* " == *" core "* ]] && command -v bwrap >/dev/null 2>&1; then
        if sbx_deps_userns_check >/dev/null; then
            userns=true
        else
            userns=false
            ok=false
        fi
    fi
    if [[ "$want_subids" == "true" ]]; then
        if sbx_deps_subids_ok; then
            subids=true
        else
            subids=false
            ok=false
        fi
    fi
    printf '{"groups":{%s},"userns":%s,"subids":%s,"install":%s,"ok":%s}\n' \
        "$groups_json" "$userns" "$subids" "$(sbx_deps_json_list "${hint[@]}")" "$ok"
}
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/deps.bats`
Expected: all pass (the previous count plus 5).

- [ ] **Step 5: Shellcheck and commit**

Run: `shellcheck -S error lib/deps.sh` — expected silent.

```bash
git add lib/deps.sh tests/deps.bats
git commit -m "Add a report-only dependency status for --dry-run"
```

---

### Task 3: `sbx_state_writes` — every host location a launch writes

**Files:**
- Modify: `lib/state-paths.sh` (append)
- Modify: `tests/state-paths.bats` (append)

**Interfaces:**
- Consumes: `sbx_state_session_base`, `sbx_state_forked_store` (Task 1); `sbx_copy_path_slug`, `sbx_copy_mount_id`; the Phase 2 plan's `.mounts[]` (`profile`, `from`, `source`, `dest`, `perm`, `present`) and `.security` (`caps_keep`, `userns_full`, `docker_api`).
- Produces:
  - `sbx_state_write_row <kind> <path> <detail> <dest> <note>` → one compact JSON object `{kind, path, detail, dest, note}`
  - `sbx_state_writes <plan json> <state_dir> <launch_dir>` → a JSON array of those rows, in this order: one row per mount that writes (in plan order), then one `archived` row if any `record` mount exists, then the podman store row if any, then the session directory row. Reads the disk (existence checks, `du`); writes nothing.

Row rules:

| mount / condition | kind | path | note |
|---|---|---|---|
| `forked`, source present, store exists | `persistent` | the forked store | `exists` |
| `forked`, source present, store absent | `persistent` | the forked store | `will seed, <du -sh of source>` |
| `forked`, source absent | *(no row — the launch skips it)* | | |
| `record` | `temporary` | `<state>/work/<session-id>/<mount id>` | `""` |
| any `record` mount (once) | `archived` | `<state>/changes/<slug>/<stamp>-<session-id>/` | `""` |
| `rw`, source present | `host` | the source | `""` |
| `rw`, source absent | `host` | the source | `created at launch` |
| `dev`, source present | `host` | the source | `""` |
| `dev` absent, `ro` | *(no row)* | | |
| `userns_full` | `persistent` | `<state>/virt/containers-full` | `""` |
| else `caps_keep` or `docker_api` | `persistent` | `<state>/virt/containers` | `""` |
| always | `temporary` | `<state>/sessions/<session base>/` | `""` |

`dest` is the mount's destination for mount rows and `""` otherwise.

- [ ] **Step 1: Write the failing tests**

Append to `tests/state-paths.bats`:

```bash
# A minimal Phase 2 plan with the given mounts (JSON array) and security flags.
plan() {   # <mounts json> [caps_keep] [userns_full] [docker_api]
    jq -cn --argjson mounts "$1" \
        --argjson ck "${2:-false}" --argjson uf "${3:-false}" --argjson da "${4:-false}" \
        '{mounts: $mounts, security: {caps_keep: $ck, userns_full: $uf, docker_api: $da}}'
}

mount() {   # <perm> <source> <dest> <present>
    jq -cn --arg perm "$1" --arg source "$2" --arg dest "$3" --argjson present "$4" \
        '{profile: "p", from: "fs/p", source: $source, dest: $dest, perm: $perm, present: $present}'
}

setup_writes() {
    W="$BATS_TEST_TMPDIR/w"
    STATE="$W/state"; LAUNCH="$W/My Proj"; SRC="$W/src"
    mkdir -p "$SRC/tree" "$LAUNCH"
    echo hi > "$SRC/tree/f"
}

@test "writes: a forked mount will seed, then exists" {
    setup_writes
    run sbx_state_writes "$(plan "[$(mount forked "$SRC/tree" /t true)]")" "$STATE" "$LAUNCH"
    [ "$status" -eq 0 ]
    store=$(sbx_state_forked_store "$STATE" "$LAUNCH" p /t)
    [ "$(jq -r '.[0].kind' <<< "$output")" = "persistent" ]
    [ "$(jq -r '.[0].path' <<< "$output")" = "$store" ]
    [ "$(jq -r '.[0].dest' <<< "$output")" = "/t" ]
    [[ "$(jq -r '.[0].note' <<< "$output")" == "will seed, "* ]]
    mkdir -p "$store"
    run sbx_state_writes "$(plan "[$(mount forked "$SRC/tree" /t true)]")" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[0].note' <<< "$output")" = "exists" ]
}

@test "writes: an absent forked source, a ro mount and an absent dev mount write nothing" {
    setup_writes
    run sbx_state_writes "$(plan "[$(mount forked "$SRC/gone" /g false),$(mount ro "$SRC/tree" /r true),$(mount dev /nonexistent /d false)]")" "$STATE" "$LAUNCH"
    [ "$(jq -r 'map(.kind) | join(",")' <<< "$output")" = "temporary" ]
}

@test "writes: record mounts get a working copy each and one archive" {
    setup_writes
    run sbx_state_writes "$(plan "[$(mount record "$SRC/tree" /a true),$(mount record "$SRC/tree" /b true)]")" "$STATE" "$LAUNCH"
    [ "$(jq -r 'map(.kind) | join(",")' <<< "$output")" = "temporary,temporary,archived,temporary" ]
    [ "$(jq -r '.[0].path' <<< "$output")" = "$STATE/work/<session-id>/_a" ]
    [ "$(jq -r '.[2].path' <<< "$output")" = "$STATE/changes/$(sbx_copy_path_slug "$LAUNCH")/<stamp>-<session-id>/" ]
}

@test "writes: rw and dev binds are host writes; an absent rw source is created at launch" {
    setup_writes
    run sbx_state_writes "$(plan "[$(mount rw "$SRC/tree" /w true),$(mount rw "$SRC/new" /n false),$(mount dev /dev/null /dn true)]")" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[0] | [.kind, .path, .note] | join("|")' <<< "$output")" = "host|$SRC/tree|" ]
    [ "$(jq -r '.[1].note' <<< "$output")" = "created at launch" ]
    [ "$(jq -r '.[2].path' <<< "$output")" = "/dev/null" ]
}

@test "writes: podman stores follow caps, docker api and userns full" {
    setup_writes
    run sbx_state_writes "$(plan '[]' true false false)" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[0].path' <<< "$output")" = "$STATE/virt/containers" ]
    run sbx_state_writes "$(plan '[]' false false true)" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[0].path' <<< "$output")" = "$STATE/virt/containers" ]
    run sbx_state_writes "$(plan '[]' true true false)" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[0].path' <<< "$output")" = "$STATE/virt/containers-full" ]
    [ "$(jq -r 'length' <<< "$output")" = "2" ]
}

@test "writes: the session directory is always last, named like the launch" {
    setup_writes
    run sbx_state_writes "$(plan '[]')" "$STATE" "$LAUNCH"
    [ "$(jq -r '.[-1].path' <<< "$output")" = "$STATE/sessions/my-proj/" ]
}

@test "writes: computing the list creates nothing" {
    setup_writes
    run sbx_state_writes "$(plan "[$(mount forked "$SRC/tree" /t true),$(mount rw "$SRC/new" /n false),$(mount record "$SRC/tree" /r true)]")" "$STATE" "$LAUNCH"
    [ "$status" -eq 0 ]
    [ ! -e "$STATE" ]
    [ ! -e "$SRC/new" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/state-paths.bats`
Expected: the 7 new tests fail with `sbx_state_writes: command not found`; Task 1's 5 pass.

- [ ] **Step 3: Implement**

Append to `lib/state-paths.sh`:

```bash
sbx_state_write_row() {   # <kind> <path> <detail> <dest> <note>
    jq -cn --arg kind "$1" --arg path "$2" --arg detail "$3" --arg dest "$4" --arg note "$5" \
        '{kind: $kind, path: $path, detail: $detail, dest: $dest, note: $note}'
}

# Every host location a launch of this plan writes, for --dry-run. Reads
# the disk (does a forked store exist yet? how big is the source it would
# be seeded from?) and writes nothing. Session IDs and archive timestamps
# are assigned at launch, so they appear as <session-id> and <stamp>.
sbx_state_writes() {   # <plan json> <state_dir> <launch_dir>
    local plan="$1" state="$2" launch="$3" slug base
    local profile source dest perm present from store size note record_seen=false
    local -a rows=()
    slug=$(sbx_copy_path_slug "$launch")
    base=$(sbx_state_session_base "$launch")

    while IFS= read -r -d '' profile && IFS= read -r -d '' source &&
          IFS= read -r -d '' dest && IFS= read -r -d '' perm &&
          IFS= read -r -d '' present && IFS= read -r -d '' from; do
        case "$perm" in
            forked)
                # An absent source is skipped outright at launch: no store.
                if [[ "$present" != "true" ]]; then
                    continue
                fi
                store=$(sbx_state_forked_store "$state" "$launch" "$profile" "$dest")
                if [[ -e "$store" ]]; then
                    note="exists"
                else
                    size=$(du -sh "$source" 2>/dev/null | cut -f1)
                    note="will seed, ${size:-unknown size}"
                fi
                rows+=("$(sbx_state_write_row persistent "$store" \
                    "forked store for $dest from $from; kept until --reseed" "$dest" "$note")")
                ;;
            record)
                rows+=("$(sbx_state_write_row temporary "$state/work/<session-id>/$(sbx_copy_mount_id "$dest")" \
                    "record working copy of $source; removed at teardown" "$dest" "")")
                record_seen=true
                ;;
            rw)
                note=""
                if [[ "$present" != "true" ]]; then
                    note="created at launch"
                fi
                rows+=("$(sbx_state_write_row host "$source" "read-write bind at $dest from $from" "$dest" "$note")")
                ;;
            dev)
                if [[ "$present" == "true" ]]; then
                    rows+=("$(sbx_state_write_row host "$source" "device bind at $dest from $from" "$dest" "")")
                fi
                ;;
        esac
    done < <(jq -j 'def nul: [0] | implode;
        .mounts[] | .profile, nul, .source, nul, .dest, nul, .perm, nul, (.present | tostring), nul, .from, nul' <<< "$plan")

    if [[ "$record_seen" == "true" ]]; then
        rows+=("$(sbx_state_write_row archived "$state/changes/$slug/<stamp>-<session-id>/" \
            "files the session created or changed in record mounts; the newest SBX_KEEP_CHANGES (default 10) are kept" "" "")")
    fi

    if [[ "$(jq -r '.security.userns_full' <<< "$plan")" == "true" ]]; then
        rows+=("$(sbx_state_write_row persistent "$state/virt/containers-full" \
            "podman image and container store (userns full)" "" "")")
    elif [[ "$(jq -r '.security.caps_keep or .security.docker_api' <<< "$plan")" == "true" ]]; then
        rows+=("$(sbx_state_write_row persistent "$state/virt/containers" \
            "podman image and container store" "" "")")
    fi

    rows+=("$(sbx_state_write_row temporary "$state/sessions/$base/" \
        "session directory; removed at teardown (-N is appended if the name is in use)" "" "")")

    printf '%s\n' "${rows[@]}" | jq -cs .
}
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/state-paths.bats`
Expected: 12/12 pass.

- [ ] **Step 5: Shellcheck, snapshots, commit**

Run: `shellcheck -S error sbx lib/*.sh && bats tests/snapshot.bats` — expected silent and 7/7.

```bash
git add lib/state-paths.sh tests/state-paths.bats
git commit -m "List every host location a launch writes, for --dry-run"
```

---

### Task 4: `lib/render.sh` — the dry-run text output

**Files:**
- Create: `lib/render.sh`
- Create: `tests/render.bats`
- Modify: `sbx` — source `lib/render.sh`; delete its own `sbx_sanitize_message` function (and move that function's comment into the library)

**Interfaces:**
- Consumes: a *dry-run document*: the Phase 2 plan plus `writes` (Task 3's array) and `needs` (Task 2's object).
- Produces:
  - `sbx_sanitize_message <text>` → moved verbatim from `sbx` (printable ASCII plus tab, capped at 500 characters). The launch's warning loop keeps using it.
  - `SBX_RENDER_JQ` — the jq program
  - `sbx_render_plan <document json> <home>` → prints the text report; `<home>` is abbreviated to `~` at the start of paths

Output format — each section title is padded to 10 characters, then a space; continuation lines are indented the same; empty sections are omitted; sections in this order:

```
Profiles   cli/pi (user)  fs/sandbox (global)
Security   capabilities dropped · no userns · no docker API
Mounts     ro      ~/.nvm → ~/.nvm  cli/pi
           forked  ~/.pi → ~/.pi  (will seed, 12M)  cli/pi
           skip    /opt/missing → /opt/x  (source absent)  fs/sandbox
Env        EDITOR=vim  (cli/dev; overrides fs/x)
Path       /usr/local/bin:/usr/bin:/bin
Passthru   ANTHROPIC_API_KEY
Network    dns 1.1.1.1
           ports 80,443: github.com, google.com
           addresses: 192.168.1.0/24 (ports 80,443)
           host ports: tcp 8080
Writes     persistent ~/.local/state/sbx/forked/pi/-home-u-proj/_home_u_.pi  (forked store for ~/.pi from cli/pi; kept until --reseed; will seed, 12M)
           temporary  ~/.local/state/sbx/sessions/proj/  (session directory; …)
Needs      core ✓ · net ✗ missing pasta · userns ✓
           install: sudo pacman -S passt
Confirm    ./.sbx/profiles/fs/tst.json would prompt
Warnings   …
Errors     …
Result     the launch would stop
```

Every output line has C0 control characters, DEL and C1 control characters (U+0080–U+009F) removed; other Unicode (✓, ✗, →, ·, and UTF-8 in paths) is kept.

- [ ] **Step 1: Write the failing tests**

Create `tests/render.bats`:

```bash
#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/render.sh"
    H=/home/u
}

# A complete dry-run document; pass a jq expression to modify it.
doc() {   # [jq update]
    jq -cn '{
      profiles: [{type:"fs",name:"sandbox",path:"/g/fs/sandbox.json",origin:"global"},
                 {type:"cli",name:"pi",path:"/home/u/.config/sbx/profiles/cli/pi.json",origin:"user"}],
      errors: [], warnings: [], confirm: [],
      deps: ["core"],
      security: {caps_keep:false, caps_profile:"", userns_full:false, userns_profile:"", docker_api:false},
      mounts: [], passthrough: [], env: [],
      path: "/usr/local/bin:/usr/bin:/bin", wd: "", gui: false,
      host_ports: {tcp: [], udp: []}, netns: false, net: {enabled: false},
      writes: [{kind:"temporary", path:"/home/u/.local/state/sbx/sessions/proj/", detail:"session directory", dest:"", note:""}],
      needs: {groups:{core:[]}, userns:true, subids:null, install:[], ok:true}
    }' | jq -c "${1:-.}"
}

render() {   # [jq update]
    run sbx_render_plan "$(doc "${1:-.}")" "$H"
    [ "$status" -eq 0 ]
}

line() {   # <prefix> -> the first output line starting with it
    printf '%s\n' "$output" | grep -m1 -F -- "$1"
}

@test "sanitize strips escapes and carriage returns and caps length" {
    run sbx_sanitize_message "$(printf 'a\033[2K\rb')"
    [ "$output" = "a[2Kb" ]
    run sbx_sanitize_message "$(printf 'x%.0s' {1..600})"
    [ "${#output}" -eq 503 ]
}

@test "profiles and security" {
    render
    [ "$(line Profiles)" = "Profiles   fs/sandbox (global)  cli/pi (user)" ]
    [ "$(line Security)" = "Security   capabilities dropped · no userns · no docker API" ]
    render '.security = {caps_keep:true, caps_profile:"/home/u/.config/sbx/profiles/fs/k.json", userns_full:true, userns_profile:"x", docker_api:true}'
    [ "$(line Security)" = "Security   capabilities KEPT (~/.config/sbx/profiles/fs/k.json) · userns full · docker API" ]
}

@test "mounts show perm, paths, note and origin; absent sources are skipped" {
    render '.mounts = [
        {profile:"pi",from:"cli/pi",source:"/home/u/.pi",dest:"/home/u/.pi",perm:"forked",present:true},
        {profile:"s",from:"fs/s",source:"/opt/missing",dest:"/opt/x",perm:"ro",present:false},
        {profile:"s",from:"fs/s",source:"/home/u/new",dest:"/n",perm:"rw",present:false}]
      | .writes = [{kind:"persistent",path:"/s/forked",detail:"forked store",dest:"/home/u/.pi",note:"will seed, 12M"},
                   {kind:"host",path:"/home/u/new",detail:"rw bind",dest:"/n",note:"created at launch"}]'
    [ "$(line Mounts)" = "Mounts     forked  ~/.pi → ~/.pi  (will seed, 12M)  cli/pi" ]
    printf '%s\n' "$output" | grep -qxF "           skip    /opt/missing → /opt/x  (source absent)  fs/s"
    printf '%s\n' "$output" | grep -qxF "           rw      ~/new → /n  (created at launch)  fs/s"
}

@test "env shows the winning value and what it overrides; PATH has its own line" {
    render '.env = [{name:"A",value:"1",from:"fs/x"},{name:"PATH",value:"/p",from:"fs/x"},{name:"A",value:"2",from:"cli/c"}]'
    [ "$(line Env)" = "Env        A=2  (cli/c; overrides fs/x)" ]
    if printf '%s\n' "$output" | grep -q 'PATH=/p'; then return 1; fi
    [ "$(line Path)" = "Path       /usr/local/bin:/usr/bin:/bin" ]
}

@test "passthrough is names only" {
    render '.passthrough = ["TOKEN","TOKEN","KEY"]'
    [ "$(line Passthru)" = "Passthru   KEY, TOKEN" ]
}

@test "network groups domains by ports and lists addresses and host ports" {
    render '.netns = true
      | .net = {enabled:true, upstreams:["1.1.1.1"],
                domains:{"github.com":{ports:"80,443",upstream:"1.1.1.1"},
                         "google.com":{ports:"80,443",upstream:"1.1.1.1"},
                         "db.example":{ports:"5432",upstream:"1.1.1.1"}},
                cidrs:{"10.0.0.0/8":"5432"}, allow_all:false, allow_all_ports:"", test_domain:"github.com"}
      | .host_ports = {tcp:[8080], udp:[53]}'
    [ "$(line Network)" = "Network    dns 1.1.1.1" ]
    printf '%s\n' "$output" | grep -qxF "           ports 5432: db.example"
    printf '%s\n' "$output" | grep -qxF "           ports 80,443: github.com, google.com"
    printf '%s\n' "$output" | grep -qxF "           addresses: 10.0.0.0/8 (ports 5432)"
    printf '%s\n' "$output" | grep -qxF "           host ports: tcp 8080; udp 53"
}

@test "network without a namespace, and host ports without a net profile" {
    render
    [ "$(line Network)" = "Network    none (no network namespace)" ]
    render '.netns = true | .host_ports = {tcp:[8080], udp:[]}'
    [ "$(line Network)" = "Network    no internet; host ports only" ]
    printf '%s\n' "$output" | grep -qxF "           host ports: tcp 8080"
}

@test "writes, needs, confirm and result" {
    render '.needs = {groups:{core:[], net:["pasta"]}, userns:true, subids:false, install:["sudo pacman -S passt"], ok:false}
      | .confirm = ["./.sbx/profiles/fs/t.json"]'
    [ "$(line Writes)" = "Writes     temporary  ~/.local/state/sbx/sessions/proj/  (session directory)" ]
    [ "$(line Needs)" = "Needs      core ✓ · net ✗ missing pasta · userns ✓ · subuid/subgid ✗" ]
    printf '%s\n' "$output" | grep -qxF "           install: sudo pacman -S passt"
    [ "$(line Confirm)" = "Confirm    ./.sbx/profiles/fs/t.json would prompt" ]
    [ "$(line Result)" = "Result     the launch would stop" ]
}

@test "errors are listed, the plan sections are omitted, and the launch would stop" {
    render '.errors = ["/p.json: .mount: unknown field for a fs profile"]'
    [ "$(line Errors)" = "Errors     /p.json: .mount: unknown field for a fs profile" ]
    if printf '%s\n' "$output" | grep -q '^Security'; then return 1; fi
    [ "$(line Result)" = "Result     the launch would stop" ]
}

@test "a clean plan would proceed" {
    render
    [ "$(line Result)" = "Result     the launch would proceed" ]
}

@test "control characters in profile-authored text are removed; unicode is kept" {
    render '.warnings = ["bad[2K\rtextend"] | .env = [{name:"U",value:"héllo",from:"fs/x"}]'
    [ "$(line Warnings)" = "Warnings   bad[2Ktextend" ]
    [ "$(line Env)" = "Env        U=héllo  (fs/x)" ]
}

@test "home is abbreviated only as a whole path component" {
    render '.mounts = [{profile:"s",from:"fs/s",source:"/home/u2/x",dest:"/home/u",perm:"ro",present:true}]'
    [ "$(line Mounts)" = "Mounts     ro      /home/u2/x → ~  fs/s" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/render.bats`
Expected: all fail — `lib/render.sh: No such file or directory`.

- [ ] **Step 3: Write the library**

Create `lib/render.sh`. Move `sbx_sanitize_message` and its comment from `sbx` verbatim (updating "Phase 3's --dry-run is another consumer" to say the dry run uses the jq `clean` filter below, which keeps UTF-8).

```bash
#!/bin/bash
# Human-readable output: the launch's warning sanitizer, and the --dry-run
# report.
#
# Defines functions and constants only — no side effects at source time,
# no dependency on sbx globals.

# [moved comment and function: sbx_sanitize_message, verbatim from sbx]
sbx_sanitize_message() {   # <text>
    local msg="$1" clean
    clean=$(LC_ALL=C tr -cd '\11\40-\176' <<< "$msg")
    if [[ ${#clean} -gt 500 ]]; then
        clean="${clean:0:500}..."
    fi
    printf '%s' "$clean"
}

# The --dry-run report. Input: the plan from lib/resolve.sh plus .writes
# (lib/state-paths.sh) and .needs (lib/deps.sh). Every line passes through
# `clean`, which removes C0 controls, DEL and C1 controls — the bytes a
# terminal can act on — while keeping printable Unicode, because paths,
# env values and warnings come from profiles and profiles may come from a
# cloned repository.
# shellcheck disable=SC2016  # jq program: $vars are jq's, not the shell's
SBX_RENDER_JQ='
def clean: explode | map(select((. >= 32 and . < 127) or . > 159)) | implode;
def spaces($n): [range(0; $n)] | map(" ") | join("");
def pad($n): . + spaces($n - length);
def tilde:
  if $home != "" and . == $home then "~"
  elif $home != "" and startswith($home + "/") then "~" + .[($home | length):]
  else . end;
def section($title; $lines):
  $lines | to_entries[]
  | ((if .key == 0 then $title else "" end) | pad(10)) + " " + .value;
def mark($ok): if $ok then "✓" else "✗" end;

. as $d
| ( section("Profiles"; [ [ $d.profiles[] | "\(.type)/\(.name) (\(.origin))" ] | join("  ") | select(length > 0) ]),

    ( if ($d.errors | length) == 0 then
        section("Security"; [ [ (if $d.security.caps_keep then "capabilities KEPT (\($d.security.caps_profile | tilde))" else "capabilities dropped" end),
                                (if $d.security.userns_full then "userns full" else "no userns" end),
                                (if $d.security.docker_api then "docker API" else "no docker API" end) ] | join(" · ") ])
      else empty end ),

    section("Mounts"; [ $d.mounts[] as $m
        | ($d.writes | map(select(.dest == $m.dest and .note != "")) | .[0]) as $w
        | ((if ($m.present | not) and $m.perm != "rw" then "skip" else $m.perm end) | pad(7))
          + " " + ($m.source | tilde) + " → " + ($m.dest | tilde)
          + ( if ($m.present | not) and $m.perm != "rw" then "  (source absent)"
              elif $w != null then "  (\($w.note))"
              else "" end )
          + "  " + $m.from ]),

    section("Env"; [ $d.env | map(select(.name != "PATH")) | group_by(.name)[]
        | .[-1] as $win
        | "\($win.name)=\($win.value)  (\($win.from)"
          + (.[:-1] | map(.from) | unique | if length > 0 then "; overrides " + join(", ") else "" end)
          + ")" ]),

    section("Path"; [ $d.path | select(length > 0) ]),

    section("Passthru"; [ $d.passthrough | unique | select(length > 0) | join(", ") ]),

    ( if ($d.errors | length) > 0 then empty
      elif ($d.netns | not) then section("Network"; ["none (no network namespace)"])
      else section("Network"; [
          ( if $d.net.enabled then "dns " + ($d.net.upstreams | join(", ")) else "no internet; host ports only" end ),
          ( ($d.net.domains // {}) | to_entries | group_by(.value.ports)[]
              | "ports \(.[0].value.ports): " + (map(.key) | join(", ")) ),
          ( ($d.net.cidrs // {}) | to_entries | select(length > 0)
              | "addresses: " + (map("\(.key) (ports \(.value))") | join(", ")) ),
          ( if $d.net.allow_all then "any domain (ports \($d.net.allow_all_ports))" else empty end ),
          ( [ ($d.host_ports.tcp | select(length > 0) | "tcp " + (map(tostring) | join(","))),
              ($d.host_ports.udp | select(length > 0) | "udp " + (map(tostring) | join(","))) ]
            | select(length > 0) | "host ports: " + join("; ") )
        ]) end ),

    section("Writes"; [ $d.writes[]
        | (.kind | pad(10)) + " " + (.path | tilde)
          + "  (" + .detail + (if .note != "" then "; " + .note else "" end) + ")" ]),

    section("Needs"; [
        ( [ ($d.needs.groups | to_entries[]
              | if (.value | length) == 0 then "\(.key) ✓" else "\(.key) ✗ missing \(.value | join(" "))" end),
            (if $d.needs.userns == null then empty else "userns \(mark($d.needs.userns))" end),
            (if $d.needs.subids == null then empty else "subuid/subgid \(mark($d.needs.subids))" end)
          ] | join(" · ") ),
        ( $d.needs.install[] | "install: " + . )
      ]),

    section("Confirm"; [ $d.confirm[] | tilde + " would prompt" ]),
    section("Warnings"; $d.warnings),
    section("Errors"; $d.errors),
    section("Result"; [ if ($d.errors | length) == 0 and $d.needs.ok
                        then "the launch would proceed" else "the launch would stop" end ])
  )
| clean
'

sbx_render_plan() {   # <dry-run document json> <home>
    jq -r --arg home "$2" "$SBX_RENDER_JQ" <<< "$1"
}
```

Replace the `[moved comment and function …]` placeholder with the comment from `sbx`. The function body above is already the verbatim copy.

- [ ] **Step 4: Run the tests**

Run: `bats tests/render.bats`
Expected: 12/12 pass. If the jq program fails to compile, every test fails with a jq error — fix the program, not the tests. Where a test's expected text disagrees with the format in this task's "Output format" block, the format block wins; fix the test and say so in the report.

- [ ] **Step 5: Use it from `sbx`**

After the `lib/state-paths.sh` source line add:

```bash
# shellcheck source=lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"
```

Delete `sbx_sanitize_message()` and its comment block from `sbx`. The warning loop keeps calling it by name.

- [ ] **Step 6: Verify**

Run: `bats tests/render.bats tests/snapshot.bats tests/project-profiles.bats && shellcheck -S error sbx lib/*.sh`
Expected: all pass; shellcheck silent.

- [ ] **Step 7: Commit**

```bash
git add lib/render.sh tests/render.bats sbx
git commit -m "Render a resolved plan as the --dry-run report"
```

---

### Task 5: `sbx --dry-run`

**Files:**
- Modify: `sbx` — state initialization as a function; `--dry-run [--json]` flag; misuse refusal; the dry-run exit point; `usage`
- Modify: `README.md`
- Create: `tests/dry-run.bats`

**Interfaces:**
- Consumes: `sbx_resolve` and `plan_get` (Phase 2), `sbx_deps_status` (Task 2), `sbx_state_writes` (Task 3), `sbx_render_plan` (Task 4).
- Produces: the user-facing `--dry-run` behavior in Global Constraints.

- [ ] **Step 1: Write the failing tests**

Create `tests/dry-run.bats`:

```bash
#!/usr/bin/env bats

# sbx --dry-run: what a launch would do, without doing any of it.

setup_file() {
    # A copy of /usr/bin as symlinks, so a test can remove one tool.
    BASE_BIN="$BATS_FILE_TMPDIR/bin"
    mkdir -p "$BASE_BIN"
    local f
    for f in /usr/bin/* /usr/local/bin/*; do
        if [[ -x "$f" && ! -e "$BASE_BIN/${f##*/}" ]]; then
            ln -s "$f" "$BASE_BIN/${f##*/}"
        fi
    done
    export BASE_BIN
}

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/proj"
    mkdir -p "$HOME/.config/sbx/profiles/fs" "$HOME/.config/sbx/profiles/cli" "$PROJ" "$ROOT/src"
    echo data > "$ROOT/src/f"
    printf 'ID=manjaro\nID_LIKE=arch\n' > "$ROOT/arch"
}

teardown() {
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]]; then
        rm -rf "$ROOT"
    fi
}

dry() {   # <sbx args...>
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --dry-run "$@"
}

nothing_created() {
    if [[ -e "$HOME/.local/state/sbx" ]]; then
        echo "dry run created $HOME/.local/state/sbx:" >&2
        find "$HOME/.local/state/sbx" >&2
        return 1
    fi
}

@test "a clean dry run reports the plan, creates nothing and exits 0" {
    dry --fs sandbox
    [ "$status" -eq 0 ]
    [[ "$output" == *"Profiles   fs/sandbox (global)"* ]]
    [[ "$output" == *"Result     the launch would proceed"* ]]
    nothing_created
}

@test "--json prints one parseable document with writes and needs" {
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>/dev/null' _ "$PROJ" "$SBX" --dry-run --json --fs sandbox
    [ "$status" -eq 0 ]
    [ "$(jq -r '.needs.ok' <<< "$output")" = "true" ]
    [ "$(jq -r '.writes[-1].kind' <<< "$output")" = "temporary" ]
    [ "$(jq -r '.profiles[0].name' <<< "$output")" = "sandbox" ]
    nothing_created
}

@test "a validation error is reported and exits 1" {
    echo '{"mount":[]}' > "$HOME/.config/sbx/profiles/fs/bad.json"
    dry --fs bad
    [ "$status" -eq 1 ]
    [[ "$output" == *".mount: unknown field for a fs profile"* ]]
    [[ "$output" == *"Result     the launch would stop"* ]]
    nothing_created
}

@test "a missing dependency is reported with the install command and exits 1" {
    mkdir -p "$ROOT/bin"
    cp -a "$BASE_BIN/." "$ROOT/bin/"
    rm "$ROOT/bin/pasta"
    run env PATH="$ROOT/bin" SBX_OS_RELEASE="$ROOT/arch" \
        bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --dry-run --net web
    [ "$status" -eq 1 ]
    [[ "$output" == *"net ✗ missing pasta"* ]]
    [[ "$output" == *"install: sudo pacman -S passt"* ]]
    nothing_created
}

@test "a forked mount shows will seed, then exists" {
    cat > "$HOME/.config/sbx/profiles/cli/keep.json" <<EOF
{"mounts":[{"source":"$ROOT/src","dest":"/data","perm":"forked"}]}
EOF
    dry --cli keep
    [ "$status" -eq 0 ]
    [[ "$output" == *"forked  $ROOT/src → /data  (will seed, "* ]]
    nothing_created
    slug=$(printf '%s' "$PROJ" | tr '/' '-')
    mkdir -p "$HOME/.local/state/sbx/forked/keep/$slug/_data"
    dry --cli keep
    [[ "$output" == *"forked  $ROOT/src → /data  (exists)"* ]]
}

@test "passthrough values never appear" {
    echo '{"passthrough":["SBX_DRY_SECRET"]}' > "$HOME/.config/sbx/profiles/fs/pt.json"
    export SBX_DRY_SECRET=hunter2
    dry --fs pt
    [[ "$output" == *"Passthru   SBX_DRY_SECRET"* ]]
    if [[ "$output" == *hunter2* ]]; then return 1; fi
}

@test "a tracked project profile does not prompt" {
    mkdir -p "$PROJ/.sbx/profiles/fs"
    echo '{"description":"t"}' > "$PROJ/.sbx/profiles/fs/t.json"
    git -C "$PROJ" init -q
    git -C "$PROJ" add -f .sbx/profiles/fs/t.json
    dry --fs t
    [ "$status" -eq 0 ]
    [[ "$output" == *"Confirm    ./.sbx/profiles/fs/t.json would prompt"* ]]
    if [[ "$output" == *"refusing to use a project profile"* ]]; then return 1; fi
    nothing_created
}

@test "--dry-run refuses to combine with state commands, in either order" {
    dry --gc
    [ "$status" -eq 2 ]
    [[ "$output" == *"--dry-run applies only to a launch"* ]]
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --gc --dry-run
    [ "$status" -eq 2 ]
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --fs sandbox --reseed --dry-run
    [ "$status" -eq 2 ]
    nothing_created
}

@test "a real launch still initializes state" {
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --list-sessions
    [ -d "$HOME/.local/state/sbx" ]
}
```

- [ ] **Step 2: Confirm the flag does not exist yet — without running the suite**

Do NOT run `tests/dry-run.bats` before implementing: today `--dry-run` is not an option, so `sbx` takes it as the payload command and attempts a real launch.

Run: `./sbx --help | grep -c -- --dry-run`
Expected: `0`.

- [ ] **Step 3: Make state initialization a function**

In `sbx`, move the top-level `mkdir -p "$STATE_DIR"` (with its `# Ensure state directory exists` comment) and the whole one-time store migration block (the comment starting `# One-time relocation of the pre-\`forked\` cli store` through its closing `fi`) into one function, defined where the migration block used to be:

```bash
# Creates the state directory and finishes any interrupted one-time store
# migration. Every path runs this before touching state — except --dry-run,
# which must create nothing.
sbx_state_init() {
    mkdir -p "$STATE_DIR"

    # [the migration block's comment, verbatim]
    if [[ -d "$STATE_DIR/profiles/cli" ]]; then
        local old_store new_store
        for old_store in "$STATE_DIR/profiles/cli"/*; do
            [[ -d "$old_store" ]] || continue
            new_store="$STATE_DIR/forked/$(basename "$old_store")"
            if [[ -e "$new_store" ]]; then
                echo "Warning: both $old_store and $new_store exist; leaving the old store in place — reconcile manually." >&2
                continue
            fi
            mkdir -p "$STATE_DIR/forked"
            mv "$old_store" "$new_store"
        done
        rmdir "$STATE_DIR/profiles/cli" "$STATE_DIR/profiles" 2>/dev/null || true
    fi
}

# --dry-run applies only to a launch. Each command that acts on state calls
# this with its own remaining arguments, so the combination is refused in
# either order: "--dry-run --gc" is caught through DRY_RUN, "--gc --dry-run"
# through the scan (which stops at --, where the payload's arguments begin).
sbx_refuse_dry_run() {   # <this command> <remaining args...>
    local cmd="$1" arg
    shift
    if [[ "$DRY_RUN" != "true" ]]; then
        for arg in "$@"; do
            if [[ "$arg" == "--" ]]; then
                break
            fi
            if [[ "$arg" == "--dry-run" ]]; then
                DRY_RUN=true
                break
            fi
        done
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "Error: --dry-run applies only to a launch; it cannot be combined with $cmd." >&2
        exit 2
    fi
}
```

Before the argument loop (next to `GUI_FLAG=false`), add:

```bash
DRY_RUN=false
DRY_RUN_JSON=false
```

- [ ] **Step 4: Call them from every command branch**

At the very start of each of these argument-loop branches, add the two calls (substituting the flag name):

```bash
            sbx_refuse_dry_run --gc "${@:2}"
            sbx_state_init
```

Branches: `--doctor`, `--list-profiles`, `--gc`, `--list-sessions`, `--changes`, `--join`, `--attach`. In `-h|--help` add only `sbx_state_init` (help with `--dry-run` just prints help). This keeps each of those commands' behavior exactly as it was: before this change the state directory and migration had already run by the time any of them executed.

Add a branch for the flag itself, next to `--gui`:

```bash
        --dry-run)
            DRY_RUN=true
            shift
            if [[ "${1:-}" == "--json" ]]; then
                DRY_RUN_JSON=true
                shift
            fi
            ;;
```

Immediately after the argument loop (before `if [[ ${#COMMAND[@]} -eq 0 ]]; then`), add:

```bash
if [[ "$RESEED" == "true" && "$DRY_RUN" == "true" ]]; then
    echo "Error: --dry-run applies only to a launch; it cannot be combined with --reseed." >&2
    exit 2
fi
if [[ "$DRY_RUN" != "true" ]]; then
    sbx_state_init
fi
```

- [ ] **Step 5: The core check under a dry run**

Replace `sbx_deps_require core || exit 1` (under `# --- Dependency preflight: core ---`) with:

```bash
if [[ "$DRY_RUN" == "true" ]]; then
    # Resolving needs the core tools (jq, realpath, envsubst) to exist at
    # all. Everything else — the user-namespace probe, optional groups —
    # is reported in the dry-run output instead of stopping it.
    if [[ -n "$(sbx_deps_missing core)" ]]; then
        sbx_deps_require core || exit 1
    fi
else
    sbx_deps_require core || exit 1
fi
```

- [ ] **Step 6: The dry-run exit point**

Immediately after the `plan_get() { … }` definition (and before the `# Errors are never profile-authored trust decisions` block), add:

```bash
# --- Dry run ---
# Everything below this point acts: prompts, creates state, launches. A dry
# run stops here with the plan, the host locations it would write, and the
# dependency check in report-only form.
if [[ "$DRY_RUN" == "true" ]]; then
    DRY_DEPS_ARGS=()
    if [[ "$(plan_get '.security.userns_full')" == "true" ]]; then
        DRY_DEPS_ARGS+=(--subids)
    fi
    mapfile -t DRY_GROUPS < <(plan_get '.deps[]')
    DRY_NEEDS=$(sbx_deps_status "${DRY_DEPS_ARGS[@]}" "${DRY_GROUPS[@]}")
    DRY_WRITES=$(sbx_state_writes "$PLAN" "$STATE_DIR" "$PWD")
    DRY_DOC=$(jq -c --argjson needs "$DRY_NEEDS" --argjson writes "$DRY_WRITES" \
        '. + {needs: $needs, writes: $writes}' <<< "$PLAN")
    if [[ "$DRY_RUN_JSON" == "true" ]]; then
        jq . <<< "$DRY_DOC"
    else
        sbx_render_plan "$DRY_DOC" "$HOME"
    fi
    if [[ "$(jq -r '(.errors | length) == 0 and .needs.ok' <<< "$DRY_DOC")" == "true" ]]; then
        exit 0
    fi
    exit 1
fi
```

- [ ] **Step 7: Usage**

In `usage`, after the `--gui` line, add:

```
  --dry-run [--json]     Show what this launch would do, without doing it
                         (exits 1 if the launch would stop)
```

- [ ] **Step 8: Run the new tests**

Run: `bats tests/dry-run.bats`
Expected: 9/9 pass.

- [ ] **Step 9: Full suite, snapshots, shellcheck**

Run: `bats tests/ && shellcheck -S error sbx lib/*.sh`
Expected: everything passes (snapshots unregenerated); shellcheck silent. Watch `sessions.bats` (`--list-sessions`, `--gc`), `join.bats` (`--join`, `--attach`), `persistent-cli.bats` (the store migration, which now runs inside `sbx_state_init`).

- [ ] **Step 10: Document**

In `README.md`, add a row to the Common Commands table after `--doctor`:

```markdown
| `--dry-run [--json]` | Show everything this launch would do — profiles, mounts, environment, network grants, every host location it would write, missing dependencies, confirmations, warnings and errors — without creating, prompting or launching anything. Exits 1 if the real launch would stop. |
```

Add a section directly after the "Profile validation" section:

```markdown
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
```

- [ ] **Step 11: Commit**

```bash
git add sbx README.md tests/dry-run.bats
git commit -m "Add sbx --dry-run"
```

---

## Open items outside this plan

- Phase 5's learning report will add a `writes` row (`~/.local/state/sbx/learn/<slug>/<stamp>-<session-id>/`) and a `network: OPEN (learning)` security marker to the render.
- `sbx-profile` (Phase 4) can suggest `sbx --dry-run` with the new profile as its "next step" line.
