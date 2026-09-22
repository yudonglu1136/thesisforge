import express from "express";
import { dataReleaseMiddleware,dataReleaseStatus } from './dataReleaseContext.js';
import { queryFacts } from './factRepository.js';
import { enableInvestmentPreview } from './investmentRoutes.js';
import cors from "cors";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  loadGuruDashboard,
  loadGuruExposureHistory,
  loadGuruMarketContext
} from "./secClient.js";
import { loadOperationCommentary } from "./commentarySearch.js";
import { gurus } from "./gurus.js";
import { registerRetiredProductRoutes } from "./retiredProductRoutes.js";
import { clearPortfolioCache, loadPortfolioDashboard, startPortfolioNavRecorder } from "./portfolioClient.js";
import { portfolioResponsePrivacy, respondPortfolioBusy } from "./portfolioHttp.js";
import { portfolioSyncResult } from "./portfolioSyncResult.js";
import { registerAdminPortfolioUsersRoute } from "./adminPortfolioUsersRoute.js";
import { requireAuth } from "./auth/requireAuth.js";
import { ADMIN_OWNER_EMAIL, adminResponsePrivacy, requireAdmin } from "./auth/requireAdmin.js";
import { recordLoginActivity, registerLoginActivityRoutes } from "./loginActivityRoutes.js";
import {
  backtestEndGraceDays,
  guruBacktestRefreshStatus,
  loadGuruBacktest,
  loadGuruBacktests,
  manager13fBacktestMethodVersion,
  manager13fProxyMethodVersion,
  manager13fSecurityMasterVersion,
  publicBacktestRequestPolicy,
  refreshGuruBacktestCache,
  startGuruBacktestRefresher
} from "./backtest.js";
import { loadValuationDashboard, loadValuationTicker } from "./valuationClient.js";
import { createValuationTickerHandler } from "./valuationHttp.js";
import { importValuationTicker } from "./valuationImporter.js";
import { translateTextsToChinese } from "./translationClient.js";
import {
  databaseInfo,
  readBackgroundJobRun,
  readPriceSeriesFromDb,
  writeAuditedPriceSeriesImport,
  writeAuditedPriceSeriesImportBatch,
  writeAuditedPriceRepair,
  writeBackgroundJobRun
} from "./localDatabase.js";
import { requireInternalCron, requireLoopbackRequest } from "./internalCronAuth.js";
import { registerAuditedPriceSeriesImportRoute } from "./auditedPriceSeriesImportRoute.js";
import { registerGuruPriceRepairRoute } from "./guruPriceRepairRoute.js";
import { startThirteenFRefresh } from "./refreshThirteenF.js";
import { loadTickerLogo } from "./logoClient.js";
import {
  refreshDividendCalendarForTickers,
  startDividendCalendarRefresher
} from "./dividendClient.js";
import { buildAdminSystemHealth } from "./systemHealth.js";
import { createPublicHealthService } from "./publicHealthService.js";
import { createPublicHealthWorkerBuilder } from "./publicHealthWorkerRunner.js";
import { installJsonTransport } from "./jsonTransport.js";
import {
  addPortfolioAccount,
  deletePortfolioConnection,
  portfolioUserForAdminHash,
  readPortfolioConnectionStatus,
  recordPortfolioUser,
  restorePortfolioConnection,
  savePortfolioConnection
} from "./userPortfolioStore.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, "..");
const app = express();
const port = Number(process.env.PORT || 8787);
const publicHealthWorker = createPublicHealthWorkerBuilder({
  databasePath: databaseInfo().path,
  methodIdentity: {
    backtestEndGraceDays,
    manager13fBacktestMethodVersion,
    manager13fProxyMethodVersion,
    manager13fSecurityMasterVersion
  }
});
const publicHealthService = createPublicHealthService({
  buildHealth: publicHealthWorker.buildHealth
});

const defaultAllowedOrigins = [
  "http://localhost:5173",
  "http://127.0.0.1:5173",
  "http://localhost:5174",
  "http://127.0.0.1:5174"
];
const allowedOrigins = String(process.env.API_ALLOWED_ORIGINS || defaultAllowedOrigins.join(","))
  .split(",")
  .map((origin) => origin.trim())
  .filter(Boolean);

