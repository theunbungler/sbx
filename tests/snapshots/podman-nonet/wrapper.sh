#!/bin/bash

mkdir -p "/run/user/@UID@/podman"
podman system service --time=0 "unix:///run/user/@UID@/podman/podman.sock" > "@ROOT@/h/.local/state/sbx/sessions/proj/podman-api.log" 2>&1 &
PODMAN_API_PID=$!
for i in {1..10}; do
    [[ -S "/run/user/@UID@/podman/podman.sock" ]] && break
    sleep 0.5
done
if [[ ! -S "/run/user/@UID@/podman/podman.sock" ]]; then
    echo "Warning: podman API socket did not appear at /run/user/@UID@/podman/podman.sock; docker SDK clients will fail (the docker CLI shim still works)." >&2
    cat "@ROOT@/h/.local/state/sbx/sessions/proj/podman-api.log" >&2 || true
fi
/bin/true 
[[ -n "$PODMAN_API_PID" ]] && kill $PODMAN_API_PID 2>/dev/null || true
