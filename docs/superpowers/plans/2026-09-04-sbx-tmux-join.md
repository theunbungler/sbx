# Non-mirroring `--join` via tmux — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `sbx --join <session>` open a fresh shell *inside* a running sandbox — its own PTY, in the sandbox's namespaces, under the same capability drop — instead of mirroring the payload's terminal.

**Architecture:** Replace `abduco`/`dtach` with a tmux server running *inside* the sandbox, its socket at `$SESSION_DIR/tmux.sock`. `sbx` already binds `$SESSION_DIR` at the same path on both sides (`sbx:1275`), so a host-side tmux client reaches that in-sandbox server with no new mount. `--join` becomes `new-session` (independent PTY, forked by a process already inside the namespaces and already under `setpriv`); `--attach` becomes `attach -t main`. A generated `session.sh` runs as PID 1 inside bwrap and outlives the payload so the session ends only when the last tmux session does.

**Tech Stack:** bash, bubblewrap, tmux 3.x, bats 1.14, shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-04-sbx-tmux-join-design.md`

## Global Constraints

- **Stock tools only.** No compiled artifacts, no bespoke daemons (`docs/superpowers/plans/2026-08-01-sbx-hardening.md:13`). `tmux` replaces `abduco`/`dtach`; nothing else is added.
- **`sbx` stays a single shipped script.** `session.sh` and `tmux.conf` are *generated* into `$SESSION_DIR` at launch, exactly like `launch.sh` and `wrapper.sh` already are.
- **Unix socket paths are capped at ~108 chars (`sun_path`).** Test `$HOME` must stay short — `mktemp -d /tmp/sbxh.XXXXXX`, never `$BATS_TEST_TMPDIR`.
- **`sbx` runs under `set -e`** (`sbx:5`). Generated scripts do not inherit it; commands whose failure is expected must end in `|| true`.
- **shellcheck baseline is 5 pre-existing findings** (SC2295 at `sbx:83`, SC2031 at `:537`, SC1010 at `:585`, SC2034 at `:1263`, SC2016 at `:1344`). Do not fix them here; do not add new ones.
- **Verification for every task:** `shellcheck sbx lib/copy-mounts.sh` (no new findings) and `bats tests/` (all pass).
- **`require_tools` is defined at `sbx:344`, *after* the argument-parsing loop at `sbx:170-270`.** Anything the parse loop needs must be an inline `command -v` check, not a `require_tools` call.

---

### Task 1: Swap the launch path from abduco/dtach to tmux

**Files:**
- Modify: `sbx:24-36` (delete `SESSION_MUX` + `find_session_mux`)
- Modify: `sbx:335-337` (delete the `find_session_mux` call and its comment)
- Modify: `sbx:364` (`require_tools bwrap jq envsubst setpriv` → add `tmux`)
- Modify: `sbx:355-361` (install-hint `case` — add a `tmux` line)
- Modify: `sbx:1305` (teardown cleanup list)
- Modify: `sbx:1317-1320` (path variables)
- Modify: `sbx:1506` (launch.sh's final bwrap line)
- Modify: `tests/hardening.bats:5-8,35-36` and `tests/persistent-cli.bats:40-41` (comments naming abduco)

**Interfaces:**
- Consumes: nothing.
- Produces: `$SESSION_DIR/tmux.sock` (server socket, host-reachable), `$SESSION_DIR/tmux.conf`, `$SESSION_DIR/session.sh`. Shell variables `TMUX_SOCK`, `TMUX_CONF`, `SESSION_SCRIPT`. Tasks 2–5 all address the sandbox through `$SDIR/tmux.sock`.

- [ ] **Step 1: Confirm the existing suite passes before touching anything**

Run: `bats tests/` — Expected: all pass. This is the baseline; if anything already fails, stop and report rather than absorbing it into this change.

- [ ] **Step 2: Delete the multiplexer discovery function**

Delete `sbx:24-36` entirely — the `SESSION_MUX=""` line and the whole `find_session_mux()` function.

Then delete its call site and comment at `sbx:335-337`:

```bash
# Resolved here, not at launch-script generation time, so a host missing
# both multiplexers fails before any session state or xpra display exists.
find_session_mux
```

- [ ] **Step 3: Require tmux instead**

At `sbx:364`, change:

```bash
require_tools bwrap jq envsubst setpriv
```

to:

```bash
require_tools bwrap tmux jq envsubst setpriv
```

And add a hint line to the `case` at `sbx:355-361`, matching the existing column alignment:

```bash
            tmux)     echo "  tmux     — Debian/Ubuntu: apt install tmux        Arch: pacman -S tmux" >&2 ;;