app.use("/api/portfolio", portfolioResponsePrivacy);
app.use("/api/investment", portfolioResponsePrivacy);
app.use(cors({
  origin(origin, callback) {
    const isLocalDevOrigin =
      process.env.NODE_ENV !== "production" &&
      /^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(origin || "");
    if (!origin || allowedOrigins.includes(origin) || isLocalDevOrigin) {
      callback(null, true);
      return;
    }
    callback(new Error("Origin is not allowed"));
  },
  methods: ["GET", "POST", "DELETE", "OPTIONS"],
  allowedHeaders: ["authorization", "content-type", "if-none-match"]
}));
installJsonTransport(app);
app.use('/api',dataReleaseMiddleware);
app.get('/api/internal/data-release',requireLoopbackRequest,requireInternalCron,async (_request,response)=>{
  try {
    const release=dataReleaseStatus();
    if(!release)return response.status(503).json({error:'data_release_not_activated'});
    const coverage=await queryFacts('get_coverage');
    response.json({status:'verified',releaseId:release.releaseId,groups:release.groups,coverage});
  }catch{return response.status(503).json({error:'data_release_probe_failed'});}
});
registerRetiredProductRoutes(app);
registerGuruPriceRepairRoute(app, {
  requireInternalCron,
  requireLoopbackRequest,
  gurus,
  readPriceSeriesFromDb,
  writeAuditedPriceSeriesImportBatch,
  loadGuruBacktest,
  strictMethodVersion: manager13fBacktestMethodVersion,
  proxyMethodVersion: manager13fProxyMethodVersion,
  securityMasterVersion: manager13fSecurityMasterVersion
});
registerAuditedPriceSeriesImportRoute(app, {
  requireInternalCron,
  requireLoopbackRequest,
  gurus,
  writeAuditedPriceSeriesImport,
  loadGuruBacktest
});
// Keep the larger parser scoped to the audited series route above. Every other
// JSON endpoint retains Express's conservative default request-size limit.
app.use(express.json());

const avatarAssetDir = fs.existsSync(path.join(rootDir, "dist", "guru-avatars"))
  ? path.join(rootDir, "dist", "guru-avatars")
  : path.join(rootDir, "web", "guru-avatars");
if (fs.existsSync(avatarAssetDir)) {
  app.use("/guru-avatars", express.static(avatarAssetDir, {
    immutable: true,
    maxAge: "30d"
  }));
}

app.get("/api/health", async (_request, response) => {
  const health = await publicHealthService.read();
  response.setHeader("Cache-Control", "no-store");
  response.status(health.ok ? 200 : 503).json(health);
});

app.get("/api/logo/:ticker", async (request, response) => {
  try {
    const asset = await loadTickerLogo(request.params.ticker);
    response.setHeader("Content-Type", asset.contentType);
    response.setHeader("Cache-Control", "public, max-age=86400");
    response.setHeader("X-Logo-Source", asset.source || "unknown");
    response.send(asset.body);
  } catch {
    response.setHeader("Cache-Control", "public, max-age=300");
    response.status(404).json({ error: "logo_not_found" });
  }
});

app.get("/api/internal/backtests/status", requireLoopbackRequest, requireInternalCron, (_request, response) => {
  response.json(guruBacktestRefreshStatus());
});

app.post("/api/internal/backtests/refresh", requireLoopbackRequest, requireInternalCron, async (request, response) => {
  try {
    const refreshGeneration = String(
      request.query.refreshGeneration || request.body?.refreshGeneration || ""
    ).trim();
    const payload = await refreshGuruBacktestCache({
      years: request.query.years || request.body?.years || 5,
      detail: request.query.detail || request.body?.detail || "compact",
      reason: "internal-api",
      refreshGeneration,
      population: request.query.population || request.body?.population || "all-supported"
    });
    response.json(payload);
  } catch (error) {
    response.status(500).json({
      error: "backtest_refresh_failed",
      message: error.message
    });
  }
});

