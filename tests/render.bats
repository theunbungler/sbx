#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/render.sh"
    H=/home/u
}

# A complete dry-run document; pass a jq expression to modify it.
doc() {   # [jq update]
    jq -cn '{
      profiles: [{type:"fs",name:"sandbox",path:"/g/fs/sandbox.json",origin:"global"},
                 {type:"cli",name:"pi",path:"/home/u/.config/sbx/profiles/cli/pi.json",origin:"user"}],
      errors: [], warnings: [], confirm: [],
      deps: ["core"],
      security: {caps_keep:false, caps_profile:"", userns_full:false, userns_profile:"", docker_api:false},
      mounts: [], passthrough: [], env: [],
      path: "/usr/local/bin:/usr/bin:/bin", wd: "", gui: false,
      host_ports: {tcp: [], udp: []}, netns: false, net: {enabled: false},
      writes: [{kind:"temporary", path:"/home/u/.local/state/sbx/sessions/proj/", detail:"session directory", dest:"", note:""}],
      needs: {groups:{core:[]}, userns:true, subids:null, install:[], ok:true}
    }' | jq -c "${1:-.}"
}

render() {   # [jq update]
    run sbx_render_plan "$(doc "${1:-.}")" "$H"
    [ "$status" -eq 0 ]
}

line() {   # <prefix> -> the first output line starting with it
    printf '%s\n' "$output" | grep -m1 -F -- "$1"
}

@test "sanitize strips escapes and carriage returns and caps length" {
    run sbx_sanitize_message "$(printf 'a\033[2K\rb')"
    [ "$output" = "a[2Kb" ]
    run sbx_sanitize_message "$(printf 'x%.0s' {1..600})"
    [ "${#output}" -eq 503 ]
}

@test "profiles and security" {
    render
    [ "$(line Profiles)" = "Profiles   fs/sandbox (global)  cli/pi (user)" ]
    [ "$(line Security)" = "Security   capabilities dropped · no userns · no docker API" ]
    render '.security = {caps_keep:true, caps_profile:"/home/u/.config/sbx/profiles/fs/k.json", userns_full:true, userns_profile:"x", docker_api:true}'
    [ "$(line Security)" = "Security   capabilities KEPT (~/.config/sbx/profiles/fs/k.json) · userns full · docker API" ]
}

@test "mounts show perm, paths, note and origin; absent sources are skipped" {
    render '.mounts = [
        {profile:"pi",from:"cli/pi",source:"/home/u/.pi",dest:"/home/u/.pi",perm:"forked",present:true},
        {profile:"s",from:"fs/s",source:"/opt/missing",dest:"/opt/x",perm:"ro",present:false},
        {profile:"s",from:"fs/s",source:"/home/u/new",dest:"/n",perm:"rw",present:false}]
      | .writes = [{kind:"persistent",path:"/s/forked",detail:"forked store",dest:"/home/u/.pi",note:"will seed, 12M",source:"/home/u/.pi"},
                   {kind:"host",path:"/home/u/new",detail:"rw bind",dest:"/n",note:"created at launch",source:"/home/u/new"}]'
    [ "$(line Mounts)" = "Mounts     forked  ~/.pi → ~/.pi  (will seed, 12M)  cli/pi" ]
    printf '%s\n' "$output" | grep -qxF "           skip    /opt/missing → /opt/x  (source absent)  fs/s"
    printf '%s\n' "$output" | grep -qxF "           rw      ~/new → /n  (created at launch)  fs/s"
}

@test "two mounts sharing a dest each show their own write note, matched by source" {
    render '.mounts = [
        {profile:"a",from:"fs/a",source:"/home/u/a",dest:"/d",perm:"forked",present:true},
        {profile:"b",from:"fs/b",source:"/home/u/b",dest:"/d",perm:"forked",present:true}]
      | .writes = [{kind:"persistent",path:"/s/a",detail:"forked store",dest:"/d",note:"note-for-a",source:"/home/u/a"},
                   {kind:"persistent",path:"/s/b",detail:"forked store",dest:"/d",note:"note-for-b",source:"/home/u/b"}]'
    printf '%s\n' "$output" | grep -qxF "Mounts     forked  ~/a → /d  (note-for-a)  fs/a"
    printf '%s\n' "$output" | grep -qxF "           forked  ~/b → /d  (note-for-b)  fs/b"
}

