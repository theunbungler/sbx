#!/usr/bin/env bats

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    source "$LIB/profiles.sh"
    source "$LIB/profile-check.sh"
    source "$LIB/net-merge.sh"
    source "$LIB/resolve.sh"
    W="$BATS_TEST_TMPDIR/w"
    PROJ="$W/proj"; CFG="$W/cfg"; GLOBAL="$W/global"; SRC="$W/src"
    mkdir -p "$PROJ/.sbx/profiles/fs" "$PROJ/.sbx/profiles/net" \
             "$CFG/profiles/fs" "$CFG/profiles/cli" "$CFG/profiles/net" "$GLOBAL/fs" "$SRC/present"
    cd "$PROJ"
}

user() {   # <type> <name> <json>
    printf '%s\n' "$3" > "$CFG/profiles/$1/$2.json"
    echo "$CFG/profiles/$1/$2.json"
}

resolve() {   # <args...>
    run sbx_resolve --launch-dir "$PROJ" --config-dir "$CFG" --global-dir "$GLOBAL" "$@"
    [ "$status" -eq 0 ]
    PLAN="$output"
}

q() { jq -c "$1" <<< "$PLAN"; }
r() { jq -r "$1" <<< "$PLAN"; }

@test "an empty launch has core deps, the default PATH and no network" {
    resolve
    [ "$(q .deps)" = '["core"]' ]
    [ "$(r .path)" = "/usr/local/bin:/usr/bin:/bin" ]
    [ "$(r .netns)" = "false" ]
    [ "$(q .net)" = '{"enabled":false}' ]
    [ "$(q .errors)" = '[]' ]
}

@test "unknown arguments return 2" {
    run sbx_resolve --bogus
    [ "$status" -eq 2 ]
}

@test "mounts are expanded, absolutised, attributed, and absence is reported" {
    local fs cli
    export SNAPVAR="$SRC"
    fs=$(user fs m '{"mounts":[{"source":"$SNAPVAR/present","dest":"$HOME/p","perm":"ro"},{"source":"'"$SRC"'/gone","dest":"/g","perm":"ro"},{"source":"'"$SRC"'/newrw","dest":"/n","perm":"rw"}]}')
    cli=$(user cli c '{"mounts":[{"source":"'"$SRC"'/present","dest":"/c","perm":"forked"}]}')
    resolve --fs "$fs" --cli "$cli"
    [ "$(q '.mounts[0]')" = "{\"profile\":\"m\",\"from\":\"fs/m\",\"source\":\"$SRC/present\",\"dest\":\"$HOME/p\",\"perm\":\"ro\",\"present\":true}" ]
    [ "$(r '.mounts[1].present')" = "false" ]
    [ "$(r '.mounts[3].from')" = "cli/c" ]
    [[ "$(r '.warnings[]')" == *"fs/m: mount source not present on this host, skipped: ro $SRC/gone"* ]]
    if [[ "$(r '.warnings[]')" == *"newrw"* ]]; then return 1; fi
}

@test "resolving creates nothing" {
    local fs
    fs=$(user fs m '{"mounts":[{"source":"'"$SRC"'/newrw","dest":"/n","perm":"rw"}]}')
    resolve --fs "$fs"
    [ ! -e "$SRC/newrw" ]
}

@test "env is every assignment in profile order; PATH layers env, cli path and the default" {
    local fs cli
    fs=$(user fs e '{"env":{"SHARED":"fs","PATH":"/fs/bin","N":7}}')
    cli=$(user cli e '{"env":{"SHARED":"cli","HOMEY":"$HOME/x"},"path":["/cli/bin","$HOME/b"]}')
    resolve --fs "$fs" --cli "$cli"
    [ "$(q '[.env[] | [.name, .value, .from]]')" = "[[\"SHARED\",\"fs\",\"fs/e\"],[\"PATH\",\"/fs/bin\",\"fs/e\"],[\"N\",\"7\",\"fs/e\"],[\"SHARED\",\"cli\",\"cli/e\"],[\"HOMEY\",\"$HOME/x\",\"cli/e\"]]" ]
    [ "$(r .path)" = "/cli/bin:$HOME/b:/fs/bin:/usr/local/bin:/usr/bin:/bin" ]
}

@test "env values beginning with a dash survive" {
    local fs
    fs=$(user fs d '{"env":{"FLAG":"-n"}}')
    resolve --fs "$fs"
    [ "$(r '.env[0].value')" = "-n" ]
}

