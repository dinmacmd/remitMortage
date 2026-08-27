#!/usr/bin/env bash
# Wrapper — delegates to the canonical script in backend/scripts/
# Allows invocation as ./scripts/detect-prisma-drift.sh from repo root.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_SCRIPT="$SCRIPT_DIR/../backend/scripts/detect-prisma-drift.sh"
if [[ ! -x "$BACKEND_SCRIPT" && ! -f "$BACKEND_SCRIPT" ]]; then
  echo "❌ Backend drift script not found at $BACKEND_SCRIPT" >&2
  exit 1
fi
exec bash "$BACKEND_SCRIPT" "$@"
