#!/usr/bin/env bash
# rth — setup + doctor
# shellcheck shell=bash

rth_example_config_src() {
  if [[ -f "$RTH_ROOT/config/hosts.example.conf" ]]; then
    printf '%s' "$RTH_ROOT/config/hosts.example.conf"
  elif [[ -f "$RTH_ROOT/config/hosts.conf.example" ]]; then
    printf '%s' "$RTH_ROOT/config/hosts.conf.example"
  else
    printf ''
  fi
}

rth_cmd_setup() {
  local non_interactive=0
  local easy=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive) non_interactive=1; shift ;;
      --easy-mode) easy=1; non_interactive=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: rth setup [--non-interactive] [--easy-mode]

  Create ~/.config/rth/hosts.conf from example, ensure SSH key,
  print per-OS checklist, optionally smoke local env.
EOF
        return 0
        ;;
      *) rth_die "setup: unknown flag $1" ;;
    esac
  done

  local cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rth"
  local cfg="$cfg_dir/hosts.conf"
  mkdir -p "$cfg_dir"

  local example
  example="$(rth_example_config_src)"
  if [[ ! -f "$cfg" ]]; then
    if [[ -n "$example" && -f "$example" ]]; then
      cp "$example" "$cfg"
      rth_ok "Wrote $cfg from example"
    else
      rth_die "Missing example config under $RTH_ROOT/config/"
    fi
  else
    rth_log "Config already exists: $cfg"
  fi

  # SSH key
  local key="$HOME/.ssh/id_ed25519"
  local pub="${key}.pub"
  if [[ ! -f "$key" ]]; then
    if [[ $non_interactive -eq 1 ]] || [[ $easy -eq 1 ]]; then
      mkdir -p "$HOME/.ssh"
      chmod 700 "$HOME/.ssh"
      ssh-keygen -t ed25519 -N '' -f "$key" -C "rth@$(hostname -s 2>/dev/null || echo host)"
      rth_ok "Generated $key"
    else
      rth_warn "No $key — generate with:"
      echo "  ssh-keygen -t ed25519 -C \"rth@\$(hostname)\"" >&2
    fi
  else
    rth_ok "SSH key present: $key"
  fi

  if [[ -f "$pub" ]]; then
    echo "" >&2
    rth_log "Public key (install on remote authorized_keys):"
    cat "$pub" >&2
    echo "" >&2
  fi

  cat <<'EOF' >&2

── Checklist ──────────────────────────────────────────
Mac (if others SSH in):
  System Settings → General → Sharing → Remote Login ON
  Or: sudo systemsetup -setremotelogin on

Windows OpenSSH Server (Admin PowerShell):
  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
  Start-Service sshd
  Set-Service -Name sshd -StartupType Automatic
  # Firewall rule usually auto-created

  Public key paths:
  • Normal user:  C:\Users\<you>\.ssh\authorized_keys
  • Administrators group:
      C:\ProgramData\ssh\administrators_authorized_keys
    (strict ACL required — see docs/SSH_WINDOWS.md)

Ubuntu WSL (v1 hop via Windows):
  wsl -l -v
  # Ensure distro name matches ubuntu_distro in hosts.conf
  # rth uses: ssh win 'wsl -d Ubuntu -- bash -lc "…"'

Edit hosts:
  $EDITOR ~/.config/rth/hosts.conf

Then:
  rth doctor
  rth matrix -- 'echo rth-ok'
───────────────────────────────────────────────────────
EOF

  if [[ $easy -eq 1 ]]; then
    # shellcheck disable=SC1090
    source "$cfg" 2>/dev/null || true
    if declare -F rth_load_config >/dev/null 2>&1; then
      RTH_CONFIG="$cfg" rth_load_config 2>/dev/null || true
    fi
  fi

  rth_ok "setup done — edit $cfg then run: rth doctor"
}

