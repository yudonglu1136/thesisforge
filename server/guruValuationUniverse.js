import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  sp500CanonicalTicker,
  sp500CompanyForTicker,
  sp500CompanyTickers
} from "./sp500ValuationUniverse.js";

// This is an allowlist of implemented economic models, never a default mapping.
// The model-catalog regression test keeps it aligned with PROFILE_SETTINGS.
export const GURU_VALUATION_PROFILE_NAMES = Object.freeze([
  "mega_cap_platform", "ads_ai_platform", "platform_reinvestment",
  "platform_marketplace_reinvestment", "subscription_streaming_platform",
  "payments_network", "payments_processor", "card_network_lender",
  "software_growth", "hypergrowth_ai_software", "semiconductor_growth",
  "semiconductor_cyclical", "semiconductor_storage_cycle", "semiconductor_value",
  "semiconductor_foundry", "semiconductor_equipment", "networking_hardware",
  "optical_networking_turnaround", "bank", "insurance", "biopharma",
  "biopharma_growth", "medtech_platform", "mature_medtech",
  "healthcare_distribution", "managed_care", "genetic_diagnostics_growth",
  "defense_prime", "defense_growth", "space_launch_growth", "space_platform_ipo",
  "bitcoin_treasury_software", "energy_e_and_p", "power_utility",
  "quality_consumer", "information_services", "media_telecom",
  "interactive_entertainment", "industrial_growth", "software_platform",
  "technology_hardware", "credit_services", "capital_markets", "asset_manager",
  "insurance_broker", "reit", "energy_infrastructure", "materials",
  "commodity_merchant", "consumer_staples", "consumer_cyclical",
  "healthcare_services", "transportation", "industrial_gases_compounder",
  "ev_autonomy_platform", "energy_technology", "emerging_biotech",
  "emerging_health_ai"
]);

const profileNames = new Set(GURU_VALUATION_PROFILE_NAMES);
const currencies = new Set(Intl.supportedValuesOf("currency"));
const manifestPath = process.env.GURU_VALUATION_UNIVERSE_PATH ||
  path.join(process.cwd(), "server/config/guru-valuation-universe.json");

function requireValue(condition, message) {
  if (!condition) throw new Error(`Invalid Guru valuation universe: ${message}`);
}

