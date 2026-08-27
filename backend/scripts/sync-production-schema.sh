#!/usr/bin/env bash
#
# Sync production snapshot from live database.
#
# Captures the current production schema into the committed snapshot files so
# the drift check can run deterministically in PRs without a live DB.
#
# Two snapshot formats are maintained:
#   - prisma/__snapshots__/production-schema.prisma  (via `prisma db pull`)
#   - prisma/__snapshots__/production-schema.sql     (via `prisma migrate diff --from-empty --script` or pg_dump)
#
# The Prisma-file snapshot is the primary one used by detect-prisma-drift.sh.
# The SQL snapshot is for human review and for pg_dump-based restores.
#
# Usage:
#   DATABASE_URL=postgres://... ./backend/scripts/sync-production-schema.sh
#   PRODUCTION_DATABASE_URL=postgres://... ./backend/scripts/sync-production-schema.sh
#   ./backend/scripts/sync-production-schema.sh --from-schema=prisma/schema.prisma  # local reset (no DB)
#
# Requires: npx prisma, and either DATABASE_URL or PRODUCTION_DATABASE_URL for live mode.
# Shadow DB: not needed — `prisma db pull` introspects directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOT_PRISMA="$BACKEND_DIR/prisma/__snapshots__/production-schema.prisma"
SNAPSHOT_SQL="$BACKEND_DIR/prisma/__snapshots__/production-schema.sql"
SCHEMA_PRISMA="$BACKEND_DIR/prisma/schema.prisma"

FROM_SCHEMA=""
LIVE_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-schema=*) FROM_SCHEMA="${1#*=}"; shift ;;
    --from-schema) FROM_SCHEMA="$2"; shift 2 ;;
    --live) LIVE_MODE=true; shift ;;
    -h|--help)
      cat <<'EOF'
Sync production snapshot

Usage:
  sync-production-schema.sh [options]

Options:
  --from-schema=PATH   Copy from a local schema file instead of live DB (e.g. for baseline reset)
  --live               Force live DB pull even if DATABASE_URL is missing (will error if not set)
  -h, --help           Show this help

Environment:
  PRODUCTION_DATABASE_URL  Preferred live DB URL
  DATABASE_URL             Fallback live DB URL

Examples:
  # Refresh from production (requires network + credentials)
  PRODUCTION_DATABASE_URL=postgres://user:pass@prod-host:5432/db ./backend/scripts/sync-production-schema.sh

  # Reset snapshot to current committed schema (no DB, for initial setup)
  ./backend/scripts/sync-production-schema.sh --from-schema=prisma/schema.prisma

EOF
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Resolve DB URL preference
if [[ -n "${PRODUCTION_DATABASE_URL:-}" ]]; then
  export DATABASE_URL="$PRODUCTION_DATABASE_URL"
fi

mkdir -p "$(dirname "$SNAPSHOT_PRISMA")"

