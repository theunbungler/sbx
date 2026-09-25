# Setup UX Phase 4: `sbx-profile` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new `sbx-profile` command that lists profiles with their origin and shadowing (`ls`), validates them (`check`), and creates new ones from a safe template or an existing profile, in the right place and never overwriting (`new`).

**Architecture:** `sbx-profile` is a small bash script beside `sbx`. It sources the existing libraries (`lib/profiles.sh` for lookup, origin and listing; `lib/profile-check.sh` for validation; `lib/render.sh` for sanitizing printed text) and adds a few pure helpers to `lib/profiles.sh` (name and type checks, templates, restricted-field detection, shadowing). `sbx --list-profiles` keeps calling the same listing function, which gains a shadowing marker.

**Tech Stack:** bash 5, jq 1.7+, bats 1.14, shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-16-setup-ux-design.md` — "Phase 4: `sbx-profile`". Phases 1–3 are complete on this branch.

## Global Constraints

- `shellcheck -S error sbx sbx-profile lib/*.sh` must be silent.
- `bats tests/snapshot.bats` passes WITHOUT `SBX_UPDATE_SNAPSHOTS=1` after every task: nothing a real launch generates may change.
- `sbx-profile` never writes the global profile directory, never overwrites an existing file (no `--force`), and writes only after the new profile validates.
- `--local` writes `./.sbx/profiles/<type>/`; `--user` writes `~/.config/sbx/profiles/<type>/`. With neither: prompt when stdin is a terminal; otherwise exit 2 with an error naming both flags.
- Templates grant nothing: cli `{description, env: {}, passthrough: [], mounts: []}`; fs `{description, mounts: []}`; net `{description, dns: "1.1.1.1", allow: [], ports: [443]}`.
- `--local --from <profile>` is refused if the source sets `caps`, `userns`, `docker_api` or `host_ports`, naming which.
- Profile-authored text printed by `sbx-profile` (validation messages, names) goes through `sbx_sanitize_message`.
- Exit status: `0` success; `1` refused or a profile has validation errors; `2` usage errors.
- The project-profile trust rule is unchanged (the user decided to keep it): an untracked `./.sbx` profile is used without confirmation, a tracked one prompts. `sbx-profile new --local` says so when it writes one.
- Library files define functions only — no side effects at source time, no dependency on `sbx` globals.
- In library code, `if` statements rather than `[[ … ]] && cmd` as a loop body's or function's last command.
- bats: `! cmd` is only an assertion on a test's last line; elsewhere use `if …; then return 1; fi`. Tests use a short `mktemp -d /tmp/sbxh.XXXXXX` root with `HOME` inside it, cleaned in `teardown`. No test runs a real `sbx` launch.
- A commit hook rejects the user's login name in tracked files; write home paths as `~/…` in docs.
- Commit messages end with exactly:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WWTpUZ8XwVF2wUzAUMreDD
  ```

## Decisions recorded for implementers

- **`--from-learn` moves to Phase 5.** It imports a learning report, and learning reports do not exist until Phase 5 builds them. So does its test.
- **The dry-run orchestration stays inline in `sbx`.** A Phase 3 reviewer suggested a library function so `sbx-profile` could reuse it; `sbx-profile` only *suggests* `sbx --dry-run`, so it has no need of one yet.
- **Profile names** are one path component: `^[A-Za-z0-9_][A-Za-z0-9._-]*$`. This keeps `new` from writing outside its directory (`../x`, `a/b`, `.hidden` are refused).
- **Validation before writing** uses a temporary file outside the destination; the final write uses `noclobber`, so a file that appears in between is still never overwritten.
- **The restricted-field list** (`caps`, `userns`, `docker_api`, `host_ports`) now appears in both `lib/profile-check.sh` (jq) and the new helper (jq). A comment on each names the other.

## File Structure

- Modify `lib/profiles.sh` — add `sbx_profile_valid_type`, `sbx_profile_valid_name`, `sbx_profile_template`, `sbx_profile_restricted_fields`, `sbx_profile_shadowing`; `sbx_profile_list` gains shadow markers (Task 1). Test: `tests/profiles.bats`.
- Create `sbx-profile` (executable) — `ls`, `check`, usage (Task 2); `new` (Task 3). Test: `tests/sbx-profile.bats`.
- Modify `README.md` and `sbx`'s `usage` (Task 3).

---

### Task 1: Profile helpers in `lib/profiles.sh`

**Files:**
- Modify: `lib/profiles.sh`, `lib/profile-check.sh` (one comment line)
- Test: `tests/profiles.bats` (append)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `sbx_profile_valid_type <type>` → status 0 for `cli`, `fs`, `net`
  - `sbx_profile_valid_name <name>` → status 0 when the name matches `^[A-Za-z0-9_][A-Za-z0-9._-]*$`
  - `sbx_profile_template <type> <description>` → prints the template JSON, 4-space indented; status 1 for an unknown type
  - `sbx_profile_restricted_fields <file>` → prints each of `caps`, `userns`, `docker_api`, `host_ports` present in the file, one per line, in that order
  - `sbx_profile_shadowing <type> <name> <location> <config_dir> <global_dir>` → for each OTHER location (`project`, `user`, `global`) holding `<type>/<name>`, prints `shadowed-by <location> <path>` if it takes precedence over `<location>`, or `shadows <location> <path>` if `<location>` hides it. Paths: `./.sbx/profiles/<type>/<name>.json`, `<config_dir>/profiles/<type>/<name>.json`, `<global_dir>/<type>/<name>.json`. Precedence: project, user, global.
  - `sbx_profile_list` output: a profile hidden by a higher-precedence one of the same name prints `  <name> (<Label>, shadowed by <Label of the one in use>)`; names are printed with C0 control characters and DEL removed. Unshadowed lines are unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `tests/profiles.bats` (its `setup` defines `$W`, `$PROJ`, `$CFG`, `$GLOBAL` with a `shared` fs profile in all three locations, `mine` in user, `base` in global, and `cd`s into `$PROJ`):

```bash
@test "valid types and names" {
    sbx_profile_valid_type cli
    sbx_profile_valid_type fs
    sbx_profile_valid_type net
    if sbx_profile_valid_type ssh; then return 1; fi
    sbx_profile_valid_name my-profile_1.2
    sbx_profile_valid_name _x
    for bad in "" ../evil a/b .hidden -dash "sp ace"; do
        if sbx_profile_valid_name "$bad"; then echo "accepted '$bad'" >&2; return 1; fi
    done
}

@test "templates are valid and grant nothing" {
    source "$BATS_TEST_DIRNAME/../lib/profile-check.sh"
    local type out
    for type in cli fs net; do
        sbx_profile_template "$type" "a $type profile" > "$W/t.json"
        out=$(sbx_profile_check "$type" "$W/t.json" project)
        if [[ -n "$out" ]]; then echo "$type template: $out" >&2; return 1; fi
    done
    [ "$(sbx_profile_template cli d | jq -c .)" = '{"description":"d","env":{},"passthrough":[],"mounts":[]}' ]
    [ "$(sbx_profile_template fs d | jq -c .)" = '{"description":"d","mounts":[]}' ]
    [ "$(sbx_profile_template net d | jq -c .)" = '{"description":"d","dns":"1.1.1.1","allow":[],"ports":[443]}' ]
    run sbx_profile_template ssh d
    [ "$status" -eq 1 ]
}

@test "restricted fields are listed in order" {
    echo '{"host_ports":[1],"caps":"keep","description":"x","docker_api":false}' > "$W/r.json"
    run sbx_profile_restricted_fields "$W/r.json"
    [ "$output" = "$(printf 'caps\ndocker_api\nhost_ports')" ]
    echo '{"description":"x"}' > "$W/r.json"
    run sbx_profile_restricted_fields "$W/r.json"
    [ -z "$output" ]
}

@test "shadowing relative to each location" {
    run sbx_profile_shadowing fs shared user "$CFG" "$GLOBAL"
    [ "${lines[0]}" = "shadowed-by project ./.sbx/profiles/fs/shared.json" ]
    [ "${lines[1]}" = "shadows global $GLOBAL/fs/shared.json" ]
    run sbx_profile_shadowing fs base project "$CFG" "$GLOBAL"
    [ "$output" = "shadows global $GLOBAL/fs/base.json" ]
    run sbx_profile_shadowing fs nothing user "$CFG" "$GLOBAL"
    [ -z "$output" ]
}

@test "list marks shadowed profiles" {
    run sbx_profile_list "$CFG" "$GLOBAL"
    [[ "$output" == *"  shared (Project)"* ]]
    [[ "$output" == *"  shared (User, shadowed by Project)"* ]]
    [[ "$output" == *"  shared (Global, shadowed by Project)"* ]]
    [[ "$output" == *"  mine (User)"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/profiles.bats`
Expected: the 5 new tests fail (`command not found` for the new functions; the list test fails on the shadow marker); the existing 7 still pass.

- [ ] **Step 3: Implement**

Append to `lib/profiles.sh`:

```bash
sbx_profile_valid_type() {   # <type>
    [[ "$1" == "cli" || "$1" == "fs" || "$1" == "net" ]]
}

# A profile name is one path component, so creating one can never write
# outside its directory.
sbx_profile_valid_name() {   # <name>
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]
}

# The starting content for a new profile: valid, and granting nothing, so
# a template left unedited can never open access by accident.
sbx_profile_template() {   # <type> <description>
    case "$1" in
        cli) jq -n --indent 4 --arg d "$2" '{description: $d, env: {}, passthrough: [], mounts: []}' ;;
        fs)  jq -n --indent 4 --arg d "$2" '{description: $d, mounts: []}' ;;
        net) jq -n --indent 4 --arg d "$2" '{description: $d, dns: "1.1.1.1", allow: [], ports: [443]}' ;;
        *)   return 1 ;;
    esac
}

# Fields a project profile may not set. Same list as `restricted` in
# lib/profile-check.sh — keep the two in step.
sbx_profile_restricted_fields() {   # <file>
    jq -r '["caps", "userns", "docker_api", "host_ports"][] as $f | select(has($f)) | $f' "$1"
}

# Other locations holding the same <type>/<name>, relative to <location>.
# Precedence is project, then user, then global (see sbx_profile_resolve).
sbx_profile_shadowing() {   # <type> <name> <location> <config_dir> <global_dir>
    local type="$1" name="$2" location="$3" config_dir="$4" global_dir="$5" i mine=-1
    local -a labels=(project user global)
    local -a paths=("./.sbx/profiles/$type/$name.json"
                    "$config_dir/profiles/$type/$name.json"
                    "$global_dir/$type/$name.json")
    for i in 0 1 2; do
        if [[ "${labels[$i]}" == "$location" ]]; then
            mine=$i
        fi
    done
    for i in 0 1 2; do
        if [[ $i -eq $mine || ! -f "${paths[$i]}" ]]; then
            continue
        fi
        if [[ $i -lt $mine ]]; then
            echo "shadowed-by ${labels[$i]} ${paths[$i]}"
        else
            echo "shadows ${labels[$i]} ${paths[$i]}"
        fi
    done
    return 0
}
```

In `sbx_profile_list`, add shadow tracking. Declare `local shown` and `local -A seen` with the other locals; reset `seen=()` at the top of each `for type` iteration; and replace the inner `while` loop body with:

```bash
                    while IFS= read -r profile; do
                        shown=$(LC_ALL=C tr -d '\000-\037\177' <<< "$profile")
                        if [[ -n "${seen[$profile]:-}" ]]; then
                            echo "  $shown ($label, shadowed by ${seen[$profile]})"
                        else
                            echo "  $shown ($label)"
                            seen[$profile]="$label"
                        fi
                        found=1
                    done <<< "$files"
```

In `lib/profile-check.sh`, on the line above `def restricted:`, add:

```
# Same list as sbx_profile_restricted_fields in lib/profiles.sh — keep the two in step.
```

(It is inside the single-quoted jq program, so write it as a jq comment: jq treats `#` to end of line as a comment.)

- [ ] **Step 4: Run the tests**

Run: `bats tests/profiles.bats tests/profile-check.bats tests/snapshot.bats`
Expected: all pass.

- [ ] **Step 5: Shellcheck and commit**

Run: `shellcheck -S error sbx lib/*.sh` — expected silent.

```bash
git add lib/profiles.sh lib/profile-check.sh tests/profiles.bats
git commit -m "Add profile helpers for sbx-profile and mark shadowed profiles"
```

---

### Task 2: `sbx-profile ls` and `sbx-profile check`

**Files:**
- Create: `sbx-profile` (mode 755)
- Create: `tests/sbx-profile.bats`

**Interfaces:**
- Consumes: `sbx_profile_resolve`, `sbx_profile_origin`, `sbx_profile_list`, `sbx_profile_valid_type` (lib/profiles.sh); `sbx_profile_check` (lib/profile-check.sh); `sbx_sanitize_message` (lib/render.sh).
- Produces the commands:
  - `sbx-profile ls` → the same output as `sbx --list-profiles`; exit 0.
  - `sbx-profile check` → every profile visible from the current directory (project, user, global; each type), one summary line each: `<type>/<name> (<origin>): ok` or `: <N> error(s)[, <M> warning(s)]` or `: <M> warning(s)`, followed by its messages indented as `  error:   <message>` / `  warning: <message>`. Exit 1 if any profile has an error, else 0. With no profiles: `No profiles found.` and exit 0.
  - `sbx-profile check <type>/<name>` → the one profile that name resolves to from here (same precedence as a launch).
  - `sbx-profile check <path>` → that file; its type is the name of its parent directory, which must be `cli`, `fs` or `net` (else exit 2 with a message saying so).
  - Anything else → usage on stderr, exit 2. `sbx-profile -h|--help|help` → usage on stdout, exit 0.

- [ ] **Step 1: Write the failing tests**

Create `tests/sbx-profile.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SBXP="$REPO/sbx-profile"
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/p"
    mkdir -p "$HOME/.config/sbx/profiles/fs" "$HOME/.config/sbx/profiles/net" "$PROJ"
    cd "$PROJ"
}

teardown() {
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]]; then
        rm -rf "$ROOT"
    fi
}

@test "ls matches sbx --list-profiles" {
    echo '{}' > "$HOME/.config/sbx/profiles/fs/sandbox.json"
    run "$SBXP" ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"  sandbox (User)"* ]]
    [[ "$output" == *"  sandbox (Global, shadowed by User)"* ]]
    local ls_out="$output"
    run "$REPO/sbx" --list-profiles
    [ "$output" = "$ls_out" ]
}

@test "check with no argument reports every visible profile and passes when none has errors" {
    run "$SBXP" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"fs/sandbox (global): ok"* ]]
    [[ "$output" == *"net/web (global): 1 warning"* ]]
    [[ "$output" == *"  warning: "*"*.google.com admits any address"* ]]
}

@test "check fails when a profile has errors, and names each problem" {
    echo '{"mount":[],"caps":"drop"}' > "$HOME/.config/sbx/profiles/fs/bad.json"
    run "$SBXP" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"fs/bad (user): 2 errors"* ]]
    [[ "$output" == *"  error:   $HOME/.config/sbx/profiles/fs/bad.json: .mount: unknown field for a fs profile"* ]]
    [[ "$output" == *"  error:   $HOME/.config/sbx/profiles/fs/bad.json: .caps: expected \"keep\", got \"drop\""* ]]
}

@test "check <type>/<name> resolves like a launch" {
    mkdir -p .sbx/profiles/fs
    echo '{"caps":"keep"}' > .sbx/profiles/fs/sandbox.json
    run "$SBXP" check fs/sandbox
    [ "$status" -eq 1 ]
    [[ "$output" == *"fs/sandbox (project): 1 error"* ]]
    [[ "$output" == *"project profiles may not set caps"* ]]
}

@test "check <path> takes the type from the parent directory" {
    echo '{"allow":["github.com"]}' > "$HOME/.config/sbx/profiles/net/gh.json"
    run "$SBXP" check "$HOME/.config/sbx/profiles/net/gh.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"net/gh (user): ok"* ]]
    mkdir -p "$ROOT/elsewhere"
    echo '{}' > "$ROOT/elsewhere/x.json"
    run "$SBXP" check "$ROOT/elsewhere/x.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"must be cli, fs or net"* ]]
}

@test "check sanitizes profile-authored text" {
    printf '{"workingDirectory":"/x\\u001b[2Kbad"}\n' > "$HOME/.config/sbx/profiles/fs/esc.json"
    run "$SBXP" check fs/esc
    if [[ "$output" == *$'\033'* ]]; then return 1; fi
    [[ "$output" == *"[2Kbad"* ]]
}

@test "usage errors exit 2; help exits 0" {
    run "$SBXP"
    [ "$status" -eq 2 ]
    run "$SBXP" frobnicate
    [ "$status" -eq 2 ]
    run "$SBXP" check a b
    [ "$status" -eq 2 ]
    run "$SBXP" check ssh/x
    [ "$status" -eq 2 ]
    run "$SBXP" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"new <type> <name>"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/sbx-profile.bats`
Expected: all fail — `sbx-profile: No such file or directory`.

- [ ] **Step 3: Write the script**

Create `sbx-profile` and `chmod 755 sbx-profile`:

```bash
#!/bin/bash
# sbx-profile — list, check and create sbx profiles.
#
# Works on profile files only. Everything that takes launch flags,
# including previewing a launch (sbx --dry-run), stays in sbx.

set -e

CONFIG_DIR="$HOME/.config/sbx"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_DIR="$SCRIPT_DIR/profiles"

# shellcheck source=lib/profiles.sh
source "$SCRIPT_DIR/lib/profiles.sh"
# shellcheck source=lib/profile-check.sh
source "$SCRIPT_DIR/lib/profile-check.sh"
# shellcheck source=lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [arguments]

Commands:
  ls                          List profiles with where each comes from;
                              a profile hidden by one of the same name is
                              marked "shadowed"
  check [<type>/<name>|<path>]
                              Validate one profile, or with no argument every
                              profile visible from this directory (exit 1 if
                              any has errors)
  new <type> <name> [--user|--local] [--from <profile>]
                              Create a profile: cli, fs or net. --user writes
                              ~/.config/sbx/profiles, --local writes
                              ./.sbx/profiles. Never overwrites.
  help                        Show this help

Profiles are searched in:
  1. ./.sbx/profiles/
  2. \$HOME/.config/sbx/profiles/
  3. $GLOBAL_DIR/
EOF
}

# One profile's validation result. Prints a summary line and its messages;
# returns 1 if the profile has errors.
check_one() {   # <type> <path>
    local type="$1" path="$2" origin name level msg errors=0 warnings=0 summary
    local -a lines=()
    origin=$(sbx_profile_origin "$path" "$PWD" "$CONFIG_DIR" "$GLOBAL_DIR")
    name=$(sbx_sanitize_message "$(basename "$path" .json)")
    while IFS=$'\t' read -r level msg; do
        case "$level" in
            error)
                errors=$((errors + 1))
                lines+=("  error:   $(sbx_sanitize_message "$msg")")
                ;;
            warning)
                warnings=$((warnings + 1))
                lines+=("  warning: $(sbx_sanitize_message "$msg")")
                ;;
        esac
    done < <(sbx_profile_check "$type" "$path" "$origin")

    summary=""
    if [[ $errors -gt 0 ]]; then
        summary="$errors error"
        if [[ $errors -gt 1 ]]; then summary+="s"; fi
    fi
    if [[ $warnings -gt 0 ]]; then
        if [[ -n "$summary" ]]; then summary+=", "; fi
        summary+="$warnings warning"
        if [[ $warnings -gt 1 ]]; then summary+="s"; fi
    fi
    if [[ -z "$summary" ]]; then
        summary="ok"
    fi
    echo "$type/$name ($origin): $summary"
    if [[ ${#lines[@]} -gt 0 ]]; then
        printf '%s\n' "${lines[@]}"
    fi
    if [[ $errors -gt 0 ]]; then
        return 1
    fi
    return 0
}

cmd_check() {
    local rc=0 type name path dir f found=0
    if [[ $# -gt 1 ]]; then
        usage >&2
        return 2
    fi

    if [[ $# -eq 0 ]]; then
        for type in cli fs net; do
            for dir in "./.sbx/profiles/$type" "$CONFIG_DIR/profiles/$type" "$GLOBAL_DIR/$type"; do
                if [[ ! -d "$dir" ]]; then
                    continue
                fi
                for f in "$dir"/*.json; do
                    if [[ ! -e "$f" ]]; then
                        continue
                    fi
                    found=1
                    check_one "$type" "$f" || rc=1
                done
            done
        done
        if [[ $found -eq 0 ]]; then
            echo "No profiles found."
        fi
        return $rc
    fi

    if [[ -f "$1" ]]; then
        type=$(basename "$(dirname "$1")")
        if ! sbx_profile_valid_type "$type"; then
            echo "Error: cannot tell the type of '$(sbx_sanitize_message "$1")': its directory must be cli, fs or net. Use <type>/<name> instead." >&2
            return 2
        fi
        check_one "$type" "$1" || rc=1
        return $rc
    fi

    if [[ "$1" != */* ]]; then
        echo "Error: check expects <type>/<name> or a path to a profile file." >&2
        return 2
    fi
    type="${1%%/*}"
    name="${1#*/}"
    if ! sbx_profile_valid_type "$type"; then
        echo "Error: the type must be cli, fs or net, got '$(sbx_sanitize_message "$type")'." >&2
        return 2
    fi
    path=$(sbx_profile_resolve "$type" "$name" "$CONFIG_DIR" "$GLOBAL_DIR") || return 1
    check_one "$type" "$path" || rc=1
    return $rc
}

