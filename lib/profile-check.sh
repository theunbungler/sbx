#!/bin/bash
# Profile validation. One jq program checks a profile against the schema
# for its type and reports every problem at once, each naming the JSON path
# it is about.
#
# Sourced by sbx and directly by tests/. Defines a constant and a function
# only — no side effects at source time, no dependency on sbx globals.
#
# Unknown fields are errors, not ignored: a typo like "mount" would
# otherwise silently grant or withhold nothing. There is deliberately no
# comment convention.

# shellcheck disable=SC2016  # jq program: $vars are jq's, not the shell's
SBX_PROFILE_CHECK_JQ='
def known:
  { cli: ["description","env","path","mounts","passthrough","caps","userns","docker_api","workingDirectory"],
    fs:  ["description","mounts","env","passthrough","caps","userns","docker_api","workingDirectory"],
    net: ["description","dns","allow","ports","host_ports"] };
def restricted: ["caps","userns","docker_api","host_ports"];
def err($p; $m): {level: "error", path: $p, message: $m};
def warn($p; $m): {level: "warning", path: $p, message: $m};
def show: if type == "string" then . else tojson end;
def is_port: type == "number" and . == floor and . >= 1 and . <= 65535;
def is_ipv4: test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$") and (split(".") | all(tonumber <= 255));
def is_cidr:
  (split("/")) as $parts
  | if ($parts | length) == 1 then $parts[0] | is_ipv4
    elif ($parts | length) == 2 then ($parts[0] | is_ipv4) and ($parts[1] | test("^[0-9]{1,2}$") and (tonumber <= 32))
    else false end;
def is_host_glob:
  . == "*" or test("^(\\*\\.)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$");
def is_var_name: type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$");
def has_ctrl: any(explode[]; . < 32);

