# sbx hardening design

**Date:** 2026-08-01
**Status:** approved, not yet implemented

## Threat model

sbx assumes both the code running inside the sandbox **and** the project
directory it was launched from are actively adversarial. A prompt-injected
agent, a malicious dependency, and a repository that ships its own
`.sbx/profiles/` are all in scope. The host user account is the asset being
protected.

This is a change in stated intent, not just in code: before this work, sbx
provided isolation that held against mistakes but not against an adversary.

## Constraint: no custom code

sbx composes stock tools — `bwrap`, `pasta`, `nft`, `dnsmasq`, `abduco`/`dtach`,
`jq`, and now `setpriv` (util-linux). This design adds no new binaries, no
compiled artifacts, and no bespoke daemons. Where a fix would require custom
code, it is documented as a residual risk instead (see below).

## Findings this design addresses

Verified empirically on bubblewrap 0.11.2 / pasta 2026_07_16 / Linux 6.12:

1. **`--cap-add ALL` makes `ro` mounts writable.** In `--net` mode pasta maps
   host uid 1000 to uid 0, and `--cap-add ALL` grants a full ambient set that
   survives execve. `CAP_SYS_ADMIN` over the mount namespace bwrap itself
   created allows `mount -o remount,bind,rw` on any `--ro-bind`. Host
   root-owned trees (`/usr`, `/etc`, `/sys`) survive only because host uid 0 is
   unmapped and DAC still denies the write. Every `ro` mount of a *user-owned*
   path — `$HOME/.nvm`, `$HOME/.npm-global`, `$HOME/.npm` in the shipped
   gemini/pi profiles — is writable from inside.
2. **The egress firewall is self-disabling.** The payload holds
   `CAP_NET_ADMIN` in its own netns; `nft flush ruleset` succeeds. The
   allow-list constrains accidents, not adversaries.
3. **`$HOME/.local` mounted rw** (`cli/claude.json`) hands over `~/.local/bin`
   (on the host PATH), `~/.local/share/systemd/user`, and — since
   `STATE_DIR="$HOME/.local/state/sbx"` — every other session directory and
   every persistent cli store.
4. **`./.sbx/profiles/` is searched first**, so a repository defines the
   sandbox that is supposed to contain it.
5. **No `--clearenv`**: the entire host environment, including API keys and
   `SSH_AUTH_SOCK`, is inherited.
6. **pasta maps the gateway address to host loopback** by default. sbx passes
   `-g "$HOST_GW"` and never `--no-map-gw`, so the sandbox reaches host-local
   services via the gateway IP.
7. **`$SESSION_DIR` is bound rw**, making `session.json` sandbox-authored while
   `--list-sessions` echoes its fields unsanitized.
8. **`session.json` never records `pid`**, so `--list-sessions` reports every
   session inactive.

### Two corrections to the original audit

- **Removing `--cap-add ALL` fixes nothing on its own.** bwrap drops
  capabilities only when it creates the user namespace. In `--net` mode it
  joins pasta's, inherits uid 0 plus a full ambient set, and passes it through
  unchanged. An explicit `--cap-drop ALL` is required.
- **Going capless costs nested user namespaces** in `--net` mode. A capless
  euid-0 process cannot write a nested `uid_map`, and neither `CAP_SETUID` +
  `CAP_SETGID` nor a full 65536-UID `--map-auto` mapping restores it. uid 0 is
  not negotiable — host uid 1000 must map to ns uid 0 or the user's own files
  stop appearing to belong to them. This limitation is therefore intrinsic to
  any capless design, not a property of the approach chosen. No-net mode is
  unaffected: bwrap creates the userns, euid stays 1000, and nesting works
  capless.

Measured behaviour, `--net` mode:

| configuration | remount `ro`→rw | `nft flush` | nested userns |
|---|---|---|---|
| `--cap-add ALL` (current) | permitted | permitted | works |
| `--cap-add` removed | permitted | permitted | works |
| `--cap-drop ALL` | denied | denied | fails |
| `--cap-drop ALL` + SETUID/SETGID | denied | denied | fails |
| no-net, capless (current) | denied | denied | works |

## Architecture

### Capability model

