-- Materialized View for Precomputed Protocol-Wide Analytics Aggregates
-- Speeds up the protocol statistics dashboard by precomputing expensive
-- aggregate queries (TVL, active loans, default rates) instead of computing
-- them on every request.

-- ── Materialized View: protocol_analytics ────────────────────────────────────
-- Aggregates key protocol metrics from the underlying transactional tables.
-- Refreshed every 5 minutes via REFRESH MATERIALIZED VIEW CONCURRENTLY.

CREATE MATERIALIZED VIEW IF NOT EXISTS protocol_analytics AS
WITH
  -- Total escrow balance across all borrowers
  escrow_totals AS (
    SELECT COALESCE(SUM("escrowBalance"::numeric), 0) AS total_escrow
    FROM "Borrower"
    WHERE "deletedAt" IS NULL
  ),
  -- Total outstanding loan principal
  loan_outstanding_totals AS (
    SELECT COALESCE(SUM("loanOutstanding"::numeric), 0) AS total_lending_pool
    FROM "Borrower"
    WHERE "deletedAt" IS NULL
  ),
  -- Loan status counts
  loan_counts AS (
    SELECT
      COUNT(*) AS total_loans,
      COUNT(*) FILTER (WHERE status IN ('Approved', 'Disbursing', 'Repaying')) AS active_loans,
      COUNT(*) FILTER (WHERE status = 'Completed') AS repaid_loans,
      COUNT(*) FILTER (WHERE status = 'Rejected') AS rejected_loans
    FROM "LoanApplication"
    WHERE "deletedAt" IS NULL
  ),
  -- Unique borrower count
  borrower_counts AS (
    SELECT COUNT(DISTINCT "stellarAddress") AS total_borrowers
    FROM "Borrower"
    WHERE "deletedAt" IS NULL
  ),
  -- Milestone counts
  milestone_counts AS (
    SELECT
      COUNT(*) AS total_milestones,
      COUNT(*) FILTER (WHERE status = 'Passed') AS milestones_completed,
      COUNT(*) FILTER (WHERE status = 'Open') AS milestones_pending
    FROM "MilestoneProposal"
  ),
  -- Monthly deposit volume (last 12 months)
  monthly_deposits AS (
    SELECT
      TO_CHAR("createdAt", 'YYYY-MM') AS month,
      COALESCE(SUM("amount"::numeric), 0) AS deposits
    FROM "EscrowDeposit"
    WHERE "createdAt" >= NOW() - INTERVAL '12 months'
    GROUP BY TO_CHAR("createdAt", 'YYYY-MM')
  ),
  -- Monthly repayment volume (last 12 months)
  monthly_repayments AS (
    SELECT
      TO_CHAR("createdAt", 'YYYY-MM') AS month,
      COALESCE(SUM("amount"::numeric), 0) AS repayments
    FROM "LoanRepayment"
    WHERE "createdAt" >= NOW() - INTERVAL '12 months'
    GROUP BY TO_CHAR("createdAt", 'YYYY-MM')
  ),
  -- Monthly disbursement volume (last 12 months)
  monthly_disbursements AS (
    SELECT
      TO_CHAR("createdAt", 'YYYY-MM') AS month,
      COALESCE(SUM("amount"::numeric), 0) AS disbursements
    FROM "LoanDisbursement"
    WHERE "createdAt" >= NOW() - INTERVAL '12 months'
    GROUP BY TO_CHAR("createdAt", 'YYYY-MM')
  )
SELECT
  -- TVL metrics
  (SELECT total_escrow FROM escrow_totals) AS total_escrow,
  (SELECT total_lending_pool FROM loan_outstanding_totals) AS total_lending_pool,
  (SELECT total_escrow + total_lending_pool FROM escrow_totals, loan_outstanding_totals) AS total_tvl,
  -- Counts
  (SELECT total_loans FROM loan_counts) AS total_loans,
  (SELECT active_loans FROM loan_counts) AS active_loans,
  (SELECT repaid_loans FROM loan_counts) AS repaid_loans,
  (SELECT rejected_loans FROM loan_counts) AS rejected_loans,
  (SELECT total_borrowers FROM borrower_counts) AS total_borrowers,
  -- Milestones
  (SELECT total_milestones FROM milestone_counts) AS total_milestones,
  (SELECT milestones_completed FROM milestone_counts) AS milestones_completed,
  (SELECT milestones_pending FROM milestone_counts) AS milestones_pending,
  -- Timestamps
  NOW() AS refreshed_at
WITH NO DATA;

-- Unique index required for CONCURRENTLY refresh
CREATE UNIQUE INDEX IF NOT EXISTS idx_protocol_analytics_refreshed_at
  ON protocol_analytics (refreshed_at);

-- ── Materialized View: monthly_volume_series ─────────────────────────────────
-- Precomputed monthly volume time-series for the analytics dashboard.

CREATE MATERIALIZED VIEW IF NOT EXISTS monthly_volume_series AS
WITH months AS (
  SELECT TO_CHAR(d, 'YYYY-MM') AS month
  FROM generate_series(
    DATE_TRUNC('month', NOW() - INTERVAL '11 months'),
    DATE_TRUNC('month', NOW()),
    INTERVAL '1 month'
  ) AS d
)
SELECT
  m.month,
  COALESCE(d.deposits, 0) AS deposits,
  COALESCE(r.repayments, 0) AS repayments,
  COALESCE(dis.disbursements, 0) AS disbursements
FROM months m
LEFT JOIN (
  SELECT TO_CHAR("createdAt", 'YYYY-MM') AS month, SUM("amount"::numeric) AS deposits
  FROM "EscrowDeposit"
  WHERE "createdAt" >= NOW() - INTERVAL '12 months'
  GROUP BY TO_CHAR("createdAt", 'YYYY-MM')
) d ON d.month = m.month
LEFT JOIN (
  SELECT TO_CHAR("createdAt", 'YYYY-MM') AS month, SUM("amount"::numeric) AS repayments
  FROM "LoanRepayment"
  WHERE "createdAt" >= NOW() - INTERVAL '12 months'
  GROUP BY TO_CHAR("createdAt", 'YYYY-MM')
) r ON r.month = m.month
LEFT JOIN (
  SELECT TO_CHAR("createdAt", 'YYYY-MM') AS month, SUM("amount"::numeric) AS disbursements
  FROM "LoanDisbursement"
  WHERE "createdAt" >= NOW() - INTERVAL '12 months'
  GROUP BY TO_CHAR("createdAt", 'YYYY-MM')
) dis ON dis.month = m.month
ORDER BY m.month ASC
WITH NO DATA;

CREATE UNIQUE INDEX IF NOT EXISTS idx_monthly_volume_series_month
  ON monthly_volume_series (month);
