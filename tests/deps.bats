#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/deps.sh"
    FIX="$BATS_TEST_TMPDIR/fix"
    mkdir -p "$FIX"
}

os_release() {   # <file> <ID> [<ID_LIKE>]
    printf 'NAME="Test"\nID=%s\n' "$2" > "$1"
    [[ -n "${3:-}" ]] && printf 'ID_LIKE="%s"\n' "$3" >> "$1"
    return 0
}

@test "family: manjaro maps to arch" {
    os_release "$FIX/os" manjaro arch
    SBX_OS_RELEASE="$FIX/os" run sbx_deps_family
    [ "$output" = "arch" ]
}

@test "family: ubuntu maps to debian through ID_LIKE" {
    os_release "$FIX/os" ubuntu debian
    SBX_OS_RELEASE="$FIX/os" run sbx_deps_family
    [ "$output" = "debian" ]
}

@test "family: rocky maps to fedora through ID_LIKE" {
    os_release "$FIX/os" rocky "rhel centos fedora"
    SBX_OS_RELEASE="$FIX/os" run sbx_deps_family
    [ "$output" = "fedora" ]
}

@test "family: a quoted ID is unquoted" {
    printf 'ID="fedora"\n' > "$FIX/os"
    SBX_OS_RELEASE="$FIX/os" run sbx_deps_family
    [ "$output" = "fedora" ]
}

@test "family: last line without a trailing newline is still read" {
    printf 'ID=arch' > "$FIX/os"
    SBX_OS_RELEASE="$FIX/os" run sbx_deps_family
    [ "$output" = "arch" ]
}

@test "family: unrecognised or absent os-release is unknown" {
    os_release "$FIX/os" gentoo
    SBX_OS_RELEASE="$FIX/os" run sbx_deps_family
    [ "$output" = "unknown" ]
    SBX_OS_RELEASE="$FIX/nope" run sbx_deps_family
    [ "$output" = "unknown" ]
}

veth_loaded() {   # a /sys/module fixture where veth is loaded
    mkdir -p "$FIX/sysmod/veth"
    export SBX_SYS_MODULE_DIR="$FIX/sysmod"
}

veth_absent() {   # no veth anywhere: not loaded, no module file, not built in
    mkdir -p "$FIX/sysmod" "$FIX/modules/6.0.0-test"
    export SBX_SYS_MODULE_DIR="$FIX/sysmod" SBX_LIB_MODULES="$FIX/modules" SBX_KERNEL_RELEASE=6.0.0-test
}

@test "tools lists a group in table order" {
    run sbx_deps_tools net
    [ "$output" = "$(printf 'pasta\nnft\ndnsmasq\nsocat')" ]
}

@test "missing reports only absent tools of the requested groups" {
    mkdir -p "$FIX/bin"
    ln -s "$(command -v nft)" "$FIX/bin/nft"
    PATH="$FIX/bin" run sbx_deps_missing net
    [ "$output" = "$(printf 'pasta\ndnsmasq\nsocat')" ]
}

@test "packages dedupes tools that share a package" {
    run sbx_deps_packages arch setpriv flock realpath
    [ "$output" = "$(printf 'util-linux\ncoreutils')" ]
}

@test "packages uses the family's own names" {
    run sbx_deps_packages debian envsubst newuidmap
    [ "$output" = "$(printf 'gettext-base\nuidmap')" ]
}

@test "install hint for a known family is one command" {
    run sbx_deps_install_hint fedora pasta ip
    [ "$output" = "sudo dnf install passt iproute" ]
}

@test "install hint for an unknown family covers all three" {
    run sbx_deps_install_hint unknown bwrap
    [ "${lines[0]}" = "arch:   sudo pacman -S bubblewrap" ]
    [ "${lines[1]}" = "debian: sudo apt install bubblewrap" ]
    [ "${lines[2]}" = "fedora: sudo dnf install bubblewrap" ]
}

fake_bwrap() {   # <exit-status> [<stderr>]
    mkdir -p "$FIX/bin"
    printf '#!/bin/sh\necho "%s" >&2\nexit %s\n' "${2:-}" "$1" > "$FIX/bin/bwrap"
    chmod +x "$FIX/bin/bwrap"
}

fake_sysctl() {   # <relative path under /proc/sys> <value>
    mkdir -p "$FIX/sys/$(dirname "$1")"
    echo "$2" > "$FIX/sys/$1"
}

