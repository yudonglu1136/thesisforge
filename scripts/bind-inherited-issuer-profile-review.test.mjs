import assert from "node:assert/strict";
import test from "node:test";
import { inheritedReviewUpdates } from "./bind-inherited-issuer-profile-review.mjs";

const fixture = () => ({ status: "profile_provenance_verified_new_release_review_required", releaseAuthorized: false,
  discrepancies: [], summary: { profileInheritanceEligible: 1, retainedModeledTickers: 1, newInputOrOutputApprovalsInherited: 0 },
  originalRelease: { gitCommit: "original" }, issuers: [{ ticker: "TEST", profileInheritanceEligible: true,
    profile: "industrial", priorStatus: "watch", originalGitSettingsSha256: "settings",
    baselineBinding: { modelSignature: "model" }, releaseAuthorized: false,
    newFinancialInputApprovalInherited: false, newGuidanceApprovalInherited: false,
    newFxApprovalInherited: false, newModelOutputsApprovalInherited: false }] });
const states = [{ ticker: "TEST", status: "inherited_release_review_pending" }, { ticker: "NEW", status: "pending_economic_review" }];

test("binds only proven old profile and preserves watch without approving inputs", () => {
  const updates = inheritedReviewUpdates(fixture(), states);
  assert.equal(updates.length, 1);
  assert.equal(updates[0].ticker, "TEST");
  const reason = JSON.parse(updates[0].reason);
  assert.equal(reason.priorStatus, "watch");
  assert.equal(reason.sourceAndOutputApprovalInherited, false);
  assert.equal(reason.releaseAuthorized, false);
});

test("rejects partial proof, expanded approval and pending new issuer substitution", () => {
  for (const change of [
    (x) => { x.discrepancies.push({ ticker: "TEST" }); },
    (x) => { x.summary.newInputOrOutputApprovalsInherited = 1; },
    (x) => { x.issuers[0].newGuidanceApprovalInherited = true; },
    (x) => { x.issuers[0].ticker = "NEW"; },
    (x) => { x.issuers.push(x.issuers[0]); },
    (x) => { x.releaseAuthorized = true; }
  ]) {
    const input = fixture(); change(input);
    assert.throws(() => inheritedReviewUpdates(input, states));
  }
});
