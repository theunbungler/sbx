#!/bin/bash
# X11 display sockets on the host, for the xpra display behind --gui.
#
# Sourced by sbx and directly by tests/. Defines functions only — no side
# effects at source time, no dependency on sbx globals.
#
# An X server listens twice: on the file /tmp/.X11-unix/X<N> and on the
# abstract socket @/tmp/.X11-unix/X<N>. Where /tmp/.X11-unix is read-only
# (WSLg mounts it so) only the abstract one exists. That one belongs to the
# host's network namespace, which the sandbox does not share, and bwrap can
# only bind a file; so sbx relays it to a file socket with socat.

# Succeeds if display <N>'s abstract socket is listening. In /proc/net/unix
# a listener carries flag 00010000 (__SO_ACCEPTCON), and an abstract name
# a leading "@".
sbx_x11_abstract_listening() {   # <display number> [proc net unix file]
    local file="${2:-/proc/net/unix}"
    awk -v want="@/tmp/.X11-unix/X$1" \
        '$4 == "00010000" && $8 == want { found = 1 } END { exit !found }' "$file"
}

# Succeeds if display <N> is taken by any means: a file socket, an
# abstract socket, or an X server's lock file.
sbx_x11_display_taken() {   # <display number> [proc net unix file]
    [[ -S "/tmp/.X11-unix/X$1" || -e "/tmp/.X$1-lock" ]] \
        || sbx_x11_abstract_listening "$@"
}

# The command that attaches a viewer to the display. Under WSL2 the viewer
# runs on WSLg, where xpra's GTK client would pick Wayland (weak in xpra 3:
# no keyboard bindings) and its OpenGL probe fails; X11 and no OpenGL work.
sbx_x11_attach_cmd() {   # <display> <kernel release>
    if [[ "${2,,}" == *microsoft* ]]; then
        echo "GDK_BACKEND=x11 xpra attach $1 --opengl=no"
    else
        echo "xpra attach $1"
    fi
}