app.post("/api/internal/backtests/:guruId/refresh", requireLoopbackRequest, requireInternalCron, async (request, response) => {
  const guru = gurus.find((item) => item.id === request.params.guruId);
  if (
    !guru ||
    !["manager13f", "congress"].includes(guru.type) ||
    guru.disableSimulation
  ) {
    response.status(400).json({
      error: "backtest_refresh_invalid_guru",
      message: "The requested guru does not have an enabled audited backtest."
    });
    return;
  }

  try {
    const payload = await loadGuruBacktest(guru.id, {
      refresh: true,
      years: request.query.years || request.body?.years || 5,
      detail: request.query.detail || request.body?.detail || "compact"
    });
    const ready = payload.status === "ready";
    response.setHeader("Cache-Control", "no-store");
    response.status(ready ? 200 : 422).json({
      ...(ready ? {} : {
        error: "backtest_refresh_not_ready",
        message: payload.method?.reason || "The audited backtest is not ready."
      }),
      guruId: guru.id,
      status: payload.status,
      window: payload.window || null,
      summary: payload.summary || {},
      dataQuality: payload.dataQuality || {},
      methodVersion: payload.method?.version || ""
    });
  } catch (error) {
    response.status(500).json({
      error: "backtest_refresh_failed",
      message: error.message
    });
  }
});

function requestedPriceRepairGuruIds(value) {
  const values = Array.isArray(value) ? value : value ? [value] : [];
  return [...new Set(values.map((item) => String(item || "").trim()).filter(Boolean))];
}

app.post("/api/internal/prices/repair", requireLoopbackRequest, requireInternalCron, async (request, response) => {
  const guruIds = requestedPriceRepairGuruIds(request.body?.refreshGuruIds);
  const knownGuruIds = new Set(gurus
    .filter((guru) =>
      (guru.type === "manager13f" || guru.type === "congress") && !guru.disableSimulation
    )
    .map((guru) => guru.id));
  const unknownGuruIds = guruIds.filter((guruId) => !knownGuruIds.has(guruId));
  if (!guruIds.length || guruIds.length > 5 || unknownGuruIds.length) {
    response.status(400).json({
      error: "price_repair_invalid_gurus",
      message: !guruIds.length
        ? "A price repair must refresh at least one affected guru."
        : unknownGuruIds.length
        ? `Unknown guru id(s): ${unknownGuruIds.join(", ")}`
        : "A price repair may refresh at most five gurus."
    });
    return;
  }

  let repair;
  try {
    repair = writeAuditedPriceRepair(request.body?.rows, {
      provider: request.body?.provider,
      reason: request.body?.reason,
      snapshotId: request.body?.snapshotId,
      sourceReference: request.body?.sourceReference,
      operator: request.body?.operator,
      affectedGuruIds: guruIds
    });
  } catch (error) {
    response.status(400).json({
      error: "price_repair_rejected",
      message: error.message
    });
    return;
  }

  const backtests = [];
  for (const guruId of guruIds) {
    try {
      const payload = await loadGuruBacktest(guruId, {
        refresh: true,
        years: 5,
        detail: "compact",
        refreshGeneration: repair.auditId
      });
      backtests.push({
        guruId,
        status: payload.status,
        start: payload.window?.start || "",
        end: payload.window?.end || "",
        minimumObservedExecutionCoverage:
          payload.dataQuality?.minimumObservedExecutionCoverage ?? null
      });
    } catch (error) {
      backtests.push({ guruId, status: "failed", message: error.message });
    }
  }

  const allRequestedBacktestsReady =
    backtests.length === guruIds.length && backtests.every((item) => item.status === "ready");
  response.setHeader("Cache-Control", "no-store");
  response.status(allRequestedBacktestsReady ? 201 : 422).json({
    ...(allRequestedBacktestsReady ? {} : {
      error: "price_repair_backtest_refresh_failed",
      message: "The price rows were repaired, but at least one affected backtest is not ready."
    }),
    repair,
    backtests,
    allRequestedBacktestsReady
  });
});

const thirteenFRefreshJobId = "guru_13f_refresh";

function thirteenFRefreshStatus() {
  return readBackgroundJobRun(thirteenFRefreshJobId) || {
    jobId: thirteenFRefreshJobId,
    startedAt: "",
    finishedAt: "",
    status: "idle",
    payload: {}
  };
}

function requested13fGuruIds(value) {
  const values = Array.isArray(value) ? value : String(value || "").split(",");
  return [...new Set(values.map((item) => String(item || "").trim()).filter(Boolean))];
}

app.get("/api/internal/gurus/refresh/status", requireLoopbackRequest, requireInternalCron, (_request, response) => {
  response.setHeader("Cache-Control", "no-store");
  response.json(thirteenFRefreshStatus());
});

