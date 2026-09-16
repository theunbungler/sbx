#!/bin/bash
# Dependency table and host checks, shared by sbx's launch preflight and
# `sbx --doctor`.
#
# Sourced by sbx and directly by tests/. Defines functions and one table
# only — no side effects at source time, no dependency on sbx globals.
# Uses bash builtins plus awk and nothing else: this file is what reports
# that the rest of the toolchain is missing.

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
    # shellcheck disable=SC2086  # ID_LIKE is a space-separated list
    for word in $id $like; do
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
