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

sbx_resolve_objects() {   # <json object>... -> JSON array
    if [[ $# -eq 0 ]]; then
        echo '[]'
        return 0
    fi
    printf '%s\n' "$@" | jq -cs .
}

sbx_resolve() {
    local launch_dir="" config_dir="" global_dir="" wd="" gui=false cli=""
    local -a fs=() net=() flag_ports=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --launch-dir) launch_dir="$2"; shift 2 ;;
            --config-dir) config_dir="$2"; shift 2 ;;
            --global-dir) global_dir="$2"; shift 2 ;;
            --fs)         fs+=("$2"); shift 2 ;;
            --cli)        cli="$2"; shift 2 ;;
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

    # Every profile in the order the launch applies them: fs, cli, net.
    local -a types=() paths=() origins=()
    local p i
    for p in "${fs[@]}"; do types+=(fs); paths+=("$p"); done
    if [[ -n "$cli" ]]; then
        types+=(cli); paths+=("$cli")
    fi
    for p in "${net[@]}"; do types+=(net); paths+=("$p"); done

    local -a profiles=() errors=() warnings=() confirm=()

    # --host-port flags are user-typed, so validate each one the same way
    # sbx's add_host_port does, before it can reach a bucketing loop that
    # assumes a well-formed spec: an out-of-range/non-numeric port or an
    # unknown protocol becomes a plan error instead of a bad bucket or a
    # jq crash on tonumber. Profile-supplied host_ports need no matching
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
        profiles+=("$(jq -cn --arg type "$type" --arg name "$name" --arg path "$p" --arg origin "$origin" \
            '{type: $type, name: $name, path: $path, origin: $origin}')")

        while IFS=$'\t' read -r level msg; do
            case "$level" in
                error)   errors+=("$msg") ;;
                warning) warnings+=("$msg") ;;
            esac
        done < <(sbx_profile_check "$type" "$p" "$origin")

        # A version-controlled project profile arrived with the repository;
        # using it is the user's explicit decision (see confirm_project_profile
        # in sbx). An untracked one is the user's own scratch config.
        if [[ "$origin" == "project" && "${SBX_TRUST_PROJECT_PROFILES:-}" != "1" ]] &&
           git -C "$launch_dir" ls-files --error-unmatch "$p" >/dev/null 2>&1; then
            confirm+=("$p")
        fi
    done

    local caps_keep=false caps_profile="" userns_full=false userns_profile="" docker_api=false
    local -a mounts=() passthrough=() env=() tcp=() udp=()
    local sandbox_path="" sandbox_path_raw="" netns=false net_json='{"enabled":false}'
    local -a deps=(core)

    if [[ ${#errors[@]} -eq 0 ]]; then
        # --- Profile feature-field scan (phase 2 virt) ---
        # Optional fields honored in any applied fs/cli profile:
        #   "userns": "full"    -> run the whole session inside an outer user
        #                          namespace carrying the user's full subordinate-
        #                          UID range (multi-UID podman). Requires --net.
        #                          Implies "caps": "keep".
        #   "caps": "keep"      -> retain capabilities inside the sandbox. Needed
        #                          for nested user namespaces (podman), and it
        #                          costs the ro-mount and firewall guarantees.
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
            if [[ "$(jq -r '.userns // empty' "$p")" == "full" ]]; then
                userns_full=true
                userns_profile="$p"
                caps_keep=true
                caps_profile="$p"
            fi
            if [[ "$(jq -r '.caps // empty' "$p")" == "keep" ]]; then
                caps_keep=true
                caps_profile="$p"
            fi
            if [[ "$(jq -r '.docker_api // false' "$p")" == "true" ]]; then
                docker_api=true
            fi
        done
        if [[ "$userns_full" == "true" && ${#net[@]} -eq 0 ]]; then
            errors+=("profile '$userns_profile' sets \"userns\": \"full\", which requires networking. Add --net <profile>.")
        fi
    fi

    if [[ ${#errors[@]} -eq 0 ]]; then
        local m source dest perm present from key value var extra
        for i in "${!paths[@]}"; do
            if [[ "${types[$i]}" == "net" ]]; then
                continue
            fi
            p="${paths[$i]}"
            name=$(basename "$p" .json)
            from="${types[$i]}/$name"

            while IFS= read -r m; do
                if [[ -z "$m" ]]; then
                    continue
                fi
                source=$(jq -r '.source' <<< "$m" | envsubst)
                source=$(realpath -m "$source")
                dest=$(jq -r '.dest' <<< "$m" | envsubst)
                perm=$(jq -r '.perm' <<< "$m")
                present=false
                if [[ -e "$source" ]]; then
                    present=true
                fi
                mounts+=("$(jq -cn --arg profile "$name" --arg from "$from" --arg source "$source" \
                    --arg dest "$dest" --arg perm "$perm" --argjson present "$present" \
                    '{profile: $profile, from: $from, source: $source, dest: $dest, perm: $perm, present: $present}')")
                # rw mounts may point at a persistent host directory that doesn't
                # exist yet (e.g. first-ever use of a profile's storage dir), so
                # an absent rw source is created by the launch, not skipped, and
                # not worth a warning.
                if [[ "$present" == "false" && "$perm" != "rw" ]]; then
                    if [[ "$perm" == "record" ]]; then
                        warnings+=("$from: mount source not present on this host; an empty working copy is bound instead: record $source")
                    else
                        warnings+=("$from: mount source not present on this host, skipped: $perm $source")
                    fi
                fi
            done < <(jq -c '.mounts[]?' "$p")

            while IFS= read -r var; do
                if [[ -n "$var" ]]; then
                    passthrough+=("$var")
                fi
            done < <(jq -r '.passthrough[]?' "$p")

            # NUL-separated so a value may hold any character, newlines included.
            while IFS= read -r -d '' key && IFS= read -r -d '' value; do
                if [[ -z "$key" ]]; then
                    continue
                fi
                raw="$value"
                value=$(printf '%s' "$value" | envsubst)
                env+=("$(jq -cn --arg name "$key" --arg value "$value" --arg raw "$raw" --arg from "$from" \
                    '{name: $name, value: $value, raw: $raw, from: $from}')")
                if [[ "$key" == "PATH" ]]; then
                    sandbox_path="$value"
                    sandbox_path_raw="$raw"
                fi
            done < <(jq -j 'def nul: [0] | implode; .env // {} | to_entries[] | .key, nul, (.value | tostring), nul' "$p")
        done

        # A cli profile's path entries go in front of any PATH an env block
        # set, and the default always closes the list.
        local default_path="/usr/local/bin:/usr/bin:/bin"
        local extra_raw=""
        extra=""
        if [[ -n "$cli" ]]; then
            extra=$(jq -r '.path[]?' "$cli" | envsubst | paste -sd: -)
            extra_raw=$(jq -r '.path[]?' "$cli" | paste -sd: -)
        fi
        if [[ -n "$extra" ]]; then
            if [[ -n "$sandbox_path" ]]; then
                sandbox_path="$extra:$sandbox_path:$default_path"
            else
                sandbox_path="$extra:$default_path"
            fi
        elif [[ -z "$sandbox_path" ]]; then
            sandbox_path="$default_path"
        fi
        if [[ -n "$extra_raw" ]]; then
            if [[ -n "$sandbox_path_raw" ]]; then
                sandbox_path_raw="$extra_raw:$sandbox_path_raw:$default_path"
            else
                sandbox_path_raw="$extra_raw:$default_path"
            fi
        elif [[ -z "$sandbox_path_raw" ]]; then
            sandbox_path_raw="$default_path"
        fi

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
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        sandbox_path=""
        sandbox_path_raw=""
    fi

    jq -n \
        --argjson profiles "$(sbx_resolve_objects "${profiles[@]}")" \
        --argjson errors "$(sbx_resolve_strings "${errors[@]}")" \
        --argjson warnings "$(sbx_resolve_strings "${warnings[@]}")" \
        --argjson confirm "$(sbx_resolve_strings "${confirm[@]}")" \
        --argjson deps "$(sbx_resolve_strings "${deps[@]}")" \
        --argjson caps_keep "$caps_keep" --arg caps_profile "$caps_profile" \
        --argjson userns_full "$userns_full" --arg userns_profile "$userns_profile" \
        --argjson docker_api "$docker_api" \
        --argjson mounts "$(sbx_resolve_objects "${mounts[@]}")" \
        --argjson passthrough "$(sbx_resolve_strings "${passthrough[@]}")" \
        --argjson env "$(sbx_resolve_objects "${env[@]}")" \
        --arg path "$sandbox_path" --arg path_raw "$sandbox_path_raw" --arg wd "$wd" --argjson gui "$gui" \
        --argjson tcp "$(sbx_resolve_strings "${tcp[@]}" | jq -c 'map(tonumber)')" \
        --argjson udp "$(sbx_resolve_strings "${udp[@]}" | jq -c 'map(tonumber)')" \
        --argjson netns "$netns" --argjson net "$net_json" \
        '{profiles: $profiles, errors: $errors, warnings: $warnings, confirm: $confirm, deps: $deps,
          security: {caps_keep: $caps_keep, caps_profile: $caps_profile,
                     userns_full: $userns_full, userns_profile: $userns_profile,
                     docker_api: $docker_api},
          mounts: $mounts, passthrough: $passthrough, env: $env, path: $path, path_raw: $path_raw,
          wd: $wd, gui: $gui, host_ports: {tcp: $tcp, udp: $udp},
          netns: $netns, net: $net}'
}
