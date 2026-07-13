#!/usr/bin/env bash
# rth — shared helpers
# shellcheck shell=bash

RTH_VERSION="0.1.0"

if [[ -z "${RTH_ROOT:-}" ]]; then
  RTH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

RTH_JSON="${RTH_JSON:-0}"
RTH_QUIET="${RTH_QUIET:-0}"
RTH_SAVE="${RTH_SAVE:-0}"
RTH_TIMEOUT="${RTH_TIMEOUT:-30}"
RTH_SERIAL="${RTH_SERIAL:-0}"
RTH_SHELL_OVERRIDE="${RTH_SHELL_OVERRIDE:-}"
RTH_ENV_FILTER="${RTH_ENV_FILTER:-}"
RTH_LOCAL_LOGS="${RTH_LOCAL_LOGS:-$RTH_ROOT/logs}"

_rth_color() {
  if [[ -t 2 ]] && [[ "$RTH_JSON" != "1" ]] && [[ -z "${NO_COLOR:-}" ]]; then
    case "$1" in
      red) printf '\033[31m' ;;
      green) printf '\033[32m' ;;
      yellow) printf '\033[33m' ;;
      blue) printf '\033[34m' ;;
      dim) printf '\033[2m' ;;
      bold) printf '\033[1m' ;;
      reset) printf '\033[0m' ;;
    esac
  fi
}

rth_log()  { [[ "$RTH_QUIET" == "1" || "$RTH_JSON" == "1" ]] && return 0; printf '%s[rth]%s %s\n' "$(_rth_color blue)" "$(_rth_color reset)" "$*" >&2; }
rth_ok()   { [[ "$RTH_QUIET" == "1" || "$RTH_JSON" == "1" ]] && return 0; printf '%s[rth]%s %s\n' "$(_rth_color green)" "$(_rth_color reset)" "$*" >&2; }
rth_warn() { [[ "$RTH_JSON" == "1" ]] && return 0; printf '%s[rth]%s %s\n' "$(_rth_color yellow)" "$(_rth_color reset)" "$*" >&2; }
rth_err()  { printf '%s[rth]%s %s\n' "$(_rth_color red)" "$(_rth_color reset)" "$*" >&2; }
rth_die()  { rth_err "$*"; exit 1; }

rth_ts() { date +%Y%m%d-%H%M%S; }

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

rth_config_path() {
  if [[ -n "${RTH_CONFIG:-}" ]]; then
    printf '%s' "$RTH_CONFIG"
    return
  fi
  local home_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/rth/hosts.conf"
  if [[ -f "$home_cfg" ]]; then
    printf '%s' "$home_cfg"
    return
  fi
  local project_cfg="$RTH_ROOT/config/hosts.conf"
  if [[ -f "$project_cfg" ]]; then
    printf '%s' "$project_cfg"
    return
  fi
  printf '%s' "$home_cfg"
}

rth_load_config() {
  local cfg
  cfg="$(rth_config_path)"
  if [[ ! -f "$cfg" ]]; then
    rth_die "No config at $cfg — run: rth setup"
  fi
  # shellcheck disable=SC1090
  source "$cfg"
  RTH_SSH_OPTS="${RTH_SSH_OPTS:--o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new}"
  RTH_ENVS="${RTH_ENVS:-mac,win,ubuntu}"
  mkdir -p "$RTH_LOCAL_LOGS"
}

rth_env_list() {
  local raw="${RTH_ENVS// /}"
  local IFS=','
  # shellcheck disable=SC2086
  set -- $raw
  printf '%s\n' "$@"
}

rth_get() {
  local env="$1" field="$2"
  local var="${env}_${field}"
  printf '%s' "${!var-}"
}

rth_require_env() {
  local want="$1" e
  for e in $(rth_env_list); do
    [[ "$e" == "$want" ]] && return 0
  done
  rth_die "Unknown env: $want (known: ${RTH_ENVS})"
}

# Resolve selected envs from filter or all
rth_selected_envs() {
  local filter="${RTH_ENV_FILTER:-}" e
  if [[ -z "$filter" ]]; then
    rth_env_list
    return
  fi
  local IFS=','
  # shellcheck disable=SC2086
  set -- ${filter// /}
  for e in "$@"; do
    rth_require_env "$e"
    printf '%s\n' "$e"
  done
}

rth_expand_home() {
  local p="$1"
  if [[ "$p" == "~/"* ]]; then
    printf '%s' "${HOME}/${p#~/}"
  elif [[ "$p" == "~" ]]; then
    printf '%s' "$HOME"
  else
    printf '%s' "$p"
  fi
}

rth_now_ms() {
  # GNU date supports %3N; BSD/macOS does not (prints literal N).
  local t
  t="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    printf '%s' "$t"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null && return
  fi
  echo $(( $(date +%s) * 1000 ))
}
