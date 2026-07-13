#!/usr/bin/env bash
# rth — run / matrix orchestration
# shellcheck shell=bash

# Run command on one env; print human or collect for JSON
# Args: env  command...
rth_cmd_run() {
  local env="$1"
  shift
  local cmd="$*"
  local prefix=""
  rth_require_env "$env"
  if [[ "$RTH_JSON" != "1" ]]; then
    rth_log "run -e $env -- $cmd"
  fi
  set +e
  rth_exec_env "$env" "$prefix" "$cmd"
  local ec=$?
  set -e

  if [[ "$RTH_SAVE" == "1" ]]; then
    local dir="$RTH_LOCAL_LOGS/$(rth_ts)"
    mkdir -p "$dir"
    {
      echo "env=$env"
      echo "cmd=$cmd"
      echo "exit=$ec"
      echo "--- stdout ---"
      printf '%s\n' "$RTH_LAST_STDOUT"
      echo "--- stderr ---"
      printf '%s\n' "$RTH_LAST_STDERR"
    } >"$dir/${env}.log"
    rth_log "saved $dir/${env}.log"
  fi

  if [[ "$RTH_JSON" == "1" ]]; then
    printf '{'
    printf '"ok":%s,' "$([[ $ec -eq 0 ]] && echo true || echo false)"
    printf '"env":"%s",' "$(json_escape "$env")"
    printf '"exit":%s,' "$ec"
    printf '"duration_ms":%s,' "${RTH_LAST_MS:-0}"
    printf '"command":"%s",' "$(json_escape "$cmd")"
    printf '"stdout":"%s",' "$(json_escape "$RTH_LAST_STDOUT")"
    printf '"stderr":"%s"' "$(json_escape "$RTH_LAST_STDERR")"
    printf '}\n'
  fi
  return "$ec"
}

