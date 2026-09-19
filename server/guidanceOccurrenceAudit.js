// Duplicate identity only, not approval of a target's amount, economic owner,
// period or model eligibility. Those remain independent release checks.
// A quote can contain multiple revenue/sales occurrences, e.g. a numerical
// quarter target followed by a qualitative annual target. Empty and populated
// observations of DIFFERENT original occurrences are not duplicate events.
const REVENUE_OWNER = /\b(?:revenues?|sales|total income)\b/gi;

function object(value) {
  if (value && typeof value === "object" && !Array.isArray(value)) return value;
  if (typeof value !== "string") return {};
  try { return object(JSON.parse(value)); } catch { return {}; }
}

export function separateOriginalRevenueOccurrences(rows) {
  if (!Array.isArray(rows) || rows.length < 2) return false;
  const quote = rows[0].value_text;
  const metric = rows[0].metric_name;
  if (typeof quote !== "string" || !quote || !["revenue_guidance", "revenue_growth"].includes(metric)) return false;
  const originalPositions = new Set([...quote.matchAll(REVENUE_OWNER)].map(match => match.index));
  const positions = new Set();
  let originalFile;
  for (const row of rows) {
    const outer = object(row.payload_json);
    const nested = outer.payload_json ? object(outer.payload_json) : outer;
    const position = nested.metric_position;
    if (row.value_text !== quote || row.metric_name !== metric || nested.metric_name !== metric ||
        nested.evidence_excerpt !== quote || !Number.isInteger(position) || !originalPositions.has(position) ||
        typeof nested.source_file !== "string" || !nested.source_file.trim()) return false;
    originalFile ??= nested.source_file;
    if (nested.source_file !== originalFile || positions.has(position)) return false;
    positions.add(position);
  }
  return positions.size === rows.length;
}
