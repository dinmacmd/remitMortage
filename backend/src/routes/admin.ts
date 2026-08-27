import { Router, Request, Response } from "express";
import { prisma } from "../services/db.js";
import { sendWebhook } from "../services/webhook.js";
import { runEscrowReconciliation } from "../jobs/escrowReconciliation.js";
import logger from "../utils/logger.js";
import { requireAdmin, type AuthenticatedRequest } from "../middleware/auth.js";
import { bulkReviewApplications, type BulkReviewDecision } from "../services/loanStore.js";

export const adminRouter = Router();

/**
 * @openapi
 * /api/admin/loans/bulk-review:
 *   post:
 *     summary: Approve or reject multiple pending loan applications
 *     tags:
 *       - Admin
 *     security:
 *       - bearerAuth: []
 */
adminRouter.post("/loans/bulk-review", requireAdmin, async (req: AuthenticatedRequest, res: Response) => {
  const body = req.body ?? {};
  const rawItems = Array.isArray(body.reviews)
    ? body.reviews
    : Array.isArray(body.applicationIds) && typeof body.decision === "string"
      ? body.applicationIds.map((applicationId: unknown) => ({ applicationId, decision: body.decision, reason: body.reason }))
      : null;

  if (!rawItems || rawItems.length === 0 || rawItems.length > 100) {
    return res.status(400).json({ error: "invalid_request", message: "reviews must contain between 1 and 100 applications" });
  }

  const items = rawItems.map((item: any) => ({
    applicationId: typeof item?.applicationId === "string" ? item.applicationId : item?.id,
    decision: item?.decision,
    reason: item?.reason,
  }));
  if (items.some((item: any) => !item.applicationId || !["approve", "reject"].includes(item.decision))) {
    return res.status(400).json({ error: "invalid_request", message: "Each review requires an applicationId and an approve or reject decision" });
  }

  const reviewerAddress = req.user?.walletAddress;
  if (!reviewerAddress) {
    return res.status(403).json({ error: "forbidden", message: "Reviewer identity is required" });
  }

  try {
    const review = await bulkReviewApplications(
      items as Array<{ applicationId: string; decision: BulkReviewDecision; reason?: string }>,
      reviewerAddress,
      req.ip,
    );
    return res.status(200).json({
      processed: review.results.length,
      failed: review.failures.length,
      results: review.results,
      failures: review.failures,
    });
  } catch (error) {
    logger.error("Bulk loan review error", { error });
    return res.status(500).json({ error: "bulk_review_failed" });
  }
});

// Trigger manual retry of a DLQ job
adminRouter.post("/webhooks/dlq/:id/retry", async (req: Request, res: Response) => {
  const { id } = req.params;

  try {
    const dlqRecord = await prisma.webhookDLQ.findUnique({
      where: { id },
    });

    if (!dlqRecord) {
      res.status(404).json({ error: "DLQ record not found" });
      return;
    }

    const payload = typeof dlqRecord.payload === "string" 
      ? JSON.parse(dlqRecord.payload) 
      : dlqRecord.payload;

    const webhookResult = await sendWebhook(dlqRecord.url, payload);

    if (webhookResult.success) {
      // If success, remove from DLQ
      await prisma.webhookDLQ.delete({
        where: { id },
      });
      res.json({ success: true, message: "Webhook retry succeeded and removed from DLQ" });
    } else {
      // If still fails, update DLQ record with new error/status
      await prisma.webhookDLQ.update({
        where: { id },
        data: {
          statusCode: webhookResult.status,
          responsePayload: webhookResult.responsePayload,
          error: webhookResult.error,
        },
      });
      res.status(500).json({ 
        success: false, 
        error: "Webhook retry failed", 
        details: webhookResult 
      });
    }
  } catch (err: any) {
    logger.error(`[AdminRouter] Failed to retry DLQ ${id}`, { err });
    res.status(500).json({ error: "Internal server error during retry" });
  }
});

/**
 * @openapi
 * /api/admin/escrow/reconcile:
 *   post:
 *     summary: Trigger manual escrow balance reconciliation
 *     description: >-
 *       Ops-only. Fetches current on-chain USDC balances for all borrower
 *       accounts from Horizon, compares them against the Postgres cache, and
 *       overwrites any mismatched cached values with the on-chain truth.
 *       Also clears outstanding mismatch alerts once corrected.
 *     tags:
 *       - Admin
 *     responses:
 *       200:
 *         description: Reconciliation complete. Returns counts of scanned, mismatches, corrected, and errors.
 *       500:
 *         description: Reconciliation job threw an unexpected error.
 */
adminRouter.post("/escrow/reconcile", async (req: Request, res: Response) => {
  try {
    logger.info("[AdminRouter] Manual escrow reconciliation triggered", {
      ip: req.ip,
    });

    // autoCorrect=true: fix cached values and clear the alert
    const result = await runEscrowReconciliation(true);

    res.json({
      success: true,
      scanned: result.scanned,
      mismatches: result.mismatches.length,
      corrected: result.corrected,
      errors: result.errors,
      details: result.mismatches,
    });
  } catch (err: any) {
    logger.error("[AdminRouter] Escrow reconciliation failed", { err });
    res.status(500).json({ error: "Reconciliation job failed", message: err.message });
  }
});
