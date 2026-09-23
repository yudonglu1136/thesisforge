// Bounded retries for read-only SEC transport failures. Identity, parsing and
// coverage failures are never retryable and never replaced with empty facts.
const transientStatuses = new Set([429, 500, 502, 503, 504]);
const transientCodes = new Set([
  "ECONNRESET", "ETIMEDOUT", "EAI_AGAIN", "UND_ERR_CONNECT_TIMEOUT",
  "UND_ERR_HEADERS_TIMEOUT", "UND_ERR_BODY_TIMEOUT", "UND_ERR_SOCKET"
]);

export function isTransientSecReadError(error) {
  if (error?.name === "AbortError") return false;
  if (error?.status != null) return transientStatuses.has(Number(error.status));
  return ["RequestTimeoutError", "TimeoutError"].includes(error?.name)
    || transientCodes.has(error?.code)
    || transientCodes.has(error?.cause?.code);
}

export async function retrySecRead(read, {
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
} = {}) {
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      return await read();
    } catch (error) {
      const retryAfter = Number(error?.retryAfterMs);
      if (attempt === 3 || !isTransientSecReadError(error)
        || (Number.isFinite(retryAfter) && retryAfter > 30000)) throw error;
      await sleep(Math.max(attempt * 1000,
        Number.isFinite(retryAfter) ? retryAfter : 0));
    }
  }
}
