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
    "unshare    core    util-linux  util-linux    util-linux-core"
    "nsenter    core    util-linux  util-linux    util-linux-core"
    "realpath   core    coreutils   coreutils     coreutils"
    "sha256sum  core    coreutils   coreutils     coreutils"
    "ip         core    iproute2    iproute2      iproute"
    "pasta      net     passt       passt         passt"
    "nft        net     nftables    nftables      nftables"
    "dnsmasq    net     dnsmasq     dnsmasq       dnsmasq"
    "socat      net     socat       socat         socat"
    "xpra       gui     xpra        xpra          xpra"
    "podman     podman  podman      podman        podman"
    "newuidmap  podman  shadow      uidmap        shadow-utils"
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
    # Braced: a redirection's own failure is reported before a 2>/dev/null
    # on the same command takes effect.
    { read -r v < "${SBX_PROC_SYS:-/proc/sys}/$1"; } 2>/dev/null || true
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

# Shared remedy for a host whose policy forbids capabilities inside a bwrap
# user namespace, or namespace creation by unshare. On Ubuntu both come from
# AppArmor: bwrap's profile puts its children under "unpriv_bwrap", which
# carries `audit deny capability`, and an unconfined binary that creates a user
# namespace lands in "unprivileged_userns", which denies the capabilities that
# namespace then needs. A local/ include cannot relax either — AppArmor's deny
# always beats a later allow — so the profile has to be replaced. Measured on
# Ubuntu 26.04 (2026-09-23): with both allowances every sbx suite passes there.
sbx_deps_apparmor_remedy() {
    local bw
    bw=$(sbx_deps_bwrap_path)
    if [[ "$(sbx_deps_sysctl kernel/apparmor_restrict_unprivileged_userns)" != "1" ]]; then
        printf '%s\n' \
            "Fix: whatever forbids it on this host (AppArmor, SELinux, seccomp, or an outer" \
            "  container runtime) has to allow capabilities inside an unprivileged user" \
            "  namespace. sbx does not skip the drop: a session either gets that guarantee" \
            "  or does not start."
        return 0
    fi
    printf '%s\n' \
        "Cause: Ubuntu's AppArmor policy (kernel.apparmor_restrict_unprivileged_userns = 1)." \
        "  Its bwrap profile puts everything inside the sandbox under \"unpriv_bwrap\", which" \
        "  denies every capability, and confines binaries that create their own user" \
        "  namespace under \"unprivileged_userns\", which does the same. A local/ include" \
        "  cannot override those denials."
    if ! sbx_deps_bwrap_trusted "$bw"; then
        printf '%s\n' \
            "Warning: bwrap resolves to \"$bw\", which is not a root-owned system binary." \
            "  sbx will not suggest an AppArmor exemption for it."
        return 0
    fi
    printf '%s\n' \
        "Note: this re-allows capabilities inside EVERY bwrap sandbox on this machine," \
        "  which is what Ubuntu's restriction exists to prevent. Your call to make." \
        "Fix: as root, retire Ubuntu's bwrap profile:" \
        "" \
        "    sudo ln -sf /etc/apparmor.d/bwrap-userns-restrict /etc/apparmor.d/disable/" \
        "    sudo apparmor_parser -R /etc/apparmor.d/bwrap-userns-restrict" \
        "" \
        "  write /etc/apparmor.d/sbx-bwrap:" \
        "" \
        "    abi <abi/4.0>," \
        "    include <tunables/global>" \
        "    profile sbx-bwrap $bw flags=(unconfined) {" \
        "      userns," \
        "    }" \
        "" \
        "  write /etc/apparmor.d/sbx-unshare, the same but naming /usr/bin/unshare," \
        "  then load both:" \
        "" \
        "    sudo apparmor_parser -r /etc/apparmor.d/sbx-bwrap /etc/apparmor.d/sbx-unshare"
}

# Every session empties its capability bounding set with setpriv, which needs
# CAP_SETPCAP inside the sandbox; bwrap keeps exactly that one capability for
# it. Where the host forbids capabilities there, setpriv fails with "apply
# bounding set: Operation not permitted" and the session aborts with status
# 127, naming setpriv rather than the policy. Probe it as a launch does.
sbx_deps_caps_check() {
    local err
    # /bin/true, not "true": both binaries run without a shell, and a probe
    # must not depend on what is on PATH inside the sandbox it builds.
    if err=$(bwrap --ro-bind / / --unshare-user --cap-drop ALL --cap-add CAP_SETPCAP -- \
             setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all -- /bin/true 2>&1 >/dev/null); then
        return 0
    fi
    echo "Error: the capability bounding set cannot be emptied inside a sandbox, which every session does."
    echo "  It reported: $err"
    sbx_deps_apparmor_remedy
    return 1
}

