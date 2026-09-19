import crypto from "node:crypto";
import { guruValuationCompanyForTicker } from "./guruValuationUniverse.js";

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
}

const equalNumber = (a, b) => typeof a === "number" && typeof b === "number" &&
  Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) <= 1e-8;
const validDate = (value) => typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) &&
  Number.isFinite(Date.parse(`${value}T00:00:00Z`)) && new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) === value;

// Read the independently approved manifest, never approve a correction merely
// because a model payload or its own provenance says it was reviewed.
export function auditReviewedShareCount({
  ticker, fiscalPeriod, sourceRecord = {}, financialShareSource,
  scoreSharesM, financialSharesM, trailingSharesM, asOfDate,
  reviewedCompany = guruValuationCompanyForTicker(ticker)
}) {
  const lineage = (Array.isArray(sourceRecord.reviewedInputCorrections) ? sourceRecord.reviewedInputCorrections : [])
    .filter((item) => item.field === "shares_m");
  const claimed = sourceRecord.shareCountBasis === "official_period_end_common_shares" || lineage.length > 0;
  const configured = reviewedCompany?.inputCorrections?.filter((item) => item.fiscalPeriod === fiscalPeriod && item.field === "shares_m") || [];
  if (!claimed && configured.length === 0) return { applies: false, ok: true, failures: [] };
  const failures = [];
  const fail = (detail) => failures.push({ ticker, period: fiscalPeriod, code: "unverified_reviewed_share_correction", detail });
  if (reviewedCompany?.ticker !== ticker || reviewedCompany?.reviewStatus !== "reviewed" ||
      reviewedCompany?.economicReview?.releaseBlockers?.length || configured.length !== 1) {
    fail("No unique approved issuer/period correction in the trusted manifest");
    return { applies: true, ok: false, failures };
  }
  const expected = configured[0];
  const digest = crypto.createHash("sha256").update(canonical(expected)).digest("hex");
  const exact = lineage.filter((item) => item.id === expected.id);
  if (exact.length !== 1 || lineage.length !== 1) fail("Missing, duplicated or unapproved correction lineage");
  const actual = exact[0] || {};
  const originalSource = actual.originalSource || {};
  let officialUrl = false;
  try {
    const url = new URL(expected.sourceUrl);
    officialUrl = url.protocol === "https:" && url.hostname === "www.sec.gov" && !url.username && !url.password &&
      url.pathname.includes(`/data/${Number(reviewedCompany.cik)}/`);
  } catch { /* Invalid source is rejected below. */ }
  if (!officialUrl || expected.field !== "shares_m" || expected.unit !== "million_common_shares" ||
      !expected.sourceLocator || expected.currency !== reviewedCompany.currency || !(expected.value > 0)) {
    fail("Invalid official source, field, quoted currency or positive share value");
  }
  if (!claimed || sourceRecord.shareCountBasis !== "official_period_end_common_shares" ||
      actual.correctionSha256 !== digest ||
      canonical(Object.fromEntries(Object.keys(expected).map((key) => [key, actual[key]]))) !== canonical(expected) ||
      actual.reviewedAt !== reviewedCompany.reviewedAt) {
    fail("Correction contents or hash do not match independently approved manifest");
  }
  if (![expected.periodEndDate, expected.sourceAvailableDate, expected.expectedRecordAvailableDate, String(asOfDate || "").slice(0, 10)].every(validDate) ||
      !expected.dimensions?.includes(sourceRecord.dimension) || sourceRecord.sourceTicker !== ticker ||
      sourceRecord.reportperiod !== expected.periodEndDate || sourceRecord.datekey !== expected.expectedRecordAvailableDate ||
      sourceRecord.modelCurrency !== expected.currency || sourceRecord.currency !== expected.currency ||
      String(asOfDate || "").slice(0, 10) < expected.expectedRecordAvailableDate ||
      expected.sourceAvailableDate > expected.expectedRecordAvailableDate ||
      expected.periodEndDate > expected.sourceAvailableDate) {
    fail("Correction identity, financial dimension, currency or PIT date scope mismatch");
  }
  if (!equalNumber(sourceRecord.rawShareCounts?.sharesbas / 1_000_000, expected.expectedOriginalValue) ||
      !equalNumber(actual.originalValue, expected.expectedOriginalValue) ||
      !equalNumber(sourceRecord.appliedShareFactor, 1) || !equalNumber(sourceRecord.sharefactor, 1) ||
      originalSource.filed !== expected.expectedRecordAvailableDate || originalSource.end !== expected.periodEndDate ||
      !/period-end basic (?:ordinary )?shares/i.test(String(sourceRecord.shareCountPolicy || ""))) {
    fail("Original provider shares, factor, policy or preserved source cannot be reconciled");
  }
  if (!equalNumber(scoreSharesM, expected.value) || !equalNumber(financialSharesM, expected.value) ||
      (trailingSharesM != null && !equalNumber(trailingSharesM, expected.value))) {
    fail("Model/financial denominator does not equal approved period-end common shares");
  }
  const tag = financialShareSource || {};
  if (tag.correctionId !== expected.id || tag.correctionSha256 !== digest ||
      tag.url !== expected.sourceUrl || tag.filed !== expected.sourceAvailableDate ||
      tag.end !== expected.periodEndDate || tag.locator !== expected.sourceLocator ||
      tag.precisionShares !== expected.sourcePrecisionShares) {
    fail("Financial source tag does not preserve approved official evidence and precision");
  }
  return { applies: true, ok: failures.length === 0, expectedSharesM: expected.value, failures };
}
