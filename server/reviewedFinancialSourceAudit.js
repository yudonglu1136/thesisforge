import crypto from "node:crypto";
import { guruValuationCompanyForTicker } from "./guruValuationUniverse.js";

const monetaryFields = new Set(["cfo_m", "capex_m", "fcf_after_capex_m", "revenue_m", "gross_profit_m", "operating_income_m", "net_income_m"]);
const finite = (v) => typeof v === "number" && Number.isFinite(v);
const same = (a, b) => finite(a) && finite(b) && Math.abs(a - b) <= 1e-8;
const originalEqual = (a, b) => a === null && b === null || same(a, b);
const date = (v) => typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v) && Number.isFinite(Date.parse(`${v}T00:00:00Z`)) && new Date(`${v}T00:00:00Z`).toISOString().slice(0, 10) === v;
const hash = (text) => crypto.createHash("sha256").update(text).digest("hex");
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  return JSON.stringify(value);
}
function issuerUrl(value, company) {
  try {
    const u = new URL(value);
    return u.protocol === "https:" && u.hostname === "www.sec.gov" && !u.username && !u.password && u.pathname.includes(`/data/${Number(company.cik)}/`);
  } catch { return false; }
}

/** Independent trusted-manifest audit of exact missing-source reconstruction.
 * financial is the source/model financial row, not scoreInputs. Model rows may
 * expose reported_fcf_after_capex_m and reported_operating_financials after the
 * separately audited economic bridge; these are checked against trusted values.
 */
