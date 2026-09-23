import assert from "node:assert/strict";
import test from "node:test";
import { isTransientSecReadError, retrySecRead } from "./secReadRetry.js";

test("SEC read retries transient transport failures without accepting partial content", async () => {
  let calls = 0;
  const delays = [];
  const result = await retrySecRead(async () => {
    calls += 1;
    if (calls === 1) throw Object.assign(new Error("overloaded"), { status: 503 });
    if (calls === 2) throw Object.assign(new Error("body interrupted"), { cause: { code: "UND_ERR_SOCKET" } });
    return { verified: true };
  }, { sleep: async ms => delays.push(ms) });
  assert.deepEqual(result, { verified: true });
  assert.equal(calls, 3);
  assert.deepEqual(delays, [1000, 2000]);
});

test("SEC retries stop after three failures and preserve the actual error", async () => {
  const error = Object.assign(new Error("timeout"), { name: "RequestTimeoutError" });
  let calls = 0;
  await assert.rejects(retrySecRead(async () => { calls++; throw error; }, {
    sleep: async () => {}
  }), caught => caught === error);
  assert.equal(calls, 3);
});

test("SEC identity, parsing, auth, absence and user cancellation fail without retry", async () => {
  for (const error of [
    Object.assign(new Error("unauthorized"), { status: 401 }),
    Object.assign(new Error("forbidden"), { status: 403 }),
    Object.assign(new Error("missing"), { status: 404 }),
    Object.assign(new Error("identity"), { code: "invalid_13f_identifier" }),
    new SyntaxError("malformed JSON"),
    Object.assign(new Error("cancelled"), { name: "AbortError" })
  ]) {
    let calls = 0;
    assert.equal(isTransientSecReadError(error), false);
    await assert.rejects(retrySecRead(async () => { calls++; throw error; }, {
      sleep: async () => assert.fail("must not retry")
    }), caught => caught === error);
    assert.equal(calls, 1);
  }
});

test("SEC Retry-After is honored; long server backoffs fail closed instead of retrying early", async () => {
  let calls = 0;
  const delays = [];
  await retrySecRead(async () => {
    if (++calls === 1) throw Object.assign(new Error("rate limit"), { status: 429, retryAfterMs: 5000 });
    return "ok";
  }, { sleep: async ms => delays.push(ms) });
  assert.deepEqual(delays, [5000]);
  await assert.rejects(retrySecRead(async () => {
    throw Object.assign(new Error("long rate limit"), { status: 429, retryAfterMs: 60000 });
  }, { sleep: async () => assert.fail("must not retry too early") }), /long rate limit/);
});
