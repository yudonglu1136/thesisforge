import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { stat } from "node:fs/promises";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const PRICE_TYPES = Object.freeze({
  RAW_CLOSE: "RAW_CLOSE",
  SPLIT_ADJUSTED_CLOSE: "SPLIT_ADJUSTED_CLOSE",
  TOTAL_RETURN_ADJUSTED_CLOSE: "TOTAL_RETURN_ADJUSTED_CLOSE"
});

// Explicit operator rollback only. Missing local data never enables old providers.
let rollbackAnnounced = false;
export function factOsEnabled() {
  const enabled = process.env.FACT_OS_ENABLED !== "0";
  if (!enabled && !rollbackAnnounced) {
    console.warn("[fact-os] Direct Fact OS reader disabled; only released SQLite data is allowed. Network/legacy provider fallback remains disabled.");
    rollbackAnnounced = true;
  }
  return enabled;
}

export class FactDataError extends Error {
  constructor(code, message) { super(message); this.name = "FactDataError"; this.code = code; }
}

// Preserve the broker's exact listing. Display/logo aliases and company names
// cannot prove that a foreign ordinary share is the corresponding US ADR.
export function canonicalListingRequest(holding) {
  const item = typeof holding === "string" ? { ticker: holding } : holding || {};
  const ticker = String(item.ticker || item.symbol || "").trim().toUpperCase();
  const quoteCurrency = String(item.quoteCurrency || item.priceCurrency || item.tradingCurrency || item.instrumentCurrency || item.currency || "").trim().toUpperCase();
  const unavailable = !ticker || !/^[A-Z0-9.-]+$/.test(ticker) ? "unverified_listing"
    : quoteCurrency && quoteCurrency !== "USD" ? "unverified_quote_currency" : null;
  // An explicit USD quote currency takes precedence over the account/display
  // currency. The repository must still resolve this exact ticker officially.
  return { ticker, quoteCurrency: quoteCurrency || null, unavailable };
}

let queue = Promise.resolve();
let cachedGeneration = "";
let cachedBytes = 0;
const readCache = new Map();
const requestKey = (request) => JSON.stringify(request);
async function refreshGeneration() {
  const root = path.resolve(process.env.FACT_OS_ROOT || path.join(projectRoot, "data/fact_os"));
  try {
    const info = await stat(path.join(root, "manifests/catalog.json"));
    const generation = `${root}:${info.mtimeMs}:${info.size}:${process.env.FACT_OS_PYTHON || "default"}`;
    if (generation !== cachedGeneration) { readCache.clear(); cachedBytes = 0; cachedGeneration = generation; }
  } catch { readCache.clear(); cachedBytes = 0; cachedGeneration = ""; }
}

function cacheResponse(request, response) {
  if (!cachedGeneration) return;
  const key = requestKey(request);
  const bytes = Buffer.byteLength(JSON.stringify(response));
  if (bytes > 16 * 1024 * 1024) return;
  while (readCache.size && (readCache.size >= 512 || cachedBytes + bytes > 64 * 1024 * 1024)) {
    const first = readCache.keys().next().value;
    cachedBytes -= readCache.get(first).bytes; readCache.delete(first);
  }
  if (readCache.has(key)) cachedBytes -= readCache.get(key).bytes;
  readCache.set(key, { response, bytes }); cachedBytes += bytes;
}

export function queryFacts(method, args = [], kwargs = {}) {
  // Bound concurrent scans and open a fresh immutable generation for each request.
  const request = { method, args, kwargs };
  const result = queue.then(async () => {
    await refreshGeneration();
    const cached = readCache.get(requestKey(request))?.response;
    if (cached) {
      if (!cached.ok) throw new FactDataError(cached.error.code, cached.error.message);
      return structuredClone(cached.result);
    }
    const result = await runRequest(request);
    cacheResponse(request, { ok: true, result });
    return structuredClone(result);
  });
  queue = result.catch(() => {});
  return result;
}

export function queryFactsBatch(requests) {
  const normalized = requests.map((r) => ({ method: r.method, args: r.args || [], kwargs: r.kwargs || {} }));
  const result = queue.then(async () => {
    await refreshGeneration();
    const generation = cachedGeneration;
    const responses = normalized.map((r) => readCache.get(requestKey(r))?.response);
    const missing = normalized.map((r, i) => ({ request: r, index: i })).filter(({ index }) => !responses[index]);
    for (let i = 0; i < missing.length; i += 256) {
      const group = missing.slice(i, i + 256);
      const values = await runRequest({ batch: group.map((entry) => entry.request) });
      values.forEach((value, j) => { responses[group[j].index] = value; cacheResponse(group[j].request, value); });
    }
    await refreshGeneration();
    if (generation && generation !== cachedGeneration) throw new FactDataError("local_snapshot_changed", "A new local data generation was published during the batch; retry to use a single consistent generation.");
    return structuredClone(responses);
  });
  queue = result.catch(() => {});
  return result;
}

function runRequest(request) {
  return new Promise((resolve, reject) => {
    const root = path.resolve(process.env.FACT_OS_ROOT || path.join(projectRoot, "data/fact_os"));
    const python = process.env.FACT_OS_PYTHON || path.join(projectRoot, ".venv-fact-os/bin/python");
    const child = spawn(python, ["-m", "fact_os.rpc", "--root", root], {
      cwd: projectRoot,
      // Provider keys and private user credentials are not inherited by readers.
      env: { PATH: process.env.PATH || "/usr/bin:/bin", PYTHONUNBUFFERED: "1", LANG: "en_US.UTF-8" },
      stdio: ["pipe", "pipe", "pipe"]
    });
    let output = ""; let finished = false;
    const finish = (error, value) => {
      if (finished) return;
      finished = true; clearTimeout(timer);
      if (error) reject(error); else resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill();
      finish(new FactDataError("local_query_timeout", "Local Fact OS query timed out; no provider fallback was used."));
    }, 120_000);
    child.stdout.on("data", (data) => {
      output += data;
      if (Buffer.byteLength(output) > 64 * 1024 * 1024) {
        child.kill(); finish(new FactDataError("local_result_too_large", "Narrow the local data query."));
      }
    });
    child.stderr.resume(); // Never return subprocess paths, environment, or traceback to clients.
    child.on("error", () => finish(new FactDataError("local_runtime_unavailable", "Fact OS Python runtime is unavailable. Run the local setup before starting the app.")));
    child.on("close", (code) => {
      if (finished) return;
      try {
        const response = JSON.parse(output);
        if (response.ok) finish(null, response.result);
        else finish(new FactDataError(response.error?.code || "local_data_unavailable", response.error?.message || "Local data is unavailable; sync separately."));
      } catch {
        finish(new FactDataError("local_query_failed", `Local Fact OS could not complete this read (${code ?? "interrupted"}). No legacy data was substituted.`));
      }
    });
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(request));
  });
}
