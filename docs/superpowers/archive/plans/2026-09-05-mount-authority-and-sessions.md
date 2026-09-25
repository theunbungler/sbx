# Mount Authority and Session Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the profile-type-dependent `copy` mount perm with `forked`
and `record`, which declare per mount whether the sandbox or the host owns
the data, and make session directories ephemeral so `--list-sessions` stops
accumulating dead entries.

**Architecture:** `forked` seeds a per-(profile, launch-dir) store from the
host once and thereafter plain-binds it — no overlay, no diff, no writeback.
`record` copies the host source into a per-session working copy, hashes it
into a manifest at launch, and at teardown diffs the working copy against
*that manifest* (not the live host) to produce a retained change archive.
Nothing durable remains in a session directory, so it is deleted on exit.

**Tech Stack:** bash 5, bubblewrap, jq, coreutils (`cp --reflink=auto`,
`sha256sum`, `comm`, `du`, `stat`), bats 1.13, shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-05-mount-authority-and-sessions-design.md`

## Global Constraints

Every task's requirements implicitly include these.

- **No new runtime dependencies.** Only what `sbx` already requires: `jq`,
  `bwrap`, `tmux`, and coreutils/findutils. `rsync` is being *removed* as a
  dependency, not added to.
- **`shellcheck -S error sbx lib/copy-mounts.sh` must be silent.** Four
  sub-error warnings pre-exist in `sbx` and are not a regression gate. Run
  this before every commit.
- **The host source is never written.** For every perm except `rw`, a test
  asserting the host source is byte-identical after a session is mandatory.
- **E2E tests need a short `$HOME`.** `sbx` binds a tmux socket at
  `$HOME/.local/state/sbx/sessions/<name>/tmux.sock`, and a Unix socket path
  over ~108 bytes fails *quietly* with "File name too long". Use
  `ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"`, never `$BATS_TEST_TMPDIR` (it
  embeds the test name). Budget: 16 (`/tmp/sbxh.XXXXXX`) + 2 (`/h`) + 17
  (`/.local/state/sbx`) + 9 (`/sessions`) + 33 (`/` + 32-char name) + 10
  (`/tmux.sock`) = 87 bytes. This is why session names are capped at 32.
- **E2E tests need a pty.** Drive `sbx` with
  `script -qec "$SBX ... " /dev/null`.
- **Any suite with fixtures under `./.sbx/profiles` must
  `export SBX_TRUST_PROJECT_PROFILES=1` in `setup()`**, or every launch
  blocks forever on the confirmation prompt.
- **`! cmd` assertions are no-ops except on the last line of a `@test`.**
  bash's `set -e` ignores a command whose status is inverted with `!`, and
  bats relies on `set -e` to fail at the offending line. Write assertions
  long-hand:
  ```bash
  if grep -q bad "$f"; then echo "leaked" >&2; return 1; fi
  ```
  This has already cost one genuine undetected leak in this repo.
- **Delimiter for mount tuples is TAB, not `:`.** The existing
  `"source:dest"` encoding breaks on paths containing colons. New arrays use
  `$'\t'` and are read with `IFS=$'\t' read -r`.
- **`<profile>` in a store path is the basename of the profile file that
  declared the mount**, with `.json` stripped — for cli *and* fs profiles
  alike. This generalizes the old `CLI_PROFILE_NAME` keying; for cli
  profiles the resulting path is unchanged, which is what makes the
  migration in Task 4 a plain `mv`.

---

## File Structure

- `lib/copy-mounts.sh` — keeps `sbx_copy_mount_id`, `sbx_copy_path_slug`,
  `sbx_copy_seed` (minus its store-overlay branch); gains
  `sbx_manifest_build`, `sbx_manifest_changed`, `sbx_manifest_deleted`;
  loses `sbx_copy_writeback` entirely. Filename is retained despite being a
  slight misnomer, to keep the diff reviewable.
- `sbx` — perm dispatch in `apply_mounts`, seeding, teardown, session
  naming and layout, the three new flags, progress reporting.
- `profiles/cli/*.json`, `profiles/fs/default.json` — `copy` → `forked` /
  `record`.
- `tests/copy-mounts.bats` — unit tests for the manifest functions.
- `tests/persistent-cli.bats` — `forked` and `record` e2e.
- `tests/sessions.bats` — **new** — naming, liveness, GC.
- `tests/hardening.bats`, `tests/join.bats` — updated for the new layout.

**One deliberate deviation from the spec.** Its "What this deletes" section
calls for `COPY_MOUNTS`/`CLI_COPY_MOUNTS` to be replaced by *one* list
carrying a perm discriminator. This plan uses two arrays instead,
`FORKED_MOUNTS` and `RECORD_MOUNTS`, because the two perms share no
processing: forked seeds conditionally and does nothing at teardown, record
seeds unconditionally, builds a manifest, and archives. A discriminated
single list would be branched on at every use, which is a merge that buys
nothing. The spec's underlying point — that the *profile type* no longer
selects behavior — holds either way.

---

### Task 1: Manifest primitives

Pure functions in the library, no `sbx` changes. Additive: the tree stays
green throughout this task.

**Files:**
- Modify: `lib/copy-mounts.sh` (append)
- Test: `tests/copy-mounts.bats` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `sbx_manifest_build <tree> <out_file>` — writes a sorted manifest of
    `<sha256><2 spaces><relpath>` lines for every regular file under
    `<tree>`. Empty file if `<tree>` is absent. Returns 0 always.
  - `sbx_manifest_changed <base_manifest> <cur_manifest>` — prints, one per
    line, the relative paths present in `cur` whose content differs from
    `base` or which are absent from `base` (i.e. added or modified).
  - `sbx_manifest_deleted <base_manifest> <cur_manifest>` — prints, one per
    line, the relative paths present in `base` and absent from `cur`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/copy-mounts.bats`:

```bash
@test "manifest_build records a hash per file" {
    mkdir -p "$SRC/sub"
    echo one > "$SRC/a.txt"
    echo two > "$SRC/sub/b.txt"
    sbx_manifest_build "$SRC" "$WORK/m"
    [ "$(wc -l < "$WORK/m")" -eq 2 ]
    grep -q ' a.txt$' "$WORK/m"
    grep -q ' sub/b.txt$' "$WORK/m"
}

@test "manifest_build on a missing tree yields an empty manifest" {
    sbx_manifest_build "$WORK/nope" "$WORK/m"
    [ -f "$WORK/m" ]
    [ ! -s "$WORK/m" ]
}

@test "manifest_build handles spaces in filenames" {
    echo hi > "$SRC/two words.txt"
    sbx_manifest_build "$SRC" "$WORK/m"
    grep -q ' two words.txt$' "$WORK/m"
}

@test "manifest_changed reports an added file" {
    echo one > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    echo new > "$SRC/b.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_changed "$WORK/base" "$WORK/cur"
    [ "$output" = "b.txt" ]
}

@test "manifest_changed reports a modified file" {
    echo one > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    echo changed > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_changed "$WORK/base" "$WORK/cur"
    [ "$output" = "a.txt" ]
}

@test "manifest_changed ignores an untouched file" {
    echo one > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_changed "$WORK/base" "$WORK/cur"
    [ -z "$output" ]
}

@test "manifest_changed does not report a deleted file" {
    echo one > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    rm "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_changed "$WORK/base" "$WORK/cur"
    [ -z "$output" ]
}

@test "manifest_deleted reports a removed file" {
    echo one > "$SRC/a.txt"
    echo two > "$SRC/b.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    rm "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_deleted "$WORK/base" "$WORK/cur"
    [ "$output" = "a.txt" ]
}