# ── Local copy mode ───────────────────────────────────────────────────
if [[ -n "$FROM_SCHEMA" ]]; then
  # Allow relative paths from BACKEND_DIR or repo root
  if [[ ! -f "$FROM_SCHEMA" ]]; then
    if [[ -f "$BACKEND_DIR/$FROM_SCHEMA" ]]; then
      FROM_SCHEMA="$BACKEND_DIR/$FROM_SCHEMA"
    elif [[ -f "$BACKEND_DIR/../$FROM_SCHEMA" ]]; then
      FROM_SCHEMA="$BACKEND_DIR/../$FROM_SCHEMA"
    fi
  fi
  if [[ ! -f "$FROM_SCHEMA" ]]; then
    echo "❌ Source schema not found: $FROM_SCHEMA" >&2
    exit 1
  fi
  echo "▶ Copying $FROM_SCHEMA → $SNAPSHOT_PRISMA"
  cp "$FROM_SCHEMA" "$SNAPSHOT_PRISMA"
  echo "▶ Generating SQL snapshot from $FROM_SCHEMA ..."
  # Generate SQL via migrate diff from empty to schema (no DB needed)
  if [[ -x "$BACKEND_DIR/node_modules/.bin/prisma" ]]; then
    PRISMA_BIN="$BACKEND_DIR/node_modules/.bin/prisma"
  else
    PRISMA_BIN="npx prisma"
  fi
  # Normalize path for prisma when run from BACKEND_DIR
  # Convert to path relative to BACKEND_DIR if it lies inside it, otherwise use absolute unix path
  PRISMA_SCHEMA_ARG="$FROM_SCHEMA"
  # If FROM_SCHEMA is repo-root relative like backend/prisma/schema.prisma, make it relative to BACKEND_DIR
  if [[ "$FROM_SCHEMA" == "$BACKEND_DIR"* ]]; then
    PRISMA_SCHEMA_ARG="${FROM_SCHEMA#$BACKEND_DIR/}"
  elif [[ "$FROM_SCHEMA" == "backend/"* ]]; then
    PRISMA_SCHEMA_ARG="${FROM_SCHEMA#backend/}"
  fi
  # Convert Windows absolute to Unix style if needed (Git Bash)
  if command -v cygpath &>/dev/null && [[ "$PRISMA_SCHEMA_ARG" == *":\\"* || "$PRISMA_SCHEMA_ARG" == *":/"* ]]; then
    PRISMA_SCHEMA_ARG="$(cygpath -u "$PRISMA_SCHEMA_ARG" 2>/dev/null || echo "$PRISMA_SCHEMA_ARG")"
  fi
  # Use a dummy DATABASE_URL for the diff (not used for file-to-file)
  # Run from BACKEND_DIR so prisma.config.ts is found
  (cd "$BACKEND_DIR" && DATABASE_URL="${DATABASE_URL:-postgresql://dummy:dummy@localhost:5432/dummy}" \
    $PRISMA_BIN migrate diff --from-empty --to-schema="$PRISMA_SCHEMA_ARG" --script > "$SNAPSHOT_SQL" 2> /tmp/sync-err.txt) || \
  (cd "$BACKEND_DIR" && $PRISMA_BIN migrate diff --from-empty --to-schema="$PRISMA_SCHEMA_ARG" --script > "$SNAPSHOT_SQL" 2> /tmp/sync-err.txt) || {
    echo "⚠️  SQL generation produced warnings:" >&2
    cat /tmp/sync-err.txt >&2
  }
  # Strip the "Loaded Prisma config" banner if present
  if head -n1 "$SNAPSHOT_SQL" | grep -q "Loaded Prisma config"; then
    tail -n +2 "$SNAPSHOT_SQL" > "$SNAPSHOT_SQL.tmp" && mv "$SNAPSHOT_SQL.tmp" "$SNAPSHOT_SQL"
  fi
  echo "✅ Snapshots updated:"
  echo "   $SNAPSHOT_PRISMA"
  echo "   $SNAPSHOT_SQL"
  exit 0
fi

# ── Live DB mode ──────────────────────────────────────────────────────
if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "❌ DATABASE_URL or PRODUCTION_DATABASE_URL must be set for live sync." >&2
  echo "" >&2
  echo "   For a baseline reset without a DB, use:" >&2
  echo "     ./backend/scripts/sync-production-schema.sh --from-schema=prisma/schema.prisma" >&2
  exit 1
fi

# Mask URL for logs
MASKED_URL="$(echo "$DATABASE_URL" | sed -E 's|://[^@]*@|://***:***@|')"
echo "=========================================="
echo "🔄 Syncing production snapshot from DB"
echo "=========================================="
echo "URL:      $MASKED_URL"
echo "Snapshot: $SNAPSHOT_PRISMA"
echo ""

# Locate prisma
if [[ -x "$BACKEND_DIR/node_modules/.bin/prisma" ]]; then
  PRISMA_BIN="$BACKEND_DIR/node_modules/.bin/prisma"
elif command -v prisma &>/dev/null; then
  PRISMA_BIN="prisma"
else
  PRISMA_BIN="npx prisma"
fi

# Backup existing snapshot
if [[ -f "$SNAPSHOT_PRISMA" ]]; then
  cp "$SNAPSHOT_PRISMA" "$SNAPSHOT_PRISMA.bak"
  echo "Backed up existing snapshot to $SNAPSHOT_PRISMA.bak"
fi