export function auditReviewedFinancialSource({ ticker, fiscalPeriod, sourceRecord = {},
  financialSources = {}, financial = {}, asOfDate,
  reviewedCompany = guruValuationCompanyForTicker(ticker) }) {
  const lineage = (sourceRecord.reviewedInputCorrections || []).filter((x) => monetaryFields.has(x.field));
  const configured = (reviewedCompany?.inputCorrections || []).filter((x) => monetaryFields.has(x.field) && x.fiscalPeriod === fiscalPeriod && x.dimensions?.includes(sourceRecord.dimension));
  if (!lineage.length && !configured.length) return { applies: false, ok: true, failures: [] };
  const failures = [];
  const fail = (detail) => failures.push({ ticker, period: fiscalPeriod, code: "unverified_reviewed_financial_source_correction", detail });
  if (reviewedCompany?.ticker !== ticker || reviewedCompany.reviewStatus !== "reviewed" || reviewedCompany.economicReview?.releaseBlockers?.length || !configured.length) {
    fail("No approved issuer/period/dimension monetary reconstruction in trusted manifest");
    return { applies: true, ok: false, failures };
  }
  if (lineage.length !== configured.length || new Set(configured.map((x) => x.id)).size !== configured.length || new Set(configured.map((x) => x.field)).size !== configured.length) fail("Missing, duplicated or extra monetary correction lineage");
  const saved = sourceRecord.reviewedOriginalFinancialPayload;
  let original = null;
  try {
    if (!saved || typeof saved.json !== "string" || hash(saved.json) !== saved.sha256) throw new Error();
    original = JSON.parse(saved.json);
  } catch { fail("Missing or invalid immutable original financial payload/hash"); }
  const cutoff = String(asOfDate || "").slice(0, 10);
  for (const expected of configured) {
    const actual = lineage.filter((x) => x.id === expected.id);
    const entry = actual[0] || {};
    const digest = hash(canonical(expected));
    if (actual.length !== 1 || entry.correctionSha256 !== digest || entry.reviewedAt !== reviewedCompany.reviewedAt ||
      canonical(Object.fromEntries(Object.keys(expected).map((k) => [k, entry[k]]))) !== canonical(expected)) fail(`${expected.field}: correction contents/hash differ from trusted manifest`);
    if (expected.unit !== "million_reporting_currency" || !issuerUrl(expected.sourceUrl, reviewedCompany) || !expected.sourceLocator || !expected.reason ||
      expected.currency !== reviewedCompany.currency || !finite(expected.value) || expected.field === "capex_m" && expected.value < 0 ||
      !finite(expected.sourcePrecisionM) || expected.sourcePrecisionM <= 0 || !expected.precisionPolicy) fail(`${expected.field}: invalid primary evidence, monetary unit or precision policy`);
    if (![cutoff, expected.periodEndDate, expected.sourceAvailableDate, expected.expectedRecordAvailableDate].every(date) ||
      sourceRecord.sourceTicker !== ticker || sourceRecord.reportperiod !== expected.periodEndDate ||
      sourceRecord.datekey !== expected.expectedRecordAvailableDate || sourceRecord.modelCurrency !== expected.currency || sourceRecord.currency !== expected.currency ||
      !same(sourceRecord.currencyScale, 1) || expected.periodEndDate > expected.sourceAvailableDate ||
      expected.sourceAvailableDate > expected.expectedRecordAvailableDate || expected.expectedRecordAvailableDate > cutoff) fail(`${expected.field}: issuer, currency, dimension or PIT date mismatch`);
    const trustedRawHash = expected.expectedOriginalPayloadSha256ByDimension?.[sourceRecord.dimension];
    if (!/^[a-f0-9]{64}$/.test(trustedRawHash || "") || saved?.sha256 !== trustedRawHash || !original ||
      original.ticker !== ticker || original.sourceDimension !== sourceRecord.dimension || original.periodEndDate !== expected.periodEndDate ||
      original.asOfDate !== expected.expectedRecordAvailableDate || original.financialStatementCurrency !== expected.currency ||
      !Object.hasOwn(original, expected.field) || !originalEqual(original[expected.field], expected.expectedOriginalValue) ||
      !originalEqual(entry.originalValue, expected.expectedOriginalValue) ||
      canonical(entry.originalSource ?? null) !== canonical(original.sources?.[expected.field] ?? null)) fail(`${expected.field}: original provider field/source cannot be independently reconstructed`);
    let total = 0;
    if (!Array.isArray(expected.sourceComponents) || !expected.sourceComponents.length) fail(`${expected.field}: exact dated derivation missing`);
    for (const item of expected.sourceComponents || []) {
      if (!finite(item.valueM) || ![1, -1].includes(item.multiplier) || item.currency !== expected.currency || !issuerUrl(item.url, reviewedCompany) ||
        !/^[a-f0-9]{64}$/.test(item.sha256 || "") || !item.locator || !date(item.availableDate) || !date(item.periodEndDate) ||
        item.periodEndDate > item.availableDate || item.periodEndDate > expected.periodEndDate || item.availableDate > expected.expectedRecordAvailableDate) fail(`${expected.field}: invalid or future component evidence`);
      total += item.valueM * item.multiplier;
    }
    if (!same(total, expected.value)) fail(`${expected.field}: exact source derivation does not equal approved value; precision is not a tolerance`);
    const tag = financialSources[expected.field] || {};
    if (tag.correctionId !== expected.id || tag.correctionSha256 !== digest || tag.url !== expected.sourceUrl ||
      tag.filed !== expected.sourceAvailableDate || tag.end !== expected.periodEndDate || tag.locator !== expected.sourceLocator ||
      tag.precisionM !== expected.sourcePrecisionM || canonical(tag.sourceComponents) !== canonical(expected.sourceComponents)) fail(`${expected.field}: source tag loses approved evidence/hash/precision`);
    const modelValue = expected.field === "fcf_after_capex_m" && Object.hasOwn(financial, "reported_fcf_after_capex_m")
      ? financial.reported_fcf_after_capex_m
      : Object.hasOwn(financial.reported_operating_financials || {}, expected.field)
        ? financial.reported_operating_financials[expected.field] : financial[expected.field];
    if (!same(modelValue, expected.value)) fail(`${expected.field}: model financial input differs from approved reconstruction`);
  }
  const cfo = configured.find((x) => x.field === "cfo_m")?.value;
  const capex = configured.find((x) => x.field === "capex_m")?.value;
  const fcf = configured.find((x) => x.field === "fcf_after_capex_m")?.value;
  if ([cfo, capex, fcf].some((v) => v !== undefined) && !same(cfo - capex, fcf)) fail("Reconstructed CFO minus cash capex does not equal FCF");
  return { applies: true, ok: failures.length === 0, correctionCount: configured.length, failures };
}
