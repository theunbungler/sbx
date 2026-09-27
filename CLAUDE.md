# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`sbx` is an unprivileged sandbox orchestrator (bwrap + nftables/dnsmasq/pasta/socat, no compiled code — bash + jq + the tool names above only) that launches isolated sessions for AI coding agents, composed from modular FS and NET profiles. The threat model treats both the sandboxed code *and* the launch directory as adversarial; changes here are security-relevant by default (see README's "Threat model" and "Caveats and Explicit Non-goals" sections before altering mount, cap, or egress logic).

## Commands

- Test everything: `bats -j 4 tests/` (~400+ tests, several minutes; many suites launch real sandboxes).
- Test one suite/file: `bats tests/<name>.bats`; one test: `bats tests/<name>.bats -f '<test name substring>'`.
- Lint gate (required for any change touching `sbx`, `sbx-profile`, or `lib/`): `shellcheck -x -S error sbx sbx-profile lib/*.sh tests/helpers/*.sh` must be silent. A few pre-existing info-level findings are not gating.
- Regenerate snapshot goldens after an *intended* behavior change: `SBX_UPDATE_SNAPSHOTS=1 bats tests/snapshot.bats`, then review the diff by hand. Never regenerate to make a diff disappear — a snapshot mismatch from a refactor that was supposed to be behavior-preserving is a bug, not a golden to update.
- Check host setup / dependencies: `./sbx --doctor [--json]`.
- Preview a launch without side effects: `./sbx --dry-run [--json] [flags...]`.

### Test environment requirements

- End-to-end tests fake `$HOME` but it must be a **short** path — the session's `tmux.sock` lives at `$SESSION_DIR/tmux.sock` and must stay under the ~108-byte Unix socket path limit. Use `mktemp -d /tmp/sbxh.XXXXXX`, not `$BATS_TEST_TMPDIR` (too long).
- sbx needs a pty for e2e launches; drive it with `script -qec "<cmd>" /dev/null`.
- `! cmd` in a bats `@test` is a no-op except on the last line (`set -e` ignores inverted commands elsewhere). Use `if grep -q bad "$f"; then echo "leaked" >&2; return 1; fi` instead.
- Suites whose fixtures live under `./.sbx/profiles` must `export SBX_TRUST_PROJECT_PROFILES=1` in `setup()`, or every launch blocks on the project-profile confirmation prompt.

## Architecture

### Control namespace (A) vs. payload namespace (B)

Every session runs two nested user namespaces, and almost every design decision in `lib/` follows from this split:

- **A** — the control namespace. `unshare --map-auto --map-root-user -- pasta ...` (or `unshare` alone for no-net sessions) creates it; `lib/launch.sh` runs here, outliving bwrap so its `EXIT` trap can release B, the relays, and dnsmasq. bwrap itself runs in A, so **every mount bwrap makes belongs to A**. A also owns the nftables ruleset and the veth's A-side address — the payload cannot see or modify either.
- **B** — the payload namespace, nested inside A (`lib/userns.sh`). The actual command execs here. Because B is a *descendant* namespace, mounts inherited from A across that boundary are `MNT_LOCKED`: B cannot remount or unmount them regardless of capabilities held. B owns its own network namespace, reached from A via a veth pair, which is why podman/netavark bridge networking and container-to-container DNS work even in `caps: keep` sessions without weakening the `ro`/firewall guarantees.

This split is why `podman`/`podman-full` plumbing (`setup_virt` in `sbx`) is set up in *every* session regardless of fs profile — it keeps network profile behavior uniform whether or not virt is actually used; the fs profile alone gates device access (`/dev/kvm`, `/dev/net/tun`).

### `sbx` itself: subcommands, then launch phases, then main

`sbx` (the single executable) is: helper functions → subcommand functions (`cmd_doctor`, `cmd_gc`, `cmd_list_sessions`, `cmd_changes`, `cmd_join`, `cmd_attach`) → the launch as an ordered sequence of phases → `main`. The launch phase order matters and mirrors what bwrap needs:

1. `preflight_core` — checks only the tools sbx itself calls before it can even report a dry run.
2. `resolve_plan` (delegates to `lib/resolve.sh`) — turns flags + profiles into one JSON **plan**, touching *nothing* on disk (no dir created, no session claimed, no profile seeded). Everything downstream reads the plan, never a profile directly, so `--dry-run` and the real launch cannot disagree.
3. `dry_run_report` / `check_plan` — renders the plan, or gates on `plan.confirm` (untracked-vs-tracked project profiles) and `plan.errors`/`plan.warnings`. Errors block prompts; prompts happen before warnings, so profile-authored warning text can never crowd out a trust prompt.
4. `preflight_session` — the dependency/host checks the plan's shape actually needs, plus the socket-path-length check, all before any session name is claimed.
5. `claim_session` — a two-step mkdir-then-pid-record claim under a claim lock, so a live session always has a liveness record (see `lib/sessions.sh`).
6. `build_base_args`, `setup_virt`, `add_profile_mounts`, `mask_project_sbx`, `seed_forked_mounts`/record-mount seeding — build the bwrap argument list and seed persistent/ephemeral state.
7. Exec into `lib/launch.sh`, which runs in A and hands off to `lib/session.sh` (PID 1 inside the sandbox) and `lib/wrapper.sh` (the actual payload, which drops the capability bounding set before exec unless `caps: keep`).

