import http from "node:http";
import https from "node:https";
import { isRetiredApiPath } from "../server/retiredProductRoutes.js";

// Explicit platform budget for the existing upstream deadline. The backend
// bounds mixed-strategy workers at 90s; current Hobby Fluid supports 120s.
export const config = { maxDuration: 120 };

const LEGACY_AWS_ORIGIN =
  process.env.AWS_API_ORIGIN ||
  "https://backend.thesisforge.tech";
const PRODUCTION = process.env.NODE_ENV === "production" || process.env.VERCEL_ENV === "production";
const UPSTREAM_HTTPS_AGENT = new https.Agent({
  keepAlive: true,
  maxSockets: 64,
  keepAliveMsecs: 30_000
});

const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade"
]);

const REQUEST_HEADERS = [
  "accept",
  "accept-encoding",
  "accept-language",
  "authorization",
  "content-type",
  "if-none-match",
  "user-agent"
];

export function targetUrl(request, origins = {}) {
  const requestUrl = new URL(request.url, "https://thesisforge.tech");
  const path = request.query?.path;
  if (typeof path !== "string") throw new Error("Invalid API path");
  requestUrl.searchParams.delete("path");
  let normalizedPath = path.startsWith("/") ? path : `/${path}`;
  // Canonicalize before routing and checking the private namespace. Never let
  // an absolute URL, encoded traversal or backslash select another origin.
  for (let depth = 0; depth < 8; depth += 1) {
    const decoded = decodeURIComponent(normalizedPath);
    if (decoded === normalizedPath) break;
    normalizedPath = decoded;
  }
  if (!/^\/api(?:\/|$)/i.test(normalizedPath) || /[\\?#%\x00-\x20\x7f]/.test(normalizedPath)) {
    throw new Error("Invalid API path");
  }
  normalizedPath = new URL(normalizedPath, "https://thesisforge.tech").pathname;
  if (!/^\/api(?:\/|$)/i.test(normalizedPath)) throw new Error("Invalid API path");
  const origin = new URL(origins.legacyOrigin || LEGACY_AWS_ORIGIN);
  if (!["http:", "https:"].includes(origin.protocol) || origin.username || origin.password
      || origin.pathname !== "/" || origin.search || origin.hash) throw new Error("Invalid API origin");
  const target = new URL(normalizedPath, origin);
  if (target.origin !== origin.origin) throw new Error("Invalid API path");
  target.search = requestUrl.searchParams.toString();
  return target;
}

export function isPrivateInternalPath(value) {
  const pathname = value instanceof URL
    ? value.pathname
    : new URL(String(value || "/"), "https://thesisforge.tech").pathname;
  let normalized = pathname;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const decoded = decodeURIComponent(normalized);
      if (decoded === normalized) break;
      normalized = decoded;
    } catch {
      break;
    }
  }
  normalized = normalized.toLowerCase();
  return normalized === "/api/internal" || normalized.startsWith("/api/internal/");
}

export function forwardedHeaders(request) {
  const headers = {};
  for (const key of REQUEST_HEADERS) {
    const value = request.headers[key];
    if (value) headers[key] = value;
  }
  headers["x-forwarded-host"] = request.headers.host || "thesisforge.tech";
  headers["x-forwarded-proto"] = "https";
  return headers;
}

export function forwardedResponseHeaders(headers) {
  return Object.entries(headers).filter(([key]) => !HOP_BY_HOP_HEADERS.has(key.toLowerCase()));
}

function hasRequestBody(request) {
  return !["GET", "HEAD"].includes(String(request.method || "GET").toUpperCase());
}

function sendProxyError(response, code, error, status = 502) {
  if (response.headersSent) {
    response.destroy(error);
    return;
  }
  for (const header of response.getHeaderNames?.() || []) response.removeHeader(header);
  const body = Buffer.from(JSON.stringify({ error: code, message: error.message }));
  response.statusCode = status;
  response.setHeader("content-type", "application/json; charset=utf-8");
  response.setHeader("cache-control", "no-store");
  if (status === 413 || status === 408) response.setHeader("connection", "close");
  response.setHeader("content-length", body.length);
  response.end(body);
}

