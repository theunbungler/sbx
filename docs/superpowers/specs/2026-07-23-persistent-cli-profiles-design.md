# Persistent CLI profiles: `copy` as an overlay with a per-profile store

**Date:** 2026-07-23
**Status:** Designed, not implemented

**Builds on:** the existing `copy` mount perm and its teardown egress
(see README "Copy Mount Egress"). No other sbx subsystem is touched —
this design adds no CLI flags, no new profile fields, and no new perm
keyword.

## Goal

Make a CLI tool's own state survive across sandbox instantiations, so
that `sbx --cli claude` resumes with the sessions, history, and
tool-local config it accumulated last time, instead of resetting to
whatever is on the host.

Today `copy` snapshots the host directory into `$SESSION_DIR/tmp_mounts/`,
binds it in, and at teardown diffs it against the host source and writes
new/changed files to `~/.local/state/sbx/<session-id>/fs/<mount_id>/`.
Nothing reads that egress back. Every launch therefore starts from the
host's state, and everything the agent accumulated is deposited in a
per-session directory nobody looks at.

The motivating case is `~/.claude/projects/<path>/<uuid>.jsonl` — the
conversation transcripts. Under today's behavior a sandboxed agent can
never resume its own prior session.

## Design decisions (with rationale)

- **The semantic is chosen by profile *type*, not by a new keyword.**
  `copy` in a **cli** profile means persistent-overlay (this design).
  `copy` in an **fs** profile keeps today's ephemeral meaning, unchanged.
  This maps onto what the two profile types are actually for: fs
  profiles scope a sandbox's view of a *project*; cli profiles carry a
  *tool's identity*. Identity is the thing that should persist.

- **The cli profile name is the store key.** No `--instance` flag, no
  per-project keying. `--cli claude` anywhere gets the same store. This
  follows from the decision above: if the cli profile *is* the identity,
  it is also the natural persistence unit.

- **Declared perms are still honoured.** Only mounts declared
  `"perm": "copy"` get the persistent treatment. `ro` and `rw` in a cli
  profile behave exactly as they do now. Coercing every directory mount
  to `copy` was considered and rejected: `~/.nvm`, `~/.npm-global` and
  `~/.local` are read-only toolchain, not identity, and copying them
  would duplicate gigabytes per profile for no isolation benefit.

- **Overlay, not replacement.** Each launch seeds from the host as it
  does today, then replays the persisted store on top. The alternative —
  store is authoritative, host never re-read after first seed — was
  rejected because its staleness is unbounded and invisible: a new MCP
  server, hook, or settings change on the host would never reach the
  sandbox, and nothing would indicate why.

- **No locking.** Concurrent sandboxes sharing a store write back
  per-file last-teardown-wins. This was checked against how the CLIs
  actually lay out their state rather than assumed (see Concurrency
  below).

- **No exclude list.** Considered and rejected for v1 on measurement
  (see Seed cost below).

## Mechanism

The store lives at:

```
~/.local/state/sbx/profiles/cli/<profile-name>/<mount_id>/
```

`<mount_id>` is the existing `dest`-with-slashes-translated identifier
(`/home/user/.claude` → `_home_user_.claude`), so the store is
structurally identical to today's per-session `fs/<mount_id>/` egress
directory. It *is* that directory, promoted from per-session to
per-profile scope.

**Seed (session start), for each `copy` mount in the applied cli
profile:**

1. `cp -a --reflink=auto` the host source into
   `$SESSION_DIR/tmp_mounts/<mount_id>/`, as today.
2. If a persistent store exists for this profile+mount, overlay it on
   top of the seeded copy — store entries win, per file.
3. Bind `tmp_mounts/<mount_id>` at `dest`, as today.

**Write-back (teardown), for each `copy` mount in the applied cli
profile:**

1. Diff `tmp_mounts/<mount_id>` against the *host source* — the same
   new-or-modified comparison used today.
2. Write the differing files into the **persistent store** rather than
   into `$SESSION_DIR/fs/<mount_id>/`.

The diff baseline stays the host source, not the store. This is what
makes the store accumulate correctly: a file the sandbox wrote in an
earlier session still differs from the host, so it is re-written to the
store and survives, even in a session that never touched it.

fs-profile `copy` mounts take neither path. They seed from the host with
no overlay and egress to `$SESSION_DIR/fs/<mount_id>/`, exactly as now.

