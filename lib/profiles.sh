#!/bin/bash
# Profile lookup, origin classification and listing, shared by sbx and the
# resolve step.
#
# Sourced by sbx and directly by tests/. Defines functions only — no side
# effects at source time, no dependency on sbx globals: every directory is
# an argument.

# Find a profile by name. Precedence is project (./.sbx/profiles, relative
# to the current directory), then user, then global. A profile argument is
# a NAME, never a file path: the launch directory itself is never searched
# and a path (with a '/' beyond an optional type prefix, "..", an absolute
# path, or a ".json" suffix) is rejected outright, before any lookup, with
# the same failure behavior (message on stderr, return 1) callers under
# `set -e` already rely on for "not found".
sbx_profile_resolve() {   # <type> <name> <config_dir> <global_dir>
    local type="$1" arg="$2" config_dir="$3" global_dir="$4" name="$2" p clean

    # Strip the type prefix if it was included (e.g., "cli/dev" -> "dev")
    if [[ "$name" == "$type/"* ]]; then
        name="${name#"$type"/}"
    fi

    if [[ "$name" == *.json ]] || ! sbx_profile_valid_name "$name"; then
        clean=$(LC_ALL=C tr -cd '\11\40-\176' <<< "$arg")
        if [[ ${#clean} -gt 500 ]]; then
            clean="${clean:0:500}..."
        fi
        echo "Error: '$clean' is not a profile name. Profiles are loaded by name from ./.sbx/profiles, ~/.config/sbx/profiles or the global profiles directory." >&2
        return 1
    fi

    for p in "./.sbx/profiles/$type/$name.json" \
             "$config_dir/profiles/$type/$name.json" \
             "$global_dir/$type/$name.json"; do
        if [[ -f "$p" ]]; then
            echo "$p"
            return 0
        fi
    done

    echo "Error: Profile '$name' of type '$type' not found." >&2
    return 1
}

# Where a resolved profile came from. "project" is what matters for trust:
# a project profile arrived with the repository and is untrusted input.
#
# Classification is OR, not just realpath containment: a project profile
# that is itself a symlink (e.g. ./.sbx/profiles/fs/evil.json -> /elsewhere)
# resolves outside <launch_dir>/.sbx via realpath -m, which would otherwise
# read it as "path" origin and skip both the restricted-field validation
# and the trust prompt. Two more tests close that: a purely LEXICAL test
# (realpath -m -s, which normalizes "." and ".." but never follows a
# symlink) of $1 against a lexical .sbx — this is what catches a symlinked
# ancestor directory anywhere in the path (e.g. .sbx/profiles/fs itself
# being a symlink to /elsewhere), because it never resolves any component,
# symlinked or not — and a test of the fully-resolved $1 against that same
# lexical .sbx, which catches a symlink only in the path's final component
# (e.g. .sbx/profiles/fs/evil.json -> /elsewhere/x.json), since resolving
# only trips on the last component in that case. Neither test alone covers
# both shapes; together they do, without ever resolving .sbx itself (which
# would let a symlinked ancestor OUTSIDE .sbx smuggle an unrelated
# directory in under the same lexical prefix — not defended against here,
# since <launch_dir> is assumed to be a real directory, not attacker input).
# The literal "./.sbx/" prefix match on $1 is kept for the plain relative
# form sbx_profile_resolve always passes.
#
# With names-only resolution (see sbx_profile_resolve), a launch only ever
# passes the "./.sbx/...", "$config_dir/profiles/..." or "$global_dir/..."
# forms produced by that lookup, so the lexical/symlink distinction here
# only matters for a path a human hands to `sbx-profile check <path>`
# directly.
sbx_profile_origin() {   # <path> <launch_dir> <config_dir> <global_dir>
    local abs abs_lexical sbx_lexical
    abs=$(realpath -m "$1")
    abs_lexical=$(realpath -m -s "$1")
    sbx_lexical=$(realpath -m -s "$2/.sbx")
    if [[ "$abs_lexical" == "$sbx_lexical" || "$abs_lexical" == "$sbx_lexical/"* || \
          "$abs" == "$sbx_lexical" || "$abs" == "$sbx_lexical/"* || \
          "$1" == "./.sbx/"* ]]; then
        echo project
    elif [[ "$abs" == "$(realpath -m "$3/profiles")/"* ]]; then
        echo user
    elif [[ "$abs" == "$(realpath -m "$4")/"* ]]; then
        echo global
    else
        echo path
    fi
}

sbx_profile_list() {   # <config_dir> <global_dir>
    local config_dir="$1" global_dir="$2"
    local type src label path files profile found shown
    local -A seen
    local sources=(
        "Project:./.sbx/profiles"
        "User:$config_dir/profiles"
        "Global:$global_dir"
    )

    echo "Available Profiles:"
    for type in cli fs net; do
        echo ""
        echo "${type^^} Profiles:"
        found=0
        seen=()
        for src in "${sources[@]}"; do
            label="${src%%:*}"
            path="${src#*:}"
            if [[ -d "$path/$type" ]]; then
                files=$(find "$path/$type" -name "*.json" | sed "s|$path/$type/||" | sed 's/\.json$//' | sort)
                if [[ -n "$files" ]]; then
                    while IFS= read -r profile; do
                        shown=$(LC_ALL=C tr -d '\000-\037\177' <<< "$profile")
                        if [[ -n "${seen[$profile]:-}" ]]; then
                            echo "  $shown ($label, shadowed by ${seen[$profile]})"
                        else
                            echo "  $shown ($label)"
                            seen[$profile]="$label"
                        fi
                        found=1
                    done <<< "$files"
                fi
            fi
        done
        if [[ $found -eq 0 ]]; then
            echo "  (none)"
        fi
    done
}

sbx_profile_valid_type() {   # <type>
    [[ "$1" == "cli" || "$1" == "fs" || "$1" == "net" ]]
}

# A profile name is one path component, so creating one can never write
# outside its directory. Capped at 200 characters so a write failure
# further down is never blamed on a filesystem name-length limit instead
# of on the name itself.
sbx_profile_valid_name() {   # <name>
    local name="$1"
    [[ ${#name} -le 200 && "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]
}

# The starting content for a new profile: valid, and granting nothing, so
# a template left unedited can never open access by accident.
sbx_profile_template() {   # <type> <description>
    case "$1" in
        cli) jq -n --indent 4 --arg d "$2" '{description: $d, env: {}, passthrough: [], mounts: []}' ;;
        fs)  jq -n --indent 4 --arg d "$2" '{description: $d, mounts: []}' ;;
        net) jq -n --indent 4 --arg d "$2" '{description: $d, dns: "1.1.1.1", allow: [], ports: [443]}' ;;
        *)   return 1 ;;
    esac
}

# Fields a project profile may not set. Same list as `restricted` in
# lib/profile-check.sh — keep the two in step.
sbx_profile_restricted_fields() {   # <file>
    jq -r '["caps", "userns", "docker_api", "host_ports"][] as $f | select(has($f)) | $f' "$1"
}

# Other locations holding the same <type>/<name>, relative to <location>.
# Precedence is project, then user, then global (see sbx_profile_resolve).
sbx_profile_shadowing() {   # <type> <name> <location> <config_dir> <global_dir>
    local type="$1" name="$2" location="$3" config_dir="$4" global_dir="$5" i mine=-1
    local -a labels=(project user global)
    local -a paths=("./.sbx/profiles/$type/$name.json"
                    "$config_dir/profiles/$type/$name.json"
                    "$global_dir/$type/$name.json")
    for i in 0 1 2; do
        if [[ "${labels[$i]}" == "$location" ]]; then
            mine=$i
        fi
    done
    for i in 0 1 2; do
        if [[ $i -eq $mine || ! -f "${paths[$i]}" ]]; then
            continue
        fi
        if [[ $i -lt $mine ]]; then
            echo "shadowed-by ${labels[$i]} ${paths[$i]}"
        else
            echo "shadows ${labels[$i]} ${paths[$i]}"
        fi
    done
    return 0
}
