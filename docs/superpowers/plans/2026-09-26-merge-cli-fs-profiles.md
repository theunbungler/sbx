# Merge cli and fs profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold sbx's `cli` profile type into `fs`: one stackable profile type that may carry `path`, with `--cli` kept as a compatibility alias that applies its profiles last.

**Architecture:** `lib/resolve.sh` learns to collect `path` from every profile (later profile first), then `sbx` stops treating `--cli` specially (it resolves an fs profile and appends it after the `--fs` list), then the `cli` type is removed from lookup, schema and `sbx-profile`, with a warning for leftover `cli/` directories. Docs last.

**Tech Stack:** bash, jq, bats 1.13, shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-26-merge-cli-fs-profiles-design.md`

## Global Constraints

- Branch: `merge-cli-fs` (off `worktree-cleanup`). Commit per task.
- Gate after every task: `shellcheck -x -S error sbx sbx-profile lib/*.sh tests/helpers/*.sh` prints nothing, and the suites the task names pass. The full `bats -j 4 tests/` runs at the end of Tasks 2 and 4.
- `lib/*.sh` stays side-effect-free at source time and never reads sbx globals; every directory is an argument (except the `./.sbx` relative form `lib/profiles.sh` already uses).
- `! cmd` in a bats test is a no-op unless it is the last line; write `if cmd; then return 1; fi`.
- E2E suites need a short `$HOME` (`mktemp -d /tmp/sbxh.XXXXXX`); existing setups already do this.
- Snapshots: regenerate only with `SBX_UPDATE_SNAPSHOTS=1 bats tests/snapshot.bats`, and only the diffs listed in Task 2 are acceptable.
- Warning text, exactly: `cli profiles are now fs profiles, so none in <dir> are loaded; move them to <parent>/fs` where `<parent>` is `<dir>` minus its trailing `/cli`.
- No automatic migration of anyone's `cli/` profiles. Net profiles unchanged. `lib/copy-mounts.sh` names unchanged.

## Review Focus

1. **A customised user `cli/claude.json` shadowed by the new global `fs/claude.json`.** `--cli claude` succeeds by loading the *global* profile, so the not-found hint never fires. The launch (and `--dry-run`) must still carry the leftover-directory warning naming `~/.config/sbx/profiles/cli`. Test in Task 3.
2. **`--cli` before `--fs` on the command line** (`--cli a --fs b`). `a` must still be applied after `b`: its env wins, its path entries come first. Test in Task 2.
3. **Habitual `--cli cli/claude`.** Must fail with a message telling the user to drop the `cli/` prefix, not the generic "not a profile name". Test in Task 3.
4. **`sbx-profile check` (no argument) with a leftover `cli/` directory.** Prints the warning and still exits 0 when no fs/net profile has errors. Test in Task 3.
5. **`--dry-run --json`** carries the leftover warning in `.warnings`, so tooling sees it too. Test in Task 3.

---

### Task 1: `path` in fs profiles, collected from every profile

**Files:**
- Modify: `lib/profile-check.sh` (the `known` table)
- Modify: `lib/resolve.sh` (header comment of `sbx_resolve_path`; locals and profile loop in `sbx_resolve`; remove the `cli_path` block)
- Test: `tests/profile-check.bats`, `tests/resolve.bats`

**Interfaces:**
- Consumes: nothing new.
- Produces: `sbx_resolve` builds `.path`/`.path_raw` from the `path` arrays of every applied non-net profile, in application order, later profile first. `sbx_resolve_path <entries> <env PATH>` unchanged. `sbx_resolve` still accepts `--cli` after this task (removed in Task 2).

- [ ] **Step 1: Write the failing tests**

Add to `tests/profile-check.bats`:

```bash
@test "an fs profile may set path, and path is validated" {
    check fs user '{"path":["/x","$HOME/bin"]}'
    [ -z "$output" ]
    check fs user '{"path":"/x"}'
    [[ "$output" == *".path"*"expected an array of strings"* ]]
    check fs user '{"path":["/x",3]}'
    [[ "$output" == *".path[1]"*"expected a string"* ]]
}
```

Add to `tests/resolve.bats`:

```bash
@test "path entries stack across profiles, later profile first, before env PATH" {
    local a b c
    a=$(user fs pa '{"path":["/a1","/a2"],"env":{"PATH":"/envp"}}')
    b=$(user fs pb '{"path":["/b1"]}')
    c=$(user fs pc '{"path":["$HOME/c1"]}')
    resolve --fs "$a" --fs "$b" --fs "$c"
    [ "$(r .path)" = "$HOME/c1:/b1:/a1:/a2:/envp:/usr/local/bin:/usr/bin:/bin" ]
    [ "$(r .path_raw)" = '$HOME/c1:/b1:/a1:/a2:/envp:/usr/local/bin:/usr/bin:/bin' ]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/profile-check.bats tests/resolve.bats -f 'path'`
Expected: the profile-check test FAILS with `.path: unknown field for a fs profile`; the resolve test FAILS (fs `path` entries are ignored, so `.path` is `/envp:/usr/local/bin:/usr/bin:/bin`).

- [ ] **Step 3: Implement**

`lib/profile-check.sh`, in `known`:

```jq
  { cli: ["description","env","path","mounts","passthrough","caps","userns","docker_api"],
    fs:  ["description","env","path","mounts","passthrough","caps","userns","docker_api"],
    net: ["description","dns","allow","ports","host_ports"] };
```

`lib/resolve.sh`:

1. Comment above `sbx_resolve_path`: replace `<cli path entries>` with `<every profile's path entries, later profile first>`.
2. In the `local kind f1 f2 f3 source dest perm present from value cli_path=""` line, drop `cli_path=""` and add a second line:
   ```bash
   local -a path_entries=() profile_path=()
   ```
3. Inside the per-profile `for i in "${!paths[@]}"` loop, right after `from="${types[$i]}/$name"`, add `profile_path=()`.
4. Add a case arm next to `pass)`:
   ```bash
                    path)
                        profile_path+=("$f1")
                        ;;
   ```
5. In the jq program feeding that loop, add a line after the `.passthrough[]?` line:
   ```jq
                (.path[]? | "path", nul, ., nul, "", nul, "", nul),
   ```
6. After the `done < <(jq -j ...)` of that loop (still inside the `for i` loop), add:
   ```bash
            # A later profile's entries go in front, as its env wins.
            path_entries=("${profile_path[@]}" "${path_entries[@]}")
   ```
7. Replace the whole `# A cli profile's path entries go in front ...` block (the `if [[ -n "$cli" ]]` and both `sbx_resolve_path` lines) with:
   ```bash
        # Every profile's path entries go in front of any PATH an env block
        # set, and the default closes the list (see sbx_resolve_path).
        local path_joined=""
        if [[ ${#path_entries[@]} -gt 0 ]]; then
            path_joined=$(printf '%s\n' "${path_entries[@]}" | paste -sd: -)
        fi
        sandbox_path=$(sbx_resolve_path "$(envsubst <<< "$path_joined")" "$sandbox_path")
        sandbox_path_raw=$(sbx_resolve_path "$path_joined" "$sandbox_path_raw")
   ```

- [ ] **Step 4: Run the suites**

Run: `bats tests/profile-check.bats tests/resolve.bats`
Expected: all PASS, including the existing `env is every assignment...` and `path_raw carries...` tests, which still pass `--cli`.

- [ ] **Step 5: shellcheck, then commit**

```bash
shellcheck -x -S error sbx sbx-profile lib/*.sh tests/helpers/*.sh
git add lib/profile-check.sh lib/resolve.sh tests/profile-check.bats tests/resolve.bats
git commit -m "Collect path from every profile, later profile first

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `--cli` becomes "apply this fs profile last"

**Files:**
- Modify: `sbx` (globals near line 45, `usage`, `parse_args` `--cli` arm, `resolve_plan`, `write_session_records`)
- Modify: `lib/resolve.sh` (drop `--cli` and the `cli` type from `sbx_resolve`)
- Move: `profiles/cli/{claude,dev,gemini,pi}.json` → `profiles/fs/`
- Modify tests: `tests/resolve.bats`, `tests/dry-run.bats`, `tests/persistent-cli.bats`, `tests/sessions.bats`, `tests/snapshot.bats`, `tests/render.bats`
- Regenerate: `tests/snapshots/*`

**Interfaces:**
- Consumes: Task 1's path collection.
- Produces: global `LAST_PROFILES=()` in `sbx` (resolved fs profile paths from `--cli`); `sbx_resolve` accepts only `--fs`/`--net` for profiles; `session.json` is `{id, cwd, pid, fs_profiles, net_profiles}` with `fs_profiles` = `--fs` list then `--cli` list.

- [ ] **Step 1: Write the failing tests**

Add to `tests/dry-run.bats`:

```bash
@test "--cli applies fs profiles after every --fs, in the order given" {
    echo '{"env":{"WHO":"a"},"path":["/a"]}' > "$HOME/.config/sbx/profiles/fs/pa.json"
    echo '{"env":{"WHO":"b"},"path":["/b"]}' > "$HOME/.config/sbx/profiles/fs/pb.json"
    echo '{"env":{"WHO":"c"},"path":["/c"]}' > "$HOME/.config/sbx/profiles/fs/pc.json"
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>/dev/null' _ "$PROJ" "$SBX" \
        --dry-run --json --cli pa --fs pc --cli pb
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.profiles[] | .type + "/" + .name]' <<< "$output")" = '["fs/pc","fs/pa","fs/pb"]' ]
    [ "$(jq -r '[.env[] | select(.name == "WHO")] | last | .value' <<< "$output")" = "b" ]
    [[ "$(jq -r '.path' <<< "$output")" == /b:/a:/c:* ]]
    nothing_created
}
```

In the existing `a forked mount shows will seed, then exists` test, change the fixture path from `profiles/cli/keep.json` to `profiles/fs/keep.json`, keep both `dry --cli keep` calls, and append:

```bash
    # The store is keyed by profile name, not by the flag that applied it.
    dry --fs keep
    [[ "$output" == *"forked  $ROOT/src → /data  (exists)"* ]]
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/dry-run.bats -f 'cli applies|forked mount'`
Expected: both FAIL: `--cli pa` is looked up under `cli/` ("Profile 'pa' of type 'cli' not found"), and so is `--cli keep`.

- [ ] **Step 3: Implement in `sbx`**

Globals: replace `CLI_PROFILE=""` with

```bash
LAST_PROFILES=()   # --cli: fs profiles applied after every --fs (compatibility)
```

`usage`: replace the `--cli` line with

```
  --cli <profile>        Apply an fs profile after every --fs one (compatibility)
```

`parse_args`, the `--cli` arm:

```bash
            --cli)
                LAST_PROFILES+=("$(resolve_profile fs "$2")")
                shift 2
                ;;
```

`resolve_plan`: replace the `FS_PROFILES` loop and the `CLI_PROFILE` block with

```bash
    for profile in "${FS_PROFILES[@]}" "${LAST_PROFILES[@]}"; do
        args+=(--fs "$profile")
    done
```

`write_session_records`, first `jq` call:

```bash
    jq -n --indent 4 --arg id "$SESSION_ID" --arg cwd "$PWD" --argjson pid "$$" \
        --argjson fs "$(sbx_resolve_strings "${FS_PROFILES[@]}" "${LAST_PROFILES[@]}")" \
        --argjson net "$(sbx_resolve_strings "${NET_PROFILES[@]}")" \
        '{id: $id, cwd: $cwd, pid: $pid, fs_profiles: $fs, net_profiles: $net}' \
        > "$SESSION_DIR/session.json"
```

Then `grep -n 'CLI_PROFILE' sbx` must print nothing.

- [ ] **Step 4: Implement in `lib/resolve.sh`**

- Locals line: `local launch_dir="" config_dir="" global_dir="" wd="" gui=false` (drop `cli=""`).
- Delete the `--cli)        cli="$2"; shift 2 ;;` arm.
- Replace the comment and the `if [[ -n "$cli" ]]` block after the fs loop, so the list is built as:
  ```bash
    # Every profile in the order the launch applies them: fs, then net.
    local -a types=() paths=() origins=()
    local p i
    for p in "${fs[@]}"; do types+=(fs); paths+=("$p"); done
    for p in "${net[@]}"; do types+=(net); paths+=("$p"); done
  ```
- In the comment `# Optional fields honored in any applied fs/cli profile:` write `fs profile:`.

- [ ] **Step 5: Move the repo profiles**

```bash
git mv profiles/cli/claude.json profiles/cli/dev.json profiles/cli/gemini.json profiles/cli/pi.json profiles/fs/
rmdir profiles/cli
```

- [ ] **Step 6: Update the existing tests**

- `tests/resolve.bats`: in `setup`, drop `"$CFG/profiles/cli"` from `mkdir`. Every `user cli <name> ...` becomes `user fs <name> ...` and every `--cli "$cli"` becomes `--fs "$cli"`. Expected `from` values `cli/c`, `cli/e` become `fs/c`, `fs/e`. Rename the tests `... PATH layers env, cli path and the default` → `... PATH layers env, path entries and the default` and `path_raw carries the unexpanded PATH env value and cli path entries, ...` → `... and path entries, ...`.
- `tests/persistent-cli.bats`: `setup` creates `$PROJ/.sbx/profiles/fs` only (drop `.../cli`). Every `cat > "$PROJ/.sbx/profiles/cli/<x>.json"` writes to `.../fs/<x>.json` instead. Keep every `--cli <x>` invocation: they now exercise the alias.
- `tests/sessions.bats`: `mkdir -p "$PROJ/.sbx/profiles/cli"` → `.../fs`, and each `cat > "$PROJ/.sbx/profiles/cli/fk.json"` → `.../fs/fk.json` (four places, including `make_fk_profile`). Remove `,"cli_profile":null` / `, cli_profile:null` from the four hand-written session.json documents. Keep `--cli fk` invocations.
- `tests/snapshot.bats`: `setup` drops `"$HOME_DIR/.config/sbx/profiles/cli"`; `write_fixture_profiles` writes `$P/fs/snapcli.json` instead of `$P/cli/snapcli.json`. Keep `--cli snapcli` in the cases.
- `tests/render.bats`: the `doc` fixture's second profile becomes `{type:"fs",name:"pi",path:"/home/u/.config/sbx/profiles/fs/pi.json",origin:"user"}`; the mount's `from:"cli/pi"` → `from:"fs/pi"`; the env entry `from:"cli/c"` → `from:"fs/c"`. Expected lines: `Profiles   fs/sandbox (global)  fs/pi (user)`, `Mounts     forked  ~/.pi → ~/.pi  (will seed, 12M)  fs/pi`, `Env        A=\$A  (fs/c; overrides fs/x)`.
- `tests/dry-run.bats`: `setup` drops `"$HOME/.config/sbx/profiles/cli"` from `mkdir`.

- [ ] **Step 7: Regenerate snapshots and review the diff**

```bash
SBX_UPDATE_SNAPSHOTS=1 bats tests/snapshot.bats
git diff --stat tests/snapshots
git diff tests/snapshots
```

Acceptable changes, and nothing else:
- every `session.json`: the `"cli_profile": ...` line is gone (and the preceding line loses its trailing comma);
- `mounts/session.json` (and any case run with `--cli snapcli`): `fs_profiles` gains `"@ROOT@/h/.config/sbx/profiles/fs/snapcli.json"` as its last entry.

If `bwrap.args`, `launch.env`, `wrapper.env`, `command` or any other file changes, stop: the PATH or mount order moved, which is a bug in Steps 3–4 or Task 1.

- [ ] **Step 8: Full suite and shellcheck**

Run: `shellcheck -x -S error sbx sbx-profile lib/*.sh tests/helpers/*.sh` → no output.
Run: `bats -j 4 tests/` → all PASS.

- [ ] **Step 9: Commit**

```bash
git add -A sbx lib/resolve.sh profiles tests
git commit -m "Make --cli apply an fs profile last, and move the cli profiles into fs

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Remove the cli type; warn about leftover cli/ directories

**Files:**
- Modify: `lib/profiles.sh` (`sbx_profile_resolve`, `sbx_profile_list`, `sbx_profile_valid_type`, `sbx_profile_template`; add `sbx_profile_legacy_cli_dirs`, `sbx_profile_legacy_cli_warning`)
- Modify: `lib/profile-check.sh` (`known`)
- Modify: `lib/resolve.sh` (add the warnings)
- Modify: `sbx-profile` (`usage`, `cmd_check`, `field_guide`, `cmd_new`)
- Test: `tests/profiles.bats`, `tests/resolve.bats`, `tests/sbx-profile.bats`, `tests/dry-run.bats`, `tests/profile-check.bats`

**Interfaces:**
- Consumes: Task 2 (nothing resolves the `cli` type any more).
- Produces:
  - `sbx_profile_legacy_cli_dirs <config_dir> <global_dir>`: prints, one per line, each of `./.sbx/profiles/cli`, `<config_dir>/profiles/cli`, `<global_dir>/cli` that holds at least one `*.json` file. Always returns 0.
  - `sbx_profile_legacy_cli_warning <dir>`: prints `cli profiles are now fs profiles, so none in <dir> are loaded; move them to <dir minus /cli>/fs`.

- [ ] **Step 1: Write the failing tests**

`tests/profiles.bats`: in `setup`, replace `"$GLOBAL/cli"` in `mkdir` with nothing and delete the `echo '{}' > "$GLOBAL/cli/dev.json"` line. Replace the `resolve strips a type prefix` test and add the rest:

```bash
@test "resolve strips a type prefix" {
    run sbx_profile_resolve fs fs/base "$CFG" "$GLOBAL"
    [ "$output" = "$GLOBAL/fs/base.json" ]
}

@test "a cli/ prefix is refused with a hint to drop it" {
    run sbx_profile_resolve fs cli/base "$CFG" "$GLOBAL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cli profiles are now fs profiles"*"'base'"* ]]
}

@test "a name found only under a cli/ directory fails with where to move it" {
    mkdir -p "$CFG/profiles/cli"
    echo '{}' > "$CFG/profiles/cli/old.json"
    run sbx_profile_resolve fs old "$CFG" "$GLOBAL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$CFG/profiles/cli/old.json"*"move it to $CFG/profiles/fs/old.json"* ]]
}

@test "legacy cli dirs: only directories holding a profile are reported" {
    run sbx_profile_legacy_cli_dirs "$CFG" "$GLOBAL"
    [ -z "$output" ]
    mkdir -p "$CFG/profiles/cli" "$GLOBAL/cli" .sbx/profiles/cli
    echo '{}' > "$GLOBAL/cli/x.json"
    echo '{}' > .sbx/profiles/cli/y.json
    run sbx_profile_legacy_cli_dirs "$CFG" "$GLOBAL"
    [ "$output" = "./.sbx/profiles/cli
$GLOBAL/cli" ]
    [ "$(sbx_profile_legacy_cli_warning "$GLOBAL/cli")" = "cli profiles are now fs profiles, so none in $GLOBAL/cli are loaded; move them to $GLOBAL/fs" ]
}

@test "the list has no CLI section and warns about a leftover cli directory" {
    mkdir -p "$CFG/profiles/cli"
    echo '{}' > "$CFG/profiles/cli/old.json"
    run sbx_profile_list "$CFG" "$GLOBAL"
    if [[ "$output" == *"CLI Profiles"* ]]; then return 1; fi
    [[ "$output" == *"Warning: cli profiles are now fs profiles, so none in $CFG/profiles/cli are loaded"* ]]
}
```

In `valid types and names`, replace `sbx_profile_valid_type cli` with `if sbx_profile_valid_type cli; then return 1; fi`. In `templates are valid and grant nothing`, loop `for type in fs net`, delete the `cli` template assertion, and change the fs one to `'{"description":"d","env":{},"passthrough":[],"mounts":[]}'`.

`tests/profile-check.bats`: in `a minimal valid profile of each type is clean`, change `check cli user` to `check fs user`.

`tests/resolve.bats`:

```bash
@test "a leftover cli directory warns, even when an fs profile of the same name loads" {
    mkdir -p "$CFG/profiles/cli"
    echo '{"env":{"MINE":"1"}}' > "$CFG/profiles/cli/claude.json"
    echo '{}' > "$GLOBAL/fs/claude.json"
    resolve --fs "$GLOBAL/fs/claude.json"
    [[ "$(r '.warnings[]')" == *"cli profiles are now fs profiles, so none in $CFG/profiles/cli are loaded; move them to $CFG/profiles/fs"* ]]
    [ "$(q .errors)" = '[]' ]
}
```

`tests/dry-run.bats`:

```bash
@test "--json carries the leftover cli directory warning" {
    mkdir -p "$HOME/.config/sbx/profiles/cli"
    echo '{}' > "$HOME/.config/sbx/profiles/cli/old.json"
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>/dev/null' _ "$PROJ" "$SBX" --dry-run --json --fs sandbox
    [ "$status" -eq 0 ]
    [[ "$(jq -r '.warnings[]' <<< "$output")" == *"none in $HOME/.config/sbx/profiles/cli are loaded"* ]]
}

@test "--cli with only a cli/ copy of the profile fails with where to move it" {
    mkdir -p "$HOME/.config/sbx/profiles/cli"
    echo '{}' > "$HOME/.config/sbx/profiles/cli/old.json"
    run bash -c 'cd "$1" && shift && "$@" < /dev/null 2>&1' _ "$PROJ" "$SBX" --dry-run --cli old
    [ "$status" -ne 0 ]
    [[ "$output" == *"move it to $HOME/.config/sbx/profiles/fs/old.json"* ]]
}
```

`tests/sbx-profile.bats`: change both `*"must be cli, fs or net"*` expectations to `*"must be fs or net"*`; in `every created profile validates`, loop `for type in fs net`. Add:

```bash
@test "new cli is refused with a pointer to fs" {
    run "$SBXP" new cli x --user
    [ "$status" -eq 2 ]
    [[ "$output" == *"cli profiles are now fs profiles"*"sbx-profile new fs x"* ]]
    if [[ -e "$HOME/.config/sbx/profiles/cli/x.json" ]]; then return 1; fi
}

@test "check refuses a cli profile by name or path, with the move hint" {
    mkdir -p "$HOME/.config/sbx/profiles/cli"
    echo '{}' > "$HOME/.config/sbx/profiles/cli/old.json"
    run "$SBXP" check cli/old
    [ "$status" -eq 2 ]
    [[ "$output" == *"cli profiles are now fs profiles"* ]]
    run "$SBXP" check "$HOME/.config/sbx/profiles/cli/old.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"move it to $HOME/.config/sbx/profiles/fs/old.json"* ]]
}

@test "check with no argument warns about a leftover cli directory and still passes" {
    mkdir -p "$HOME/.config/sbx/profiles/cli"
    echo '{}' > "$HOME/.config/sbx/profiles/cli/old.json"
    run "$SBXP" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"warning: cli profiles are now fs profiles, so none in $HOME/.config/sbx/profiles/cli are loaded"* ]]
    if [[ "$output" == *"cli/old ("* ]]; then return 1; fi
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/profiles.bats tests/resolve.bats tests/sbx-profile.bats tests/dry-run.bats tests/profile-check.bats`
Expected: the new tests FAIL (`sbx_profile_legacy_cli_dirs: command not found`, no hint text, `cli` still a valid type, fs template still `{description, mounts}`).

- [ ] **Step 3: Implement `lib/profiles.sh`**

In `sbx_profile_resolve`, after the type-prefix strip and before the `*.json`/name validation:

```bash
    # "cli/<name>" from habit: cli profiles are fs profiles now.
    if [[ "$name" == cli/* ]] && sbx_profile_valid_name "${name#cli/}"; then
        echo "Error: cli profiles are now fs profiles; name it '${name#cli/}'." >&2
        return 1
    fi
```

Replace the final `echo "Error: Profile '$name' of type '$type' not found." >&2` with:

```bash
    if [[ "$type" == fs ]]; then
        for p in "./.sbx/profiles/cli/$name.json" \
                 "$config_dir/profiles/cli/$name.json" \
                 "$global_dir/cli/$name.json"; do
            if [[ -f "$p" ]]; then
                echo "Error: Profile '$name' not found. $p is a cli profile, and cli profiles are now fs profiles: move it to ${p%/cli/*}/fs/$name.json" >&2
                return 1
            fi
        done
    fi
    echo "Error: Profile '$name' of type '$type' not found." >&2
```

Add after `sbx_profile_resolve`:

```bash
# cli profiles were folded into fs profiles; nothing loads from a cli/
# directory any more. These name the ones still holding profiles, so a
# launch, --list-profiles and sbx-profile check can say so rather than
# ignore them silently.
sbx_profile_legacy_cli_dirs() {   # <config_dir> <global_dir>
    local d f
    for d in "./.sbx/profiles/cli" "$1/profiles/cli" "$2/cli"; do
        for f in "$d"/*.json; do
            if [[ -f "$f" ]]; then
                printf '%s\n' "$d"
                break
            fi
        done
    done
    return 0
}

sbx_profile_legacy_cli_warning() {   # <dir>
    printf 'cli profiles are now fs profiles, so none in %s are loaded; move them to %s/fs\n' "$1" "${1%/cli}"
}
```

In `sbx_profile_list`: `for type in fs net; do`, and after that loop:

```bash
    local legacy
    while IFS= read -r legacy; do
        echo ""
        echo "Warning: $(sbx_profile_legacy_cli_warning "$legacy" | LC_ALL=C tr -d '\000-\037\177')"
    done < <(sbx_profile_legacy_cli_dirs "$config_dir" "$global_dir")
```

`sbx_profile_valid_type`: `[[ "$1" == "fs" || "$1" == "net" ]]`.

`sbx_profile_template`: delete the `cli)` arm; the `fs)` arm becomes

```bash
        fs)  jq -n --indent 4 --arg d "$2" '{description: $d, env: {}, passthrough: [], mounts: []}' ;;
```

- [ ] **Step 4: Implement `lib/profile-check.sh` and `lib/resolve.sh`**

`known`: delete the `cli:` line (the `{` moves to the `fs:` line).

`lib/resolve.sh`, right after the `for i in "${!paths[@]}"` origin/check loop (before `local caps_keep=false ...`):

```bash
    # A cli/ directory is never read; say so rather than let a profile
    # there be ignored silently (see sbx_profile_legacy_cli_dirs).
    local legacy
    while IFS= read -r legacy; do
        warnings+=("$(sbx_profile_legacy_cli_warning "$legacy")")
    done < <(sbx_profile_legacy_cli_dirs "$config_dir" "$global_dir")
```

- [ ] **Step 5: Implement `sbx-profile`**

`usage`: `Create a profile: fs or net. --user writes`.

`cmd_check`:
- no-argument loop: `for type in fs net; do`, and after the loop (before the `found` check):
  ```bash
        local legacy
        while IFS= read -r legacy; do
            echo "warning: $(sbx_sanitize_message "$(sbx_profile_legacy_cli_warning "$legacy")")"
        done < <(sbx_profile_legacy_cli_dirs "$CONFIG_DIR" "$GLOBAL_DIR")
  ```
- `-f "$1"` branch, before the `sbx_profile_valid_type` check:
  ```bash
        if [[ "$type" == cli ]]; then
            echo "Error: cli profiles are now fs profiles: move it to $(sbx_sanitize_message "$(dirname "$(dirname "$1")")/fs/$(basename "$1")")" >&2
            return 2
        fi
  ```
  and its error text `its directory must be cli, fs or net` → `its directory must be fs or net`.
- `<type>/<name>` branch, before `sbx_profile_valid_type`:
  ```bash
    if [[ "$type" == cli ]]; then
        echo "Error: cli profiles are now fs profiles; check fs/$(sbx_sanitize_message "$name") instead." >&2
        return 2
    fi
  ```

`field_guide`: delete the `cli)` arm; `fs)` becomes

```bash
        fs)
            echo '  mounts       [{"source": "...", "dest": "...", "perm": "ro|rw|dev|forked|record"}]'
            echo '  env          variables to set, e.g. {"EDITOR": "vim"}'
            echo '  passthrough  host variables to forward by name, e.g. ["ANTHROPIC_API_KEY"]'
            echo '  path         directories to put first on PATH'
            ;;
```

`cmd_new`, before `if ! sbx_profile_valid_type "$type"`:

```bash
    if [[ "$type" == cli ]]; then
        echo "Error: cli profiles are now fs profiles; use: sbx-profile new fs $(sbx_sanitize_message "$name")" >&2
        return 2
    fi
```

and that check's message becomes `the type must be fs or net`.

- [ ] **Step 6: Run the suites**

Run: `bats tests/profiles.bats tests/resolve.bats tests/sbx-profile.bats tests/dry-run.bats tests/profile-check.bats`
Expected: all PASS. (`ls matches sbx --list-profiles` still passes: both call `sbx_profile_list`.)

- [ ] **Step 7: shellcheck, confirm no cli type remains, commit**

```bash
shellcheck -x -S error sbx sbx-profile lib/*.sh tests/helpers/*.sh
grep -n 'cli)\|cli:' lib/*.sh sbx-profile   # expect no matches (sbx keeps only its --cli) arm)
git add lib/profiles.sh lib/profile-check.sh lib/resolve.sh sbx-profile tests
git commit -m "Drop the cli profile type, and warn about leftover cli directories

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Docs, and the full gate

**Files:**
- Modify: `README.md`
- Add: `CLAUDE.md` (currently untracked; update its Profiles section)

**Interfaces:**
- Consumes: the behaviour of Tasks 1–3.
- Produces: nothing code consumes.

- [ ] **Step 1: README**

- Line 3: `...using modular profiles for filesystem/environment and networking.`
- Features: delete the `**CLI Profiles**` bullet; the FS bullet becomes `**Filesystem (FS) Profiles**: Mounts, environment variables, PATH entries and capabilities (e.g., `claude`, `sandbox`, `podman`).`
- `--list-profiles` row: `Show all available FS and NET profiles.`
- Examples at lines ~150, ~320, ~391, ~483, ~489: use `--fs` in place of `--cli` (e.g. `./sbx --fs dev --fs chrome --net web`). The prose at ~244, ~412, ~414, ~441 says `--fs claude` / `./sbx --fs <name> --reseed`.
- Line ~156: `Profiles are JSON files in two categories — **Filesystem (FS)** and **Network (NET)** — stored under `profiles/<type>/<name>.json`.`
- Line ~166: `` `--fs`/`--net` do not accept a file path ``.
- Replace the whole `### CLI Profiles (`profiles/cli/<name>.json`)` section, down to (not including) `### Filesystem (FS) Profiles`, with nothing; then in the FS section's field table add these rows (after `mounts`) and delete the `Honored in CLI profiles too.` sentence from `docker_api`:
  ```markdown
  | `env` | object | No | Environment variables to set. A later profile's value wins. |
  | `path` | array of strings | No | Directories to put first on the sandbox `PATH`. A later profile's entries go in front of an earlier one's, and all go before any `env.PATH`. |
  | `passthrough` | array | No | Host environment variables to forward into the sandbox by name. The environment is otherwise cleared. |
  ```
  (Skip any row the table already has.) Move the two JSON examples from the deleted section under the FS section, with the second example's `"description"` kept.
- Under `### Applying Profiles` (~316), replace the first sentence with:
  ```markdown
  Profiles are applied with `--fs` and `--net`, each repeatable, in the order given. `--cli <name>` is kept for compatibility: it applies an fs profile after every `--fs` one, so its env and PATH entries win.

  Profiles used to live in a separate `cli/` directory. Nothing is loaded from `cli/` any more; if one still holds profiles, every launch, `--dry-run`, `--list-profiles` and `sbx-profile check` warn about it. Move the files to the `fs/` directory beside it. `forked` stores are keyed by profile name, so a moved profile keeps its store.
  ```

- [ ] **Step 2: CLAUDE.md**

In the `### Profiles` section, replace the three bullets and the paragraph after them with:

```markdown
Two categories, each a JSON file resolved by name (never a path) with project → user → global precedence:

- `profiles/fs/*.json` — mounts, `env`, `path`, `passthrough`, and `caps`/`userns`/`docker_api` (e.g. `claude`, `gemini`, `pi`, `dev`, `sandbox`, `podman`). Stack as many as you like; later profiles win on env and put their `path` entries first. `--cli <name>` is a compatibility alias that applies an fs profile after every `--fs` one. A leftover `cli/` directory is never read; sbx warns about it.
- `profiles/net/*.json` — egress allow-lists (`web`, `anthropic`, `gemini`).

Mount `perm` is one of `ro`, `rw`, `dev`, `forked`, `record` (`lib/profile-check.sh`). `forked` (persistent, sandbox-owned, keyed by profile name + launch dir) and `record` (ephemeral, host-owned, diffed at teardown) are the two isolating perms; see "Forked and Record Mounts" in the README.
```

Anywhere else in CLAUDE.md that says `--cli claude`, write `--fs claude`.

- [ ] **Step 3: Check nothing stale remains**

```bash
grep -n -- '--cli\|profiles/cli\|CLI Profiles' README.md CLAUDE.md sbx sbx-profile
```

Expected: only the compatibility-alias sentences, the `usage` line in `sbx`, and the legacy-warning text.

- [ ] **Step 4: Full gate**

Run: `shellcheck -x -S error sbx sbx-profile lib/*.sh tests/helpers/*.sh` → no output.
Run: `bats -j 4 tests/` → all PASS.
Run: `git diff worktree-cleanup --stat -- tests/snapshots` → only `session.json` files.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "Document fs profiles as the one profile type, and add CLAUDE.md

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
