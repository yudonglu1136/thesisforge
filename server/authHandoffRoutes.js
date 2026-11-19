import crypto from "node:crypto";
import { verifySupabaseAccessToken } from "./auth/verifyAuth.js";

const DEFAULT_HANDOFF_TTL_MS = 10 * 60 * 1000;
const DEFAULT_PAIR_CODE_TTL_MS = 5 * 60 * 1000;
const MAX_ACTIVE_RECORDS = 512;
const RATE_WINDOW_MS = 10 * 60 * 1000;
const MAX_STARTS_PER_WINDOW = 12;
const MAX_FAILED_REDEEMS_PER_WINDOW = 8;

const PRODUCTION_ALLOWED_ORIGINS = new Set([
  "https://thesisforge.tech",
  "https://www.thesisforge.tech"
]);

function timingSafeStringEqual(left, right) {
  const leftBuf = Buffer.from(String(left || ""), "utf8");
  const rightBuf = Buffer.from(String(right || ""), "utf8");
  if (leftBuf.length === 0 || leftBuf.length !== rightBuf.length) return false;
  return crypto.timingSafeEqual(leftBuf, rightBuf);
}

function normalizeEmail(raw) {
  const email = String(raw || "").trim().toLowerCase();
  if (!email || email.length > 254) return "";
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return "";
  return email;
}

function resolveAllowedRedirectOrigin(rawOrigin, headerOrigin) {
  const candidate = String(rawOrigin || headerOrigin || "https://www.thesisforge.tech")
    .trim()
    .replace(/\/$/, "");
  if (PRODUCTION_ALLOWED_ORIGINS.has(candidate)) {
    return candidate;
  }
  if (
    process.env.NODE_ENV !== "production" &&
    /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(candidate)
  ) {
    return candidate;
  }
  return "https://www.thesisforge.tech";
}

function clientIpKey(request) {
  const forwarded = String(request.headers?.["x-forwarded-for"] || "")
    .split(",")[0]
    .trim();
  return forwarded || String(request.ip || request.socket?.remoteAddress || "unknown");
}

function extractBearerToken(headerValue) {
  if (typeof headerValue !== "string") return "";
  const match = headerValue.match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : "";
}

