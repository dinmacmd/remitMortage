# Prisma Schema Drift Remediation Runbook

When the `Prisma Schema Drift Detection` workflow fails, the committed `prisma/schema.prisma` no longer matches the production database (or the committed production snapshot). Drift means a table, column, index, enum, or other DDL object was created, altered, or deleted outside the normal `prisma migrate` flow — usually a manual `psql` change, a hotfix applied directly to production, or a migration that was run in one environment but not committed.

This runbook mirrors `docs/terraform-drift-remediation.md` but for the database schema.

---

## 1. Understand the Alert

The `Prisma Schema Drift Detection` workflow (`.github/workflows/prisma-drift.yml`) runs in two modes:

| Mode | Trigger | Compares | Secret needed |
|------|---------|----------|---------------|
| **Snapshot file** | Every PR that touches `backend/prisma/**` | `prisma/__snapshots__/production-schema.prisma` (committed) vs `prisma/schema.prisma` (committed) | None — works in forks |
| **Live DB** | `push` to `main` and nightly `03:00 UTC` | Live production DB (`PRODUCTION_DATABASE_URL`) vs `prisma/schema.prisma` | `PRODUCTION_DATABASE_URL` |

A failure with exit code `2` means `prisma migrate diff --exit-code` found a non-empty diff. The workflow uploads:

- `drift-summary.txt` — human-readable summary (e.g. `[+] Added tables - DriftTest`, `[*] Changed the 'status' column on 'LoanApplication'`)
- `drift.sql` — the SQL that would migrate FROM → TO (the reconciling migration)
- `drift-raw.txt` — raw `prisma migrate diff` output

Download the `prisma-drift-*` artifact from the failed run before doing anything else. The summary also appears in the job's `GITHUB_STEP_SUMMARY`.

**Example clean output:**

```
Loaded Prisma config from prisma.config.ts.

No difference detected.
```

**Example drifted output (human-readable):**

```
[+] Added tables
  - DriftProbe

[*] Changed the `status` column on the `LoanApplication` table. No underlying data migration needed.
```

**Example drifted output (SQL):**

```sql
-- CreateTable
CREATE TABLE "DriftProbe" (
    "id" TEXT NOT NULL,
    "probe" TEXT NOT NULL,
    CONSTRAINT "DriftProbe_pkey" PRIMARY KEY ("id")
);
```

---

## 2. Classify the Drift

Read `drift-summary.txt` and `drift.sql` and categorise each changed object:

