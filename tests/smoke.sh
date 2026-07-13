#!/usr/bin/env bash
# smoke.sh — local automated checks for rth (no remote SSH required)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTH="$ROOT/bin/rth"
CFG="$ROOT/tests/fixtures/hosts.local.conf"
FAIL=0
PASS=0

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "  PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name (got=$got want=$want)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo "  PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name (missing '$needle' in: ${hay:0:200})"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local name="$1" want="$2"
  shift 2
  set +e
  "$@" >/tmp/rth-test-out.$$ 2>/tmp/rth-test-err.$$
  local ec=$?
  set -e
  if [[ "$ec" -eq "$want" ]]; then
    echo "  PASS  $name (exit $ec)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name (exit $ec want $want)"
    echo "        stdout: $(head -c 200 /tmp/rth-test-out.$$)"
    echo "        stderr: $(head -c 200 /tmp/rth-test-err.$$)"
    FAIL=$((FAIL + 1))
  fi
}

echo "== rth smoke tests =="
echo "ROOT=$ROOT"
[[ -x "$RTH" ]] || chmod +x "$RTH"
[[ -f "$CFG" ]] || { echo "missing fixture $CFG"; exit 1; }

echo "-- version / help --"
out="$("$RTH" --version 2>&1)"
assert_contains "version" "$out" "0.1.0"

assert_exit "help exit 0" 0 "$RTH" --help

echo "-- list / status --"
out="$("$RTH" --config "$CFG" list 2>&1)"
assert_eq "list mac" "$(echo "$out" | tr -d '[:space:]')" "mac"

out="$("$RTH" --config "$CFG" status 2>&1)"
assert_contains "status header" "$out" "ENV"
assert_contains "status local" "$out" "local"

echo "-- doctor --"
assert_exit "doctor local ok" 0 "$RTH" --config "$CFG" doctor

echo "-- run --"
out="$("$RTH" --config "$CFG" run -e mac -- 'echo smoke-run' 2>/dev/null)"
assert_contains "run stdout" "$out" "smoke-run"

echo "-- matrix --"
out="$("$RTH" --config "$CFG" matrix -- 'echo smoke-matrix' 2>/dev/null)"
assert_contains "matrix prefix" "$out" "[mac]"
assert_contains "matrix body" "$out" "smoke-matrix"

json="$("$RTH" --json --config "$CFG" matrix -- 'echo json-ok' 2>/dev/null)"
assert_contains "json ok field" "$json" '"ok":true'
assert_contains "json stdout" "$json" 'json-ok'

assert_exit "matrix false -> exit 3" 3 "$RTH" --config "$CFG" matrix -- false

echo "-- guide --"
assert_exit "guide setup" 0 "$RTH" guide setup
assert_exit "guide --json" 0 "$RTH" --json guide
json="$("$RTH" --json guide 2>/dev/null)"
assert_contains "guide json tool" "$json" '"tool":"rth"'
assert_contains "guide json steps" "$json" '"steps"'

echo "-- missing config --"
assert_exit "no config dies" 1 env RTH_CONFIG=/nonexistent/hosts.conf "$RTH" list

echo "-- install.sh syntax --"
if command -v bash >/dev/null; then
  assert_exit "install.sh parse" 0 bash -n "$ROOT/install.sh"
  assert_exit "bin/rth parse" 0 bash -n "$ROOT/bin/rth"
  for f in "$ROOT"/lib/*.sh; do
    assert_exit "parse $(basename "$f")" 0 bash -n "$f"
  done
fi

rm -f /tmp/rth-test-out.$$ /tmp/rth-test-err.$$ 2>/dev/null || true

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
