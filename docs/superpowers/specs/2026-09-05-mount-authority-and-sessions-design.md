# Mount authority: `forked` and `record`, and the session lifecycle

**Date:** 2026-09-05
**Status:** Designed, not implemented

**Supersedes:** `docs/superpowers/specs/2026-07-23-persistent-cli-profiles-design.md`.
That design made persistence a property of the *profile type* (`copy` in a
cli profile persists; `copy` in an fs profile does not). This one makes it a
property of the *mount*, which is where the distinction actually lives. The
per-profile, per-directory store keying from that spec is kept verbatim; its
rationale still holds and is not re-argued here.

**Builds on:** the `copy` mount perm and its teardown egress. Touches
`lib/copy-mounts.sh`, the `apply_mounts` case at `sbx:845`, the seeding at
`sbx:887-914`, the teardown at `sbx:1395-1421`, and `--list-sessions` at
`sbx:161`. No changes to networking, capabilities, `--join`, or `--attach`
beyond path relocations.

## Goal

Two things, which turn out to be one thing.

1. **Make what persists, and what doesn't, a declared property of each
   mount** — rather than something inferred from which profile the mount
   happens to sit in.
2. **Stop `--list-sessions` accumulating dead date-keyed entries**, by
   making sessions genuinely ephemeral and moving everything durable out
   of them.

(2) falls out of (1): once durable state lives in mount-keyed stores, a
session directory holds nothing worth keeping and can be deleted on exit.

## The problem

`perm: "copy"` names two opposite intentions, and `sbx:846-863` already
says so in a comment:

- `profiles/fs/default.json` maps `./src` to `/home/user/src` with `copy`.
  Intent: *the host owns this tree; give the sandbox a scratch copy so it
  cannot damage the original.*
- `profiles/cli/claude.json` maps `$HOME/.claude` with `copy`. Intent:
  *the tool owns this directory; give it a home that survives across runs.*

Opposite authority, one keyword, disambiguated by which file the line
appears in. The `--cli` persistent store exists precisely because the
keyword could not express the second case.

That conflation produces three concrete defects in `lib/copy-mounts.sh`:

1. **Permanent silent shadowing.** `sbx_copy_seed` lays the store over the
   host copy, store winning per file (`copy-mounts.sh:41-44`). Once a file
   is in the store it wins forever; a later host edit to that file is never
   visible again, with no invalidation and no message.
2. **Deletion is impossible.** `sbx_copy_writeback` "never prunes `$out`"
   (`copy-mounts.sh:50`). A file deleted inside the sandbox remains in the
   store and is re-seeded on the next launch.
3. **A race that pins stale content.** The diff baseline is the *live host
   source at teardown* (`copy-mounts.sh:64`). If the host changed a file
   while the session ran, a file the sandbox never touched now differs from
   the baseline and is written into the store — permanently pinning the
   *old* host content. The race window is the session's entire runtime.

Defect 3 is a data-correctness bug independent of any redesign.

## Design decisions (with rationale)

### Authority is declared per mount

Each mount states who is authoritative for its contents. Four perms:

| perm | authority | seeded | survives | teardown |
|---|---|---|---|---|
| `ro` | host | — | — | nothing |
| `rw` | host, shared | — | writes are live | nothing |
| `forked` | **sandbox** | once, on first launch | yes, stable path | nothing |
| `record` | host | every launch | no, resets | archive the changes |

`ro` and `rw` are unchanged in behavior and implementation.

### `forked`: seeded once, owned thereafter — and no overlay

A `forked` mount is initialized from the host source the first time it is
used, and from then on the sandbox owns it outright.

- **First launch:** the store path does not exist → `cp -a --reflink=auto`
  the host source into it.
- **Every launch, including the first:** plain `--bind` of the store at the
  destination. The sandbox reads and writes the store directly.
- **Teardown:** nothing. There is no copy back because there was no copy
  out.

No overlay, no second layer, no diff, no baseline. All three defects above
stop existing rather than being fixed: there is no diff to get wrong (3),
no layering for a store to shadow through (1), and deletion is ordinary
`unlink` on a real directory (2).

**Accepted cost, stated plainly:** after the first launch, host edits to the
source never reach the sandbox. This is the defining property of the perm,
not a limitation of the implementation. `--reseed` (below) is the escape
hatch.

