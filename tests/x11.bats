#!/usr/bin/env bats

# lib/x11.sh reads /proc/net/unix; these tests hand it a fixed one.

setup() {
    source "$BATS_TEST_DIRNAME/../lib/x11.sh"
    NET_UNIX="$BATS_TEST_TMPDIR/unix"
    cat > "$NET_UNIX" <<'TABLE'
Num       RefCount Protocol Flags    Type St Inode Path
0000000000000000: 00000002 00000000 00010000 0001 01  2626 /tmp/.X11-unix/X0
0000000000000000: 00000002 00000000 00010000 0001 01  4300 @/tmp/.X11-unix/X100
0000000000000000: 00000003 00000000 00000000 0001 03  4310 @/tmp/.X11-unix/X101
0000000000000000: 00000002 00000000 00010000 0001 01  4320 @/tmp/.X11-unix/X1020
TABLE
}

@test "an abstract X listener is found" {
    sbx_x11_abstract_listening 100 "$NET_UNIX"
}

@test "a file socket is not an abstract one" {
    run sbx_x11_abstract_listening 0 "$NET_UNIX"
    [ "$status" -ne 0 ]
}

@test "a connected, non-listening abstract socket is not a display" {
    run sbx_x11_abstract_listening 101 "$NET_UNIX"
    [ "$status" -ne 0 ]
}

@test "display 102 does not match X1020" {
    run sbx_x11_abstract_listening 102 "$NET_UNIX"
    [ "$status" -ne 0 ]
}

@test "a display held only by its abstract socket counts as taken" {
    sbx_x11_display_taken 100 "$NET_UNIX"
}

@test "the attach command under WSL2 forces X11 and turns OpenGL off" {
    [ "$(sbx_x11_attach_cmd :100 6.18.33.2-microsoft-standard-WSL2)" = "GDK_BACKEND=x11 xpra attach :100 --opengl=no" ]
}

@test "the attach command elsewhere is plain" {
    [ "$(sbx_x11_attach_cmd :101 6.10.5-arch1-1)" = "xpra attach :101" ]
}
