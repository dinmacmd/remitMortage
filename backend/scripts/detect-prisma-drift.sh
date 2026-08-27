#!/usr/bin/env bash
#
# Prisma Schema Drift Detector
#
# Compares the committed Prisma schema against a snapshot of the production
# database and fails with a readable diff when drift is detected.
#
# Two modes:
#   1. Snapshot-file mode (default, works without network):
#        npx prisma migrate diff --from-schema=<snapshot> --to-schema=<schema>
#      Used in PRs from forks where PRODUCTION_DATABASE_URL is unavailable.
#
#   2. Live-DB mode (when PRODUCTION_DATABASE_URL or DATABASE_URL is set):
#        npx prisma migrate diff --from-config-datasource --to-schema=<schema>
#      Used on main/nightly when the secret is present. Requires a valid
#      DATABASE_URL pointing at production (read-only).
#
# Usage:
#   ./backend/scripts/detect-prisma-drift.sh
#   PRODUCTION_DATABASE_URL=postgres://... ./backend/scripts/detect-prisma-drift.sh
#   ./backend/scripts/detect-prisma-drift.sh --from-schema=path --to-schema=path
#   ./backend/scripts/detect-prisma-drift.sh --help
#
# Exit codes:
#   0 = no drift (schemas in sync)
#   1 = error
#   2 = drift detected (also prints diff)
#
# When --exit-code is passed, drift exits with 2 so CI can distinguish it.
# Otherwise the script exits with 1 on drift for backwards compatibility.
#
# Artifacts:
#   Writes drift-summary.txt (human readable) and drift.sql (--script) to the
#   current directory when drift is found, for upload as CI artifacts.

set -euo pipefail

# ── Resolve paths ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Support being called from repo root, backend/, or via npx
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BACKEND_DIR/.." && pwd)"

# Allow being invoked as scripts/detect-prisma-drift.sh from repo root
if [[ "$SCRIPT_DIR" == "$REPO_ROOT/scripts" ]]; then
  BACKEND_DIR="$REPO_ROOT/backend"
fi

DEFAULT_SNAPSHOT="$BACKEND_DIR/prisma/__snapshots__/production-schema.prisma"
DEFAULT_SCHEMA="$BACKEND_DIR/prisma/schema.prisma"
DEFAULT_SQL_SNAPSHOT="$BACKEND_DIR/prisma/__snapshots__/production-schema.sql"

# Also support JS snapshot fallback if prisma file missing but SQL exists
SNAPSHOT_PRISMA="$DEFAULT_SNAPSHOT"
SCHEMA_PRISMA="$DEFAULT_SCHEMA"

# ── Defaults / flags ─────────────────────────────────────────────────────
FROM_SCHEMA=""
TO_SCHEMA="$SCHEMA_PRISMA"
FROM_CONFIG_DATASOURCE=false
USE_EXIT_CODE=false
SHOW_HELP=false
OUTPUT_DIR="."
SCRIPT_OUTPUT=false
FROM_SNAPSHOT_SQL=""

# ── Parse args ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-schema=*) FROM_SCHEMA="${1#*=}"; shift ;;
    --from-schema) FROM_SCHEMA="$2"; shift 2 ;;
    --to-schema=*) TO_SCHEMA="${1#*=}"; shift ;;
    --to-schema) TO_SCHEMA="$2"; shift 2 ;;
    --from-config-datasource) FROM_CONFIG_DATASOURCE=true; shift ;;
    --from-snapshot-sql=*) FROM_SNAPSHOT_SQL="${1#*=}"; shift ;;
    --exit-code) USE_EXIT_CODE=true; shift ;;
    --script) SCRIPT_OUTPUT=true; shift ;;
    --output-dir=*) OUTPUT_DIR="${1#*=}"; shift ;;
    -h|--help) SHOW_HELP=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ "$SHOW_HELP" == true ]]; then
  cat <<'EOF'
Prisma Schema Drift Detector

Compares committed schema vs production snapshot.

Usage:
  detect-prisma-drift.sh [options]