```

- [ ] **Step 4: Rename the socket variable and add the two new paths**

At `sbx:1317-1320`, replace:

```bash
SESSION_SOCK="$SESSION_DIR/session.sock"
LAUNCH_SCRIPT="$SESSION_DIR/launch.sh"
CAT_WRAPPER="$SESSION_DIR/wrapper.sh"
```

with:

```bash
TMUX_SOCK="$SESSION_DIR/tmux.sock"
TMUX_CONF="$SESSION_DIR/tmux.conf"
SESSION_SCRIPT="$SESSION_DIR/session.sh"
LAUNCH_SCRIPT="$SESSION_DIR/launch.sh"
CAT_WRAPPER="$SESSION_DIR/wrapper.sh"
```

- [ ] **Step 5: Generate the tmux config**

Immediately after the `chmod +x "$CAT_WRAPPER"` line (`sbx:1482`), add:

```bash
# Per-session tmux config. The -f that loads this is not cosmetic: the
# sandbox usually has $HOME mounted, so without it the server would read
# the user's ~/.tmux.conf and session behaviour would depend on host
# dotfiles. Every setting here is load-bearing:
#   exit-empty     the session-lifetime rule — server exits with its last
#                  session, which is what lets session.sh stop waiting.
#   prefix C-\     a host tmux keeps C-b, so nesting needs no doubled
#                  prefix. C-\ is also abduco's old detach chord.
#   window-size    per-client sizing, so one join cannot resize another.
#   status-left    makes "you are inside a sandbox" visible at a glance.
cat > "$TMUX_CONF" <<EOF
set -g exit-empty on
set -g escape-time 0
set -g window-size latest
unbind C-b
set -g prefix C-\\\\
bind C-\\\\ send-prefix
set -g status on
set -g status-left ' sbx:$SESSION_ID '
set -g status-left-length 40
EOF
```

- [ ] **Step 6: Verify the prefix escaping is actually what tmux parses**

The backslash survives three layers here (bash heredoc → tmux config parser → tmux key parser), so prove it rather than assume:

```bash
printf 'set -g prefix C-\\\\\nset -g exit-empty on\n' > /tmp/sbxc.conf
tmux -f /tmp/sbxc.conf -S /tmp/sbxc.sock new-session -d 'sleep 5'
tmux -S /tmp/sbxc.sock show-options -g prefix
tmux -S /tmp/sbxc.sock kill-server; rm -f /tmp/sbxc.conf
```

Expected: `prefix C-\`. If it prints `prefix C-b` or errors, fix the escaping in Step 5 before continuing — a wrong prefix silently leaves `C-b` colliding with the host tmux.

- [ ] **Step 7: Generate session.sh, the PID-1 orchestrator**

Directly after the config block from Step 5, add:

```bash
# PID 1 inside the sandbox. This script — not the tmux server, and not the
# payload — is what bwrap waits on, and that is the whole implementation of
# the session-lifetime rule: the server daemonizes, so if this exited,
# bwrap's direct child would be gone and the pid namespace would take every
# live session with it, joins included. Instead it hangs around until the
# server is gone, which (with exit-empty on) means the last session — payload
# or join, whichever ends last — has exited. Only then does bwrap return and
# launch.sh proceed to copy-writeback, so a join can never be racing the
# write-back of its own files.
#
# No `set -e`: attach is expected to fail when the payload is short-lived
# enough to have exited before we get here, and that is not an error.
cat > "$SESSION_SCRIPT" <<EOF
#!/bin/bash
tmux -f $(printf '%q' "$TMUX_CONF") -S $(printf '%q' "$TMUX_SOCK") \\
    new-session -d -s main -- $(printf '%q' "$CAT_WRAPPER")
