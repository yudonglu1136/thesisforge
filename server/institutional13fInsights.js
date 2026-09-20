import { assert, isoDate } from './investmentMath.js';

const parse = row => row ? JSON.parse(row.payload_json) : null;

function visibleSnapshot(source, asOf, reportDate = null) {
  isoDate(asOf);
  if (reportDate) isoDate(reportDate);
  const db=source.insightsDb??source.db;
  const exists = db.prepare(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='institutional_13f_insight_snapshots'"
  ).get();
  assert(exists, 'institutional_13f_insights_unavailable');
  const visible = db.prepare(`
    SELECT report_date,available_at,generated_at,payload_json
    FROM institutional_13f_insight_snapshots s
    WHERE available_at<=?
      AND generated_at=(
        SELECT max(generated_at) FROM institutional_13f_insight_snapshots n
        WHERE n.report_date=s.report_date AND n.available_at<=?
      )
    ORDER BY report_date DESC
  `).all(asOf, asOf);
  assert(visible.length, 'institutional_13f_insights_not_available_at_date');
  const selected = reportDate
    ? visible.find(row => row.report_date === reportDate)
    : visible[0];
  assert(selected, 'institutional_13f_quarter_not_available');
  return {payload:parse(selected), selected, quarters:visible.map(row => row.report_date)};
}

export function institutional13fInsights(source, asOf, reportDate = null, ticker = null) {
  const {payload,selected,quarters}=visibleSnapshot(source,asOf,reportDate);
  const mostIncreased=payload.rows.reduce((best,row)=>(row.increases??0)>(best?.increases??-1)?row:best,null);
  const selectedTicker=typeof ticker==='string' && /^[A-Z][A-Z0-9.-]{0,14}$/.test(ticker)
    ? ticker
    : mostIncreased?.ticker;
  const boundedDetails=selectedTicker && payload.details?.[selectedTicker]
    ? {[selectedTicker]:payload.details[selectedTicker]}
    : {};
  const {details:allDetails,...summary}=payload;
  return {
    ...summary,
    asOf,
    quarters,
    generatedAt: selected.generated_at,
    details: boundedDetails,
    coverage: {
      ...payload.coverage,
      scope: 'all_sf3_institutional_filers',
      selectedGuruCount: null,
    },
  };
}

export function institutional13fInsightDetail(source, ticker, asOf, reportDate = null) {
  isoDate(asOf);
  assert(/^[A-Z][A-Z0-9.-]{0,14}$/.test(ticker),'invalid_ticker');
  const {payload}=visibleSnapshot(source,asOf,reportDate);
  const row=payload.rows.find(item=>item.ticker===ticker);
  assert(row,'institutional_13f_security_not_found');
  return {version:payload.version,asOf,reportDate:payload.reportDate,ticker,row,details:payload.details?.[ticker]??{}};
}