if type != "object" then [err("."; "expected a JSON object at the top level")]
else
  . as $p
  | [ ( keys[] | . as $k | select(known[$type] | any(. == $k) | not)
        | err(".\($k)"; "unknown field for a \($type) profile") ),

      ( if has("description") and (.description | type) != "string"
        then err(".description"; "expected a string, got \(.description | tojson)") else empty end ),

      ( if has("env") then
          if (.env | type) != "object" then err(".env"; "expected an object, got \(.env | tojson)")
          else .env | to_entries[] | select(.value | type | IN("string", "number") | not)
               | err(".env.\(.key)"; "expected a string or number, got \(.value | tojson)")
          end
        else empty end ),

      ( if has("env") and (.env | type) == "object" then
          ( .env | keys[] | select(has_ctrl) | err(".env.\(.)"; "expected no control characters") ),
          ( .env | to_entries[] | select(.value | type == "string" and has_ctrl)
               | err(".env.\(.key)"; "expected no control characters") )
        else empty end ),

      ( if has("path") then
          if (.path | type) != "array" then err(".path"; "expected an array of strings, got \(.path | tojson)")
          else .path | to_entries[] | select(.value | type != "string")
               | err(".path[\(.key)]"; "expected a string, got \(.value | tojson)")
          end
        else empty end ),

      ( if has("passthrough") then
          if (.passthrough | type) != "array" then err(".passthrough"; "expected an array of variable names, got \(.passthrough | tojson)")
          else .passthrough | to_entries[] | select(.value | is_var_name | not)
               | err(".passthrough[\(.key)]"; "expected a variable name, got \(.value | tojson)")
          end
        else empty end ),

      ( if has("mounts") then
          if (.mounts | type) != "array" then err(".mounts"; "expected an array, got \(.mounts | tojson)")
          else .mounts | to_entries[] | .key as $i | .value as $m
               | if ($m | type) != "object" then err(".mounts[\($i)]"; "expected an object, got \($m | tojson)")
                 else
                   ( ($m | keys[] | select(IN("source", "dest", "perm") | not)
                        | err(".mounts[\($i)].\(.)"; "unknown mount field")),
                     ( ("source", "dest") as $f
                        | if ($m | has($f)) | not then err(".mounts[\($i)].\($f)"; "required")
                          elif ($m[$f] | type) != "string" then err(".mounts[\($i)].\($f)"; "expected a string, got \($m[$f] | tojson)")
                          elif ($m[$f] | has_ctrl) then err(".mounts[\($i)].\($f)"; "expected no control characters")
                          else empty end ),
                     ( if ($m | has("perm")) | not then err(".mounts[\($i)].perm"; "required")
                       elif $m.perm == "copy" then err(".mounts[\($i)].perm"; "\"copy\" has been split: use \"forked\" if the sandbox owns the data (seeded from the host once), \"record\" if the host owns it (reseeded every launch, changes archived)")
                       elif ($m.perm | IN("ro", "rw", "dev", "forked", "record")) | not then err(".mounts[\($i)].perm"; "expected one of ro, rw, dev, forked, record, got \($m.perm | tojson)")
                       else empty end ) )
                 end
          end
        else empty end ),

      ( if has("caps") and .caps != "keep" then err(".caps"; "expected \"keep\", got \(.caps | tojson)") else empty end ),
      ( if has("userns") and .userns != "full" then err(".userns"; "expected \"full\", got \(.userns | tojson)") else empty end ),
      ( if has("docker_api") and (.docker_api | type) != "boolean" then err(".docker_api"; "expected true or false, got \(.docker_api | tojson)") else empty end ),

      ( if has("workingDirectory") then warn(".workingDirectory"; "no longer honored; pass --wd \(.workingDirectory | show) instead") else empty end ),

      ( if has("dns") then
          if (.dns | type) != "string" then err(".dns"; "expected a string, got \(.dns | tojson)")
          elif (.dns | is_ipv4) | not then warn(".dns"; "not a bare IPv4 address, so 1.1.1.1 is used instead")
          else empty end
        else empty end ),

      ( if has("allow") then
          if (.allow | type) != "array" then err(".allow"; "expected an array, got \(.allow | tojson)")
          else .allow | to_entries[] | .key as $i | .value as $a
               | if ($a | type) != "string" then err(".allow[\($i)]"; "expected a string, got \($a | tojson)")
                 elif ($a | has_ctrl) then err(".allow[\($i)]"; "expected no control characters")
                 elif ($a | test("^[0-9]")) then
                   ( if ($a | is_cidr) then empty
                     else err(".allow[\($i)]"; "expected an IPv4 address or CIDR, got \($a | tojson) (entries starting with a digit are read as addresses)") end )
                 elif ($a | is_host_glob) | not then err(".allow[\($i)]"; "expected a hostname, *.hostname, * or a CIDR, got \($a | tojson)")
                 elif ($a | startswith("*.")) then warn(".allow[\($i)]"; "\($a) admits any address published under that suffix (see README, Threat model)")
                 else empty end
          end
        else empty end ),

      ( if has("ports") then
          if (.ports | type) != "array" then err(".ports"; "expected an array, got \(.ports | tojson)")
          else .ports | to_entries[] | select((.value == "*") or (.value | is_port) | not)
               | err(".ports[\(.key)]"; "expected a port 1-65535 or \"*\", got \(.value | tojson)")
          end
        else empty end ),

      ( if has("host_ports") then
          if (.host_ports | type) != "array" then err(".host_ports"; "expected an array, got \(.host_ports | tojson)")
          else .host_ports | to_entries[]
               | select(.value
                   | (is_port)
                     or (type == "string" and test("^[0-9]+(/(tcp|udp))?$") and (split("/")[0] | tonumber | is_port))
                   | not)
               | err(".host_ports[\(.key)]"; "expected N, \"N/tcp\" or \"N/udp\" with N 1-65535, got \(.value | tojson)")
          end
        else empty end ),

      ( if $origin == "project" then
          restricted[] as $f
          | select(($p | has($f)) and (known[$type] | any(. == $f)))
          | err(".\($f)"; "project profiles may not set \($f); move the profile to ~/.config/sbx/profiles/ to grant it")
        else empty end )
    ]
end
| .[] | "\(.level)\t\(.path): \(.message)"
'

sbx_profile_check() {   # <type> <file> <origin>
    local type="$1" file="$2" origin="$3" out level rest
    if ! out=$(jq -r --arg type "$type" --arg origin "$origin" "$SBX_PROFILE_CHECK_JQ" "$file" 2>&1); then
        printf 'error\t%s: invalid JSON: %s\n' "$file" "${out%%$'\n'*}"
        return 0
    fi
    while IFS=$'\t' read -r level rest; do
        if [[ -n "$level" ]]; then
            printf '%s\t%s: %s\n' "$level" "$file" "$rest"
        fi
    done <<< "$out"
    return 0
}