@test "userns check passes when bwrap succeeds" {
    fake_bwrap 0
    PATH="$FIX/bin:$PATH" run sbx_deps_userns_check
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userns check blames AppArmor when Ubuntu's restriction is on" {
    fake_bwrap 1 "bwrap: setting up uid map: Permission denied"
    fake_sysctl kernel/apparmor_restrict_unprivileged_userns 1
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" SBX_BWRAP_PATH=/usr/bin/bwrap \
        SBX_APPARMOR_EXTRA="$FIX/no-such-dir" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"AppArmor"* ]]
    [[ "$output" == *"userns,"* ]]
    [[ "$output" == *"apparmor_parser -r"* ]]
}

@test "userns check warns instead of naming a non-root-owned bwrap in the AppArmor profile" {
    fake_bwrap 1 "bwrap: setting up uid map: Permission denied"
    fake_sysctl kernel/apparmor_restrict_unprivileged_userns 1
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a root-owned system binary"* ]]
    if [[ "$output" == *"profile sbx-bwrap"* ]]; then return 1; fi
}

@test "userns check recommends bwrap-userns-restrict when the extra profile exists" {
    fake_bwrap 1 "bwrap: setting up uid map: Permission denied"
    fake_sysctl kernel/apparmor_restrict_unprivileged_userns 1
    mkdir -p "$FIX/extra-profiles"
    : > "$FIX/extra-profiles/bwrap-userns-restrict"
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" SBX_BWRAP_PATH=/usr/bin/bwrap \
        SBX_APPARMOR_EXTRA="$FIX/extra-profiles" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"bwrap-userns-restrict"* ]]
    [[ "$output" == *"apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict"* ]]
}

@test "userns check warns what the fallback AppArmor profile weakens when the extra profile is absent" {
    fake_bwrap 1 "bwrap: setting up uid map: Permission denied"
    fake_sysctl kernel/apparmor_restrict_unprivileged_userns 1
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" SBX_BWRAP_PATH=/usr/bin/bwrap \
        SBX_APPARMOR_EXTRA="$FIX/no-such-dir" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"any local user"* ]]
    [[ "$output" == *"pasta may need the same allowance"* ]]
}

@test "userns check blames unprivileged_userns_clone when it is 0" {
    fake_bwrap 1 "bwrap: No permissions to create new namespace"
    fake_sysctl kernel/apparmor_restrict_unprivileged_userns 0
    fake_sysctl kernel/unprivileged_userns_clone 0
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"kernel.unprivileged_userns_clone=1"* ]]
    [[ "$output" == *"bwrap reported: bwrap: No permissions to create new namespace"* ]]
}

@test "userns check blames max_user_namespaces when it is 0" {
    fake_bwrap 1 "bwrap: No space left on device"
    fake_sysctl user/max_user_namespaces 0
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"user.max_user_namespaces"* ]]
}

@test "userns check with no known cause shows bwrap's own message" {
    fake_bwrap 1 "bwrap: something unexpected"
    mkdir -p "$FIX/sys"
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"bwrap: something unexpected"* ]]
}

@test "subids ok when the user has both ranges" {
    printf '%s:100000:65536\n' "$(id -un)" > "$FIX/subuid"
    printf '%s:100000:65536\n' "$(id -u)"  > "$FIX/subgid"
    SBX_SUBUID="$FIX/subuid" SBX_SUBGID="$FIX/subgid" run sbx_deps_subids_ok
    [ "$status" -eq 0 ]
}

@test "subids not ok when one file lacks the user" {
    printf '%s:100000:65536\n' "$(id -un)" > "$FIX/subuid"
    printf 'someoneelse:100000:65536\n'   > "$FIX/subgid"
    SBX_SUBUID="$FIX/subuid" SBX_SUBGID="$FIX/subgid" run sbx_deps_subids_ok
    [ "$status" -eq 1 ]
}

@test "subids not ok when a name merely starts with the user's" {
    printf '%sx:100000:65536\n' "$(id -un)" > "$FIX/subuid"
    cp "$FIX/subuid" "$FIX/subgid"
    SBX_SUBUID="$FIX/subuid" SBX_SUBGID="$FIX/subgid" run sbx_deps_subids_ok
    [ "$status" -eq 1 ]
}

