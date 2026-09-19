import { reviewedCurrentFromEnvironment } from "../server/reviewedCurrentFullRebuild.js";
const reviewed = reviewedCurrentFromEnvironment();
if (!reviewed) throw new Error("Pinned current manifest required");
process.stdout.write(JSON.stringify({ manifestSha256: reviewed.manifestSha256, historicalApproval: false,
  candidates: reviewed.candidates.map(c => ({ ticker: c.ticker, snapshot: c.snapshot, currentSourceBinding: c.currentSourceBinding })) }));