# A session without networking, and every "userns": "full" session, creates its
# control namespace with unshare rather than pasta. A host that confines an
# unconfined binary for creating a user namespace then refuses the network
# namespace that goes with it ("unshare failed: Operation not permitted").
sbx_deps_nsunshare_check() {
    local err
    if err=$(unshare --user --map-root-user --net /bin/true 2>&1 >/dev/null); then
        return 0
    fi
    echo "Error: unshare cannot create a user and network namespace together, which a session"
    echo "  without networking — and every \"userns\": \"full\" session — needs."
    echo "  It reported: $err"
    sbx_deps_apparmor_remedy
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

sbx_deps_kernel_release() {
    local rel="${SBX_KERNEL_RELEASE:-}"
    if [[ -z "$rel" ]]; then
        read -r rel < /proc/sys/kernel/osrelease
    fi
    echo "$rel"
}

# Every networked session joins its payload namespace to the control
# namespace with a veth pair. veth is a kernel module, not a binary: the
# RUNNING kernel must have it loaded, built in, or in its module tree. After
# a kernel upgrade without a reboot the running kernel's tree is often gone,
# and `ip link add ... type veth` then fails with "Unknown device type".
sbx_deps_veth_ok() {
    local mods="${SBX_LIB_MODULES:-/lib/modules}" rel f
    [[ -d "${SBX_SYS_MODULE_DIR:-/sys/module}/veth" ]] && return 0
    rel=$(sbx_deps_kernel_release)
    for f in "$mods/$rel/kernel/drivers/net/veth.ko"*; do
        [[ -e "$f" ]] && return 0
    done
    if awk '/\/veth\.ko$/ { found = 1 } END { exit !found }' "$mods/$rel/modules.builtin" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Two lines, separately, because each caller prefixes them its own way: the
# preflight writes "Error: the <problem>", the doctor a ✗ and an indent. One
# function returning both left both callers slicing an array and stripping
# the indent back off.
sbx_deps_veth_problem() {
    echo "veth kernel module is not available to the running kernel ($(sbx_deps_kernel_release))."
}

sbx_deps_veth_remedy() {
    echo "After a kernel upgrade, reboot so the running kernel matches its modules."
}

# xpra's GTK3 viewer paints through PyGObject's cairo bindings. They are a
# separate package on Debian and Ubuntu, which xpra does not depend on;
# without them `xpra attach` opens windows that stay black. Reported by the
# doctor only: it concerns the viewer, not the launch.
sbx_deps_gicairo_ok() {
    "${SBX_DEPS_PYTHON:-python3}" -c 'import gi; gi.require_foreign("cairo")' >/dev/null 2>&1
}

sbx_deps_gicairo_package() {   # <family>
    case "$1" in
        arch)   echo "sudo pacman -S python-gobject" ;;
        debian) echo "sudo apt install python3-gi-cairo" ;;
        fedora) echo "sudo dnf install python3-gobject" ;;
        *)      echo "install PyGObject's cairo bindings (python3-gi-cairo on Debian/Ubuntu)" ;;
    esac
}