Options:
  --from-schema=PATH            Snapshot Prisma file to diff FROM (default: prisma/__snapshots__/production-schema.prisma)
  --to-schema=PATH              Committed schema to diff TO (default: prisma/schema.prisma)
  --from-config-datasource      Use live DATABASE_URL as source instead of snapshot file
  --from-snapshot-sql=PATH      Compare via SQL snapshot (pg_dump) instead of Prisma file
  --exit-code                   Exit 2 on drift, 0 on clean, 1 on error (for CI)
  --script                      Also emit SQL script (drift.sql)
  --output-dir=DIR              Where to write drift-summary.txt / drift.sql (default: .)
  -h, --help                    Show this help

Environment:
  PRODUCTION_DATABASE_URL       If set, live-DB mode is used automatically unless --from-schema is explicit
  DATABASE_URL                  Fallback for live-DB mode

Examples:
  # PR check (no DB, file-to-file)
  ./backend/scripts/detect-prisma-drift.sh

  # Nightly live check
  PRODUCTION_DATABASE_URL=postgres://... ./backend/scripts/detect-prisma-drift.sh --exit-code

  # Custom paths
  ./backend/scripts/detect-prisma-drift.sh --from-schema=./snapshot.prisma --to-schema=./schema.prisma --exit-code

  # SQL snapshot mode (pg_dump file)
  ./backend/scripts/detect-prisma-drift.sh --from-snapshot-sql=./production-schema.sql

EOF
  exit 0
fi

# ── Auto-detect live-DB mode ─────────────────────────────────────────────
# If PRODUCTION_DATABASE_URL is set and caller did not force --from-schema, use live DB.
if [[ -z "$FROM_SCHEMA" && "$FROM_CONFIG_DATASOURCE" == false ]]; then
  if [[ -n "${PRODUCTION_DATABASE_URL:-}" ]]; then
    FROM_CONFIG_DATASOURCE=true
  elif [[ -n "${DATABASE_URL:-}" && "${PRODUCTION_DATABASE_URL:-__unset}" == "__unset" ]]; then
    # Heuristic: if we're running in CI with DATABASE_URL pointing at prod, honour it.
    # But only auto-switch if snapshot file is missing — otherwise prefer file for determinism.
    if [[ ! -f "$SNAPSHOT_PRISMA" ]]; then
      FROM_CONFIG_DATASOURCE=true
    fi
  fi
fi

# If no explicit FROM and not live-DB, default to snapshot file
if [[ -z "$FROM_SCHEMA" && "$FROM_CONFIG_DATASOURCE" == false ]]; then
  FROM_SCHEMA="$SNAPSHOT_PRISMA"
fi

# ── Validate inputs ──────────────────────────────────────────────────────
if [[ "$FROM_CONFIG_DATASOURCE" == false && -n "$FROM_SCHEMA" && ! -f "$FROM_SCHEMA" ]]; then
  # Fallback: try repo-root-relative path
  ALT="$REPO_ROOT/$FROM_SCHEMA"
  if [[ -f "$ALT" ]]; then
    FROM_SCHEMA="$ALT"
  else
    # Also try SQL snapshot fallback
    if [[ -f "$DEFAULT_SQL_SNAPSHOT" && "$FROM_SCHEMA" == "$SNAPSHOT_PRISMA" ]]; then
      echo "⚠️  Prisma snapshot not found at $FROM_SCHEMA" >&2
      echo "   Falling back to SQL snapshot comparison is not supported via migrate diff." >&2
      echo "   Please run: cp $TO_SCHEMA $SNAPSHOT_PRISMA" >&2
    fi
    echo "❌ Snapshot file not found: $FROM_SCHEMA" >&2
    echo "   Hint: run backend/scripts/sync-production-schema.sh to generate it," >&2
    echo "   or set PRODUCTION_DATABASE_URL for live-DB mode." >&2
    exit 1
  fi
fi

if [[ ! -f "$TO_SCHEMA" ]]; then
  ALT="$REPO_ROOT/$TO_SCHEMA"
  if [[ -f "$ALT" ]]; then
    TO_SCHEMA="$ALT"
  else
    echo "❌ Target schema not found: $TO_SCHEMA" >&2
    exit 1
  fi
