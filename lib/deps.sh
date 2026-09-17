#!/bin/bash
# Dependency table and host checks, shared by sbx's launch preflight and
# `sbx --doctor`.
#
# Sourced by sbx and directly by tests/. Defines functions and one table
# only — no side effects at source time, no dependency on sbx globals.
# Contract: bash builtins plus awk and id — this file is what reports that
# the rest of the toolchain is missing. The userns diagnosis path
# (sbx_deps_userns_explain and its helpers) additionally uses realpath and
# stat, both core tools, and runs bwrap itself as the probe.

# tool       group   arch        debian        fedora
SBX_DEPS=(
    "bwrap      core    bubblewrap  bubblewrap    bubblewrap"
    "tmux       core    tmux        tmux          tmux"
    "jq         core    jq          jq            jq"
    "envsubst   core    gettext     gettext-base  gettext-envsubst"
    "setpriv    core    util-linux  util-linux    util-linux-core"
    "flock      core    util-linux  util-linux    util-linux-core"
    "realpath   core    coreutils   coreutils     coreutils"
    "sha256sum  core    coreutils   coreutils     coreutils"
    "ip         core    iproute2    iproute2      iproute"
    "pasta      net     passt       passt         passt"
    "nft        net     nftables    nftables      nftables"
    "dnsmasq    net     dnsmasq     dnsmasq       dnsmasq"
    "xpra       gui     xpra        xpra          xpra"
    "podman     podman  podman      podman        podman"
    "newuidmap  podman  shadow      uidmap        shadow-utils"
    "unshare    podman  util-linux  util-linux    util-linux-core"
)

# Map /etc/os-release to a package family. ID is tried before ID_LIKE, so
# a derivative that names itself (manjaro) and its parent (arch) resolves
# the same either way.
sbx_deps_family() {
    local file="${SBX_OS_RELEASE:-/etc/os-release}" key val id="" like="" word
    local -a words
    if [[ -r "$file" ]]; then
        while IFS='=' read -r key val || [[ -n "$key" ]]; do
            val="${val#[\"\']}"
            val="${val%[\"\']}"
            case "$key" in
                ID)      id="$val" ;;
                ID_LIKE) like="$val" ;;
            esac
        done < "$file"
    fi
    read -ra words <<< "$id $like"
    for word in "${words[@]}"; do
        case "$word" in
            arch|manjaro|endeavouros|garuda|artix)           echo arch;   return 0 ;;
            debian|ubuntu|linuxmint|pop|raspbian|kali)       echo debian; return 0 ;;
            fedora|rhel|centos|rocky|almalinux|ol)           echo fedora; return 0 ;;
        esac
    done
    echo unknown
}

sbx_deps_tools() {
    local row tool group rest g
    for row in "${SBX_DEPS[@]}"; do
        read -r tool group rest <<< "$row"
        for g in "$@"; do
            [[ "$group" == "$g" ]] && echo "$tool"
        done
    done
    return 0
}

sbx_deps_missing() {
    local tool
    while IFS= read -r tool; do
        command -v "$tool" >/dev/null 2>&1 || echo "$tool"
    done < <(sbx_deps_tools "$@")
    return 0
}

sbx_deps_packages() {
    local family="$1"; shift
    local want row tool group arch debian fedora pkg seen=" "
    for want in "$@"; do
        for row in "${SBX_DEPS[@]}"; do
            read -r tool group arch debian fedora <<< "$row"
            [[ "$tool" == "$want" ]] || continue
            case "$family" in
                arch)   pkg="$arch" ;;
                debian) pkg="$debian" ;;
                fedora) pkg="$fedora" ;;
                *)      return 1 ;;
            esac
            if [[ "$seen" != *" $pkg "* ]]; then
                echo "$pkg"
                seen+="$pkg "
            fi
        done
    done
    return 0
}

sbx_deps_package_manager() {
    case "$1" in
        arch)   echo "sudo pacman -S" ;;
        debian) echo "sudo apt install" ;;
        fedora) echo "sudo dnf install" ;;
    esac
}

sbx_deps_install_hint() {
    local family="$1"; shift
    local f
    local -a pkgs
    case "$family" in
        arch|debian|fedora)
            mapfile -t pkgs < <(sbx_deps_packages "$family" "$@")
            echo "$(sbx_deps_package_manager "$family") ${pkgs[*]}"
            ;;
        *)
            for f in arch debian fedora; do
                mapfile -t pkgs < <(sbx_deps_packages "$f" "$@")
                printf '%-7s %s %s\n' "$f:" "$(sbx_deps_package_manager "$f")" "${pkgs[*]}"
            done
            ;;
    esac
}

# Read one sysctl value, or nothing if the knob does not exist on this
# kernel (unprivileged_userns_clone is a Debian/Arch patch, the AppArmor
# knob is Ubuntu's).
sbx_deps_sysctl() {
    local v=""
    read -r v < "${SBX_PROC_SYS:-/proc/sys}/$1" 2>/dev/null || true
    echo "$v"
}

