-- CreateSchema
CREATE SCHEMA IF NOT EXISTS "public";

-- CreateEnum
CREATE TYPE "NotificationStatus" AS ENUM ('Pending', 'Sent', 'Failed');

-- CreateEnum
CREATE TYPE "LoanStatus" AS ENUM ('Pending', 'Approved', 'Rejected', 'Disbursing', 'Repaying', 'Completed');

-- CreateEnum
CREATE TYPE "VerificationStatus" AS ENUM ('PENDING', 'ELIGIBLE', 'INELIGIBLE');

-- CreateEnum
CREATE TYPE "WorkspaceRole" AS ENUM ('OWNER', 'BUILDER', 'VIEWER');

-- CreateEnum
CREATE TYPE "WorkspaceInvitationStatus" AS ENUM ('PENDING', 'ACCEPTED', 'REJECTED', 'EXPIRED');

-- CreateEnum
CREATE TYPE "DataDeletionStatus" AS ENUM ('PENDING', 'APPROVED', 'COMPLETED', 'REJECTED');

-- CreateEnum
CREATE TYPE "WebhookEventTopic" AS ENUM ('deposit', 'withdraw', 'release', 'disburse', 'repay', 'all');

-- CreateEnum
CREATE TYPE "WebhookSubscriptionStatus" AS ENUM ('active', 'paused', 'revoked');

