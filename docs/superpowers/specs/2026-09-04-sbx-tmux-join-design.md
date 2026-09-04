# Non-mirroring `--join`: swapping abduco/dtach for tmux

## Problem

`--join` does not join a sandbox. It mirrors a terminal.

`sbx` runs the payload under `abduco -c "$SESSION_DIR/session.sock"`, and
`--join` runs `abduco -a` against that socket from the host. Both clients share
one PTY: the joiner sees the payload's screen and types into it. Nothing about
the join enters the sandbox. The `abduco -a` process stays on the host, as the
host user, outside every namespace bwrap created; the only thing crossing the
boundary is the socket.

What is wanted instead: `sbx --join <session>` opens a *fresh* shell inside a
running sandbox — its own PTY, its own window size, independent of whatever the
payload is doing, but in the sandbox's mount, pid, net, ipc and uts namespaces
and under the same capability drop.

## Why not nsenter

The obvious alternative is to `nsenter` into the running bwrap child from the
host. It fails on two counts.

`session.json` records `"pid": $$` (`sbx:1174`) — the *host-side* `sbx` process,
not the bwrap child inside the namespaces — so there is no re-entry handle to
target without adding one.

More importantly, entering from outside means reconstructing the sandbox's
security posture by hand. The payload runs under
`setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all` (`sbx:1479`);
an `nsenter`-spawned shell would sidestep that unless every flag were
replicated at the join site, and would drift the moment the wrapper changed.
A process forked by something *already inside* inherits the drop for free.

## Approach: tmux server inside, tmux client outside

Run the multiplexer's server inside the sandbox with its socket at
`$SESSION_DIR/tmux.sock`. `sbx:1275` already binds `$SESSION_DIR` at the *same
path* on both sides, so a host-side `tmux -S "$SESSION_DIR/tmux.sock"` client
talks to that in-sandbox server with no new mount.

tmux already draws the exact distinction the feature needs:

- two clients on the **same session** mirror each other — today's `--join`
- clients on **different sessions in one server** are independent, each with
  its own PTY and size — the `--join` we want

So `--join` is `new-session`, and the server — inside the namespaces, under
`setpriv` — forks the shell. The control channel, the per-join PTY, the join
registry, and the "wait for the last shell" teardown all come from tmux instead
of from bespoke code, which keeps the project's stock-tools-only rule
(`docs/superpowers/plans/2026-08-01-sbx-hardening.md:13`).

### Rejected alternatives

**A FIFO supervisor keeping abduco.** A ~50-line `supervisor.sh` inside the
sandbox holding `$SESSION_DIR/ctl.fifo` open read-write, spawning an
`abduco -c` session per request. Works, smaller blast radius, no dependency
change — but it is hand-rolled process management duplicating what tmux does,
and it leaves detach one-way (see below).

**A socat control socket.** A real stream socket with a request/response
protocol. Buys nothing over the FIFO and adds a `socat` dependency inside the
sandbox.

**A pre-spawned pool of idle shells.** No control channel at all, but a fixed
cap on joins and N idle processes per session.

## Why the multiplexer cannot simply be dropped

Worth recording, because it is not obvious and it constrains everything else.

`--new-session` (`sbx:507`) calls `setsid()`, which is what stops the sandbox
from injecting into the host terminal. Its side effect is that the sandboxed
process has **no controlling terminal**. Verified:

```
$ bwrap --unshare-pid --new-session ... -- bash -c '...'
tty(stdin)=/dev/console
has-ctty: /bin/bash: line 1: /dev/tty: No such device or address
NO
```

stdin is still the host pts, but `/dev/tty` does not open. No job control, no
Ctrl-C delivery (SIGINT goes to the host terminal's foreground process group,
which the sandbox is no longer in), and anything opening `/dev/tty` directly —
`sudo`/`ssh` prompts, `less`, `vim`, gpg pinentry, full-screen TUIs — fails.

`abduco -c` repairs that by allocating a PTY *inside* the sandbox and making it
the payload's controlling terminal. Detach/reattach was its visible feature;
supplying a ctty under `--new-session` is the load-bearing one. tmux must take
over that job, which it does by construction.

## Architecture

