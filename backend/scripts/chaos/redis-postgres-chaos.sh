#!/usr/bin/env bash
#
# Chaos / fault-injection harness for Redis and Postgres outages (issue #479).
#
# Pauses (and then unpauses) the real Redis and Postgres containers underneath a
# running backend and asserts the service degrades gracefully — it must keep
# answering /api/health with a clean 200/503 instead of crashing or hanging —
# and then recovers to a healthy 200 once the dependency returns.
#
# This complements the unit-level fault-injection test
# (backend/src/__tests__/chaos/redisChaos.test.ts), which simulates the same
# outages without Docker.
#
# Usage:
#   docker compose up -d
#   ./scripts/chaos/redis-postgres-chaos.sh
#
# Env:
#   HEALTH_URL        Backend health endpoint (default http://localhost:4000/api/health)
#   REDIS_CONTAINER   Redis container name   (default remitmortgage-redis-1)
#   PG_CONTAINER      Postgres container name (default remitmortgage-postgres)
#   OUTAGE_SECONDS    How long to hold each outage (default 8)

set -uo pipefail

HEALTH_URL="${HEALTH_URL:-http://localhost:4000/api/health}"
REDIS_CONTAINER="${REDIS_CONTAINER:-remitmortgage-redis-1}"
PG_CONTAINER="${PG_CONTAINER:-remitmortgage-postgres}"
OUTAGE_SECONDS="${OUTAGE_SECONDS:-8}"

fail() { echo "CHAOS FAIL: $*" >&2; exit 1; }
info() { echo "[chaos] $*"; }

# Prints the HTTP status of the health endpoint, or 000 if the request could
# not complete at all (connection refused / hang == the process crashed).
health_status() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HEALTH_URL" 2>/dev/null || echo "000"
}

# Asserts the backend is still *answering* (any HTTP status is fine — a 503 is a
# graceful degradation) rather than dead (000 == refused/timed out).
assert_responsive() {
  local phase="$1"
  local code
  code="$(health_status)"
  info "$phase -> HTTP $code"
  if [[ "$code" == "000" ]]; then
    fail "$phase: backend did not respond (crash/hang), expected a graceful HTTP status"
  fi
}

assert_healthy() {
  local phase="$1"
  local code
  code="$(health_status)"
  info "$phase -> HTTP $code"
  [[ "$code" == "200" ]] || fail "$phase: expected HTTP 200 after recovery, got $code"
}

run_outage() {
  local name="$1" container="$2"
  info "=== Simulating $name outage on container '$container' ==="

  docker inspect "$container" >/dev/null 2>&1 || fail "container '$container' not found (is docker compose up?)"

  info "Baseline health before outage"
  assert_responsive "before-$name-outage"

  info "Pausing $container for ${OUTAGE_SECONDS}s"
  docker pause "$container" >/dev/null || fail "could not pause $container"

  # During the outage the backend must degrade gracefully, not crash.
  sleep 2
  assert_responsive "during-$name-outage"
  sleep "$OUTAGE_SECONDS"
  assert_responsive "during-$name-outage-sustained"

  info "Unpausing $container"
  docker unpause "$container" >/dev/null || fail "could not unpause $container"

  # Give the pool/cache a few seconds to reconnect, then require full health.
  info "Waiting for $name reconnection"
  local recovered=0
  for _ in $(seq 1 15); do
    if [[ "$(health_status)" == "200" ]]; then recovered=1; break; fi
    sleep 2
  done
  [[ "$recovered" == "1" ]] || fail "$name: backend did not recover to HTTP 200 after container resumed"
  assert_healthy "after-$name-recovery"
  info "=== $name outage/recovery cycle passed ==="
}

info "Health endpoint: $HEALTH_URL"
assert_healthy "startup"

run_outage "redis" "$REDIS_CONTAINER"
run_outage "postgres" "$PG_CONTAINER"

info "All chaos scenarios passed: graceful degradation + automatic recovery verified."
