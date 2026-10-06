#!/usr/bin/env bats

# lib/tmux.sh decides from the value of $TMUX, which these tests pass in.

setup() {
    source "$BATS_TEST_DIRNAME/../lib/tmux.sh"
}

@test "outside a host tmux both C-b and C-\\ are prefixes" {
    [ "$(sbx_tmux_prefixes '')" = 'C-b C-\' ]
}

@test "inside a host tmux C-\\ is the only prefix" {
    [ "$(sbx_tmux_prefixes /tmp/tmux-1000/default,123,0)" = 'C-\ None' ]
}

@test "the prefix arguments follow another command and name no target by default" {
    local -a args
    mapfile -d '' -t args < <(sbx_tmux_prefix_args /tmp/tmux-1000/default,1,0)
    [ "${args[*]}" = '; set-option prefix C-\ ; set-option prefix2 None' ]
}

@test "the prefix arguments can target a named session" {
    local -a args
    mapfile -d '' -t args < <(sbx_tmux_prefix_args '' main)
    [ "${args[*]}" = '; set-option -t main prefix C-b ; set-option -t main prefix2 C-\' ]
}