@test "manifest_deleted is silent when a file only changed" {
    echo one > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/base"
    echo changed > "$SRC/a.txt"
    sbx_manifest_build "$SRC" "$WORK/cur"
    run sbx_manifest_deleted "$WORK/base" "$WORK/cur"
    [ -z "$output" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/copy-mounts.bats`
Expected: the eight new tests FAIL with `sbx_manifest_build: command not found`.

- [ ] **Step 3: Implement the manifest functions**

Append to `lib/copy-mounts.sh`:

```bash
# Manifest of a tree's file contents, used as the diff baseline for a
# `record` mount.
#
# One line per regular file: "<sha256>  <relpath>" — exactly sha256sum's
# own output format, with the leading "./" stripped, sorted bytewise.
#
# Content only, no mode. The single batched `find -exec sha256sum {} +` is
# what keeps this affordable on a large tree; collecting modes as well needs
# a second walk or a per-file subshell, and a mode-only change with
# byte-identical content is not worth either. Such a change is not detected.
#
# LC_ALL=C throughout: the sort order only has to be *stable between the two
# manifests* being compared, and a locale-dependent collation that differs
# between the launch and teardown environments would silently desynchronize
# comm(1) below.
sbx_manifest_build() {
    local tree="$1" out="$2"

    : > "$out"
    [[ -d "$tree" ]] || return 0

    (
        cd "$tree" || exit 0
        find . -type f -exec sha256sum {} + 2>/dev/null
    ) | sed 's|^\(\w*\)  \./|\1  |' | LC_ALL=C sort > "$out"
}

# Relative paths of the files in $2 that are absent from, or differ in
# content from, $1. comm on whole lines: a differing hash makes the whole
# line unique to $2, which is exactly "added or modified".
sbx_manifest_changed() {
    LC_ALL=C comm -13 "$1" "$2" | cut -d' ' -f3-
}

# Relative paths present in $1 and absent from $2. Compares path columns
# only, so a file that merely changed content is not reported here.
sbx_manifest_deleted() {
    LC_ALL=C comm -23 \
        <(cut -d' ' -f3- "$1" | LC_ALL=C sort) \
        <(cut -d' ' -f3- "$2" | LC_ALL=C sort)
}
```

Note on `cut -d' ' -f3-`: `sha256sum` separates hash and path with **two**
spaces, so field 1 is the hash, field 2 is empty, and fields 3 onward are
the path — which is why this is correct for paths containing spaces.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/copy-mounts.bats`
Expected: all tests PASS, including the pre-existing ones.

- [ ] **Step 5: Lint**

Run: `shellcheck -S error sbx lib/copy-mounts.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/copy-mounts.sh tests/copy-mounts.bats
git commit -m "Add content manifests for record-mount change detection

A manifest built at launch is the diff baseline a record mount needs, and
replaces diffing against the live host source at teardown — which let a
concurrent host edit masquerade as a sandbox change."
```

---

### Task 2: The `forked` perm

Adds `forked` alongside the existing `copy`. `copy` keeps working until
Task 4, so the tree stays green.

**Files:**
- Modify: `sbx` — `apply_mounts` case (~`sbx:845`), mount arrays
  (~`sbx:797`), seeding block (~`sbx:887`)
- Test: `tests/persistent-cli.bats`

**Interfaces:**
- Consumes: `sbx_copy_seed`, `sbx_copy_mount_id`, `sbx_copy_path_slug`.
- Produces:
  - `FORKED_MOUNTS` array, TAB-separated `profile<TAB>source<TAB>dest`.
  - Store path convention:
    `$STATE_DIR/forked/<profile>/<dir-slug>/<mount-id>/`.

- [ ] **Step 1: Write the failing tests**

In `tests/persistent-cli.bats`, add to `setup()` after the existing
fixtures:

```bash
    FORKED_ROOT="$HOME/.local/state/sbx/forked"
    cat > "$PROJ/.sbx/profiles/cli/fk.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/fkmount","perm":"forked"}]}
EOF
```

Then append these tests:

```bash
@test "a forked mount is seeded from the host on first launch" {
    run_sbx "--cli fk" "cp /tmp/fkmount/host.txt /tmp/fkmount/seen.txt"
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/seen.txt")" = "hostfile" ]
}

@test "a forked mount carries a new file into the next launch" {
    run_sbx "--cli fk" "echo made > /tmp/fkmount/new.txt"
    run_sbx "--cli fk" "cp /tmp/fkmount/new.txt /tmp/fkmount/echoed.txt"
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/echoed.txt")" = "made" ]
}

@test "a forked mount stops seeing host edits after the first launch" {
    run_sbx "--cli fk" "true"
    echo edited > "$HOSTDIR/host.txt"
    run_sbx "--cli fk" "cp /tmp/fkmount/host.txt /tmp/fkmount/seen.txt"
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/seen.txt")" = "hostfile" ]
}

@test "a file deleted in a forked mount stays deleted" {
    run_sbx "--cli fk" "rm /tmp/fkmount/host.txt"
    run_sbx "--cli fk" "test -f /tmp/fkmount/host.txt && echo back > /tmp/fkmount/back.txt"
    [ ! -f "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/back.txt" ]
}

@test "a forked mount never modifies the host source" {
    run_sbx "--cli fk" "echo sandbox > /tmp/fkmount/host.txt; echo x > /tmp/fkmount/new.txt"
    [ "$(cat "$HOSTDIR/host.txt")" = "hostfile" ]
    [ ! -f "$HOSTDIR/new.txt" ]
}

@test "forked stores are keyed by launch directory" {
    OTHER="$ROOT/o"; mkdir -p "$OTHER"
    OTHER_SLUG=$(echo "$OTHER" | tr '/' '-')
    cp -a "$PROJ/.sbx" "$OTHER/.sbx"
    run_sbx "--cli fk" "echo here > /tmp/fkmount/where.txt"
    run_sbx_in "$OTHER" "--cli fk" "echo there > /tmp/fkmount/where.txt"
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/where.txt")" = "here" ]
    [ "$(cat "$FORKED_ROOT/fk/$OTHER_SLUG/_tmp_fkmount/where.txt")" = "there" ]
}
```

Note the fourth test's inverted logic: it asserts the *absence* of
`back.txt`, because writing it is what a re-seeded (i.e. broken) mount would
do. This is a positive assertion on a negative condition, not a `! cmd`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/persistent-cli.bats`
Expected: the six new tests FAIL. `forked` is not a recognised perm, so the
`case` falls through, no mount is made, and `/tmp/fkmount/...` does not
exist inside the sandbox.

- [ ] **Step 3: Declare the array and parse the perm**

In `sbx`, next to the existing arrays (~line 797) add:

```bash
FORKED_MOUNTS=()   # "profile<TAB>source<TAB>dest" — sandbox-owned, seeded once
```

`apply_mounts` needs the declaring profile's name. Change its signature use
— at the top of the function body (~line 802), after `local profile="$1"`,
add:

```bash
    local profile_name
    profile_name=$(basename "$profile" .json)
```

Then add a case arm beside `ro`/`rw`/`dev`/`copy` (~line 845):

```bash
            forked)
                FORKED_MOUNTS+=("$profile_name"$'\t'"$source"$'\t'"$dest")
                ;;
```

- [ ] **Step 4: Seed and bind forked mounts**

In the seeding block (~line 907, beside the existing `COPY_MOUNTS` loops),
add:

```bash
# Sandbox-owned mounts. Seeded from the host only when the store does not
# yet exist; from then on the store IS the tree and the host source is
# never consulted again. That is the defining property of `forked`, not an
# optimization — see the design spec. Bound rw directly, so there is no
# write-back at teardown and nothing to diff.
for fm in "${FORKED_MOUNTS[@]}"; do
    IFS=$'\t' read -r f_prof f_src f_dest <<< "$fm"
    f_id=$(sbx_copy_mount_id "$f_dest")
    f_store="$STATE_DIR/forked/$f_prof/$(sbx_copy_path_slug "$PWD")/$f_id"

    if [[ ! -e "$f_store" ]]; then
        mkdir -p "$f_store"
        sbx_copy_seed "$f_src" "$f_store"
    fi

    if [[ -f "$f_src" ]]; then
        BWRAP_ARGS+=(--bind "$f_store/$(basename "$f_src")" "$f_dest")
    else
        BWRAP_ARGS+=(--tmpfs "$f_dest")
        BWRAP_ARGS+=(--bind "$f_store" "$f_dest")
    fi
done
```

The `--tmpfs` before `--bind` for the directory case mirrors what
`seed_copy_mount` already does at `sbx:909`: it guarantees the mount point
exists inside the sandbox before the bind lands on it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/persistent-cli.bats`
Expected: all PASS, including the pre-existing `copy` tests.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck -S error sbx lib/copy-mounts.sh
git add sbx tests/persistent-cli.bats
git commit -m "Add the forked mount perm: seeded once, sandbox-owned after

A forked mount is initialized from the host the first time it is used and
plain-bound from its store thereafter. No overlay, no diff, no write-back,
and deletion is ordinary unlink."
```

---

### Task 3: The `record` perm and `--changes`

**Files:**
- Modify: `sbx` — arrays, perm case, seeding, `teardown()`, arg parsing,
  `usage()`
- Test: `tests/persistent-cli.bats`

**Interfaces:**
- Consumes: `sbx_copy_seed`, `sbx_manifest_build`, `sbx_manifest_changed`,
  `sbx_manifest_deleted`, `SESSION_NAME` (Task 5 renames this; until then
  use `SESSION_ID`).
- Produces:
  - `RECORD_MOUNTS` array, TAB-separated `source<TAB>dest`.
  - Working copy: `$STATE_DIR/work/<session>/<mount-id>/`
  - Baseline: `$STATE_DIR/work/<session>/<mount-id>.manifest`
  - Archive: `$STATE_DIR/changes/<dir-slug>/<stamp>-<session>/<mount-id>/`
    and `.../<mount-id>.deleted`
  - `--changes [<archive>]` flag.

- [ ] **Step 1: Write the failing tests**

Add to `setup()` in `tests/persistent-cli.bats`:

```bash
    CHANGES_ROOT="$HOME/.local/state/sbx/changes"
    cat > "$PROJ/.sbx/profiles/fs/rec.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/recmount","perm":"record"}]}