@test "require passes silently when nothing is missing" {
    veth_loaded
    fake_bwrap 0
    PATH="$FIX/bin:$PATH" run sbx_deps_require core net
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "require names missing tools and the distro's command" {
    os_release "$FIX/os" ubuntu debian
    mkdir -p "$FIX/bin"
    PATH="$FIX/bin" SBX_OS_RELEASE="$FIX/os" run sbx_deps_require net
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" == "Error: sbx requires pasta nft dnsmasq socat, which are not on PATH." ]]
    [[ "$output" == *"sudo apt install passt nftables dnsmasq socat"* ]]
    if [[ "$output" == *pacman* ]]; then return 1; fi
}

@test "require skips the userns probe for optional groups" {
    veth_loaded
    fake_bwrap 1 "should not run"
    PATH="$FIX/bin:$PATH" run sbx_deps_require net
    [ "$status" -eq 0 ]
}

@test "require runs the userns probe with core" {
    fake_bwrap 1 "bwrap: nope"
    mkdir -p "$FIX/sys"
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" run sbx_deps_require core
    [ "$status" -eq 1 ]
    [[ "$output" == *"unprivileged user namespace"* ]]
}

@test "veth ok when the module is loaded" {
    veth_loaded
    run sbx_deps_veth_ok
    [ "$status" -eq 0 ]
}

@test "veth ok when the running kernel has the module file" {
    veth_absent
    mkdir -p "$FIX/modules/6.0.0-test/kernel/drivers/net"
    : > "$FIX/modules/6.0.0-test/kernel/drivers/net/veth.ko.zst"
    run sbx_deps_veth_ok
    [ "$status" -eq 0 ]
}

@test "veth ok when it is built into the running kernel" {
    veth_absent
    echo "kernel/drivers/net/veth.ko" > "$FIX/modules/6.0.0-test/modules.builtin"
    run sbx_deps_veth_ok
    [ "$status" -eq 0 ]
}

@test "veth not ok when the running kernel's module tree lacks it" {
    veth_absent
    run sbx_deps_veth_ok
    [ "$status" -eq 1 ]
}

@test "require net fails with a reboot hint when veth is unavailable" {
    veth_absent
    fake_bwrap 0
    PATH="$FIX/bin:$PATH" run sbx_deps_require net
    [ "$status" -eq 1 ]
    [[ "$output" == *"veth kernel module is not available to the running kernel (6.0.0-test)"* ]]
    [[ "$output" == *reboot* ]]
}

@test "require core does not check veth" {
    veth_absent
    fake_bwrap 0
    PATH="$FIX/bin:$PATH" run sbx_deps_require core
    [ "$status" -eq 0 ]
}

doctor_bin() {   # <tool to omit>...: a PATH holding every table tool except those named
    mkdir -p "$FIX/bin"
    local tool skip
    while IFS= read -r tool; do
        for skip in "$@"; do [[ "$tool" == "$skip" ]] && continue 2; done
        ln -sf "$(command -v "$tool")" "$FIX/bin/$tool"
    done < <(sbx_deps_tools core net gui podman)
    # id and awk are used by the subid check
    ln -sf "$(command -v id)" "$FIX/bin/id"
    ln -sf "$(command -v awk)" "$FIX/bin/awk"
}

@test "doctor: all present exits 0 and reports each group" {
    doctor_bin bwrap
    veth_loaded
    fake_bwrap 0
    os_release "$FIX/os" manjaro arch
    PATH="$FIX/bin" SBX_OS_RELEASE="$FIX/os" run sbx_deps_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"distro family: arch"* ]]
    [[ "$output" == *"✓ unprivileged user namespaces"* ]]
    if [[ "$output" == *"Install missing packages"* ]]; then return 1; fi
}

@test "doctor: a missing optional tool is reported but exits 0" {
    doctor_bin bwrap pasta
    fake_bwrap 0
    os_release "$FIX/os" fedora
    PATH="$FIX/bin" SBX_OS_RELEASE="$FIX/os" run sbx_deps_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"✗ missing: pasta"* ]]
    [[ "$output" == *"sudo dnf install passt"* ]]
}

@test "doctor: a missing core tool exits 1" {
    doctor_bin bwrap jq
    fake_bwrap 0
    PATH="$FIX/bin" run sbx_deps_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"✗ missing: jq"* ]]
}

@test "doctor: missing bwrap marks userns unknown" {
    doctor_bin bwrap
    PATH="$FIX/bin" run sbx_deps_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"? unprivileged user namespaces (needs bwrap)"* ]]
}

@test "doctor: a failing probe exits 1 and includes the diagnosis" {
    doctor_bin bwrap
    fake_bwrap 1 "bwrap: nope"
    fake_sysctl kernel/unprivileged_userns_clone 0
    PATH="$FIX/bin" SBX_PROC_SYS="$FIX/sys" run sbx_deps_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"kernel.unprivileged_userns_clone=1"* ]]
}