app.post("/api/internal/gurus/refresh", requireLoopbackRequest, requireInternalCron, (request, response) => {
  const previous = thirteenFRefreshStatus();
  const previousStartedAt = new Date(previous.startedAt || "").getTime();
  const previousIsActive = ["queued", "running"].includes(previous.status) &&
    Number.isFinite(previousStartedAt) &&
    Date.now() - previousStartedAt < 2 * 60 * 60 * 1000;
  if (previousIsActive) {
    response.status(409).json({
      error: "guru_13f_refresh_in_progress",
      message: "A 13F refresh is already queued or running.",
      job: previous
    });
    return;
  }

  const guruIds = requested13fGuruIds(request.query.guru || request.body?.guru);
  const managerIds = new Set(
    gurus.filter((guru) => guru.type === "manager13f").map((guru) => guru.id)
  );
  const unknownIds = guruIds.filter((guruId) => !managerIds.has(guruId));
  if (unknownIds.length) {
    response.status(400).json({
      error: "unknown_13f_guru",
      message: `Unknown manager 13F guru id(s): ${unknownIds.join(", ")}`
    });
    return;
  }

  const years = String(request.query.years || request.body?.years || "all").trim();
  const requestedDetail = String(
    request.query.detail || request.body?.detail || "compact"
  ).trim().toLowerCase();
  const detail = ["compact", "full", "attribution"].includes(requestedDetail)
    ? requestedDetail
    : "compact";
  const exposureLimit = Math.max(
    4,
    Math.min(
      40,
      Math.round(
        Number(request.query.exposureLimit || request.body?.exposureLimit || 40) || 40
      )
    )
  );
  const reason = String(
    request.query.reason || request.body?.reason || "internal-api"
  ).trim().slice(0, 120) || "internal-api";
  const startedAt = new Date().toISOString();
  try {
    const refresh = startThirteenFRefresh({
      guruIds,
      reason,
      years,
      detail,
      exposureLimit
    });
    if (!refresh.started) {
      response.status(409).json({
        error: "guru_13f_refresh_in_progress",
        message: "A 13F refresh is already running in this API process.",
        job: thirteenFRefreshStatus()
      });
      return;
    }
    void refresh.promise.catch((error) => {
      console.error(`[13f-refresh] internal refresh failed: ${error.stack || error.message}`);
    });
    response.status(202).json({
      jobId: thirteenFRefreshJobId,
      status: "running",
      startedAt,
      selectedGuruIds: guruIds.length ? guruIds : [...managerIds]
    });
  } catch (error) {
    response.status(500).json({
      error: "guru_13f_refresh_start_failed",
      message: error.message
    });
  }
});

app.use("/api/admin", adminResponsePrivacy);
app.use("/api", requireAuth);
// Apply the owner gate to every current and future Admin route, before reads.
app.use("/api/admin", requireAdmin);
app.get('/api/admin/data-pipeline/status',(_request,response)=>response.json(dataReleaseStatus()??{status:'not_activated'}));
app.use("/api", recordLoginActivity);

function recordPortfolioRequestUser(request) {
  try {
    recordPortfolioUser(request.user);
  } catch (error) {
    console.warn("Unable to record portfolio user", error.message);
  }
}

app.use("/api", (request, _response, next) => {
  recordPortfolioRequestUser(request);
  next();
});
enableInvestmentPreview(app);
registerLoginActivityRoutes(app);


app.get("/api/gurus/config", (_request, response) => {
  response.json({ gurus });
});

app.get("/api/gurus", async (request, response) => {
  try {
    const forceRefresh = request.query.refresh === "1" || request.query.refresh === "true";
    const payload = await loadGuruDashboard({ forceRefresh });
    response.setHeader(
      "Cache-Control",
      forceRefresh ? "no-store" : "private, max-age=120, stale-while-revalidate=300"
    );
    response.json(payload);
  } catch (error) {
    response.status(500).json({ error: error.message });
  }
});

app.get("/api/portfolio", async (request, response) => {
  try {
    recordPortfolioRequestUser(request);
    const forceRefresh = request.query.refresh === "1" || request.query.refresh === "true";
    const payload = await loadPortfolioDashboard({ forceRefresh, user: request.user });
    response.json(payload);
  } catch (error) {
    if (respondPortfolioBusy(error, response)) return;
    response.status(500).json({ error: error.message });
  }
});

