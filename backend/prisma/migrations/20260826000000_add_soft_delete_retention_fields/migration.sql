ALTER TABLE "Applicant" ADD COLUMN "deletedAt" TIMESTAMP(3);
ALTER TABLE "LoanApplication" ADD COLUMN "deletedAt" TIMESTAMP(3);
ALTER TABLE "Borrower" ADD COLUMN "deletedAt" TIMESTAMP(3);

CREATE INDEX "Applicant_deletedAt_idx" ON "Applicant"("deletedAt");
CREATE INDEX "LoanApplication_deletedAt_idx" ON "LoanApplication"("deletedAt");
CREATE INDEX "Borrower_deletedAt_idx" ON "Borrower"("deletedAt");
