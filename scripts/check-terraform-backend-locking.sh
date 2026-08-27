#!/usr/bin/env bash
set -euo pipefail

# Script: check-terraform-backend-locking.sh
# Purpose: Audit all Terraform root modules to ensure they configure a remote backend with state locking enabled.

ERRORS=0

echo "==> Auditing Terraform root modules for remote backend state locking..."

# Find all directories containing *.tf files that define a terraform block or provider
ROOT_MODULES=$(find devops infrastructure -type f -name "*.tf" -exec grep -l "provider \"aws\"" {} + | xargs -n1 dirname | sort -u)

for mod in $ROOT_MODULES; do
  echo "Checking module directory: $mod"
  
  # Search all .tf files in module for backend configuration
  TF_FILES=$(find "$mod" -maxdepth 1 -name "*.tf")
  
  HAS_REMOTE_BACKEND=0
  HAS_STATE_LOCKING=0

  if grep -E -q 'backend\s+"(s3|remote|gcs|azurerm)"' $TF_FILES; then
    HAS_REMOTE_BACKEND=1
  fi

  if grep -E -q '(dynamodb_table\s*=|use_lockfile\s*=\s*true)' $TF_FILES; then
    HAS_STATE_LOCKING=1
  fi

  if [ $HAS_REMOTE_BACKEND -eq 0 ]; then
    echo "  ❌ ERROR: Module '$mod' does not configure a remote backend!"
    ERRORS=$((ERRORS + 1))
  elif [ $HAS_STATE_LOCKING -eq 0 ]; then
    echo "  ❌ ERROR: Module '$mod' uses a remote backend but lacks state locking (dynamodb_table / use_lockfile)!"
    ERRORS=$((ERRORS + 1))
  else
    echo "  ✅ Module '$mod' correctly configures a remote backend with state locking."
  fi
done

if [ $ERRORS -gt 0 ]; then
  echo ""
  echo "❌ Verification failed: $ERRORS Terraform root module(s) missing remote backend or state locking configuration."
  exit 1
fi

echo ""
echo "✅ All Terraform root modules passed state locking verification."
exit 0
