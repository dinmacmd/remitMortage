import { Router } from "express";
import {
  getProtocolOverview,
  getLoanPerformance,
  getDisbursementProgress,
  getMonthlyVolume,
  getProtocolOverviewFromView,
  getLoanPerformanceFromView,
  getDisbursementProgressFromView,
  getMonthlyVolumeFromView,
} from "../services/analytics.js";
import { getLendingPoolRates } from "../services/soroban.js";
import { feeEstimator } from "../services/feeEstimator.js";
import { cacheMiddleware } from "../middleware/cache.js";
import { loadConfig } from "../config.js";
import { convertUsdTo } from "../services/fx.js";

export const analyticsRouter = Router();

const DEFAULT_VOLUME_MONTHS = 6;
const MAX_VOLUME_MONTHS = 24;

/**
 * @openapi
 * /api/analytics/overview:
 *   get:
 *     summary: Protocol overview metrics
 *     description: >-
 *       Returns aggregate protocol metrics — total value locked (escrow +
 *       lending pool), and counts of borrowers, investors, and loans. Cached
 *       for 60 seconds.
 *     tags:
 *       - Analytics
 *     responses:
 *       200:
 *         description: Protocol summary.
 */
analyticsRouter.get("/overview", cacheMiddleware(60), async (req, res) => {
  try {
    const overview = (await getProtocolOverviewFromView()) ?? getProtocolOverview();
    const currency = (req.query.currency as string) || "USD";

    if (currency !== "USD" && currency !== "USDC") {
      const converted = { ...overview, tvl: { ...overview.tvl } };
      converted.tvl.escrow = (await convertUsdTo(parseFloat(overview.tvl.escrow), currency)).toFixed(2);
      converted.tvl.lendingPool = (await convertUsdTo(parseFloat(overview.tvl.lendingPool), currency)).toFixed(2);
      converted.tvl.total = (await convertUsdTo(parseFloat(overview.tvl.total), currency)).toFixed(2);
      
      // Clearly label converted values
      (converted as any).isConvertedEstimate = true;
      (converted as any).displayCurrency = currency;
      
      return res.json(converted);
    }

    res.json(overview);
  } catch (error) {
    console.error("Analytics overview error:", error);
    res.status(500).json({ error: "Failed to compute protocol overview" });
  }
});

/**
 * @openapi
 * /api/analytics/loans:
 *   get:
 *     summary: Loan performance breakdown
 *     description: >-
 *       Returns active/repaid/defaulted loan counts along with repayment rate,
 *       default rate, and on-time payment percentage. Cached for 60 seconds.
 *     tags:
 *       - Analytics
 *     responses:
 *       200:
 *         description: Loan performance metrics.
 */
analyticsRouter.get("/loans", cacheMiddleware(60), async (_req, res) => {
  try {
    const performance = (await getLoanPerformanceFromView()) ?? getLoanPerformance();
    res.json(performance);
  } catch (error) {
    console.error("Analytics loans error:", error);
    res.status(500).json({ error: "Failed to compute loan performance" });
  }
});

/**
 * @openapi
 * /api/analytics/disbursement:
 *   get:
 *     summary: Disbursement and milestone progress
 *     description: >-
 *       Returns total disbursed, milestones completed vs. pending, and the
 *       average time to complete a milestone. Cached for 60 seconds.
 *     tags:
 *       - Analytics
 *     responses:
 *       200:
 *         description: Disbursement progress metrics.
 */
analyticsRouter.get("/disbursement", cacheMiddleware(60), async (req, res) => {
  try {
    const progress = (await getDisbursementProgressFromView()) ?? getDisbursementProgress();
    const currency = (req.query.currency as string) || "USD";

    if (currency !== "USD" && currency !== "USDC") {
      const converted = { ...progress };
      converted.totalDisbursed = (await convertUsdTo(parseFloat(progress.totalDisbursed), currency)).toFixed(2);
      
      (converted as any).isConvertedEstimate = true;
      (converted as any).displayCurrency = currency;
      
      return res.json(converted);
    }

    res.json(progress);
  } catch (error) {
    console.error("Analytics disbursement error:", error);
    res.status(500).json({ error: "Failed to compute disbursement progress" });
  }
});