export function createAuthHandoffService({
  verifyAccessToken = verifySupabaseAccessToken,
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
  handoffTtlMs = DEFAULT_HANDOFF_TTL_MS,
  pairCodeTtlMs = DEFAULT_PAIR_CODE_TTL_MS
} = {}) {
  const cipherKey = crypto.randomBytes(32);
  const handoffById = new Map();
  const pairByCode = new Map();
  const startAttemptsByIp = new Map();
  const failedRedeemsByIp = new Map();

  function sealPayload(payload) {
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv("aes-256-gcm", cipherKey, iv);
    const plaintext = Buffer.from(JSON.stringify(payload), "utf8");
    const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    const tag = cipher.getAuthTag();
    return { iv, encrypted, tag };
  }

  function openPayload(sealed) {
    const decipher = crypto.createDecipheriv("aes-256-gcm", cipherKey, sealed.iv);
    decipher.setAuthTag(sealed.tag);
    const decrypted = Buffer.concat([
      decipher.update(sealed.encrypted),
      decipher.final()
    ]);
    return JSON.parse(decrypted.toString("utf8"));
  }

  function pruneExpired(currentNow = now()) {
    for (const [id, record] of handoffById.entries()) {
      if (record.expiresAt <= currentNow) {
        handoffById.delete(id);
        if (record.pairCode) pairByCode.delete(record.pairCode);
      }
    }
    for (const [code, record] of pairByCode.entries()) {
      if (record.expiresAt <= currentNow) {
        pairByCode.delete(code);
      }
    }
    for (const bucket of [startAttemptsByIp, failedRedeemsByIp]) {
      for (const [ip, entry] of bucket.entries()) {
        if (entry.resetAt <= currentNow) bucket.delete(ip);
      }
    }
  }

  function evictIfNeeded(map) {
    while (map.size >= MAX_ACTIVE_RECORDS) {
      const oldestKey = map.keys().next().value;
      if (oldestKey === undefined) break;
      const removed = map.get(oldestKey);
      map.delete(oldestKey);
      if (removed?.pairCode) pairByCode.delete(removed.pairCode);
    }
  }

  function checkCounter(bucket, key, limit, currentNow = now()) {
    const existing = bucket.get(key);
    if (!existing || existing.resetAt <= currentNow) {
      return { allowed: true, count: 0 };
    }
    return { allowed: existing.count < limit, count: existing.count };
  }

  function incrementCounter(bucket, key, currentNow = now()) {
    const existing = bucket.get(key);
    if (!existing || existing.resetAt <= currentNow) {
      bucket.set(key, { count: 1, resetAt: currentNow + RATE_WINDOW_MS });
      return 1;
    }
    existing.count += 1;
    return existing.count;
  }

  function generateUniquePairCode() {
    for (let attempt = 0; attempt < 32; attempt += 1) {
      const code = String(crypto.randomInt(100000, 1000000));
      if (!pairByCode.has(code)) return code;
    }
    throw new Error("Unable to allocate unique 6-digit pairing code");
  }

  function burnRecord(record) {
    if (!record) return;
    if (record.handoffId) handoffById.delete(record.handoffId);
    if (record.pairCode) pairByCode.delete(record.pairCode);
  }

  async function startEmailHandoff({ email: rawEmail, origin, headerOrigin, ip }) {
    const currentNow = now();
    pruneExpired(currentNow);

    const email = normalizeEmail(rawEmail);
    if (!email) {
      return {
        httpStatus: 400,
        body: { ok: false, error: "invalid_email", message: "Valid email is required." }
      };
    }

    if (!checkCounter(startAttemptsByIp, ip, MAX_STARTS_PER_WINDOW, currentNow).allowed) {
      return {
        httpStatus: 429,
        body: {
          ok: false,
          error: "rate_limited",
          message: "Too many sign-in code requests. Please wait a few minutes."
        }
      };
    }

    const supabaseUrl = String(process.env.SUPABASE_URL || "").trim().replace(/\/$/, "");
    const anonKey = String(process.env.SUPABASE_ANON_KEY || "").trim();
    if (!supabaseUrl || !anonKey) {
      return {
        httpStatus: 503,
        body: {
          ok: false,
          error: "auth_not_configured",
          message: "Supabase auth environment is not configured."
        }
      };
    }

    incrementCounter(startAttemptsByIp, ip, currentNow);
    evictIfNeeded(handoffById);

    const handoffId = crypto.randomBytes(18).toString("base64url");
    const pollSecret = crypto.randomBytes(24).toString("base64url");
    const pairCode = generateUniquePairCode();
    const safeOrigin = resolveAllowedRedirectOrigin(origin, headerOrigin);
    const redirectTo = `${safeOrigin}/?auth_handoff=${encodeURIComponent(handoffId)}`;

    const otpEndpoint = `${supabaseUrl}/auth/v1/otp?redirect_to=${encodeURIComponent(redirectTo)}`;
    let otpResponse;
    try {
      otpResponse = await fetchImpl(otpEndpoint, {
        method: "POST",
        headers: {
          accept: "application/json",
          apikey: anonKey,
          "content-type": "application/json"
        },
        body: JSON.stringify({
          email,
          create_user: true
        })
      });
    } catch {
      return {
        httpStatus: 503,
        body: {
          ok: false,
          error: "supabase_unreachable",
          message: "Unable to reach authentication service."
        }
      };
    }

    if (!otpResponse.ok) {
      const status = otpResponse.status === 429 ? 429 : 400;
      let detail = "Could not send sign-in email.";
      try {
        const errJson = await otpResponse.json();
        detail = String(errJson?.msg || errJson?.error_description || errJson?.message || detail);
      } catch {
        // Ignore non-JSON upstream body
      }
      return {
        httpStatus: status,
        body: {
          ok: false,
          error: status === 429 ? "email_rate_limited" : "otp_send_failed",
          message: detail
        }
      };
    }

    const expiresAt = currentNow + handoffTtlMs;
    handoffById.set(handoffId, {
      handoffId,
      pollSecret,
      pairCode,
      email,
      source: "handoff",
      createdAt: currentNow,
      expiresAt,
      completedAt: null,
      sealedSession: null
    });

    return {
      httpStatus: 200,
      body: {
        ok: true,
        handoffId,
        pollSecret,
        expiresIn: Math.round(handoffTtlMs / 1000)
      }
    };
  }

  async function completeEmailHandoff({ handoffId, accessToken, refreshToken }) {
    const currentNow = now();
    pruneExpired(currentNow);

    const id = String(handoffId || "").trim();
    const token = String(accessToken || "").trim();
    const refresh = String(refreshToken || "").trim();
    if (!id || !token || refresh.length < 8) {
      return {
        httpStatus: 400,
        body: { ok: false, error: "invalid_handoff_payload", message: "Missing handoff tokens." }
      };
    }

    const record = handoffById.get(id);
    if (!record || record.expiresAt <= currentNow) {
      burnRecord(record);
      return {
        httpStatus: 404,
        body: {
          ok: false,
          error: "handoff_expired",
          message: "This sign-in request has expired or was already used."
        }
      };
    }

    const verification = await verifyAccessToken(token);
    if (!verification?.ok || !verification.user?.email) {
      return {
        httpStatus: 401,
        body: { ok: false, error: "invalid_token", message: "Invalid access token." }
      };
    }

    const verifiedEmail = normalizeEmail(verification.user.email);
    if (verifiedEmail !== record.email) {
      return {
        httpStatus: 403,
        body: {
          ok: false,
          error: "email_mismatch",
          message: "Verified account email does not match requested email."
        }
      };
    }

    record.completedAt = currentNow;
    record.sealedSession = sealPayload({
      accessToken: token,
      refreshToken: refresh,
      email: verifiedEmail
    });
    pairByCode.set(record.pairCode, record);

    return {
      httpStatus: 200,
      body: {
        ok: true,
        pairCode: record.pairCode,
        email: verifiedEmail,
        expiresIn: Math.max(1, Math.round((record.expiresAt - currentNow) / 1000))
      }
    };
  }

  function pollEmailHandoff({ handoffId, pollSecret }) {
    const currentNow = now();
    pruneExpired(currentNow);

    const id = String(handoffId || "").trim();
    const secret = String(pollSecret || "").trim();
    const record = handoffById.get(id);
    if (!record || record.expiresAt <= currentNow) {
      burnRecord(record);
      return {
        httpStatus: 404,
        body: { ok: false, status: "expired", error: "handoff_expired" }
      };
    }
    if (!timingSafeStringEqual(secret, record.pollSecret)) {
      return {
        httpStatus: 403,
        body: { ok: false, status: "forbidden", error: "invalid_poll_secret" }
      };
    }
    if (!record.sealedSession) {
      return {
        httpStatus: 200,
        body: {
          ok: true,
          status: "pending",
          expiresIn: Math.max(1, Math.round((record.expiresAt - currentNow) / 1000))
        }
      };
    }

    const session = openPayload(record.sealedSession);
    burnRecord(record);
    return {
      httpStatus: 200,
      body: {
        ok: true,
        status: "completed",
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        email: session.email
      }
    };
  }

  function createDevicePairCode({ user, accessToken, refreshToken }) {
    const currentNow = now();
    pruneExpired(currentNow);

    const email = normalizeEmail(user?.email);
    const token = String(accessToken || "").trim();
    const refresh = String(refreshToken || "").trim();
    if (!email || !token || refresh.length < 8) {
      return {
        httpStatus: 400,
        body: {
          ok: false,
          error: "invalid_session_payload",
          message: "Active session refresh token is required to create a pairing code."
        }
      };
    }

    evictIfNeeded(pairByCode);
    const pairCode = generateUniquePairCode();
    const expiresAt = currentNow + pairCodeTtlMs;
    const record = {
      handoffId: null,
      pollSecret: null,
      pairCode,
      email,
      source: "device_pair",
      createdAt: currentNow,
      expiresAt,
      completedAt: currentNow,
      sealedSession: sealPayload({
        accessToken: token,
        refreshToken: refresh,
        email
      })
    };
    pairByCode.set(pairCode, record);

    return {
      httpStatus: 200,
      body: {
        ok: true,
        pairCode,
        email,
        expiresIn: Math.round(pairCodeTtlMs / 1000)
      }
    };
  }

  function redeemPairCode({ pairCode, email: rawEmail, ip }) {
    const currentNow = now();
    pruneExpired(currentNow);

    if (!checkCounter(failedRedeemsByIp, ip, MAX_FAILED_REDEEMS_PER_WINDOW, currentNow).allowed) {
      return {
        httpStatus: 429,
        body: {
          ok: false,
          error: "rate_limited",
          message: "Too many invalid verification attempts. Please wait 10 minutes."
        }
      };
    }

    const cleanCode = String(pairCode || "").replace(/\s+/g, "");
    if (!/^\d{6}$/.test(cleanCode)) {
      incrementCounter(failedRedeemsByIp, ip, currentNow);
      return {
        httpStatus: 400,
        body: { ok: false, error: "invalid_code_format", message: "Enter a 6-digit numeric code." }
      };
    }

    const record = pairByCode.get(cleanCode);
    if (!record || !record.sealedSession || record.expiresAt <= currentNow) {
      burnRecord(record);
      incrementCounter(failedRedeemsByIp, ip, currentNow);
      return {
        httpStatus: 401,
        body: {
          ok: false,
          error: "code_invalid_or_expired",
          message: "Verification code is invalid or expired."
        }
      };
    }

    const optionalEmail = String(rawEmail || "").trim().toLowerCase();
    if (
      record.source === "handoff" &&
      optionalEmail &&
      optionalEmail !== record.email
    ) {
      incrementCounter(failedRedeemsByIp, ip, currentNow);
      return {
        httpStatus: 401,
        body: {
          ok: false,
          error: "code_email_mismatch",
          message: "Code does not match the entered email address."
        }
      };
    }

    const session = openPayload(record.sealedSession);
    burnRecord(record);
    return {
      httpStatus: 200,
      body: {
        ok: true,
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        email: session.email
      }
    };
  }

  return {
    startEmailHandoff,
    completeEmailHandoff,
    pollEmailHandoff,
    createDevicePairCode,
    redeemPairCode
  };
}