# Runs the host checks once and leaves the results in globals, for the
# three reports below to render:
#   SBX_DEPS_GROUPS    the tool groups asked for, in order
#   SBX_DEPS_MISSING   every missing tool across them
#   SBX_DEPS_HINT      install command lines for SBX_DEPS_MISSING
#   SBX_DEPS_R         missing_<group>, and for each probe (userns, caps,
#                      nsunshare, subids, veth) true, false or null when it
#                      did not run, with <probe>_msg holding the diagnosis
# Tool groups are positional; "nsunshare" may also be passed positionally,
# as sbx_deps_require's callers do. userns runs with core when bwrap exists,
# caps only once userns passes (its probe runs inside a namespace), veth with
# net, nsunshare and subids only when asked for.
sbx_deps_probe() {   # [--nsunshare] [--subids] <group>...
    local want_nsunshare=false want_subids=false group msg
    local -a missing
    SBX_DEPS_GROUPS=()
    SBX_DEPS_MISSING=()
    SBX_DEPS_HINT=()
    declare -gA SBX_DEPS_R=([userns]=null [caps]=null [nsunshare]=null [subids]=null [veth]=null)
    while true; do
        case "${1:-}" in
            --subids)    want_subids=true; shift ;;
            --nsunshare) want_nsunshare=true; shift ;;
            *)           break ;;
        esac
    done
    for group in "$@"; do
        if [[ "$group" == "nsunshare" ]]; then
            want_nsunshare=true
            continue
        fi
        mapfile -t missing < <(sbx_deps_missing "$group")
        SBX_DEPS_GROUPS+=("$group")
        SBX_DEPS_R[missing_$group]="${missing[*]}"
        SBX_DEPS_MISSING+=("${missing[@]}")
    done
    if [[ ${#SBX_DEPS_MISSING[@]} -gt 0 ]]; then
        mapfile -t SBX_DEPS_HINT < <(sbx_deps_install_hint "$(sbx_deps_family)" "${SBX_DEPS_MISSING[@]}")
    fi

    if [[ " ${SBX_DEPS_GROUPS[*]} " == *" core "* ]] && command -v bwrap >/dev/null 2>&1; then
        if msg=$(sbx_deps_userns_check); then
            SBX_DEPS_R[userns]=true
            if msg=$(sbx_deps_caps_check); then
                SBX_DEPS_R[caps]=true
            else
                SBX_DEPS_R[caps]=false
                SBX_DEPS_R[caps_msg]="$msg"
            fi
        else
            SBX_DEPS_R[userns]=false
            SBX_DEPS_R[userns_msg]="$msg"
        fi
    fi
    if [[ "$want_nsunshare" == "true" ]] && command -v unshare >/dev/null 2>&1; then
        if msg=$(sbx_deps_nsunshare_check); then
            SBX_DEPS_R[nsunshare]=true
        else
            SBX_DEPS_R[nsunshare]=false
            SBX_DEPS_R[nsunshare_msg]="$msg"
        fi
    fi
    if [[ "$want_subids" == "true" ]]; then
        if sbx_deps_subids_ok; then
            SBX_DEPS_R[subids]=true
        else
            SBX_DEPS_R[subids]=false
        fi
    fi
    if [[ " ${SBX_DEPS_GROUPS[*]} " == *" net "* ]]; then
        if sbx_deps_veth_ok; then
            SBX_DEPS_R[veth]=true
        else
            SBX_DEPS_R[veth]=false
        fi
    fi
    return 0
}

# The error a launch prints for tools that are not on PATH.
sbx_deps_report_missing() {   # <tool>...
    local line
    if [[ $# -eq 1 ]]; then
        echo "Error: sbx requires $1, which is not on PATH."
    else
        echo "Error: sbx requires $*, which are not on PATH."
    fi
    echo "  Install with:"
    while IFS= read -r line; do
        echo "    $line"
    done < <(sbx_deps_install_hint "$(sbx_deps_family)" "$@")
}

# A launch's preflight: silent on success; on failure prints the first
# problem, with its remedy, and returns 1.
sbx_deps_require() {   # <group>... [nsunshare]
    local probe
    sbx_deps_probe "$@"
    if [[ ${#SBX_DEPS_MISSING[@]} -gt 0 ]]; then
        sbx_deps_report_missing "${SBX_DEPS_MISSING[@]}" >&2
        return 1
    fi
    for probe in userns caps nsunshare; do
        if [[ "${SBX_DEPS_R[$probe]}" == "false" ]]; then
            printf '%s\n' "${SBX_DEPS_R[${probe}_msg]}" >&2
            return 1
        fi
    done
    if [[ "${SBX_DEPS_R[veth]}" == "false" ]]; then
        {
            echo "Error: the $(sbx_deps_veth_problem)"
            echo "  $(sbx_deps_veth_remedy)"
        } >&2
        return 1
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

# The groups object of the JSON reports, from the last sbx_deps_probe.
sbx_deps_json_groups() {
    local group first=1
    printf '{'
    for group in "${SBX_DEPS_GROUPS[@]}"; do
        [[ $first -eq 1 ]] || printf ','
        # shellcheck disable=SC2086  # the stored list is space-separated
        printf '"%s":%s' "$group" "$(sbx_deps_json_list ${SBX_DEPS_R[missing_$group]})"
        first=0
    done
    printf '}'
}

# Prints a probe's diagnosis indented under its line in the doctor report.
sbx_deps_doctor_detail() {   # <probe>
    local line
    while IFS= read -r line; do
        echo "           $line"
    done <<< "${SBX_DEPS_R[${1}_msg]}"
}

sbx_deps_doctor() {
    local json=false group user rc=0 line
    local -a tools
    [[ "${1:-}" == "--json" ]] && json=true

    sbx_deps_probe --nsunshare --subids core net gui podman
    # Only what every session needs decides the exit status; an optional
    # group's gap is reported, not fatal.
    if [[ -n "${SBX_DEPS_R[missing_core]}" || "${SBX_DEPS_R[userns]}" == "false" ||
          "${SBX_DEPS_R[caps]}" == "false" || "${SBX_DEPS_R[nsunshare]}" == "false" ]]; then
        rc=1
    fi

    if $json; then
        printf '{"family":"%s","ok":%s,"groups":%s,"userns":%s,"caps":%s,"nsunshare":%s,"subids":%s,"veth":%s,"install":%s}\n' \
            "$(sbx_deps_family)" "$([[ $rc -eq 0 ]] && echo true || echo false)" "$(sbx_deps_json_groups)" \
            "${SBX_DEPS_R[userns]}" "${SBX_DEPS_R[caps]}" "${SBX_DEPS_R[nsunshare]}" \
            "${SBX_DEPS_R[subids]}" "${SBX_DEPS_R[veth]}" "$(sbx_deps_json_list "${SBX_DEPS_HINT[@]}")"
        return $rc
    fi

    user=$(id -un)
    echo "sbx doctor — distro family: $(sbx_deps_family)"
    echo
    for group in "${SBX_DEPS_GROUPS[@]}"; do
        if [[ -z "${SBX_DEPS_R[missing_$group]}" ]]; then
            mapfile -t tools < <(sbx_deps_tools "$group")
            printf '%-8s ✓ %s\n' "$group" "${tools[*]}"
        else
            printf '%-8s ✗ missing: %s\n' "$group" "${SBX_DEPS_R[missing_$group]}"
        fi
        case "$group" in
            core)
                case "${SBX_DEPS_R[userns]}" in
                    true)  echo "         ✓ unprivileged user namespaces" ;;
                    null)  echo "         ? unprivileged user namespaces (needs bwrap)" ;;
                    false)
                        echo "         ✗ unprivileged user namespaces"
                        sbx_deps_doctor_detail userns
                        ;;
                esac
                case "${SBX_DEPS_R[caps]}" in
                    true)  echo "         ✓ capabilities usable inside a sandbox (the bounding-set drop)" ;;
                    false)
                        echo "         ✗ capabilities usable inside a sandbox (the bounding-set drop)"
                        sbx_deps_doctor_detail caps
                        ;;
                esac
                case "${SBX_DEPS_R[nsunshare]}" in
                    true)  echo "         ✓ unshare can create a user + network namespace" ;;
                    false)
                        echo "         ✗ unshare can create a user + network namespace"
                        echo "           (sessions without networking, and every \"userns\": \"full\" session)"
                        sbx_deps_doctor_detail nsunshare
                        ;;
                esac
                ;;
            net)
                if [[ "${SBX_DEPS_R[veth]}" == "true" ]]; then
                    echo "         ✓ veth kernel module"
                else
                    echo "         ✗ $(sbx_deps_veth_problem)"
                    echo "           $(sbx_deps_veth_remedy)"
                fi
                ;;
            gui)
                if [[ -z "${SBX_DEPS_R[missing_gui]}" ]]; then
                    if sbx_deps_gicairo_ok; then
                        echo "         ✓ xpra viewer can draw (PyGObject cairo bindings)"
                    else
                        echo "         ✗ xpra viewer cannot draw: PyGObject's cairo bindings are missing"
                        echo "           (xpra attach shows black windows)"
                        echo "           $(sbx_deps_gicairo_package "$(sbx_deps_family)")"
                    fi
                fi
                ;;
            podman)
                if [[ "${SBX_DEPS_R[subids]}" == "false" ]]; then
                    echo "         ✗ no subordinate UID/GID range for $user (needed by \"userns\": \"full\")"
                    echo "           sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $user"
                    echo "           (choose a range not already used by another user in /etc/subuid)"
                fi
                ;;
        esac
    done
    if [[ ${#SBX_DEPS_HINT[@]} -gt 0 ]]; then
        echo
        echo "Install missing packages:"
        for line in "${SBX_DEPS_HINT[@]}"; do
            echo "  $line"
        done
    fi
    return $rc
}

# Report-only form of sbx_deps_require, for --dry-run: one JSON object with
# every result, returning 0 either way — .ok carries the verdict, so the
# caller can show everything before deciding its exit status.
sbx_deps_status() {   # [--subids] [--nsunshare] <group>...
    local ok=true probe
    sbx_deps_probe "$@"
    if [[ ${#SBX_DEPS_MISSING[@]} -gt 0 ]]; then
        ok=false
    fi
    for probe in userns caps nsunshare subids veth; do
        if [[ "${SBX_DEPS_R[$probe]}" == "false" ]]; then
            ok=false
        fi
    done
    printf '{"groups":%s,"userns":%s,"caps":%s,"nsunshare":%s,"subids":%s,"veth":%s,"install":%s,"ok":%s}\n' \
        "$(sbx_deps_json_groups)" "${SBX_DEPS_R[userns]}" "${SBX_DEPS_R[caps]}" "${SBX_DEPS_R[nsunshare]}" \
        "${SBX_DEPS_R[subids]}" "${SBX_DEPS_R[veth]}" "$(sbx_deps_json_list "${SBX_DEPS_HINT[@]}")" "$ok"
}
