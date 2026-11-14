import { createHash } from "node:crypto";

function normalizedCusip(value) {
  return String(value || "")
    .trim()
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");
}

function normalizedTicker(value) {
  return String(value || "").trim().toUpperCase();
}

function validIsoDate(value) {
  const normalized = String(value || "").trim();
  return /^\d{4}-\d{2}-\d{2}$/.test(normalized) ? normalized : "";
}

function validCashPrice(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

/**
 * Point-in-time terminal cash actions used by the manager-13F simulator.
 *
 * These are deliberately exact-CUSIP records. A ticker alone is not a safe
 * corporate-action identity because symbols can be recycled. Each row needs
 * an effective date and a per-share cash right from primary evidence. The
 * cash treatment applies only to ordinary public shares that were converted
 * by the merger; a separately negotiated private rollover is outside scope.
 */
export const manager13fCashAcquisitions = Object.freeze([
  Object.freeze({
    id: "change-healthcare-unitedhealth-2022",
    cusip: "15912K100",
    ticker: "CHNG",
    issuer: "Change Healthcare Inc.",
    actionType: "cash_acquisition",
    effectiveDate: "2022-10-03",
    consideration: Object.freeze({
      type: "cash",
      amountPerShare: 25.75,
      additionalCashPerShare: 2.00,
      totalCashEntitlementPerShare: 27.75,
      currency: "USD"
    }),
    publicShareScope: "non_excluded_public_common_shares",
    sources: Object.freeze([
      "https://www.sec.gov/Archives/edgar/data/1756497/000119312522256246/d403452d8k.htm",
      "https://www.sec.gov/Archives/edgar/data/1756497/000089924322033017/xslF345X03/doc4.xml"
    ])
  }),
  Object.freeze({
    id: "twitter-x-holdings-2022",
    cusip: "90184L102",
    ticker: "TWTR",
    issuer: "Twitter, Inc.",
    actionType: "cash_acquisition",
    effectiveDate: "2022-10-27",
    publicTradingEndExclusive: "2022-10-28",
    consideration: Object.freeze({
      type: "cash",
      amountPerShare: 54.20,
      additionalCashPerShare: 0,
      totalCashEntitlementPerShare: 54.20,
      currency: "USD"
    }),
    publicShareScope: "non_excluded_public_common_shares",
    sources: Object.freeze([
      "https://www.sec.gov/Archives/edgar/data/1418091/000119312522272772/d411753d8k.htm",
      "https://www.sec.gov/Archives/edgar/data/876661/000087666122000890/ruleprovisionnotice.htm",
      "https://www.sec.gov/Archives/edgar/data/1418091/000110465922113051/tm2229215d1_sc13da.htm"
    ])
  }),
  Object.freeze({
    id: "zendesk-permira-hellman-friedman-2022",
    cusip: "98936J101",
    ticker: "ZEN",
    issuer: "Zendesk, Inc.",
    actionType: "cash_acquisition",
    effectiveDate: "2022-11-22",
    consideration: Object.freeze({
      type: "cash",
      amountPerShare: 77.50,
      additionalCashPerShare: 0,
      totalCashEntitlementPerShare: 77.50,
      currency: "USD"
    }),
    publicShareScope: "non_excluded_public_common_shares",
    sources: Object.freeze([
      "https://www.sec.gov/Archives/edgar/data/1463172/000114036122042681/brhc10044488_8k.htm"
    ])
  }),
  Object.freeze({
    id: "archaea-energy-bp-2022",
    cusip: "03940F103",
    ticker: "LFG",
    issuer: "Archaea Energy Inc.",
    actionType: "cash_acquisition",
    effectiveDate: "2022-12-28",
    consideration: Object.freeze({
      type: "cash",
      amountPerShare: 26.00,
      additionalCashPerShare: 0,
      totalCashEntitlementPerShare: 26.00,
      currency: "USD"
    }),
    publicShareScope: "non_excluded_public_common_shares",
    sources: Object.freeze([
      "https://www.sec.gov/Archives/edgar/data/1823766/000121390022083247/ea170864-8k_archaea.htm",
      "https://www.sec.gov/Archives/edgar/data/1823766/000121390022064373/ea167189ex99-1_archaea.htm"
    ])
  }),
  Object.freeze({
    id: "veritiv-clayton-dubilier-rice-2023",
    cusip: "923454102",
    ticker: "VRTV",
    issuer: "Veritiv Corporation",
    actionType: "cash_acquisition",
    effectiveDate: "2023-11-30",
    consideration: Object.freeze({
      type: "cash",
      amountPerShare: 170.00,
      additionalCashPerShare: 0,
      totalCashEntitlementPerShare: 170.00,
      currency: "USD"
    }),
    publicShareScope: "non_excluded_public_common_shares",
    sources: Object.freeze([
      "https://www.sec.gov/Archives/edgar/data/1599489/000110465923122267/tm2331772d1_8k.htm"
    ])
  }),
  Object.freeze({
    id: "atlas-air-apollo-2023",
    cusip: "049164205",
    ticker: "AAWW",
    issuer: "Atlas Air Worldwide Holdings, Inc.",
    actionType: "cash_acquisition",
    effectiveDate: "2023-03-17",
    consideration: Object.freeze({
      type: "cash",
      amountPerShare: 102.50,
      additionalCashPerShare: 0,
      totalCashEntitlementPerShare: 102.50,
      currency: "USD"
    }),
    publicShareScope: "non_excluded_public_common_shares",
    sources: Object.freeze([
      "https://www.sec.gov/Archives/edgar/data/1135185/000110465923033984/tm239235d1_ex99-1.htm"
    ])
  }),
  Object.freeze({
    id: "smartsheet-blackstone-vista-2025",
    cusip: "83200N103",
    ticker: "SMAR",
    issuer: "Smartsheet Inc.",
    actionType: "cash_acquisition",
    effectiveDate: "2025-01-22",
    consideration: Object.freeze({
      type: "cash",
      amountPerShare: 56.50,
      additionalCashPerShare: 0,
      totalCashEntitlementPerShare: 56.50,
      currency: "USD"
    }),
    publicShareScope: "non_excluded_public_common_shares",
    sources: Object.freeze([
      "https://www.sec.gov/Archives/edgar/data/1366561/000162828025002101/smar-20250122.htm"
    ])
  }),
  Object.freeze({
    id: "semrush-adobe-2026",
    cusip: "81686C104",
    ticker: "SEMR",
    issuer: "Semrush Holdings, Inc.",
    actionType: "cash_acquisition",
    effectiveDate: "2026-04-28",
    consideration: Object.freeze({
      type: "cash",
      amountPerShare: 12.00,
      additionalCashPerShare: 0,
      totalCashEntitlementPerShare: 12.00,
      currency: "USD"
    }),
    publicShareScope: "non_excluded_public_common_shares",
    sources: Object.freeze([
      "https://www.sec.gov/Archives/edgar/data/1831840/000114036126017299/ef20071354_8k.htm"
    ])
  }),
  Object.freeze({
    id: "odp-atlas-holdings-2025",
    cusip: "88337F105",
    ticker: "ODP",
    issuer: "The ODP Corporation",
    actionType: "cash_acquisition",
    effectiveDate: "2025-12-10",
    consideration: Object.freeze({
      type: "cash",
      amountPerShare: 28.00,
      additionalCashPerShare: 0,
      totalCashEntitlementPerShare: 28.00,
      currency: "USD"
    }),
    publicShareScope: "non_excluded_public_common_shares",
    sources: Object.freeze([
      "https://www.sec.gov/Archives/edgar/data/800240/000119312525314368/d76250d8k.htm"
    ])
  })
]);

export const manager13fStockConversions = Object.freeze([
  Object.freeze({
    id: "arch-resources-core-natural-resources-2025",
    cusip: "03940R107",
    ticker: "ARCH",
    issuer: "Arch Resources, Inc.",
    actionType: "stock_conversion",
    effectiveDate: "2025-01-14",
    successorFirstTradingDate: "2025-01-15",
    consideration: Object.freeze({
      type: "stock",
      successorTicker: "CNR",
      successorSharesPerShare: 1.326
    }),
    publicShareScope: "non_excluded_public_common_shares",
    sources: Object.freeze([
      "https://www.sec.gov/Archives/edgar/data/1037676/000110465925003782/tm252363d1_8k.htm"
    ])
  }),
  Object.freeze({
    id: "roku-fox-2026",
    cusip: "77543R102",
    ticker: "ROKU",
    issuer: "Roku, Inc.",
    actionType: "stock_and_cash_conversion",
    legalCompletionDate: "2026-11-06",
    effectiveDate: "2026-11-09",
    successorFirstTradingDate: "2026-11-09",
    consideration: Object.freeze({
      type: "stock_and_cash",
      successorTicker: "FOXA",
      successorSharesPerShare: 0.9799,
      amountPerShare: 95.30,
      additionalCashPerShare: 0,
      totalCashEntitlementPerShare: 95.30,
      currency: "USD"
    }),
    publicShareScope: "non_excluded_public_common_shares",
    sources: Object.freeze([
      "https://www.sec.gov/Archives/edgar/data/1428439/000119312526451874/d181620d8k.htm",
      "https://www.sec.gov/Archives/edgar/data/1428439/000135445726001058/xslF25X02/primary_doc.xml"
    ])
  })
]);

export const manager13fCorporateActions = Object.freeze([
  ...manager13fCashAcquisitions,
  ...manager13fStockConversions
]);

function canonicalAction(action) {
  return {
    id: String(action?.id || "").trim(),
    cusip: normalizedCusip(action?.cusip),
    ticker: normalizedTicker(action?.ticker),
    effectiveDate: validIsoDate(action?.effectiveDate),
    publicTradingEndExclusive: validIsoDate(action?.publicTradingEndExclusive),
    actionType: String(action?.actionType || "").trim(),
    considerationType: String(action?.consideration?.type || "").trim(),
    amountPerShare: validCashPrice(action?.consideration?.amountPerShare),
    additionalCashPerShare: Number(action?.consideration?.additionalCashPerShare || 0),
    totalCashEntitlementPerShare: validCashPrice(
      action?.consideration?.totalCashEntitlementPerShare
    ),
    currency: String(action?.consideration?.currency || "").trim().toUpperCase(),
    publicShareScope: String(action?.publicShareScope || "").trim(),
    sources: [...(action?.sources || [])].map((source) => String(source))
  };
}

export const manager13fCorporateActionCatalogVersion = (() => {
  const digest = createHash("sha256")
    .update(JSON.stringify(manager13fCorporateActions.map((action) => ({
      ...canonicalAction(action),
      successorTicker: normalizedTicker(action?.consideration?.successorTicker),
      successorSharesPerShare: Number(action?.consideration?.successorSharesPerShare),
      successorFirstTradingDate: validIsoDate(action?.successorFirstTradingDate)
    }))))
    .digest("hex")
    .slice(0, 16);
  return `manager13f-corporate-actions-v1-${digest}`;
})();

function isAuditedPublicCashAcquisition(action) {
  const row = canonicalAction(action);
  const publicTradingEndExclusive = row.publicTradingEndExclusive || row.effectiveDate;
  const considerationReconciles = Number.isFinite(row.additionalCashPerShare) &&
    row.additionalCashPerShare >= 0 &&
    row.totalCashEntitlementPerShare != null &&
    Math.abs(
      row.amountPerShare + row.additionalCashPerShare -
      row.totalCashEntitlementPerShare
    ) < 1e-9;
  return row.id &&
    row.cusip.length === 9 &&
    row.effectiveDate &&
    publicTradingEndExclusive >= row.effectiveDate &&
    row.actionType === "cash_acquisition" &&
    row.considerationType === "cash" &&
    row.amountPerShare != null &&
    considerationReconciles &&
    row.currency.length === 3 &&
    row.publicShareScope === "non_excluded_public_common_shares" &&
    row.sources.length >= 1;
}

function cashConversionDate(action) {
  return validIsoDate(action?.publicTradingEndExclusive) ||
    validIsoDate(action?.effectiveDate);
}

function isAuditedPublicStockConversion(action) {
  const cusip = normalizedCusip(action?.cusip);
  const effectiveDate = validIsoDate(action?.effectiveDate);
  const successorFirstTradingDate = validIsoDate(action?.successorFirstTradingDate);
  const successorTicker = normalizedTicker(action?.consideration?.successorTicker);
  const successorSharesPerShare = Number(
    action?.consideration?.successorSharesPerShare
  );
  const isPureStock = action?.actionType === "stock_conversion" &&
    action?.consideration?.type === "stock";
  const row = canonicalAction(action);
  const isMixedStockAndCash = action?.actionType === "stock_and_cash_conversion" &&
    action?.consideration?.type === "stock_and_cash" &&
    row.amountPerShare != null &&
    Number.isFinite(row.additionalCashPerShare) &&
    row.additionalCashPerShare >= 0 &&
    row.totalCashEntitlementPerShare != null &&
    Math.abs(
      row.amountPerShare + row.additionalCashPerShare -
      row.totalCashEntitlementPerShare
    ) < 1e-9 &&
    row.currency.length === 3;
  return String(action?.id || "").trim() &&
    cusip.length === 9 &&
    effectiveDate &&
    successorFirstTradingDate >= effectiveDate &&
    (isPureStock || isMixedStockAndCash) &&
    successorTicker &&
    Number.isFinite(successorSharesPerShare) &&
    successorSharesPerShare > 0 &&
    action?.publicShareScope === "non_excluded_public_common_shares" &&
    Array.isArray(action?.sources) &&
    action.sources.length >= 1;
}

/**
 * Resolve an exact public-common-share cash acquisition. Private rollover,
 * stock consideration, ambiguous ticker-only rows, and unverified records
 * intentionally return null and therefore retain the normal fail-closed path.
 */
export function cashAcquisitionForHolding(
  holding,
  {
    actions = manager13fCorporateActions,
    holderHasPrivateRollover = false
  } = {}
) {
  if (holderHasPrivateRollover) return null;
  const cusip = normalizedCusip(holding?.cusip);
  if (cusip.length !== 9) return null;
  return (actions || []).find((action) =>
    isAuditedPublicCashAcquisition(action) &&
    normalizedCusip(action.cusip) === cusip
  ) || null;
}

export function preExecutionCashAcquisition(
  holding,
  { reportDate, executionDate, actions, holderHasPrivateRollover = false } = {}
) {
  const action = cashAcquisitionForHolding(holding, {
    actions,
    holderHasPrivateRollover
  });
  const report = validIsoDate(reportDate);
  const execution = validIsoDate(executionDate);
  if (!action || !report || !execution) return null;
  return action.effectiveDate > report && cashConversionDate(action) <= execution
    ? action
    : null;
}

export function activeCashAcquisition(
  holding,
  { executionDate, actions, holderHasPrivateRollover = false } = {}
) {
  const action = cashAcquisitionForHolding(holding, {
    actions,
    holderHasPrivateRollover
  });
  const execution = validIsoDate(executionDate);
  if (!action || !execution) return null;
  return cashConversionDate(action) > execution ? action : null;
}

export function stockConversionForHolding(
  holding,
  {
    actions = manager13fCorporateActions,
    holderHasPrivateRollover = false
  } = {}
) {
  if (holderHasPrivateRollover) return null;
  const cusip = normalizedCusip(holding?.cusip);
  if (cusip.length !== 9) return null;
  return (actions || []).find((action) =>
    isAuditedPublicStockConversion(action) &&
    normalizedCusip(action.cusip) === cusip
  ) || null;
}

export function preExecutionStockConversion(
  holding,
  { reportDate, executionDate, actions, holderHasPrivateRollover = false } = {}
) {
  const action = stockConversionForHolding(holding, {
    actions,
    holderHasPrivateRollover
  });
  const report = validIsoDate(reportDate);
  const execution = validIsoDate(executionDate);
  if (!action || !report || !execution) return null;
  return action.effectiveDate > report && action.effectiveDate <= execution
    ? action
    : null;
}

export function activeStockConversion(
  holding,
  { executionDate, actions, holderHasPrivateRollover = false } = {}
) {
  const action = stockConversionForHolding(holding, {
    actions,
    holderHasPrivateRollover
  });
  const execution = validIsoDate(executionDate);
  if (!action || !execution) return null;
  return action.effectiveDate > execution ? action : null;
}

export function compactCashAcquisitionResolution(action, holding = {}) {
  if (!isAuditedPublicCashAcquisition(action)) return null;
  const shares = Number(holding?.shares);
  const amountPerShare = Number(action.consideration.amountPerShare);
  const additionalCashPerShare = Number(
    action.consideration.additionalCashPerShare || 0
  );
  const totalCashEntitlementPerShare = Number(
    action.consideration.totalCashEntitlementPerShare
  );
  return {
    actionId: action.id,
    actionType: action.actionType,
    cusip: normalizedCusip(action.cusip),
    ticker: normalizedTicker(holding?.ticker || action.ticker) || null,
    issuer: holding?.issuer || action.issuer,
    effectiveDate: action.effectiveDate,
    publicTradingEndExclusive: cashConversionDate(action),
    considerationType: "cash",
    terminalCashPrice: amountPerShare,
    additionalCashPerShare,
    terminalCashEntitlementPerShare: totalCashEntitlementPerShare,
    currency: action.consideration.currency,
    publicShareScope: action.publicShareScope,
    // This is audit context only. The pre-execution allocator preserves the
    // reported-book weight rather than manufacturing a pre-disclosure return.
    terminalCashProceeds: Number.isFinite(shares) && shares > 0
      ? shares * totalCashEntitlementPerShare
      : null,
    sources: [...action.sources]
  };
}

export function compactStockConversionResolution(action, holding = {}) {
  if (!isAuditedPublicStockConversion(action)) return null;
  const considerationType = String(action.consideration.type || "stock");
  const isMixed = considerationType === "stock_and_cash";
  const amountPerShare = isMixed
    ? Number(action.consideration.amountPerShare)
    : null;
  const additionalCashPerShare = isMixed
    ? Number(action.consideration.additionalCashPerShare || 0)
    : null;
  const totalCashEntitlementPerShare = isMixed
    ? Number(action.consideration.totalCashEntitlementPerShare)
    : null;
  return {
    actionId: action.id,
    actionType: action.actionType,
    cusip: normalizedCusip(action.cusip),
    ticker: normalizedTicker(holding?.ticker || action.ticker) || null,
    issuer: holding?.issuer || action.issuer,
    ...(action.legalCompletionDate
      ? { legalCompletionDate: action.legalCompletionDate }
      : {}),
    effectiveDate: action.effectiveDate,
    considerationType,
    successorTicker: normalizedTicker(action.consideration.successorTicker),
    successorSharesPerShare: Number(
      action.consideration.successorSharesPerShare
    ),
    ...(isMixed
      ? {
          terminalCashPrice: amountPerShare,
          additionalCashPerShare,
          terminalCashEntitlementPerShare: totalCashEntitlementPerShare,
          currency: action.consideration.currency
        }
      : {}),
    successorFirstTradingDate: action.successorFirstTradingDate,
    publicShareScope: action.publicShareScope,
    sources: [...action.sources]
  };
}