rc=0
case "${1:-}" in
    ls)
        shift
        if [[ $# -gt 0 ]]; then
            usage >&2
            exit 2
        fi
        sbx_profile_list "$CONFIG_DIR" "$GLOBAL_DIR"
        ;;
    check)
        shift
        cmd_check "$@" || rc=$?
        exit "$rc"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/sbx-profile.bats`
Expected: 7/7 pass. If the "check with no argument" expectations about the shipped global profiles are wrong (a different warning count), read `profiles/net/web.json` and `sbx_profile_check`'s rules and correct the TEST to the true count, saying so in the report; do not change the checker.

- [ ] **Step 5: Shellcheck, snapshots, commit**

Run: `shellcheck -S error sbx sbx-profile lib/*.sh && bats tests/snapshot.bats tests/profiles.bats`
Expected: silent; all pass.

```bash
git add sbx-profile tests/sbx-profile.bats
git commit -m "Add sbx-profile ls and check"
```

---

### Task 3: `sbx-profile new`, and documentation

**Files:**
- Modify: `sbx-profile` — add `cmd_new` and its `case` branch; mention in `usage` is already there
- Modify: `tests/sbx-profile.bats` (append)
- Modify: `README.md`; `sbx` (`usage`)

**Interfaces:**
- Consumes: `sbx_profile_valid_type`, `sbx_profile_valid_name`, `sbx_profile_template`, `sbx_profile_restricted_fields`, `sbx_profile_shadowing`, `sbx_profile_resolve` (lib/profiles.sh); `sbx_profile_check`; `sbx_sanitize_message`.
- Produces: `sbx-profile new <type> <name> [--user|--local] [--from <name>|<type>/<name>]` with the behavior below.

Behavior, in order:
1. Parse: two positionals (`<type> <name>`), options `--user`, `--local`, `--from <profile>`, in any order. Any other word starting with `-`, a missing `--from` value, or a positional count other than two → usage error, exit 2. Both `--user` and `--local` → `Error: choose one of --user or --local.`, exit 2.
2. `<type>` not `cli|fs|net` → `Error: the type must be cli, fs or net, got '<type>'.`, exit 2. `<name>` fails `sbx_profile_valid_name` → `Error: a profile name is letters, digits, '.', '_' and '-', not starting with '.' or '-'; got '<name>'.`, exit 2 (sanitize the echoed values).
3. Location: `--user` → `~/.config/sbx/profiles/<type>/`, origin `user`; `--local` → `./.sbx/profiles/<type>/`, origin `project`. Neither: if stdin is a terminal, print to stderr `Write <type>/<name> to (u)ser ~/.config/sbx/profiles or (l)ocal ./.sbx/profiles? [u/l] ` and read an answer (`u`/`user` or `l`/`local`, case-insensitive; anything else → `Aborted.`, exit 1). Not a terminal → `Error: say where to write the profile: --user (~/.config/sbx/profiles) or --local (./.sbx/profiles).`, exit 2.
4. If `<dir>/<name>.json` exists → `Error: <path> already exists; sbx-profile never overwrites a profile. Remove it first to replace it.`, exit 1.
5. Content:
   - With `--from`: `<name>` alone means the same type; `<type>/<name>` must have the same type as the new profile (else exit 2 `Error: --from must name a <type> profile.`). Resolve it with `sbx_profile_resolve` (exit 1 on not found). With `--local`, if `sbx_profile_restricted_fields` lists anything → `Error: <source> sets <fields>, which a project profile may not set. Create it with --user instead.`, exit 1. Content = the source with `.description` set to `<name> (copied from <type>/<source name>)`, 4-space indented. A source that is not valid JSON → `Error: <source> is not valid JSON.`, exit 1.
   - Otherwise: `sbx_profile_template <type> <name>`.
6. Validate: write the content to a `mktemp` file, run `sbx_profile_check <type> <tmp> <origin>`, remove the temp file. Errors → print each as `  error:   <message>` with the temp path replaced by the final path, then `Error: not written: the new profile does not validate.`, exit 1. Warnings are printed the same way as `  warning: …` and do not stop the write.
7. Write: `mkdir -p <dir>`, then write with `noclobber` (a file that appeared since step 4 → the step 4 message, exit 1).
8. Report on stdout:
   ```
   Created <path, with $HOME shown as ~>
   <field guide for the type — see below>
   See "Constructing Profiles" in the README for every field.
   Next: sbx --dry-run --<type> <name>
   ```
   Then, from `sbx_profile_shadowing <type> <name> <origin> …`: for each `shadows <loc> <path>` line, `Note: this profile hides the <loc> profile <path>.`; for each `shadowed-by <loc> <path>` line, `Warning: the <loc> profile <path> takes precedence; from this directory sbx will use that one, not this.` (warnings to stderr, notes to stdout). With `--local`, also: `Note: sbx uses an untracked ./.sbx profile without asking; once git tracks it, launches from this directory will ask before using it.`

Field guides (printed verbatim, each line indented two spaces):

- cli:
  ```
    env          variables to set, e.g. {"EDITOR": "vim"}
    passthrough  host variables to forward by name, e.g. ["ANTHROPIC_API_KEY"]
    path         directories to put first on PATH
    mounts       [{"source": "...", "dest": "...", "perm": "ro|rw|dev|forked|record"}]
  ```
- fs:
  ```
    mounts       [{"source": "...", "dest": "...", "perm": "ro|rw|dev|forked|record"}]
    env          variables to set, e.g. {"EDITOR": "vim"}
  ```
- net:
  ```
    allow        hostnames, *.domains or CIDRs, e.g. ["github.com", "*.example.com"]
    ports        allowed ports, e.g. [443] or ["*"]
    dns          upstream resolver, a bare IPv4 address
  ```

- [ ] **Step 1: Write the failing tests**

Append to `tests/sbx-profile.bats`:

```bash
@test "new --user writes the template and says what to do next" {
    run "$SBXP" new net api --user
    [ "$status" -eq 0 ]
    [ "$(jq -c . "$HOME/.config/sbx/profiles/net/api.json")" = '{"description":"api","dns":"1.1.1.1","allow":[],"ports":[443]}' ]
    [[ "$output" == *"Created ~/.config/sbx/profiles/net/api.json"* ]]
    [[ "$output" == *"allow        hostnames"* ]]
    [[ "$output" == *"Next: sbx --dry-run --net api"* ]]
}

@test "new --local writes under ./.sbx and explains the trust rule" {
    run "$SBXP" new fs work --local
    [ "$status" -eq 0 ]
    [ -f "$PROJ/.sbx/profiles/fs/work.json" ]
    [[ "$output" == *"untracked ./.sbx profile without asking"* ]]
}

@test "without a location flag: an error off a terminal, a prompt on one" {
    run bash -c "cd '$PROJ' && '$SBXP' new fs x < /dev/null 2>&1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--user"*"--local"* ]]
    if [[ -e "$PROJ/.sbx" || -e "$HOME/.config/sbx/profiles/fs/x.json" ]]; then return 1; fi
    run bash -c "cd '$PROJ' && printf 'l\n' | script -qec \"'$SBXP' new fs x\" /dev/null"
    [ "$status" -eq 0 ]
    [ -f "$PROJ/.sbx/profiles/fs/x.json" ]
}

@test "new never overwrites" {
    "$SBXP" new fs keep --user > /dev/null
    echo '{"description":"mine"}' > "$HOME/.config/sbx/profiles/fs/keep.json"
    run "$SBXP" new fs keep --user
    [ "$status" -eq 1 ]
    [[ "$output" == *"already exists"* ]]
    [ "$(jq -r .description "$HOME/.config/sbx/profiles/fs/keep.json")" = "mine" ]
}

@test "--from copies a profile under a new description" {
    run "$SBXP" new net web2 --user --from web
    [ "$status" -eq 0 ]
    [ "$(jq -r .description "$HOME/.config/sbx/profiles/net/web2.json")" = "web2 (copied from net/web)" ]
    [ "$(jq -c .allow "$HOME/.config/sbx/profiles/net/web2.json")" = "$(jq -c .allow "$REPO/profiles/net/web.json")" ]
    [[ "$output" == *"warning: "* ]]
}

@test "--local --from refuses a profile with restricted fields" {
    run "$SBXP" new fs pod --local --from fs/podman
    [ "$status" -eq 1 ]
    [[ "$output" == *"sets caps docker_api, which a project profile may not set"* ]]
    if [[ -e "$PROJ/.sbx" ]]; then return 1; fi
}

@test "--from must match the type" {
    run "$SBXP" new fs x --user --from net/web
    [ "$status" -eq 2 ]
}

@test "shadowing is reported both ways" {
    run "$SBXP" new fs sandbox --user
    [[ "$output" == *"Note: this profile hides the global profile"* ]]
    mkdir -p .sbx/profiles/fs
    echo '{}' > .sbx/profiles/fs/mine.json
    run bash -c "cd '$PROJ' && '$SBXP' new fs mine --user 2>&1"
    [[ "$output" == *"Warning: the project profile ./.sbx/profiles/fs/mine.json takes precedence"* ]]
}

@test "bad types and names are refused and write nothing" {
    run "$SBXP" new ssh x --user
    [ "$status" -eq 2 ]
    run "$SBXP" new fs ../evil --user
    [ "$status" -eq 2 ]
    run "$SBXP" new fs x --user --local
    [ "$status" -eq 2 ]
    run "$SBXP" new fs x --user --bogus
    [ "$status" -eq 2 ]
    if [[ -e "$HOME/.config/sbx/evil.json" || -e "$HOME/.config/sbx/profiles/fs/x.json" ]]; then return 1; fi
}

@test "every created profile validates" {
    local type
    for type in cli fs net; do
        "$SBXP" new "$type" "t$type" --user > /dev/null
        run "$SBXP" check "$type/t$type"
        [ "$status" -eq 0 ]
        [[ "$output" == *"$type/t$type (user): ok"* ]]
    done
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/sbx-profile.bats`
Expected: the 10 new tests fail (`new` falls to the usage branch, exit 2); Task 2's 7 still pass.

- [ ] **Step 3: Implement `cmd_new`**

Add to `sbx-profile`, before the final `case`:

```bash
field_guide() {   # <type>
    case "$1" in
        cli)
            echo '  env          variables to set, e.g. {"EDITOR": "vim"}'
            echo '  passthrough  host variables to forward by name, e.g. ["ANTHROPIC_API_KEY"]'
            echo '  path         directories to put first on PATH'
            echo '  mounts       [{"source": "...", "dest": "...", "perm": "ro|rw|dev|forked|record"}]'
            ;;
        fs)
            echo '  mounts       [{"source": "...", "dest": "...", "perm": "ro|rw|dev|forked|record"}]'
            echo '  env          variables to set, e.g. {"EDITOR": "vim"}'
            ;;
        net)
            echo '  allow        hostnames, *.domains or CIDRs, e.g. ["github.com", "*.example.com"]'
            echo '  ports        allowed ports, e.g. [443] or ["*"]'
            echo '  dns          upstream resolver, a bare IPv4 address'
            ;;
    esac
}

cmd_new() {
    local type name location="" from="" dir final answer content src src_type src_name
    local tmp level msg errors=0 relation loc other shown
    local -a pos=() restricted=() messages=()
    local nflags=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)  location=user; nflags=$((nflags + 1)); shift ;;
            --local) location=project; nflags=$((nflags + 1)); shift ;;
            --from)
                if [[ $# -lt 2 ]]; then
                    usage >&2
                    return 2
                fi
                from="$2"
                shift 2
                ;;
            -*)
                echo "Error: unknown option '$(sbx_sanitize_message "$1")' for new." >&2
                return 2
                ;;
            *)  pos+=("$1"); shift ;;
        esac
    done
    if [[ ${#pos[@]} -ne 2 ]]; then
        usage >&2
        return 2
    fi
    if [[ $nflags -gt 1 ]]; then
        echo "Error: choose one of --user or --local." >&2
        return 2
    fi
    type="${pos[0]}"
    name="${pos[1]}"
    if ! sbx_profile_valid_type "$type"; then
        echo "Error: the type must be cli, fs or net, got '$(sbx_sanitize_message "$type")'." >&2
        return 2
    fi
    if ! sbx_profile_valid_name "$name"; then
        echo "Error: a profile name is letters, digits, '.', '_' and '-', not starting with '.' or '-'; got '$(sbx_sanitize_message "$name")'." >&2
        return 2
    fi

    if [[ -z "$location" ]]; then
        if [[ -t 0 ]]; then
            printf 'Write %s/%s to (u)ser ~/.config/sbx/profiles or (l)ocal ./.sbx/profiles? [u/l] ' "$type" "$name" >&2
            answer=""
            read -r answer || true
            case "${answer,,}" in
                u|user)  location=user ;;
                l|local) location=project ;;
                *)
                    echo "Aborted." >&2
                    return 1
                    ;;
            esac
        else
            echo "Error: say where to write the profile: --user (~/.config/sbx/profiles) or --local (./.sbx/profiles)." >&2
            return 2
        fi
    fi

    if [[ "$location" == "user" ]]; then
        dir="$CONFIG_DIR/profiles/$type"
    else
        dir="./.sbx/profiles/$type"
    fi
    final="$dir/$name.json"
    if [[ -e "$final" ]]; then
        echo "Error: $final already exists; sbx-profile never overwrites a profile. Remove it first to replace it." >&2
        return 1
    fi

    if [[ -n "$from" ]]; then
        src_type="$type"
        src_name="$from"
        if [[ "$from" == */* ]]; then
            src_type="${from%%/*}"
            src_name="${from#*/}"
        fi
        if [[ "$src_type" != "$type" ]]; then
            echo "Error: --from must name a $type profile." >&2
            return 2
        fi
        src=$(sbx_profile_resolve "$type" "$src_name" "$CONFIG_DIR" "$GLOBAL_DIR") || return 1
        if [[ "$location" == "project" ]]; then
            mapfile -t restricted < <(sbx_profile_restricted_fields "$src" 2>/dev/null)
            if [[ ${#restricted[@]} -gt 0 ]]; then
                echo "Error: $src sets ${restricted[*]}, which a project profile may not set. Create it with --user instead." >&2
                return 1
            fi
        fi
        if ! content=$(jq --indent 4 --arg d "$name (copied from $type/$(basename "$src" .json))" \
                '.description = $d' "$src" 2>/dev/null); then
            echo "Error: $src is not valid JSON." >&2
            return 1
        fi
    else
        content=$(sbx_profile_template "$type" "$name")
    fi

    # Validate before anything is written, from a temporary file outside
    # the destination, as the kind of profile it is about to become.
    tmp=$(mktemp)
    printf '%s\n' "$content" > "$tmp"
    while IFS=$'\t' read -r level msg; do
        msg="${msg//"$tmp"/"$final"}"
        case "$level" in
            error)
                errors=$((errors + 1))
                messages+=("  error:   $(sbx_sanitize_message "$msg")")
                ;;
            warning)
                messages+=("  warning: $(sbx_sanitize_message "$msg")")
                ;;
        esac
    done < <(sbx_profile_check "$type" "$tmp" "$location")
    rm -f "$tmp"
    if [[ ${#messages[@]} -gt 0 ]]; then
        printf '%s\n' "${messages[@]}"
    fi
    if [[ $errors -gt 0 ]]; then
        echo "Error: not written: the new profile does not validate." >&2
        return 1
    fi

    mkdir -p "$dir"
    # noclobber: a file that appeared since the check above is still never
    # overwritten.
    if ! ( set -o noclobber; printf '%s\n' "$content" > "$final" ) 2>/dev/null; then
        echo "Error: $final already exists; sbx-profile never overwrites a profile. Remove it first to replace it." >&2
        return 1
    fi

    shown="$final"
    if [[ "$shown" == "$HOME/"* ]]; then
        shown="~/${shown#"$HOME"/}"
    fi
    echo "Created $shown"
    field_guide "$type"
    echo 'See "Constructing Profiles" in the README for every field.'
    echo "Next: sbx --dry-run --$type $name"

    while read -r relation loc other; do
        case "$relation" in
            shadows)
                echo "Note: this profile hides the $loc profile $other."
                ;;
            shadowed-by)
                echo "Warning: the $loc profile $other takes precedence; from this directory sbx will use that one, not this." >&2
                ;;
        esac
    done < <(sbx_profile_shadowing "$type" "$name" "$location" "$CONFIG_DIR" "$GLOBAL_DIR")

    if [[ "$location" == "project" ]]; then
        echo "Note: sbx uses an untracked ./.sbx profile without asking; once git tracks it, launches from this directory will ask before using it."
    fi
    return 0
}
```

Add the branch to the final `case`, before `-h|--help|help)`:

```bash
    new)
        shift
        cmd_new "$@" || rc=$?
        exit "$rc"
        ;;