## Concurrency

Two simultaneous `sbx --cli claude` sandboxes share one store. This is
safe enough to need no locking, because these CLIs already assume
concurrent sessions and lay their state out accordingly. Inspection of a
real `~/.claude`:

- `projects/<path>/<uuid>.jsonl` — one file per session
- `shell-snapshots/`, `session-env/`, `tasks/`, `debug/`,
  `security/security_warnings_state_<uuid>.json` — per-session files
- `history.jsonl` — append-only
- `.claude.json`, `settings.json` — genuinely shared, read-modify-write

Only the last group can contend, and those already get last-write-wins
across concurrent sessions *on the host* today. Write-back reproduces
that rather than inventing a stricter rule: each teardown copies the
files that differ from the host source into the store, overwriting, so
the last teardown wins for any file it touched. Store files that a
session did not touch are left alone — write-back never prunes the
store — so two concurrent sessions working on different files both
persist.

Locking schemes (refuse the second launch; or fall back to ephemeral
with a warning) were designed and discarded: they solve a problem the
tools have already solved by file layout, at the cost of either blocking
the common case or making persistence non-deterministic.

One real asymmetry, accepted: on the host, clobbering happens at write
time (seconds granularity, bounded to what one session changed in that
window). Here it happens at teardown (session granularity), so a long
sandbox session can revert a shared file that a shorter concurrent one
updated. This is confined to `.claude.json` and `settings.json`.

## Seed cost

`~/.claude` measures 337M, which initially looked like a reason to add
per-mount exclusions. Measurement showed otherwise:

- `security/agent-sdk-venv` is 281M of it — a Python virtualenv, 2555
  files, **zero modified in the last 30 days**. Static toolchain, not
  churn.
- `debug/` is 22M across 10 files, also static.
- The actual target, `projects/`, is 13M.

Consequences: the venv contributes **nothing** to the teardown diff
(unchanged files are never egressed), so the store does not grow with
it. The only real cost is seed-time copy, and `$STATE_DIR` sits on the
same btrfs subvolume as `~/.claude` — verified — so `--reflink=auto`
makes the seed a metadata-only CoW operation. On ext4 or across
filesystems it degrades silently to a normal copy.

An `"exclude": [...]` field on the mount object was designed and
dropped. Revisit only if profiling shows the seed is slow in practice.

## Known sharp edges

Both are inherent to the overlay model and are accepted.

- **Deletions do not stick.** A file deleted inside the sandbox returns
  from the host on the next launch, because the host is re-seeded every
  time and the store has no way to express a tombstone. This is
  consistent with what `copy` means — the host directory is the floor.

- **Shadowing.** Once the sandbox has written a given file, the store's
  version wins on every subsequent launch, so the host's version of
  *that file* is masked indefinitely. This is sharpest for
  `~/.claude.json`, a single monolithic file both sides write: the first
  sandbox write freezes the host's copy out for good. Host-side changes
  to files the sandbox has never touched still flow through normally.

## Follow-up (not in this design)

`--reseed` — drop a cli profile's store and start clean. The pressure
valve for shadowing. Deliberately deferred so v1 stays small; the store
is a plain directory, so `rm -rf` is an adequate stopgap.

## Testing

- fs-profile `copy` is unchanged: a `copy` mount in an fs profile still
  egresses to `$SESSION_DIR/fs/<mount_id>/` and does not create or read
  a persistent store.
- First launch of a cli profile with no store seeds from the host alone.
- A file created in the sandbox appears in the store after teardown, and
  is present inside a subsequent sandbox.
- That file persists across a *third* session in which it is untouched
  (verifies the diff baseline is the host, not the store).
- A file changed on the host after the store exists, and never touched
  by the sandbox, is visible inside the sandbox (verifies overlay, not
  replacement).
- A file changed on *both* sides resolves to the store's version
  (documents shadowing).
- A file deleted in the sandbox returns on the next launch (documents
  deletion behavior).
- The host source directory is never modified, in any of the above.
- `--reflink=auto` falls back cleanly when source and store are on
  different filesystems.

## Documentation

README needs updating in two places, both of which currently state the
ephemeral behavior unconditionally:

- the `perm` table row and "Permission modes explained" bullet for
  `copy`, which must now distinguish fs from cli profiles
- the "Copy Mount Egress" section, which must document the per-profile
  store path alongside the per-session one
