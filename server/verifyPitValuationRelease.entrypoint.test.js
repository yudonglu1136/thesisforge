import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";

test("importing diagnostic inspectors does not open databases or publish a release pass", () => {
  const result = spawnSync(process.execPath, ["--input-type=module", "-e",
    'const m = await import("./server/verifyPitValuationRelease.js"); if (typeof m.inspectModels !== "function") throw Error("missing inspector");'
  ], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "");
});

test("direct release verification still requires all three exact database paths", () => {
  const result = spawnSync(process.execPath, ["server/verifyPitValuationRelease.js"], { encoding: "utf8" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Usage: node server\/verifyPitValuationRelease/);
  assert.doesNotMatch(result.stdout, /"status"\s*:\s*"pass"/);
});