function readBody(request, maxBytes, timeoutMs) {
  return new Promise((resolve, reject) => {
    const declared = request.headers["content-length"];
    if (declared !== undefined && (!/^\d+$/.test(String(declared)) || Number(declared) > maxBytes)) {
      request.on("error", () => {});
      request.resume?.();
      reject(Object.assign(new Error("Request body exceeds the allowed size."), { status: 413 }));
      return;
    }
    let bytes = 0;
    let finished = false;
    const chunks = [];
    const finish = (error, body) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      request.removeListener("data", onData);
      request.removeListener("end", onEnd);
      request.removeListener("error", onError);
      request.removeListener("aborted", onAborted);
      if (error) { request.on("error", () => {}); request.resume?.(); reject(error); }
      else resolve(body);
    };
    const onData = (chunk) => {
      bytes += chunk.length;
      if (bytes > maxBytes) finish(Object.assign(new Error("Request body exceeds the allowed size."), { status: 413 }));
      else chunks.push(chunk);
    };
    const onEnd = () => finish(null, Buffer.concat(chunks));
    const onError = () => finish(Object.assign(new Error("Request body was interrupted."), { status: 400 }));
    const onAborted = () => finish(Object.assign(new Error("Request body was interrupted."), { status: 400 }));
    const timer = setTimeout(() => finish(Object.assign(new Error("Request body timed out."), { status: 408 })), timeoutMs);
    timer.unref?.();
    request.on("data", onData);
    request.once("end", onEnd);
    request.once("error", onError);
    request.once("aborted", onAborted);
  });
}

export function createProxyHandler({ production = PRODUCTION, maxBodyBytes = 1024 * 1024,
  bodyTimeoutMs = 10000, upstreamTimeoutMs = 120000, ...origins } = {}) {
 return async function handler(request, response) {
  let target;
  try { target = targetUrl(request, origins); }
  catch {
    sendProxyError(response, "invalid_proxy_target", new Error("The API route or origin is invalid."), 400);
    return;
  }
  // Internal release credentials are restricted to EB loopback, even after TLS.
  if (isPrivateInternalPath(target)) {
    const body = Buffer.from(JSON.stringify({
      error: "not_found",
      message: "This endpoint is not available through the public API proxy."
    }));
    response.statusCode = 404;
    response.setHeader("content-type", "application/json; charset=utf-8");
    response.setHeader("cache-control", "no-store");
    response.setHeader("content-length", body.length);
    response.end(body);
    return;
  }
  // Retirement precedes body parsing and upstream creation, including for
  // authenticated legacy clients. Never redirect credentials to another host.
  if (isRetiredApiPath(target.pathname)) {
    sendProxyError(response, "module_retired", new Error("This module has been retired."), 410);
    return;
  }
  if (production && target.protocol !== "https:") {
    sendProxyError(response, "insecure_upstream", new Error("The production API requires a secure upstream."), 503);
    return;
  }
  let body;
  try { body = hasRequestBody(request) ? await readBody(request, maxBodyBytes, bodyTimeoutMs) : undefined; }
  catch (error) {
    sendProxyError(response, "invalid_request_body", error, error.status || 400);
    return;
  }
  const transport = target.protocol === "https:" ? https : http;

  await new Promise((resolve) => {
    let completed = false;
    const settle = () => {
      if (completed) return;
      completed = true;
      clearTimeout(deadline);
      resolve();
    };
    const fail = (code, error) => {
      if (completed) return;
      // Do not return raw transport errors (which can contain private origins).
      sendProxyError(response, code, new Error(code === "upstream_timeout"
        ? "The upstream API timed out." : "The upstream API response could not be completed."), code === "upstream_timeout" ? 504 : 502);
      settle();
      upstreamRequest.destroy();
    };
    const upstreamRequest = transport.request(target, {
      method: request.method,
      headers: forwardedHeaders(request),
      ...(production && target.protocol === "https:" ? { agent: UPSTREAM_HTTPS_AGENT } : {})
    }, (upstream) => {
      response.statusCode = upstream.statusCode || 502;
      for (const [key, value] of forwardedResponseHeaders(upstream.headers)) {
        if (value !== undefined) response.setHeader(key, value);
      }
      upstream.once("aborted", () => fail(
        "upstream_stream_failed",
        new Error("Upstream response ended before its declared body arrived")
      ));
      upstream.once("error", (error) => fail("upstream_stream_failed", error));
      upstream.pipe(response);
    });

    upstreamRequest.once("error", (error) => fail("upstream_unavailable", error));
    // Wall-clock deadline includes DNS, TLS, headers and the complete stream;
    // an idle-only socket timeout can be evaded by a trickling response.
    const deadline = setTimeout(() => fail("upstream_timeout"), upstreamTimeoutMs);
    deadline.unref?.();

    if (body?.length) upstreamRequest.end(body);
    else upstreamRequest.end();

    request.once?.("aborted", () => {
      if (completed) return;
      upstreamRequest.destroy();
      settle();
    });
    response.once?.("finish", settle);
    response.once?.("close", () => {
      if (!response.writableEnded) upstreamRequest.destroy();
      settle();
    });
  });
 };
}

export default createProxyHandler();