### `lib/*.sh` — pure functions, sourced by both `sbx` and tests

Every file under `lib/` is side-effect-free at source time and has no dependency on `sbx`'s globals — directories/plans/session dirs are always passed as arguments. This is what lets `tests/*.bats` source them directly and unit-test logic (mount seeding, plan resolution, profile validation, net-profile merging) without spinning up a real sandbox. Key modules:

- `lib/resolve.sh` — flags + profiles → JSON plan (the single source of truth downstream).
- `lib/profiles.sh` / `lib/profile-check.sh` — profile lookup (project → user → global precedence) and schema validation. Project profiles are restricted from setting `caps`, `userns`, `docker_api`, `host_ports` (`SBX_PROFILE_RESTRICTED`), and unknown fields are hard errors, not ignored.
- `lib/net-merge.sh` — composes multiple `--net` profiles by pairing each destination with *only* the port list of the profile that granted it, never a union across profiles.
- `lib/egress.sh` / `lib/nestnet.sh` — dnsmasq config and the nftables ruleset in A, and the A↔B veth wiring, host-port relay (socat), and DNS setup.
- `lib/copy-mounts.sh` / `lib/state-paths.sh` — seeding and manifest-diffing shared by `forked` (persistent, sandbox-owned) and `record` (ephemeral, host-owned, diffed-at-teardown) mount permissions; see "Forked and Record Mounts" in the README for the semantics.
- `lib/sessions.sh` — host-side session bookkeeping. Liveness is derived **only** from `join/<name>.pid`, never `session.json` (which is bound rw into the sandbox and so is payload-forgeable); `join/` is masked inside the sandbox.
- `lib/deps.sh` — the dependency table and host checks shared by preflight and `--doctor`.
- `lib/render.sh` — output formatting, including the ASCII/length sanitizer applied to any profile-authored string before it reaches the terminal (mount sources, warnings) — untrusted text must never be able to repaint or crowd out a trust prompt.

### Profiles

Two categories, each a JSON file resolved by name (never a path) with project → user → global precedence:

- `profiles/fs/*.json` — mounts, `env`, `path`, `passthrough`, `gui`, and `caps`/`userns`/`docker_api` (e.g. `claude`, `gemini`, `pi`, `dev`, `sandbox`, `podman`). Stack as many as you like; later profiles win on env and put their `path` entries first. `--cli <name>` is a compatibility alias that applies an fs profile after every `--fs` one. A leftover `cli/` directory is never read; sbx warns about it.
- `profiles/net/*.json` — egress allow-lists (`web`, `anthropic`, `gemini`), each a set of domains/IPs and ports.

A **workspace** (`./.sbx/<name>.json`, else `~/.config/sbx/<name>.json`; most local wins) is only `{fs, net, wd, gui}`: flags written down, expanded by `expand_workspace` in `sbx` where `--workspace` appears. It grants nothing itself; a git-tracked project workspace is confirmed like a tracked project profile.

Mount `perm` is one of `ro`, `rw`, `dev`, `forked`, `record` (`lib/profile-check.sh`). `forked` (persistent, sandbox-owned, keyed by profile name + launch dir) and `record` (ephemeral, host-owned, diffed at teardown) are the two isolating perms; see "Forked and Record Mounts" in the README.

Multiple profiles of the same category stack (e.g. two `--fs` profiles); see README "Stacking Network Profiles" for the port-pairing rule that keeps stacked grants minimal rather than unioned.

### Security-sensitive invariants worth knowing before touching related code

- `./.sbx` (the directory that configures the *next* launch from this directory) is never visible inside any session — masked with an empty tmpfs over every writable mount that would expose it, so a payload can never plant a profile for a future launch to trust.
- `ro` mounts are enforced by the A/B namespace nesting itself (see above), not by a flag a payload could later disable.
- Untracked project profiles under `./.sbx/profiles` are trusted without a prompt (treated as the user's own scratch config); git-tracked ones require confirmation (or `SBX_TRUST_PROJECT_PROFILES=1`). This is a deliberate, documented trust boundary — don't "fix" it without checking the README threat model first.
- Sessions with `"caps": "keep"` (`fs/podman`, `fs/podman-full`) hold capabilities *inside B's own namespace* — enough to create further namespaces and over-mount paths on themselves, but never enough to write a `ro` mount or touch A's firewall.

## Docs conventions

- `docs/superpowers/specs/` holds design docs for major features (dated, `<feature>-design.md`); `docs/superpowers/archive/plans/` holds executed implementation plans, archived after landing. Check these before re-deriving the rationale behind an existing subsystem (e.g. the nested-userns networking design, persistent CLI profiles and the later cli→fs merge, setup-UX phases) — several non-obvious tradeoffs are recorded there rather than in code comments.
