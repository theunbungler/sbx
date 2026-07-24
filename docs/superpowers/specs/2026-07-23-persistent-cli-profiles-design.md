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

- **The store is keyed by cli profile name *and* the external invoking
  directory.** `sbx --cli claude` in `~/projA` and in `~/projB` get
  separate persistent stores; re-running in the same directory resumes.
  No `--instance` flag.

  An earlier revision of this spec keyed on the profile name alone, on the
  theory that a cli profile *is* one identity and should persist as one
  unit. That was wrong in practice, for a reason that only surfaced during
  implementation: the fs profiles normalize every project to a fixed
  working directory inside the sandbox (`sandbox.json` mounts `$PWD` at
  `/workspace`; `default.json` maps `./src` to `/home/user/src`). The CLI
  therefore sees the *same* cwd in every project, so the tool's own
  per-project partitioning — Claude Code writes sessions under
  `~/.claude/projects/<cwd-slug>/` — collapses into a single bucket. Under
  a name-only store, that means every project's sessions accumulate in one
  shared `projects/-workspace/` directory and interleave. Keying the store
  by the external invoking path restores the per-project separation the
  CLI can no longer make for itself, matching how these tools behave
  unsandboxed.

  This does mean auth and global config (`.claude.json`, `settings.json`)
  are *not* shared across projects — each directory re-authenticates. That
  is a deliberate accepted cost of doing the separation at the store layer
  rather than by preserving the real cwd inside the sandbox (which would
  have been a broader change to fs-profile working-directory handling,
  out of this feature's scope).

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
~/.local/state/sbx/profiles/cli/<profile-name>/<cwd-slug>/<mount_id>/
```

`<mount_id>` is the existing `dest`-with-slashes-translated identifier
(`/home/user/.claude` → `_home_user_.claude`), so the leaf is structurally
identical to today's per-session `fs/<mount_id>/` egress directory.

`<cwd-slug>` is the external invoking directory (`$PWD`, the same value
`sbx` already records as `"cwd"` in `session.json`) with slashes
translated, Claude-Code style: `/home/user/projA` → `-home-user-projA`.
This is the component that separates one project's persistent store from
another's.

Like Claude Code's own slug, this is lossy: `/home/user/a-b` and
`/home/user/a/b` both slug to `-home-user-a-b`, so two sibling projects
differing only in dash-vs-slash would share a store. Accepted — it
requires a contrived directory layout, affects only the one user's own
projects (no cross-trust-boundary effect), and matches the upstream tools'
identical behavior.

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

The diff baseline stays the host source, not the store. The reason is
semantic, not a correctness cliff: "differs from the host" is what the
store is supposed to mean — the set of divergences from the user's real
config — so the store stays a minimal delta rather than growing into a
full mirror of the host directory.

An earlier draft of this spec claimed the baseline was load-bearing for
survival — that a file written in session 1 would be dropped in session 3
unless the comparison used the host. That was wrong, and the test written
to prove it was tautological (it passed with the overlay removed
entirely). Survival across untouched sessions comes from write-back never
pruning the store, not from the choice of baseline. Recorded here because
the false claim is more dangerous than the true one: it would have sent a
future reader hunting for a bug that does not exist.

fs-profile `copy` mounts take neither path. They seed from the host with
no overlay and egress to `$SESSION_DIR/fs/<mount_id>/`, exactly as now.

## Concurrency

Two simultaneous `sbx --cli claude` sandboxes launched *from the same
directory* share one store (a different directory is a different store
and never contends). This is safe enough to need no locking, because
these CLIs already assume concurrent sessions and lay their state out
accordingly. Inspection of a real `~/.claude`:

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