EOF
```

Add this helper below `run_sbx_in()`:

```bash
# The single archive directory produced by the most recent record session.
latest_archive() {
    find "$CHANGES_ROOT" -mindepth 2 -maxdepth 2 -type d 2>/dev/null |
        LC_ALL=C sort | tail -n1
}
```

Then the tests:

```bash
@test "a record mount archives a file the sandbox created" {
    run_sbx "--fs rec" "echo made > /tmp/recmount/new.txt"
    [ "$(cat "$(latest_archive)/_tmp_recmount/new.txt")" = "made" ]
}

@test "a record mount archives a file the sandbox modified" {
    run_sbx "--fs rec" "echo changed > /tmp/recmount/host.txt"
    [ "$(cat "$(latest_archive)/_tmp_recmount/host.txt")" = "changed" ]
}

@test "a record mount does not archive an untouched file" {
    run_sbx "--fs rec" "echo made > /tmp/recmount/new.txt"
    [ ! -f "$(latest_archive)/_tmp_recmount/host.txt" ]
}

@test "a record mount lists a deleted file and does not archive it" {
    run_sbx "--fs rec" "rm /tmp/recmount/host.txt"
    [ "$(cat "$(latest_archive)/_tmp_recmount.deleted")" = "host.txt" ]
    [ ! -f "$(latest_archive)/_tmp_recmount/host.txt" ]
}

@test "a record mount resets to host state on the next launch" {
    run_sbx "--fs rec" "echo made > /tmp/recmount/new.txt"
    run_sbx "--fs rec" "test -f /tmp/recmount/new.txt && echo leaked > /tmp/recmount/leak.txt"
    [ ! -f "$(latest_archive)/_tmp_recmount/leak.txt" ]
}

@test "a record mount never modifies the host source" {
    run_sbx "--fs rec" "echo sandbox > /tmp/recmount/host.txt; rm -f /tmp/recmount/host.txt; echo x > /tmp/recmount/new.txt"
    [ "$(cat "$HOSTDIR/host.txt")" = "hostfile" ]
    [ ! -f "$HOSTDIR/new.txt" ]
}

