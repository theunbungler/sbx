# Persistent CLI Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `copy` mounts declared in a **cli** profile persist across sandbox instantiations via a per-profile store, while `copy` in an **fs** profile keeps today's ephemeral behavior.

**Architecture:** The copy-mount seed and write-back logic is extracted from `sbx` into a sourceable `lib/copy-mounts.sh` so it can be unit-tested without launching a sandbox. `sbx_copy_seed` gains an optional third argument — a persistent store overlaid on top of the host copy. `sbx` then routes cli-profile copy mounts to a store under `$STATE_DIR/profiles/cli/<name>/` at both seed and teardown, leaving fs-profile mounts on the existing per-session path.

**Tech Stack:** Bash, bwrap, bats 1.13, shellcheck, rsync (optional — a pure-bash fallback already exists), jq, envsubst.

**Spec:** `docs/superpowers/specs/2026-07-23-persistent-cli-profiles-design.md`

## Global Constraints

- **No new CLI flags, profile fields, or perm keywords.** Activation is entirely `copy`-in-a-cli-profile. `--reseed` is explicitly out of scope for this plan.
- **No new runtime dependencies.** `rsync` stays optional with its existing fallback.
- **Declared perms are honoured.** Only `"perm": "copy"` mounts are affected. `ro`, `rw`, and `dev` behavior is untouched in both profile types.
- **The host source directory is never modified.** True today, must remain true.
- **The teardown diff baseline is the host source, never the store.** This is load-bearing: it is what makes a file written in session 1 survive session 3 even when session 3 never touches it. Do not "simplify" this to diffing against the store.
- **`shellcheck -S error` must pass** on `sbx` and `lib/copy-mounts.sh`. It passes on `sbx` today (verified — 4 sub-error warnings exist and are not a regression gate).
- Store path is exactly `$STATE_DIR/profiles/cli/<profile-name>/<mount_id>/` where `STATE_DIR="$HOME/.local/state/sbx"`.
- `<profile-name>` is `basename "$CLI_PROFILE" .json` — derived from the *resolved* profile path, so `--cli claude`, `--cli cli/claude`, and `--cli ./claude.json` all key the same store.

**Verified environment facts** (do not re-litigate):
- `$STATE_DIR/profiles/` cannot collide with session directories: `--list-sessions` (`sbx:123-124`) requires `$sdir/session.json`, which a store directory never has.
- `sbx` already depends on files beside it (`$SCRIPT_DIR/profiles/`, `sbx:59`), so adding `$SCRIPT_DIR/lib/` breaks no portability contract.
- `bwrap`, `rsync`, `bats` 1.13, `shellcheck`, `jq`, `envsubst`, `abduco` are all present.
- End-to-end sbx runs work non-interactively under `script -qec "<cmd>" /dev/null` — verified, including that egress lands at `$STATE_DIR/<session>/fs/<mount_id>/`.
- End-to-end tests isolate state by exporting a fake `HOME`, which works — but **the fake `HOME` must be a short path**. `sbx` ends in `abduco -c "$HOME/.local/state/sbx/<session-id>/abduco.sock"`, and a Unix socket path over ~108 chars fails with `create-session: File name too long`, silently producing an empty egress. Verified both ways. `$BATS_TEST_TMPDIR` is too long because it embeds the test name.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/copy-mounts.sh` | **Create.** Pure filesystem operations for copy mounts: mount-id derivation, seeding (with optional store overlay), and diff-based write-back. No sbx globals, no side effects at source time. |
| `sbx` | **Modify.** Sources the lib; separates fs- from cli-profile copy mounts; computes the store path; routes seed and teardown. |
| `tests/copy-mounts.bats` | **Create.** Unit tests for the lib. Fast, no sandbox. |
| `tests/persistent-cli.bats` | **Create.** End-to-end tests through real `sbx` invocations. |
| `README.md` | **Modify.** Two sections currently state the ephemeral behavior unconditionally. |

---

### Task 1: Extract copy-mount logic into a testable library

Pure refactor plus two robustness fixes. Behavior for existing users is unchanged: fs and cli `copy` mounts both still egress to `$SESSION_DIR/fs/<mount_id>/`.

The two fixes folded in here, both in code this task is already rewriting:
- `cp -a` gains `--reflink=auto`, making the seed a metadata-only CoW operation when source and destination share a btrfs/xfs filesystem (they do by default: `~/.claude` and `~/.local/state/sbx` are both under `$HOME`). Silently falls back to a full copy otherwise.
- The single-file write-back path calls `stat` on a file the sandbox may have deleted (`sbx:761`). Under `set -e` inside an `EXIT` trap that can abort teardown. Guarded with an existence check.

**Files:**
- Create: `lib/copy-mounts.sh`
- Create: `tests/copy-mounts.bats`
- Modify: `sbx:9` (source the lib), `sbx:435-454` (seed), `sbx:716-770` (teardown egress)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `sbx_copy_mount_id <dest>` → echoes the flat mount id (`/home/u/.claude` → `_home_u_.claude`)
  - `sbx_copy_seed <src> <tmp> [store]` → populates `<tmp>`; returns 0 with `<tmp>` created-but-empty if `<src>` does not exist. `[store]` is unused until Task 2.
  - `sbx_copy_writeback <src> <tmp> <out>` → copies files in `<tmp>` that differ from `<src>` into `<out>`. Never modifies `<src>`.

- [ ] **Step 1: Write the failing tests**

Create `tests/copy-mounts.bats`:

```bash
#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/copy-mounts.sh"
    WORK="$BATS_TEST_TMPDIR/w"
    SRC="$WORK/src"; TMP="$WORK/tmp"; OUT="$WORK/out"
    mkdir -p "$SRC"
}

