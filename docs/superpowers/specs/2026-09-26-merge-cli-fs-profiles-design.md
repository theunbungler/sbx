# Merge cli and fs profiles

## Why

Since the `copy` perm was retired in favour of `forked` and `record`
(418d197), nothing about a mount depends on the profile's type. A cli
profile is now an fs profile with one extra field, `path`, that can only be
applied once per session:

| | cli | fs |
|---|---|---|
| Fields | fs's, plus `path` | `description, mounts, env, passthrough, caps, userns, docker_api` |
| Per session | one; a second `--cli` silently replaces the first | any number, stacked |
| Apply order | after every fs profile | flag order |

The split costs users a choice that means nothing, and the one-per-session
rule is a trap (`--cli a --cli b` drops `a` without a word). This design
folds cli into fs.

## Decisions

- `--fs` is the one repeatable profile flag.
- `--cli` stays, for compatibility only, as an alias whose profiles are
  applied after every `--fs` profile.
- There is no `cli/` lookup fallback. Profiles under a `cli/` directory are
  not loaded; sbx warns about them. No automatic migration (consistent with
  be38a8f, which dropped profile-transition logic).
- net profiles are untouched: a different schema, feeding a different part
  of the launch.

## Design

### 1. Command line (`sbx`)

- `--fs <name>`: unchanged, repeatable.
- `--cli <name>`: resolves an fs profile and appends it to a separate list
  that is applied after all `--fs` profiles, in the order given. Repeatable:
  `--cli a --cli b` applies `a` then `b`.
- A `cli/<name>` type prefix is no longer accepted; `fs/<name>` still is.
- `usage` describes `--cli` as "apply an fs profile last (compatibility)".

`sbx` passes `lib/resolve.sh` the combined list (fs flags, then cli flags) as `--fs`
arguments, so `lib/resolve.sh` sees one ordered list and needs no notion of
cli at all.

### 2. Schema (`lib/profile-check.sh`, `lib/profiles.sh`)

- `known` loses `cli`; `fs` gains `path`:
  `description, env, path, mounts, passthrough, caps, userns, docker_api`.
- `sbx_profile_valid_type` accepts `fs` and `net` only.
- `sbx_profile_template fs` becomes what `cli` produced:
  `{description, env: {}, passthrough: [], mounts: []}`.
- `SBX_PROFILE_RESTRICTED` and every project restriction are unchanged.

### 3. PATH (`lib/resolve.sh`)

Each applied profile's `path` entries are collected in application order,
and **a later profile's entries go in front of an earlier one's**. That is
the same "later wins" rule `env` already follows, and it reproduces today's
behaviour exactly for `--cli` (applied last, its entries first).

The combined list is handed to the unchanged `sbx_resolve_path`, so it still
goes in front of any `env.PATH` and the default still closes it. The
`cli_path` special case and the `--cli` argument of `sbx_resolve` are
removed.

### 4. Lookup and the leftover warning

- `sbx_profile_resolve` searches `fs/` only (with net unchanged).
- Not found, but `cli/<name>.json` exists at any of the three locations: the
  error names that file and the `fs/` path to move it to.
- A new helper, `sbx_profile_legacy_cli_dirs <config_dir> <global_dir>`,
  prints each of `./.sbx/profiles/cli`, `$config_dir/profiles/cli` and
  `$global_dir/cli` that holds at least one `.json` file.
- `sbx_resolve` adds one plan warning per such directory, built by
  `sbx_profile_legacy_cli_warning <dir>`:
  `cli profiles are now fs profiles, so none in <dir> are loaded; move them to <parent>/fs`.
  It therefore appears on every launch and in `--dry-run` (text and JSON),
  after any trust prompt, as all warnings do.
- `sbx_profile_list` lists FS and NET only, and prints the same warning for
  each leftover directory.
- `sbx-profile`: `new`, `check` and the type inference accept `fs` and `net`;
  a `cli` type or a path under a `cli/` directory is refused with the same
  move hint.

The warning text is built from paths sbx chose, not from file contents, but
it still passes through `sbx_sanitize_message` like every other warning.

### 5. Repository and records

- `profiles/cli/{claude,dev,gemini,pi}.json` move to `profiles/fs/`. None
  collide with the existing fs profiles (`chrome, default, podman,
  podman-full, sandbox`).
- `forked` stores are keyed by profile *name* (`lib/state-paths.sh`,
  `sbx_state_forked_store`), not type, so `--fs claude` finds the stores
  `--cli claude` created. No state moves.
- `session.json` drops `cli_profile`; `fs_profiles` lists every applied
  profile in application order. Nothing reads `cli_profile` today.

## Testing

Updated: every suite that names cli (`profiles`, `resolve`, `profile-check`,
`sbx-profile`, `dry-run`, `render`, `persistent-cli`, `sessions`, `hardening`,
`nested`, `join`, `snapshot`).

New tests:
- `--cli a --cli b` applies both, in order, after every `--fs`.
- PATH across stacked profiles: a later profile's entries come first; all
  come before `env.PATH`; the default closes the list.
- `path` is valid in an fs profile, and still subject to validation.
- Not-found with a matching `cli/<name>.json` prints the move hint.
- A leftover `cli/` directory yields the plan warning on launch and
  `--dry-run`, and in `--list-profiles`; an empty one does not.
- `sbx-profile new cli/x` is refused with the hint.
- A `forked` store created under the old cli name is reused by `--fs`.

Snapshots are regenerated with `SBX_UPDATE_SNAPSHOTS=1`, and the diff is
reviewed line by line. Expected changes only: `cli_profile` gone from every
`session.json`; in `mounts`, the fixture profile moves from `cli/` to `fs/`
and its `fs_profiles` entry appears. Any other change is a bug.

Gate: `bats -j 4 tests/` passes and
`shellcheck -x -S error sbx sbx-profile lib/*.sh tests/helpers/*.sh` is
silent.

## Docs

README (the CLI Profiles section folds into FS Profiles; `path` documented
there; a short note on `--cli` and the leftover warning), `sbx --help`,
`sbx-profile --help`, and CLAUDE.md.

## Out of scope

- Moving users' `cli/` profiles automatically.
- Renaming `lib/copy-mounts.sh` or its `sbx_copy_*` functions.
- Any change to net profiles.
