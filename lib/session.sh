#!/bin/bash
# PID 1 inside the sandbox. sbx copies this into the session directory,
# which is the one host path bound into every sandbox; tmux.conf, tmux.sock
# and wrapper.sh are its neighbours there.
#
# bwrap waits on this script, not on the tmux server (which daemonizes) or
# the payload, and that is the session-lifetime rule: it stays until the
# server is gone, which with exit-empty on means the last session — payload
# or join, whichever ends last — has exited. Only then does bwrap return and
# teardown archive the record mounts. Its liveness test is the socket, so
# the payload can end its own sandbox early (delete the socket, or
# `tmux kill-server`); that also destroys the pid namespace any join runs
# in. The case this cannot cover — sbx itself killed while the sandbox runs
# — is what the host-side join lock in teardown is for.
#
# No `set -e`: attach fails harmlessly when the payload has already exited.
# A server that never started is a different failure and is reported.

dir="${BASH_SOURCE[0]%/*}"

# The capability drop ran just before this, under any --seccomp filter
# bwrap loaded first, and a filter can make a call report success without
# running it. So check the result, not the exit status: a capless session
# starts only with an empty bounding set. A read the filter fakes leaves
# capbnd empty, which refuses too.
# shellcheck source=/dev/null
source "$dir/wrapper.env"
if [[ "$CAPS_KEEP" != "true" ]]; then
    capbnd=""
    while read -r key value; do
        if [[ "$key" == "CapBnd:" ]]; then
            capbnd="$value"
        fi
    done < /proc/self/status
    if [[ "$capbnd" != "0000000000000000" ]]; then
        echo "sbx: the capability bounding set is not empty (${capbnd:-unreadable}); refusing to start. A --seccomp filter that fakes success for prctl or capset does this." >&2
        exit 1
    fi
fi
if ! tmux -f "$dir/tmux.conf" -S "$dir/tmux.sock" new-session -d -s main -- "$dir/wrapper.sh"; then
    echo "sbx: the in-sandbox tmux server failed to start; the payload did not run." >&2
    exit 1
fi
tmux -S "$dir/tmux.sock" attach -t main || true
while tmux -S "$dir/tmux.sock" list-sessions >/dev/null 2>&1; do
    sleep 0.5
done
