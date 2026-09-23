#!/bin/bash
# Human-readable output: the launch's warning sanitizer, and the --dry-run
# report.
#
# Defines functions and constants only — no side effects at source time,
# no dependency on sbx globals.

# Profile-authored text (mount sources, .workingDirectory) reaches this
# print loop verbatim from validation. Strip anything outside printable
# ASCII plus tab and cap the length before it ever reaches the terminal —
# a warning is not a trusted string, and the trust prompt printed just
# above it (see the confirm loop in sbx) is the one control between a
# cloned repository and an arbitrary mount set; nothing printed here may
# be able to repaint or crowd it. The --dry-run report below uses the jq
# `clean` filter instead, which keeps UTF-8.
sbx_sanitize_message() {   # <text>
    local msg="$1" clean
    clean=$(LC_ALL=C tr -cd '\11\40-\176' <<< "$msg")
    if [[ ${#clean} -gt 500 ]]; then
        clean="${clean:0:500}..."
    fi
    printf '%s' "$clean"
}

# The --dry-run report. Input: the plan from lib/resolve.sh plus .writes
# (lib/state-paths.sh) and .needs (lib/deps.sh). Every line passes through
# `clean`, which removes C0 controls, DEL and C1 controls — the bytes a
# terminal can act on — while keeping printable Unicode, because paths,
# env values and warnings come from profiles and profiles may come from a
# cloned repository.
# shellcheck disable=SC2016  # jq program: $vars are jq's, not the shell's
SBX_RENDER_JQ='
def clean: explode | map(select(
    ((. >= 32 and . < 127) or . > 159)
    and (. < 8203 or . > 8207)
    and (. < 8234 or . > 8238)
    and (. < 8294 or . > 8297)
  )) | implode;
def spaces($n): [range(0; $n)] | map(" ") | join("");
def pad($n): . + spaces($n - length);
def tilde:
  if $home != "" and . == $home then "~"
  elif $home != "" and startswith($home + "/") then "~" + .[($home | length):]
  else . end;
def section($title; $lines):
  $lines | to_entries[]
  | ((if .key == 0 then $title else "" end) | pad(10)) + " " + .value;
def mark($ok): if $ok then "✓" else "✗" end;

. as $d
| ( section("Profiles"; [ [ $d.profiles[] | "\(.type)/\(.name) (\(.origin))" ] | join("  ") | select(length > 0) ]),

    ( if ($d.errors | length) == 0 then
        section("Security"; [ [ (if $d.security.caps_keep then "capabilities KEPT in the payload namespace (\($d.security.caps_profile | tilde))" else "capabilities dropped; mounts and the firewall are enforced from outside the payload namespace" end),
                                (if $d.security.userns_full then "userns full" else "no userns" end),
                                (if $d.security.docker_api then "docker API" else "no docker API" end) ] | join(" · ") ])
      else empty end ),

    section("Mounts"; [ $d.mounts[] as $m
        | ($d.writes | map(select(.dest == $m.dest and .source == $m.source and .note != "")) | .[0]) as $w
        | ((if ($m.present | not) and $m.perm != "rw" and $m.perm != "record" then "skip" else $m.perm end) | pad(7))
          + " " + ($m.source | tilde) + " → " + ($m.dest | tilde)
          + ( if ($m.present | not) and $m.perm == "record" then "  (source absent; empty working copy)"
              elif ($m.present | not) and $m.perm != "rw" then "  (source absent)"
              elif $w != null then "  (\($w.note))"
              else "" end )
          + "  " + $m.from ]),

    section("Env"; [ $d.env | map(select(.name != "PATH")) | group_by(.name)[]
        | .[-1] as $win
        | "\($win.name)=\($win.raw)  (\($win.from)"
          + (.[:-1] | map(.from) | unique | if length > 0 then "; overrides " + join(", ") else "" end)
          + ")" ]),

    section("Path"; [ $d.path_raw | select(length > 0) | ($d.session.dir + "bin:" + .) | tilde ]),

    section("Passthru"; [ $d.passthrough | unique | select(length > 0)
        | map(. as $n
              | $n + (if (($d.passthrough_set // []) | index($n)) then
                        (if ($d.env | any(.name == $n)) then " (overridden by env)" else "" end)
                      else " (unset on host)" end))
        | join(", ") ]),

    ( if ($d.errors | length) > 0 then empty
      elif ($d.netns | not) then section("Network"; ["none (no network namespace)"])
      else section("Network"; [
          ( if $d.net.enabled then "dns " + ($d.net.upstreams | join(", ")) else "no internet; host ports only" end ),
          ( ($d.net.domains // {}) | to_entries | group_by(.value.ports)[]
              | "ports \(.[0].value.ports): " + (map(.key) | join(", ")) ),
          ( ($d.net.cidrs // {}) | to_entries | select(length > 0)
              | "addresses: " + (map("\(.key) (ports \(.value))") | join(", ")) ),
          ( if $d.net.allow_all then "any domain (ports \($d.net.allow_all_ports))" else empty end ),
          ( [ ($d.host_ports.tcp | select(length > 0) | "tcp " + (map(tostring) | join(","))),
              ($d.host_ports.udp | select(length > 0) | "udp " + (map(tostring) | join(","))) ]
            | select(length > 0) | "host ports: " + join("; ") )
        ]) end ),

    ( if ($d.errors | length) > 0 then empty
      else section("Writes"; [ $d.writes[]
          | (.kind | pad(10)) + " " + (.path | tilde)
            + "  (" + .detail + (if .note != "" then "; " + .note else "" end) + ")" ]) end ),

    section("Needs"; [
        ( [ ($d.needs.groups | to_entries[]
              | if (.value | length) == 0 then "\(.key) ✓" else "\(.key) ✗ missing \(.value | join(" "))" end),
            (if $d.needs.userns == null then empty else "userns \(mark($d.needs.userns))" end),
            (if $d.needs.subids == null then empty else "subuid/subgid \(mark($d.needs.subids))" end),
            (if $d.needs.veth == null then empty else "veth \(mark($d.needs.veth))" end)
          ] | join(" · ") ),
        ( $d.needs.install[] | "install: " + . )
      ]),

    section("Confirm"; [ $d.confirm[] | tilde + " would prompt (a launch without a terminal refuses instead)" ]),
    section("Warnings"; $d.warnings),
    section("Errors"; $d.errors),
    section("Stops"; $d.stops // []),
    section("Result"; [ if $d.proceed then "the launch would proceed" else "the launch would stop" end ])
  )
| clean
'

sbx_render_plan() {   # <dry-run document json> <home>
    jq -r --arg home "$2" "$SBX_RENDER_JQ" <<< "$1"
}