fi

# ── Locate prisma CLI ────────────────────────────────────────────────────
PRISMA_BIN=""
if [[ -x "$BACKEND_DIR/node_modules/.bin/prisma" ]]; then
  PRISMA_BIN="$BACKEND_DIR/node_modules/.bin/prisma"
elif command -v prisma &>/dev/null; then
  PRISMA_BIN="prisma"
elif command -v npx &>/dev/null; then
  PRISMA_BIN="npx prisma"
else
  echo "❌ prisma CLI not found. Run 'npm ci' in $BACKEND_DIR first." >&2
  exit 1
fi

# ── Helpers ──────────────────────────────────────────────────────────────
ensure_output_dir() {
  mkdir -p "$OUTPUT_DIR"
}

# Run prisma migrate diff and capture output + exit code.
# Prisma 7 flags: --from-schema, --to-schema, --from-config-datasource, --exit-code, --script
run_diff() {
  local mode="$1" # "human" or "script"
  local exit_code=0
  local cmd=()
  # Use npx prisma if PRISMA_BIN contains space
  if [[ "$PRISMA_BIN" == "npx prisma" ]]; then
    cmd=(npx prisma migrate diff)
  else
    cmd=("$PRISMA_BIN" migrate diff)
  fi

  if [[ "$FROM_CONFIG_DATASOURCE" == true ]]; then
    # Live-DB mode: requires DATABASE_URL env to be set for Prisma config.
    # Prefer PRODUCTION_DATABASE_URL if given, else DATABASE_URL.
    if [[ -n "${PRODUCTION_DATABASE_URL:-}" ]]; then
      export DATABASE_URL="$PRODUCTION_DATABASE_URL"
    fi
    if [[ -z "${DATABASE_URL:-}" ]]; then
      echo "❌ Live-DB mode requires DATABASE_URL or PRODUCTION_DATABASE_URL to be set." >&2
      return 1
    fi
    cmd+=(--from-config-datasource)
  else
    cmd+=(--from-schema="$FROM_SCHEMA")
  fi
  cmd+=(--to-schema="$TO_SCHEMA")

  if [[ "$mode" == "script" ]]; then
    cmd+=(--script)
  fi

  # Always use --exit-code internally so we can distinguish drift vs error,
  # but map to caller expectation later.
  cmd+=(--exit-code)

  # Run from BACKEND_DIR so prisma.config.ts is found.
  set +e
  local output
  output=$(cd "$BACKEND_DIR" && "${cmd[@]}" 2>&1)
  exit_code=$?
  set -e

  # Prisma prints "Loaded Prisma config from ..." on stdout - keep it but
  # also surface it. Exit codes: 0=clean, 1=error, 2=drift (with --exit-code)
  echo "$output"
  return $exit_code
}

# ── Main ─────────────────────────────────────────────────────────────────
echo "=========================================="
echo "🔍 Prisma Schema Drift Check"
echo "=========================================="
echo "Backend:  $BACKEND_DIR"
if [[ "$FROM_CONFIG_DATASOURCE" == true ]]; then
  echo "From:     live DATABASE_URL (config datasource)"
  # Mask URL for logs
  MASKED_URL="${DATABASE_URL:-${PRODUCTION_DATABASE_URL:-}}"
  MASKED_URL="$(echo "$MASKED_URL" | sed -E 's|://[^@]*@|://***:***@|')"
  echo "URL:      $MASKED_URL"
else
  echo "From:     $FROM_SCHEMA (snapshot)"
fi
echo "To:       $TO_SCHEMA (committed)"
echo ""

ensure_output_dir

SUMMARY_FILE="$OUTPUT_DIR/drift-summary.txt"
SQL_FILE="$OUTPUT_DIR/drift.sql"

# Capture human-readable diff
set +e
HUMAN_OUTPUT=$(run_diff "human")
HUMAN_EXIT=$?
set -e

# Prisma may emit "No difference detected." on stdout with exit 0.
# With --exit-code, drift exits 2 and still prints diff.

