# Continue: sbx setup-UX work (paste this into a new session)

We are partway through a five-phase "setup UX" effort on the `setup-ux`
branch of this repository (`~/git/sandbox-gemini`). Everything below is the
state as of 2026-09-19.

## Read these first

- Spec (all five phases): `docs/superpowers/specs/2026-09-16-setup-ux-design.md`
- Phase 1 plan (done): `docs/superpowers/plans/2026-09-16-setup-ux-phase1-deps.md`
- Phase 2 plan (done): `docs/superpowers/plans/2026-09-17-setup-ux-phase2-resolve.md`
- Phase 3 plan (done): `docs/superpowers/plans/2026-09-18-setup-ux-phase3-dry-run.md`
- Phase 4 plan (done): `docs/superpowers/plans/2026-09-19-setup-ux-phase4-sbx-profile.md`

## Where the work stands

**Branch `setup-ux`, ahead of `main`, nothing merged.** After each phase the
user has chosen to keep the branch as-is rather than merge or open a PR.

- **Phase 1 (dependencies) — complete.** `lib/deps.sh`, launch preflight,
  `sbx --doctor [--json]`.
- **Phase 2 (resolve step and validation) — complete.** `lib/profiles.sh`,
  `lib/profile-check.sh`, `lib/net-merge.sh`, `lib/resolve.sh`; `sbx`
  hydrates its launch from one JSON plan. `tests/snapshot.bats` holds golden
  files of everything a launch generates; they still pass unregenerated.
- **Phase 3 (`sbx --dry-run [--json]`) — complete.** `lib/state-paths.sh`
  (session name, forked-store path, socket probe, `sbx_state_writes`),
  `sbx_deps_status`, `lib/render.sh`. State setup is `sbx_state_init`, run by
  every command branch and after parsing, except under a dry run. Exit 0/1/2.
  Also, by the user's decision after review: unknown `--options` are rejected
  (exit 2) instead of becoming the payload command, and the dry run shows env
  values and PATH unexpanded (`raw`, `path_raw`) so host secrets are not
  printed.
- **Phase 4 (`sbx-profile ls|check|new`) — complete.** A separate script
  beside `sbx`. `ls` marks shadowed profiles (so does `sbx --list-profiles`);
  `check` validates every visible profile or one, path shown once per
  profile; `new` writes a template that grants nothing or a `--from` copy,
  validates first, never overwrites (noclobber), never writes the global
  directory, refuses a symlinked `./.sbx` for `--local`, and refuses to copy
  a project profile that sets restricted fields.
- **Phase 5 — designed in the spec, not started, no plan file yet.**

Suite: 344/344 at the end of Phase 4; `shellcheck -S error sbx sbx-profile lib/*.sh`
silent. Before starting anything:

    git status && git log --oneline -3
    bats tests/snapshot.bats        # must pass WITHOUT SBX_UPDATE_SNAPSHOTS
    bats tests/                     # 344/344

Never regenerate the snapshot goldens to make a diff go away.

## User decisions to respect

- **Project-profile trust stays as it is.** An untracked `./.sbx` profile is
  trusted without a prompt; a git-tracked one prompts. The user chose this
  knowing that code inside a sandbox with `fs/sandbox` (launch dir mounted
  rw) can write an untracked profile that the next launch uses without
  asking. Do not change it without asking.
- **No git hardening.** The user declined hardening `sbx`'s `git` calls
  against a launch directory's `.git/config` (e.g. `core.fsmonitor`). Both
  of these are documented in the README threat model under "What it does
  not protect against"; keep that section accurate if either changes.