The name is a past participle deliberately: it describes the mount's
standing condition, true on run 1 and run 500 alike, rather than an action
performed at setup. A fork is a point event whose consequence — two lines
that never re-sync — is permanent, which is exactly the semantic and
exactly the thing that surprises people.

### `record`: reseeded every launch, diffed against the snapshot

A `record` mount gives the sandbox an isolated working copy of the host
source, and reports what changed.

- **Launch:** `cp -a --reflink=auto` the host source into a per-session
  working copy, and compute a **manifest** over it (relative path →
  content hash and mode). Bind the working copy at the destination.
- **During:** the sandbox reads and writes the working copy. The host
  source is never written.
- **Teardown:** walk the working copy against the manifest. Added,
  modified, and deleted entries are the change set. Copy added and modified
  files into a retained archive; record deletions as a manifest of removed
  paths. Delete the working copy.
- **Next launch:** a fresh copy from the host source. Previous runs'
  archives are untouched.

**Why a manifest rather than a second pristine copy.** Diffing needs a
baseline. A second full copy of the tree is the obvious one, but doubles
launch cost on any filesystem without reflink. A manifest costs one hash
pass at launch — over pages already warm from the copy that just ran — and
one at teardown, while storing a single copy of the data. It also detects
deletions, which the current content-diff cannot express at all.

**This fixes defect 3.** The baseline is the tree *as seeded at launch*,
not the live host source at teardown. A host edit during the session
cannot masquerade as a sandbox change.

### Overlayfs was evaluated and rejected

Overlayfs is the obvious implementation for both perms: `upperdir` is the
change set for free, whiteouts make deletion explicit, and copy-up gives
per-file authority transfer with no code. It is available here — bwrap
0.11.2 has `--overlay`, unprivileged overlay needs kernel 5.11+ and this
host is on 6.12. It is nonetheless the wrong choice:

- **`lowerdir` must not change while mounted.** The kernel documents this
  as undefined behavior. In practice, content rewrites of an existing lower
  file usually pass through, while namespace changes (create, delete,
  rename) may not appear or may appear inconsistently. That is the worst
  failure profile available: reliable enough to depend on, unreliable
  exactly when it matters. Editing a source tree in a host editor while a
  sandbox runs is a completely ordinary thing to do. No mount option fixes
  it; `index`, `metacopy` and `redirect_dir` all increase cached state.
- **WSL2 is a supported target, and `/mnt/c` is `drvfs` (9p).** As
  `upperdir` it is flatly unsupported — no user xattrs, so no whiteouts —
  and the mount fails with `EINVAL`. As `lowerdir` it is nominally allowed
  but hazardous: Windows filesystems are case-insensitive by default while
  overlayfs assumes case-sensitive semantics throughout, and without the
  `metadata` mount option drvfs cannot represent the modes and ownership
  that copy-up tries to preserve.
- **Not worth two mechanisms.** The portable fallback must exist and be
  tested regardless. Carrying a second set of semantics to save a hash pass
  on one of three platforms is a poor trade.

Once `lowerdir` must be a private snapshot for correctness, overlay's
remaining advantage over copy-plus-manifest is a hash pass. It can be added
later, behind the same snapshot anchor, without changing any observable
behavior.

The design therefore requires nothing of the filesystem beyond the ability
to hold files.

### `copy` is a hard error, not an alias

`copy` currently means `forked` in cli profiles and `record` in fs
profiles. Aliasing it to either would silently pick wrong half the time.
The loader rejects it:

```
Error: profiles/cli/claude.json: mount "$HOME/.claude" uses perm "copy",
  which has been split into "forked" (sandbox owns the data; seeded from
  the host once) and "record" (host owns the data; changes are archived
  each run). Pick one.
```

The shipped profiles are migrated in the same change: every `copy` in
`profiles/cli/*` becomes `forked`; the `./src` mount in
`profiles/fs/default.json` becomes `record`.

