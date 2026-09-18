# Continue: sbx setup-UX work (paste this into a new session)

We are partway through a five-phase "setup UX" effort on the `setup-ux`
branch of this repository (`~/git/sandbox-gemini`). Everything below is the
state as of 2026-09-18.

## Read these first

- Spec (all five phases): `docs/superpowers/specs/2026-09-16-setup-ux-design.md`
- Phase 1 plan (done): `docs/superpowers/plans/2026-09-16-setup-ux-phase1-deps.md`
- Phase 2 plan (done): `docs/superpowers/plans/2026-09-17-setup-ux-phase2-resolve.md`

## Where the work stands

**Branch `setup-ux`, ahead of `main`, nothing merged.** After each phase the
user has chosen to keep the branch as-is rather than merge or open a PR.

- **Phase 1 (dependencies) — complete.** `lib/deps.sh` (dependency table,
  distro detection, a real bwrap user-namespace probe with cause diagnosis,
  subuid check), a launch preflight that stops before building anything, and
  `sbx --doctor [--json]`.
- **Phase 2 (resolve step and validation) — complete.** `lib/profiles.sh`,
  `lib/profile-check.sh`, `lib/net-merge.sh`, `lib/resolve.sh`; `sbx` now
  hydrates its launch variables from one JSON plan instead of re-reading
  profile files. `tests/snapshot.bats` holds golden files of everything a
  launch generates, captured before the refactor; they pass unregenerated.
  Full suite 239/239, `shellcheck -S error sbx lib/*.sh` silent.
- **Phases 3, 4, 5 — designed in the spec, not started, no plan files yet.**

Before starting anything, confirm the tree is clean and the suite is green:

    git status && git log --oneline -3
    bats tests/snapshot.bats        # must pass WITHOUT SBX_UPDATE_SNAPSHOTS
    bats tests/                     # 239/239 at the end of Phase 2

Never regenerate the snapshot goldens to make a diff go away: a golden diff
means generated launch output changed. Regenerate only after an intentional
change, and review the golden diff like code.

## How this work has been run

Superpowers skills, per phase: `brainstorming` → `writing-plans` →
`subagent-driven-development` (a fresh subagent per task, a review after each,
then a whole-branch review on opus, one fix wave, one scoped re-review), then
`finishing-a-development-branch`. The user picks option 1 (subagent-driven)
when asked. Keep using it: reviews caught real defects in every phase,
including security issues the plans themselves introduced.

Practical notes that mattered:
- Subagents hit session rate limits several times and died mid-task, once with
  work committed and once with it only in the tree. Check `git status` and
  `git log` before assuming a task needs redoing, and verify the work yourself.
- Specify a model on every Agent call: haiku for pure transcription, sonnet
  for implementation and task reviews, opus for the final whole-branch review.
- A commit hook rejects the user's login name in tracked files; use `~/…`
  paths in docs.

## What comes next, in order

1. **Phase 3 (`sbx --dry-run`)** — write the plan first. It prints the plan
   the resolve step already builds, and adds `plan.writes` (every host
   location a session writes: forked stores, record working copies and
   archives, rw binds, podman/qemu stores, session dirs). The spec's Phase 3
   section has the output format and the writes table. The Phase 2 reviewers
   asked for these to be folded into Phase 3:
   - collapse `sbx`'s `${#NET_PROFILES[@]}` branches onto `plan.netns` /
     `plan.net.enabled`;
   - consider splitting the ~250-line `sbx_resolve` into helpers before it
     grows;
   - `--dry-run` must print "would prompt" from `plan.confirm`, which the
     launch now also consumes (single source of truth — keep it that way);
   - print profile-authored text through `sbx_sanitize_message` (control
     characters stripped), as the launch's warning loop does.
2. **Phase 4 (`sbx-profile new|check|ls`)** — the user's own profiles are the
   motivating case: `~/.config/sbx/profiles/cli/pi.json` still uses the
   removed `"perm": "copy"` and `fs/media.json` is not valid JSON, so both
   already fail to launch. There is no automated profile-JSON migration, and
   the user was told why: `copy` split into `forked` (sandbox owns the data)
   and `record` (host owns it), and choosing one is intent, not mechanics. The
   recommendation given was that `sbx-profile check` covers this. The user was
   also offered a direct fix of those two files and has not answered.
3. **Phase 5 (`--learn-net`)** — needs a feasibility spike FIRST: whether nft
   can add `ip daddr . dport` to a dynamic set from the output hook inside
   pasta's network namespace. If it cannot, learning mode sees DNS lookups
   only, not ports or raw-IP attempts, and the spec's design needs revisiting.

## Deferred items (triaged "fine to defer" by the final reviews)

- `FORKED_MOUNTS` / `RECORD_MOUNTS` still join fields with a literal tab
  internally in `sbx`. Validation now rejects control characters in mount
  source/dest, which closes it in practice.
- A newline inside an `allow` hostname splits into two domains in
  `lib/net-merge.sh`'s read loop — identical to the pre-refactor code, and
  validation rejects such hostnames.
- The fail-closed default branch for an unknown mount perm in `sbx`'s
  hydration loop has no test: validation makes it unreachable from the CLI,
  and testing it would need the loop extracted into a function.
- `prompt_project_profile` re-reads the profile file to display it, after
  resolve validated an earlier read (narrow local TOCTOU).
- An empty `tests/snapshots/host-ports/dns_resolv.conf` golden is expected:
  host-ports-only sessions write an empty resolv.conf.

## Open items that need another machine

- **Ubuntu 24.04:** the AppArmor diagnosis and the profile text sbx prints
  cannot be exercised on this Manjaro host. Also unverified: whether pasta
  (not bwrap) needs its own `userns` allowance for `--net` sessions — sbx
  prints a caveat line instead of claiming to fix it.
- **Fedora package names** (`gettext-envsubst`, `util-linux-core`,
  `shadow-utils`, `iproute`) should be confirmed with `dnf provides`.
