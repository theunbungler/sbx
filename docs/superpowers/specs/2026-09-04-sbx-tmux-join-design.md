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
security posture by hand. The whole session runs under
`setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all`, applied in
`launch.sh` above `session.sh`; an `nsenter`-spawned shell would sidestep that
unless every flag were replicated at the join site, and would drift the moment
the drop changed.
A process forked by something *already inside* inherits the sandbox's
namespaces for free; the capability drop is a separate matter, and is handled
by dropping once above the tmux server so that everything it forks is capless
by construction (see "Joins are capless" below).

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
pasta → launch.sh → bwrap → setpriv → session.sh           [PID 1 in sandbox]
                                 (drops every cap, once, for everything below)
                                        ├─ tmux -f tmux.conf -S tmux.sock \
                                        │       new-session -d -s main -- wrapper.sh
                                        ├─ tmux attach -t main   [foreground, owns bwrap stdio]
                                        └─ while has-session; do sleep; done
```

`session.sh` replaces `wrapper.sh` as bwrap's argument, and the capability drop
moves out of `wrapper.sh` and up to `setpriv`, above `session.sh`, so it covers
the tmux server and everything the server ever forks rather than the payload
alone. `wrapper.sh` is otherwise unchanged and becomes the `main` session's
command. (`"caps": "keep"` sessions omit the `setpriv` step entirely.)

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

The waiter is not sufficient on its own, and the guarantee must not be stated
as though it were. Its liveness test is "can a client connect to this socket",
and both the socket and the server are inside the sandbox's writable set: a
payload that runs `rm $SESSION_DIR/tmux.sock` or `tmux kill-server` ends the
loop whenever it likes. Verified — the session tore down with a join mid-write,
and the join's file never reached `fs/_copy`.

That verification was read at the time as proof that the host needs a lock to
stop writeback overlapping *that* torn-down join. A later, more precise
measurement (on the `mount-authority` branch, `tests/join.bats` "writeback
waits on the host lock when teardown is not gated by the sandbox") shows the
mechanism is different from what this section originally claimed. Killing the
waiter's liveness signal is what makes bwrap's PID-1 child exit, and bwrap
exiting destroys the pid namespace the join's pane lives in — so the join
loses its process, and stops writing, within milliseconds of the tamper,
before `launch.sh` ever reaches copy-writeback. Every write the join managed
before that moment is still copied; none is torn mid-write by a race with
writeback. So the mid-write loss observed above was real, but its cause was
namespace teardown ending the join, not writeback running concurrently with
it — against tampering specifically, the host lock turns out not to be the
thing preventing the loss.

Where the lock is load-bearing is a case this section did not consider:
`teardown()`/copy-writeback running as an `EXIT` trap on a fatal signal —
Ctrl-C on the launching terminal, a CI timeout — while `session.sh`, the tmux
server, the payload and any join are all still alive and behaving normally.
`--die-with-parent` only kills bwrap once `launch.sh` has already exited, i.e.
after that trap has already run, so the PID-1 waiter is not on this exit path
at all and cannot order anything here. This is the case the flock actually
exists for.

The enforcing half therefore lives on the host regardless of which case
motivates it. `--join` takes a *shared* `flock` on `$STATE_DIR/<id>.joinlock`
for its whole life, and `teardown()` takes the same lock *exclusively* before
running copy-writeback. That path is outside `$SESSION_DIR` and behind the
`--tmpfs "$STATE_DIR"` mask, so it does not exist from inside the sandbox and
nothing in there can touch it. The wait is bounded (`flock -w 30`) and warns
loudly rather than blocking forever, so a stale lock cannot wedge a teardown.

What that does and does not promise: writeback never *overlaps* a live join,
whatever the sandbox does to the socket or whatever signal `sbx` receives. It
cannot keep a hostile payload from ending its own sandbox and taking a live
join down with it — bwrap's child is PID 1 of the namespace, and nothing on
the host can stop it exiting — but, per the measurement above, that path
already stops the join's writes before writeback would start, with or without
the lock. The property the lock buys is "writeback and a join never run at
the same time", not "a join cannot be killed", and the case where that
property is doing real work is a signalled teardown of a live sandbox, not a
tampering payload.

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

This covers the *payload's* status only. A **launch** failure is a different
thing and is not swallowed: if `new-session` fails, `session.sh` prints to
stderr and exits 1 rather than falling into a wait loop whose first
`list-sessions` also fails, and `sbx` exits non-zero and says the payload may
never have run instead of "Changes saved". Without that check, any reason the
server cannot start — an over-long socket path, no tmux in the sandbox's
`/usr` view, an unparseable `tmux.conf` — produced a fast, silent, successful
looking no-op that a CI job could not tell from a successful run.

## Interface

| Flag | Behaviour |
|---|---|
| `--join <session>` | `tmux -S "$SDIR/tmux.sock" new-session -c <workdir> -- /usr/bin/env PATH=<session PATH> <cmd>` — a fresh PTY inside the sandbox. No command → `/bin/bash`. The whole argv is built on the host; `-c` and `PATH` come from the host-side sidecar, because tmux would otherwise use the client's cwd and the client's `PATH`. |
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

**Joins are capless because the drop is applied above the server.** The
first design assumed the server would run under the *payload's* `setpriv`. It
does not: the server is started by `session.sh`, which is a sibling of the
payload, so it would hold the session's retained `CAP_SETPCAP` for the whole
life of the sandbox and hand it to every process it forks — a join, but
equally `new-window` and `split-window`, which are default key bindings.
Measured on a live session before the fix: the join itself
`CapBnd: 0000000000000000`, a window opened inside it
`CapBnd: 0000000000000100`.

The drop therefore happens *once*, at the highest point it can: `launch.sh`
makes bwrap's direct child `setpriv --bounding-set=-all --inh-caps=-all
--ambient-caps=-all -- session.sh`. CAP_SETPCAP is spent there and is gone
before the tmux server, the payload or any join exists, so every
server-forked process — by any route, including `respawn-pane`, `run-shell`,
hooks and `default-command` — is capless by construction. `wrapper.sh` carries
no `setpriv` of its own any more; a second `--bounding-set=-all` under an
already-empty bounding set fails with EPERM, since emptying one requires
CAP_SETPCAP.

Setting `default-command` in `tmux.conf` was considered and rejected: it
enumerates fork paths instead of covering them, and the payload holds the
server socket, so it can simply `tmux set -g default-command` its way out.

`"caps": "keep"` sessions are deliberately not wrapped, and their joins keep
capabilities too — which is why `--join` needs no capability logic of its own.

**The socket sits in sandbox-writable space.** `$SESSION_DIR` is bound rw
inside, so the payload can interfere with `tmux.sock` and `tmux.conf`, and
`session.json` is already treated as attacker-authored (`sbx:184`).

The exposure *would* grow if `--join` executed anything from that directory.
An earlier revision did — it ran a generated `join_wrapper.sh` — and that was
demonstrably defeatable: an in-sandbox process overwrote the script, and the
next host-initiated join ran the attacker's version with
`CapEff: 0000000000000100`. Under abduco a joiner knew they were looking at
the payload's own terminal; `--join` advertises a fresh, sbx-provided shell,
which is a new trust relationship, and handing the sandbox the script behind
it gives that relationship away.

So nothing `--join` runs comes from inside. The wrapper is gone; the host
builds the whole argv (`/usr/bin/env PATH=… -- <cmd>`), and everything it
needs to know about the session — `PATH`, working directory, capability
policy — is read from a sidecar at `$STATE_DIR/<id>.join.json`, which is
outside `$SESSION_DIR` and therefore behind the `--tmpfs "$STATE_DIR"` mask
that hides sibling state from the sandbox. Narrowing the bind so only `fs/`,
`tmp/` and the socket are writable remains a worthwhile follow-up, but the
join path no longer depends on it.

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
| Joins are capless *because the drop is applied above the tmux server* | with the drop at `launch.sh`: join and a window opened inside it both `CapBnd: 0000000000000000`. With it applied only in `wrapper.sh` (the original design): join `0000000000000000` but server-forked window `0000000000000100`. The original probe measured the payload's own session, not a `new-session` fork, so it did not show what this row first claimed. |
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