```
pasta → launch.sh → bwrap → session.sh                     [PID 1 in sandbox]
                              ├─ tmux -f tmux.conf -S tmux.sock \
                              │       new-session -d -s main -- wrapper.sh
                              ├─ tmux attach -t main       [foreground, owns bwrap stdio]
                              └─ while has-session; do sleep; done
```

`session.sh` replaces `wrapper.sh` as bwrap's argument; `wrapper.sh` itself is
unchanged and becomes the `main` session's command.

`session.sh` is *generated* into `$SESSION_DIR` at launch, exactly as
`launch.sh` and `wrapper.sh` already are (`sbx:1319`, `sbx:1320`): `sbx`
remains a single shipped script, and a session directory simply holds three
generated scripts instead of two. The three cannot be collapsed, because each
runs at a different point in the chain — `launch.sh` outside bwrap in pasta's
namespaces, `session.sh` inside bwrap as PID 1, and `wrapper.sh` as the payload,
which must be separately invocable to serve as the `main` session's command.
Keeping the PID-1 waiter on disk is deliberate: it is the new lifetime logic and
the piece most likely to need inspection when a session misbehaves.

**`session.sh` must be what bwrap waits on.** The tmux server daemonizes, so if
bwrap's direct child exited, PID 1 would die and the pid namespace would take
every session with it. The trailing wait loop is the entire implementation of
the session-lifetime rule below.

### Session lifetime

The session lives until the **last** tmux session exits — payload or join,
whichever is last. `exit-empty on` makes the server exit when no sessions
remain; `session.sh`'s loop then returns, bwrap exits, and `launch.sh` proceeds
to copy-writeback.

This closes a race the current design cannot have but the feature would
introduce: writeback (`sbx:1294`, `sbx:1301`) copies sandbox state back to the
host the moment the payload exits, so a join still writing files during
writeback would have its work partially copied or lost.

Accepted consequence: the launching terminal is occupied for the session's
whole life. Detaching returns to the waiter, not to a shell prompt. A
`--detach` flag could address this later; out of scope.

### Exit codes

Payload exit status is no longer propagated out of the sandbox. `abduco -c`'s
status was the payload's status and reached the caller through bwrap; a tmux
server's status says nothing about the payload, and recovering it needs a shim
writing `$?` to a file for `launch.sh` to read.

Explicitly dropped as not worth the machinery. Verified safe against the
current suite: every `$status` assertion is on an argument-validation path
(`tests/hardening.bats:166`, `:175`, `tests/project-profiles.bats:24`, `:47`,
`:59`), on `--list-sessions` (`tests/hardening.bats:286`), or on the
`sbx_copy_writeback` shell-function unit tests (`tests/copy-mounts.bats:76`).
The e2e helpers discard status entirely (`tests/persistent-cli.bats:44`).

## Interface

| Flag | Behaviour |
|---|---|
| `--join <session>` | `tmux -S "$SDIR/tmux.sock" new-session [-- cmd]` — a fresh PTY inside the sandbox. No command → the sandbox's `$SHELL`. |
| `--attach <session>` | `tmux -S "$SDIR/tmux.sock" attach -t main` — reattach to the payload's own terminal. |

Mirroring is gone from `--join`; `--attach` exists so that detaching the main
session is not a permanent lockout from a still-running payload. Both refuse
with the existing message shape when the socket is absent.

`--join <id> -- cmd` runs `cmd` in a fresh PTY, matching how `sbx` already
accepts a trailing command. Non-PTY/piped exec mode is out of scope.

## Generated tmux config

Written per session to `$SESSION_DIR/tmux.conf` and passed as `-f`. The `-f` is
not cosmetic: the sandbox usually has `$HOME` mounted, so without it the server
would read the user's `~/.tmux.conf` and session behaviour would depend on host
dotfiles.

| Setting | Reason |
|---|---|
| `set -g update-environment ""` | **Security.** See below. |
| `set -g exit-empty on` | The teardown condition. (Default; set explicitly.) |
| `set -g prefix 'C-\'` + `unbind C-b` | A host tmux keeps `C-b`; no doubled prefixes when nesting. |
| `set -g status on`, `status-left` naming the sbx session id | Makes "you are inside a sandbox" visible. |
| `set -g window-size latest` | Per-client sizing, so one join does not resize another. |
| `set -g escape-time 0` | Standard; avoids ESC lag in TUIs. |

## Security

