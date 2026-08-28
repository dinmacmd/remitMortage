-- AlterEnum
ALTER TYPE "LoanStatus" ADD VALUE 'Draft';

-- AlterTable
ALTER TABLE "LoanApplication" ADD COLUMN "lastActivityAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE "LoanApplication" ADD COLUMN "draftStaleNotifiedAt" TIMESTAMP(3);

-- CreateIndex
CREATE INDEX "LoanApplication_status_lastActivityAt_idx" ON "LoanApplication"("status", "lastActivityAt");