if [[ $HUMAN_EXIT -eq 0 ]]; then
  echo "✅ No drift detected — production snapshot matches committed schema."
  echo ""
  echo "$HUMAN_OUTPUT"
  # Write a clean summary for artifact consistency
  {
    echo "Prisma Schema Drift Check"
    echo "========================="
    echo "from=$FROM_SCHEMA"
    echo "to=$TO_SCHEMA"
    echo "result=PASS"
    echo "timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo ""
    echo "$HUMAN_OUTPUT"
  } > "$SUMMARY_FILE"
  # Clean up any stale drift.sql
  rm -f "$SQL_FILE" 2>/dev/null || true
  echo ""
  echo "Summary written to $SUMMARY_FILE"
  exit 0
elif [[ $HUMAN_EXIT -eq 2 ]]; then
  echo "⚠️  Drift detected — committed schema differs from production snapshot!"
  echo ""
  # Print the human-readable summary
  echo "$HUMAN_OUTPUT"
  echo ""
  echo "--- Generating SQL script for the drift (what would be applied) ---"
  set +e
  SCRIPT_OUTPUT=$(run_diff "script")
  SCRIPT_EXIT=$?
  set -e
  # Even when drifted, script exit should also be 2, but capture output anyway
  echo "$SCRIPT_OUTPUT"

  # Write artifacts
  {
    echo "Prisma Schema Drift Check"
    echo "========================="
    echo "from=$FROM_SCHEMA"
    echo "to=$TO_SCHEMA"
    echo "result=FAIL (drift detected)"
    echo "timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo ""
    echo "Human-readable diff:"
    echo "--------------------"
    echo "$HUMAN_OUTPUT"
    echo ""
    echo "SQL script to reconcile (apply to production snapshot to reach committed schema):"
    echo "-------------------------------------------------------------------------------"
    echo "$SCRIPT_OUTPUT"
  } > "$SUMMARY_FILE"

  # Write raw SQL for direct use with `prisma db execute`
  echo "$SCRIPT_OUTPUT" > "$SQL_FILE"

  echo ""
  echo "=========================================="
  echo "❌ Drift check FAILED"
  echo "=========================================="
  echo "Readable summary: $SUMMARY_FILE"
  echo "SQL migration:    $SQL_FILE"
  echo ""
  echo "Next steps:"
  echo "  1. Review $SUMMARY_FILE or $SQL_FILE"
  echo "  2. See docs/PRISMA_SCHEMA_DRIFT_REMEDIATION.md for reconciliation"
  echo "  3. If the change is intentional, update the snapshot:"
  echo "       cp $TO_SCHEMA $FROM_SCHEMA"
  echo "     or run: backend/scripts/sync-production-schema.sh"
  echo ""
  # Also emit GitHub Actions error annotation if in CI
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error::Prisma schema drift detected. See drift-summary.txt artifact." >&2
    # Persist summary for upload-artifact
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "drift_detected=true" >> "$GITHUB_OUTPUT" 2>/dev/null || true
      echo "summary_path=$SUMMARY_FILE" >> "$GITHUB_OUTPUT" 2>/dev/null || true
    fi
  fi

  if [[ "$USE_EXIT_CODE" == true ]]; then
    exit 2
  else
    exit 1
  fi
else
  # Exit 1 = error (bad schema, missing DB, etc.)
  echo "❌ Failed to compute diff (exit code $HUMAN_EXIT)" >&2
  echo ""
  echo "$HUMAN_OUTPUT" >&2
  echo ""
  echo "Troubleshooting:"
  echo "  - Ensure $BACKEND_DIR/prisma.config.ts is valid and DATABASE_URL is set for live-DB mode"
  echo "  - Validate schemas with: npx prisma validate --schema=$TO_SCHEMA"
  echo "  - For file mode, ensure both --from-schema and --to-schema exist"
  {
    echo "Prisma Schema Drift Check"
    echo "========================="
    echo "from=$FROM_SCHEMA"
    echo "to=$TO_SCHEMA"
    echo "result=ERROR"
    echo "exit_code=$HUMAN_EXIT"
    echo "timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo ""
    echo "$HUMAN_OUTPUT"
  } > "$SUMMARY_FILE"
  exit 1
fi