function nonempty(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function validTicker(value) {
  return typeof value === "string" && /^[A-Z0-9][A-Z0-9.-]{0,15}$/.test(value);
}

function validDate(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

function validateEvidence(item, ticker) {
  requireValue(item && typeof item === "object" && !Array.isArray(item), `${ticker} identity evidence must be an object`);
  requireValue(nonempty(item.source) && nonempty(item.evidence), `${ticker} identity evidence needs source and evidence`);
  let url;
  try {
    url = new URL(item.url);
  } catch {
    requireValue(false, `${ticker} identity evidence needs a public HTTPS URL`);
  }
  requireValue(url.protocol === "https:" && !url.username && !url.password &&
    url.hostname.includes(".") && !/^(?:localhost|127\.|0\.|10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)/.test(url.hostname),
  `${ticker} identity evidence needs a public HTTPS URL without credentials`);
}

export function createGuruValuationUniverse(input) {
  requireValue(input && typeof input === "object" && !Array.isArray(input), "manifest must be an object");
  requireValue(input.schemaVersion === 1, "schemaVersion must be 1");
  requireValue(validDate(input.asOf), "asOf must be a real YYYY-MM-DD date");
  requireValue(Array.isArray(input.companies), "companies must be an array");
  if (input.securityMasterRecordsSha256 != null) {
    requireValue(/^[a-f0-9]{64}$/.test(input.securityMasterRecordsSha256), "securityMasterRecordsSha256 must be 64 lowercase hex characters");
  }
  const manifest = structuredClone(input);
  const byTicker = new Map();
  const canonicalByAlias = new Map();
  const allTickers = new Set();
  const cikOwners = new Map();
  const sourceOwners = new Map();
  const priceOwners = new Map();
  const indexCiks = new Set(sp500CompanyTickers().map((ticker) => sp500CompanyForTicker(ticker)?.cik));
  let unreviewedCompanyCount = 0;
  for (const company of manifest.companies) {
    requireValue(company && typeof company === "object" && !Array.isArray(company), "company row must be an object");
    const ticker = company.ticker;
    requireValue(validTicker(ticker), "ticker must be an uppercase canonical symbol");
    requireValue(!allTickers.has(ticker), `duplicate ticker ${ticker}`);
    allTickers.add(ticker);
    requireValue(["reviewed", "unreviewed"].includes(company.reviewStatus), `${ticker} requires explicit reviewStatus`);
    if (company.reviewStatus === "unreviewed") {
      unreviewedCompanyCount += 1;
      continue;
    }
    for (const key of ["sourceTicker", "priceTicker"]) {
      requireValue(validTicker(company[key]), `${ticker} requires valid ${key}`);
    }
    requireValue(nonempty(company.name), `${ticker} requires issuer name`);
    requireValue(typeof company.cik === "string" && /^\d{10}$/.test(company.cik) && Number(company.cik) > 0,
      `${ticker} requires a nonzero ten-digit issuer CIK`);
    requireValue(!indexCiks.has(company.cik), `${ticker} duplicates an S&P issuer CIK`);
    requireValue(!cikOwners.has(company.cik), `${ticker} duplicates reviewed issuer CIK owned by ${cikOwners.get(company.cik)}`);
    for (const key of ["currency", "reportingCurrency"]) {
      requireValue(currencies.has(company[key]), `${ticker} requires recognized uppercase ${key}`);
    }
    requireValue(profileNames.has(company.valuationProfile), `${ticker} requires an implemented explicit valuationProfile`);
    requireValue(nonempty(company.profileRationale), `${ticker} requires profileRationale`);
    requireValue(validDate(company.reviewedAt) && company.reviewedAt <= manifest.asOf,
      `${ticker} reviewedAt must be a real date on or before asOf`);
    requireValue(Array.isArray(company.identityEvidence) && company.identityEvidence.length > 0,
      `${ticker} requires identityEvidence`);
    for (const evidence of company.identityEvidence) validateEvidence(evidence, ticker);
    requireValue(company.aliases == null || Array.isArray(company.aliases), `${ticker} aliases must be an array`);
    const aliases = [ticker, ...(company.aliases || [])];
    requireValue(new Set(aliases).size === aliases.length, `${ticker} contains duplicate aliases`);
    for (const alias of aliases) {
      requireValue(validTicker(alias), `${ticker} has an invalid alias`);
      requireValue(!sp500CompanyForTicker(alias), `${ticker} conflicts with S&P ticker or alias ${alias}`);
      requireValue(!canonicalByAlias.has(alias), `${ticker} conflicts with reviewed alias ${alias}`);
      canonicalByAlias.set(alias, ticker);
    }
    for (const [key, owners] of [["sourceTicker", sourceOwners], ["priceTicker", priceOwners]]) {
      requireValue(!owners.has(company[key]), `${ticker} duplicates ${key} owned by ${owners.get(company[key])}`);
      requireValue(!sp500CompanyForTicker(company[key]), `${ticker} ${key} points to an S&P security`);
      owners.set(company[key], ticker);
    }
    cikOwners.set(company.cik, ticker);
    byTicker.set(ticker, company);
  }
  for (const ticker of allTickers) {
    requireValue(!canonicalByAlias.has(ticker) || canonicalByAlias.get(ticker) === ticker,
      `${ticker} company row conflicts with another company's alias`);
  }
  const normalized = (value) => String(value || "").trim().toUpperCase();
  const canonicalTicker = (value) => canonicalByAlias.get(normalized(value)) || normalized(value);
  const companyForTicker = (value) => {
    const company = byTicker.get(canonicalTicker(value));
    return company ? structuredClone(company) : null;
  };
  return {
    companyForTicker,
    canonicalTicker,
    companyTickers: () => [...byTicker.keys()].sort(),
    valuationProfile: (value) => byTicker.get(canonicalTicker(value))?.valuationProfile || null,
    expectedTickerSet: (baselineTickers = []) => new Set([
      ...sp500CompanyTickers(),
      ...baselineTickers.map((ticker) => canonicalTicker(sp500CanonicalTicker(normalized(ticker)))),
      ...byTicker.keys()
    ]),
    summary: () => ({
      schemaVersion: manifest.schemaVersion,
      asOf: manifest.asOf,
      reviewedCompanyCount: byTicker.size,
      unreviewedCompanyCount,
      securityMasterRecordsSha256: manifest.securityMasterRecordsSha256 || null
    })
  };
}

export function loadGuruValuationUniverse(filePath = manifestPath) {
  const content = fs.readFileSync(filePath, "utf8");
  const universe = createGuruValuationUniverse(JSON.parse(content));
  const summary = universe.summary();
  universe.summary = () => ({
    ...summary,
    manifestSha256: crypto.createHash("sha256").update(content).digest("hex")
  });
  return universe;
}

const universe = loadGuruValuationUniverse();
export const guruValuationCompanyForTicker = universe.companyForTicker;
export const guruValuationCanonicalTicker = universe.canonicalTicker;
export const guruValuationCompanyTickers = universe.companyTickers;
export const guruValuationProfile = universe.valuationProfile;
export const guruValuationExpectedTickerSet = universe.expectedTickerSet;
export const guruValuationUniverseSummary = universe.summary;
