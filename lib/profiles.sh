#!/bin/bash
# Profile lookup, origin classification and listing, shared by sbx and the
# resolve step.
#
# Sourced by sbx and directly by tests/. Defines functions only — no side
# effects at source time, no dependency on sbx globals: every directory is
# an argument.

# Find a profile by name. Precedence is project (./.sbx/profiles, relative
# to the current directory), then user, then global. A name that is itself
# a file path is used directly.
sbx_profile_resolve() {   # <type> <name> <config_dir> <global_dir>
    local type="$1" name="$2" config_dir="$3" global_dir="$4" p

    if [[ -f "$name" ]]; then
        realpath "$name"
        return 0
    fi
    if [[ -f "$name.json" ]]; then
        realpath "$name.json"
        return 0
    fi

    # Strip the type prefix if it was included (e.g., "cli/dev" -> "dev")
    if [[ "$name" == "$type/"* ]]; then
        name="${name#"$type"/}"
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
# and the trust prompt. sbx_profile_resolve only ever finds a project
# profile under the literal "./.sbx/" prefix, so matching that lexical
# form as well closes the symlink escape without following the link.
sbx_profile_origin() {   # <path> <launch_dir> <config_dir> <global_dir>
    local abs
    abs=$(realpath -m "$1")
    if [[ "$abs" == "$(realpath -m "$2/.sbx")/"* || "$1" == "./.sbx/"* ]]; then
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
    local type src label path files profile found
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
        for src in "${sources[@]}"; do
            label="${src%%:*}"
            path="${src#*:}"
            if [[ -d "$path/$type" ]]; then
                files=$(find "$path/$type" -name "*.json" | sed "s|$path/$type/||" | sed 's/\.json$//' | sort)
                if [[ -n "$files" ]]; then
                    while IFS= read -r profile; do
                        echo "  $profile ($label)"
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
