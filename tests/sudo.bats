#!/usr/bin/env bats

# lib/sudo.sh, the in-sandbox sudo: namespace root through a nested user
# namespace. unshare is stubbed to print the argv it would have run.

setup() {
    SUDO="$BATS_TEST_DIRNAME/../lib/sudo.sh"
    STUB="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB"
    cat > "$STUB/unshare" <<'STUBEOF'
#!/bin/sh
printf '[%s]' "$@"; echo
STUBEOF
    chmod +x "$STUB/unshare"
    export PATH="$STUB:$PATH" SHELL=/bin/sh
}

@test "runs the command as namespace root" {
    run bash "$SUDO" id -u
    [ "$status" -eq 0 ]
    [ "$output" = "[--map-root-user][--][id][-u]" ]
}

@test "accepts and ignores the options that make no difference here" {
    run bash "$SUDO" -E -H -n -S -k -p 'pw:' -- make install
    [ "$output" = "[--map-root-user][--][make][install]" ]
}

@test "-u root and -u 0 are fine; any other user is refused" {
    run bash "$SUDO" -u root id
    [ "$output" = "[--map-root-user][--][id]" ]
    run bash "$SUDO" -u0 id
    [ "$output" = "[--map-root-user][--][id]" ]
    run bash "$SUDO" -u nobody id
    [ "$status" -ne 0 ]
    [[ "$output" == *"only root"* ]]
}

@test "-i and -s with no command open a shell" {
    run bash "$SUDO" -i
    [ "$output" = "[--map-root-user][--][/bin/sh]" ]
    run bash "$SUDO" -s
    [ "$output" = "[--map-root-user][--][/bin/sh]" ]
}

@test "-s with a command runs it through the shell" {
    run bash "$SUDO" -s echo hi
    [ "$output" = "[--map-root-user][--][/bin/sh][-c][echo hi]" ]
}

@test "-v and -l succeed without running anything" {
    run bash "$SUDO" -v
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run bash "$SUDO" -l
    [ "$status" -eq 0 ]
    [[ "$output" == *"namespace root"* ]]
}

@test "no command is a usage error" {
    run bash "$SUDO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage"* ]]
}

@test "an unknown option is refused rather than guessed" {
    run bash "$SUDO" -g wheel id
    [ "$status" -eq 1 ]
    [[ "$output" == *"-g"* ]]
}