```

Note `"$location"` is `user` or `project`, which is exactly the origin `sbx_profile_check` and `sbx_profile_shadowing` expect.

- [ ] **Step 4: Run the tests**

Run: `bats tests/sbx-profile.bats`
Expected: 17/17 pass. The "--from copies" test expects a validation warning because `profiles/net/web.json` has a `*.google.com` entry; if that changes, adjust that one assertion and say so.

- [ ] **Step 5: Documentation**

In `sbx`'s `usage`, after the `--list-profiles` line add:

```
                         (sbx-profile ls / check / new manage profile files)
```

In `README.md`, replace the numbered list under `### Creating Custom Profiles` with:

```markdown
Use `sbx-profile`:

    ./sbx-profile new net myapi --user              # ~/.config/sbx/profiles/net/myapi.json
    ./sbx-profile new fs work --local               # ./.sbx/profiles/fs/work.json
    ./sbx-profile new net web2 --user --from web    # start from an existing profile
    ./sbx-profile check                             # validate every profile you can see
    ./sbx-profile ls                                # list them, marking shadowed ones

`new` writes a minimal profile that grants nothing (or a copy of `--from`),
validates it before writing, never overwrites an existing file, and never
writes the global directory. Without `--user` or `--local` it asks where to
write when run from a terminal, and refuses otherwise. `--local --from` is
refused for a profile that sets `caps`, `userns`, `docker_api` or
`host_ports`, which a project profile may not set. It then prints a short
guide to the type's fields and the `sbx --dry-run` command to preview it.

A profile under `./.sbx` that git does not track is used without a prompt;
once git tracks it, launches ask before using it (see Threat model).
```

Keep the existing text around it. Also, in the Profile Locations section, add after the list: `` `sbx-profile ls` shows which one wins when the same name exists in several places. ``

- [ ] **Step 6: Full suite, shellcheck, commit**

Run: `bats tests/ && shellcheck -S error sbx sbx-profile lib/*.sh`
Expected: all pass (the previous total was 302), snapshots unregenerated; shellcheck silent.

```bash
git add sbx-profile tests/sbx-profile.bats README.md sbx
git commit -m "Add sbx-profile new"
```

---

## Open items outside this plan

- `sbx-profile new --from-learn <dir|latest>` and its test move to Phase 5, with the learning reports it reads.
