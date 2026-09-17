#!/bin/bash
if ! tmux -f @ROOT@/h/.local/state/sbx/sessions/proj/tmux.conf -S @ROOT@/h/.local/state/sbx/sessions/proj/tmux.sock \
    new-session -d -s main -- @ROOT@/h/.local/state/sbx/sessions/proj/wrapper.sh; then
    echo "sbx: the in-sandbox tmux server failed to start; the payload did not run." >&2
    exit 1
fi
tmux -S @ROOT@/h/.local/state/sbx/sessions/proj/tmux.sock attach -t main || true
while tmux -S @ROOT@/h/.local/state/sbx/sessions/proj/tmux.sock list-sessions >/dev/null 2>&1; do
    sleep 0.5
done