app.get("/api/portfolio/connection", async (request, response) => {
  try {
    recordPortfolioRequestUser(request);
    response.json(readPortfolioConnectionStatus(request.user));
  } catch (error) {
    response.status(500).json({ error: error.message });
  }
});

app.post("/api/portfolio/connection", async (request, response) => {
  try {
    recordPortfolioRequestUser(request);
    savePortfolioConnection(request.user, request.body || {});
    clearPortfolioCache(request.user);
    const payload = await loadPortfolioDashboard({ forceRefresh: true, user: request.user });
    response.json({
      ok: true,
      connection: readPortfolioConnectionStatus(request.user),
      portfolio: payload
    });
  } catch (error) {
    if (respondPortfolioBusy(error, response)) return;
    response.status(400).json({ error: "portfolio_connection_invalid", message: error.message });
  }
});

app.post("/api/portfolio/accounts", async (request, response) => {
  try {
    recordPortfolioRequestUser(request);
    addPortfolioAccount(request.user, request.body || {});
    clearPortfolioCache(request.user);
    const payload = await loadPortfolioDashboard({ forceRefresh: true, user: request.user });
    response.json({
      ok: true,
      connection: readPortfolioConnectionStatus(request.user),
      portfolio: payload
    });
  } catch (error) {
    if (respondPortfolioBusy(error, response)) return;
    response.status(400).json({ error: "portfolio_account_invalid", message: error.message });
  }
});

app.post("/api/portfolio/sync", async (request, response) => {
  const startedAt = new Date().toISOString();
  const userHash = String(request.user?.adminPortfolioHash || "").trim();
  writeBackgroundJobRun("portfolio_sync", {
    startedAt,
    status: "running",
    payload: {
      userHash,
      email: request.user?.email || "",
      source: "user-api"
    }
  });
  try {
    recordPortfolioRequestUser(request);
    // Force bypasses completed cache entries, but repeated sync clicks should
    // join the same in-flight work. Only connection changes invalidate it.
    const payload = await loadPortfolioDashboard({ forceRefresh: true, user: request.user });
    const result = portfolioSyncResult(payload);
    writeBackgroundJobRun("portfolio_sync", {
      startedAt,
      finishedAt: new Date().toISOString(),
      status: result.status,
      payload: {
        userHash,
        email: request.user?.email || "",
        source: "user-api",
        accounts: payload.summary?.accounts || 0,
        holdings: payload.summary?.holdings || 0,
        totalValue: payload.summary?.totalValue || 0,
        connectionStatus: payload.connection?.status || ""
      }
    });
    response.setHeader("Cache-Control", "no-store");
    response.json(result.response);
  } catch (error) {
    writeBackgroundJobRun("portfolio_sync", {
      startedAt,
      finishedAt: new Date().toISOString(),
      status: "failed",
      payload: {
        userHash,
        email: request.user?.email || "",
        source: "user-api",
        error: error.message
      }
    });
    if (respondPortfolioBusy(error, response)) return;
    response.status(500).json({ error: "portfolio_sync_failed", message: error.message });
  }
});

app.delete("/api/portfolio/connection", async (request, response) => {
  try {
    recordPortfolioRequestUser(request);
    const deletion = deletePortfolioConnection(request.user);
    clearPortfolioCache(request.user);
    response.json({
      ok: true,
      ...deletion,
      connection: readPortfolioConnectionStatus(request.user)
    });
  } catch (error) {
    response.status(500).json({ error: error.message });
  }
});

app.post("/api/portfolio/connection/restore", async (request, response) => {
  try {
    recordPortfolioRequestUser(request);
    const restoration = restorePortfolioConnection(request.user);
    if (!restoration.restored) {
      response.status(409).json({
        error: "portfolio_connection_recovery_unavailable",
        message: restoration.reason === "connection_exists"
          ? "A new portfolio connection already exists; the previous recovery copy was discarded."
          : "The portfolio connection recovery window has expired or is no longer available.",
        reason: restoration.reason,
        connection: readPortfolioConnectionStatus(request.user)
      });
      return;
    }
    clearPortfolioCache(request.user);
    const payload = await loadPortfolioDashboard({ forceRefresh: true, user: request.user });
    response.json({
      ok: true,
      restored: true,
      connection: readPortfolioConnectionStatus(request.user),
      portfolio: payload
    });
  } catch (error) {
    if (respondPortfolioBusy(error, response)) return;
    response.status(500).json({ error: error.message });
  }
});

