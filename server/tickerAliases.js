import { sp500CanonicalTicker } from "./sp500ValuationUniverse.js";

const explicitLondonAliases = new Map([
  ["AZNL", { valuation: "AZN", market: "AZN.L", display: "AZN.L" }],
  ["AZN.L", { valuation: "AZN", market: "AZN.L", display: "AZN.L" }],
  ["LSEGL", { valuation: "LSEG", market: "LSEG.L", display: "LSEG.L" }],
  ["LSEG.L", { valuation: "LSEG", market: "LSEG.L", display: "LSEG.L" }]
]);

const valuationMarketAliases = new Map([
  ["AZN", "AZN.L"],
  ["LSEG", "LSEG.L"]
]);

export function normalizeTicker(value) {
  return String(value || "").trim().toUpperCase().replace(/[^A-Z0-9.-]/g, "");
}

export function isSterlingCurrency(value) {
  const raw = String(value || "").trim();
  const compact = raw.replace(/[^A-Za-z]/g, "").toUpperCase();
  return (
    compact === "GBP" ||
    compact === "GBX" ||
    compact === "GBPENCE" ||
    compact === "PENCE" ||
    compact === "PENNY" ||
    raw === "GBp"
  );
}

function pushUnique(values, value) {
  const normalized = normalizeTicker(value);
  if (normalized && !values.includes(normalized)) values.push(normalized);
}

function trailingLondonCandidate(ticker) {
  if (!ticker || ticker.includes(".") || !ticker.endsWith("L") || ticker.length < 4) return "";
  return `${ticker.slice(0, -1)}.L`;
}

function likelyLondonListing(currency, companyName) {
  const companyText = String(companyName || "").toUpperCase();
  return (
    isSterlingCurrency(currency) ||
    /LONDON STOCK EXCHANGE|ASTRAZENECA/.test(companyText)
  );
}

export function londonMarketTicker(value, { currency = "", companyName = "" } = {}) {
  const ticker = normalizeTicker(value);
  if (!ticker) return "";
  const explicit = explicitLondonAliases.get(ticker);
  if (explicit) return explicit.market;
  if (ticker.endsWith(".L")) return ticker;

  const likelyLondon = likelyLondonListing(currency, companyName);
  const trailingCandidate = trailingLondonCandidate(ticker);
  if (trailingCandidate && likelyLondon) return trailingCandidate;
  if (likelyLondon) return `${ticker}.L`;
  return ticker;
}

export function portfolioDisplayTicker(value, { currency = "", companyName = "" } = {}) {
  const ticker = normalizeTicker(value);
  if (!ticker) return "";
  const explicit = explicitLondonAliases.get(ticker);
  if (explicit) return explicit.display;
  return londonMarketTicker(ticker, { currency, companyName });
}

export function valuationTickerCandidates(value, { currency = "", companyName = "" } = {}) {
  const ticker = normalizeTicker(value);
  const candidates = [];
  if (!ticker) return candidates;
  pushUnique(candidates, ticker);
  pushUnique(candidates, sp500CanonicalTicker(ticker));

  const explicit = explicitLondonAliases.get(ticker);
  if (explicit) {
    pushUnique(candidates, explicit.valuation);
    pushUnique(candidates, explicit.market);
  }

  if (ticker.endsWith(".L")) {
    pushUnique(candidates, ticker.slice(0, -2));
  } else {
    const trailingCandidate = trailingLondonCandidate(ticker);
    const likelyLondon = likelyLondonListing(currency, companyName);
    if (trailingCandidate && likelyLondon) {
      pushUnique(candidates, trailingCandidate);
      pushUnique(candidates, trailingCandidate.slice(0, -2));
    }
    if (likelyLondon) {
      pushUnique(candidates, `${ticker}.L`);
    }
  }

  return candidates;
}

export function marketTickerCandidates(value, { currency = "", companyName = "" } = {}) {
  const ticker = normalizeTicker(value);
  const candidates = [];
  if (!ticker) return candidates;

  const market = londonMarketTicker(ticker, { currency, companyName });
  pushUnique(candidates, market);
  pushUnique(candidates, ticker);

  if (market.endsWith(".L")) pushUnique(candidates, market.slice(0, -2));
  if (ticker.endsWith(".L")) pushUnique(candidates, ticker.slice(0, -2));

  const trailingCandidate = trailingLondonCandidate(ticker);
  if (trailingCandidate && likelyLondonListing(currency, companyName)) {
    pushUnique(candidates, trailingCandidate);
    pushUnique(candidates, trailingCandidate.slice(0, -2));
  }

  return candidates;
}

export function valuationLookupKeysForSnapshot(snapshot = {}) {
  const ticker = normalizeTicker(snapshot.ticker || snapshot.key);
  const keys = [];
  pushUnique(keys, ticker);
  pushUnique(keys, sp500CanonicalTicker(ticker));
  const explicit = explicitLondonAliases.get(ticker);
  if (explicit) {
    pushUnique(keys, explicit.valuation);
    pushUnique(keys, explicit.market);
    pushUnique(keys, explicit.display);
  }
  if (String(snapshot.currency || "").toUpperCase() === "GBP") {
    const base = ticker.endsWith(".L") ? ticker.slice(0, -2) : ticker;
    pushUnique(keys, `${base}.L`);
    pushUnique(keys, `${base}L`);
  }
  return keys;
}

export function valuationMarketPriceSymbol(value) {
  const ticker = normalizeTicker(value);
  if (!ticker) return "";
  return valuationMarketAliases.get(ticker) || ticker;
}
