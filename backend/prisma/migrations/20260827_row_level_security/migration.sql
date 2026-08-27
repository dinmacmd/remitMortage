-- Row-Level Security (RLS) Migration
-- Adds database-enforced tenant isolation as defense-in-depth for tenant data.
-- Each query missing an explicit tenant filter still returns only rows
-- belonging to the session's organization context.

-- ── Helper: set the current tenant context ──────────────────────────────────
-- Called once per request by the connection middleware to scope all subsequent
-- queries in that session to a single tenant.

CREATE OR REPLACE FUNCTION set_current_tenant(tenant_id TEXT)
RETURNS VOID AS $$
BEGIN
  PERFORM set_config('app.current_tenant', tenant_id, false);
END;
$$ LANGUAGE plpgsql;

-- ── Helper: get the current tenant context ──────────────────────────────────

CREATE OR REPLACE FUNCTION get_current_tenant()
RETURNS TEXT AS $$
BEGIN
  RETURN current_setting('app.current_tenant', true);
END;
$$ LANGUAGE plpgsql;

-- ── Helper: bypass RLS for admin queries ────────────────────────────────────
-- Admin sessions call this to temporarily elevate past tenant isolation.

CREATE OR REPLACE FUNCTION set_tenant_bypass(bypass BOOLEAN)
RETURNS VOID AS $$
BEGIN
  PERFORM set_config('app.bypass_rls', bypass::TEXT, false);
END;
$$ LANGUAGE plpgsql;

-- ── Enable RLS on tenant-scoped tables ──────────────────────────────────────

ALTER TABLE "Applicant" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "LoanApplication" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "Borrower" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "VerificationResult" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "BorrowerCredential" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "KycDocument" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "NotificationPreference" ENABLE ROW LEVEL SECURITY;

-- ── Policies: Applicant ─────────────────────────────────────────────────────
-- Tenant isolation on Applicant is based on stellarAddress matching the
-- current session's tenant context.

CREATE POLICY tenant_isolation_applicant ON "Applicant"
  USING (
    current_setting('app.bypass_rls', true) = 'true'
    OR stellarAddress = current_setting('app.current_tenant', true)
  );

-- ── Policies: LoanApplication ───────────────────────────────────────────────
-- Isolated via the applicant's stellarAddress.

CREATE POLICY tenant_isolation_loan_application ON "LoanApplication"
  USING (
    current_setting('app.bypass_rls', true) = 'true'
    OR "applicantId" IN (
      SELECT id FROM "Applicant"
      WHERE stellarAddress = current_setting('app.current_tenant', true)
    )
  );

-- ── Policies: Borrower ──────────────────────────────────────────────────────

CREATE POLICY tenant_isolation_borrower ON "Borrower"
  USING (
    current_setting('app.bypass_rls', true) = 'true'
    OR stellarAddress = current_setting('app.current_tenant', true)
  );

-- ── Policies: VerificationResult ────────────────────────────────────────────

CREATE POLICY tenant_isolation_verification_result ON "VerificationResult"
  USING (
    current_setting('app.bypass_rls', true) = 'true'
    OR "applicantId" IN (
      SELECT id FROM "Applicant"
      WHERE stellarAddress = current_setting('app.current_tenant', true)
    )
  );

-- ── Policies: BorrowerCredential ────────────────────────────────────────────

CREATE POLICY tenant_isolation_borrower_credential ON "BorrowerCredential"
  USING (
    current_setting('app.bypass_rls', true) = 'true'
    OR "applicantId" IN (
      SELECT id FROM "Applicant"
      WHERE stellarAddress = current_setting('app.current_tenant', true)
    )
  );

-- ── Policies: KycDocument ───────────────────────────────────────────────────

CREATE POLICY tenant_isolation_kyc_document ON "KycDocument"
  USING (
    current_setting('app.bypass_rls', true) = 'true'
    OR "applicantId" IN (
      SELECT id FROM "Applicant"
      WHERE stellarAddress = current_setting('app.current_tenant', true)
    )
  );

-- ── Policies: NotificationPreference ────────────────────────────────────────

CREATE POLICY tenant_isolation_notification_preference ON "NotificationPreference"
  USING (
    current_setting('app.bypass_rls', true) = 'true'
    OR "applicantId" IN (
      SELECT id FROM "Applicant"
      WHERE stellarAddress = current_setting('app.current_tenant', true)
    )
  );

-- ── Force RLS for table owners (defense-in-depth) ───────────────────────────
-- Without this, table owners bypass RLS by default.

ALTER TABLE "Applicant" FORCE ROW LEVEL SECURITY;
ALTER TABLE "LoanApplication" FORCE ROW LEVEL SECURITY;
ALTER TABLE "Borrower" FORCE ROW LEVEL SECURITY;
ALTER TABLE "VerificationResult" FORCE ROW LEVEL SECURITY;
ALTER TABLE "BorrowerCredential" FORCE ROW LEVEL SECURITY;
ALTER TABLE "KycDocument" FORCE ROW LEVEL SECURITY;
ALTER TABLE "NotificationPreference" FORCE ROW LEVEL SECURITY;