# Resolve the bwrap path used ONLY by the AppArmor explain text below (never
# by the probe itself). SBX_BWRAP_PATH overrides for tests; otherwise resolve
# `command -v bwrap` through realpath so a symlink or a PATH-shadowing copy
# (e.g. from a project .envrc) doesn't get named in a profile meant to be
# installed as root. Falls back to /usr/bin/bwrap if realpath is unavailable.
sbx_deps_bwrap_path() {
    if [[ -n "${SBX_BWRAP_PATH:-}" ]]; then
        echo "$SBX_BWRAP_PATH"
        return 0
    fi
    local raw
    raw=$(command -v bwrap || echo /usr/bin/bwrap)
    if command -v realpath >/dev/null 2>&1; then
        realpath "$raw" 2>/dev/null || echo "$raw"
    else
        echo /usr/bin/bwrap
    fi
}

# True if $1 is owned by root and lives under /usr/ or /bin/ — the bar for
# naming it in an AppArmor profile that will be installed as root. `[[ -O ]]`
# is the wrong check (it tests the invoking user, not root); use `stat`
# instead, and treat an unreadable/unavailable `stat` as untrusted.
sbx_deps_bwrap_trusted() {
    local path="$1" owner
    command -v stat >/dev/null 2>&1 || return 1
    owner=$(stat -c %u "$path" 2>/dev/null) || return 1
    [[ "$owner" == "0" ]] || return 1
    [[ "$path" == /usr/* || "$path" == /bin/* ]] || return 1
    return 0
}

sbx_deps_userns_explain() {
    local bwrap_err="$1" bw extra_dir
    if [[ "$(sbx_deps_sysctl kernel/apparmor_restrict_unprivileged_userns)" == "1" ]]; then
        bw=$(sbx_deps_bwrap_path)
        printf '%s\n' \
            "Cause: AppArmor restricts unprivileged user namespaces" \
            "  (kernel.apparmor_restrict_unprivileged_userns = 1, the Ubuntu 24.04+ default)."
        if ! sbx_deps_bwrap_trusted "$bw"; then
            printf '%s\n' \
                "Warning: bwrap resolves to \"$bw\", which is not a root-owned system binary." \
                "  sbx will not suggest an AppArmor exemption for it." \
                "bwrap reported: $bwrap_err"
            return 0
        fi
        extra_dir="${SBX_APPARMOR_EXTRA:-/usr/share/apparmor/extra-profiles}"
        if [[ -e "$extra_dir/bwrap-userns-restrict" ]]; then
            printf '%s\n' \
                "Fix: apply Ubuntu's own bwrap-userns-restrict profile. As root:" \
                "" \
                "  sudo install -m 644 $extra_dir/bwrap-userns-restrict /etc/apparmor.d/" \
                "  sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict"
        else
            printf '%s\n' \
                "Note: this lets any local user create user namespaces through bwrap, which is what Ubuntu's restriction exists to limit." \
                "Fix: allow bwrap to create them. As root, create /etc/apparmor.d/sbx-bwrap:" \
                "" \
                "  abi <abi/4.0>," \
                "  include <tunables/global>" \
                "" \
                "  profile sbx-bwrap $bw flags=(unconfined) {" \
                "    userns," \
                "  }" \
                "" \
                "then load it:  sudo apparmor_parser -r /etc/apparmor.d/sbx-bwrap"
        fi
        printf '%s\n' \
            "If --net sessions still fail, pasta may need the same allowance (not yet verified on Ubuntu)." \
            "bwrap reported: $bwrap_err"
        return 0
    fi
    if [[ "$(sbx_deps_sysctl kernel/unprivileged_userns_clone)" == "0" ]]; then
        printf '%s\n' \
            "Cause: the kernel disallows unprivileged user namespaces" \
            "  (kernel.unprivileged_userns_clone = 0)." \
            "Fix:  sudo sysctl -w kernel.unprivileged_userns_clone=1" \
            "  To keep it across reboots:" \
            "  echo 'kernel.unprivileged_userns_clone = 1' | sudo tee /etc/sysctl.d/90-sbx-userns-clone.conf" \
            "bwrap reported: $bwrap_err"
        return 0
    fi
    if [[ "$(sbx_deps_sysctl user/max_user_namespaces)" == "0" ]]; then
        printf '%s\n' \
            "Cause: user namespaces are capped at zero (user.max_user_namespaces = 0)." \
            "Fix:  sudo sysctl -w user.max_user_namespaces=10000" \
            "  To keep it across reboots:" \
            "  echo 'user.max_user_namespaces = 10000' | sudo tee /etc/sysctl.d/90-sbx-max-userns.conf" \
            "bwrap reported: $bwrap_err"
        return 0
    fi
    echo "Cause: not one sbx recognises. bwrap reported:"
    echo "  $bwrap_err"
}

sbx_deps_userns_check() {
    local err
    if err=$(bwrap --unshare-user --ro-bind / / true 2>&1 >/dev/null); then
        return 0
    fi
    echo "Error: bwrap cannot create an unprivileged user namespace, which every sbx session needs."
    sbx_deps_userns_explain "$err"
    return 1
}

# userns: full maps the user's subordinate range through newuidmap, which
# refuses outright without an entry. Entries may name the user or the UID.
sbx_deps_subids_ok() {
    local user uid f
    user=$(id -un)
    uid=$(id -u)
    for f in "${SBX_SUBUID:-/etc/subuid}" "${SBX_SUBGID:-/etc/subgid}"; do
        awk -F: -v u="$user" -v i="$uid" '$1 == u || $1 == i { found = 1 } END { exit !found }' "$f" 2>/dev/null \
            || return 1
    done
    return 0
}

sbx_deps_require() {
    local -a missing
    local line
    mapfile -t missing < <(sbx_deps_missing "$@")
    if [[ ${#missing[@]} -gt 0 ]]; then
        {
            if [[ ${#missing[@]} -eq 1 ]]; then
                echo "Error: sbx requires ${missing[0]}, which is not on PATH."
            else
                echo "Error: sbx requires ${missing[*]}, which are not on PATH."
            fi
            echo "  Install with:"
            while IFS= read -r line; do
                echo "    $line"
            done < <(sbx_deps_install_hint "$(sbx_deps_family)" "${missing[@]}")
        } >&2
        return 1
    fi
    if [[ " $* " == *" core "* ]]; then
        sbx_deps_userns_check >&2 || return 1
    fi
    return 0
}

sbx_deps_json_list() {
    local first=1 x
    printf '['
    for x in "$@"; do
        [[ $first -eq 1 ]] || printf ','
        printf '"%s"' "$x"
        first=0
    done
    printf ']'
}

sbx_deps_doctor() {
    local json=false
    [[ "${1:-}" == "--json" ]] && json=true

    local family group rc=0 userns=null userns_msg="" subids=false user line
    local -a missing tools all_missing=() hint=()
    local -A group_missing=()

    family=$(sbx_deps_family)
    user=$(id -un)
    for group in core net gui podman; do
        mapfile -t missing < <(sbx_deps_missing "$group")
        group_missing[$group]="${missing[*]}"
        all_missing+=("${missing[@]}")
    done
    if [[ -n "${group_missing[core]}" ]]; then
        rc=1
    fi
    if command -v bwrap >/dev/null 2>&1; then
        if userns_msg=$(sbx_deps_userns_check); then
            userns=true
        else
            userns=false
            rc=1
        fi
    fi
    if sbx_deps_subids_ok; then
        subids=true
    fi
    if [[ ${#all_missing[@]} -gt 0 ]]; then
        mapfile -t hint < <(sbx_deps_install_hint "$family" "${all_missing[@]}")
    fi

    if $json; then
        printf '{"family":"%s","ok":%s,"groups":{' "$family" "$([[ $rc -eq 0 ]] && echo true || echo false)"
        local first=1
        for group in core net gui podman; do
            [[ $first -eq 1 ]] || printf ','
            # shellcheck disable=SC2086  # the stored list is space-separated
            printf '"%s":%s' "$group" "$(sbx_deps_json_list ${group_missing[$group]})"
            first=0
        done
        printf '},"userns":%s,"subids":%s,"install":%s}\n' "$userns" "$subids" "$(sbx_deps_json_list "${hint[@]}")"
        return $rc
    fi

    echo "sbx doctor — distro family: $family"
    echo
    for group in core net gui podman; do
        if [[ -z "${group_missing[$group]}" ]]; then
            mapfile -t tools < <(sbx_deps_tools "$group")
            printf '%-8s ✓ %s\n' "$group" "${tools[*]}"
        else
            printf '%-8s ✗ missing: %s\n' "$group" "${group_missing[$group]}"
        fi
        case "$group" in
            core)
                case "$userns" in
                    true)  echo "         ✓ unprivileged user namespaces" ;;
                    null)  echo "         ? unprivileged user namespaces (needs bwrap)" ;;
                    false)
                        echo "         ✗ unprivileged user namespaces"
                        while IFS= read -r line; do
                            echo "           $line"
                        done <<< "$userns_msg"
                        ;;
                esac
                ;;
            podman)
                if [[ "$subids" == "false" ]]; then
                    echo "         ✗ no subordinate UID/GID range for $user (needed by \"userns\": \"full\")"
                    echo "           sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $user"
                    echo "           (choose a range not already used by another user in /etc/subuid)"
                fi
                ;;
        esac
    done
    if [[ ${#hint[@]} -gt 0 ]]; then
        echo
        echo "Install missing packages:"
        for line in "${hint[@]}"; do
            echo "  $line"
        done
    fi
    return $rc
}
