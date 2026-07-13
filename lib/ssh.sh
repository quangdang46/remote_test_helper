#!/usr/bin/env bash
# rth — local / ssh / wsl execution
# shellcheck shell=bash

# Escape a string for single-quoted shell embedding: ' -> '\''
rth_shell_single_quote() {
  local s=$1
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# Build remote command string for a given shell kind
# Args: shell_kind  command...
rth_wrap_command() {
  local shell_kind="$1"
  shift
  local cmd="$*"
  case "$shell_kind" in
    bash|sh)
      printf 'bash -lc %s' "$(rth_shell_single_quote "$cmd")"
      ;;
    cmd)
      # cmd /c "..." — escape double quotes
      local esc=${cmd//\"/\\\"}
      printf 'cmd /c "%s"' "$esc"
      ;;
    powershell|pwsh)
      local esc=${cmd//\'/\'\'}
      printf "powershell -NoProfile -NonInteractive -Command '%s'" "$esc"
      ;;
    *)
      rth_die "Unknown shell kind: $shell_kind"
      ;;
  esac
}

# SSH target user@host -p port
rth_ssh_target() {
  local env="$1"
  local user host port
  user="$(rth_get "$env" user)"
  host="$(rth_get "$env" host)"
  port="$(rth_get "$env" port)"
  port="${port:-22}"
  [[ -n "$host" ]] || rth_die "env $env: host is empty — edit $(rth_config_path)"
  if [[ -n "$user" ]]; then
    printf '%s@%s' "$user" "$host"
  else
    printf '%s' "$host"
  fi
  # port returned via global for callers that need -p
  RTH_LAST_PORT="$port"
}

# Run a command on one env. Streams stdout/stderr with optional prefix.
# Sets: RTH_LAST_EXIT, RTH_LAST_STDOUT, RTH_LAST_STDERR, RTH_LAST_MS
# Args: env  prefix(empty ok)  command...
rth_exec_env() {
  local env="$1"
  local prefix="$2"
  shift 2
  local cmd="$*"
  local kind shell distro workdir wrapped target port start end out_file err_file exit_file
  kind="$(rth_get "$env" kind)"
  kind="${kind:-ssh}"
  shell="$(rth_get "$env" shell)"
  if [[ -n "$RTH_SHELL_OVERRIDE" && "$env" == "win" ]]; then
    shell="$RTH_SHELL_OVERRIDE"
  fi
  shell="${shell:-bash}"
  distro="$(rth_get "$env" distro)"
  distro="${distro:-Ubuntu}"
  workdir="$(rth_get "$env" workdir)"

  out_file="$(mktemp)"
  err_file="$(mktemp)"
  exit_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$out_file' '$err_file' '$exit_file'" RETURN

  start="$(rth_now_ms)"

  case "$kind" in
    local)
      wrapped="$(rth_wrap_command "$shell" "$cmd")"
      if [[ -n "$workdir" ]]; then
        local wd
        wd="$(rth_expand_home "$workdir")"
        if [[ -d "$wd" ]]; then
          ( cd "$wd" && eval "$wrapped" ) >"$out_file" 2>"$err_file"
        else
          eval "$wrapped" >"$out_file" 2>"$err_file"
        fi
      else
        eval "$wrapped" >"$out_file" 2>"$err_file"
      fi
      echo $? >"$exit_file"
      ;;
    ssh)
      target="$(rth_ssh_target "$env")"
      port="${RTH_LAST_PORT:-22}"
      wrapped="$(rth_wrap_command "$shell" "$cmd")"
      # shellcheck disable=SC2086
      ssh $RTH_SSH_OPTS -p "$port" "$target" "$wrapped" >"$out_file" 2>"$err_file"
      echo $? >"$exit_file"
      ;;
    wsl)
      # Hop: SSH to Windows host, then wsl -d Distro -- bash -lc 'cmd'
      target="$(rth_ssh_target "$env")"
      port="${RTH_LAST_PORT:-22}"
      local inner remote
      inner="$(rth_shell_single_quote "$cmd")"
      remote="wsl -d $(rth_shell_single_quote "$distro") -- bash -lc $inner"
      # shellcheck disable=SC2086
      ssh $RTH_SSH_OPTS -p "$port" "$target" "$remote" >"$out_file" 2>"$err_file"
      echo $? >"$exit_file"
      ;;
    *)
      rth_die "env $env: unknown kind='$kind' (use local|ssh|wsl)"
      ;;
  esac

  end="$(rth_now_ms)"
  if [[ "$end" =~ ^[0-9]+$ && "$start" =~ ^[0-9]+$ ]]; then
    RTH_LAST_MS=$(( end - start ))
    [[ "$RTH_LAST_MS" -lt 0 ]] && RTH_LAST_MS=0
  else
    RTH_LAST_MS=0
  fi
  RTH_LAST_EXIT="$(cat "$exit_file" 2>/dev/null || echo 1)"
  RTH_LAST_STDOUT="$(cat "$out_file")"
  RTH_LAST_STDERR="$(cat "$err_file")"

  # Stream with optional prefix
  if [[ -n "$prefix" ]]; then
    if [[ -n "$RTH_LAST_STDOUT" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s%s\n' "$prefix" "$line"
      done <<<"$RTH_LAST_STDOUT"
    fi
    if [[ -n "$RTH_LAST_STDERR" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s%s\n' "$prefix" "$line" >&2
      done <<<"$RTH_LAST_STDERR"
    fi
  else
    [[ -n "$RTH_LAST_STDOUT" ]] && printf '%s\n' "$RTH_LAST_STDOUT"
    [[ -n "$RTH_LAST_STDERR" ]] && printf '%s\n' "$RTH_LAST_STDERR" >&2
  fi

  return "$RTH_LAST_EXIT"
}

# Interactive SSH / local shell
rth_ssh_interactive() {
  local env="$1"
  local kind target port
  kind="$(rth_get "$env" kind)"
  kind="${kind:-ssh}"
  case "$kind" in
    local)
      rth_log "Opening local shell for $env"
      exec "${SHELL:-bash}" -l
      ;;
    ssh)
      target="$(rth_ssh_target "$env")"
      port="${RTH_LAST_PORT:-22}"
      # shellcheck disable=SC2086
      exec ssh $RTH_SSH_OPTS -p "$port" "$target"
      ;;
    wsl)
      target="$(rth_ssh_target "$env")"
      port="${RTH_LAST_PORT:-22}"
      local distro
      distro="$(rth_get "$env" distro)"
      distro="${distro:-Ubuntu}"
      # shellcheck disable=SC2086
      exec ssh $RTH_SSH_OPTS -p "$port" -t "$target" "wsl -d $distro -- bash -l"
      ;;
    *)
      rth_die "Cannot open interactive shell for kind=$kind"
      ;;
  esac
}