| Class | Description | Action |
|-------|-------------|--------|
| **Authorized** | Deliberate hotfix applied manually to production under incident pressure and not yet codified in `schema.prisma` / `prisma/migrations/` | [Reconcile snapshot → schema](#3a-reconcile-authorized-out-of-band-changes) |
| **Unauthorized** | Unexpected or unrecognised DDL — potential security incident or accidental `psql` by an operator | [Revert in production](#3b-revert-unauthorized-changes) |
| **Migration history divergence** | Production's `_prisma_migrations` table does not match `prisma/migrations/` (migration applied in one env but not the other, or `migrate resolve` needed) | [Fix migration history](#3c-fix-migration-history-divergence) |
| **Stale snapshot** | Snapshot file is behind the committed schema because a migration was merged but `production-schema.prisma` was not refreshed | [Refresh snapshot](#3a-reconcile-authorized-out-of-band-changes) |

---

## 3. Remediation Procedures

### 3a. Reconcile Authorized Out-of-Band Changes

Use this when the production change was intentional (e.g. emergency index or column added via `psql`).

**If the change should be kept (codify it):**

1. **Document** — add a comment to the drift issue/PR describing why it was made manually and who approved it.
2. **Codify the drift** — generate a migration that captures the out-of-band DDL:

   ```bash
   # Option 1: let Prisma diff live DB → schema generate the migration
   # (requires PRODUCTION_DATABASE_URL)
   npx prisma migrate diff \
     --from-config-datasource \
     --to-schema=prisma/schema.prisma \
     --script > prisma/migrations/$(date +%Y%m%d%H%M%S)_reconcile_drift/migration.sql

   # Option 2: pull the live schema into schema.prisma, then create a migration
   npx prisma db pull          # overwrites schema.prisma with production introspection
   npx prisma migrate dev --name reconcile_production_drift
   git diff prisma/schema.prisma  # review carefully
   ```

   For snapshot-file drift (no live DB), simply update the snapshot to match the intended state after the migration is committed:

   ```bash
   ./backend/scripts/sync-production-schema.sh --from-schema=prisma/schema.prisma
   ```

3. **Validate:**

   ```bash
   npx prisma validate --schema=prisma/schema.prisma
   npx prisma migrate diff --from-schema=prisma/__snapshots__/production-schema.prisma --to-schema=prisma/schema.prisma
   # Should now print "No difference detected."
   # Or via the helper:
   ./backend/scripts/detect-prisma-drift.sh --exit-code
   ```

4. Open a PR with the migration + refreshed snapshot. After merge, the next scheduled run should pass.

**If the snapshot is stale (migration was merged but snapshot not updated):**

```bash
# After any migration that modifies the schema, refresh the snapshot in the same PR:
cp prisma/schema.prisma prisma/__snapshots__/production-schema.prisma
npx prisma migrate diff --from-empty --to-schema=prisma/schema.prisma --script > prisma/__snapshots__/production-schema.sql

# Or use the helper (does both):
./backend/scripts/sync-production-schema.sh --from-schema=prisma/schema.prisma
git add prisma/__snapshots__/production-schema.prisma prisma/__snapshots__/production-schema.sql
git commit -m "chore(prisma): refresh production snapshot after <migration-name>"
```

### 3b. Revert Unauthorized Changes

Use this when the change is unrecognised or potentially malicious.

1. **Treat as potential security incident** — notify the security team and preserve evidence before reverting:
   ```bash
   # Who ran the DDL?
   psql "$PRODUCTION_DATABASE_URL" -c "
     SELECT query, usename, application_name, backend_start
     FROM pg_stat_statements JOIN pg_stat_activity USING (query)
     WHERE query ILIKE '%ALTER TABLE%' OR query ILIKE '%CREATE TABLE%'
     ORDER BY backend_start DESC LIMIT 20;
   "
   # Or CloudTrail / pgAudit logs if enabled
   ```

2. **Revert by applying the inverse of `drift.sql`**, or by restoring the drifted object:

   ```bash
   # Example: drift.sql says CREATE TABLE "DriftProbe" — revert with DROP
   psql "$PRODUCTION_DATABASE_URL" -c 'DROP TABLE IF EXISTS "DriftProbe" CASCADE;'

   # Example: drift says column added — drop it
   psql "$PRODUCTION_DATABASE_URL" -c 'ALTER TABLE "LoanApplication" DROP COLUMN IF EXISTS "driftColumn";'
   ```

   For a larger revert, restore the last known-good schema snapshot:

   ```bash
   # Generate inverse migration from live DB → snapshot (snapshot is known-good)
   npx prisma migrate diff \
     --from-config-datasource \
     --to-schema=prisma/__snapshots__/production-schema.prisma \
     --script | psql "$PRODUCTION_DATABASE_URL"
   ```

3. **Verify:**

   ```bash
   ./backend/scripts/detect-prisma-drift.sh --from-config-datasource --exit-code
   # Should print "No drift detected"
   ```

4. Audit credentials for the role that performed the change; rotate if compromise is suspected.
5. Close the drift issue with a post-mortem.

### 3c. Fix Migration History Divergence

Use this when `_prisma_migrations` does not match the filesystem:

**Production has a migration not in the repo (hotfix applied via `migrate deploy` but branch not merged):**

```bash
# On a machine with PRODUCTION_DATABASE_URL:
npx prisma migrate status
# Shows "Following migrations have not been applied to the database" or extra rows

# If the migration is legitimate, commit its directory from production's history
# (copy the row from _prisma_migrations and recreate the migration.sql from drift.sql)
# Then:
npx prisma migrate resolve --applied "20260825_hotfix_name"
```

**Repo has a migration not yet applied to production:**

```bash
# Normal deploy path will catch up:
npx prisma migrate deploy
# Verify:
npx prisma migrate status  # should show "No pending migrations"
```

**Migration failed halfway:**

```bash
npx prisma migrate diff --from-config-datasource --to-schema=prisma/schema.prisma --script
# Review the diff, then either:
npx prisma migrate resolve --rolled-back "20260825_failed_migration"
# or
npx prisma migrate resolve --applied "20260825_failed_migration"
# depending on whether the DB side actually committed
```

After any `migrate resolve`, refresh the snapshot and re-run the drift check.

---

## 4. Preventing Future Drift

| Control | Description |
|---------|-------------|
| **Single migration path** | All DDL must go through `prisma migrate dev` / `prisma migrate deploy`. Never run bare `psql ALTER TABLE` in production except via the authorized hotfix path above. |
| **Restricted production access** | Revoke direct `DDL` grants for operator roles in production; use a break-glass role with MFA and audit logging (`pgAudit`). |
| **CI gate** | Make `Prisma Drift Detection` a required status check (see `.github/workflows/prisma-drift.yml`). PRs that change `prisma/schema.prisma` without updating the snapshot will fail. |
| **Snapshot hygiene** | Every PR that adds a migration must also run `./backend/scripts/sync-production-schema.sh --from-schema=prisma/schema.prisma` and commit the snapshot. Add this to your PR checklist. |
| **Migration history monitoring** | The existing boot-time guard in `backend/src/index.ts:81` (`checkPrismaMigrations()`) plus `backend/src/utils/prismaCheck.ts:20` already aborts production boot when `migrate status` shows pending migrations. Keep `SKIP_PRISMA_CHECK` unset in production. |
| **Periodic live checks** | The nightly `schedule: '0 3 * * *'` live-DB job catches drift that snapshot-file checks cannot (e.g. manual DB edits that were never snapshot). Keep `PRODUCTION_DATABASE_URL` secret rotated. |
| **Backups** | Nightly `backup-verification.yml` ensures a restore is possible if a revert goes wrong. |

---

## 5. Required Secrets & Files

| Secret / File | Description |
|---------------|-------------|
| `PRODUCTION_DATABASE_URL` | Read-only Postgres URL for live-DB drift mode (e.g. `postgresql://drift_checker:RO_PASS@prod-host:5432/remitmortgage?sslmode=require`). The DB user needs only `SELECT` on `information_schema` / `pg_catalog`; no write grants. |
| `DEVOPS_ALERT_WEBHOOK_URL` | Slack/Discord webhook for drift notifications (optional, reused from `terraform-drift-detection.yml`). |
| `backend/prisma/__snapshots__/production-schema.prisma` | Committed snapshot of production's Prisma datamodel. Updated via `sync-production-schema.sh`. |
| `backend/prisma/__snapshots__/production-schema.sql` | SQL counterpart (`pg_dump --schema-only` equivalent). For human review; not used by the diff directly. |
| `backend/prisma.config.ts` | Must define `datasource.url = process.env.DATABASE_URL` so `--from-config-datasource` works (see `prisma.config.ts:1-11`). |

---

## 6. Manual Workflow Trigger & Local Usage

**Trigger the check on-demand:**

1. Go to **Actions → Prisma Schema Drift Detection → Run workflow**.
2. Review the `prisma-drift-*` artifact and the job summary (`GITHUB_STEP_SUMMARY`).

**Run locally (no DB, file-to-file):**

```bash
# From repo root — uses committed snapshot
./backend/scripts/detect-prisma-drift.sh
./backend/scripts/detect-prisma-drift.sh --exit-code && echo "clean" || echo "drift"

# With custom paths (e.g. testing a branch)
./backend/scripts/detect-prisma-drift.sh --from-schema=backend/prisma/__snapshots__/production-schema.prisma --to-schema=backend/prisma/schema.prisma --exit-code
```

**Run locally (live DB):**

```bash
PRODUCTION_DATABASE_URL=postgres://... ./backend/scripts/detect-prisma-drift.sh --from-config-datasource --exit-code
# Or explicitly:
DATABASE_URL=postgres://... npx prisma migrate diff --from-config-datasource --to-schema=backend/prisma/schema.prisma --exit-code
DATABASE_URL=postgres://... npx prisma migrate diff --from-config-datasource --to-schema=backend/prisma/schema.prisma --script | head -n 100
```

**Refresh snapshot after a legitimate change:**

```bash
# From a migration PR (no DB needed, baseline reset):
./backend/scripts/sync-production-schema.sh --from-schema=prisma/schema.prisma

# From live production (requires network):
PRODUCTION_DATABASE_URL=postgres://... ./backend/scripts/sync-production-schema.sh
git add backend/prisma/__snapshots__/production-schema.prisma backend/prisma/__snapshots__/production-schema.sql
git commit -m "chore(prisma): refresh production snapshot after <reason>"
```

---

## 7. Interpreting the Diff

`prisma migrate diff` prints a diff that migrates **FROM → TO** (apply FROM's state to reach TO). In drift detection:

- `FROM` = production snapshot (or live DB)
- `TO` = committed `schema.prisma`

So:

- `[+] Added tables - Foo` means `Foo` exists in `TO` but not in `FROM` — committed schema has a table production lacks. The reconciling SQL will `CREATE TABLE "Foo"`.
- `[-] Removed tables - Bar` means `Bar` exists in `FROM` but not in `TO` — production has a table the committed schema does not. The reconciling SQL will `DROP TABLE "Bar"`.
- `[*] Changed the 'x' column on the 'Y' table` — type, default, or nullability differs. Check `drift.sql` for the `ALTER TABLE` statement.
- Partition children like `AuditLog_2024_01` are ephemeral (see `backend/prisma/migrations/20260825_partition_auditlog/migration.sql:5-13`). The drift harness ignores them via the Prisma datamodel (they are not in `schema.prisma`), so they should not cause false positives. If they do appear, filter them as noise and investigate `pg_partman` vs Prisma.

When in doubt, generate both human and SQL forms:

```bash
npx prisma migrate diff --from-schema=prisma/__snapshots__/production-schema.prisma --to-schema=prisma/schema.prisma
npx prisma migrate diff --from-schema=prisma/__snapshots__/production-schema.prisma --to-schema=prisma/schema.prisma --script
```

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Snapshot file not found` | Snapshot was never committed or was deleted | Run `./backend/scripts/sync-production-schema.sh --from-schema=prisma/schema.prisma` and commit |
| `Failed to parse syntax of config file at prisma.config.ts` | `prisma.config.ts` is invalid or uses old `earlyAccess` shape | Ensure it uses `defineConfig({ schema: 'prisma/schema.prisma', datasource: { url: process.env.DATABASE_URL } })` (see `backend/prisma.config.ts`) |
| `P1012 error validating schema` with `@@index` | Snapshot was generated via `pg_dump` and not normalised to Prisma syntax | The file-to-file diff expects Prisma files on both sides; regenerate the Prisma snapshot via `prisma db pull` or the sync script, not raw `pg_dump` |
| Drift on `AuditLog` partitions | Partition children differ due to monthly rotation | Expected; the Prisma snapshot does not model partition children — ignore them in the diff, or update `detect-prisma-drift.sh` to filter `AuditLog_\d+` |
| Live-DB mode exits 1 with `Cannot resolve environment variable: DATABASE_URL` | `PRODUCTION_DATABASE_URL` not set or not exported as `DATABASE_URL` | The wrapper does this for you; ensure `PRODUCTION_DATABASE_URL` is set in the workflow secrets or `export DATABASE_URL=...` before running manually |
| `prisma migrate diff` succeeds but `migrate deploy` fails with `P3005` | Migration history has diverged (`_prisma_migrations` mismatch) | See §3c |

---

## 9. References

- Implementation: `backend/scripts/detect-prisma-drift.sh`, `backend/scripts/sync-production-schema.sh`, `backend/src/utils/prismaDrift.ts`, `backend/src/__tests__/prismaSchemaDrift.test.ts`, `backend/prisma/__snapshots__/README.md`
- Workflow: `.github/workflows/prisma-drift.yml`
- Precedent: `docs/terraform-drift-remediation.md`, `.github/workflows/terraform-drift-detection.yml`
- Prisma docs: https://pris.ly/d/migrate-diff, https://pris.ly/d/config
- Boot guard: `backend/src/index.ts:81`, `backend/src/utils/prismaCheck.ts:20`
