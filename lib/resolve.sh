#!/bin/bash
# The resolve step: flags and profiles in, one JSON launch plan out.
#
# Everything a launch decides about profiles is decided here, and nothing
# here touches the disk: no directory is created, nothing is seeded, no
# session name is claimed. sbx builds the sandbox from the plan, and
# --dry-run (phase 3) prints it, so the two cannot disagree.
#
# Requires lib/profiles.sh, lib/profile-check.sh and lib/net-merge.sh to be
# sourced first. Defines functions only — no side effects at source time,
# no dependency on sbx globals.

sbx_resolve_strings() {   # <string>... -> JSON array
    if [[ $# -eq 0 ]]; then
        echo '[]'
        return 0
    fi
    jq -cn '$ARGS.positional' --args -- "$@"
}

# A flat list of strings, <n> fields per record, as a JSON array of arrays.
# Fields travel as arguments, so any character but NUL survives.
sbx_resolve_records() {   # <n> <field>...
    local n="$1"
    shift
    jq -cn --argjson n "$n" '$ARGS.positional as $f | [range(0; $f | length; $n) as $i | $f[$i:$i + $n]]' \
        --args -- "$@"
}

# PATH inside the sandbox: <every profile's path entries, later profile
# first> in front of <env PATH>, then
# the default. With no entries, an env PATH stands alone.
sbx_resolve_path() {   # <entries, colon-joined> <env PATH>
    local default="/usr/local/bin:/usr/bin:/bin"
    if [[ -z "$1" ]]; then
        printf '%s\n' "${2:-$default}"
    else
        printf '%s\n' "$1:${2:+$2:}$default"
    fi
}

sbx_resolve() {
    local launch_dir="" config_dir="" global_dir="" wd="" gui=false
    local -a fs=() net=() flag_ports=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --launch-dir) launch_dir="$2"; shift 2 ;;
            --config-dir) config_dir="$2"; shift 2 ;;
            --global-dir) global_dir="$2"; shift 2 ;;
            --fs)         fs+=("$2"); shift 2 ;;
            --net)        net+=("$2"); shift 2 ;;
            --host-port)  flag_ports+=("$2"); shift 2 ;;
            --wd)         wd="$2"; shift 2 ;;
            --gui)        gui=true; shift ;;
            *)
                echo "sbx_resolve: unknown argument '$1'" >&2
                return 2
                ;;
        esac
    done

    # Every profile in the order the launch applies them: fs, then net.
    local -a types=() paths=() origins=()
    local p i
    for p in "${fs[@]}"; do types+=(fs); paths+=("$p"); done
    for p in "${net[@]}"; do types+=(net); paths+=("$p"); done

    local -a profiles=() errors=() warnings=() confirm=()

    # --host-port flags arrive exactly as typed; this is their only
    # validation. An out-of-range/non-numeric port or an unknown protocol
    # becomes a plan error instead of a bad bucket or a jq crash on
    # tonumber. A bare port means TCP only: pasta's -T and -U are
    # independent, so a UDP grant is always something someone asked for. Profile-supplied host_ports need no matching
    # check here: sbx_profile_check's schema already rejects any entry
    # that isn't a well-formed "N" or "N/tcp"|"N/udp" with N 1-65535, and
    # that rejection lands in $errors before the bucketing loop ever runs
    # (it is gated by the same "errors is empty" check below).
    local -a valid_flag_ports=()
    local fp fport fproto
    for fp in "${flag_ports[@]}"; do
        fport="${fp%%/*}"
        fproto=tcp
        if [[ "$fp" == */* ]]; then
            fproto="${fp#*/}"
        fi
        fproto="${fproto,,}"
        if [[ "$fport" =~ ^[0-9]+$ ]] && (( fport >= 1 && fport <= 65535 )) &&
           [[ "$fproto" == "tcp" || "$fproto" == "udp" ]]; then
            valid_flag_ports+=("$fp")
        else
            errors+=("--host-port expects <port>[/tcp|/udp] with a port 1-65535, got '$fp'")
        fi
    done
    flag_ports=("${valid_flag_ports[@]}")

    local type origin name level msg
    for i in "${!paths[@]}"; do
        type="${types[$i]}"
        p="${paths[$i]}"
        name=$(basename "$p" .json)
        origin=$(sbx_profile_origin "$p" "$launch_dir" "$config_dir" "$global_dir")
        origins+=("$origin")
        profiles+=("$type" "$name" "$p" "$origin")

        while IFS=$'\t' read -r level msg; do
            case "$level" in
                error)   errors+=("$msg") ;;
                warning) warnings+=("$msg") ;;
            esac
        done < <(sbx_profile_check "$type" "$p" "$origin")

        # A version-controlled project profile arrived with the repository;
        # using it is the user's explicit decision (see prompt_project_profile
        # in sbx). An untracked one is the user's own scratch config.
        if [[ "$origin" == "project" && "${SBX_TRUST_PROJECT_PROFILES:-}" != "1" ]] &&
           git -C "$launch_dir" ls-files --error-unmatch "$p" >/dev/null 2>&1; then
            confirm+=("$p")
        fi
    done

    # A cli/ directory is never read; say so rather than let a profile
    # there be ignored silently (see sbx_profile_legacy_cli_dirs).
    local legacy
    while IFS= read -r legacy; do
        warnings+=("$(sbx_profile_legacy_cli_warning "$legacy")")
    done < <(sbx_profile_legacy_cli_dirs "$config_dir" "$global_dir")

    local caps_keep=false caps_profile="" userns_full=false userns_profile="" docker_api=false
    local f_userns f_caps f_docker
    # profiles, mounts and env hold flat field lists (sbx_resolve_records),
    # turned into objects by one jq call each at the end.
    local -a mounts=() passthrough=() env=() tcp=() udp=()
    local sandbox_path="" sandbox_path_raw="" netns=false net_json='{"enabled":false}'
    local -a deps=(core) checks=()

    if [[ ${#errors[@]} -eq 0 ]]; then
        # --- Profile feature-field scan (phase 2 virt) ---
        # Optional fields honored in any applied fs profile:
        #   "userns": "full"    -> run the whole session inside an outer user
        #                          namespace carrying the user's full subordinate-
        #                          UID range (multi-UID podman). Requires --net.
        #                          Implies "caps": "keep".
        #   "caps": "keep"      -> retain capabilities inside the sandbox. Needed
        #                          for nested user namespaces (podman). Capabilities
        #                          are held inside the payload namespace B; the ro
        #                          mounts and the firewall ruleset belong to the
        #                          control namespace A and stay out of B's reach.
        #   "docker_api": true  -> start a podman docker-API socket for the session.
        #
        # None of these are honored from a project-supplied profile: a repository
        # must never be able to talk its way back to the pre-hardening boundary,
        # with or without the interactive confirmation added elsewhere.
        for i in "${!paths[@]}"; do
            if [[ "${types[$i]}" == "net" || "${origins[$i]}" == "project" ]]; then
                continue
            fi
            p="${paths[$i]}"
            IFS=$'\t' read -r f_userns f_caps f_docker < <(
                jq -r '[.userns // "-", .caps // "-", (.docker_api // false | tostring)] | @tsv' "$p")
            if [[ "$f_userns" == "full" ]]; then
                userns_full=true
                userns_profile="$p"
                caps_keep=true
                caps_profile="$p"
            fi
            if [[ "$f_caps" == "keep" ]]; then
                caps_keep=true
                caps_profile="$p"
            fi
            if [[ "$f_docker" == "true" ]]; then
                docker_api=true
            fi
        done
        if [[ "$userns_full" == "true" && ${#net[@]} -eq 0 ]]; then
            errors+=("profile '$userns_profile' sets \"userns\": \"full\", which requires networking. Add --net <profile>.")
        fi
    fi

    if [[ ${#errors[@]} -eq 0 ]]; then
        local kind f1 f2 f3 source dest perm present from value
        local -a path_entries=() profile_path=()
        for i in "${!paths[@]}"; do
            if [[ "${types[$i]}" == "net" ]]; then
                continue
            fi
            p="${paths[$i]}"
            name=$(basename "$p" .json)
            from="${types[$i]}/$name"
            profile_path=()

            # One jq pass per profile: every mount, passthrough name and env
            # entry, NUL-separated so a value may hold any character.
            while IFS= read -r -d '' kind && IFS= read -r -d '' f1 &&
                  IFS= read -r -d '' f2 && IFS= read -r -d '' f3; do
                case "$kind" in
                    mount)
                        source=$(realpath -m "$(printf '%s' "$f1" | envsubst)")
                        dest=$(printf '%s' "$f2" | envsubst)
                        perm="$f3"
                        present=false
                        if [[ -e "$source" ]]; then
                            present=true
                        fi
                        mounts+=("$name" "$from" "$source" "$dest" "$perm" "$present")
                        # An absent rw source is a persistent directory the
                        # launch creates, not one it skips: no warning.
                        if [[ "$present" == "false" && "$perm" == "record" ]]; then
                            warnings+=("$from: mount source not present on this host; an empty working copy is bound instead: record $source")
                        elif [[ "$present" == "false" && "$perm" != "rw" ]]; then
                            warnings+=("$from: mount source not present on this host, skipped: $perm $source")
                        fi
                        ;;
                    path)
                        profile_path+=("$f1")
                        ;;
                    pass)
                        if [[ -n "$f1" ]]; then
                            passthrough+=("$f1")
                        fi
                        ;;
                    env)
                        if [[ -n "$f1" ]]; then
                            value=$(printf '%s' "$f2" | envsubst)
                            env+=("$f1" "$value" "$f2" "$from")
                            if [[ "$f1" == "PATH" ]]; then
                                sandbox_path="$value"
                                sandbox_path_raw="$f2"
                            fi
                        fi
                        ;;
                esac
            done < <(jq -j 'def nul: [0] | implode;
                (.mounts[]? | "mount", nul, .source, nul, .dest, nul, .perm, nul),
                (.passthrough[]? | "pass", nul, ., nul, "", nul, "", nul),
                (.path[]? | "path", nul, ., nul, "", nul, "", nul),
                (.env // {} | to_entries[] | "env", nul, .key, nul, (.value | tostring), nul, "", nul)' "$p")
            # A later profile's entries go in front, as its env wins.
            path_entries=("${profile_path[@]}" "${path_entries[@]}")
        done

        # Every profile's path entries go in front of any PATH an env block
        # set, and the default closes the list (see sbx_resolve_path).
        local path_joined=""
        if [[ ${#path_entries[@]} -gt 0 ]]; then
            path_joined=$(printf '%s\n' "${path_entries[@]}" | paste -sd: -)
        fi
        sandbox_path=$(sbx_resolve_path "$(envsubst <<< "$path_joined")" "$sandbox_path")
        sandbox_path_raw=$(sbx_resolve_path "$path_joined" "$sandbox_path_raw")

        # --- Host-service access ---
        # Ports named here are forwarded by pasta from the host's loopback into the
        # sandbox's loopback at the same number, so a host service on 127.0.0.1:8080
        # answers at 127.0.0.1:8080 inside. Ports NOT named are not forwarded.
        #
        # This has to be explicit. pasta's default is -T auto, which forwards every
        # port bound on the host — including ports bound after the session starts,
        # and ports bound by other users — so an --net sandbox could reach every
        # host-local service without a single rule naming it. sbx passes an explicit
        # list (or "none") instead, which is what makes host access an allow-list
        # rather than an accident. It is also what stops a host service on :53 from
        # taking the port this session's dnsmasq needs.
        #
        # Not honored from a project profile, for the same reason userns/caps/
        # docker_api are not: a cloned repository must not be able to open a path
        # from its sandbox to a service on the machine running it.
        local spec port proto
        local -a specs=("${flag_ports[@]}")
        for i in "${!paths[@]}"; do
            if [[ "${types[$i]}" != "net" || "${origins[$i]}" == "project" ]]; then
                continue
            fi
            while IFS= read -r spec; do
                if [[ -n "$spec" ]]; then
                    specs+=("$spec")
                fi
            done < <(jq -r '.host_ports[]? | tostring' "${paths[$i]}")
        done
        for spec in "${specs[@]}"; do
            port="${spec%%/*}"
            proto=tcp
            if [[ "$spec" == */* ]]; then
                proto="${spec#*/}"
            fi
            case "${proto,,}" in
                tcp) tcp+=("$port") ;;
                udp) udp+=("$port") ;;
            esac
        done
        if [[ ${#tcp[@]} -gt 0 ]]; then
            mapfile -t tcp < <(printf '%s\n' "${tcp[@]}" | sort -n -u)
        fi
        if [[ ${#udp[@]} -gt 0 ]]; then
            mapfile -t udp < <(printf '%s\n' "${udp[@]}" | sort -n -u)
        fi

        if [[ ${#net[@]} -gt 0 ]]; then
            net_json=$(sbx_net_merge "${net[@]}" | jq -cS '. + {enabled: true}')
        fi
        if [[ ${#net[@]} -gt 0 || ${#tcp[@]} -gt 0 || ${#udp[@]} -gt 0 ]]; then
            netns=true
            deps+=(net)
        fi
        if [[ "$gui" == "true" ]]; then
            deps+=(gui)
        fi
        if [[ "$caps_keep" == "true" || "$userns_full" == "true" || "$docker_api" == "true" ]]; then
            deps+=(podman)
        fi
        # Host checks beyond "is the tool installed" that this session's
        # shape needs. unshare builds the control namespace for a session
        # with no networking and for userns: full (a plain networked session
        # gets it from pasta); userns: full also needs a subordinate id range.
        if [[ "$netns" != "true" || "$userns_full" == "true" ]]; then
            checks+=(nsunshare)
        fi
        if [[ "$userns_full" == "true" ]]; then
            checks+=(subids)
        fi
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        sandbox_path=""
        sandbox_path_raw=""
    fi

    jq -n \
        --argjson profiles "$(sbx_resolve_records 4 "${profiles[@]}" |
            jq -c 'map({type: .[0], name: .[1], path: .[2], origin: .[3]})')" \
        --argjson errors "$(sbx_resolve_strings "${errors[@]}")" \
        --argjson warnings "$(sbx_resolve_strings "${warnings[@]}")" \
        --argjson confirm "$(sbx_resolve_strings "${confirm[@]}")" \
        --argjson deps "$(sbx_resolve_strings "${deps[@]}")" \
        --argjson checks "$(sbx_resolve_strings "${checks[@]}")" \
        --argjson caps_keep "$caps_keep" --arg caps_profile "$caps_profile" \
        --argjson userns_full "$userns_full" --arg userns_profile "$userns_profile" \
        --argjson docker_api "$docker_api" \
        --argjson mounts "$(sbx_resolve_records 6 "${mounts[@]}" |
            jq -c 'map({profile: .[0], from: .[1], source: .[2], dest: .[3], perm: .[4], present: (.[5] == "true")})')" \
        --argjson passthrough "$(sbx_resolve_strings "${passthrough[@]}")" \
        --argjson env "$(sbx_resolve_records 4 "${env[@]}" |
            jq -c 'map({name: .[0], value: .[1], raw: .[2], from: .[3]})')" \
        --arg path "$sandbox_path" --arg path_raw "$sandbox_path_raw" --arg wd "$wd" --argjson gui "$gui" \
        --argjson tcp "$(sbx_resolve_strings "${tcp[@]}" | jq -c 'map(tonumber)')" \
        --argjson udp "$(sbx_resolve_strings "${udp[@]}" | jq -c 'map(tonumber)')" \
        --argjson netns "$netns" --argjson net "$net_json" \
        '{profiles: $profiles, errors: $errors, warnings: $warnings, confirm: $confirm, deps: $deps, checks: $checks,
          security: {caps_keep: $caps_keep, caps_profile: $caps_profile,
                     userns_full: $userns_full, userns_profile: $userns_profile,
                     docker_api: $docker_api},
          mounts: $mounts, passthrough: $passthrough, env: $env, path: $path, path_raw: $path_raw,
          wd: $wd, gui: $gui, host_ports: {tcp: $tcp, udp: $udp},
          netns: $netns, net: $net}'
}
