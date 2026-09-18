# Continue: sbx setup-UX work (paste this into a new session)

We are partway through a five-phase "setup UX" effort on the `setup-ux`
branch of this repository (`~/git/sandbox-gemini`). Everything below is the
state as of 2026-09-18.

## Read these first

- Spec (all five phases): `docs/superpowers/specs/2026-09-16-setup-ux-design.md`
- Phase 1 plan (done): `docs/superpowers/plans/2026-09-16-setup-ux-phase1-deps.md`
- Phase 2 plan (nearly done): `docs/superpowers/plans/2026-09-17-setup-ux-phase2-resolve.md`
- Phase 2 execution ledger, with every ruling made along the way:
  `.superpowers/sdd/2026-09-17-setup-ux-phase2-resolve/progress.md` (git-ignored)
- Outstanding fix list for Phase 2:
  `.superpowers/sdd/2026-09-17-setup-ux-phase2-resolve/final-findings.md`

## Where the work stands

**Branch `setup-ux`, 12 commits ahead of `main`, nothing merged.** The user
chose to keep it unmerged after Phase 1 and has not revisited that.

- **Phase 1 (dependencies) — complete.** `lib/deps.sh` (dependency table,
  distro detection, a real bwrap user-namespace probe with cause diagnosis,
  subuid check), a launch preflight that stops before building anything, and
  `sbx --doctor [--json]`.
- **Phase 2 (resolve step and validation) — code complete, fixes in flight.**
  `lib/profiles.sh`, `lib/profile-check.sh`, `lib/net-merge.sh`,
  `lib/resolve.sh`, and `sbx` now hydrates its launch variables from one JSON
  plan instead of re-reading profile files. `tests/snapshot.bats` holds golden
  files of everything a launch generates, captured before the refactor; they
  pass unregenerated, which is the evidence the refactor changed nothing.
- **Phases 3, 4, 5 — designed in the spec, not started, no plan files yet.**

### FIRST THING TO CHECK

A fix-wave subagent was applying the final review's findings when the session
ended. **The working tree may hold uncommitted changes** to `sbx`,
`README.md`, `lib/profiles.sh`, `lib/profile-check.sh`, `tests/profiles.bats`,
`tests/profile-check.bats`, `tests/resolve.bats`, `tests/project-profiles.bats`.

Run `git status` and `git log --oneline -3`. If the work is uncommitted,
verify it yourself rather than trusting it:

    bats tests/snapshot.bats        # must pass WITHOUT SBX_UPDATE_SNAPSHOTS
    bats tests/                     # was 233/233 before the fix wave
    shellcheck -S error sbx lib/*.sh

Then check each finding in `final-findings.md` is actually addressed, and
commit. If the changes look partial or wrong, `git checkout` them and re-run
the fix wave from `final-findings.md`. Never regenerate the snapshot goldens
to make a diff go away: a golden diff means generated output changed.

### The findings that fix wave was applying

- **F1 (Important, security):** warnings quote profile-authored text and print
  *before* the project-profile trust prompt; a crafted `workingDirectory` can
  carry terminal escape sequences that repaint the lines above that prompt.
  Fix: buffer warnings until after the confirm loop, and strip control
  characters when printing.
- **F2 (Important, security, pre-existing):** a project profile that is a
  symlink pointing outside the repo classifies as `path`, not `project`, so
  `caps`/`userns`/`docker_api` are honored with no prompt. Fix: treat a path
  lexically under `./.sbx/` as `project` too.
- **F3 (Important):** the trust decision is computed twice (`plan.confirm` and
  `confirm_project_profile`); the launch uses only one. Fix: drive the loop
  from `plan.confirm`.
- **M1:** reject control characters in env names/values, mount source/dest and
  `allow` entries in `lib/profile-check.sh`.
- **M2:** the mount hydration `case` needs a default branch that fails closed
  on an unknown perm.
- **M3:** one README sentence — a project profile with `"docker_api": false`
  is now an error (validation checks presence, not value).

## How this work has been run

Superpowers skills, in this order per phase: `brainstorming` → `writing-plans`
→ `subagent-driven-development` (a fresh subagent per task, a review after
each, then a whole-branch review by an opus reviewer, one fix wave, one scoped
re-review). The user picks option 1 (subagent-driven) when asked. Keep using
it — the per-task reviews have caught real defects every phase, including two
security issues the plans themselves introduced.

Practical notes that mattered:
- Subagents hit session rate limits twice and died mid-task, once with work
  committed and once with it only in the tree. Check `git status` and `git log`
  before assuming a task needs redoing.
- Specify a model on every Agent call: haiku for mechanical transcription,
  sonnet for implementation and reviews, opus for the final whole-branch review.
- Commit message trailer used throughout:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` plus the session URL.

## What comes next, in order

1. **Finish Phase 2:** verify/commit the fix wave, dispatch one scoped
   re-review of the fix diff, then ask the user how to finish the branch
   (merge / PR / keep as-is — they chose "keep as-is" last time).
2. **Phase 3 (`--dry-run`)**: write the plan first. It prints the plan the
   resolve step already builds, and adds `plan.writes` (every host location a
   session writes: forked stores, record working copies and archives, rw
   binds, podman/qemu stores, session dirs). The spec's Phase 3 section has
   the output format and the writes table. Deferred items the reviewer asked
   to fold in here: collapse `sbx`'s eight `${#NET_PROFILES[@]}` branches onto
   `plan.netns`/`plan.net.enabled`, and consider splitting the ~250-line
   `sbx_resolve` into helpers before it grows.
3. **Phase 4 (`sbx-profile new|check|ls`)**: the user's own profiles are the
   motivating case — `~/.config/sbx/profiles/cli/pi.json` still uses the
   removed `"perm": "copy"` and `fs/media.json` is not valid JSON, so both
   already fail to launch. There is no automated profile-JSON migration and
   the user was told why: `copy` split into `forked` (sandbox owns the data)
   and `record` (host owns it), and picking one is intent, not mechanics.
   They were offered a direct fix of those two files and have not answered.
4. **Phase 5 (`--learn-net`)**: needs a feasibility spike FIRST — whether nft
   can add `ip daddr . dport` to a dynamic set from the output hook inside
   pasta's network namespace. If it cannot, learning mode sees DNS lookups
   only, not ports or raw-IP attempts, and the spec's design needs revisiting.

## Open items neither phase could close here

- **Ubuntu 24.04 check:** the AppArmor diagnosis and the profile text sbx
  prints cannot be exercised on this Manjaro host. Also unverified: whether
  pasta (not bwrap) needs its own `userns` allowance for `--net` sessions —
  sbx currently prints a caveat line instead of claiming to fix it.
- **Fedora package names** (`gettext-envsubst`, `util-linux-core`,
  `shadow-utils`, `iproute`) should be confirmed with `dnf provides`.
- Deferred minors are listed in the Phase 2 ledger; the final review triaged
  all of them as fine to defer.
