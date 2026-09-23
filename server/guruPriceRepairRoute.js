import express from "express";

import {
  applyGuruPriceRepairArtifact,
  validateGuruPriceRepairArtifact
} from "./guruPriceRepairArtifact.js";

function validSnapshotId(value) {
  return /^snap-[a-f0-9]{8,32}$/.test(String(value || "").trim().toLowerCase());
}

function validOperator(value) {
  return /^[A-Za-z0-9][A-Za-z0-9._:@/-]{2,79}$/.test(String(value || "").trim());
}

function payloadMatchesRelease(payload, target, expectations, startedAt) {
  if (payload?.status !== target.expectedStatus) return false;
  if (payload?.method?.version !== expectations.strictMethodVersion) return false;
  if (payload?.method?.securityMasterVersion !== expectations.securityMasterVersion) return false;
  if (Number(payload?.method?.years) !== target.years) return false;
  const generatedAt = Date.parse(payload?.generatedAt || "");
  if (!Number.isFinite(generatedAt) || generatedAt < Date.parse(startedAt)) return false;
  if (target.expectedStatus === "proxy_ready") {
    return payload?.proxy?.methodVersion === expectations.proxyMethodVersion &&
      payload?.proxy?.securityMasterVersion === expectations.securityMasterVersion;
  }
  return true;
}

export function registerGuruPriceRepairRoute(app, {
  requireInternalCron,
  requireLoopbackRequest,
  gurus,
  readPriceSeriesFromDb,
  writeAuditedPriceSeriesImportBatch,
  loadGuruBacktest,
  strictMethodVersion,
  proxyMethodVersion,
  securityMasterVersion
}) {
  app.post(
    "/api/internal/release/guru-price-repair",
    requireLoopbackRequest,
    requireInternalCron,
    express.json({ limit: "5mb" }),
    async (request, response) => {
      response.setHeader("Cache-Control", "no-store");
      const snapshotId = String(request.body?.snapshotId || "").trim().toLowerCase();
      const snapshotState = String(request.body?.snapshotState || "").trim().toLowerCase();
      const operator = String(request.body?.operator || "").trim();
      if (!validSnapshotId(snapshotId) || snapshotState !== "completed" || !validOperator(operator)) {
        response.status(400).json({
          error: "guru_price_repair_invalid_release_context",
          message: "A completed pre-write snapshot and valid operator are required."
        });
        return;
      }

      const knownGuruIds = gurus
        .filter((guru) => guru.type === "manager13f" && !guru.disableSimulation)
        .map((guru) => guru.id);
      let artifact;
      try {
        artifact = validateGuruPriceRepairArtifact(request.body?.artifact, { knownGuruIds });
      } catch (error) {
        response.status(400).json({
          error: "guru_price_repair_invalid_artifact",
          message: error.message
        });
        return;
      }
      const expected = artifact.expectations;
      const releaseContextMatches = artifact.release.sourceSnapshotId === snapshotId &&
        artifact.release.operator === operator &&
        artifact.release.releaseId === String(request.body?.releaseId || "").trim() &&
        artifact.release.sourceVolumeId ===
          String(request.body?.sourceVolumeId || "").trim().toLowerCase() &&
        artifact.release.encryptedSnapshotId ===
          String(request.body?.encryptedSnapshotId || "").trim().toLowerCase();
      if (!releaseContextMatches) {
        response.status(409).json({
          error: "guru_price_repair_release_context_mismatch",
          message: "The artifact is not bound to this release volume, snapshots, and operator."
        });
        return;
      }
      if (expected.strictMethodVersion !== strictMethodVersion ||
          expected.proxyMethodVersion !== proxyMethodVersion ||
          expected.securityMasterVersion !== securityMasterVersion) {
        response.status(409).json({
          error: "guru_price_repair_release_identity_mismatch",
          message: "The artifact does not match the running backtest and security-master identities."
        });
        return;
      }

      let installation;
      try {
        installation = applyGuruPriceRepairArtifact(artifact, {
          snapshotId,
          snapshotState,
          operator,
          knownGuruIds,
          readSeries: readPriceSeriesFromDb,
          writeBatch: writeAuditedPriceSeriesImportBatch
        });
      } catch (error) {
        response.status(409).json({
          error: "guru_price_repair_install_failed",
          message: error.message
        });
        return;
      }

      const startedAt = new Date().toISOString();
      const refreshes = [];
      for (const target of artifact.refreshTargets) {
        try {
          const payload = await loadGuruBacktest(target.guruId, {
            refresh: true,
            computeFromDisclosures: true,
            years: target.years,
            detail: "compact",
            refreshGeneration:
              `${artifact.recordsSha256}:${target.guruId}:${target.years}`
          });
          refreshes.push({
            ...target,
            actualStatus: payload?.status || "missing",
            generatedAt: payload?.generatedAt || "",
            methodVersion: payload?.method?.version || "",
            securityMasterVersion: payload?.method?.securityMasterVersion || "",
            pass: payloadMatchesRelease(payload, target, expected, startedAt)
          });
        } catch (error) {
          refreshes.push({ ...target, actualStatus: "failed", pass: false, message: error.message });
        }
      }
      const pass = refreshes.length === artifact.refreshTargets.length &&
        refreshes.every((refresh) => refresh.pass);
      response.status(pass ? 201 : 422).json({
        ...(pass ? {} : {
          error: "guru_price_repair_target_refresh_failed",
          message: "The price repair was installed, but a required post-repair curve did not pass."
        }),
        status: pass ? "installed" : "refresh_failed",
        recordsSha256: artifact.recordsSha256,
        installedAt: startedAt,
        series: installation.series,
        totalRows: installation.totalRows,
        importedRows: installation.importedRows,
        verifiedExistingRows: installation.verifiedExistingRows,
        auditIds: installation.auditIds,
        batchAuditId: installation.batchAuditId,
        batchAuditReplayed: installation.batchAuditReplayed,
        expectations: artifact.expectations,
        release: artifact.release,
        refreshes,
        pass
      });
    }
  );
}
