import crypto from "node:crypto";

const hash = (value) => crypto.createHash("sha256").update(value).digest("hex");

// Validate the exact text that will be attached, not just a cache key or the
// presence of Chinese in an older snapshot. This module has no DB side effects.
export function auditedQaTranslation(source, translations, sourceAudits) {
  if (!source) return "";
  const target = translations.get(source);
  const audit = sourceAudits[source];
  if (!audit || !["pass", "approved"].includes(audit.status)) {
    throw new Error("translation_source_not_approved");
  }
  if (audit.source_sha256 !== hash(source)) throw new Error("source_hash_mismatch");
  if (typeof target !== "string" || !target || !/[\u3400-\u9fff]/.test(target)) {
    throw new Error("cache_translation_missing");
  }
  if (audit.translation_sha256 !== hash(target)) throw new Error("translation_hash_mismatch");
  return target;
}

export function selectedQaTranslation(source, translations) {
  if (!source) return "";
  const translated = translations.get(source);
  if (typeof translated !== "string" || !translated) throw new Error("audited_translation_missing_at_attachment");
  return translated;
}

export function qaTranslationSources(rows, fallbackAnswer) {
  const sources = new Set();
  for (const row of rows) {
    const question = String(row.question || "").trim();
    const answer = String(row.answer || fallbackAnswer || "").trim();
    if (question) sources.add(question);
    if (answer) sources.add(answer);
  }
  return sources;
}

export function assertAttachedQaTranslations(rows, translations, fallbackAnswer) {
  for (const row of rows) {
    for (const field of ["question", "answer"]) {
      const source = String(row[field] || (field === "answer" ? fallbackAnswer : "") || "").trim();
      if (!source) continue;
      if (row[`${field}Zh`] !== selectedQaTranslation(source, translations)) {
        throw new Error("attached_translation_differs_from_audited_cache");
      }
    }
  }
}