app.post("/api/portfolio/dividends/refresh", async (_request, response) => {
  try {
    recordPortfolioRequestUser(_request);
    const payload = await loadPortfolioDashboard({ forceRefresh: true, user: _request.user });
    const result = await refreshDividendCalendarForTickers(payload.holdings || [], { force: true });
    response.json(result);
  } catch (error) {
    if (respondPortfolioBusy(error, response)) return;
    response.status(500).json({ error: error.message });
  }
});

registerAdminPortfolioUsersRoute(app);

app.get("/api/admin/system-health", requireAdmin, async (_request, response) => {
  try {
    response.setHeader("Cache-Control", "no-store");
    response.json(buildAdminSystemHealth({
      allowedOrigins,
      adminEmails: [ADMIN_OWNER_EMAIL]
    }));
  } catch (error) {
    response.status(500).json({
      error: "admin_system_health_failed",
      message: error.message
    });
  }
});

app.get("/api/admin/portfolio-users/:hash", requireAdmin, async (request, response) => {
  try {
    const target = portfolioUserForAdminHash(request.params.hash);
    if (!target) {
      response.status(404).json({ error: "portfolio_user_not_found" });
      return;
    }
    const forceRefresh = request.query.refresh === "1" || request.query.refresh === "true";
    const portfolio = await loadPortfolioDashboard({ forceRefresh, user: target.user });
    response.setHeader("Cache-Control", "no-store");
    response.json({
      generatedAt: new Date().toISOString(),
      user: target.publicUser,
      portfolio
    });
  } catch (error) {
    if (respondPortfolioBusy(error, response)) return;
    response.status(500).json({ error: "admin_portfolio_detail_failed", message: error.message });
  }
});

app.get("/api/admin/backtests/status", requireAdmin, (_request, response) => {
  response.json(guruBacktestRefreshStatus());
});

app.post("/api/admin/backtests/refresh", requireAdmin, async (request, response) => {
  try {
    const payload = await refreshGuruBacktestCache({
      years: request.query.years || request.body?.years || 5,
      detail: request.query.detail || request.body?.detail || "compact",
      reason: "admin-api"
    });
    response.json(payload);
  } catch (error) {
    response.status(500).json({
      error: "admin_backtest_refresh_failed",
      message: error.message
    });
  }
});

app.get("/api/valuation", async (_request, response) => {
  try {
    const payload = await loadValuationDashboard();
    response.setHeader("Cache-Control", "private, max-age=120");
    response.json(payload);
  } catch (error) {
    response.status(500).json({ error: error.message });
  }
});

app.post("/api/valuation/:ticker/import", async (request, response) => {
  try {
    const payload = await importValuationTicker(request.params.ticker, {
      pricePoints: request.query.pricePoints || request.body?.pricePoints
    });
    response.setHeader("Cache-Control", "no-store");
    response.json(payload);
  } catch (error) {
    response.status(error.statusCode || 502).json({
      error: "valuation_import_failed",
      message: error.message
    });
  }
});

app.get("/api/valuation/:ticker", createValuationTickerHandler(loadValuationTicker));

app.post("/api/translate/zh", async (request, response) => {
  try {
    const texts = Array.isArray(request.body?.texts) ? request.body.texts : [];
    const totalChars = texts.reduce((sum, value) => sum + String(value || "").length, 0);
    if (texts.length > 24 || totalChars > 60000) {
      response.status(400).json({
        error: "translation_request_too_large",
        message: "Translation request is too large."
      });
      return;
    }
    const translations = await translateTextsToChinese(texts);
    response.setHeader("Cache-Control", "private, max-age=86400");
    response.json({ targetLanguage: "zh-CN", translations });
  } catch (error) {
    response.status(502).json({
      error: "translation_failed",
      message: error.message
    });
  }
});

