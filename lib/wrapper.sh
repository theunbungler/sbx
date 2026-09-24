#!/bin/bash
# The payload, as the in-sandbox tmux server starts it. sbx copies this into
# the session directory beside wrapper.env (variables) and command (the
# payload's argv, NUL-separated).
#
# A capless session just execs the command: it is already capless, since
# the drop happens once in launch.sh above session.sh. The podman steps
# below need capabilities, so only a "caps": "keep" session runs them.

dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=/dev/null
source "$dir/wrapper.env"
mapfile -d '' -t cmd < "$dir/command"

if [[ "$CAPS_KEEP" != "true" ]]; then
    exec "${cmd[@]}"
fi

# userns: full — the DNS-enabled network containers.conf names as the
# default. Created under the bootstrap config (no [network] section), since
# podman creates the default network itself with DNS off otherwise. A repeat
# "already exists" is expected; a real failure surfaces when a container
# runs, and its stderr is kept here.
if [[ "$USERNS_FULL" == "true" ]]; then
    CONTAINERS_CONF="$VIRT_DIR/containers-bootstrap.conf" podman network create sbx0 \
        >/dev/null 2>> "$VIRT_DIR/network-create.log" || true
fi

# "docker_api": true — a warning, not fatal, if it does not come up: the
# docker CLI shim works without it.
if [[ "$DOCKER_API" == "true" ]]; then
    mkdir -p "${PODMAN_SOCK%/*}"
    podman system service --time=0 "unix://$PODMAN_SOCK" > "$dir/podman-api.log" 2>&1 &
    podman_api_pid=$!
    for _ in {1..10}; do
        [[ -S "$PODMAN_SOCK" ]] && break
        sleep 0.5
    done
    if [[ ! -S "$PODMAN_SOCK" ]]; then
        echo "Warning: podman API socket did not appear at $PODMAN_SOCK; docker SDK clients will fail (the docker CLI shim still works)." >&2
        cat "$dir/podman-api.log" >&2 || true
    fi
fi

"${cmd[@]}"
status=$?
if [[ -n "${podman_api_pid:-}" ]]; then
    kill "$podman_api_pid" 2>/dev/null || true
fi
exit "$status"