@test "mount_id flattens a destination path" {
    run sbx_copy_mount_id "/home/user/.claude"
    [ "$output" = "_home_user_.claude" ]
}

@test "seed copies a directory's contents from the host" {
    echo hello > "$SRC/a.txt"
    sbx_copy_seed "$SRC" "$TMP"
    [ "$(cat "$TMP/a.txt")" = "hello" ]
}

@test "seed copies a single file into the working directory" {
    echo hi > "$WORK/one.txt"
    sbx_copy_seed "$WORK/one.txt" "$TMP"
    [ "$(cat "$TMP/one.txt")" = "hi" ]
}

@test "seed is a no-op when the source does not exist" {
    sbx_copy_seed "$WORK/missing" "$TMP"
    [ -d "$TMP" ]
    [ -z "$(ls -A "$TMP")" ]
}

@test "writeback captures a file the sandbox created" {
    echo hello > "$SRC/a.txt"
    sbx_copy_seed "$SRC" "$TMP"
    echo new > "$TMP/b.txt"
    sbx_copy_writeback "$SRC" "$TMP" "$OUT"
    [ "$(cat "$OUT/b.txt")" = "new" ]
}

@test "writeback captures a file the sandbox modified" {
    echo hello > "$SRC/a.txt"
    sbx_copy_seed "$SRC" "$TMP"
    echo changed-and-longer > "$TMP/a.txt"
    sbx_copy_writeback "$SRC" "$TMP" "$OUT"
    [ "$(cat "$OUT/a.txt")" = "changed-and-longer" ]
}

@test "writeback ignores a file the sandbox did not touch" {
    echo hello > "$SRC/a.txt"
    sbx_copy_seed "$SRC" "$TMP"
    sbx_copy_writeback "$SRC" "$TMP" "$OUT"
    [ ! -f "$OUT/a.txt" ]
}

@test "writeback never modifies the host source" {
    echo hello > "$SRC/a.txt"
    sbx_copy_seed "$SRC" "$TMP"
    echo clobbered > "$TMP/a.txt"
    echo new > "$TMP/b.txt"
    sbx_copy_writeback "$SRC" "$TMP" "$OUT"
    [ "$(cat "$SRC/a.txt")" = "hello" ]
    [ ! -f "$SRC/b.txt" ]
}