rth_cmd_doctor() {
  rth_load_config
  local envs=() e
  while IFS= read -r e; do
    [[ -n "$e" ]] && envs+=("$e")
  done < <(rth_selected_envs)

  local ok_count=0 fail_count=0
  local results=()

  if [[ "$RTH_JSON" != "1" ]]; then
    rth_log "doctor — probing ${#envs[@]} env(s) from $(rth_config_path)"
  fi

  for e in "${envs[@]}"; do
    local kind label host shell
    kind="$(rth_get "$e" kind)"
    label="$(rth_get "$e" label)"
    host="$(rth_get "$e" host)"
    shell="$(rth_get "$e" shell)"
    kind="${kind:-ssh}"
    label="${label:-$e}"

    local probe_cmd="echo rth-doctor-ok"
    case "$shell" in
      cmd) probe_cmd="echo rth-doctor-ok" ;;
      powershell|pwsh) probe_cmd="Write-Output rth-doctor-ok" ;;
    esac

    local prefix=""
    if [[ "$RTH_JSON" != "1" ]]; then
      prefix=""
      rth_log "probe $e ($kind) $label ${host:+host=$host}"
    fi

    if rth_exec_env "$e" "" "$probe_cmd" >/dev/null 2>&1; then
      local id_out=""
      case "$kind" in
        local|ssh)
          if [[ "$shell" == "cmd" ]]; then
            rth_exec_env "$e" "" "ver" >/dev/null 2>&1 || true
            id_out="$RTH_LAST_STDOUT"
          elif [[ "$shell" == "powershell" || "$shell" == "pwsh" ]]; then
            rth_exec_env "$e" "" "\$PSVersionTable.PSVersion.ToString()" >/dev/null 2>&1 || true
            id_out="$RTH_LAST_STDOUT"
          else
            rth_exec_env "$e" "" "uname -a 2>/dev/null || ver" >/dev/null 2>&1 || true
            id_out="$RTH_LAST_STDOUT"
          fi
          ;;
        wsl)
          rth_exec_env "$e" "" "uname -a" >/dev/null 2>&1 || true
          id_out="$RTH_LAST_STDOUT"
          ;;
      esac
      # re-run probe for clean exit
      rth_exec_env "$e" "" "$probe_cmd" >/dev/null 2>&1
      local mex=$?
      if [[ $mex -eq 0 ]]; then
        ok_count=$((ok_count + 1))
        if [[ "$RTH_JSON" != "1" ]]; then
          rth_ok "$e OK  ${id_out//$'\n'/ }"
        fi
        results+=("$(printf '{"env":"%s","ok":true,"kind":"%s","detail":"%s"}' \
          "$(json_escape "$e")" "$(json_escape "$kind")" "$(json_escape "$id_out")")")
      else
        fail_count=$((fail_count + 1))
        if [[ "$RTH_JSON" != "1" ]]; then
          rth_err "$e FAIL exit=$mex — check SSH keys / host / WSL (docs/SSH_WINDOWS.md)"
        fi
        results+=("$(printf '{"env":"%s","ok":false,"kind":"%s","exit":%s,"stderr":"%s"}' \
          "$(json_escape "$e")" "$(json_escape "$kind")" "$mex" "$(json_escape "$RTH_LAST_STDERR")")")
      fi
    else
      fail_count=$((fail_count + 1))
      if [[ "$RTH_JSON" != "1" ]]; then
        rth_err "$e FAIL — unreachable or auth error"
        rth_err "  next: verify host/user in config; BatchMode key auth; for Admin Windows see administrators_authorized_keys"
        [[ "$kind" == "wsl" ]] && rth_err "  WSL: on Windows run  wsl -e true   and check ubuntu_distro name"
      fi
      results+=("$(printf '{"env":"%s","ok":false,"kind":"%s","exit":%s,"stderr":"%s"}' \
        "$(json_escape "$e")" "$(json_escape "$kind")" "${RTH_LAST_EXIT:-1}" "$(json_escape "${RTH_LAST_STDERR-}")")")
    fi
  done

  if [[ "$RTH_JSON" == "1" ]]; then
    local first=1
    printf '{"ok":%s,"ok_count":%s,"fail_count":%s,"results":[' \
      "$([[ $fail_count -eq 0 ]] && echo true || echo false)" "$ok_count" "$fail_count"
    for r in "${results[@]}"; do
      [[ $first -eq 1 ]] || printf ','
      first=0
      printf '%s' "$r"
    done
    printf ']}\n'
  else
    printf '%s── doctor: %s ok, %s fail ──%s\n' \
      "$(_rth_color bold)" "$ok_count" "$fail_count" "$(_rth_color reset)" >&2
  fi

  if [[ $fail_count -eq 0 ]]; then
    return 0
  elif [[ $ok_count -eq 0 ]]; then
    return 3
  else
    return 2
  fi
}

rth_cmd_status() {
  rth_load_config
  local e
  if [[ "$RTH_JSON" == "1" ]]; then
    printf '{"envs":['
    local first=1
    for e in $(rth_selected_envs); do
      [[ $first -eq 1 ]] || printf ','
      first=0
      printf '{"name":"%s","kind":"%s","label":"%s","host":"%s","shell":"%s"}' \
        "$(json_escape "$e")" \
        "$(json_escape "$(rth_get "$e" kind)")" \
        "$(json_escape "$(rth_get "$e" label)")" \
        "$(json_escape "$(rth_get "$e" host)")" \
        "$(json_escape "$(rth_get "$e" shell)")"
    done
    printf ']}\n'
    return 0
  fi
  printf '%-10s %-8s %-20s %-22s %s\n' "ENV" "KIND" "LABEL" "HOST" "SHELL"
  printf '%-10s %-8s %-20s %-22s %s\n' "---" "----" "-----" "----" "-----"
  for e in $(rth_selected_envs); do
    printf '%-10s %-8s %-20s %-22s %s\n' \
      "$e" \
      "$(rth_get "$e" kind)" \
      "$(rth_get "$e" label)" \
      "$(rth_get "$e" host)" \
      "$(rth_get "$e" shell)"
  done
}

rth_cmd_list() {
  rth_load_config
  if [[ "$RTH_JSON" == "1" ]]; then
    printf '{"envs":['
    local first=1 e
    for e in $(rth_env_list); do
      [[ $first -eq 1 ]] || printf ','
      first=0
      printf '"%s"' "$(json_escape "$e")"
    done
    printf ']}\n'
  else
    rth_env_list
  fi
}
