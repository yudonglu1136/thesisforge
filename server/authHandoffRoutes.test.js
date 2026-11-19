import assert from "node:assert/strict";
import test from "node:test";
import { createAuthHandoffService } from "./authHandoffRoutes.js";

test("Email handoff start -> complete -> poll delivers single-use session and rejects replay", async () => {
  const prevUrl = process.env.SUPABASE_URL;
  const prevAnon = process.env.SUPABASE_ANON_KEY;
  process.env.SUPABASE_URL = "https://ynwagccwndqxhewosjvh.supabase.co";
  process.env.SUPABASE_ANON_KEY = "sb_publishable_test_key";

  let capturedUrl = "";
  let capturedBody = null;
  let clock = 1_700_000_000_000;

  try {
    const service = createAuthHandoffService({
      now: () => clock,
      fetchImpl: async (url, init) => {
        capturedUrl = String(url);
        capturedBody = JSON.parse(init.body);
        return new Response("{}", {
          status: 200,
          headers: { "content-type": "application/json" }
        });
      },
      verifyAccessToken: async (token) => {
        if (token === "valid-access-jwt") {
          return {
            ok: true,
            user: { id: "user-1", email: "luyudong1136@gmail.com" }
          };
        }
        return { ok: false, status: 401 };
      }
    });

    const started = await service.startEmailHandoff({
      email: "LuYudong1136@gmail.com",
      origin: "https://evil.example.com",
      ip: "203.0.113.10"
    });
    assert.equal(started.httpStatus, 200);
    assert.equal(started.body.ok, true);
    assert.ok(started.body.handoffId.length >= 16);
    assert.ok(started.body.pollSecret.length >= 20);
    assert.equal(started.body.pairCode, undefined, "pairCode must never leak before email click");

    // Evil origin must be sanitized to official ThesisForge origin and use Implicit flow (no code_challenge)
    assert.match(
      capturedUrl,
      /^https:\/\/ynwagccwndqxhewosjvh\.supabase\.co\/auth\/v1\/otp\?redirect_to=https%3A%2F%2Fwww\.thesisforge\.tech%2F%3Fauth_handoff%3D/
    );
    assert.equal(capturedUrl.includes("code_challenge"), false);
    assert.deepEqual(capturedBody, {
      email: "luyudong1136@gmail.com",
      create_user: true
    });

    // Polling before email click returns pending
    const pending = service.pollEmailHandoff({
      handoffId: started.body.handoffId,
      pollSecret: started.body.pollSecret
    });
    assert.equal(pending.httpStatus, 200);
    assert.equal(pending.body.status, "pending");

    // Wrong poll secret is rejected
    const badPoll = service.pollEmailHandoff({
      handoffId: started.body.handoffId,
      pollSecret: "wrong-secret-value-123456789012"
    });
    assert.equal(badPoll.httpStatus, 403);

    // Completing with mismatched email token is rejected
    const completeServiceMismatch = await createAuthHandoffService({
      fetchImpl: async () => new Response("{}", { status: 200 }),
      verifyAccessToken: async () => ({
        ok: true,
        user: { id: "u2", email: "other@example.com" }
      })
    });
    const started2 = await completeServiceMismatch.startEmailHandoff({
      email: "luyudong1136@gmail.com",
      origin: "https://thesisforge.tech",
      ip: "203.0.113.11"
    });
    const mismatch = await completeServiceMismatch.completeEmailHandoff({
      handoffId: started2.body.handoffId,
      accessToken: "other-jwt",
      refreshToken: "refresh-token-valid-12345"
    });
    assert.equal(mismatch.httpStatus, 403);

    // Completing with valid verified token returns real 6-digit numeric pairCode
    const completed = await service.completeEmailHandoff({
      handoffId: started.body.handoffId,
      accessToken: "valid-access-jwt",
      refreshToken: "refresh-token-valid-99999"
    });
    assert.equal(completed.httpStatus, 200);
    assert.match(completed.body.pairCode, /^\d{6}$/);
    assert.equal(completed.body.email, "luyudong1136@gmail.com");

    // Polling inside the iOS WebClip App delivers the refresh token and burns the record
    const claimed = service.pollEmailHandoff({
      handoffId: started.body.handoffId,
      pollSecret: started.body.pollSecret
    });
    assert.equal(claimed.httpStatus, 200);
    assert.equal(claimed.body.status, "completed");
    assert.equal(claimed.body.refreshToken, "refresh-token-valid-99999");

    // Second poll or pairCode redeem after claim is rejected (single-use burn)
    const replayPoll = service.pollEmailHandoff({
      handoffId: started.body.handoffId,
      pollSecret: started.body.pollSecret
    });
    assert.equal(replayPoll.httpStatus, 404);

    const replayRedeem = service.redeemPairCode({
      pairCode: completed.body.pairCode,
      email: "luyudong1136@gmail.com",
      ip: "203.0.113.10"
    });
    assert.equal(replayRedeem.httpStatus, 401);
  } finally {
    if (prevUrl === undefined) delete process.env.SUPABASE_URL;
    else process.env.SUPABASE_URL = prevUrl;
    if (prevAnon === undefined) delete process.env.SUPABASE_ANON_KEY;
    else process.env.SUPABASE_ANON_KEY = prevAnon;
  }
});

test("6-digit pairCode from Desktop/Safari session or Email Handoff redeems cleanly and enforces brute-force rate limit", async () => {
  let clock = 1_700_000_000_000;
  const service = createAuthHandoffService({ now: () => clock });

  const created = service.createDevicePairCode({
    user: { id: "user-1", email: "luyudong1136@gmail.com" },
    accessToken: "desktop-access-jwt",
    refreshToken: "desktop-refresh-token-abc123"
  });
  assert.equal(created.httpStatus, 200);
  assert.match(created.body.pairCode, /^\d{6}$/);
  assert.equal(created.body.expiresIn, 300);

  // User enters spaced 6-digit code in iPhone App without even needing to type email
  const spacedCode = `${created.body.pairCode.slice(0, 3)} ${created.body.pairCode.slice(3)}`;
  const redeemed = service.redeemPairCode({
    pairCode: spacedCode,
    email: "",
    ip: "198.51.100.5"
  });
  assert.equal(redeemed.httpStatus, 200);
  assert.equal(redeemed.body.refreshToken, "desktop-refresh-token-abc123");
  assert.equal(redeemed.body.email, "luyudong1136@gmail.com");

  // Single-use: second redeem fails
  const second = service.redeemPairCode({
    pairCode: created.body.pairCode,
    email: "",
    ip: "198.51.100.5"
  });
  assert.equal(second.httpStatus, 401);

  // Brute-force protection locks out IP after 8 failed attempts
  for (let i = 0; i < 7; i += 1) {
    const miss = service.redeemPairCode({
      pairCode: "000000",
      email: "",
      ip: "198.51.100.5"
    });
    assert.equal(miss.httpStatus, 401);
  }
  const locked = service.redeemPairCode({
    pairCode: "000000",
    email: "",
    ip: "198.51.100.5"
  });
  assert.equal(locked.httpStatus, 429);

  // Advancing clock past 10m window clears rate limit
  clock += 11 * 60 * 1000;
  const afterWindow = service.redeemPairCode({
    pairCode: "000000",
    email: "",
    ip: "198.51.100.5"
  });
  assert.equal(afterWindow.httpStatus, 401);
});
