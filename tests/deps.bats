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

@test "tools lists a group in table order" {
    run sbx_deps_tools net
    [ "$output" = "$(printf 'pasta\nnft\ndnsmasq')" ]
}

@test "missing reports only absent tools of the requested groups" {
    mkdir -p "$FIX/bin"
    ln -s "$(command -v nft)" "$FIX/bin/nft"
    PATH="$FIX/bin" run sbx_deps_missing net
    [ "$output" = "$(printf 'pasta\ndnsmasq')" ]
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
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"AppArmor"* ]]
    [[ "$output" == *"userns,"* ]]
    [[ "$output" == *"apparmor_parser -r"* ]]
}

@test "userns check blames unprivileged_userns_clone when it is 0" {
    fake_bwrap 1 "bwrap: No permissions to create new namespace"
    fake_sysctl kernel/apparmor_restrict_unprivileged_userns 0
    fake_sysctl kernel/unprivileged_userns_clone 0
    PATH="$FIX/bin:$PATH" SBX_PROC_SYS="$FIX/sys" run sbx_deps_userns_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"kernel.unprivileged_userns_clone=1"* ]]
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
