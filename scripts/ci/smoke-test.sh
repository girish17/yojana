#!/usr/bin/env bash
# Post-deploy smoke tests against production Yojana (yojana.girishm.info).
# Runs on the CI VM/Jenkins agent.
# Usage: smoke-test.sh [BASE_URL]
set -euo pipefail

BASE_URL="${1:-https://yojana.girishm.info}"
FAILURES=0

check() { # desc url expect [follow]
  local desc="$1" url="$2" expect="${3:-200}" follow="${4:-}"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 ${follow:+-L} "$url")"
  if [ "$code" = "$expect" ]; then
    echo "PASS: $desc ($code)"
  else
    echo "FAIL: $desc (expected $expect, got $code)"
    FAILURES=$((FAILURES+1))
  fi
}

echo "==> Smoke tests against $BASE_URL ..."

# Cold-start allowance: Caddy swaps instantly, but the container's Postgres + Rails
# boot can take ~30-60s. Retry the first check until app answers 2xx.
echo "==> Waiting for app readiness (up to ~2 min) =="
READY=""
for i in $(seq 1 12); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$BASE_URL/login")"
  echo "    attempt $i -> $code"
  case "$code" in
    2[0-9][0-9]|3[0-9][0-9]) READY=1; break;;
  esac
  sleep 10
done
[ -n "$READY" ] || { echo "FAIL: app did not become reachable after cold start"; exit 1; }

check "home"         "$BASE_URL/" 200 1
check "login page"   "$BASE_URL/login"
check "anchorless /" "$BASE_URL/" 200 1

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL SMOKE TESTS PASSED"
else
  echo "$FAILURES SMOKE TEST(S) FAILED"
  exit 1
fi