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
