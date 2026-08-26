#!/usr/bin/env bash
#
# teardown-preview-env.sh — tear down RemitMortage PR preview environments.
#
# Convention (must match the preview deployment workflow):
#   - Every AWS resource provisioned for a PR preview carries three tags:
#       Preview          = "true"
#       PreviewPR        = "<pull request number>"
#       PreviewCreatedAt = "<ISO-8601 UTC timestamp, e.g. 2026-08-25T10:00:00Z>"
#   - Preview resources live in App Runner services (backend API), CloudFront
#     distributions and S3 buckets (frontend static site). Preview-specific
#     Route 53 records are cleaned up best-effort by name (`preview-pr-<n>.`),
#     since individual records do not support resource tags.
#
# Usage:
#   teardown-preview-env.sh pr <pr-number>          # tear down one PR's preview
#   teardown-preview-env.sh sweep [<max-age-days>]  # tear down stale previews
#
# Output (for CI to build PR comments):
#   PREVIEW_TEARDOWN <pr> <resource-type> <identifier>   one line per removal
#   PREVIEW_TEARDOWN_DONE <pr> <removed-count>
#
# The script is idempotent (nothing matched is a successful no-op) and exits 0
# even when AWS assets are already gone.

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
STALE_ENV_MAX_AGE_DAYS="${STALE_ENV_MAX_AGE_DAYS:-14}"

TAG_PREVIEW="Preview"
TAG_PR="PreviewPR"
TAG_CREATED="PreviewCreatedAt"
TAG_PREVIEW_VALUE="true"

warn() { printf 'warning: %s\n' "$*" >&2; }

# ── tag helpers ────────────────────────────────────────────────────────────
# Tag query APIs differ per service; normalize to "Key=Value" lines.

tag_pairs() {
  local type="$1" id="$2"
  case "$type" in
    apprunner)
      aws apprunner list-tags-for-resource --region "$AWS_REGION" --resource-arn "$id" --output json 2>/dev/null \
        | jq -r '.Tags[]? | .Key + "=" + .Value' || true
      ;;
    cloudfront)
      aws cloudfront list-tags-for-resource --region "$AWS_REGION" --resource "$id" --output json 2>/dev/null \
        | jq -r '.Tags.Items[]? | .Key + "=" + .Value' || true
      ;;
    s3)
      aws s3api get-bucket-tagging --region "$AWS_REGION" --bucket "$id" --output json 2>/dev/null \
        | jq -r '.TagSet[]? | .Key + "=" + .Value' || true
      ;;
  esac
}

tag_value() {
  local type="$1" id="$2" key="$3"
  tag_pairs "$type" "$id" | sed -n "s/^${key}=//p" | head -1
}

is_preview() {
  local type="$1" id="$2" pr="${3:-}"
  local v
  v="$(tag_value "$type" "$id" "$TAG_PREVIEW")"
  [ "$v" = "$TAG_PREVIEW_VALUE" ] || return 1
  if [ -n "$pr" ]; then
    v="$(tag_value "$type" "$id" "$TAG_PR")"
    [ "$v" = "$pr" ] || return 1
  fi
  return 0
}

# age_days <iso-8601> — whole days elapsed since the timestamp (-1 unparsable).
# Uses python3 so GNU and BSD hosts agree on `%s`-style parsing.
age_days() {
  local ts="$1"
  python3 - "$ts" <<'PY'
import sys
from datetime import datetime, timezone
ts = sys.argv[1]
try:
    created = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    if created.tzinfo is None:
        created = created.replace(tzinfo=timezone.utc)
    print((datetime.now(timezone.utc) - created).days)
except Exception:
    print(-1)
PY
}

is_stale() {
  local type="$1" id="$2" max="$3" created age
  created="$(tag_value "$type" "$id" "$TAG_CREATED")"
  [ -n "$created" ] || return 1   # no creation tag → leave it alone
  age="$(age_days "$created")"
  [ "$age" -ge "$max" ]
}

# ── resource discovery ─────────────────────────────────────────────────────

list_identifiers() {
  local type="$1"
  case "$type" in
    apprunner)
      aws apprunner list-services --region "$AWS_REGION" --output json 2>/dev/null \
        | jq -r '.ServiceSummaryList[]?.ServiceArn' || true
      ;;
    cloudfront)
      aws cloudfront list-distributions --region "$AWS_REGION" --output json 2>/dev/null \
        | jq -r '.DistributionList.Items[]?.Id' || true
      ;;
    s3)
      aws s3api list-buckets --region "$AWS_REGION" --output json 2>/dev/null \
        | jq -r '.Buckets[]?.Name' || true
      ;;
  esac
}

# identifiers matching the preview convention, optionally for one PR only.
list_preview() {
  local type="$1" pr="${2:-}" id
  list_identifiers "$type" | while read -r id; do
    [ -n "$id" ] || continue
    is_preview "$type" "$id" "$pr" && printf '%s\n' "$id"
  done
}

# identifiers that are previews and older than max-age-days.
list_stale_ids() {
  local type="$1" max="$2" id
  list_identifiers "$type" | while read -r id; do
    [ -n "$id" ] || continue
    is_preview "$type" "$id" "" || continue
    is_stale "$type" "$id" "$max" && printf '%s\n' "$id"
  done
}

# ── deletion ────────────────────────────────────────────────────────────────

