# Anonymized Staging/Dev Seed Pipeline

Lets developers and QA work against realistic, production-shaped data in
staging and dev without ever exposing real borrower PII.

## What it does

`backend/scripts/anonymize-staging-seed.ts` reads a production database
snapshot (ideally a read-only replica, never the primary) and writes an
irreversibly anonymized copy into a lower-environment database:

- **Referential integrity is preserved.** Primary keys and foreign keys are
  copied unchanged; tables are copied parent-before-child (see `MODEL_ORDER`
  in the script). Only PII *payload* columns (wallet/Stellar addresses,
  emails, phone numbers, tax IDs, IP addresses, document names, DIDs,
  session/API secrets, webhook URLs/secrets, ...) are replaced.
- **Realistic distributions are preserved.** Anonymized values keep the
  shape of the original (a Stellar address still looks like a Stellar
  address; `monthlyIncome` is jittered ±8% rather than replaced, so
  aggregate stats stay representative).
- **It's irreversible.** Every PII field is replaced with the output of an
  HMAC-SHA256 keyed hash. The key (`salt`) is generated fresh in memory for
  each run via `crypto.randomBytes` and is never written to disk, logged, or
  returned — once the process exits, there is no way (for anyone, including
  whoever ran the job) to map an anonymized value back to the original.
  Within a single run, the same source value always maps to the same output,
  which keeps unique constraints (e.g. `stellarAddress`) satisfied.

## Running it

```bash
cd backend
SOURCE_DATABASE_URL=postgres://readonly-user@prod-replica/db \
TARGET_DATABASE_URL=postgres://staging-user@staging-db/db \
ANONYMIZE_TARGET_ENV=staging \
  npm run anonymize:staging-seed
```

Each run clears the target's tables first, so it's idempotent — safe to run
repeatedly on a schedule.

## Cadence

`devops/k8s/anonymized-staging-seed-cronjob.yaml` runs the pipeline weekly
(Sunday 03:00 UTC) inside the **staging cluster only**. See
[devops/k8s/README.md](../devops/k8s/README.md) for deployment details.

## Safeguards against running against production

This pipeline's entire purpose is to move data out of production, so it
fails closed at every layer rather than offering an override:

1. **Explicit opt-in target.** `ANONYMIZE_TARGET_ENV` must literally be one
   of `staging`, `dev`, `development`, or `test`. There is no default — an
   unset or misspelled value refuses to run rather than silently proceeding.
2. **`NODE_ENV=production` refuses outright.** The pipeline must be invoked
   from a CI/ops job, never from inside a production deployment's own
   process.
3. **Source/target identity check.** If `TARGET_DATABASE_URL` equals
   `SOURCE_DATABASE_URL`, the run is refused — the pipeline is destructive to
   its target (it clears tables before reseeding), so source and target must
   always be distinct databases.
4. **Connection-string pattern check.** `TARGET_DATABASE_URL` is rejected if
   it contains `prod`, `production`, `primary`, or `master`, as defense in
   depth against a copy-pasted production URL.
5. **Deployment topology.** The CronJob is defined to run only in the
   staging cluster/namespace; it authenticates to production solely via a
   read-only replica credential (`production-readonly-secrets`), and its
   write target is always the staging DB secret in that same namespace.

See `assertSafeToRun()` in `backend/scripts/anonymize-staging-seed.ts` for
the implementation.