tmux -S $(printf '%q' "$TMUX_SOCK") attach -t main || true
while tmux -S $(printf '%q' "$TMUX_SOCK") list-sessions >/dev/null 2>&1; do
    sleep 0.5
done
EOF
chmod +x "$SESSION_SCRIPT"
```

Note `list-sessions`, not `has-session`: `has-session` needs a target and reports on one named session, while the loop must wait for *any* session — the payload's or a join's.

- [ ] **Step 8: Point bwrap at session.sh**

At `sbx:1506`, replace:

```bash
printf "%q -c %q %q\n" "$SESSION_MUX" "$SESSION_SOCK" "$CAT_WRAPPER" >> "$LAUNCH_SCRIPT"
```

with:

```bash
printf "%q\n" "$SESSION_SCRIPT" >> "$LAUNCH_SCRIPT"
```

- [ ] **Step 9: Update the teardown cleanup list**

At `sbx:1305`, replace:

```bash
    rm -f "$SESSION_DIR/session.sock" "$SESSION_DIR/wrapper.sh"
```

with:

```bash
    rm -f "$SESSION_DIR/tmux.sock" "$SESSION_DIR/tmux.conf" \
          "$SESSION_DIR/session.sh" "$SESSION_DIR/wrapper.sh"
```

- [ ] **Step 10: Reword the test comments that name abduco**

`tests/hardening.bats:5-8` — replace the `setup()` comment with:

```bash
    # NOT $BATS_TEST_TMPDIR — it embeds the test name, and sbx's tmux
    # socket at $HOME/.local/state/sbx/<session-id>/tmux.sock would blow
    # the ~108-char sun_path limit. Keep this path short.