@test "writeback handles a single-file source deleted in the sandbox" {
    echo hi > "$WORK/one.txt"
    sbx_copy_seed "$WORK/one.txt" "$TMP"
    rm "$TMP/one.txt"
    run sbx_copy_writeback "$WORK/one.txt" "$TMP" "$OUT"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/copy-mounts.bats`
Expected: all fail — `source: .../lib/copy-mounts.sh: No such file or directory`

- [ ] **Step 3: Create the library**

Create `lib/copy-mounts.sh`:

```bash
#!/bin/bash
# Copy-mount seeding and write-back.
#
# Sourced by sbx and directly by tests/. Defines functions only — no side
# effects at source time, no dependency on sbx globals.

# Translate a sandbox destination path into the flat identifier used for
# tmp_mounts/, per-session egress, and persistent store directories.
#   /home/user/.claude -> _home_user_.claude
sbx_copy_mount_id() {
    echo "$1" | tr '/' '_'
}

# Populate a copy mount's working directory.
#   $1 src   - host source path (file or directory)
#   $2 tmp   - working directory to populate
#   $3 store - optional persistent store, overlaid on top of the host copy
#
# --reflink=auto makes this metadata-only on btrfs/xfs when src and tmp
# share a filesystem, and silently falls back to a full copy otherwise.
sbx_copy_seed() {
    local src="$1" tmp="$2" store="${3:-}"

    mkdir -p "$tmp"

    if [[ -d "$src" ]]; then
        cp -a --reflink=auto "$src/." "$tmp/"
    elif [[ -f "$src" ]]; then
        cp -a --reflink=auto "$src" "$tmp/"
    else
        return 0
    fi

    # Store entries win over the host copy, per file.
    if [[ -n "$store" && -d "$store" ]]; then
        cp -a --reflink=auto "$store/." "$tmp/"
    fi
}

# Copy files that differ from the host source into an output directory.
#   $1 src - host source path; the diff baseline, never modified
#   $2 tmp - the session's working copy
#   $3 out - destination for changed files
#
# Never prunes $out: entries it does not write are left alone.
sbx_copy_writeback() {
    local src="$1" tmp="$2" out="$3"

    mkdir -p "$out"

    if [[ -d "$src" ]]; then
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --compare-dest="$src/" "$tmp/" "$out/"
        else
            (
                cd "$tmp" || exit 0
                find . -type f -print0 | while IFS= read -r -d '' rel_path; do
                    rel_path="${rel_path#./}"
                    local file="$tmp/$rel_path"
                    local orig_file="$src/$rel_path"

                    local needs_copy=0
                    if [[ ! -f "$orig_file" ]]; then
                        needs_copy=1
                    elif [[ $(stat -c %s "$file") -ne $(stat -c %s "$orig_file") ]] || \
                         [[ $(stat -c %Y "$file") -gt $(stat -c %Y "$orig_file") ]]; then
                        needs_copy=1
                    fi

                    if [[ $needs_copy -eq 1 ]]; then
                        mkdir -p "$(dirname "$out/$rel_path")"
                        cp -a "$file" "$out/$rel_path"
                    fi
                done
            )
        fi
    elif [[ -f "$src" ]]; then
        local filename file
        filename=$(basename "$src")
        file="$tmp/$filename"

        # The sandbox may have deleted it; nothing to write back if so.
        [[ -f "$file" ]] || return 0

        if [[ $(stat -c %s "$file") -ne $(stat -c %s "$src") ]] || \
           [[ $(stat -c %Y "$file") -gt $(stat -c %Y "$src") ]]; then
            cp -a "$file" "$out/$filename"
        fi
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/copy-mounts.bats`
Expected: 9 tests, all PASS

- [ ] **Step 5: Source the library from sbx**

In `sbx`, immediately after the `SCRIPT_DIR` assignment (line 9), add:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/copy-mounts.sh
source "$SCRIPT_DIR/lib/copy-mounts.sh"
```

- [ ] **Step 6: Replace the inline seed block**

Replace `sbx:435-454` (the block beginning `# Pre-population for copy mounts`, ending at the `done` before the blank line preceding `# Parse Environment and Working Directory`) with:

```bash
# Pre-population for copy mounts
mkdir -p "$SESSION_DIR/tmp_mounts"

for cm in "${COPY_MOUNTS[@]}"; do
    src="${cm%%:*}"
    dst="${cm#*:}"

    mount_id=$(sbx_copy_mount_id "$dst")
    tmp_src="$SESSION_DIR/tmp_mounts/$mount_id"

    sbx_copy_seed "$src" "$tmp_src"

    if [[ -d "$src" ]]; then
        BWRAP_ARGS+=(--tmpfs "$dst")
        BWRAP_ARGS+=(--bind "$tmp_src" "$dst")
    elif [[ -f "$src" ]]; then
        BWRAP_ARGS+=(--bind "$tmp_src/$(basename "$src")" "$dst")
    fi
done
```

- [ ] **Step 7: Replace the inline teardown egress block**

Replace `sbx:716-770` (from `    # Egress for copy mounts` through the `    done` that closes that loop, leaving `rm -rf "$SESSION_DIR/tmp_mounts"` intact) with:

```bash
    # Egress for copy mounts
    for cm in "${COPY_MOUNTS[@]}"; do
        src="${cm%%:*}"
        dst="${cm#*:}"
        mount_id=$(sbx_copy_mount_id "$dst")
        sbx_copy_writeback "$src" "$SESSION_DIR/tmp_mounts/$mount_id" "$SESSION_DIR/fs/$mount_id"
    done
```

- [ ] **Step 8: Verify the refactor preserved behavior**

Run:
```bash
shellcheck -S error sbx lib/copy-mounts.sh
bats tests/copy-mounts.bats
```
Expected: shellcheck silent (exit 0); 9 tests PASS.

Then a manual end-to-end smoke check that egress still works:
```bash
T=$(mktemp -d) && mkdir -p "$T/proj/.sbx/profiles/cli" "$T/hostdir"
echo hostfile > "$T/hostdir/host.txt"
cat > "$T/proj/.sbx/profiles/cli/tst.json" <<EOF
{"description":"test","mounts":[{"source":"$T/hostdir","dest":"/tmp/tstmount","perm":"copy"}]}
EOF
(cd "$T/proj" && script -qec "$PWD/../../sbx --cli tst -- /bin/sh -c 'echo made > /tmp/tstmount/new.txt'" /dev/null)
find ~/.local/state/sbx -name new.txt -newermt '-2 minutes'
```
Expected: a path ending `.../fs/_tmp_tstmount/new.txt` is printed.

- [ ] **Step 9: Commit**

```bash
git add lib/copy-mounts.sh tests/copy-mounts.bats sbx
git commit -m "Extract copy-mount seed and write-back into a testable library

Behavior-preserving, with two fixes in the code being moved: cp gains
--reflink=auto, and single-file write-back no longer stats a file the
sandbox may have deleted."
```

---

### Task 2: Overlay a persistent store during seeding

Teaches `sbx_copy_seed` to use its third argument. Nothing calls it with a store yet, so this task changes no observable `sbx` behavior — it is gated purely on its own tests.

**Files:**
- Modify: `lib/copy-mounts.sh` (already accepts and applies `$3` from Task 1 — verify, do not duplicate)
- Modify: `tests/copy-mounts.bats`

**Interfaces:**
- Consumes: `sbx_copy_seed <src> <tmp> [store]`, `sbx_copy_writeback <src> <tmp> <out>` from Task 1.
- Produces: no new symbols. Establishes the overlay contract Task 3 depends on: store entries win per file; host entries absent from the store still come through; a nonexistent store is not an error.

- [ ] **Step 1: Write the failing tests**

Append to `tests/copy-mounts.bats` (and add `STORE="$WORK/store"` to the `setup()` assignments alongside `OUT`):

```bash
@test "seed overlays store entries on top of the host copy" {
    echo host > "$SRC/a.txt"
    mkdir -p "$STORE"
    echo stored > "$STORE/a.txt"
    sbx_copy_seed "$SRC" "$TMP" "$STORE"
    [ "$(cat "$TMP/a.txt")" = "stored" ]
}

@test "seed brings through host files absent from the store" {
    echo host > "$SRC/a.txt"
    echo hostonly > "$SRC/b.txt"
    mkdir -p "$STORE"
    echo stored > "$STORE/a.txt"
    sbx_copy_seed "$SRC" "$TMP" "$STORE"
    [ "$(cat "$TMP/b.txt")" = "hostonly" ]
}

@test "seed brings through store files absent from the host" {
    echo host > "$SRC/a.txt"
    mkdir -p "$STORE"
    echo storeonly > "$STORE/c.txt"
    sbx_copy_seed "$SRC" "$TMP" "$STORE"
    [ "$(cat "$TMP/c.txt")" = "storeonly" ]
}

@test "seed tolerates a store that does not exist yet" {
    echo host > "$SRC/a.txt"
    sbx_copy_seed "$SRC" "$TMP" "$WORK/no-such-store"
    [ "$(cat "$TMP/a.txt")" = "host" ]
}

@test "seed overlays nested store paths" {
    mkdir -p "$SRC/sub"
    echo host > "$SRC/sub/a.txt"
    mkdir -p "$STORE/sub"
    echo stored > "$STORE/sub/a.txt"
    sbx_copy_seed "$SRC" "$TMP" "$STORE"
    [ "$(cat "$TMP/sub/a.txt")" = "stored" ]
}

# The load-bearing one: proves the diff baseline must be the host source.
# b.txt came from the store, was never touched this session, and must
# still be in the store afterwards.
@test "a stored file survives a session that never touches it" {
    echo host > "$SRC/a.txt"
    mkdir -p "$STORE"
    echo stored > "$STORE/b.txt"
    sbx_copy_seed "$SRC" "$TMP" "$STORE"
    sbx_copy_writeback "$SRC" "$TMP" "$STORE"
    [ "$(cat "$STORE/b.txt")" = "stored" ]
}
```

- [ ] **Step 2: Run tests**

Run: `bats tests/copy-mounts.bats`
Expected: 15 tests, all PASS — Task 1's implementation already satisfies these.

If any fail, fix `sbx_copy_seed` in `lib/copy-mounts.sh`; the overlay must be `cp -a --reflink=auto "$store/." "$tmp/"` applied *after* the host copy, guarded by `[[ -n "$store" && -d "$store" ]]`.

- [ ] **Step 3: Commit**

```bash
git add tests/copy-mounts.bats lib/copy-mounts.sh
git commit -m "Cover the persistent-store overlay contract in copy-mount seeding"
```

---

### Task 3: Route cli-profile copy mounts to a per-profile store

The behavior change. Separates cli- from fs-profile copy mounts and points the cli ones at `$STATE_DIR/profiles/cli/<name>/` for both seed and write-back.

**Files:**
- Modify: `sbx:376` (array declarations), `sbx:378-379` + `sbx:420-422` (`apply_mounts` kind), `sbx:427-433` (call sites), after `sbx:218` (store path), seed block, teardown block
- Create: `tests/persistent-cli.bats`

**Interfaces:**
- Consumes: `sbx_copy_mount_id`, `sbx_copy_seed <src> <tmp> [store]`, `sbx_copy_writeback` from Tasks 1-2.
- Produces: shell variables `CLI_PROFILE_NAME` and `CLI_STORE_DIR` (empty when no `--cli` profile is applied); array `CLI_COPY_MOUNTS` holding `source:dest` entries.

- [ ] **Step 1: Write the failing tests**

Create `tests/persistent-cli.bats`:

```bash
#!/usr/bin/env bats

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"

    # NOT $BATS_TEST_TMPDIR — it embeds the test name, and sbx's abduco
    # socket at $HOME/.local/state/sbx/<session-id>/abduco.sock would blow
    # the ~108-char sun_path limit, failing with "create-session: File name
    # too long" before the command ever runs. Verified: a long HOME fails,
    # /tmp/sbxh.XXXXXX (66 chars total) works. Keep this path short.
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    STORE_ROOT="$HOME/.local/state/sbx/profiles/cli"
    PROJ="$ROOT/p"
    HOSTDIR="$ROOT/s"
    mkdir -p "$HOME" "$PROJ/.sbx/profiles/cli" "$PROJ/.sbx/profiles/fs" "$HOSTDIR"
    echo hostfile > "$HOSTDIR/host.txt"

    cat > "$PROJ/.sbx/profiles/cli/tst.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/tstmount","perm":"copy"}]}
EOF
    cat > "$PROJ/.sbx/profiles/fs/tstfs.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/tstmount","perm":"copy"}]}
EOF
}

teardown() {
    [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]] && rm -rf "$ROOT"
}

# Run a shell command inside a sandbox. sbx ends in `abduco -c`, which
# needs a pty; `script -qec` supplies one non-interactively.
run_sbx() {
    ( cd "$PROJ" && script -qec "$SBX $1 -- /bin/sh -c '$2'" /dev/null >/dev/null 2>&1 )
}

@test "a cli copy mount persists a new file into the profile store" {
    run_sbx "--cli tst" "echo made > /tmp/tstmount/new.txt"
    [ "$(cat "$STORE_ROOT/tst/_tmp_tstmount/new.txt")" = "made" ]
}

@test "a file created in one session is visible in the next" {
    run_sbx "--cli tst" "echo made > /tmp/tstmount/new.txt"
    run_sbx "--cli tst" "cp /tmp/tstmount/new.txt /tmp/tstmount/echoed.txt"
    [ "$(cat "$STORE_ROOT/tst/_tmp_tstmount/echoed.txt")" = "made" ]
}

@test "a stored file survives a session that never touches it" {
    run_sbx "--cli tst" "echo made > /tmp/tstmount/new.txt"
    run_sbx "--cli tst" "true"
    [ -f "$STORE_ROOT/tst/_tmp_tstmount/new.txt" ]
}

@test "host changes reach the sandbox for files it has not touched" {
    run_sbx "--cli tst" "echo made > /tmp/tstmount/new.txt"
    echo updated > "$HOSTDIR/host.txt"
    run_sbx "--cli tst" "cp /tmp/tstmount/host.txt /tmp/tstmount/seen.txt"
    [ "$(cat "$STORE_ROOT/tst/_tmp_tstmount/seen.txt")" = "updated" ]
}

@test "the store shadows later host changes to the same file" {
    run_sbx "--cli tst" "echo sandbox > /tmp/tstmount/host.txt"
    echo updated > "$HOSTDIR/host.txt"
    run_sbx "--cli tst" "cp /tmp/tstmount/host.txt /tmp/tstmount/seen.txt"
    [ "$(cat "$STORE_ROOT/tst/_tmp_tstmount/seen.txt")" = "sandbox" ]
}

@test "a file deleted in the sandbox returns on the next launch" {
    run_sbx "--cli tst" "rm /tmp/tstmount/host.txt"
    run_sbx "--cli tst" "test -f /tmp/tstmount/host.txt && echo back > /tmp/tstmount/back.txt"
    [ -f "$STORE_ROOT/tst/_tmp_tstmount/back.txt" ]
}

@test "fs profile copy mounts stay ephemeral and create no store" {
    run_sbx "--fs tstfs" "echo made > /tmp/tstmount/new.txt"
    [ ! -d "$HOME/.local/state/sbx/profiles" ]
    run bash -c "find '$HOME/.local/state/sbx' -path '*/fs/_tmp_tstmount/new.txt'"
    [ -n "$output" ]
}

@test "the host source directory is never modified" {
    run_sbx "--cli tst" "echo sandbox > /tmp/tstmount/host.txt; echo x > /tmp/tstmount/new.txt"
    [ "$(cat "$HOSTDIR/host.txt")" = "hostfile" ]
    [ ! -f "$HOSTDIR/new.txt" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/persistent-cli.bats`
Expected: the seven `--cli` tests FAIL (no `$STORE_ROOT` is ever created); "fs profile copy mounts stay ephemeral" PASSES already.

- [ ] **Step 3: Split the copy-mount arrays by profile type**

In `sbx`, replace line 376:

```bash
COPY_MOUNTS=()     # fs-profile copy mounts,  "source:dest" — ephemeral
CLI_COPY_MOUNTS=() # cli-profile copy mounts, "source:dest" — persistent
```

Change the `apply_mounts` signature (line 379) to take the profile kind:

```bash
apply_mounts() {
    local profile="$1" kind="${2:-fs}"
```

Replace the `copy)` case (lines 420-422) with:

```bash
            copy)
                # `copy` means different things by profile type: ephemeral
                # snapshot in an fs profile, persistent overlay in a cli
                # profile. See docs/superpowers/specs/2026-07-23-persistent-cli-profiles-design.md
                if [[ "$kind" == "cli" ]]; then
                    CLI_COPY_MOUNTS+=("$source:$dest")
                else
                    COPY_MOUNTS+=("$source:$dest")
                fi
                ;;
```

Replace the call sites (lines 427-433):

```bash
for profile in "${FS_PROFILES[@]}"; do
    apply_mounts "$profile" fs
done

if [[ -n "$CLI_PROFILE" ]]; then
    apply_mounts "$CLI_PROFILE" cli
fi
```

- [ ] **Step 4: Compute the store path**

In `sbx`, immediately after the Session Initialization block (after `mkdir -p "$SESSION_DIR/tmp"`, line 220), add:

```bash
# Persistent store for cli-profile copy mounts, keyed by profile name so
# that every `--cli <name>` session shares one identity. Derived from the
# resolved path, so `--cli claude`, `--cli cli/claude` and
# `--cli ./claude.json` all key the same store. Safe to live under
# STATE_DIR: --list-sessions only considers directories with a
# session.json, which this never has.
CLI_PROFILE_NAME=""
CLI_STORE_DIR=""
if [[ -n "$CLI_PROFILE" ]]; then
    CLI_PROFILE_NAME=$(basename "$CLI_PROFILE" .json)
    CLI_STORE_DIR="$STATE_DIR/profiles/cli/$CLI_PROFILE_NAME"
fi
```

- [ ] **Step 5: Route seeding**

Replace the seed block written in Task 1 Step 6 with:

```bash
# Pre-population for copy mounts. fs-profile mounts are seeded from the
# host alone; cli-profile mounts additionally overlay the profile's
# persistent store, so the previous session's changes come back.
mkdir -p "$SESSION_DIR/tmp_mounts"

seed_copy_mount() {
    local src="$1" dst="$2" store="$3"
    local mount_id tmp_src
    mount_id=$(sbx_copy_mount_id "$dst")
    tmp_src="$SESSION_DIR/tmp_mounts/$mount_id"

    sbx_copy_seed "$src" "$tmp_src" "$store"

    if [[ -d "$src" ]]; then
        BWRAP_ARGS+=(--tmpfs "$dst")
        BWRAP_ARGS+=(--bind "$tmp_src" "$dst")
    elif [[ -f "$src" ]]; then
        BWRAP_ARGS+=(--bind "$tmp_src/$(basename "$src")" "$dst")
    fi
}

for cm in "${COPY_MOUNTS[@]}"; do
    seed_copy_mount "${cm%%:*}" "${cm#*:}" ""
done

for cm in "${CLI_COPY_MOUNTS[@]}"; do
    dst="${cm#*:}"
    seed_copy_mount "${cm%%:*}" "$dst" "$CLI_STORE_DIR/$(sbx_copy_mount_id "$dst")"
done
```

- [ ] **Step 6: Route write-back**

Replace the teardown block written in Task 1 Step 7 with:

```bash
    # Egress for copy mounts. fs-profile mounts land in this session's
    # fs/ directory; cli-profile mounts land in the profile's persistent
    # store, where the next --cli session of the same name picks them up.
    # The diff baseline is the host source in BOTH cases — that is what
    # keeps a file written in an earlier session in the store even when
    # this session never touched it.
    for cm in "${COPY_MOUNTS[@]}"; do
        src="${cm%%:*}"
        dst="${cm#*:}"
        mount_id=$(sbx_copy_mount_id "$dst")
        sbx_copy_writeback "$src" "$SESSION_DIR/tmp_mounts/$mount_id" "$SESSION_DIR/fs/$mount_id"
    done

    for cm in "${CLI_COPY_MOUNTS[@]}"; do
        src="${cm%%:*}"
        dst="${cm#*:}"
        mount_id=$(sbx_copy_mount_id "$dst")
        sbx_copy_writeback "$src" "$SESSION_DIR/tmp_mounts/$mount_id" "$CLI_STORE_DIR/$mount_id"
    done
```

- [ ] **Step 7: Run tests to verify they pass**

Run:
```bash
shellcheck -S error sbx lib/copy-mounts.sh
bats tests/copy-mounts.bats tests/persistent-cli.bats
```
Expected: shellcheck silent; 15 + 8 = 23 tests PASS.

- [ ] **Step 8: Commit**

```bash
git add sbx tests/persistent-cli.bats
git commit -m "Make cli-profile copy mounts persist across sandbox instantiations

copy in a cli profile now seeds from the host and overlays a per-profile
store, writing changed files back to that store at teardown. copy in an
fs profile is unchanged."
```

---

### Task 4: Document the split semantics

`README.md` currently describes `copy` as unconditionally ephemeral in two places. Both are now wrong for cli profiles.

**Files:**
- Modify: `README.md:118` (perm table row), `README.md:124` (permission modes bullet), `README.md:214-231` ("Copy Mount Egress" section)

**Interfaces:**
- Consumes: the store layout established in Task 3.
- Produces: nothing.

- [ ] **Step 1: Update the perm table row**

In the Mount Object table, replace the `perm` row description with:

```
| `perm` | string | Yes | Mount permission: one of `ro` (read-only bind), `rw` (read-write bind), `dev` (device bind, for files under `/dev`), or `copy` (writable snapshot — see below; behavior differs between fs and cli profiles) |
```

- [ ] **Step 2: Update the permission modes bullet**

Replace the `copy` bullet with:

```markdown
- **`copy`** — Writable snapshot. The source is copied into a session-local working directory at start and bound into the sandbox; the original host path is never modified. What happens to the changes depends on the profile type:
  - In an **fs** profile, changes are **ephemeral**. At teardown, new or modified files are saved to `~/.local/state/sbx/<session-id>/fs/<mount_id>/` and nothing is carried into the next session.
  - In a **cli** profile, changes are **persistent**. They are saved to `~/.local/state/sbx/profiles/cli/<profile-name>/<mount_id>/` and replayed on top of the host copy the next time that profile is used, so a CLI tool's sessions, history, and local config survive across sandboxes.
```

- [ ] **Step 3: Rewrite the Copy Mount Egress section**

Replace the "Copy Mount Egress" section body with:

```markdown
## Copy Mount Egress

With `copy` mounts, the sandbox isolates changes from the host. At teardown, `sbx` compares the working copy against the **original host source** and saves only the files that are **new or modified**. Where they are saved depends on the profile the mount was declared in.

**fs profiles — ephemeral.** Changes go to `~/.local/state/sbx/<session-id>/fs/<mount_id>/` and stay there. Each session starts from the host's state.

**cli profiles — persistent.** Changes go to `~/.local/state/sbx/profiles/cli/<profile-name>/<mount_id>/`, and the next session using that profile overlays this store on top of a fresh copy of the host source. This is what lets `sbx --cli claude` resume with the sessions and history it accumulated last time.

In both cases:
- The **original host directory is never modified**.
- Only **changed files** are written; the comparison baseline is always the host source, never the store.
- The egress uses `rsync --compare-dest` when available, otherwise a file-by-file size and timestamp comparison.
- The session's temporary working copies are cleaned up afterwards.

**Persistent store behavior.** Two consequences follow from the overlay model and are intentional:

- **Deletions do not persist.** A file deleted inside the sandbox is restored from the host on the next launch — the host directory is the floor. If you want it gone, delete it from the store.
- **Written files shadow the host.** Once a session writes a given file, the store's version wins on every later launch, so subsequent host-side edits to *that file* are not seen. Host changes to files the sandbox has never touched still come through normally. To start over, delete the profile's store directory.

The profile name is the store key: every `sbx --cli claude`, in any directory, shares one store. Concurrent sessions are allowed and are not locked — write-back is per file, and the last session to tear down wins for any file it changed. This matches how the CLI tools already behave across concurrent sessions on the host.

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
        _home_user_.claude/    # persistent store for `--cli claude`
        _home_user_.claude.json
```
```

- [ ] **Step 4: Verify the docs match reality**

Run:
```bash
grep -n "profiles/cli" README.md
bats tests/persistent-cli.bats
```
Expected: the README store path matches the path asserted in the tests (`.../state/sbx/profiles/cli/<name>/<mount_id>/`); 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Document copy-mount semantics as profile-type dependent"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| `copy` semantic chosen by profile type | 3 (steps 3, 5, 6) |
| cli profile name is the store key | 3 (step 4) |
| Declared perms still honoured — only `copy` affected | 3 (step 3; `ro`/`rw`/`dev` cases untouched) |
| Overlay, not replacement | 2 (tests), 1 (impl) |
| Store at `$STATE_DIR/profiles/cli/<name>/<mount_id>/` | 3 (step 4) |
| Diff baseline stays the host source | 2 ("survives a session that never touches it"), 3 (step 6 + comment) |
| No locking; last-teardown-wins; never prunes the store | 1 (`sbx_copy_writeback` never deletes), 4 (documented) |
| `cp -a --reflink=auto` | 1 (step 3) |
| fs-profile `copy` unchanged | 3 ("fs profile copy mounts stay ephemeral", passes before *and* after) |
| Deletions do not stick | 3 ("a file deleted in the sandbox returns"), 4 |
| Shadowing | 3 ("the store shadows later host changes"), 4 |
| Host source never modified | 1 ("writeback never modifies the host source"), 3 (e2e equivalent) |
| README updated in both places | 4 |
| `--reseed` | Out of scope — deferred by the spec, flagged in Global Constraints |

No gaps.

**Placeholder scan:** No TBD/TODO, no "add error handling", no "similar to Task N". Every code step carries complete code; every test step carries complete test bodies.

**Type consistency:** `sbx_copy_mount_id`, `sbx_copy_seed`, `sbx_copy_writeback` are spelled identically in the library, in both test files, and at all four `sbx` call sites. `CLI_COPY_MOUNTS`, `CLI_STORE_DIR`, and `CLI_PROFILE_NAME` are consistent between Task 3 steps 3, 4, 5 and 6. `seed_copy_mount`'s three parameters match both loops that call it.

**One deliberate ordering note:** Task 2 is expected to pass immediately against Task 1's implementation, because Task 1 writes the store overlay into `sbx_copy_seed` as part of the extracted function. Task 2 is therefore a test-only gate that locks the contract before Task 3 depends on it, rather than a red-to-green cycle. Its step 2 says so explicitly and tells the implementer what to fix if it does go red.
