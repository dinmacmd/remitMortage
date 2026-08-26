-- Issue #474: Audit-trigger logging for direct manual database edits.
--
-- Row-level triggers on the sensitive tables (Applicant, VerificationResult,
-- LoanApplication) log every INSERT/UPDATE/DELETE — including manual SQL by
-- ops — into the partitioned AuditLog table with the executing role,
-- timestamp, and before/after values. Application-layer writes through Prisma
-- land in the same log (acceptance criterion #2).
--
-- Restriction: after this migration, INSERT/UPDATE/DELETE on "AuditLog" are
-- revoked from PUBLIC, so the only writers are the triggers themselves. The
-- trigger function is SECURITY DEFINER and runs with its owner's privileges,
-- so it keeps writing even after the revoke.
--
-- NOTE: for the revoke to bind against the application, the application role
-- must not own the "AuditLog" table (table owners bypass ACLs). The backend
-- connects with a dedicated role that should own database content but NOT the
-- audit table; if it currently owns it, transfer ownership before applying
-- this migration:
--   ALTER TABLE "AuditLog" OWNER TO <privileged_role>;

-- 1. Trigger function: writes one AuditLog row per changed row.
CREATE OR REPLACE FUNCTION log_manual_table_edit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_before jsonb;
    v_after  jsonb;
BEGIN
    v_before := NULL;
    v_after  := NULL;

    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        v_before := to_jsonb(OLD);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        v_after := to_jsonb(NEW);
    END IF;

    INSERT INTO "AuditLog" (
        "id",
        "action",
        "actorAddress",
        "metadata",
        "createdAt"
    ) VALUES (
        gen_random_uuid()::text,
        'db:' || lower(TG_TABLE_NAME) || ':' || lower(TG_OP),
        'pg:' || current_user,
        jsonb_build_object(
            'source',   'postgres-trigger',
            'table',    TG_TABLE_NAME,
            'operation', TG_OP,
            'role',     current_user,
            'client',   current_setting('application_name', true),
            'before',   v_before,
            'after',    v_after
        ),
        CURRENT_TIMESTAMP
    );

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- 2. Attach the triggers to the sensitive tables.
DROP TRIGGER IF EXISTS trg_applicant_audit ON "Applicant";
CREATE TRIGGER trg_applicant_audit
AFTER INSERT OR UPDATE OR DELETE ON "Applicant"
FOR EACH ROW EXECUTE FUNCTION log_manual_table_edit();

DROP TRIGGER IF EXISTS trg_verification_result_audit ON "VerificationResult";
CREATE TRIGGER trg_verification_result_audit
AFTER INSERT OR UPDATE OR DELETE ON "VerificationResult"
FOR EACH ROW EXECUTE FUNCTION log_manual_table_edit();

DROP TRIGGER IF EXISTS trg_loan_application_audit ON "LoanApplication";
CREATE TRIGGER trg_loan_application_audit
AFTER INSERT OR UPDATE OR DELETE ON "LoanApplication"
FOR EACH ROW EXECUTE FUNCTION log_manual_table_edit();

-- 3. Restrict AuditLog writes to trigger execution only (reads stay open).
REVOKE INSERT, UPDATE, DELETE ON TABLE "AuditLog" FROM PUBLIC;