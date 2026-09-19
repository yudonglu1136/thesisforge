import assert from "node:assert/strict";
import crypto from "node:crypto";
import test from "node:test";
import { auditedQaTranslation, selectedQaTranslation, qaTranslationSources, assertAttachedQaTranslations } from "./valuationQaTranslationIntegrity.js";

const hash = (s) => crypto.createHash("sha256").update(s).digest("hex");
function fixture() {
  const source = "Revenue increased 20%.";
  const target = "营收增长20%。";
  return { source, target, cache: new Map([[source, target]]), audit: {
    [source]: { status: "pass", source_sha256: hash(source), translation_sha256: hash(target) }
  } };
}
test("attachment uses the exact approved cache, never a different existing Chinese value", () => {
  const { source, target, cache, audit } = fixture();
  assert.equal(auditedQaTranslation(source, cache, audit), target);
  assert.equal(selectedQaTranslation(source, cache), target);
});
test("existing Chinese cannot remove a used source from the audit", () => {
  const sources = qaTranslationSources([{ question: "Question?", questionZh: "已有问题", answer: "Answer.", answerZh: "已有回答" }], "Fallback.");
  assert.deepEqual([...sources], ["Question?", "Answer."]);
});
test("changed source, changed target, absent hash and unapproved source all fail closed", () => {
  for (const mutation of [
    (f) => { f.audit[f.source].source_sha256 = hash("Different source"); },
    (f) => { f.cache.set(f.source, "营收增长200%。"); },
    (f) => { delete f.audit[f.source].translation_sha256; },
    (f) => { f.audit[f.source].status = "recovered_pending_review"; },
    (f) => { f.cache.delete(f.source); },
    (f) => { delete f.audit[f.source]; },
  ]) {
    const f = fixture(); mutation(f);
    assert.throws(() => auditedQaTranslation(f.source, f.cache, f.audit));
  }
});
test("missing attachment cannot echo English as a successful translation", () => {
  assert.throws(() => selectedQaTranslation("Revenue increased 20%.", new Map()));
  assert.equal(selectedQaTranslation("", new Map()), "");
});
test("explicit approved editorial correction is bound identically to model output", () => {
  const f = fixture(); f.audit[f.source].status = "approved";
  assert.equal(auditedQaTranslation(f.source, f.cache, f.audit), f.target);
});
test("the final attached QA is checked, not only the input cache", () => {
  const f = fixture();
  const qa = [{ question: f.source, questionZh: f.target, answer: "" }];
  assert.doesNotThrow(() => assertAttachedQaTranslations(qa, f.cache, ""));
  qa[0].questionZh = "营收增长200%。";
  assert.throws(() => assertAttachedQaTranslations(qa, f.cache, ""), /attached_translation_differs/);
});