- **Profiles load by NAME ONLY** from `./.sbx/profiles`,
  `~/.config/sbx/profiles` and the global `profiles/` directory. The launch
  directory is never searched and `--fs/--net/--cli` no longer accept file
  paths (the user's decision, 2026-09-19). `sbx-profile check <path>` still
  validates any file, because it loads nothing.

## How this work has been run

Superpowers skills, per phase: `brainstorming` (design is already in the
spec for phases 4-5) → `writing-plans` → `subagent-driven-development` (a
fresh subagent per task, a review after each, a whole-branch review on
opus, one fix wave, one scoped re-review) → `finishing-a-development-branch`.
The user picks option 1 (subagent-driven). Reviews caught real defects in
every phase, several of them in the plans themselves.

Practical notes that mattered:
- Subagents hit session rate limits several times and died mid-task. Check
  `git status` and `git log` before redoing work, and verify it yourself.
- Haiku implementers write their own model into the commit trailer; fix it
  with `git commit --amend` before review. Use sonnet for anything touching
  `sbx`, sonnet for task reviews, opus for the final whole-branch review.
- A reviewer once started real launches by passing an argument string as one
  word in zsh. Any manual `sbx` run must use `--dry-run` (or be read-only)
  under a throwaway `HOME=$(mktemp -d /tmp/sbxh.XXXXXX)/h`, with arguments as
  separate words. Unknown `--options` are now rejected, which removes most of
  that risk, but a mistyped non-dash word still starts a payload.
- A commit hook rejects the user's login name in tracked files; use `~/…`.

## What comes next, in order

1. **Phase 5 (`--learn-net`)** — needs a feasibility spike FIRST: whether nft
   can add `ip daddr . dport` to a dynamic set from the output hook inside
   pasta's network namespace. The Phase 3 reviewer suggested a plan field
   (e.g. `plan.learn`) so `sbx_state_writes` adds the learn row and the
   render shows an OPEN network marker from the plan. Phase 5 also owns
   `sbx-profile new --from-learn <dir|latest>` (moved out of Phase 4): add
   it as a third content source in `cmd_new` feeding the same
   validate-then-noclobber path, mutually exclusive with `--from`, net only;
   resolve `latest`/`<dir>` only under sbx's state directory; and treat
   `suggested.json` as adversarial (show every `allow`/`ports` entry before
   writing, cap list sizes). The user's own profiles still need attention:
   `~/.config/sbx/profiles/cli/pi.json` uses the removed `"perm": "copy"` and
   `fs/media.json` is invalid JSON (`sbx-profile check` shows both).

## Deferred items (triaged "fine to defer" by the final reviews)

- `sbx_state_writes` re-implements per-perm launch rules (skip absent forked,
  create absent rw, dev only if present, record always) rather than sharing
  predicates with the launch loops; cross-reference comments mark both sides.
- An absent `record` source still binds an empty writable working copy at
  launch (the report now says so); making the launch skip it would be a
  deliberate behavior change with a snapshot update.
- Dry-run output: paths inside `detail` text are not `~`-abbreviated; the
  Network section does not show per-domain upstream resolvers; mount paths
  are shown `$VAR`-expanded.
- `FORKED_MOUNTS` / `RECORD_MOUNTS` join fields with a tab internally
  (validation rejects control characters in mount paths, closing it in
  practice); a newline in an `allow` hostname splits in `lib/net-merge.sh`
  (validation rejects it); `sbx_deps_json_list` does no JSON escaping (inputs
  are fixed table literals).
- A launch that fails during argument parsing, and plain `--help`, no longer
  create the state directory (ruled harmless).
- `sbx_profile_list` strips only C0/DEL from names (not C1/bidi like the
  render's `clean`); `--from` a non-object JSON value says "not valid JSON";
  the restricted-field list lives in two places, pinned equal by a test.

## Open items that need another machine

- **Ubuntu 24.04:** the AppArmor diagnosis and the profile text sbx prints
  are unverified here; also whether pasta needs its own `userns` allowance.
- **Fedora package names** (`gettext-envsubst`, `util-linux-core`,
  `shadow-utils`, `iproute`) should be confirmed with `dnf provides`.