`launch.sh` becomes the privileged setup stage rather than a one-line
`exec bwrap`. It already runs inside pasta's namespaces as uid 0 with a full
capability set, which is exactly what `nft` and `dnsmasq` need and the payload
does not.

```
launch.sh          (pasta ns, privileged)
    ip link set lo up
    nft -f rules.nft                  # hard-fail, as today
    dnsmasq … &                       # outside the sandbox's PID and mount ns
    readiness probe
    bwrap --cap-drop ALL --cap-add CAP_SETPCAP --die-with-parent …
          <mux> -c sock wrapper.sh
    trap: kill dnsmasq

wrapper.sh         (sandbox, unprivileged)
    exec setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all \
        -- <command>
```

**Why `CAP_SETPCAP` is retained.** bwrap zeroes every capability set when it
*creates* the user namespace, but leaves all of them full when it *joins* one —
which is what the `--net` path does, since pasta creates the namespace. So
`--cap-drop ALL` is required for net mode, and there it zeroes the effective
set while leaving `CapBnd` full. `setpriv` empties the bounding set, but
dropping bounding bits itself requires `CAP_SETPCAP`: a plain `--cap-drop ALL`
takes away the very privilege `setpriv` needs, and the wrapper dies with
`setpriv: apply bounding set: Operation not permitted`, exit 127, in *every*
session.

Retaining exactly `CAP_SETPCAP` resolves it. Measured on bubblewrap 0.11.2,
both modes reach `CapEff=0 CapBnd=0` with `ro` remount and `nft flush` both
denied. `CAP_SETPCAP` cannot mount, configure networking, or change ownership,
so holding it across the single exec into `setpriv` is not an escape surface,
and a missing or failing `setpriv` fails closed — the payload never runs.

Consequences beyond the capability drop itself:

- The firewall and the resolver are not merely unwritable from the sandbox,
  they are unreachable — dnsmasq is outside its PID namespace and cannot be
  signalled.
- Setup failures print before the session multiplexer starts, so they land on
  the user's terminal instead of inside a detachable session that then exits.
- The `_CONTAINERS_USERNS_CONFIGURED` / `_CONTAINERS_ROOTLESS_*` overrides
  exist only because `--cap-add ALL` made podman believe it was real root.
  They move under the cap-retaining branch.

No-net mode already lands capless; it takes the same flags for uniformity.

**Readiness probe.** The existing `getent ahostsv4` check must query the
session's dnsmasq, but `launch.sh` sees the host `/etc/resolv.conf`. The probe
runs inside a minimal `bwrap --ro-bind "$DNS_DIR/resolv.conf" /etc/resolv.conf`
invocation, reusing a tool already required, so all setup failures stay
pre-session.

### Capability retention (opt-in)

Container workloads need nested user namespaces and therefore capabilities. A
new profile field `"caps": "keep"` requests them; `"userns": "full"` implies it.
`fs/podman.json` and `fs/podman-full.json` both set it.

Retention is honoured only from host-owned profiles — `$HOME/.config/sbx` and
the sbx install directory. A `./.sbx` profile requesting `caps` or `userns` is
rejected outright, regardless of confirmation, so a repository can never talk
its way back to the old boundary.

Any session that retains capabilities prints one line at launch:

```
Warning: profile 'podman' retains capabilities — this session's ro mounts and
egress firewall are NOT enforceable against code running inside it.
```

### Environment

`--clearenv` is emitted unconditionally. There is no flag to disable it and no
launch path without it. Variables are then set in this order, later winning:

1. **Base set**, forwarded from the host:
   `HOME USER LOGNAME TERM COLORTERM LANG LC_* TZ SHELL`
2. **Profile `"passthrough": ["VAR", …]`** — new field on cli and fs profiles,
   forwarding named host variables by name only
3. **Profile `"env"`** — existing behaviour, unchanged
4. **sbx-controlled** — `PATH`, `XDG_RUNTIME_DIR`, `CONTAINERS_*`,
   `DOCKER_HOST`, `DISPLAY`, `XAUTHORITY`

Secrets reach a sandbox only when a profile names them.

### Mount integrity

The mount code is unchanged: `ro` becomes truthful for free once capabilities
are gone. Two masks are appended **after** all profile mounts, so that no
profile can re-expose them by mounting a parent directory:

