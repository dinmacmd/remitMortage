# Production Schema Snapshots

This directory holds **versioned snapshots of the production database schema** used by the drift-detection pipeline.

## Files

| File | Purpose |
|------|---------|
| `production-schema.prisma` | Introspected Prisma datamodel of production (`prisma db pull` output). Used for file-to-file diffs without a live DB. |
| `production-schema.sql` | `pg_dump --schema-only` equivalent generated via `prisma migrate diff --from-empty --to-schema=prisma/schema.prisma --script`. Useful as a SQL baseline for review. |

Both files represent the **same logical schema** — the committed `prisma/schema.prisma` at the time the snapshot was taken. The drift job compares either file against the current `prisma/schema.prisma`:

```bash
# File-to-file (no DB needed, works in PRs from forks)
npx prisma migrate diff --from-schema=prisma/__snapshots__/production-schema.prisma --to-schema=prisma/schema.prisma

# Live DB to file (nightly, requires PRODUCTION_DATABASE_URL)
npx prisma migrate diff --from-config-datasource --to-schema=prisma/schema.prisma
```

## Refreshing the Snapshot

When production has legitimately drifted forward (hotfix applied out-of-band) and you have reconciled it into `schema.prisma`:

```bash
# Option A: Refresh from live production (requires access)
./scripts/sync-production-schema.sh

# Option B: Refresh from current committed schema (baseline reset)
cp prisma/schema.prisma prisma/__snapshots__/production-schema.prisma
npx prisma migrate diff --from-empty --to-schema=prisma/schema.prisma --script > prisma/__snapshots__/production-schema.sql
```

Commit the updated snapshot in the same PR that reconciles the drift. See `docs/PRISMA_SCHEMA_DRIFT_REMEDIATION.md` for the full runbook.

## CI Behaviour

- PRs without `PRODUCTION_DATABASE_URL` secret use the **committed snapshot file** — deterministic, no network.
- `push` to `main` and nightly `schedule` use the **live URL** if the secret is present, falling back to the file otherwise.
- Either path fails with exit code `2` and an uploaded `drift.txt` artifact when drift is detected.
