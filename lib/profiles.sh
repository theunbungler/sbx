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
#
# That lexical match only helps a caller who passes the relative
# "./.sbx/..." form, though (as sbx_profile_resolve does). A caller who
# passes an absolute path to the same symlinked file — e.g.
# "$PWD/.sbx/profiles/fs/evil.json" — has no such prefix, and realpath -m
# on the full path still follows the symlink's final component out of
# .sbx, misclassifying it as "path" and skipping the restricted-field
# check either way. So there's a third test: resolve the path's PARENT
# directory only (dirname), never following the final component, and
# check whether THAT lies at or under <launch_dir>/.sbx. A symlink can
# only escape via its own final component, not via its containing
# directory, so this catches the absolute-path case without being fooled
# by a symlinked ancestor directory.
sbx_profile_origin() {   # <path> <launch_dir> <config_dir> <global_dir>
    local abs sbx_abs parent_abs
    abs=$(realpath -m "$1")
    sbx_abs=$(realpath -m "$2/.sbx")
    parent_abs=$(realpath -m "$(dirname "$1")")
    if [[ "$abs" == "$sbx_abs/"* || "$1" == "./.sbx/"* || \
          "$parent_abs" == "$sbx_abs" || "$parent_abs" == "$sbx_abs/"* ]]; then
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
# outside its directory.
sbx_profile_valid_name() {   # <name>
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]
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
