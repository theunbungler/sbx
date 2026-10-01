#!/bin/bash
# sudo, inside a session whose payload runs as the user (the plan's
# security.identity "user"). sbx copies this to $SESSION_DIR/bin/sudo.
#
# The real sudo cannot work in any session: no_new_privs makes the kernel
# ignore its setuid bit, and host root is unmapped, so sudo and its config
# appear owned by nobody. What a "must be root" check wants is uid 0, and
# any process may have that in a nested user namespace of its own; this
# runs the command there. It grants nothing: ro mounts stay read-only, the
# firewall stays outside the payload namespace, and what the command
# writes is owned by the user on the host.
#
# Options that only matter to a real sudo are accepted and ignored, so
# scripts keep working; ones that would change what runs (another user, a
# group, an editor) are refused rather than guessed at.

usage() {
    echo "usage: sudo [-EHKknS] [-p prompt] [-u root] [-i | -s] [--] command [args...]" >&2
    exit 1
}

user_ok() {   # <user>
    case "$1" in
        root|0|'#0') return 0 ;;
    esac
    echo "sudo: only root is available in sbx (asked for '$1')." >&2
    exit 1
}

shell=false list=false validate=false reset=false
while [[ $# -gt 0 && "$1" == -* ]]; do
    opt="$1"
    shift
    case "$opt" in
        --) break ;;
        --preserve-env|--preserve-env=*|--non-interactive|--stdin|--set-home|--reset-timestamp)
            continue ;;
        --login|--shell) shell=true; continue ;;
        --user=*) user_ok "${opt#--user=}"; continue ;;
        --*) echo "sudo: option $opt is not supported in sbx." >&2; exit 1 ;;
    esac
    # A cluster of short options, e.g. -En or -uroot.
    i=1
    while (( i < ${#opt} )); do
        c="${opt:i:1}"
        rest="${opt:i+1}"
        case "$c" in
            E|H|n|S) ;;
            k|K) reset=true ;;
            i|s) shell=true ;;
            l) list=true ;;
            v) validate=true ;;
            u|p)
                if [[ -z "$rest" ]]; then
                    [[ $# -gt 0 ]] || usage
                    rest="$1"
                    shift
                fi
                [[ "$c" == u ]] && user_ok "$rest"
                break ;;
            *) echo "sudo: option -$c is not supported in sbx." >&2; exit 1 ;;
        esac
        i=$((i + 1))
    done
done

if [[ "$list" == "true" ]]; then
    echo "sbx: sudo runs commands as namespace root (uid 0 in a nested user namespace); it grants no real privilege."
    exit 0
fi

sh="${SHELL:-/bin/sh}"
if [[ $# -eq 0 ]]; then
    if [[ "$shell" == "true" ]]; then
        exec unshare --map-root-user -- "$sh"
    fi
    if [[ "$validate" == "true" || "$reset" == "true" ]]; then
        exit 0
    fi
    usage
fi
if [[ "$shell" == "true" ]]; then
    exec unshare --map-root-user -- "$sh" -c "$*"
fi
exec unshare --map-root-user -- "$@"
