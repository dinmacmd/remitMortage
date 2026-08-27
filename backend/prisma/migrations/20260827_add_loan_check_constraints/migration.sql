-- Add interestRateBps column and CHECK constraints for LoanApplication
-- Protocol bounds: 200 bps (2%) floor, 1800 bps (18%) cap — from contracts/verification-registry/src/lib.rs RATE_FLOOR_BPS / RATE_CAP_BPS
-- Principal must be > 0 ; existing seed data uses 70000, 50000 etc, so safe to enforce immediately.

-- 1. Add column if not exists (idempotent). NOT NULL with DEFAULT so existing rows backfill to 800 (within 200..1800).
ALTER TABLE "LoanApplication" ADD COLUMN IF NOT EXISTS "interestRateBps" INTEGER NOT NULL DEFAULT 800;

-- Backfill any NULLs that might have slipped through (defensive, should be none after ADD COLUMN DEFAULT)
UPDATE "LoanApplication" SET "interestRateBps" = 800 WHERE "interestRateBps" IS NULL;

-- 2. Validate existing data before adding CHECKs — fail fast with clear message if dirty data exists.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM "LoanApplication" WHERE "principal" <= 0) THEN
    RAISE EXCEPTION 'Migration would violate LoanApplication_principal_check: principal must be > 0. Found % rows', (SELECT count(*) FROM "LoanApplication" WHERE "principal" <= 0);
  END IF;
  IF EXISTS (SELECT 1 FROM "LoanApplication" WHERE "interestRateBps" < 200 OR "interestRateBps" > 1800) THEN
    RAISE EXCEPTION 'Migration would violate LoanApplication_interestRateBps_check: interestRateBps must be BETWEEN 200 AND 1800. Found % rows', (SELECT count(*) FROM "LoanApplication" WHERE "interestRateBps" < 200 OR "interestRateBps" > 1800);
  END IF;
END $$;

-- 3. Add CHECK constraints (IF NOT EXISTS via pg_constraint)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'LoanApplication_principal_check') THEN
    ALTER TABLE "LoanApplication" ADD CONSTRAINT "LoanApplication_principal_check" CHECK ("principal" > 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'LoanApplication_interestRateBps_check') THEN
    ALTER TABLE "LoanApplication" ADD CONSTRAINT "LoanApplication_interestRateBps_check" CHECK ("interestRateBps" >= 200 AND "interestRateBps" <= 1800);
  END IF;
END $$;