delete_one() {
  local type="$1" id="$2" cfg etag tmp status
  case "$type" in
    apprunner)
      aws apprunner delete-service --region "$AWS_REGION" --service-arn "$id" >/dev/null
      ;;
    cloudfront)
      # A CloudFront distribution must be disabled and fleet-wide "Deployed"
      # before `delete-distribution` will accept it.
      cfg="$(aws cloudfront get-distribution-config --region "$AWS_REGION" --id "$id" --output json)"
      etag="$(printf '%s' "$cfg" | jq -r '.ETag')"
      tmp="$(mktemp)"
      printf '%s' "$cfg" | jq '.DistributionConfig | .Enabled = false' > "$tmp"
      aws cloudfront update-distribution --region "$AWS_REGION" --id "$id" \
        --distribution-config "file://$tmp" --if-match "$etag" >/dev/null
      for _ in $(seq 1 60); do
        status="$(aws cloudfront get-distribution --region "$AWS_REGION" --id "$id" \
          --query 'Distribution.Status' --output text 2>/dev/null || true)"
        [ "$status" = "Deployed" ] && break
        sleep 10
      done
      etag="$(aws cloudfront get-distribution --region "$AWS_REGION" --id "$id" \
        --query 'ETag' --output text)"
      aws cloudfront delete-distribution --region "$AWS_REGION" --id "$id" --if-match "$etag" >/dev/null
      rm -f "$tmp"
      ;;
    s3)
      aws s3 rb --region "$AWS_REGION" "s3://$id" --force >/dev/null
      ;;
  esac
}

# Best-effort Route 53 cleanup: individual records cannot carry tags, so
# preview records are matched by name (`preview-pr-<n>.`). Records are only
# ever DELETEd with their exact existing shape — never modified — and a
# failure here is logged, not fatal.
delete_route53_records() {
  local pr="$1" zones zone changes batch
  zones="$(aws route53 list-hosted-zones --region "$AWS_REGION" --output json 2>/dev/null \
    | jq -r '.HostedZones[]?.Id' || true)"
  [ -n "$zones" ] || return 0
  for zone in $zones; do
    changes="$(aws route53 list-resource-record-sets --region "$AWS_REGION" --hosted-zone-id "$zone" --output json 2>/dev/null \
      | jq -c --arg tok "preview-pr-${pr}." '.ResourceRecordSets[]
           | select((.Name | contains($tok)) or ((.AliasTarget.DNSName // "") | contains($tok)))' || true)"
    [ -n "$changes" ] || continue
    batch="$(printf '%s\n' "$changes" | jq -sc '{Changes: [.[] | {Action: "DELETE", ResourceRecordSet: .}]}')"
    aws route53 change-resource-record-sets --region "$AWS_REGION" \
      --hosted-zone-id "$zone" --change-batch "$batch" >/dev/null 2>&1 \
      || warn "could not delete preview Route 53 record in zone $zone"
  done
}

# ── modes ──────────────────────────────────────────────────────────────────

# teardown_pr <pr> — remove every preview resource tagged for the PR.
teardown_pr() {
  local pr="$1" type total=0 id
  for type in apprunner cloudfront s3; do
    while read -r id; do
      [ -n "$id" ] || continue
      if delete_one "$type" "$id" 2>/dev/null; then
        printf 'PREVIEW_TEARDOWN %s %s %s\n' "$pr" "$type" "$id"
        total=$((total + 1))
      else
        warn "failed to delete ${type} ${id}"
      fi
    done <<<"$(list_preview "$type" "$pr")"
  done
  delete_route53_records "$pr" || true
  printf 'PREVIEW_TEARDOWN_DONE %s %s\n' "$pr" "$total"
}

# sweep_stale <max-age-days> — remove stale previews, grouped per PR.
sweep_stale() {
  local max="$1" type id pr tmp
  tmp="$(mktemp)"
  for type in apprunner cloudfront s3; do
    while read -r id; do
      [ -n "$id" ] || continue
      pr="$(tag_value "$type" "$id" "$TAG_PR")"
      pr="${pr:-unknown}"
      if delete_one "$type" "$id" 2>/dev/null; then
        printf 'PREVIEW_TEARDOWN %s %s %s\n' "$pr" "$type" "$id" | tee -a "$tmp"
      else
        warn "failed to delete stale ${type} ${id}"
      fi
    done <<<"$(list_stale_ids "$type" "$max")"
  done
  # Emit one DONE line per affected PR with its removal count.
  local pr2 count
  for pr2 in $(awk '{print $2}' "$tmp" | sort -u); do
    count="$(awk -v p="$pr2" '$2 == p { n++ } END { print n + 0 }' "$tmp")"
    printf 'PREVIEW_TEARDOWN_DONE %s %s\n' "$pr2" "$count"
  done
  rm -f "$tmp"
}

# ---- entry point ----

usage() {
  printf 'usage: %s pr <pr-number> | sweep [max-age-days]\n' "$0"
  exit 1
}

[ $# -ge 1 ] || usage

case "$1" in
  pr)
    [ $# -ge 2 ] || usage
    teardown_pr "$2"
    ;;
  sweep)
    sweep_stale "${2:-$STALE_ENV_MAX_AGE_DAYS}"
    ;;
  *)
    usage
    ;;
esac