@test "doctor reports veth under net" {
    doctor_bin bwrap
    fake_bwrap 0
    veth_absent
    PATH="$FIX/bin" run sbx_deps_doctor
    [[ "$output" == *"✗ veth kernel module"* ]]
    PATH="$FIX/bin" run sbx_deps_doctor --json
    [ "$(jq -r .veth <<< "$output")" = "false" ]
}

@test "status: veth is null without net and false when net needs it" {
    doctor_bin bwrap
    fake_bwrap 0
    veth_absent
    PATH="$FIX/bin" run sbx_deps_status core
    [ "$(jq -r .veth <<< "$output")" = "null" ]
    PATH="$FIX/bin" run sbx_deps_status core net
    [ "$(jq -r .veth <<< "$output")" = "false" ]
    [ "$(jq -r .ok <<< "$output")" = "false" ]
}

@test "doctor --json is parseable and matches the text report" {
    doctor_bin bwrap pasta
    veth_loaded
    fake_bwrap 0
    os_release "$FIX/os" ubuntu debian
    : > "$FIX/subuid"; : > "$FIX/subgid"
    PATH="$FIX/bin" SBX_OS_RELEASE="$FIX/os" SBX_SUBUID="$FIX/subuid" SBX_SUBGID="$FIX/subgid" \
        run sbx_deps_doctor --json
    [ "$status" -eq 0 ]
    [ "$(jq -r .family <<< "$output")" = "debian" ]
    [ "$(jq -c .groups.net <<< "$output")" = '["pasta"]' ]
    [ "$(jq -r .userns <<< "$output")" = "true" ]
    [ "$(jq -r .subids <<< "$output")" = "false" ]
    [ "$(jq -r '.install[0]' <<< "$output")" = "sudo apt install passt" ]
}

@test "status: everything present is ok" {
    doctor_bin bwrap
    veth_loaded
    fake_bwrap 0
    PATH="$FIX/bin" run sbx_deps_status core net
    [ "$status" -eq 0 ]
    [ "$(jq -c .groups <<< "$output")" = '{"core":[],"net":[]}' ]
    [ "$(jq -r .userns <<< "$output")" = "true" ]
    [ "$(jq -r .subids <<< "$output")" = "null" ]
    [ "$(jq -c .install <<< "$output")" = '[]' ]
    [ "$(jq -r .ok <<< "$output")" = "true" ]
}

@test "status: a missing tool is listed with the distro's command, and returns 0" {
    doctor_bin bwrap pasta
    veth_loaded
    fake_bwrap 0
    os_release "$FIX/os" manjaro arch
    PATH="$FIX/bin" SBX_OS_RELEASE="$FIX/os" run sbx_deps_status core net
    [ "$status" -eq 0 ]
    [ "$(jq -c .groups.net <<< "$output")" = '["pasta"]' ]
    [ "$(jq -r '.install[0]' <<< "$output")" = "sudo pacman -S passt" ]
    [ "$(jq -r .ok <<< "$output")" = "false" ]
}

@test "status: a failing probe is reported, not printed" {
    doctor_bin bwrap
    fake_bwrap 1 "bwrap: nope"
    mkdir -p "$FIX/sys"
    PATH="$FIX/bin" SBX_PROC_SYS="$FIX/sys" run sbx_deps_status core
    [ "$status" -eq 0 ]
    [ "$(jq -r .userns <<< "$output")" = "false" ]
    [ "$(jq -r .ok <<< "$output")" = "false" ]
}

@test "status: the probe does not run without core" {
    doctor_bin bwrap
    veth_loaded
    fake_bwrap 1 "bwrap: nope"
    PATH="$FIX/bin" run sbx_deps_status net
    [ "$(jq -r .userns <<< "$output")" = "null" ]
    [ "$(jq -r .ok <<< "$output")" = "true" ]
}

@test "status: --subids reports a missing range" {
    doctor_bin bwrap
    fake_bwrap 0
    : > "$FIX/subuid"; : > "$FIX/subgid"
    PATH="$FIX/bin" SBX_SUBUID="$FIX/subuid" SBX_SUBGID="$FIX/subgid" run sbx_deps_status --subids core podman
    [ "$(jq -r .subids <<< "$output")" = "false" ]
    [ "$(jq -r .ok <<< "$output")" = "false" ]
}