# Introspect production into a temp file, then atomically move.
TMP_SNAPSHOT="$(mktemp)"
# prisma db pull writes to schema.prisma by default, so we use --schema to control output.
# Prisma 7: `prisma db pull` introspects the datasource URL into the schema file.
# We create a temporary schema file that just holds the introspected result.
echo "▶ Running prisma db pull (introspection)..."
# We need to run from BACKEND_DIR so config is found; DATABASE_URL env is already set.
# Use --schema to write directly to temp snapshot location via a temporary config override?
# Simpler: run db pull and then copy the generated snapshot.
# Prisma db pull overwrites the configured schema file, so we must not overwrite SCHEMA_PRISMA.
# Workaround: use a temporary directory with its own minimal config.

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR" "$TMP_SNAPSHOT" 2>/dev/null || true' EXIT

# Create a minimal prisma schema that will be overwritten by pull
cat > "$TMP_DIR/schema.prisma" <<'PRISMA'
datasource db {
  provider = "postgresql"
}
generator client {
  provider = "prisma-client-js"
}
PRISMA

cat > "$TMP_DIR/prisma.config.ts" <<'CONFIG'
import { defineConfig } from 'prisma/config';
export default defineConfig({
  schema: 'schema.prisma',
  datasource: { url: process.env.DATABASE_URL },
});
CONFIG

echo "▶ Introspecting... (this may take a few seconds)"
set +e
INTROSPECT_OUTPUT=$(cd "$TMP_DIR" && $PRISMA_BIN db pull --force 2>&1)
INTROSPECT_EXIT=$?
set -e
echo "$INTROSPECT_OUTPUT"

if [[ $INTROSPECT_EXIT -ne 0 ]]; then
  echo "❌ prisma db pull failed (exit $INTROSPECT_EXIT)" >&2
  exit $INTROSPECT_EXIT
fi

# The pulled schema is now at $TMP_DIR/schema.prisma
if [[ ! -f "$TMP_DIR/schema.prisma" ]]; then
  echo "❌ Expected introspected schema not found at $TMP_DIR/schema.prisma" >&2
  exit 1
fi

# Verify it parses
echo "▶ Validating introspected schema..."
set +e
VALIDATE_OUTPUT=$(cd "$TMP_DIR" && $PRISMA_BIN validate 2>&1)
VALIDATE_EXIT=$?
set -e
if [[ $VALIDATE_EXIT -ne 0 ]]; then
  echo "⚠️  Introspected schema failed validation:" >&2
  echo "$VALIDATE_OUTPUT" >&2
  echo "   Proceeding anyway, but please review $TMP_DIR/schema.prisma" >&2
else
  echo "✅ Introspected schema validates"
fi

# Move to snapshot location
cp "$TMP_DIR/schema.prisma" "$SNAPSHOT_PRISMA"
echo "✅ Prisma snapshot written to $SNAPSHOT_PRISMA"

# Also generate SQL snapshot from the introspected schema
echo "▶ Generating SQL snapshot..."
(cd "$BACKEND_DIR" && DATABASE_URL="$DATABASE_URL" $PRISMA_BIN migrate diff --from-empty --to-schema="$SNAPSHOT_PRISMA" --script > "$SNAPSHOT_SQL" 2> /tmp/sync-err2.txt) || \
(cd "$BACKEND_DIR" && $PRISMA_BIN migrate diff --from-empty --to-schema="$SNAPSHOT_PRISMA" --script > "$SNAPSHOT_SQL" 2> /tmp/sync-err2.txt) || {
  cat /tmp/sync-err2.txt >&2
}
if head -n1 "$SNAPSHOT_SQL" | grep -q "Loaded Prisma config"; then
  tail -n +2 "$SNAPSHOT_SQL" > "$SNAPSHOT_SQL.tmp" && mv "$SNAPSHOT_SQL.tmp" "$SNAPSHOT_SQL"
fi
echo "✅ SQL snapshot written to $SNAPSHOT_SQL"

echo ""
echo "=========================================="
echo "✅ Sync complete"
echo "=========================================="
echo "Review the diff:"
echo "  git diff $SNAPSHOT_PRISMA"
echo "  git diff $SNAPSHOT_SQL"
echo ""
echo "If the new snapshot looks correct, commit it:"
echo "  git add $SNAPSHOT_PRISMA $SNAPSHOT_SQL"
echo "  git commit -m \"chore(prisma): refresh production snapshot\""
