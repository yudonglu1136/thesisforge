import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { createHash } from "node:crypto";
import { buildSpotCurrentSnapshot } from "../server/spotCurrentSnapshot.js";

const a = process.argv.slice(2), o = {};
for (let i = 0; i < a.length; i += 2) {
  if (!["--input", "--input-sha256", "--sources", "--sources-sha256", "--model-signature", "--output"].includes(a[i]) || !a[i + 1] || o[a[i]]) throw new Error("Explicit input/source/model digests and new output are required");
  o[a[i]] = a[i + 1];
}
for (const key of ["--input", "--input-sha256", "--sources", "--sources-sha256", "--model-signature", "--output"]) if (!o[key]) throw new Error(`Missing ${key}`);
const path = resolve(o["--output"]);
if (existsSync(path)) throw new Error("Immutable output already exists");
const result = buildSpotCurrentSnapshot({ inputJson: readFileSync(o["--input"], "utf8"), sourceBundleJson: readFileSync(o["--sources"], "utf8"),
  trust: { inputSha256: o["--input-sha256"], sourceBundleSha256: o["--sources-sha256"], modelSignature: o["--model-signature"] } });
if (result.status === "blocked") throw new Error(JSON.stringify(result));
const raw = JSON.stringify(result, null, 2) + "\n";
mkdirSync(dirname(path), { recursive: true });
writeFileSync(path, raw, { flag: "wx" });
console.log(JSON.stringify({ path, sha256: createHash("sha256").update(raw).digest("hex"), ticker: "SPOT", historyRows: result.snapshot.history.length,
  sourceAndArithmeticReady: result.sourceAndArithmeticReady, releaseReady: false, fairValue: result.snapshot.latest.baseFairValue }));