```

`tests/hardening.bats:35-36` and `tests/persistent-cli.bats:40-41` — replace both `run_sbx` comments with:

```bash
# sbx runs its payload under a tmux server inside the sandbox, and a tmux
# client needs a pty; `script -qec` supplies one non-interactively.
```

- [ ] **Step 11: Run the full suite**

Run: `bats tests/`

Expected: all pass. The canary at `tests/hardening.bats:42` (`a sandbox command actually runs`) is the one that matters most here — it proves the payload still executes through the new tmux launch path. If it fails, inspect a live session's generated scripts (`cat ~/.local/state/sbx/*/session.sh`) rather than guessing.

- [ ] **Step 12: Run shellcheck**

Run: `shellcheck sbx lib/copy-mounts.sh`

Expected: the same 5 pre-existing findings listed in Global Constraints, and no others.

- [ ] **Step 13: Commit**

```bash
git add sbx tests/hardening.bats tests/persistent-cli.bats
git commit -m "Run the payload under an in-sandbox tmux server

Replaces abduco/dtach. session.sh becomes bwrap's direct child and PID 1,
holding the namespace open until the tmux server's last session exits, so
a later --join cannot race copy-writeback."
```

---

### Task 2: `--join` opens a fresh shell inside the sandbox

**Files:**
- Modify: `sbx:205-219` (the `--join` branch)
- Modify: `sbx:48` (usage text)
- Modify: `README.md:66` and `README.md:11`
- Test: `tests/join.bats` (create)

**Interfaces:**
- Consumes: `$SDIR/tmux.sock` from Task 1.
- Produces: `sbx --join <session>` → interactive shell; `sbx --join <session> -- <cmd>` → `<cmd>` in a fresh PTY. Test helpers `start_bg_sbx <sbx-args> <payload-sh>` (sets `BG_PID`, `BG_SDIR`, `BG_SESSION`) and `join_sbx <sh-command>`, reused by Tasks 3–5.

- [ ] **Step 1: Write the failing tests**

Create `tests/join.bats`:

```bash
#!/usr/bin/env bats

setup() {
    SBX="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sbx"

    # NOT $BATS_TEST_TMPDIR — it embeds the test name, and sbx's tmux
    # socket at $HOME/.local/state/sbx/<session-id>/tmux.sock would blow
    # the ~108-char sun_path limit. Keep this path short.
    ROOT="$(mktemp -d /tmp/sbxj.XXXXXX)"
    export HOME="$ROOT/h"
    PROJ="$ROOT/p"
    HOSTDIR="$ROOT/o"
    mkdir -p "$HOME" "$PROJ/.sbx/profiles/fs" "$HOSTDIR"
    export SBX_TRUST_PROJECT_PROFILES=1

    cat > "$PROJ/.sbx/profiles/fs/caps.json" <<EOF
{"description":"test","mounts":[{"source":"$HOSTDIR","dest":"/out","perm":"rw"}]}
EOF
}

teardown() {
    # Release any payload still parked on the marker, so a failed
    # assertion cannot leave a sandbox running past the test.
    touch "$HOSTDIR/stop" 2>/dev/null || true
    [[ -n "$BG_PID" ]] && wait "$BG_PID" 2>/dev/null || true
    if [[ -n "$ROOT" && "$ROOT" == /tmp/sbxj.* ]]; then
        rm -rf "$ROOT"
    fi
}

# Launch a sandbox in the background and wait for its tmux socket to
# appear. $1 = sbx args, $2 = payload shell command. A tmux client needs a
# pty, so `script -qec` supplies one.
start_bg_sbx() {
    ( cd "$PROJ" && script -qec "$SBX $1 -- /bin/sh -c '$2'" /dev/null >/dev/null 2>&1 ) &
    BG_PID=$!
    local sock
    for _ in $(seq 100); do
        sock=$(find "$HOME/.local/state/sbx" -maxdepth 2 -name tmux.sock 2>/dev/null | head -n1)
        if [[ -S "$sock" ]]; then
            BG_SDIR=$(dirname "$sock")
            BG_SESSION=$(basename "$BG_SDIR")
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# Run a command in a fresh join and wait for it to finish.
join_sbx() {
    ( cd "$PROJ" && script -qec "$SBX --join $BG_SESSION -- /bin/sh -c '$1'" /dev/null >/dev/null 2>&1 )
}

# A payload that parks until the test releases it.
PARK='while [ ! -f /out/stop ]; do sleep 0.2; done'

@test "a join runs inside the payload's namespaces" {
    start_bg_sbx "--fs caps" "readlink /proc/self/ns/pid > /out/payload.ns; $PARK"
    join_sbx "readlink /proc/self/ns/pid > /out/join.ns"
    [ -s "$HOSTDIR/join.ns" ]
    [ "$(cat "$HOSTDIR/join.ns")" = "$(cat "$HOSTDIR/payload.ns")" ]
    [ "$(cat "$HOSTDIR/join.ns")" != "$(readlink /proc/self/ns/pid)" ]
}

@test "a join sees the sandbox mount namespace, not the host's" {
    start_bg_sbx "--fs caps" "$PARK"
    join_sbx "readlink /proc/self/ns/mnt > /out/join.mnt"
    [ -s "$HOSTDIR/join.mnt" ]
    [ "$(cat "$HOSTDIR/join.mnt")" != "$(readlink /proc/self/ns/mnt)" ]
}

@test "a join has an empty capability bounding set" {
    start_bg_sbx "--fs caps" "$PARK"
    join_sbx "grep ^CapBnd /proc/self/status > /out/join.caps"
    [[ "$(cat "$HOSTDIR/join.caps")" == *"0000000000000000"* ]]
}

@test "a join gets its own pty, separate from the payload's" {
    start_bg_sbx "--fs caps" "tty > /out/payload.tty; $PARK"
    join_sbx "tty > /out/join.tty"
    [ -s "$HOSTDIR/join.tty" ]
    [ "$(cat "$HOSTDIR/join.tty")" != "$(cat "$HOSTDIR/payload.tty")" ]
}

@test "joining a session that does not exist fails" {
    run bash -c "cd '$PROJ' && $SBX --join nosuchsession 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/join.bats`

Expected: FAIL. The namespace/capability/pty tests fail because `--join` still runs `abduco -a` semantics against a socket that no longer exists — it will report the "not found" error, so the join never runs and `/out/join.*` is never written. (`joining a session that does not exist fails` may already pass; that is fine.)

- [ ] **Step 3: Rewrite the `--join` branch**

Replace `sbx:205-219` in full:

```bash
        --join)
            JOIN_SESSION="$2"
            shift 2
            # A trailing `-- cmd` has to be consumed here: this branch exits
            # before the main loop ever reaches the `--` case.
            JOIN_CMD=()
            if [[ "${1-}" == "--" ]]; then
                shift
                JOIN_CMD=("$@")
            fi
            SDIR="$STATE_DIR/$JOIN_SESSION"
            # -S, not -f: the server's rendezvous point is a unix socket,
            # which is never a regular file.
            if [[ ! -d "$SDIR" || ! -S "$SDIR/tmux.sock" ]]; then
                echo "Error: Session '$JOIN_SESSION' not found or no socket available." >&2
                exit 1
            fi
            # Inline check, not require_tools: that function is defined
            # further down and does not exist yet during argument parsing.
            if ! command -v tmux >/dev/null 2>&1; then
                echo "Error: sbx requires tmux, which is not on PATH." >&2
                exit 1
            fi
            # new-session, NOT attach: a second client on the SAME session
            # would mirror the payload's terminal, which is exactly the
            # behaviour this flag exists to stop doing. A new session in the
            # same server is an independent client with its own pty and its
            # own size, and the server — already inside the namespaces and
            # already under the wrapper's setpriv drop — is what forks it,
            # so the joined shell is capless without any code of ours.
            if [[ ${#JOIN_CMD[@]} -gt 0 ]]; then
                exec tmux -S "$SDIR/tmux.sock" new-session -- "${JOIN_CMD[@]}"
            else
                exec tmux -S "$SDIR/tmux.sock" new-session
            fi
            ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/join.bats` — Expected: all 5 pass.

- [ ] **Step 5: Update the usage text**

At `sbx:48`, replace:

```
  --join <session>       Attach to an existing session
```

with:

```
  --join <session>       Open a new shell inside a running session
                         (--join <session> -- <cmd> runs <cmd> instead)
```

- [ ] **Step 6: Update the README**

`README.md:66`, replace the `--join` row with:

```
| `--join <session>` | Open a new shell inside a running sandbox session, with its own terminal. Append `-- <cmd>` to run a command instead. |
```

`README.md:11`, replace the feature bullet with:

```
- **Session Management**: List active sessions, and open additional shells inside a running one.
```

- [ ] **Step 7: Run the whole suite and shellcheck**

Run: `bats tests/` then `shellcheck sbx lib/copy-mounts.sh`

Expected: all tests pass; no new shellcheck findings beyond the documented 5.

- [ ] **Step 8: Commit**

```bash
git add sbx tests/join.bats README.md
git commit -m "Make --join open a new shell inside the sandbox

new-session rather than attach: a second client on the same session mirrors
the payload's terminal, which is what --join used to do. The in-sandbox
server forks the shell, so it lands in the sandbox's namespaces and inherits
the payload's empty capability bounding set for free."
```

---

### Task 3: The host environment must not reach a join

**Files:**
- Modify: `sbx` (the `cat > "$TMUX_CONF"` block from Task 1, Step 5)
- Test: `tests/join.bats` (append)

**Interfaces:**
- Consumes: `start_bg_sbx`, `join_sbx`, `PARK` from Task 2.
- Produces: nothing new.

This is a real leak, not a hypothetical: a probe during design confirmed a host `DISPLAY` reaching a join. The tmux client ships its environment to the server, and `update-environment` (default: `DISPLAY`, `SSH_AUTH_SOCK`, `SSH_CONNECTION`, …) applies it to *new* sessions — driving a hole straight through the `--clearenv` policy at `sbx:524`, whose entire point is that the host environment carries API keys, tokens and `SSH_AUTH_SOCK`. Task 1 deliberately left the fix out so this test can be seen to fail first.

- [ ] **Step 1: Write the failing test**

Append to `tests/join.bats`:

```bash
@test "the host environment does not reach a join" {
    # tmux clients ship their environment to the server; update-environment
    # decides how much of it lands in new sessions. DISPLAY is on tmux's
    # default list, so it is the canary. SBX_TEST_SECRET stands in for the
    # API keys and tokens --clearenv exists to keep out.
    export DISPLAY=":99"
    export SSH_AUTH_SOCK="/tmp/fake-agent.sock"
    export SBX_TEST_SECRET=hunter2
    start_bg_sbx "--fs caps" "$PARK"
    join_sbx "env > /out/join.env"
    [ -s "$HOSTDIR/join.env" ]
    ! grep -q '^DISPLAY=:99' "$HOSTDIR/join.env"
    ! grep -q '^SSH_AUTH_SOCK=' "$HOSTDIR/join.env"
    ! grep -q 'hunter2' "$HOSTDIR/join.env"
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bats tests/join.bats -f "host environment"`

Expected: FAIL on the `DISPLAY` assertion — `join.env` contains `DISPLAY=:99`. If it passes at this point, stop: either the config already carries the setting or the test is not reaching a real join, and both need explaining before proceeding.

- [ ] **Step 3: Close the leak**

In the `cat > "$TMUX_CONF"` heredoc, add as the first line of the config body:

```
set -g update-environment ''
```

so the block reads:

```bash
cat > "$TMUX_CONF" <<EOF
set -g update-environment ''
set -g exit-empty on
set -g escape-time 0
set -g window-size latest
unbind C-b
set -g prefix C-\\\\
bind C-\\\\ send-prefix
set -g status on
set -g status-left ' sbx:$SESSION_ID '
set -g status-left-length 40
EOF
```

And extend the comment above the block with the reason, since this line is the one a future reader is most likely to "clean up":

```bash
#   update-environment  SECURITY. A tmux client ships its environment to the
#                  server, and this list is what gets applied to new
#                  sessions — by default DISPLAY, SSH_AUTH_SOCK and friends.
#                  Leaving it at the default drives a host-env hole straight
#                  through the --clearenv policy above. Emptied deliberately.
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bats tests/join.bats -f "host environment"` — Expected: PASS.

- [ ] **Step 5: Run the whole suite and shellcheck**

Run: `bats tests/` then `shellcheck sbx lib/copy-mounts.sh` — Expected: all pass, no new findings.

- [ ] **Step 6: Commit**

```bash
git add sbx tests/join.bats
git commit -m "Stop tmux carrying the host environment into a join

tmux clients ship their environment to the server and update-environment
applies it to new sessions, which put host DISPLAY and SSH_AUTH_SOCK inside
the sandbox despite --clearenv. Emptied, with a regression test."
```

---

### Task 4: Copy-writeback waits for a live join

**Files:**
- Test: `tests/join.bats` (append)

**Interfaces:**
- Consumes: `start_bg_sbx`, `join_sbx` from Task 2; the `session.sh` wait loop from Task 1.
- Produces: nothing new.

No production change is expected — Task 1's wait loop should already deliver this. The task exists because it is the property most likely to break silently later, and the one that protects the user's files: if `session.sh` ever exited on payload exit, writeback (`sbx:1294`, `sbx:1301`) would fire while a join was still writing, and work would be partially copied or lost. If the test fails, the bug is in Task 1's loop, not here.

- [ ] **Step 1: Write the test**

Append to `tests/join.bats`. Note this test needs a *copy* mount, since a plain `rw` bind writes through immediately and would pass no matter when writeback ran:

```bash
@test "writeback waits for a join that outlives the payload" {
    # A copy mount, not a plain rw bind: rw writes through immediately, so
    # it would pass regardless of when (or whether) writeback ran.
    cat > "$PROJ/.sbx/profiles/fs/cp.json" <<EOF
{"description":"test","mounts":[
  {"source":"$HOSTDIR","dest":"/out","perm":"rw"},
  {"source":"$ROOT/src","dest":"/copy","perm":"copy"}
]}
EOF
    mkdir -p "$ROOT/src"

    # Payload exits as soon as it is released; the join keeps running past
    # that point and writes only after the payload is gone.
    start_bg_sbx "--fs cp" "while [ ! -f /out/payload-go ]; do sleep 0.2; done"

    ( cd "$PROJ" && script -qec "$SBX --join $BG_SESSION -- /bin/sh -c 'while [ ! -f /out/join-go ]; do sleep 0.2; done; echo late > /copy/late.txt; echo done > /out/join-done'" /dev/null >/dev/null 2>&1 ) &
    local join_pid=$!

    # Let the join reach its wait loop, then end the payload.
    sleep 1
    touch "$HOSTDIR/payload-go"
    sleep 1

    # The session must still be alive with the payload gone — that is the
    # whole point of the PID-1 waiter.
    [ -S "$BG_SDIR/tmux.sock" ]

    touch "$HOSTDIR/join-go"
    wait "$join_pid" 2>/dev/null || true
    wait "$BG_PID" 2>/dev/null || true
    BG_PID=""

    [ -f "$HOSTDIR/join-done" ]
    [ "$(cat "$BG_SDIR/fs/_copy/late.txt")" = "late" ]
}
```

- [ ] **Step 2: Run it**

Run: `bats tests/join.bats -f "writeback waits"`

Expected: PASS. Two failure modes to tell apart if it does not:
- `[ -S "$BG_SDIR/tmux.sock" ]` fails → `session.sh` exited with the payload; the wait loop in Task 1 Step 7 is wrong.
- the `late.txt` assertion fails → the session outlived the payload but writeback did not capture the late write; check the copy-mount id slug (`sbx_copy_mount_id`) used in the path rather than assuming `_copy`.

- [ ] **Step 3: Confirm the mount-id slug in the assertion is right**

The path `fs/_copy/late.txt` assumes `sbx_copy_mount_id /copy` → `_copy`. Verify against `lib/copy-mounts.sh` and fix the assertion if the slug differs; the test must assert the real path, not a guessed one.

- [ ] **Step 4: Run the whole suite**

Run: `bats tests/` — Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add tests/join.bats
git commit -m "Test that writeback waits for a join outliving the payload

Locks in the property the PID-1 waiter exists for: a join still writing
after the payload exits must not race copy-writeback."
```

---

### Task 5: `--attach` for the payload's own terminal

**Files:**
- Modify: `sbx` (add an `--attach` branch beside `--join`)
- Modify: `sbx:48` (usage text)
- Modify: `README.md` (command table)
- Test: `tests/join.bats` (append)

**Interfaces:**
- Consumes: `$SDIR/tmux.sock`; `start_bg_sbx` from Task 2.
- Produces: `sbx --attach <session>` → attaches to the `main` session created by `session.sh`.

With mirroring gone from `--join`, detaching the main session would otherwise be a permanent lockout from a still-running payload. `--attach` is the deliberate exception: it is mirroring, by name, for your own session.

- [ ] **Step 1: Write the failing tests**

Append to `tests/join.bats`:

```bash
@test "attaching to a session that does not exist fails" {
    run bash -c "cd '$PROJ' && $SBX --attach nosuchsession 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "attach reaches the payload's own terminal" {
    # The payload prints a marker to its terminal and parks; an attach must
    # see that marker on its screen, which a fresh --join never would.
    start_bg_sbx "--fs caps" "echo PAYLOAD_MARKER; $PARK"
    sleep 1
    ( cd "$PROJ" && timeout 5 script -qec "$SBX --attach $BG_SESSION" /dev/null > "$HOSTDIR/attach.out" 2>&1 ) || true
    grep -q PAYLOAD_MARKER "$HOSTDIR/attach.out"
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/join.bats -f attach`

Expected: FAIL — `sbx` does not know `--attach`, so it is treated as a command to run and the marker never appears.

- [ ] **Step 3: Add the `--attach` branch**

Insert immediately after the `--join)` branch's closing `;;`:

```bash
        --attach)
            ATTACH_SESSION="$2"
            shift 2
            SDIR="$STATE_DIR/$ATTACH_SESSION"
            if [[ ! -d "$SDIR" || ! -S "$SDIR/tmux.sock" ]]; then
                echo "Error: Session '$ATTACH_SESSION' not found or no socket available." >&2
                exit 1
            fi
            if ! command -v tmux >/dev/null 2>&1; then
                echo "Error: sbx requires tmux, which is not on PATH." >&2
                exit 1
            fi
            # This one really is mirroring, deliberately and by name: it is
            # the way back to a payload you detached from. --join is the
            # non-mirroring door; without this, detaching the main session
            # would lock you out of a still-running payload for good.
            exec tmux -S "$SDIR/tmux.sock" attach -t main
            ;;
```

- [ ] **Step 4: Run them to verify they pass**

Run: `bats tests/join.bats -f attach` — Expected: both pass.

- [ ] **Step 5: Update usage and README**

`sbx:48` area — add below the `--join` lines:

```
  --attach <session>     Reattach to a session's original terminal
```

`README.md`, add below the `--join` row:

```
| `--attach <session>` | Reattach to a running session's original terminal (the one `sbx` started it on). |
```

- [ ] **Step 6: Run the whole suite and shellcheck**

Run: `bats tests/` then `shellcheck sbx lib/copy-mounts.sh` — Expected: all pass, no new findings.

- [ ] **Step 7: Commit**

```bash
git add sbx tests/join.bats README.md
git commit -m "Add --attach to reach a session's original terminal

--join no longer mirrors, so detaching the main session would otherwise
lock you out of a running payload. --attach is that door, named for what
it does."
```

---

## Self-Review

**Spec coverage:** Architecture/`session.sh` → Task 1. Session lifetime → Task 1 (implementation) + Task 4 (test). Exit codes dropped → no task needed; Task 1 Step 8 removes the propagation path and the Global Constraints record that no test asserts it. Interface table (`--join`/`--attach`) → Tasks 2 and 5. Generated tmux config → Task 1 Step 5 + Task 3 Step 3. Security/env hygiene → Task 3. Security/capless joins → Task 2 test. Fallout (`find_session_mux`, cleanup list, README, test comments) → Tasks 1, 2, 5. Testing list items 1–5 → Tasks 2, 3, 4, 5. No gaps.

**Deliberate spec deviations:** the spec puts `update-environment ''` in the config from the start; this plan holds it back to Task 3 so its regression test can be observed failing first, which is the only way to know the test actually tests something. Task 1 Step 5's comment block is extended in Task 3 Step 3 rather than written once.

**Type/name consistency:** `TMUX_SOCK`, `TMUX_CONF`, `SESSION_SCRIPT`, `CAT_WRAPPER`, `LAUNCH_SCRIPT` used identically across Tasks 1–5. `start_bg_sbx`/`join_sbx`/`PARK`/`BG_PID`/`BG_SDIR`/`BG_SESSION` are defined once in Task 2 Step 1 and consumed under those exact names in Tasks 3–5. The socket is `tmux.sock` everywhere; `session.sock` survives only in the deletions.

**Known-uncertain steps, each with a verification built in rather than an assumption:** the `C-\` prefix escaping (Task 1 Step 6 proves it against real tmux) and the copy-mount slug in the writeback assertion (Task 4 Step 3 checks it against `lib/copy-mounts.sh`).