@test "env shows the winning value and what it overrides; PATH has its own line" {
    render '.env = [{name:"A",value:"1",from:"fs/x"},{name:"PATH",value:"/p",from:"fs/x"},{name:"A",value:"2",from:"cli/c"}]'
    [ "$(line Env)" = "Env        A=2  (cli/c; overrides fs/x)" ]
    if printf '%s\n' "$output" | grep -q 'PATH=/p'; then return 1; fi
    [ "$(line Path)" = "Path       /usr/local/bin:/usr/bin:/bin" ]
}

@test "passthrough is names only" {
    render '.passthrough = ["TOKEN","TOKEN","KEY"]'
    [ "$(line Passthru)" = "Passthru   KEY, TOKEN" ]
}

@test "network groups domains by ports and lists addresses and host ports" {
    render '.netns = true
      | .net = {enabled:true, upstreams:["1.1.1.1"],
                domains:{"github.com":{ports:"80,443",upstream:"1.1.1.1"},
                         "google.com":{ports:"80,443",upstream:"1.1.1.1"},
                         "db.example":{ports:"5432",upstream:"1.1.1.1"}},
                cidrs:{"10.0.0.0/8":"5432"}, allow_all:false, allow_all_ports:"", test_domain:"github.com"}
      | .host_ports = {tcp:[8080], udp:[53]}'
    [ "$(line Network)" = "Network    dns 1.1.1.1" ]
    printf '%s\n' "$output" | grep -qxF "           ports 5432: db.example"
    printf '%s\n' "$output" | grep -qxF "           ports 80,443: github.com, google.com"
    printf '%s\n' "$output" | grep -qxF "           addresses: 10.0.0.0/8 (ports 5432)"
    printf '%s\n' "$output" | grep -qxF "           host ports: tcp 8080; udp 53"
}

@test "network without a namespace, and host ports without a net profile" {
    render
    [ "$(line Network)" = "Network    none (no network namespace)" ]
    render '.netns = true | .host_ports = {tcp:[8080], udp:[]}'
    [ "$(line Network)" = "Network    no internet; host ports only" ]
    printf '%s\n' "$output" | grep -qxF "           host ports: tcp 8080"
}

@test "writes, needs, confirm and result" {
    render '.needs = {groups:{core:[], net:["pasta"]}, userns:true, subids:false, install:["sudo pacman -S passt"], ok:false}
      | .confirm = ["./.sbx/profiles/fs/t.json"]'
    [ "$(line Writes)" = "Writes     temporary  ~/.local/state/sbx/sessions/proj/  (session directory)" ]
    [ "$(line Needs)" = "Needs      core ✓ · net ✗ missing pasta · userns ✓ · subuid/subgid ✗" ]
    printf '%s\n' "$output" | grep -qxF "           install: sudo pacman -S passt"
    [ "$(line Confirm)" = "Confirm    ./.sbx/profiles/fs/t.json would prompt" ]
    [ "$(line Result)" = "Result     the launch would stop" ]
}

@test "errors are listed, the plan sections are omitted, and the launch would stop" {
    render '.errors = ["/p.json: .mount: unknown field for a fs profile"]'
    [ "$(line Errors)" = "Errors     /p.json: .mount: unknown field for a fs profile" ]
    if printf '%s\n' "$output" | grep -q '^Security'; then return 1; fi
    [ "$(line Result)" = "Result     the launch would stop" ]
}

@test "a clean plan would proceed" {
    render
    [ "$(line Result)" = "Result     the launch would proceed" ]
}

@test "control characters in profile-authored text are removed; unicode is kept" {
    render '.warnings = ["bad[2K\rtextend"] | .env = [{name:"U",value:"héllo",from:"fs/x"}]'
    [ "$(line Warnings)" = "Warnings   bad[2Ktextend" ]
    [ "$(line Env)" = "Env        U=héllo  (fs/x)" ]
}

@test "home is abbreviated only as a whole path component" {
    render '.mounts = [{profile:"s",from:"fs/s",source:"/home/u2/x",dest:"/home/u",perm:"ro",present:true}]'
    [ "$(line Mounts)" = "Mounts     ro      /home/u2/x → ~  fs/s" ]
}