const defaultAuthHandoffService = createAuthHandoffService();

export function mountPublicAuthHandoffRoutes(app, service = defaultAuthHandoffService) {
  app.post("/api/auth/handoff/start", async (request, response) => {
    response.setHeader("Cache-Control", "no-store");
    const result = await service.startEmailHandoff({
      email: request.body?.email,
      origin: request.body?.origin,
      headerOrigin: request.headers?.origin,
      ip: clientIpKey(request)
    });
    response.status(result.httpStatus).json(result.body);
  });

  app.post("/api/auth/handoff/complete", async (request, response) => {
    response.setHeader("Cache-Control", "no-store");
    const result = await service.completeEmailHandoff({
      handoffId: request.body?.handoffId,
      accessToken: request.body?.accessToken,
      refreshToken: request.body?.refreshToken
    });
    response.status(result.httpStatus).json(result.body);
  });

  app.post("/api/auth/handoff/poll", (request, response) => {
    response.setHeader("Cache-Control", "no-store");
    const result = service.pollEmailHandoff({
      handoffId: request.body?.handoffId,
      pollSecret: request.body?.pollSecret
    });
    response.status(result.httpStatus).json(result.body);
  });

  app.post("/api/auth/pair-code/redeem", (request, response) => {
    response.setHeader("Cache-Control", "no-store");
    const result = service.redeemPairCode({
      pairCode: request.body?.pairCode,
      email: request.body?.email,
      ip: clientIpKey(request)
    });
    response.status(result.httpStatus).json(result.body);
  });
}

export function mountProtectedAuthHandoffRoutes(app, service = defaultAuthHandoffService) {
  app.post("/api/auth/pair-code/create", (request, response) => {
    response.setHeader("Cache-Control", "no-store");
    const accessToken = extractBearerToken(request.headers?.authorization);
    const result = service.createDevicePairCode({
      user: request.user,
      accessToken,
      refreshToken: request.body?.refreshToken
    });
    response.status(result.httpStatus).json(result.body);
  });
}