-- CreateTable
CREATE TABLE "Notification" (
    "id" TEXT NOT NULL,
    "recipient" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "content" TEXT NOT NULL,
    "status" "NotificationStatus" NOT NULL DEFAULT 'Pending',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,
    "attempts" INTEGER NOT NULL DEFAULT 0,
    "lastError" TEXT,
    "nextRetryAt" TIMESTAMP(3),

    CONSTRAINT "Notification_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "InAppNotification" (
    "id" TEXT NOT NULL,
    "walletAddress" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "message" TEXT,
    "variant" TEXT NOT NULL DEFAULT 'info',
    "read" BOOLEAN NOT NULL DEFAULT false,
    "metadata" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "InAppNotification_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "UnpinnedCid" (
    "id" TEXT NOT NULL,
    "cid" TEXT NOT NULL,
    "proposalId" TEXT,
    "success" BOOLEAN NOT NULL,
    "pinataStatus" INTEGER,
    "error" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "UnpinnedCid_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "KycDocument" (
    "id" TEXT NOT NULL,
    "applicantId" TEXT NOT NULL,
    "documentId" TEXT NOT NULL,
    "originalName" TEXT NOT NULL,
    "mimeType" TEXT NOT NULL,
    "uploadedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expiresAt" TIMESTAMP(3),
    "reminderSent30d" BOOLEAN NOT NULL DEFAULT false,
    "reminderSent7d" BOOLEAN NOT NULL DEFAULT false,
    "expired" BOOLEAN NOT NULL DEFAULT false,

    CONSTRAINT "KycDocument_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Workspace" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "slug" TEXT NOT NULL,
    "createdBy" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Workspace_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "WorkspaceMember" (
    "id" TEXT NOT NULL,
    "workspaceId" TEXT NOT NULL,
    "walletAddress" TEXT NOT NULL,
    "role" "WorkspaceRole" NOT NULL DEFAULT 'VIEWER',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "WorkspaceMember_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "WorkspaceInvitation" (
    "id" TEXT NOT NULL,
    "workspaceId" TEXT NOT NULL,
    "inviteeAddress" TEXT NOT NULL,
    "invitedBy" TEXT NOT NULL,
    "role" "WorkspaceRole" NOT NULL DEFAULT 'VIEWER',
    "status" "WorkspaceInvitationStatus" NOT NULL DEFAULT 'PENDING',
    "expiresAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "WorkspaceInvitation_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Applicant" (
    "id" TEXT NOT NULL,
    "stellarAddress" TEXT NOT NULL,
    "verificationStatus" "VerificationStatus" NOT NULL DEFAULT 'PENDING',
    "creditScore" INTEGER,
    "taxId" TEXT,
    "monthlyIncome" TEXT,
    "displayCurrency" TEXT NOT NULL DEFAULT 'USD',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Applicant_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "VerificationResult" (
    "id" TEXT NOT NULL,
    "applicantId" TEXT NOT NULL,
    "reportHash" TEXT NOT NULL,
    "totalPayments" INTEGER NOT NULL,
    "totalVolume" DOUBLE PRECISION NOT NULL,
    "spanMonths" DOUBLE PRECISION NOT NULL,
    "eligible" BOOLEAN NOT NULL,
    "analyzedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "VerificationResult_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "LoanApplication" (
    "id" TEXT NOT NULL,
    "applicantId" TEXT NOT NULL,
    "escrowContractId" TEXT,
    "loanId" TEXT,
    "principal" DOUBLE PRECISION NOT NULL,
    "interestRateBps" INTEGER NOT NULL DEFAULT 800,
    "status" "LoanStatus" NOT NULL DEFAULT 'Pending',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "dueDate" TIMESTAMP(3),
    "missedPayments" INTEGER NOT NULL DEFAULT 0,
    "lateFeeBalance" DOUBLE PRECISION NOT NULL DEFAULT 0,
    "gracePeriodEndsAt" TIMESTAMP(3),
    "assignedReviewerEmail" TEXT,
    "statusUpdatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "slaAlertSentAt" TIMESTAMP(3),

    CONSTRAINT "LoanApplication_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "AuditLog" (
    "id" TEXT NOT NULL,
    "action" TEXT NOT NULL,
    "actorAddress" TEXT,
    "ipAddress" TEXT,
    "metadata" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "AuditLog_pkey" PRIMARY KEY ("id","createdAt")
);

-- CreateTable
CREATE TABLE "Borrower" (
    "id" TEXT NOT NULL,
    "stellarAddress" TEXT NOT NULL,
    "escrowBalance" TEXT NOT NULL DEFAULT '0',
    "loanOutstanding" TEXT NOT NULL DEFAULT '0',
    "totalDeposited" TEXT NOT NULL DEFAULT '0',
    "totalDisbursed" TEXT NOT NULL DEFAULT '0',
    "totalRepaid" TEXT NOT NULL DEFAULT '0',
    "lastEventLedger" INTEGER NOT NULL DEFAULT 0,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Borrower_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "EscrowDeposit" (
    "id" TEXT NOT NULL,
    "borrowerId" TEXT NOT NULL,
    "contractId" TEXT NOT NULL,
    "amount" TEXT NOT NULL,
    "ledger" INTEGER NOT NULL,
    "eventHash" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "EscrowDeposit_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "EscrowWithdrawal" (
    "id" TEXT NOT NULL,
    "borrowerId" TEXT NOT NULL,
    "contractId" TEXT NOT NULL,
    "amount" TEXT NOT NULL,
    "ledger" INTEGER NOT NULL,
    "eventHash" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "EscrowWithdrawal_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "LoanDisbursement" (
    "id" TEXT NOT NULL,
    "borrowerId" TEXT NOT NULL,
    "contractId" TEXT NOT NULL,
    "amount" TEXT NOT NULL,
    "ledger" INTEGER NOT NULL,
    "eventHash" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "LoanDisbursement_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "LoanRepayment" (
    "id" TEXT NOT NULL,
    "borrowerId" TEXT NOT NULL,
    "contractId" TEXT NOT NULL,
    "amount" TEXT NOT NULL,
    "ledger" INTEGER NOT NULL,
    "eventHash" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "LoanRepayment_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "EventIndexerState" (
    "id" TEXT NOT NULL,
    "key" TEXT NOT NULL,
    "lastProcessedLedger" INTEGER NOT NULL DEFAULT 0,
    "cursor" TEXT,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "EventIndexerState_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "DataDeletionRequest" (
    "id" TEXT NOT NULL,
    "walletAddress" TEXT NOT NULL,
    "status" "DataDeletionStatus" NOT NULL DEFAULT 'PENDING',
    "reason" TEXT,
    "requestedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "processedAt" TIMESTAMP(3),
    "anonymizedAt" TIMESTAMP(3),
    "details" JSONB,

    CONSTRAINT "DataDeletionRequest_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "BorrowerCredential" (
    "id" TEXT NOT NULL,
    "applicantId" TEXT NOT NULL,
    "did" TEXT NOT NULL,
    "didHash" TEXT NOT NULL,
    "verificationMethod" TEXT NOT NULL,
    "challenge" TEXT,
    "issuer" TEXT,
    "verifiedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expiresAt" TIMESTAMP(3),
    "revokedAt" TIMESTAMP(3),
    "isRevoked" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "BorrowerCredential_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "WebhookDLQ" (
    "id" TEXT NOT NULL,
    "url" TEXT NOT NULL,
    "payload" JSONB NOT NULL,
    "statusCode" INTEGER,
    "responsePayload" TEXT,
    "error" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "WebhookDLQ_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "WebhookSubscription" (
    "id" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    "url" TEXT NOT NULL,
    "secret" TEXT NOT NULL,
    "previousSecret" TEXT,
    "previousSecretExpiresAt" TIMESTAMP(3),
    "secretRotatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "topics" "WebhookEventTopic"[],
    "status" "WebhookSubscriptionStatus" NOT NULL DEFAULT 'active',
    "ownerAddress" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "WebhookSubscription_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "WebhookDelivery" (
    "id" TEXT NOT NULL,
    "subscriptionId" TEXT NOT NULL,
    "topic" TEXT NOT NULL,
    "payload" JSONB NOT NULL,
    "statusCode" INTEGER,
    "responseBody" TEXT,
    "error" TEXT,
    "success" BOOLEAN NOT NULL DEFAULT false,
    "attempt" INTEGER NOT NULL DEFAULT 0,
    "nextRetryAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "WebhookDelivery_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ApiKey" (
    "id" TEXT NOT NULL,
    "key" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "scopes" TEXT[],
    "revoked" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "ApiKey_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "NotificationPreference" (
    "id" TEXT NOT NULL,
    "applicantId" TEXT NOT NULL,
    "email" TEXT,
    "phone" TEXT,
    "emailAlerts" BOOLEAN NOT NULL DEFAULT true,
    "smsAlerts" BOOLEAN NOT NULL DEFAULT false,
    "escrowApproaching" BOOLEAN NOT NULL DEFAULT true,
    "escrowReached" BOOLEAN NOT NULL DEFAULT true,
    "paymentMissed" BOOLEAN NOT NULL DEFAULT true,
    "loanMilestones" BOOLEAN NOT NULL DEFAULT true,
    "webhookUrl" TEXT,
    "timezone" TEXT NOT NULL DEFAULT 'UTC',
    "businessDays" TEXT NOT NULL DEFAULT '1,2,3,4,5',
    "startHour" TEXT NOT NULL DEFAULT '09:00',
    "endHour" TEXT NOT NULL DEFAULT '17:00',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "NotificationPreference_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "SessionToken" (
    "id" TEXT NOT NULL,
    "tokenHash" TEXT NOT NULL,
    "walletAddress" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "revokedAt" TIMESTAMP(3),
    "lastUsedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "SessionToken_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "Notification_status_idx" ON "Notification"("status");

-- CreateIndex
CREATE INDEX "Notification_status_nextRetryAt_idx" ON "Notification"("status", "nextRetryAt");

-- CreateIndex
CREATE INDEX "InAppNotification_walletAddress_createdAt_idx" ON "InAppNotification"("walletAddress", "createdAt" DESC);

-- CreateIndex
CREATE INDEX "InAppNotification_walletAddress_read_idx" ON "InAppNotification"("walletAddress", "read");

-- CreateIndex
CREATE UNIQUE INDEX "KycDocument_documentId_key" ON "KycDocument"("documentId");

-- CreateIndex
CREATE INDEX "KycDocument_applicantId_idx" ON "KycDocument"("applicantId");

-- CreateIndex
CREATE INDEX "KycDocument_expiresAt_idx" ON "KycDocument"("expiresAt");

-- CreateIndex
CREATE INDEX "KycDocument_expired_idx" ON "KycDocument"("expired");

-- CreateIndex
CREATE UNIQUE INDEX "Workspace_slug_key" ON "Workspace"("slug");

-- CreateIndex
CREATE INDEX "WorkspaceMember_walletAddress_idx" ON "WorkspaceMember"("walletAddress");

-- CreateIndex
CREATE UNIQUE INDEX "WorkspaceMember_workspaceId_walletAddress_key" ON "WorkspaceMember"("workspaceId", "walletAddress");

-- CreateIndex
CREATE INDEX "WorkspaceInvitation_inviteeAddress_idx" ON "WorkspaceInvitation"("inviteeAddress");

-- CreateIndex
CREATE INDEX "WorkspaceInvitation_status_idx" ON "WorkspaceInvitation"("status");

-- CreateIndex
CREATE UNIQUE INDEX "Applicant_stellarAddress_key" ON "Applicant"("stellarAddress");

-- CreateIndex
CREATE INDEX "VerificationResult_applicantId_analyzedAt_idx" ON "VerificationResult"("applicantId", "analyzedAt");

-- CreateIndex
CREATE INDEX "VerificationResult_eligible_idx" ON "VerificationResult"("eligible");

-- CreateIndex
CREATE INDEX "LoanApplication_applicantId_createdAt_idx" ON "LoanApplication"("applicantId", "createdAt");

-- CreateIndex
CREATE INDEX "LoanApplication_status_idx" ON "LoanApplication"("status");

-- CreateIndex
CREATE INDEX "LoanApplication_applicantId_status_idx" ON "LoanApplication"("applicantId", "status");

-- CreateIndex
CREATE INDEX "LoanApplication_status_createdAt_idx" ON "LoanApplication"("status", "createdAt");

-- CreateIndex
CREATE INDEX "AuditLog_action_idx" ON "AuditLog"("action");

-- CreateIndex
CREATE INDEX "AuditLog_actorAddress_idx" ON "AuditLog"("actorAddress");

-- CreateIndex
CREATE INDEX "AuditLog_createdAt_idx" ON "AuditLog"("createdAt");

-- CreateIndex
CREATE INDEX "AuditLog_action_createdAt_idx" ON "AuditLog"("action", "createdAt");

-- CreateIndex
CREATE UNIQUE INDEX "Borrower_stellarAddress_key" ON "Borrower"("stellarAddress");

-- CreateIndex
CREATE UNIQUE INDEX "EscrowDeposit_eventHash_key" ON "EscrowDeposit"("eventHash");

-- CreateIndex
CREATE INDEX "EscrowDeposit_borrowerId_idx" ON "EscrowDeposit"("borrowerId");

-- CreateIndex
CREATE INDEX "EscrowDeposit_ledger_idx" ON "EscrowDeposit"("ledger");

-- CreateIndex
CREATE UNIQUE INDEX "EscrowWithdrawal_eventHash_key" ON "EscrowWithdrawal"("eventHash");

-- CreateIndex
CREATE INDEX "EscrowWithdrawal_borrowerId_idx" ON "EscrowWithdrawal"("borrowerId");

-- CreateIndex
CREATE INDEX "EscrowWithdrawal_ledger_idx" ON "EscrowWithdrawal"("ledger");

-- CreateIndex
CREATE UNIQUE INDEX "LoanDisbursement_eventHash_key" ON "LoanDisbursement"("eventHash");

-- CreateIndex
CREATE INDEX "LoanDisbursement_borrowerId_idx" ON "LoanDisbursement"("borrowerId");

-- CreateIndex
CREATE INDEX "LoanDisbursement_ledger_idx" ON "LoanDisbursement"("ledger");

-- CreateIndex
CREATE UNIQUE INDEX "LoanRepayment_eventHash_key" ON "LoanRepayment"("eventHash");

-- CreateIndex
CREATE INDEX "LoanRepayment_borrowerId_idx" ON "LoanRepayment"("borrowerId");

-- CreateIndex
CREATE INDEX "LoanRepayment_ledger_idx" ON "LoanRepayment"("ledger");

-- CreateIndex
CREATE UNIQUE INDEX "EventIndexerState_key_key" ON "EventIndexerState"("key");

-- CreateIndex
CREATE INDEX "DataDeletionRequest_walletAddress_idx" ON "DataDeletionRequest"("walletAddress");

-- CreateIndex
CREATE INDEX "DataDeletionRequest_status_idx" ON "DataDeletionRequest"("status");

-- CreateIndex
CREATE UNIQUE INDEX "BorrowerCredential_did_key" ON "BorrowerCredential"("did");

-- CreateIndex
CREATE UNIQUE INDEX "BorrowerCredential_didHash_key" ON "BorrowerCredential"("didHash");

-- CreateIndex
CREATE INDEX "BorrowerCredential_applicantId_idx" ON "BorrowerCredential"("applicantId");

-- CreateIndex
CREATE INDEX "BorrowerCredential_did_idx" ON "BorrowerCredential"("did");

-- CreateIndex
CREATE INDEX "WebhookSubscription_status_idx" ON "WebhookSubscription"("status");

-- CreateIndex
CREATE INDEX "WebhookSubscription_ownerAddress_idx" ON "WebhookSubscription"("ownerAddress");

-- CreateIndex
CREATE INDEX "WebhookSubscription_secretRotatedAt_idx" ON "WebhookSubscription"("secretRotatedAt");

-- CreateIndex
CREATE INDEX "WebhookDelivery_subscriptionId_idx" ON "WebhookDelivery"("subscriptionId");

-- CreateIndex
CREATE INDEX "WebhookDelivery_success_idx" ON "WebhookDelivery"("success");

-- CreateIndex
CREATE INDEX "WebhookDelivery_nextRetryAt_idx" ON "WebhookDelivery"("nextRetryAt");

-- CreateIndex
CREATE UNIQUE INDEX "ApiKey_key_key" ON "ApiKey"("key");

-- CreateIndex
CREATE INDEX "ApiKey_key_idx" ON "ApiKey"("key");

-- CreateIndex
CREATE INDEX "ApiKey_revoked_idx" ON "ApiKey"("revoked");

-- CreateIndex
CREATE UNIQUE INDEX "NotificationPreference_applicantId_key" ON "NotificationPreference"("applicantId");

-- CreateIndex
CREATE INDEX "NotificationPreference_applicantId_idx" ON "NotificationPreference"("applicantId");

-- CreateIndex
CREATE UNIQUE INDEX "SessionToken_tokenHash_key" ON "SessionToken"("tokenHash");

-- CreateIndex
CREATE INDEX "SessionToken_walletAddress_idx" ON "SessionToken"("walletAddress");

-- CreateIndex
CREATE INDEX "SessionToken_expiresAt_idx" ON "SessionToken"("expiresAt");

-- CreateIndex
CREATE INDEX "SessionToken_createdAt_idx" ON "SessionToken"("createdAt");

-- AddForeignKey
ALTER TABLE "KycDocument" ADD CONSTRAINT "KycDocument_applicantId_fkey" FOREIGN KEY ("applicantId") REFERENCES "Applicant"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "WorkspaceMember" ADD CONSTRAINT "WorkspaceMember_workspaceId_fkey" FOREIGN KEY ("workspaceId") REFERENCES "Workspace"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "WorkspaceInvitation" ADD CONSTRAINT "WorkspaceInvitation_workspaceId_fkey" FOREIGN KEY ("workspaceId") REFERENCES "Workspace"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "VerificationResult" ADD CONSTRAINT "VerificationResult_applicantId_fkey" FOREIGN KEY ("applicantId") REFERENCES "Applicant"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "LoanApplication" ADD CONSTRAINT "LoanApplication_applicantId_fkey" FOREIGN KEY ("applicantId") REFERENCES "Applicant"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "EscrowDeposit" ADD CONSTRAINT "EscrowDeposit_borrowerId_fkey" FOREIGN KEY ("borrowerId") REFERENCES "Borrower"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "EscrowWithdrawal" ADD CONSTRAINT "EscrowWithdrawal_borrowerId_fkey" FOREIGN KEY ("borrowerId") REFERENCES "Borrower"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "LoanDisbursement" ADD CONSTRAINT "LoanDisbursement_borrowerId_fkey" FOREIGN KEY ("borrowerId") REFERENCES "Borrower"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "LoanRepayment" ADD CONSTRAINT "LoanRepayment_borrowerId_fkey" FOREIGN KEY ("borrowerId") REFERENCES "Borrower"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "BorrowerCredential" ADD CONSTRAINT "BorrowerCredential_applicantId_fkey" FOREIGN KEY ("applicantId") REFERENCES "Applicant"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "WebhookDelivery" ADD CONSTRAINT "WebhookDelivery_subscriptionId_fkey" FOREIGN KEY ("subscriptionId") REFERENCES "WebhookSubscription"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "NotificationPreference" ADD CONSTRAINT "NotificationPreference_applicantId_fkey" FOREIGN KEY ("applicantId") REFERENCES "Applicant"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