**Existing `--cli` stores are migrated, not discarded.** Today's store
lives at `profiles/cli/<profile>/<dir-slug>/<mount-id>/` and its contents
are already a valid owned tree — every file the sandbox ever changed, which
is exactly what `forked` binds. The new layout puts it at
`forked/<profile>/<dir-slug>/<mount-id>/`, so a one-time `mv` of
`profiles/cli/` to `forked/` on first run of the new version preserves all
accumulated tool state. (The old location is a poor name regardless: it
sits under a `profiles/` directory that otherwise holds no state.) The one
behavior change users will observe is that host-side edits to a file the
sandbox has already touched stop leaking in, which was defect 1.

## State layout

```
~/.local/state/sbx/
  sessions/<name>/                          live runtime only; removed at teardown
      session.json  tmux.sock  tmux.conf  session.sh  wrapper.sh
      launch.sh  bin/  dns/  virt/  tmp/
  join/<name>.json                          join sidecar (outside sessions/, see below)
  join/<name>.lock                          teardown/join mutex
  forked/<profile>/<dir-slug>/<mount-id>/   owned trees; bound rw
  work/<name>/<mount-id>/                   record working copies; removed at teardown
  work/<name>/<mount-id>.manifest           launch-time baseline
  changes/<dir-slug>/<stamp>-<name>/<mount-id>/          retained change archives
  changes/<dir-slug>/<stamp>-<name>/<mount-id>.deleted
```

`<mount-id>` and `<dir-slug>` keep their current derivations
(`sbx_copy_mount_id`, `sbx_copy_path_slug`).

The join sidecar and lock stay outside `sessions/<name>/` for the reason
given at `sbx:1252-1257`: the session directory is bound rw into the
sandbox, so anything inside it is attacker-authored, and `--join` must not
take security-relevant input from the sandbox it is about to enter. Moving
them under `join/` makes that boundary explicit in the layout rather than
implicit in a filename convention.

`$SESSION_DIR/fs/` is deleted. It is write-only today — `sbx:1407` writes
to it and nothing reads it — and under this design nothing writes to it
either.

## Session lifecycle

### A session is a running process

`sessions/<name>/` is created at launch and **removed in `teardown()`**.
Nothing durable lives there any more, so there is nothing to keep. This is
the entire fix for the accumulating-inactive-sessions complaint: inactive
sessions cease to exist rather than being listed.

`--list-sessions` correspondingly lists only live sessions, and drops the
`(inactive)` branch at `sbx:177-179`. A directory in `sessions/` whose pid
is dead is a crash residue, not a session; it is reported once under
`--gc` and removed.

### Names

The current id is `date +%Y%m%d-%H%M%S-$RANDOM` (`sbx:542`) — unique, and
unusable as something you type at `--join`.

Sessions are named after the launch directory's basename, with a numeric
suffix only when needed to disambiguate a concurrently live session:

```
~/git/sandbox-gemini   ->  sandbox-gemini
                           sandbox-gemini-2   (only if the first is live)
```

Because dead sessions are removed, the plain name is free again as soon as
a session exits, so the common case is that `--join sandbox-gemini` always
works and no one ever types a suffix. Two live sessions in different
directories sharing a basename disambiguate the same way, by suffix, in
launch order.

Name derivation: basename, lowercased, non-`[a-z0-9._-]` replaced with
`-`, truncated to 32 characters, and falling back to `sbx` if that leaves
nothing. Uniqueness is established by `mkdir` on `sessions/<name>`
succeeding — an atomic claim, so two simultaneous launches cannot both
take a name.

Session names are reused over time, so they cannot key the change
archives on their own. Archives are keyed `<timestamp>-<name>` —
`20260905-141500-sandbox-gemini` — which is unique, sorts chronologically,
and makes "keep the most recent N" an `ls | sort | head`. The date-stamped
identifier does not disappear; it moves to the one place where a history
is actually wanted.

### Garbage collection

- **Session directories:** removed at teardown; crash residue removed by
  `--gc`.
- **`changes/` archives:** keep the most recent N per directory (default
  10), prune older on each teardown. Configurable via `SBX_KEEP_CHANGES`.
- **`forked/` stores:** never automatically removed. They are the user's
  data, and deleting a tool's accumulated state on a heuristic is not
  recoverable. `--gc` reports their sizes; removal is explicit.

### New flags

```
--changes [<session>]   List what a record mount changed. With no argument,
                        the most recent archive for this directory.
--reseed [<mount>]      Delete this directory's forked stores so the next
                        launch re-seeds them from the host. With no
                        argument, all of them for the active cli profile.
                        Prompts unless --yes.
--gc                    Remove crash residue and over-quota change
                        archives; report forked store sizes.
```

