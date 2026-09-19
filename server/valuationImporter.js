import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadPriceSeries } from "./marketData.js";
import { loadValuationTicker } from "./valuationClient.js";
import { normalizeTicker, valuationTickerCandidates } from "./tickerAliases.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, "..");
const importScriptPath = path.join(__dirname, "importSecQuarterlyValuations.js");
const activeImports = new Map();
const importTimeoutMs = Number(process.env.VALUATION_IMPORT_TIMEOUT_MS || 1000 * 90);

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}

function unique(values) {
  const seen = new Set();
  const result = [];
  for (const value of values) {
    const normalized = normalizeTicker(value);
    if (!normalized || seen.has(normalized)) continue;
    seen.add(normalized);
    result.push(normalized);
  }
  return result;
}

function validateTicker(value) {
  const raw = String(value || "").trim().toUpperCase();
  const normalized = normalizeTicker(raw);
  if (
    !normalized ||
    normalized !== raw ||
    normalized.length > 16 ||
    !/^[A-Z0-9.-]+$/.test(normalized)
  ) {
    const error = new Error("Ticker must contain only letters, numbers, dot, or dash.");
    error.statusCode = 400;
    throw error;
  }
  return normalized;
}

function importTickersFor(inputTicker) {
  const normalized = validateTicker(inputTicker);
  const candidates = valuationTickerCandidates(normalized)
    .flatMap((candidate) => candidate.endsWith(".L") ? [candidate.slice(0, -2), candidate] : [candidate]);
  const normalizedCandidates = unique(candidates.map((candidate) =>
    candidate.endsWith(".L") ? candidate.slice(0, -2) : candidate
  ));
  if (normalizedCandidates.length > 1) {
    const canonicalCandidates = normalizedCandidates.filter((candidate) => candidate !== normalized);
    if (canonicalCandidates.length) return canonicalCandidates;
  }
  return normalizedCandidates;
}

function runImportScript(tickers) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [importScriptPath], {
      cwd: rootDir,
      env: {
        ...process.env,
        SEC_VALUATION_TICKERS: tickers.join(",")
      },
      stdio: ["ignore", "pipe", "pipe"]
    });

    let stdout = "";
    let stderr = "";
    const timeout = setTimeout(() => {
      child.kill("SIGTERM");
      const error = new Error(`Valuation import timed out after ${Math.round(importTimeoutMs / 1000)}s.`);
      error.statusCode = 504;
      reject(error);
    }, importTimeoutMs);

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timeout);
      if (code !== 0) {
        const error = new Error(stderr.trim() || `Valuation import failed with exit code ${code}.`);
        error.statusCode = 502;
        reject(error);
        return;
      }
      try {
        resolve(JSON.parse(stdout));
      } catch {
        resolve({ rawOutput: stdout.trim(), stderr: stderr.trim() });
      }
    });
  });
}

async function warmPriceHistory(tickers) {
  const start = process.env.VALUATION_IMPORT_PRICE_START_DATE || "2014-01-01";
  const end = todayIso();
  const attempts = await Promise.allSettled(
    tickers.map((ticker) => loadPriceSeries(ticker, {
      start,
      end,
      priceType: "RAW_CLOSE"
    }))
  );
  return attempts.map((attempt, index) => ({
    ticker: tickers[index],
    ok: attempt.status === "fulfilled",
    source: attempt.status === "fulfilled" ? attempt.value.source : "unavailable",
    points: attempt.status === "fulfilled" ? attempt.value.points?.length || 0 : 0,
    error: attempt.status === "rejected" ? attempt.reason?.message || String(attempt.reason) : null
  }));
}

async function importValuationTickerNow(inputTicker, options = {}) {
  const requestedTicker = validateTicker(inputTicker);
  const importTickers = importTickersFor(requestedTicker);
  const priceWarmup = await warmPriceHistory(importTickers);
  const importResult = await runImportScript(importTickers);
  const tickerPayload = await loadValuationTicker(requestedTicker, {
    pricePoints: options.pricePoints || 900
  });
  return {
    generatedAt: new Date().toISOString(),
    requestedTicker,
    importTickers,
    priceWarmup,
    importResult,
    ...tickerPayload
  };
}

export async function importValuationTicker(inputTicker, options = {}) {
  const requestedTicker = validateTicker(inputTicker);
  const cacheKey = importTickersFor(requestedTicker).join(",");
  if (activeImports.has(cacheKey)) {
    return activeImports.get(cacheKey);
  }
  const promise = importValuationTickerNow(requestedTicker, options)
    .finally(() => activeImports.delete(cacheKey));
  activeImports.set(cacheKey, promise);
  return promise;
}