**Environment hygiene — a real leak, caught in the probe.** The tmux client
ships its environment to the server, and `update-environment` (default:
`DISPLAY`, `SSH_AUTH_SOCK`, `SSH_CONNECTION`, …) applies it to *new* sessions.
The probe confirmed a host `DISPLAY` reaching a join. That is a hole straight
through the `--clearenv` policy at `sbx:524`, whose entire point is that the
host environment carries API keys, tokens and `SSH_AUTH_SOCK`.
`update-environment ""` is mandatory, and gets a regression test.

**TIOCSTI posture is unchanged, not weakened.** The tmux client passes its tty
fd to the server, so the in-sandbox server holds a descriptor to the host
terminal. This is already true today: bwrap's stdin/stdout *are* the host pts
and are inherited by everything inside. What holds the line is that the fd is
not the sandbox's *controlling* terminal — `TIOCSTI` on a non-controlling tty
requires `CAP_SYS_ADMIN`, which the payload does not have. `--new-session` and
the capability drop both survive the swap unchanged.

**Joins are capless by construction.** The server runs under the payload's
`setpriv` drop, so every session it forks inherits an empty bounding set with
no code of ours. Probe: payload `CapBnd: 0000000000000000`, join identical.

**The socket sits in sandbox-writable space.** `$SESSION_DIR` is bound rw
inside, so the payload can interfere with `tmux.sock` and `tmux.conf`. This is
the pre-existing posture — `session.json` is already treated as
attacker-authored (`sbx:184`) — and the exposure does not grow: a malicious
payload already controls the bytes on its own PTY. Narrowing the bind so only
`fs/`, `tmp/` and the socket are writable is a worthwhile follow-up but is out
of scope here.

**Path length.** tmux sockets inherit the ~108-char `sun_path` limit that
already constrains e2e tests to a short `$HOME`
(`docs/superpowers/plans/2026-07-23-persistent-cli-profiles.md:30`). The first
probe run failed exactly this way. Comments and test scaffolding that explain
the limit in terms of abduco must be reworded, not deleted.

## Feasibility evidence

A throwaway probe (not retained) validated every load-bearing claim before
this spec was written:

| Claim | Result |
|---|---|
| Host client reaches the in-sandbox server across the bind | socket visible, `list-sessions` works |
| A host-initiated join runs inside the namespaces | join pid ns `4026533663` = payload's ≠ host's; pid inside is `12` |
| Joins are capless with no extra code | `CapBnd: 0000000000000000`, identical to payload |
| A PID-1 waiter outlives the payload and dies with the last session | waiter exited only after the server was gone |
| Host env does not leak | **failed** without `update-environment ""` — `DISPLAY` reached the join |

`tmux 3.7c`; multiple independent sessions in one server confirmed.

## Fallout

- `find_session_mux` (`sbx:25`) collapses into a plain `tmux` requirement in
  `require_tools`; `SESSION_MUX`/`SESSION_SOCK` go away.
- Cleanup (`sbx:1305`) drops `session.sock`/`wrapper.sh` and instead removes
  `tmux.sock`, `tmux.conf` and `session.sh`.
- README's `--join` row (`README.md:66`) and feature bullet (`:11`) are now
  wrong and must describe join-vs-attach.
- abduco/dtach prose in `tests/persistent-cli.bats:40` and
  `tests/hardening.bats:35` needs rewording. `script -qec` scaffolding stays —
  a tmux client needs a pty too.

## Testing

Existing suites must pass unchanged. New coverage:

1. **A join shares the payload's namespaces** — compare
   `readlink /proc/self/ns/pid` between payload and join.
2. **A join is capless** — joined shell reports `CapBnd: 0000000000000000`.
3. **Host environment does not reach a join** — export a marker plus `DISPLAY`
   on the host; neither appears in the join's `env`. Regression test for the
   probe's one failure.
4. **Writeback waits for a live join** — a join writing to a copy mount after
   the payload exits still has its file copied back.
5. **`--attach` reaches the payload's session**, and `--join`/`--attach`
   against a missing socket fail with the existing message.

Tests need a launch-in-background-then-poll-for-socket helper, since every
current e2e helper runs a sandbox to completion synchronously.

## Out of scope

`--detach` for backgrounding the launcher; non-PTY join exec mode; narrowing
the `$SESSION_DIR` bind; propagating payload exit status.
