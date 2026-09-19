import assert from "node:assert/strict";
import test from "node:test";
import { independentPerShareEvidence, resolveIndependentPerShareOwner } from "./guidancePerShareEvidenceAudit.js";

const cases = [
  ["HPE", "Putting things in perspective, first, you know we are raising our FY 2021 EPS outlook by $0.09 at the midpoint to $1.82-$1.94 based on our Q2 outperformance, and we feel very confident for the rest of the year.", 1.88, .09],
  ["HPE", "Given our strong performance in Q1 and building momentum across the business, I am pleased to announce that we are raising our full year non-GAAP diluted net EPS outlook range for fiscal year 2022 by $0.7 At the midpoint to $2.03-$2.17.", 2.1, .7],
  ["IDXX", "We're raising our EPS guidance range by $0.06 at midpoint to $8.30-$8.38, reflecting 26%-27% full year comparable EPS growth.", 8.34, .06],
  ["INTC", "As a result, we are raising our full-year revenue guidance by $500 million to approximately $60 billion, and our EPS guidance by $0.05 to approximately $2.85 per share.", 2.85, .05],
  ["INTC", "Based on these factors, we are raising our full-year revenue guidance by $1.3 billion to $61.3 billion, operating income guidance by $600 million to $17.9 billion, and EPS guidance by $0.15 to $3 per share.", 3, .15],
  ["LMT", "Netting these changes together, we now expect our EPS for the year will be $0.05 higher than we guided in January to a new range of $10.85-$11.15 per share.", 11, .05],
  ["MCO", "On adjusted diluted EPS, we are raising the low end of the range by $0.10, bringing full-year guidance to $16.50-$17, or 12% growth at the midpoint.", 16.75, .1],
  ["SWK", "Finally, we are raising our 2024 full-year adjusted diluted EPS guidance range by $0.10 at the midpoint to a range of $3.70-$4.50, and increasing our free cash flow guidance to $650-$850 million.", 4.1, .1]
];
const check = (evidence, value) => independentPerShareEvidence({ evidence, value, unit: "currency_per_share", currency: "USD" });

for (const [ticker, evidence, target, delta] of cases) test(`${ticker} original raise-by target is reconstructed independently: ${target}`, () => {
  assert.equal(check(evidence, target), null);
  for (const wrong of [delta, (delta + target) / 2, target + .01]) assert.ok(check(evidence, wrong));
  const owner = resolveIndependentPerShareOwner({ evidence, value: target, unit: "currency_per_share", currency: "USD" });
  assert.equal(owner.status, "ready");
  assert.ok(owner.owner.valueStartIndex > owner.owner.metricIndex);
  assert.ok(owner.owner.valueEndIndex > owner.owner.valueStartIndex);
});

test("a delta cannot consume a foreign-owner value or become standalone absolute EPS", () => {
  for (const evidence of [
    "For the full year we raise EPS by $0.10 at the midpoint.",
    "For the full year we raise EPS by $0.10 due to tax expense of $3 per share.",
    "For the full year we raise EPS by $0.10, bringing revenue guidance to $30 million.",
    "For the full year we raise EPS by $0.10; our normalized FFO target is $3 per share."
  ]) for (const value of [.1, 3, 30]) assert.ok(check(evidence, value), evidence);
});

test("unchanged absolute ranges stay valid and explicit currency conflicts stay blocked", () => {
  assert.equal(check("For the full year we expect EPS of $3.70-$4.50.", 4.1), null);
  assert.equal(check("For the full year we raise EPS by $0.10 to $3.70-$4.50.", 4.1), null);
  assert.ok(check("For the full year we raise EPS by GBP 0.10 at the midpoint to GBP 3.70-GBP 4.50.", 4.1));
});

for (const [ticker, evidence, target, wrong] of [
  ["FISV", "Based on the strong Q2 results and higher anticipated organic revenue growth, we are raising our full-year adjusted EPS guidance range once again from the previous $7.30 to $7.40, to a new range of $7.40 to $7.50, representing growth of 14% to 16% over 2022.", 7.45, [7.35, 7.4]],
  ["FISV", "Based on this higher anticipated organic revenue growth and strong third quarter results, we are raising our full-year adjusted EPS guidance range once again from the previous $7.40-$7.50, to a new range of $7.47-$7.52, representing growth of 15%-16% over 2022.", 7.495, [7.45, 7.47]],
  ["SBUX", "As we expect these lower restructuring costs to sustain, we are raising our full year fiscal 2021 GAAP EPS guidance by $0.08 from a range of $2.34 to $2.54 to a new range of $2.42 to $2.62, both inclusive of approximately $0.10 for the 53rd week.", 2.52, [.08, 2.44, .1]],
  ["DECK", "We are raising our full-year EPS outlook from $3.73 to $3.80 to reflect the $2 million tax benefit recognized in the third quarter.", 3.8, [3.73, 3.765, 2]],
  ["FTV", "We are raising the low end of our full year 2021 adjusted diluted net EPS guidance to $2.70, resulting in a range of $2.70-$2.75 for the year.", 2.725, [2.7, 2.75]],
  ["FIS", "We are raising our full-year EPS outlook by $0.13-$0.15, to $5.03-$5.11, reflecting normalized growth of 13%-15%.", 5.07, [.14, 5.03]],
  ["FIS", "We are raising our full-year EPS outlook by $0.09-$0.12 to $5.15-$5.20, reflecting normalized growth of 16% to 17%.", 5.175, [.105, 5.15]],
  ["TMO", "All of this is enabling us to raise the 2022 adjusted EPS guidance by $0.08 from $22.93 to $23.01, further improving a very strong outlook for the year.", 23.01, [.08, 22.93, 22.97]],
  ["EFX", "Increasing our full year adjusted EPS guidance by $0.22 per share to a midpoint of $7.57 per share, which adjusting for Technology Transformation cost implies a 23% growth in EPS.", 7.57, [.22]],
]) test(`${ticker} revised EPS regime does not average prior guide and delta`, () => {
  assert.equal(check(evidence, target), null);
  for (const value of wrong) assert.ok(check(evidence, value));
});

test("actual source deltas and ambiguous transcript punctuation cannot masquerade as EPS levels", () => {
  for (const [evidence, wrong] of [
    ["Based on our robust performance this quarter and the continued strong outlook for our business, we are raising our full year adjusted earnings per share guidance by $0.10.", .1],
    ["We continue to expect business optimization actions to impact fiscal 2024 GAAP operating margin by 70 basis points and EPS by $0.56.", .56],
    ["For 2016, we estimate that the 53rd week will aid total sales by approximately 1.5% and earnings per share by $0.05-$0.06.", .055],
    ["We estimate foreign exchange will increase full year EPS by $0.02 per share, given current hedge positions.", .02],
    ["Today, we're raising our adjusted EPS guidance for 2021 by $0.01- $2.83-$2.87, with a focus on the midpoint.", 1.42],
    ["As a result, we're raising our adjusted earnings per share guidance for the year by $0.50- $6.25-$6.75.", 3.375],
    ["For the full year, we are raising the midpoint of our adjusted EPS guidance by $0.03- $3.78.", 1.905],
    ["On the bottom line, we're raising our adjusted EPS guidance for 2022 by $0.28- $22.93.", 11.605],
    ["We raise EPS by $0.10 from tax expense of $2.34 to a new range of $2.42-$2.62.", 2.52],
    ["We expect EPS from $3.73 to $3.80.", 3.8],
  ]) assert.ok(check(evidence, wrong), evidence);
});