# Matrix: run on all selected envs
# Exit: 0 all ok, 2 partial, 3 all unreachable-ish (if all fail with ssh-ish), 1 no envs
rth_cmd_matrix() {
  local cmd="$*"
  [[ -n "$cmd" ]] || rth_die "matrix: missing command after --"

  local envs=()
  local e
  while IFS= read -r e; do
    [[ -n "$e" ]] && envs+=("$e")
  done < <(rth_selected_envs)
  [[ ${#envs[@]} -gt 0 ]] || rth_die "matrix: no environments selected"

  if [[ "$RTH_JSON" != "1" ]]; then
    rth_log "matrix (${#envs[@]} envs) -- $cmd"
  fi

  local save_dir=""
  if [[ "$RTH_SAVE" == "1" ]]; then
    save_dir="$RTH_LOCAL_LOGS/$(rth_ts)"
    mkdir -p "$save_dir"
  fi

  local results_json=()
  local ok_count=0 fail_count=0
  local ec=0

  _rth_matrix_one() {
    local env="$1"
    local prefix="[$env] "
    local outf errf
    outf="$(mktemp)"
    errf="$(mktemp)"
    # capture stdout/stderr; keep duration from rth_exec_env (same shell)
    set +e
    rth_exec_env "$env" "" "$cmd" >"$outf" 2>"$errf"
    local mex=$?
    set -e
    local mms="${RTH_LAST_MS:-0}"
    local mout merr
    mout="$(cat "$outf")"
    merr="$(cat "$errf")"
    rm -f "$outf" "$errf"

    if [[ "$RTH_JSON" != "1" ]]; then
      if [[ -n "$mout" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
          printf '%s%s\n' "$prefix" "$line"
        done <<<"$mout"
      fi
      if [[ -n "$merr" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
          printf '%s%s\n' "$prefix" "$line" >&2
        done <<<"$merr"
      fi
      if [[ "$mex" -eq 0 ]]; then
        rth_ok "$env exit 0 (${mms}ms)"
      else
        rth_err "$env exit $mex (${mms}ms)"
      fi
    fi

    if [[ -n "$save_dir" ]]; then
      {
        echo "env=$env"
        echo "cmd=$cmd"
        echo "exit=$mex"
        echo "--- stdout ---"
        printf '%s\n' "$mout"
        echo "--- stderr ---"
        printf '%s\n' "$merr"
      } >"$save_dir/${env}.log"
    fi

    results_json+=("$(printf '{"env":"%s","ok":%s,"exit":%s,"duration_ms":%s,"stdout":"%s","stderr":"%s"}' \
      "$(json_escape "$env")" \
      "$([[ $mex -eq 0 ]] && echo true || echo false)" \
      "$mex" \
      "$mms" \
      "$(json_escape "$mout")" \
      "$(json_escape "$merr")")")

    if [[ "$mex" -eq 0 ]]; then
      ok_count=$((ok_count + 1))
    else
      fail_count=$((fail_count + 1))
    fi
  }

  if [[ "$RTH_SERIAL" == "1" ]] || [[ ${#envs[@]} -eq 1 ]]; then
    for e in "${envs[@]}"; do
      _rth_matrix_one "$e"
    done
  else
    # Parallel: background jobs with per-env temp result files
    local pids=() tmpdir
    tmpdir="$(mktemp -d)"
    for e in "${envs[@]}"; do
      (
        rth_exec_env "$e" "" "$cmd" >"$tmpdir/${e}.out" 2>"$tmpdir/${e}.err"
        echo $? >"$tmpdir/${e}.ec"
        echo "${RTH_LAST_MS:-0}" >"$tmpdir/${e}.ms"
      ) &
      pids+=($!)
    done
    for pid in "${pids[@]}"; do
      wait "$pid" || true
    done
    for e in "${envs[@]}"; do
      local mex mout merr mms prefix
      prefix="[$e] "
      mex="$(cat "$tmpdir/${e}.ec" 2>/dev/null || echo 1)"
      mout="$(cat "$tmpdir/${e}.out" 2>/dev/null || true)"
      merr="$(cat "$tmpdir/${e}.err" 2>/dev/null || true)"
      mms="$(cat "$tmpdir/${e}.ms" 2>/dev/null || echo 0)"
      if [[ "$RTH_JSON" != "1" ]]; then
        if [[ -n "$mout" ]]; then
          while IFS= read -r line || [[ -n "$line" ]]; do
            printf '%s%s\n' "$prefix" "$line"
          done <<<"$mout"
        fi
        if [[ -n "$merr" ]]; then
          while IFS= read -r line || [[ -n "$line" ]]; do
            printf '%s%s\n' "$prefix" "$line" >&2
          done <<<"$merr"
        fi
        if [[ "$mex" -eq 0 ]]; then
          rth_ok "$e exit 0 (${mms}ms)"
        else
          rth_err "$e exit $mex (${mms}ms)"
        fi
      fi
      if [[ -n "$save_dir" ]]; then
        {
          echo "env=$e"
          echo "cmd=$cmd"
          echo "exit=$mex"
          echo "--- stdout ---"
          printf '%s\n' "$mout"
          echo "--- stderr ---"
          printf '%s\n' "$merr"
        } >"$save_dir/${e}.log"
      fi
      results_json+=("$(printf '{"env":"%s","ok":%s,"exit":%s,"duration_ms":%s,"stdout":"%s","stderr":"%s"}' \
        "$(json_escape "$e")" \
        "$([[ $mex -eq 0 ]] && echo true || echo false)" \
        "$mex" \
        "$mms" \
        "$(json_escape "$mout")" \
        "$(json_escape "$merr")")")
      if [[ "$mex" -eq 0 ]]; then
        ok_count=$((ok_count + 1))
      else
        fail_count=$((fail_count + 1))
      fi
    done
    rm -rf "$tmpdir"
  fi

  if [[ -n "$save_dir" && "$RTH_JSON" != "1" ]]; then
    rth_log "saved logs under $save_dir"
  fi

  if [[ "$RTH_JSON" == "1" ]]; then
    local first=1
    printf '{'
    printf '"ok":%s,' "$([[ $fail_count -eq 0 ]] && echo true || echo false)"
    printf '"command":"%s",' "$(json_escape "$cmd")"
    printf '"ok_count":%s,' "$ok_count"
    printf '"fail_count":%s,' "$fail_count"
    printf '"results":['
    for r in "${results_json[@]}"; do
      [[ $first -eq 1 ]] || printf ','
      first=0
      printf '%s' "$r"
    done
    printf ']}\n'
  else
    printf '%s── matrix: %s ok, %s fail ──%s\n' \
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