`--changes` is what makes `record` useful rather than merely safe: the
archive is a plain directory tree plus a `.deleted` list, so it can also be
inspected, `diff -r`'d, or copied by hand without tool support.

## Non-goals and open questions

**Resolved by construction: "resume the last session in this directory."**
The original motivation for this work was making a re-run in the same
directory pick up where the last one left off. Under this design that is
not a feature — `forked` state is bound in every launch by definition, so
there is nothing to resume. `--join` remains what it is: a door into a
*live* session, an unrelated axis.

**Open: flag recall.** Bare `sbx` in a directory could remember the last
launch's `--fs`/`--net`/`--cli` flags so they need not be retyped. This is
a genuine ergonomic want and is now cleanly separable from state, since it
carries no filesystem semantics — it is a small `lastrun.json` per
directory slug and a rule for when an explicit flag overrides it. **Not
specified here**, because it was never settled: it needs a decision about
whether recalled flags are silent or announced, and whether a recalled
`--net` is acceptable given that it changes the sandbox's security
posture. Recommend deferring to its own spec.

**Open: `record` on very large trees.** Two full passes (hash at launch,
hash at teardown) plus a copy. On btrfs the copy is a reflink and nearly
free; the hashing is not. If this bites, the mitigation is to hash lazily —
compare size and mtime first, hash only on a match-ambiguous entry — which
reintroduces the granularity problem that `copy-mounts.sh:51-56` documents
having already been burned by. Measure before optimizing.

## Testing

Extends `tests/copy-mounts.bats` and `tests/persistent-cli.bats`; the
existing `copy` cases are rewritten against the new perms rather than
deleted.

**`forked`:**
- First launch with no store seeds from the host; the sandbox sees host
  content.
- Second launch binds the store; a file written in launch 1 is present in
  launch 2.
- A host edit made between launches to a file the store contains is **not**
  visible in launch 2. (This is defect 1, now the specified behavior.)
- A file deleted in the sandbox stays deleted across launches. (Defect 2.)
- The host source is byte-identical after a launch that rewrote everything.
- `--reseed` restores host content on the next launch.
- An existing pre-migration `--cli` store is bound successfully with its
  contents intact.

**`record`:**
- Host source is unmodified after a session that wrote, added, and deleted
  files.
- The archive contains exactly the added and modified files.
- Deleted paths appear in `.deleted` and nowhere else.
- **A host edit made *during* the session does not appear in the archive.**
  This is the regression test for defect 3, and it fails against the
  current implementation.
- A second launch sees host content, not the first launch's changes.
- Archive pruning keeps exactly N.

**Sessions:**
- `sessions/<name>/` does not exist after a clean exit.
- `--list-sessions` shows nothing after all sessions end.
- Two concurrent launches in the same directory get `<name>` and
  `<name>-2`; the second name is released when the first exits.
- `--join <name>` reaches the right session when two are live.
- Crash residue (a session directory with a dead pid) is not listed and is
  removed by `--gc`.

**Migration:**
- A profile containing `perm: "copy"` fails to load, with a message naming
  both replacements.
- Every shipped profile in `profiles/` loads.

## What this deletes

- `sbx_copy_writeback` in its entirety, including the rsync/`cmp` fallback
  and the whole content-vs-mtime discussion at `copy-mounts.sh:51-56` —
  the manifest makes the question moot.
- The store-overlay branch of `sbx_copy_seed` (`copy-mounts.sh:41-44`).
- Both writeback loops and `tmp_mounts` cleanup in `teardown()`
  (`sbx:1395-1417`).
- `$SESSION_DIR/fs/` and `$SESSION_DIR/tmp_mounts/`.
- The `(inactive)` branch of `--list-sessions` (`sbx:177-179`).
- `COPY_MOUNTS` / `CLI_COPY_MOUNTS` as a pair; one list carrying a perm
  discriminator replaces them, since the profile type no longer selects
  behavior.

`lib/copy-mounts.sh` retains `sbx_copy_mount_id`, `sbx_copy_path_slug` and
a reduced `sbx_copy_seed`, and gains the manifest build and compare.