- `--tmpfs "$STATE_DIR"` followed by `--bind "$SESSION_DIR" "$SESSION_DIR"` —
  the sandbox sees its own session and nothing else: no sibling sessions, no
  persistent cli stores.
- `--tmpfs "$CONFIG_DIR"` — a sandbox must not author the profiles that
  configure the next launch.

Ordering matters because bwrap applies mount arguments sequentially.

### Network

`--no-map-gw` is added to both pasta invocations, closing the
gateway-to-host-loopback path. The nftables rules and dnsmasq flags are
otherwise unchanged; they simply become enforceable.

### Project-profile confirmation

When a resolved profile path lies under `./.sbx/profiles/`, sbx prints the path
and the profile body, then prompts:

```
Use this project profile? [y/N]
```

If the file is tracked in a repository that has a remote — `git ls-files
--error-unmatch <path>` succeeds and `git remote get-url` returns a URL — the
prompt is preceded by:

```
This profile is checked into a repo with remote <url> — it was authored by
whoever wrote that repository, not by you.
```

Non-interactive stdin refuses rather than defaulting to yes.
`SBX_TRUST_PROJECT_PROFILES=1` is the scripting escape hatch. Independently of
confirmation, project profiles may not set `caps`, `userns`, or `docker_api`.

### Shipped profile changes

- `cli/claude.json`: `$HOME/.local` and `$HOME/.nvm` change from `rw` to `ro`.
  `$HOME/.npm` stays `rw` as a build cache. Starting restrictive by intent:
  narrow `rw` or `copy` mounts get added for whatever actually breaks.
- `fs/podman.json`, `fs/podman-full.json`: add `"caps": "keep"`.

### Smaller fixes

- `--die-with-parent` on bwrap.
- Record `pid` in `session.json` so `--list-sessions` reports accurately.
- Strip control characters from `session.json` values before echoing them in
  `--list-sessions`, since the file is sandbox-writable.

## Testing

Extending the existing bats suites in `tests/`, honouring the short-`HOME`
requirement for e2e sandbox launches and keeping the shellcheck gate green.

- **Capabilities** — launch a real session and assert `CapEff=0`, that
  remounting a `ro` mount rw fails, and that `nft flush ruleset` fails.
- **Capability retention** — a profile with `"caps": "keep"` yields a non-zero
  `CapEff` and prints the warning; a `./.sbx` profile setting `caps` is
  rejected.
- **Environment** — a host `SBX_TEST_SECRET` is absent inside; a profile
  `passthrough` entry arrives; the base set is present.
- **Masks** — `$STATE_DIR` inside contains only the current session;
  `$CONFIG_DIR` is empty.
- **Project profiles** — a non-interactive launch against a `./.sbx` profile
  refuses; `SBX_TRUST_PROJECT_PROFILES=1` proceeds.
- **Regression** — existing copy-mount and persistent-cli suites stay green.
  Note that `--clearenv` does not affect profile `envsubst` expansion: that
  runs on the host inside sbx, before any bwrap argument is built.

## Residual risks

Documented deliberately rather than fixed:

- **`"caps": "keep"` sessions retain the pre-hardening boundary.** In those
  sessions `ro` mounts are writable and the firewall is removable. This is the
  accepted cost of supporting podman, which structurally requires nested user
  namespaces.
- **No seccomp filter.** `bwrap --seccomp` requires a compiled BPF blob, which
  is precisely the custom code this project refuses. Kernel syscall surface
  remains broad.
- **Wildcard `allow` entries** such as `*.anthropic.com` admit any IP address
  an attacker can publish under that suffix, via dnsmasq's `--nftset`
  population.
- **DNS remains an exfiltration channel** — query labels for allowed domains
  are forwarded upstream.
- **`"ports": ["*"]` is retained** in `net/anthropic.json` and
  `net/gemini.json`. Narrowing to 443 would break `git push` over SSH to
  `github.com`, which those profiles plainly expect. Any allowed IP stays
  reachable on any port.
- **Copy-mount write-back** carries sandbox-authored content into the
  persistent store, which the next session from the same directory re-seeds.