# The regression test for the defect this design exists to fix. Against the
# old sbx_copy_writeback, which diffed against the live host source at
# teardown, a host edit made mid-session shows up in the egress as though
# the sandbox had made it. The manifest baseline is captured at launch, so
# it cannot.
@test "a host edit during the session is not attributed to the sandbox" {
    ( cd "$PROJ" && script -qec \
        "$SBX --fs rec -- /bin/sh -c 'echo ready > /tmp/recmount/ready.txt; sleep 5'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    for _ in $(seq 1 40); do
        [[ -n "$(find "$HOME/.local/state/sbx/work" -name 'ready.txt' 2>/dev/null)" ]] && break
        sleep 0.25
    done
    echo "edited-by-host" > "$HOSTDIR/host.txt"
    wait $bg
    [ ! -f "$(latest_archive)/_tmp_recmount/host.txt" ]
}

@test "the work directory is removed at teardown" {
    run_sbx "--fs rec" "echo made > /tmp/recmount/new.txt"
    [ -z "$(find "$HOME/.local/state/sbx/work" -mindepth 1 2>/dev/null)" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/persistent-cli.bats`
Expected: the eight new tests FAIL — `record` is unrecognised, so nothing is
mounted and `latest_archive` returns empty.

- [ ] **Step 3: Declare, parse, seed**

Add beside `FORKED_MOUNTS`:

```bash
RECORD_MOUNTS=()   # "source<TAB>dest" — host-owned, reseeded, changes archived
```

Add the case arm beside `forked`:

```bash
            record)
                RECORD_MOUNTS+=("$source"$'\t'"$dest")
                ;;
```

Add the seeding loop beside the `forked` loop:

```bash
# Host-owned mounts with change detection. A private working copy is seeded
# fresh every launch and hashed into a manifest; teardown diffs the working
# copy against THAT manifest rather than against the live host source, so a
# host edit made while the session runs cannot be misattributed to the
# sandbox.
RECORD_WORK_DIR="$STATE_DIR/work/$SESSION_ID"
for rm_ in "${RECORD_MOUNTS[@]}"; do
    IFS=$'\t' read -r r_src r_dest <<< "$rm_"
    r_id=$(sbx_copy_mount_id "$r_dest")
    r_work="$RECORD_WORK_DIR/$r_id"

    mkdir -p "$r_work"
    sbx_copy_seed "$r_src" "$r_work"
    sbx_manifest_build "$r_work" "$RECORD_WORK_DIR/$r_id.manifest"

    if [[ -f "$r_src" ]]; then
        BWRAP_ARGS+=(--bind "$r_work/$(basename "$r_src")" "$r_dest")
    else
        BWRAP_ARGS+=(--tmpfs "$r_dest")
        BWRAP_ARGS+=(--bind "$r_work" "$r_dest")
    fi
done
```

`rm_` rather than `rm`: shadowing the `rm` command inside a loop that later
gained a cleanup call is a foreseeable trap.

- [ ] **Step 4: Archive at teardown**

In `teardown()`, replacing the two write-back loops at `sbx:1403-1417`
(leave the `copy` loops in place for now — Task 4 removes them):

```bash
    # Change archive for record mounts. The baseline is the launch-time
    # manifest, not the host source, so this reports what the SANDBOX did.
    if [[ ${#RECORD_MOUNTS[@]} -gt 0 ]]; then
        arch_dir="$STATE_DIR/changes/$(sbx_copy_path_slug "$PWD")/$(date +%Y%m%d-%H%M%S)-$SESSION_ID"
        for rm_ in "${RECORD_MOUNTS[@]}"; do
            IFS=$'\t' read -r r_src r_dest <<< "$rm_"
            r_id=$(sbx_copy_mount_id "$r_dest")
            r_work="$RECORD_WORK_DIR/$r_id"
            r_base="$RECORD_WORK_DIR/$r_id.manifest"
            [[ -d "$r_work" ]] || continue

            r_cur="$RECORD_WORK_DIR/$r_id.manifest.now"
            sbx_manifest_build "$r_work" "$r_cur"

            mkdir -p "$arch_dir/$r_id"
            while IFS= read -r rel; do
                [[ -z "$rel" ]] && continue
                mkdir -p "$arch_dir/$r_id/$(dirname "$rel")"
                cp -a "$r_work/$rel" "$arch_dir/$r_id/$rel"
            done < <(sbx_manifest_changed "$r_base" "$r_cur")

            sbx_manifest_deleted "$r_base" "$r_cur" > "$arch_dir/$r_id.deleted"
            echo "Changes from this session: $arch_dir/$r_id"
        done
    fi
    rm -rf "$RECORD_WORK_DIR"
```

- [ ] **Step 5: Add `--changes`**

In the argument-parsing `while` loop, beside `--list-sessions`:

```bash
        --changes)
            CHANGES_DIR="$STATE_DIR/changes/$(sbx_copy_path_slug "$PWD")"
            if [[ -n "${2-}" && "$2" != -* ]]; then
                target="$CHANGES_DIR/$2"; shift 2
            else
                target=$(find "$CHANGES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
                         LC_ALL=C sort | tail -n1)
                shift
            fi
            if [[ -z "$target" || ! -d "$target" ]]; then
                echo "No recorded changes for this directory." >&2
                exit 1
            fi
            echo "$target"
            # Paths are attacker-authored (a record mount's contents come
            # from inside the sandbox), so strip control characters before
            # echoing them to a terminal — same reasoning as --list-sessions.
            find "$target" -mindepth 2 -type f -printf '  + %P\n' | tr -d '\000-\037'
            for d in "$target"/*.deleted; do
                [[ -f "$d" ]] || continue
                sed 's/^/  - /' "$d" | tr -d '\000-\037'
            done
            exit 0
            ;;
```

Add to `usage()` after the `--list-sessions` line:

```
  --changes [<id>]       Show what a record mount changed (default: latest)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats tests/persistent-cli.bats`
Expected: all PASS.

- [ ] **Step 7: Lint and commit**

```bash
shellcheck -S error sbx lib/copy-mounts.sh
git add sbx tests/persistent-cli.bats
git commit -m "Add the record mount perm and --changes

A record mount reseeds from the host every launch and archives what the
session changed, diffed against a launch-time manifest rather than the live
host source."
```

---

### Task 4: Retire `copy` and delete the write-back machinery

**Files:**
- Modify: `sbx`, `lib/copy-mounts.sh`, `profiles/cli/*.json`,
  `profiles/fs/default.json`, `tests/copy-mounts.bats`,
  `tests/persistent-cli.bats`

**Interfaces:**
- Consumes: everything from Tasks 2 and 3.
- Produces: no `copy` perm; `COPY_MOUNTS`, `CLI_COPY_MOUNTS`,
  `CLI_STORE_DIR`, `sbx_copy_writeback`, `$SESSION_DIR/fs`,
  `$SESSION_DIR/tmp_mounts` all gone.

- [ ] **Step 1: Write the failing tests**

Replace the test `"fs profile copy mounts stay ephemeral and create no
store"` in `tests/persistent-cli.bats` with:

```bash
@test "the copy perm is rejected with a message naming both replacements" {
    cat > "$PROJ/.sbx/profiles/fs/old.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/o","perm":"copy"}]}
EOF
    run bash -c "cd '$PROJ' && $SBX --fs old -- true 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *forked* ]]
    [[ "$output" == *record* ]]
}

@test "every shipped profile loads" {
    for p in "$BATS_TEST_DIRNAME"/../profiles/*/*.json; do
        run jq -e '[.mounts[]?.perm] | all(. == "ro" or . == "rw" or . == "dev" or . == "forked" or . == "record")' "$p"
        [ "$status" -eq 0 ]
    done
}

@test "a pre-migration cli store is carried over to the forked layout" {
    mkdir -p "$HOME/.local/state/sbx/profiles/cli/fk/$PROJ_SLUG/_tmp_fkmount"
    echo carried > "$HOME/.local/state/sbx/profiles/cli/fk/$PROJ_SLUG/_tmp_fkmount/old.txt"
    run_sbx "--cli fk" "cp /tmp/fkmount/old.txt /tmp/fkmount/seen.txt"
    [ "$(cat "$FORKED_ROOT/fk/$PROJ_SLUG/_tmp_fkmount/seen.txt")" = "carried" ]
    [ ! -d "$HOME/.local/state/sbx/profiles" ]
}
```

Then delete the obsolete `copy` coverage. In
`tests/persistent-cli.bats`, remove the `tst` and `tstfs` fixtures from
`setup()` and every `@test` that uses them — the `fk` and `rec` fixtures
added in Tasks 2 and 3 cover the same behavior under the new perms. Leaving
a fixture that declares `copy` will now abort the launch, so this is not
optional.

In `tests/copy-mounts.bats`, delete these eleven tests (everything from
line 38 to the end of the file as it stands today), keeping only the five
that cover `mount_id`, `path_slug` and the three plain `seed` cases:

- `writeback captures a file the sandbox created`
- `writeback captures a file the sandbox modified`
- `writeback ignores a file the sandbox did not touch`
- `writeback never modifies the host source`
- `writeback handles a single-file source deleted in the sandbox`
- `seed overlays store entries on top of the host copy`
- `seed brings through host files absent from the store`
- `seed brings through store files absent from the host`
- `seed tolerates a store that does not exist yet`
- `seed overlays nested store paths`
- `a stored file survives a session that never touches it`

Also drop `STORE="$WORK/store"` from that file's `setup()`; nothing
references it any more.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/persistent-cli.bats`
Expected: `"the copy perm is rejected"` FAILS (exit status 0, `copy` still
accepted) and the migration test FAILS.

- [ ] **Step 3: Reject `copy`**

Replace the whole `copy)` case arm (`sbx:855-863`) with:

```bash
            copy)
                echo "Error: $profile: mount \"$dest\" uses perm \"copy\", which has been split." >&2
                echo "  Use \"forked\" if the SANDBOX owns the data (seeded from the host once," >&2
                echo "  then never re-read — tool state, config, caches)." >&2
                echo "  Use \"record\" if the HOST owns it (reseeded every launch, with the" >&2
                echo "  session's changes archived for inspection — source trees)." >&2
                exit 1
                ;;
            *)
                echo "Error: $profile: mount \"$dest\" has unknown perm \"$perm\"." >&2
                exit 1
                ;;
```

The `*)` arm is new: the old `case` silently ignored a typo'd perm, which
produced a sandbox missing a mount with no diagnostic at all.

- [ ] **Step 4: Migrate the store layout on startup**

After `mkdir -p "$STATE_DIR"` (~`sbx:19`):

```bash
# One-time relocation of the pre-`forked` cli store. The old path is
# $STATE_DIR/profiles/cli/<profile>/<slug>/<mount-id>, which is the same
# shape the forked store uses, so this is a rename rather than a conversion
# — the contents are already a valid sandbox-owned tree. ("profiles/" was
# always a poor name for state; nothing else lives under it.)
if [[ -d "$STATE_DIR/profiles/cli" && ! -d "$STATE_DIR/forked" ]]; then
    mkdir -p "$STATE_DIR/forked"
    for old_store in "$STATE_DIR/profiles/cli"/*; do
        [[ -d "$old_store" ]] && mv "$old_store" "$STATE_DIR/forked/"
    done
    rmdir "$STATE_DIR/profiles/cli" "$STATE_DIR/profiles" 2>/dev/null || true
fi
```

- [ ] **Step 5: Delete the dead machinery**

In `sbx`:
- Remove `COPY_MOUNTS`, `CLI_COPY_MOUNTS` declarations (~797-798).
- Remove `CLI_PROFILE_NAME` / `CLI_STORE_DIR` and their comment block
  (~556-566).
- Remove `seed_copy_mount()` and both loops that call it (~892-914).
- Remove `mkdir -p "$SESSION_DIR/fs"` (~544) and
  `mkdir -p "$SESSION_DIR/tmp_mounts"` (~890).
- Remove both write-back loops and `rm -rf "$SESSION_DIR/tmp_mounts"` in
  `teardown()` (~1403-1417).
- Change the final teardown message from
  `"Changes saved to $SESSION_DIR/fs"` to `"Session $SESSION_ID finished."`

In `lib/copy-mounts.sh`:
- Delete `sbx_copy_writeback` entirely.
- Delete the store-overlay branch of `sbx_copy_seed` (the `if [[ -n
  "$store" ...` block) and the `store` parameter, leaving:

```bash
# Populate a copy mount's working directory from the host source.
#
# --reflink=auto makes this metadata-only on btrfs/xfs when src and tmp
# share a filesystem, and silently falls back to a full copy otherwise. On
# the design host that is a 37x difference on 300MB (4ms vs 144ms), which
# is why setup progress reporting only ever engages on the fallback path.
sbx_copy_seed() {
    local src="$1" tmp="$2"

    mkdir -p "$tmp"

    if [[ -d "$src" ]]; then
        cp -a --reflink=auto "$src/." "$tmp/"
    elif [[ -f "$src" ]]; then
        cp -a --reflink=auto "$src" "$tmp/"
    fi
}
```

- [ ] **Step 6: Migrate the shipped profiles**

```bash
sed -i 's/"perm": *"copy"/"perm": "forked"/' profiles/cli/*.json
sed -i 's/"perm": *"copy"/"perm": "record"/' profiles/fs/default.json
git diff --stat profiles/
```

Verify by eye: every `cli` profile's `.claude` / `.pi` / `.gemini` mount is
now `forked`, and `default.json`'s `./src` is `record`.

- [ ] **Step 7: Run the full suite**

First update `tests/hardening.bats`'s
`"the sandbox cannot see persistent cli stores"`, which asserts on the now
non-existent `profiles` path: change its fixture to
`mkdir -p "$HOME/.local/state/sbx/forked/other"` and its grep target from
`profiles` to `forked`.

Run: `bats tests/`
Expected: all PASS.

- [ ] **Step 8: Lint and commit**

```bash
shellcheck -S error sbx lib/copy-mounts.sh
git add -A sbx lib profiles tests
git commit -m "Retire the copy perm in favour of forked and record

copy meant sandbox-owned in a cli profile and host-owned in an fs profile,
so it cannot be aliased to either: the loader now rejects it and names both
replacements. Removes sbx_copy_writeback, the per-session fs/ egress that
nothing ever read, and relocates existing cli stores to forked/."
```

---

### Task 5: Ephemeral sessions and readable names

**Files:**
- Modify: `sbx` — session init (~542), `--list-sessions` (~161), `--join`
  (~186), `--attach` (~267), `teardown()`, bwrap state-dir masking
- Modify: `tests/hardening.bats`, `tests/join.bats`
- Create: `tests/sessions.bats`

**Interfaces:**
- Consumes: nothing from earlier tasks except `RECORD_WORK_DIR`, whose
  name is unchanged.
- Produces:
  - `SESSION_NAME` replaces `SESSION_ID` throughout.
  - `SESSION_DIR="$STATE_DIR/sessions/$SESSION_NAME"`.
  - Join sidecar at `$STATE_DIR/join/$SESSION_NAME.json`, lock at
    `$STATE_DIR/join/$SESSION_NAME.lock`.

- [ ] **Step 1: Write the failing tests**

Create `tests/sessions.bats`:

```bash
#!/usr/bin/env bats

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"
    ROOT="$(mktemp -d /tmp/sbxh.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/myproj"
    HOSTDIR="$ROOT/s"
    mkdir -p "$HOME" "$PROJ/.sbx/profiles/fs" "$HOSTDIR"
    export SBX_TRUST_PROJECT_PROFILES=1
    cat > "$PROJ/.sbx/profiles/fs/t.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
}

teardown() {
    [[ -n "$ROOT" && "$ROOT" == /tmp/sbxh.* ]] && rm -rf "$ROOT"
}

run_sbx() {
    ( cd "$PROJ" && script -qec "$SBX $1 -- /bin/sh -c '$2'" /dev/null >/dev/null 2>&1 )
}

@test "a session is named after its launch directory" {
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo up > /out/up.txt; sleep 5'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/up.txt" ]] && break; sleep 0.25; done
    [ -d "$HOME/.local/state/sbx/sessions/myproj" ]
    wait $bg
}

@test "a session directory is removed on exit" {
    run_sbx "--fs t" "true"
    [ -z "$(find "$HOME/.local/state/sbx/sessions" -mindepth 1 2>/dev/null)" ]
}

@test "list-sessions is empty once every session has ended" {
    run_sbx "--fs t" "true"
    run bash -c "cd '$PROJ' && $SBX --list-sessions"
    [ "$status" -eq 0 ]
    [[ "$output" != *myproj* ]]
}

@test "a second concurrent session in the same directory gets a -2 suffix" {
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo a > /out/a.txt; sleep 6'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg1=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/a.txt" ]] && break; sleep 0.25; done
    ( cd "$PROJ" && script -qec \
        "$SBX --fs t -- /bin/sh -c 'echo b > /out/b.txt; sleep 4'" \
        /dev/null >/dev/null 2>&1 ) &
    local bg2=$!
    for _ in $(seq 1 40); do [[ -f "$HOSTDIR/b.txt" ]] && break; sleep 0.25; done
    [ -d "$HOME/.local/state/sbx/sessions/myproj" ]
    [ -d "$HOME/.local/state/sbx/sessions/myproj-2" ]
    wait $bg1 $bg2
}

@test "a name is reusable after its session ends" {
    run_sbx "--fs t" "true"
    run_sbx "--fs t" "true"
    [ -z "$(find "$HOME/.local/state/sbx/sessions" -mindepth 1 2>/dev/null)" ]
}

# Crash residue: a session directory whose supervising pid is gone. It must
# not be listed as live, and its name must be reclaimable.
@test "a dead session directory is not listed and its name is reclaimed" {
    mkdir -p "$HOME/.local/state/sbx/sessions/myproj"
    cat > "$HOME/.local/state/sbx/sessions/myproj/session.json" <<EOF
{"id":"myproj","cwd":"$PROJ","pid":999999,"fs_profiles":[],"net_profiles":[],"cli_profile":null}
EOF
    run bash -c "cd '$PROJ' && $SBX --list-sessions"
    [[ "$output" != *myproj* ]]
    run_sbx "--fs t" "echo ok > /out/ok.txt"
    [ "$(cat "$HOSTDIR/ok.txt")" = "ok" ]
}

@test "list-sessions strips control characters from a live session's id" {
    mkdir -p "$HOME/.local/state/sbx/sessions/evil"
    cat > "$HOME/.local/state/sbx/sessions/evil/session.json" <<EOF
{"id":"evil$(printf '\033')[31m","cwd":"$PROJ","pid":$$,"fs_profiles":[],"net_profiles":[],"cli_profile":null}
EOF
    run bash -c "cd '$PROJ' && $SBX --list-sessions"
    [ "$status" -eq 0 ]
    [[ "$output" == *evil* ]]
    [[ "$output" != *$'\033'* ]]
}
```

The last test replaces `tests/hardening.bats`'s
`"list-sessions survives control characters in session.json"`, which cannot
survive this change: it tampers with a `session.json` *after* the run, and
that file no longer exists then. Fabricating a directory with the test's own
`$$` as the pid gives a genuinely-live session to sanitize, without a
launch. **Delete the old test from `tests/hardening.bats`.**

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/sessions.bats`
Expected: most FAIL — sessions are still at `$STATE_DIR/<date-id>` and are
never removed.

- [ ] **Step 3: Derive and claim the session name**

Replace the session init block (`sbx:542-544`):

```bash
# Session name. Derived from the launch directory's basename, because the
# thing a user types at --join should be recognisable; the old
# date-plus-random id was unique and unusable. Capped at 32 characters: the
# tmux socket lives at $SESSION_DIR/tmux.sock and a Unix socket path over
# ~108 bytes fails quietly with "File name too long".
#
# Uniqueness is established by mkdir succeeding — an atomic claim, so two
# simultaneous launches cannot both take a name. A directory whose
# supervising pid is gone is crash residue, not a session: it is removed and
# the name reclaimed.
SESSION_BASE=$(printf '%s' "$(basename "$PWD")" |
               tr '[:upper:]' '[:lower:]' |
               tr -c 'a-z0-9._-' '-' |
               cut -c1-32)
SESSION_BASE="${SESSION_BASE#-}"
SESSION_BASE="${SESSION_BASE%-}"
[[ -z "$SESSION_BASE" ]] && SESSION_BASE="sbx"

mkdir -p "$STATE_DIR/sessions" "$STATE_DIR/join"
SESSION_NAME="$SESSION_BASE"
session_n=1
while ! mkdir "$STATE_DIR/sessions/$SESSION_NAME" 2>/dev/null; do
    stale_pid=$(jq -r '.pid // empty' \
        "$STATE_DIR/sessions/$SESSION_NAME/session.json" 2>/dev/null | tr -d '\000-\037')
    if [[ ! "$stale_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$stale_pid" 2>/dev/null; then
        rm -rf "${STATE_DIR:?}/sessions/$SESSION_NAME"
        continue
    fi
    session_n=$((session_n + 1))
    if [[ $session_n -gt 99 ]]; then
        echo "Error: too many live sessions named '$SESSION_BASE'." >&2
        exit 1
    fi
    SESSION_NAME="$SESSION_BASE-$session_n"
done

SESSION_ID="$SESSION_NAME"   # retained: session.json's .id field
SESSION_DIR="$STATE_DIR/sessions/$SESSION_NAME"
mkdir -p "$SESSION_DIR/tmp"
```

`SESSION_ID` is kept as an alias so the many existing references
(`session.json`, teardown messages, `RECORD_WORK_DIR`) need no edit. The
`continue` after removing residue retries the same name rather than
advancing the counter, which is what makes the name reclaimable.

- [ ] **Step 4: Relocate the join sidecar and lock**

Three sites use `$STATE_DIR/$SESSION_ID.join.json` or `.joinlock`
(~`sbx:223`, `sbx:237`, `sbx:1266`, `sbx:1388`, `sbx:1421`). Change each to
`$STATE_DIR/join/$SESSION_NAME.json` and `$STATE_DIR/join/$SESSION_NAME.lock`
respectively. In the `--join` and `--attach` branches, `$SDIR` becomes
`$STATE_DIR/sessions/$JOIN_SESSION`.

The sidecar must stay outside `sessions/<name>/` — that directory is bound
rw into the sandbox, so anything in it is attacker-authored, and `--join`
must not take security-relevant input from the sandbox it is entering. The
`join/` directory makes that boundary explicit rather than relying on a
filename convention.

- [ ] **Step 5: List only live sessions**

Replace the `--list-sessions` body (`sbx:161-184`):

```bash
        --list-sessions)
            echo "Active Sessions (this directory):"
            for sdir in "$STATE_DIR"/sessions/*; do
                [[ -d "$sdir" && -f "$sdir/session.json" ]] || continue
                # session.json lives inside a directory bound rw into the
                # sandbox — every field is attacker-authored. Strip control
                # characters before echoing them to a terminal.
                scwd=$(jq -r '.cwd' "$sdir/session.json" 2>/dev/null | tr -d '\000-\037')
                [[ "$scwd" == "$PWD" ]] || continue
                sid=$(jq -r '.id' "$sdir/session.json" 2>/dev/null | tr -d '\000-\037')
                pid=$(jq -r '.pid // empty' "$sdir/session.json" 2>/dev/null | tr -d '\000-\037')
                # Validated, not merely non-empty: an unchecked $pid
                # reaching kill is a signal sent wherever the sandbox chose.
                if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
                    echo "  $sid (PID: $pid)"
                fi
            done
            exit 0
            ;;
```

An entry whose pid is dead is crash residue, not an inactive session, and
is simply not shown. `--gc` (Task 6) removes it.

- [ ] **Step 6: Delete the session directory at teardown**

At the end of `teardown()`, replacing the selective `rm -f` list
(`sbx:1418-1421`):

```bash
    # Nothing durable lives here: forked stores, change archives and the
    # join sidecar are all outside. Removing the directory outright is the
    # whole fix for --list-sessions accumulating dead entries.
    rm -rf "${SESSION_DIR:?}"
    rm -f "$STATE_DIR/join/$SESSION_NAME.json" "$JOIN_LOCK"
```

`${SESSION_DIR:?}` guards against an unset variable expanding to `rm -rf ""`.

- [ ] **Step 7: Fix the tests that assert on the old layout**

- `tests/join.bats:39` — `find ... -maxdepth 2 -name tmux.sock` becomes
  `-maxdepth 3`; the socket is now one level deeper.
- `tests/hardening.bats:213` — the decoy fixture path becomes
  `$HOME/.local/state/sbx/sessions/decoy-session`.
- `tests/hardening.bats:220` — fixture becomes
  `$HOME/.local/state/sbx/forked/other`; the grep target becomes `forked`.
- `tests/hardening.bats:233` — `"the sandbox can still write its own
  session directory"` asserts `ls $STATE_DIR | wc -l` is 1. It still is —
  the single visible entry is now `sessions` rather than the session id
  itself. Update the test's comment to say so; the assertion is unchanged.
- `tests/hardening.bats:270` — `"session.json records the supervising pid"`
  runs `find` *after* the session ends, so it now finds nothing. Rewrite it
  to launch in the background like `tests/sessions.bats` does and read
  `$HOME/.local/state/sbx/sessions/*/session.json` while the session is
  live.
- `tests/hardening.bats:280` — delete; replaced by the `sessions.bats`
  version.

- [ ] **Step 8: Run the full suite**

Run: `bats tests/`
Expected: all PASS.

- [ ] **Step 9: Lint and commit**

```bash
shellcheck -S error sbx lib/copy-mounts.sh
git add -A sbx tests
git commit -m "Make sessions ephemeral and name them after the launch directory

Nothing durable lives in a session directory now, so teardown removes it and
--list-sessions shows only live sessions. Names come from the launch dir's
basename, suffixed only to disambiguate concurrent sessions, so --join takes
something a user can type."
```

---

### Task 6: `--gc` and `--reseed`

**Files:**
- Modify: `sbx` — arg parsing, `usage()`, `teardown()`
- Test: `tests/sessions.bats`

**Interfaces:**
- Consumes: the Task 5 layout, `sbx_copy_path_slug`.
- Produces: `--gc`, `--reseed [<mount>]`, `--yes`, `SBX_KEEP_CHANGES`
  (default 10).

- [ ] **Step 1: Write the failing tests**

Append to `tests/sessions.bats`:

```bash
@test "gc removes crash residue" {
    mkdir -p "$HOME/.local/state/sbx/sessions/dead"
    cat > "$HOME/.local/state/sbx/sessions/dead/session.json" <<EOF
{"id":"dead","cwd":"$PROJ","pid":999999}
EOF
    run bash -c "cd '$PROJ' && $SBX --gc"
    [ "$status" -eq 0 ]
    [ ! -d "$HOME/.local/state/sbx/sessions/dead" ]
}

@test "gc leaves a live session alone" {
    mkdir -p "$HOME/.local/state/sbx/sessions/alive"
    cat > "$HOME/.local/state/sbx/sessions/alive/session.json" <<EOF
{"id":"alive","cwd":"$PROJ","pid":$$}
EOF
    run bash -c "cd '$PROJ' && $SBX --gc"
    [ -d "$HOME/.local/state/sbx/sessions/alive" ]
}

@test "change archives are pruned to the keep limit" {
    slug=$(echo "$PROJ" | tr '/' '-')
    for i in 1 2 3 4 5; do
        mkdir -p "$HOME/.local/state/sbx/changes/$slug/2026090$i-000000-myproj"
    done
    run bash -c "cd '$PROJ' && SBX_KEEP_CHANGES=2 $SBX --gc"
    [ "$(find "$HOME/.local/state/sbx/changes/$slug" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]
}

@test "reseed drops a forked store so the next launch re-reads the host" {
    mkdir -p "$PROJ/.sbx/profiles/cli"
    cat > "$PROJ/.sbx/profiles/cli/fk.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/tmp/fkmount","perm":"forked"}]}
EOF
    echo hostfile > "$HOSTDIR/host.txt"
    run_sbx "--cli fk --fs t" "echo owned > /tmp/fkmount/host.txt"
    echo refreshed > "$HOSTDIR/host.txt"
    run bash -c "cd '$PROJ' && $SBX --cli fk --reseed --yes"
    [ "$status" -eq 0 ]
    run_sbx "--cli fk --fs t" "cp /tmp/fkmount/host.txt /out/seen.txt"
    [ "$(cat "$HOSTDIR/seen.txt")" = "refreshed" ]
}
```

`--fs t` is needed on both launches: `t.json` is what mounts `$HOSTDIR` at
`/out`, which is how the sandbox reports back what it saw. Note that
`$HOSTDIR` is therefore both the forked mount's source and a plain `rw`
mount — that is deliberate here, and is why the assertion reads
`$HOSTDIR/seen.txt` rather than a store path.

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/sessions.bats`
Expected: the four new tests FAIL — `--gc` and `--reseed` are unrecognised
options.

- [ ] **Step 3: Implement `--gc`**

In the argument-parsing loop:

```bash
        --gc)
            for sdir in "$STATE_DIR"/sessions/*; do
                [[ -d "$sdir" ]] || continue
                gpid=$(jq -r '.pid // empty' "$sdir/session.json" 2>/dev/null | tr -d '\000-\037')
                if [[ "$gpid" =~ ^[0-9]+$ ]] && kill -0 "$gpid" 2>/dev/null; then
                    continue
                fi
                echo "Removing crash residue: $(basename "$sdir")"
                rm -rf "${sdir:?}"
            done

            keep="${SBX_KEEP_CHANGES:-10}"
            for cdir in "$STATE_DIR"/changes/*; do
                [[ -d "$cdir" ]] || continue
                find "$cdir" -mindepth 1 -maxdepth 1 -type d |
                    LC_ALL=C sort -r | tail -n "+$((keep + 1))" |
                    while IFS= read -r old; do rm -rf "${old:?}"; done
            done

            # Never removed automatically: a forked store is the user's
            # accumulated tool state, and deleting it on a heuristic is not
            # recoverable. Reported so the space is at least visible.
            if [[ -d "$STATE_DIR/forked" ]]; then
                echo "Forked stores (not removed; use --reseed):"
                du -sh "$STATE_DIR"/forked/* 2>/dev/null | sed 's/^/  /'
            fi
            exit 0
            ;;
```

- [ ] **Step 4: Implement `--reseed`**

`--reseed` needs the profiles parsed first, so set a flag during parsing and
act after profile resolution. In the parsing loop:

```bash
        --reseed)
            RESEED=true
            shift
            ;;
        --yes)
            ASSUME_YES=true
            shift
            ;;
```

Declare `RESEED=false` and `ASSUME_YES=false` beside `GUI_FLAG=false`
(~`sbx:152`). Then, immediately after the `FORKED_MOUNTS` seeding loop is
*defined* but before bwrap runs — i.e. directly before the seeding loop
added in Task 2 — insert:

```bash
if [[ "$RESEED" == "true" ]]; then
    if [[ ${#FORKED_MOUNTS[@]} -eq 0 ]]; then
        echo "No forked mounts in the selected profiles; nothing to reseed." >&2
        exit 1
    fi
    echo "This will delete the sandbox-owned copies of:"
    for fm in "${FORKED_MOUNTS[@]}"; do
        IFS=$'\t' read -r f_prof f_src f_dest <<< "$fm"
        echo "  $f_dest  (re-seeded from $f_src)"
    done
    if [[ "$ASSUME_YES" != "true" ]]; then
        read -r -p "Proceed? [y/N] " reply
        [[ "$reply" == [yY]* ]] || { echo "Aborted." >&2; exit 1; }
    fi
    for fm in "${FORKED_MOUNTS[@]}"; do
        IFS=$'\t' read -r f_prof f_src f_dest <<< "$fm"
        f_store="$STATE_DIR/forked/$f_prof/$(sbx_copy_path_slug "$PWD")/$(sbx_copy_mount_id "$f_dest")"
        rm -rf "${f_store:?}"
    done
    echo "Reseeded. The next launch will read from the host."
    exit 0
fi
```

Add to `usage()`:

```
  --changes [<id>]       Show what a record mount changed (default: latest)
  --reseed               Discard this directory's forked stores, so the next
                         launch re-seeds them from the host (asks first)
  --gc                   Remove crash residue and old change archives
  --yes                  Do not prompt for confirmation
```

- [ ] **Step 5: Prune archives at teardown too**

At the end of the record-archive block in `teardown()`, so pruning happens
without needing an explicit `--gc`:

```bash
        keep="${SBX_KEEP_CHANGES:-10}"
        find "$STATE_DIR/changes/$(sbx_copy_path_slug "$PWD")" \
            -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
            LC_ALL=C sort -r | tail -n "+$((keep + 1))" |
            while IFS= read -r old; do rm -rf "${old:?}"; done
```

- [ ] **Step 6: Run the suite**

Run: `bats tests/`
Expected: all PASS.

- [ ] **Step 7: Lint and commit**

```bash
shellcheck -S error sbx lib/copy-mounts.sh
git add sbx tests/sessions.bats
git commit -m "Add --gc and --reseed

--gc removes crash residue and prunes change archives to SBX_KEEP_CHANGES.
--reseed is the escape hatch for a forked mount having permanently stopped
reading the host; it prompts, because the store is the user's accumulated
tool state."
```

---

### Task 7: Setup progress reporting

**Files:**
- Modify: `lib/copy-mounts.sh` (add `sbx_copy_seed_progress`), `sbx`
  (call it from the `record` seeding loop; clear the line in `teardown()`)
- Test: `tests/copy-mounts.bats`

**Interfaces:**
- Consumes: `sbx_copy_seed`.
- Produces: `sbx_copy_seed_progress <src> <dst> <label>` — same effect as
  `sbx_copy_seed`, plus a progress line on stderr when the copy exceeds
  `SBX_PROGRESS_DELAY` (default 1) seconds *and* stderr is a TTY.

- [ ] **Step 1: Write the failing tests**

Append to `tests/copy-mounts.bats`:

```bash
@test "seed_progress copies the tree like seed does" {
    mkdir -p "$SRC/sub"
    echo one > "$SRC/a.txt"
    echo two > "$SRC/sub/b.txt"
    sbx_copy_seed_progress "$SRC" "$TMP" "test" 2>/dev/null
    [ "$(cat "$TMP/a.txt")" = "one" ]
    [ "$(cat "$TMP/sub/b.txt")" = "two" ]
}

@test "seed_progress prints nothing when stderr is not a tty" {
    echo one > "$SRC/a.txt"
    run bash -c "source '$BATS_TEST_DIRNAME/../lib/copy-mounts.sh'; \
                 SBX_PROGRESS_DELAY=0 sbx_copy_seed_progress '$SRC' '$TMP' test 2>&1"
    [ -z "$output" ]
}

@test "seed_progress copies a single file" {
    echo hi > "$WORK/one.txt"
    sbx_copy_seed_progress "$WORK/one.txt" "$TMP" "test" 2>/dev/null
    [ "$(cat "$TMP/one.txt")" = "hi" ]
}
```

The second test is the important one: `run bash -c` gives a non-TTY stderr,
and `SBX_PROGRESS_DELAY=0` defeats the time threshold, so *only* the TTY
gate can keep the output empty.

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/copy-mounts.bats`
Expected: FAIL with `sbx_copy_seed_progress: command not found`.

- [ ] **Step 3: Implement**

Append to `lib/copy-mounts.sh`:

```bash
# sbx_copy_seed, with a progress line for copies slow enough to look hung.
#
# Gated on BOTH a time threshold and stderr being a TTY, because the fast
# path needs no instrumentation at all: a 300MB same-filesystem btrfs seed
# is a reflink and completes in ~4ms, versus ~144ms with --reflink=never.
# Progress is only ever wanted where reflink is unavailable, which is
# exactly where it is slow. CI and pipelines print nothing.
#
# The numerator is rchar from /proc/<pid>/io — bytes the copy has consumed,
# obtained without walking the filesystem. The denominator needs du -sb,
# which is itself a full stat walk and can take seconds on a 9p mount like
# WSL2's /mnt/c, so it runs CONCURRENTLY: the display starts as
# bytes-plus-elapsed and upgrades to a percentage if and when du returns.
# rchar counts directory reads too and so overshoots slightly; the
# percentage is capped at 99 until the copy actually exits.
sbx_copy_seed_progress() {
    local src="$1" tmp="$2" label="$3"
    local delay="${SBX_PROGRESS_DELAY:-1}"

    mkdir -p "$tmp"
    [[ -e "$src" ]] || return 0

    local cp_pid du_pid du_out total="" start shown=0
    du_out=$(mktemp)

    if [[ -d "$src" ]]; then
        cp -a --reflink=auto "$src/." "$tmp/" & cp_pid=$!
    else
        cp -a --reflink=auto "$src" "$tmp/" & cp_pid=$!
    fi

    du -sb "$src" 2>/dev/null | cut -f1 > "$du_out" & du_pid=$!
    start=$SECONDS

    while kill -0 "$cp_pid" 2>/dev/null; do
        sleep 0.2
        [[ -t 2 ]] || continue
        (( SECONDS - start < delay )) && continue

        if [[ -z "$total" ]] && ! kill -0 "$du_pid" 2>/dev/null; then
            total=$(cat "$du_out" 2>/dev/null)
            [[ "$total" =~ ^[0-9]+$ ]] || total="unknown"
        fi

        local done_b
        done_b=$(awk '/^rchar:/{print $2}' "/proc/$cp_pid/io" 2>/dev/null)
        shown=1
        if [[ -n "$total" && "$total" != unknown && -n "$done_b" && "$total" -gt 0 ]]; then
            local pct=$(( done_b * 100 / total ))
            (( pct > 99 )) && pct=99
            printf '\r\033[K  %s: %d%% (%ds)' "$label" "$pct" "$(( SECONDS - start ))" >&2
        elif [[ -n "$done_b" ]]; then
            printf '\r\033[K  %s: %s copied (%ds)' \
                "$label" "$(numfmt --to=iec "$done_b" 2>/dev/null || echo "$done_b B")" \
                "$(( SECONDS - start ))" >&2
        else
            # /proc/<pid>/io unreadable — hardened procfs, or not Linux.
            printf '\r\033[K  %s: working (%ds)' "$label" "$(( SECONDS - start ))" >&2
        fi
    done

    wait "$cp_pid"; local rc=$?
    kill "$du_pid" 2>/dev/null || true
    wait "$du_pid" 2>/dev/null || true
    rm -f "$du_out"
    (( shown )) && printf '\r\033[K' >&2
    return $rc
}
```

Killing `du_pid` on the way out matters: a Ctrl-C during a slow `/mnt/c`
seed would otherwise leave an orphaned stat walk grinding away.

- [ ] **Step 4: Call it from the record seeding loop**

In `sbx`, in the loop added in Task 3, replace

```bash
    sbx_copy_seed "$r_src" "$r_work"
```

with

```bash
    sbx_copy_seed_progress "$r_src" "$r_work" "Seeding $r_dest"
```

and in the `forked` loop from Task 2, replace

```bash
        sbx_copy_seed "$f_src" "$f_store"
```

with

```bash
        sbx_copy_seed_progress "$f_src" "$f_store" "Seeding $f_dest"
```

- [ ] **Step 5: Clear the line on an interrupt**

As the first statement in `teardown()`, after `local exit_status=$?`:

```bash
    # A seed interrupted mid-progress leaves a partial line on the terminal.
    [[ -t 2 ]] && printf '\r\033[K' >&2
```

- [ ] **Step 6: Run the full suite**

Run: `bats tests/`
Expected: all PASS.

- [ ] **Step 7: Lint and commit**

```bash
shellcheck -S error sbx lib/copy-mounts.sh
git add sbx lib/copy-mounts.sh tests/copy-mounts.bats
git commit -m "Report progress for slow mount seeds

Seeding happens before bwrap runs, so a large tree on a filesystem without
reflink makes sbx look hung. Gated on a time threshold and a TTY so the fast
path stays silent; the numerator comes from /proc/<pid>/io to avoid walking
the tree, and the du supplying the denominator runs concurrently."
```

---

## Final verification

- [ ] `bats tests/` — all five suites pass.
- [ ] `shellcheck -S error sbx lib/copy-mounts.sh` — silent.
- [ ] `grep -rn '"copy"' profiles/` — no results.
- [ ] `grep -n 'sbx_copy_writeback\|CLI_STORE_DIR\|SESSION_DIR/fs\|tmp_mounts' sbx lib/` — no results.
- [ ] Manual: run `sbx --cli claude` in a real project twice; confirm
      `~/.claude` state carries over and `~/.local/state/sbx/sessions/` is
      empty afterwards.
- [ ] Manual: `sbx --list-sessions` in a directory with no live session
      prints only the header.
- [ ] Update `README.md`'s "Copy Mount Egress" section, which documents the
      removed behavior.
