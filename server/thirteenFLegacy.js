// Legacy SEC text tables, before XML became mandatory. This adapter only
// extracts reported cells; classification, aggregation and ranking stay in
// secClient/thirteenF. Unknown layouts fail closed rather than yielding a
// partial book. The original .txt remains the public source document.
export function parseLegacy13fInformationTable(text) {
  if (!/<SEC-DOCUMENT>/i.test(text) || !/<TYPE>13F-HR\s*\n/i.test(text)) throw Error('legacy_13f_original_required');
  if (!/CONFORMED SUBMISSION TYPE:\s*13F-HR\s*\n/i.test(text)) throw Error('legacy_13f_amendment_not_supported');
  const tables = [...text.matchAll(/<TABLE>([\s\S]*?)<\/TABLE>/gi)].map(m => m[1]);
  const rows = [];
  for (const table of tables) {
    const columnMarker = /^\s*(?:<(?:S|C)>\s*){3,}$/im;
    if (!/CUSIP/i.test(table) || !columnMarker.test(table)) continue;
    const heading = table.slice(0, table.search(columnMarker));
    if (!/x\$1000|\$?\s*1,?000|thousands/i.test(heading)) throw Error('legacy_13f_unknown_value_unit');
    let active = false;
    for (const line of table.split(/\r?\n/)) {
      if (columnMarker.test(line)) { active = true; continue; }
      if (!active || !line.trim() || /^\s*<\/?(?:PAGE|CAPTION)>\s*$/i.test(line) || /^\s*[-=]+\s*$/.test(line)) continue;
      const match = /^(.*?)\s+'?([A-Z0-9]{9})\s+([\d,]+(?:\.\d+)?)\s+([\d,]+(?:\.\d+)?)\s*(SH|PRN)\s*(?:(PUT|CALL)\s+)?(?:SOLE|SHARED|OTHER|DEFINED)\b/i.exec(line);
      if (!match) throw Error('legacy_13f_unparsed_row:' + line.trim().slice(0,90));
      let prefix = match[1].trim().split(/\s{2,}/);
      if (prefix.length === 1) {
        const joined = /^(.*?)\s+(COM(?: NEW)?|CL [A-Z](?: NEW)?|ADR|ORD|SHS|SH BEN INT(?: NEW)?|SPONSORED ADR)$/i.exec(prefix[0]);
        if (joined) prefix = [joined[1], joined[2]];
      }
      // A blank class is retained as reported, just as for XML. Never invent
      // COM for it. Issuers may themselves contain repeated spaces.
      prefix = prefix.length === 1 ? [prefix[0], ''] : [prefix.slice(0, -1).join(' '), prefix.at(-1)];
      if (!prefix[0]) throw Error('legacy_13f_missing_issuer');
      const [, , cusip, value, shares, shareType, putCall = ''] = match;
      const number = v => Number(v.replaceAll(',', ''));
      if (![number(value), number(shares)].every(n => Number.isFinite(n) && n >= 0)) throw Error('legacy_13f_invalid_number');
      rows.push({nameOfIssuer: prefix[0], titleOfClass: prefix[1], cusip: cusip.toUpperCase(), value: number(value),
        shrsOrPrnAmt: {sshPrnamt: number(shares), sshPrnamtType: shareType.toUpperCase()}, putCall: putCall.toUpperCase()});
    }
  }
  if (!rows.length) throw Error('legacy_13f_information_table_missing');
  const count = text.match(/Information\s+Table\s+Entry\s+Total:\s*([\d,]+)/i);
  if (count && Number(count[1].replaceAll(',', '')) !== rows.length) throw Error('legacy_13f_entry_total_mismatch');
  const total = text.match(/Information\s+Table\s+Value\s+Total:\s*\$?\s*([\d,]+)/i);
  if (total && Number(total[1].replaceAll(',', '')) !== rows.reduce((s,r) => s + r.value,0)) throw Error('legacy_13f_value_total_mismatch');
  return {rows, valueScale: 1000};
}

export function assertLegacy13fIdentity(text, {cik, accessionNumber, reportDate}) {
  const header = text.match(/<SEC-HEADER>([\s\S]*?)<\/SEC-HEADER>/i)?.[1] || '';
  const actualCik = header.match(/CENTRAL INDEX KEY:\s*(\d+)/i)?.[1]?.padStart(10, '0');
  const accession = header.match(/ACCESSION NUMBER:\s*(\S+)/i)?.[1];
  const period = header.match(/CONFORMED PERIOD OF REPORT:\s*(\d{8})/i)?.[1];
  if (actualCik !== String(cik).padStart(10, '0') || accession !== accessionNumber ||
      period !== String(reportDate).replaceAll('-', '')) throw Error('legacy_13f_filing_identity_mismatch');
}

export function indexed13fAttachment(candidates, accession, submissionName) {
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*\.xml$/i.test(submissionName) || submissionName.includes('..')) throw Error('unsafe_information_table_filename');
  const exact = candidates.filter(name => name === submissionName || name === `${accession}-${submissionName}`);
  if (exact.length > 1) throw Error('ambiguous_indexed_information_table');
  return exact[0] || submissionName;
}