/**
 * @openapi
 * /api/analytics/volume:
 *   get:
 *     summary: Monthly volume time-series
 *     description: >-
 *       Returns monthly deposit, repayment, and disbursement volume for the
 *       requested number of months (default 6, max 24). Cached for 60 seconds.
 *     tags:
 *       - Analytics
 *     parameters:
 *       - in: query
 *         name: months
 *         required: false
 *         description: Number of trailing months to return (1-24).
 *         schema:
 *           type: integer
 *           minimum: 1
 *           maximum: 24
 *           default: 6
 *     responses:
 *       200:
 *         description: Monthly volume series, oldest first.
 */
analyticsRouter.get("/volume", cacheMiddleware(60), async (req, res) => {
  try {
    const parsed = parseInt(String(req.query.months ?? ""), 10);
    const months = Number.isFinite(parsed)
      ? Math.min(Math.max(parsed, 1), MAX_VOLUME_MONTHS)
      : DEFAULT_VOLUME_MONTHS;
      
    const volumeData = (await getMonthlyVolumeFromView(months)) ?? getMonthlyVolume(months);
    const currency = (req.query.currency as string) || "USD";

    if (currency !== "USD" && currency !== "USDC") {
      const converted = await Promise.all(volumeData.map(async (month) => {
        return {
          ...month,
          deposits: (await convertUsdTo(parseFloat(month.deposits), currency)).toFixed(2),
          repayments: (await convertUsdTo(parseFloat(month.repayments), currency)).toFixed(2),
          disbursements: (await convertUsdTo(parseFloat(month.disbursements), currency)).toFixed(2),
        };
      }));
      
      return res.json({
        data: converted,
        isConvertedEstimate: true,
        displayCurrency: currency
      });
    }

    res.json(volumeData);
  } catch (error) {
    console.error("Analytics volume error:", error);
    res.status(500).json({ error: "Failed to compute monthly volume" });
  }
});

/**
 * @openapi
 * /api/analytics/pool-rates:
 *   get:
 *     summary: Live lending-pool interest rates
 *     description: >-
 *       Reads the deployed lending-pool contract's on-chain configuration
 *       (the protocol's rate registry) and derives the current senior and
 *       junior tranche APYs from it, rather than a static estimate. Cached
 *       for 60 seconds to limit RPC traffic.
 *     tags:
 *       - Analytics
 *     responses:
 *       200:
 *         description: Live pool/senior/junior APY figures (basis points) and tranche liquidity.
 *       502:
 *         description: Unable to query the lending-pool contract.
 *       503:
 *         description: Lending pool contract is not configured.
 */
analyticsRouter.get("/pool-rates", cacheMiddleware(60), async (_req, res) => {
  const { lendingPoolContractId } = loadConfig();

  if (!lendingPoolContractId) {
    res.status(503).json({
      error: "not_configured",
      message: "LENDING_POOL_CONTRACT_ID is not configured",
    });
    return;
  }

  try {
    const rates = await getLendingPoolRates(lendingPoolContractId);
    res.json(rates);
  } catch (error) {
    console.error("Analytics pool-rates error:", error);
    res.status(502).json({
      error: "on_chain_unavailable",
      message: "Unable to query the lending pool contract. Please retry shortly.",
    });
  }
});

/**
 * @openapi
 * /api/analytics/gas:
 *   get:
 *     summary: Live gas fee recommendations
 *     description: >-
 *       Returns current low, medium, and high fee recommendations (in stroops)
 *       along with the latest ledger sequence and an update timestamp.
 *     tags:
 *       - Analytics
 *     responses:
 *       200:
 *         description: Current gas fee estimates.
 */
analyticsRouter.get("/gas", (_req, res) => {
  try {
    const recommendation = feeEstimator.getRecommendation();
    res.json(recommendation);
  } catch (error) {
    console.error("Analytics gas error:", error);
    res.status(500).json({ error: "Failed to fetch gas recommendations" });
  }
});
