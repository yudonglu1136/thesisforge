import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const hash = (raw) => createHash("sha256").update(raw).digest("hex");
export function sourceText(html) {
  return html.replace(/<[^>]*>/g, " ").replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&nbsp;|&ensp;|&emsp;/gi, " ").replace(/&amp;/gi, "&")
    .replace(/&euro;/gi, "€").replace(/\s+/g, " ").trim();
}
const num = (s) => {
  const n = s.replace(/[,\s]/g, "").replace(/^\((.*)\)$/, "-$1");
  return /^-?\d+(\.\d+)?$/.test(n) ? Number(n) : null;
};

export function exactStatementRow(html, label, columns) {
  const found = [];
  for (const match of html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)) {
    const cells = [...match[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map((x) => sourceText(x[1])).filter(Boolean);
    if (cells[0] !== label) continue;
    const values = cells.slice(1).map(num).filter((x) => x !== null).slice(-columns);
    if (values.length === columns) found.push(values);
  }
  if (!found.length || found.some((v) => JSON.stringify(v) !== JSON.stringify(found[0]))) throw new Error(`Missing/conflicting exact statement row: ${label}`);
  return found[0];
}

/** Independent original-document audit; no imports from the valuation producer.
 * It verifies source bytes, SEC dates and table owners before model application.
 */
export function auditSpotCurrentSource({ bundleJson, expectedBundleSha256, read = readFileSync } = {}) {
  const failures = [], observations = [];
  try {
    if (hash(bundleJson) !== expectedBundleSha256) throw new Error("Source bundle is not independently pinned");
    const bundle = JSON.parse(bundleJson);
    const configRaw = readFileSync(new URL("./config/guru-current-economic-evidence.json", import.meta.url));
    const config = JSON.parse(configRaw).companies.SPOT;
    if (bundle.configBinding.sha256 !== hash(configRaw) || bundle.asOfDate !== "2026-09-05" ||
      bundle.ticker !== "SPOT" || bundle.historicalApproval !== false) throw new Error("Wrong dated source/config scope");
    const subRaw = read(bundle.submissionIndexBinding.path);
    if (hash(subRaw) !== bundle.submissionIndexBinding.sha256) throw new Error("SEC submission index changed");
    const recent = JSON.parse(subRaw).filings.recent;
    if (bundle.documents.length !== 4 || new Set(bundle.documents.map((d) => d.sourceId)).size !== 4) throw new Error("Incomplete or duplicate source set");
    const documents = {};
    for (const d of bundle.documents) {
      const c = config.sources[d.sourceId] || (d.sourceId === "q32026_guidance" ? {
        availableDate: "2026-08-04", url: "https://www.sec.gov/Archives/edgar/data/1639920/000114036126031044/ef20078867_ex99-1.htm"
      } : null), b = d.submissionBinding;
      if (!c || d.url !== c.url || d.availableDate !== c.availableDate || d.availableDate > bundle.asOfDate) throw new Error("Wrong source/available date");
      const i = recent.accessionNumber.indexOf(b.accession);
      if (i < 0 || recent.filingDate[i] !== d.availableDate || recent.acceptanceDateTime[i] !== b.acceptedAt ||
          recent.form[i] !== b.form || !d.url.includes(`/1639920/${b.accession.replaceAll("-", "")}/`)) throw new Error("SEC original index identity/date mismatch");
      const raw = read(d.path);
      if (hash(raw) !== d.sha256 || raw.length !== d.byteLength) throw new Error("Original statement bytes changed");
      const html = raw.toString(), text = sourceText(html);
      if (d.sourceId !== "q32026_guidance" && !/statement of cash flows.{0,100}\(in € millions\)/i.test(text)) throw new Error("Missing statement-owned EUR million unit");
      documents[d.sourceId] = { html, text, sha256: d.sha256, url: d.url };
    }
    const rules = [
      ["cfoM", "Net cash flows from operating activities", 1],
      ["cashPpeM", "Purchases of property and equipment", -1],
      ["leasePrincipalM", "Payments of lease liabilities", -1],
      ["sbcM", "Share-based compensation expense", 1],
      ["managementCapexM", "Capital expenditures", -1],
      ["restrictedCashReleaseM", "Change in restricted cash", 1],
    ];
    for (const [period, p] of Object.entries(config.periods)) {
      const d = documents[p.sourceId], columns = p.sourceId === "fy2025" ? 3 : 2, column = period === "h12025" ? 1 : 0;
      for (const [key, label, sign] of rules) {
        const values = exactStatementRow(d.html, label, columns), actual = sign * values[column];
        if (actual !== p[key]) throw new Error(`Official ${period}/${key} differs from current model`);
        observations.push({ period, metric: key, value: actual, unit: "EUR_million", label, column, sourceId: p.sourceId, sourceSha256: d.sha256 });
      }
    }
    const half = documents.h12026.text, quarter = documents.q12026.text, annual = documents.fy2025.text;
    const halfShares = /As of June 30, 2026 and December 31, 2025, the Company had ([\d,]+) and ([\d,]+) ordinary shares issued and fully paid, respectively, with ([\d,]+) and ([\d,]+) ordinary shares held as treasury shares/.exec(half);
    const qShares = /As of March 31, 2026 and December 31, 2025, the Company had ([\d,]+) and ([\d,]+) ordinary shares issued and fully paid, respectively, with ([\d,]+) and ([\d,]+) ordinary shares held as treasury shares/.exec(quarter);
    if (!halfShares || !qShares) throw new Error("Period-owned ordinary-share claims missing");
    const got = (m, n) => Number(m[n].replaceAll(",", ""));
    const shareRows = [["2026-06-30", got(halfShares, 1), got(halfShares, 3)], ["2026-03-31", got(qShares, 1), got(qShares, 3)],
      ["2025-12-31", got(halfShares, 2), got(halfShares, 4)]];
    if (got(qShares, 2) !== got(halfShares, 2) || got(qShares, 4) !== got(halfShares, 4)) throw new Error("Annual share comparative conflict");
    for (const [date, issued, treasury] of shareRows) {
      const r = config.shareObservations.find((s) => s.periodEndDate === date);
      if (!r || r.issued !== issued || r.treasury !== treasury || r.outstanding !== issued - treasury) throw new Error("Ordinary shares/treasury not reconciled");
    }
    if (!annual.includes("209,485,215") || !annual.includes("3,652,688")) throw new Error("Annual original share amounts missing");
    const exercisable = exactStatementRow(documents.h12026.html, "Exercisable at June 30, 2026", 2)[0];
    // Multiple tables have the outstanding-at label (options/RSU). Therefore
    // the exact exercised-option row is authoritative for the valuation claim.
    if (exercisable !== config.claims.exercisableOptions) throw new Error("Exercisable option claim mismatch");
    if (!half.includes("4,496,814") || !half.includes("1,456,016") || config.claims.allOptions !== 4496814 || config.claims.unvestedRsus !== 1456016) throw new Error("Other award disclosures mismatch");
    if (!/Exchangeable Notes 15, 19 — 1,458/.test(half) || config.claims.cashSettledExchangeableNotesRemaining !== 0) throw new Error("Current notes claim not zero in original balance sheet");
    observations.push({ metric: "exercisableOptions", value: exercisable, unit: "shares", sourceId: "h12026" });
    const guidanceText = documents.q32026_guidance.text;
    const start = guidanceText.indexOf("Outlook for Q3");
    const excerpt = guidanceText.slice(start, guidanceText.indexOf("Webcast Information", start));
    if (start < 0 || !/expectations for Q3 2026 as of August 4, 2026/.test(excerpt) ||
      !/Total Revenue €5\.0 billion/.test(excerpt) || !/Operating Income €670 million/.test(excerpt)) throw new Error("Quarterly official outlook is missing or changed");
    const guidanceReview = { sourceDate: "2026-08-04", fiscalPeriod: "2026-Q3", scope: "quarter", currency: "EUR",
      sourceUrl: documents.q32026_guidance.url, sourceSha256: documents.q32026_guidance.sha256,
      revenueM: 5000, operatingIncomeM: 670, includedInParentFcfeInputs: false,
      exclusionReason: "quarterly_revenue_and_operating_profit_are_not_parent_fcfe; no automatic cash-conversion or quarterly-to-annual FCFE substitution",
      analystForecastDisclosure: "The five-year FCFE path is an explicit analyst assumption, not company guidance; official quarterly outlook is retained separately." };
    return { status: "pass", scope: "dated_current_source_and_claims_not_generic_history", observations,
      shareObservations: shareRows.map(([periodEndDate, issued, treasury]) => ({ periodEndDate, issued, treasury, outstanding: issued - treasury })),
      guidanceReview, sourceBundleSha256: expectedBundleSha256, sourceDocuments: 4, historicalApproval: false, releaseAuthorized: false };
  } catch (error) { failures.push(error.message); }
  return { status: "fail", failures, observations, historicalApproval: false, releaseAuthorized: false };
}
