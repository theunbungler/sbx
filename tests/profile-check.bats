#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/profile-check.sh"
    F="$BATS_TEST_TMPDIR/p.json"
}

check() {   # <type> <origin> <json>
    printf '%s\n' "$3" > "$F"
    run sbx_profile_check "$1" "$F" "$2"
    [ "$status" -eq 0 ]
}

@test "a minimal valid profile of each type is clean" {
    check cli user '{"description":"d","env":{"A":"b","N":1},"path":["/x"],"passthrough":["TOKEN"],"mounts":[{"source":"/a","dest":"/b","perm":"ro"}]}'
    [ -z "$output" ]
    check fs user '{"mounts":[{"source":"/a","dest":"/b","perm":"forked"}],"caps":"keep","userns":"full","docker_api":true}'
    [ -z "$output" ]
    check net user '{"dns":"9.9.9.9","allow":["github.com","*","10.0.0.0/8","127.0.0.1"],"ports":[80,"*"],"host_ports":[5432,"53/udp","8080/tcp"]}'
    [ -z "$output" ]
}

@test "invalid JSON is one error naming the file" {
    check fs user '{"mounts": ['
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == "error"$'\t'"$F: invalid JSON: "* ]]
}

@test "a non-object top level is an error" {
    check fs user '[1,2]'
    [ "$output" = "error"$'\t'"$F: .: expected a JSON object at the top level" ]
}

@test "unknown fields are errors, per type" {
    check fs user '{"mount":[]}'
    [ "$output" = "error"$'\t'"$F: .mount: unknown field for a fs profile" ]
    check net user '{"env":{}}'
    [ "$output" = "error"$'\t'"$F: .env: unknown field for a net profile" ]
}

@test "mount problems name the exact entry" {
    check fs user '{"mounts":[{"source":"/a","dest":"/b","perm":"readonly"},{"dest":"/c","perm":"ro","extra":1},"x"]}'
    [[ "$output" == *"$F: .mounts[0].perm: expected one of ro, rw, dev, forked, record, got \"readonly\""* ]]
    [[ "$output" == *"$F: .mounts[1].source: required"* ]]
    [[ "$output" == *"$F: .mounts[1].extra: unknown mount field"* ]]
    [[ "$output" == *"$F: .mounts[2]: expected an object, got \"x\""* ]]
}

@test "perm copy explains the split" {
    check cli user '{"mounts":[{"source":"/a","dest":"/b","perm":"copy"}]}'
    [[ "$output" == *".mounts[0].perm: \"copy\" has been split: use \"forked\""*"\"record\""* ]]
}

@test "field types and fixed values" {
    check fs user '{"description":3,"env":{"A":{"x":1}},"caps":"drop","userns":"yes","docker_api":"true","passthrough":["OK",2,"BAD-NAME"]}'
    [[ "$output" == *".description: expected a string, got 3"* ]]
    [[ "$output" == *".env.A: expected a string or number, got {\"x\":1}"* ]]
    [[ "$output" == *".caps: expected \"keep\", got \"drop\""* ]]
    [[ "$output" == *".userns: expected \"full\", got \"yes\""* ]]
    [[ "$output" == *".docker_api: expected true or false, got \"true\""* ]]
    [[ "$output" == *".passthrough[1]: expected a variable name, got 2"* ]]
    [[ "$output" == *".passthrough[2]: expected a variable name, got \"BAD-NAME\""* ]]
}

@test "ports, host_ports and allow entries" {
    check net user '{"ports":["https",0,443],"host_ports":["80/sctp",70000],"allow":["ok.example","1password.com","300.1.1.1/8","10.0.0.0/33","bad_host!"]}'
    [[ "$output" == *".ports[0]: expected a port 1-65535 or \"*\", got \"https\""* ]]
    [[ "$output" == *".ports[1]: expected a port 1-65535 or \"*\", got 0"* ]]
    if [[ "$output" == *".ports[2]"* ]]; then return 1; fi
    [[ "$output" == *".host_ports[0]: expected N, \"N/tcp\" or \"N/udp\" with N 1-65535, got \"80/sctp\""* ]]
    [[ "$output" == *".host_ports[1]: expected N, \"N/tcp\" or \"N/udp\" with N 1-65535, got 70000"* ]]
    [[ "$output" == *".allow[1]: expected an IPv4 address or CIDR, got \"1password.com\" (entries starting with a digit are read as addresses)"* ]]
    [[ "$output" == *".allow[2]: expected an IPv4 address or CIDR, got \"300.1.1.1/8\""* ]]
    [[ "$output" == *".allow[3]: expected an IPv4 address or CIDR, got \"10.0.0.0/33\""* ]]
    [[ "$output" == *".allow[4]: expected a hostname, *.hostname, * or a CIDR, got \"bad_host!\""* ]]
    if [[ "$output" == *".allow[0]"* ]]; then return 1; fi
}

@test "warnings: workingDirectory, non-IPv4 dns, wildcard suffix" {
    check fs user '{"workingDirectory":"/src"}'
    [ "$output" = "warning"$'\t'"$F: .workingDirectory: no longer honored; pass --wd /src instead" ]
    check net user '{"dns":"sdns://abc","allow":["*.example.com"]}'
    [[ "$output" == *"warning"$'\t'"$F: .dns: not a bare IPv4 address, so 1.1.1.1 is used instead"* ]]
    [[ "$output" == *"warning"$'\t'"$F: .allow[0]: *.example.com admits any address published under that suffix (see README, Threat model)"* ]]
}

@test "project profiles may not set restricted fields" {
    check fs project '{"caps":"keep","userns":"full","docker_api":true}'
    [[ "$output" == *"$F: .caps: project profiles may not set caps; move the profile to ~/.config/sbx/profiles/ to grant it"* ]]
    [[ "$output" == *"$F: .userns: project profiles may not set userns"* ]]
    [[ "$output" == *"$F: .docker_api: project profiles may not set docker_api"* ]]
    check net project '{"host_ports":[5432]}'
    [[ "$output" == *"$F: .host_ports: project profiles may not set host_ports"* ]]
    check fs user '{"caps":"keep"}'
    [ -z "$output" ]
}

@test "every shipped profile validates clean" {
    local f type
    for f in "$BATS_TEST_DIRNAME"/../profiles/*/*.json; do
        type=$(basename "$(dirname "$f")")
        run sbx_profile_check "$type" "$f" global
        if [[ "$output" == *"error"$'\t'* ]]; then
            echo "$output" >&2
            return 1
        fi
    done
}