@test "passthrough carries names, never values" {
    local fs
    export SBX_RESOLVE_SECRET=hunter2
    fs=$(user fs p '{"passthrough":["SBX_RESOLVE_SECRET"]}')
    resolve --fs "$fs"
    [ "$(q .passthrough)" = '["SBX_RESOLVE_SECRET"]' ]
    if [[ "$PLAN" == *hunter2* ]]; then return 1; fi
}

@test "caps keep and docker_api set security and the podman dep group" {
    local fs
    fs=$(user fs k '{"caps":"keep","docker_api":true}')
    resolve --fs "$fs"
    [ "$(r .security.caps_keep)" = "true" ]
    [ "$(r .security.caps_profile)" = "$fs" ]
    [ "$(r .security.docker_api)" = "true" ]
    [ "$(q .deps)" = '["core","podman"]' ]
}

@test "userns full without a net profile is an error" {
    local fs
    fs=$(user fs u '{"userns":"full"}')
    resolve --fs "$fs"
    [[ "$(r '.errors[0]')" == *"requires networking"* ]]
}

@test "userns full with net sets caps too" {
    local fs net
    fs=$(user fs u '{"userns":"full"}')
    net=$(user net n '{"allow":["github.com"]}')
    resolve --fs "$fs" --net "$net"
    [ "$(r .security.userns_full)" = "true" ]
    [ "$(r .security.caps_keep)" = "true" ]
    [ "$(r .security.userns_profile)" = "$fs" ]
    [ "$(q .deps)" = '["core","net","podman"]' ]
}

@test "a project profile asking for caps is an error and nothing else is resolved" {
    printf '%s\n' '{"caps":"keep","mounts":[{"source":"/a","dest":"/b","perm":"ro"}]}' > .sbx/profiles/fs/evil.json
    resolve --fs ./.sbx/profiles/fs/evil.json
    [[ "$(r '.errors[0]')" == *"may not set caps"* ]]
    [ "$(q .mounts)" = '[]' ]
    [ "$(r .security.caps_keep)" = "false" ]
    [ "$(r '.profiles[0].origin')" = "project" ]
}

@test "validation errors from every profile are collected" {
    local a b
    a=$(user fs a '{"mount":[]}')
    b=$(user net b '{"ports":["https"]}')
    resolve --fs "$a" --net "$b"
    [ "$(r '.errors | length')" = "2" ]
}

@test "confirm lists only git-tracked project profiles, unless trusted" {
    printf '{}\n' > .sbx/profiles/fs/tracked.json
    printf '{}\n' > .sbx/profiles/fs/loose.json
    git init -q .
    git add -f .sbx/profiles/fs/tracked.json
    resolve --fs ./.sbx/profiles/fs/tracked.json --fs ./.sbx/profiles/fs/loose.json
    [ "$(q .confirm)" = '["./.sbx/profiles/fs/tracked.json"]' ]
    SBX_TRUST_PROJECT_PROFILES=1 resolve --fs ./.sbx/profiles/fs/tracked.json
    [ "$(q .confirm)" = '[]' ]
}

@test "host ports merge flags and profiles, sorted and de-duplicated" {
    local net
    net=$(user net h '{"allow":["x.example"],"host_ports":[5433,"53/udp",8080]}')
    resolve --net "$net" --host-port 8080/tcp --host-port 22/tcp
    [ "$(q .host_ports)" = '{"tcp":[22,5433,8080],"udp":[53]}' ]
    [ "$(r .netns)" = "true" ]
    [ "$(r .net.enabled)" = "true" ]
    [ "$(r '.net.domains["x.example"].ports')" = "80,443" ]
}

@test "host ports alone make a network namespace without a net profile" {
    resolve --host-port 8080/tcp
    [ "$(r .netns)" = "true" ]
    [ "$(r .net.enabled)" = "false" ]
    [ "$(q .deps)" = '["core","net"]' ]
}

@test "--wd and --gui pass through" {
    resolve --wd /work --gui
    [ "$(r .wd)" = "/work" ]
    [ "$(r .gui)" = "true" ]
    [ "$(q .deps)" = '["core","gui"]' ]
}

@test "workingDirectory surfaces as a warning" {
    local fs
    fs=$(user fs w '{"workingDirectory":"/src"}')
    resolve --fs "$fs"
    [[ "$(r '.warnings[0]')" == *".workingDirectory: no longer honored; pass --wd /src instead"* ]]
}