app.get("/api/gurus/:id", async (request, response) => {
  try {
    const forceRefresh = request.query.refresh === "1" || request.query.refresh === "true";
    const payload = await loadGuruDashboard({
      forceRefresh
    });
    const guru = payload.gurus.find((item) => item.id === request.params.id);
    if (!guru) {
      response.status(404).json({ error: "Guru not found" });
      return;
    }
    response.setHeader(
      "Cache-Control",
      forceRefresh ? "no-store" : "private, max-age=120, stale-while-revalidate=300"
    );
    response.json({ generatedAt: payload.generatedAt, source: payload.source, guru });
  } catch (error) {
    response.status(500).json({ error: error.message });
  }
});

app.get("/api/gurus/:id/context", async (request, response) => {
  try {
    const payload = await loadGuruMarketContext(request.params.id, {
      ticker: request.query.ticker,
      refresh: request.query.refresh === "1" || request.query.refresh === "true"
    });
    response.json(payload);
  } catch (error) {
    response.status(500).json({ error: error.message });
  }
});

app.get("/api/gurus/:id/exposure", async (request, response) => {
  try {
    const forceRefresh = request.query.refresh === "1" || request.query.refresh === "true";
    const payload = await loadGuruExposureHistory(request.params.id, {
      forceRefresh,
      limit: request.query.limit
    });
    response.setHeader(
      "Cache-Control",
      forceRefresh ? "no-store" : "private, max-age=120, stale-while-revalidate=300"
    );
    response.json(payload);
  } catch (error) {
    response.status(error.statusCode || 500).json({ error: error.message });
  }
});

app.get("/api/gurus/:id/backtest", async (request, response) => {
  try {
    const forceRefresh = request.query.refresh === "1" || request.query.refresh === "true";
    const requestedYears = request.query.years || 5;
    const policy = publicBacktestRequestPolicy(requestedYears, forceRefresh);
    const payload = await loadGuruBacktest(request.params.id, {
      refresh: policy.refresh,
      years: requestedYears,
      detail: request.query.detail,
      allowCold: policy.allowCold
    });
    response.setHeader(
      "Cache-Control",
      policy.refresh ? "no-store" : "private, max-age=120, stale-while-revalidate=300"
    );
    response.json(payload);
  } catch (error) {
    response.status(500).json({ error: error.message });
  }
});

app.get("/api/backtests", async (request, response) => {
  try {
    const forceRefresh = request.query.refresh === "1" || request.query.refresh === "true";
    const requestedYears = request.query.years || 5;
    const policy = publicBacktestRequestPolicy(requestedYears, forceRefresh);
    const payload = await loadGuruBacktests({
      refresh: policy.refresh,
      years: requestedYears,
      detail: request.query.detail,
      allowCold: policy.allowCold
    });
    response.setHeader(
      "Cache-Control",
      policy.refresh ? "no-store" : "private, max-age=120, stale-while-revalidate=300"
    );
    response.json(payload);
  } catch (error) {
    response.status(500).json({ error: error.message });
  }
});

app.get("/api/gurus/:id/commentary", async (request, response) => {
  try {
    const payload = await loadOperationCommentary(request.params.id, request.query);
    response.json(payload);
  } catch (error) {
    response.status(500).json({ error: error.message });
  }
});

if (process.env.NODE_ENV === "production" || process.env.SERVE_FRONTEND_DIST === "1") {
  const distDir = path.join(rootDir, "dist");
  const distIndexPath = path.join(distDir, "index.html");

  if (fs.existsSync(distIndexPath)) {
    app.use(express.static(distDir));
    app.use((_request, response) => {
      response.sendFile(distIndexPath);
    });
  } else {
    app.use((_request, response) => {
      response.status(404).json({
        error: "not_found",
        message: "This AWS service hosts API routes only. Use https://www.thesisforge.tech for the frontend."
      });
    });
  }
}

app.listen(port, process.env.INVESTMENT_WORKFLOW_ENABLED === 'true' ? '127.0.0.1' : undefined, () => {
  console.log(`Guru Analysis backend listening on http://127.0.0.1:${port}`);
});

if (process.env.PORTFOLIO_NAV_AUTO_CAPTURE !== "false") {
  startPortfolioNavRecorder();
}

if (process.env.DIVIDEND_CALENDAR_AUTO_REFRESH !== "false") {
  startDividendCalendarRefresher(async () => {
    const payload = await loadPortfolioDashboard({ forceRefresh: false });
    return payload.holdings || [];
  });
}

if (process.env.GURU_BACKTEST_AUTO_REFRESH !== "false") {
  startGuruBacktestRefresher();
}
