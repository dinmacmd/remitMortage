import { StrKey } from "@stellar/stellar-sdk";
import { prisma } from "./db.js";

// lightweight id generator to avoid adding dependencies
function makeId() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2,9)}`;
}

export type LoanStatus =
  | "Pending"
  | "Approved"
  | "Rejected"
  | "Disbursing"
  | "Repaying"
  | "Completed"
  | "MANUAL_REVIEW";

export interface LoanApplication {
  id: string;
  borrowerAddress: string;
  amount: string;
  status: LoanStatus;
  reason?: string;
  createdAt: string;
  updatedAt: string;
}

function mapLoanApplication(record: any): LoanApplication {
  return {
    id: record.id,
    borrowerAddress: record.applicant.stellarAddress,
    amount: record.principal,
    status: record.status,
    reason: record.reason ?? undefined,
    createdAt: record.createdAt.toISOString(),
    updatedAt: record.updatedAt.toISOString(),
  };
}

async function findOrCreateApplicant(stellarAddress: string) {
  return prisma.applicant.upsert({
    where: { stellarAddress },
    update: { deletedAt: null },
    create: { stellarAddress },
  });
}

export async function createApplication(borrowerAddress: string, amount: string) {
  StrKey.decodeEd25519PublicKey(borrowerAddress);

  const applicant = await findOrCreateApplicant(borrowerAddress);
  const id = makeId();

  const record = await prisma.loanApplication.create({
    data: {
      id,
      applicantId: applicant.id,
      principal: amount,
      status: "Pending",
    },
    include: { applicant: true },
  });

  return mapLoanApplication(record);
}

export async function getApplication(id: string) {
  const record = await prisma.loanApplication.findFirst({
    where: { id, deletedAt: null },
    include: { applicant: true },
  });

  return record ? mapLoanApplication(record) : null;
}

export async function getApplicationsByBorrower(address: string) {
  const records = await prisma.loanApplication.findMany({
    where: { deletedAt: null, applicant: { stellarAddress: address, deletedAt: null } },
    include: { applicant: true },
  });

  return records.map(mapLoanApplication);
}

export async function getPendingApplications() {
  const records = await prisma.loanApplication.findMany({
    where: { status: "Pending", deletedAt: null },
    include: { applicant: true },
  });

  return records.map(mapLoanApplication);
}

export async function listApplications() {
  const records = await prisma.loanApplication.findMany({
    where: { deletedAt: null },
    include: { applicant: true },
  });
  return records.map(mapLoanApplication);
}

export async function updateApplication(id: string, patch: Partial<LoanApplication>) {
  const existing = await prisma.loanApplication.findFirst({
    where: { id, deletedAt: null },
  });
  if (!existing) return null;

  if (patch.borrowerAddress) {
    await prisma.applicant.update({
      where: { id: existing.applicantId },
      data: { stellarAddress: patch.borrowerAddress },
    });
  }

  const updateData: {
    principal?: string;
    status?: LoanStatus;
    reason?: string | null;
  } = {};

  if (patch.amount !== undefined) updateData.principal = patch.amount;
  if (patch.status !== undefined) updateData.status = patch.status;
  if (patch.reason !== undefined) updateData.reason = patch.reason ?? null;

  const record = Object.keys(updateData).length
    ? await prisma.loanApplication.update({
        where: { id },
        data: updateData,
        include: { applicant: true },
      })
    : await prisma.loanApplication.findFirst({
        where: { id, deletedAt: null },
        include: { applicant: true },
      });

  return record ? mapLoanApplication(record) : null;
}

export type BulkReviewDecision = "approve" | "reject";

export interface BulkReviewItem {
  applicationId: string;
  decision: BulkReviewDecision;
  reason?: string;
}

export interface BulkReviewResult {
  applicationId: string;
  decision: BulkReviewDecision;
  status: LoanStatus;
}

/**
 * Review applications independently while keeping each state change and its
 * compliance audit event in one database transaction. A rejected item does
 * not roll back successful decisions for other applications in the batch.
 */
export async function bulkReviewApplications(
  items: BulkReviewItem[],
  reviewerAddress: string,
  ipAddress?: string,
) {
  const results: BulkReviewResult[] = [];
  const failures: Array<{ applicationId: string; error: string }> = [];

  for (const item of items) {
    try {
      const result = await prisma.$transaction(async (tx) => {
        const application = await tx.loanApplication.findFirst({
          where: { id: item.applicationId, deletedAt: null },
          include: { applicant: true },
        });

        if (!application) throw new Error("not_found");
        if (application.status !== "Pending") throw new Error("invalid_state");
        if (application.principal <= 0 || application.applicant.deletedAt !== null) {
          throw new Error("ineligible");
        }
        if (application.applicant.verificationStatus === "INELIGIBLE") {
          throw new Error("ineligible");
        }

        const status = item.decision === "approve" ? "Approved" : "Rejected";
        const updated = await tx.loanApplication.update({
          where: { id: item.applicationId },
          data: { status, statusUpdatedAt: new Date() },
          include: { applicant: true },
        });

        await tx.auditLog.create({
          data: {
            action: `loan_application.bulk_${item.decision}d`,
            actorAddress: reviewerAddress,
            ipAddress,
            metadata: {
              applicationId: item.applicationId,
              previousStatus: application.status,
              newStatus: status,
              decision: item.decision,
              reason: item.reason ?? null,
              reviewedAt: new Date().toISOString(),
            },
          },
        });

        return { applicationId: updated.id, decision: item.decision, status };
      });
      results.push(result);
    } catch (error) {
      const message = error instanceof Error ? error.message : "review_failed";
      failures.push({ applicationId: item.applicationId, error: message });
    }
  }

  return { results, failures };
}

// Simple escrow check: for demo purposes consider escrow "met" when requested amount is <= 5000
export function escrowTargetMetForAmount(amount: string) {
  const num = Number(amount);
  if (Number.isNaN(num) || num <= 0) return false;
  return num <= 5000;
}
