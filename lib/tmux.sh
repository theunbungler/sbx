#!/bin/bash
# The in-sandbox tmux's prefix keys.
#
# Sourced by sbx and directly by tests/. Defines functions only — no side
# effects at source time, no dependency on sbx globals.
#
# C-\ is always a prefix, so it is the one key that works everywhere. C-b is
# one too, unless the terminal the client opens in is itself inside a host
# tmux, which keeps C-b. prefix and prefix2 are session options, so each
# launch, --join and --attach chooses for the session it opens.

# Prints "<prefix> <prefix2>" for a client opened where $TMUX is <tmux>.
sbx_tmux_prefixes() {   # <value of $TMUX, empty if unset>
    if [[ -n "$1" ]]; then
        printf '%s\n' 'C-\ None'
    else
        printf '%s\n' 'C-b C-\'
    fi
}

# The tmux command-line arguments that set those prefixes on the session
# <target> (empty: the client's current one), to append after another
# command. They follow it, never precede it: a session must exist first.
sbx_tmux_prefix_args() {   # <value of $TMUX> [target session]
    local prefix prefix2
    local -a target=()
    read -r prefix prefix2 <<< "$(sbx_tmux_prefixes "$1")"
    if [[ -n "${2-}" ]]; then
        target=(-t "$2")
    fi
    printf '%s\0' ';' set-option "${target[@]}" prefix "$prefix" \
                  ';' set-option "${target[@]}" prefix2 "$prefix2"
}
