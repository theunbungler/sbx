# Continue: sbx setup-UX work (paste this into a new session)

We are partway through a five-phase "setup UX" effort on the `setup-ux`
branch of this repository (`~/git/sandbox-gemini`). Everything below is the
state as of 2026-09-19.

## Read these first

- Spec (all five phases): `docs/superpowers/specs/2026-09-16-setup-ux-design.md`
- Phase 1 plan (done): `docs/superpowers/plans/2026-09-16-setup-ux-phase1-deps.md`
- Phase 2 plan (done): `docs/superpowers/plans/2026-09-17-setup-ux-phase2-resolve.md`
- Phase 3 plan (done): `docs/superpowers/plans/2026-09-18-setup-ux-phase3-dry-run.md`

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
- **Phases 4, 5 — designed in the spec, not started, no plan files yet.**

Suite: 302/302 at the end of Phase 3; `shellcheck -S error sbx lib/*.sh`
silent. Before starting anything:

    git status && git log --oneline -3
    bats tests/snapshot.bats        # must pass WITHOUT SBX_UPDATE_SNAPSHOTS
    bats tests/                     # 302/302

Never regenerate the snapshot goldens to make a diff go away.

## User decisions to respect

- **Project-profile trust stays as it is.** An untracked `./.sbx` profile is
  trusted without a prompt; a git-tracked one prompts. The user chose this
  knowing that code inside a sandbox with `fs/sandbox` (launch dir mounted
  rw) can write an untracked profile that the next launch uses without
  asking. Do not change it without asking. Note: the README threat model
  still says "Project-supplied profiles require confirmation", which is only
  true for tracked ones — the user has not yet said whether to reword it.
- **OPEN, needs the user's answer:** `sbx` runs `git ls-files` (and `git
  remote` in the prompt) in the launch directory, so a `.git/config` with
  `core.fsmonitor` runs a command on the host during a launch or dry run.
  Hardening (`git -c core.fsmonitor=false -c core.hooksPath=/dev/null`,
  `GIT_CONFIG_NOSYSTEM=1`) would not change who is trusted. The user's
  "keep as is" answer did not clearly cover this; it has been left untouched.

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

1. **Get the user's answer on the git `fsmonitor` hardening** (above).
2. **Phase 4 (`sbx-profile new|check|ls`)** — write the plan first. The spec
   section covers it; its "next step" line should suggest
   `sbx --dry-run --<type> <name>`. The dry-run orchestration currently lives
   inline in `sbx`'s `--- Dry run ---` block; the Phase 3 reviewer suggested
   moving it into a library function (e.g. `sbx_dry_run_doc <plan>
   <state_dir> <launch_dir>` returning the document with `.proceed`) so
   `sbx-profile` can reuse it. The user's own profiles still need attention:
   `~/.config/sbx/profiles/cli/pi.json` uses the removed `"perm": "copy"` and
   `fs/media.json` is invalid JSON; the user was offered a direct fix and has
   not answered.
3. **Phase 5 (`--learn-net`)** — needs a feasibility spike FIRST: whether nft
   can add `ip daddr . dport` to a dynamic set from the output hook inside
   pasta's network namespace. The Phase 3 reviewer suggested a plan field
   (e.g. `plan.learn`) so `sbx_state_writes` adds the learn row and the
   render shows an OPEN network marker from the plan.

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

## Open items that need another machine

- **Ubuntu 24.04:** the AppArmor diagnosis and the profile text sbx prints
  are unverified here; also whether pasta needs its own `userns` allowance.
- **Fedora package names** (`gettext-envsubst`, `util-linux-core`,
  `shadow-utils`, `iproute`) should be confirmed with `dnf provides`.
