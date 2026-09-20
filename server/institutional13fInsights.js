import { assert, isoDate } from './investmentMath.js';
import { gunzipSync } from 'node:zlib';

const parse = row => {
  if (!row) return null;
  if (row.payload_gzip) return JSON.parse(gunzipSync(row.payload_gzip).toString('utf8'));
  return JSON.parse(row.payload_json);
};

const selectedPayloadCache = new WeakMap();
const historyIndexCache = new WeakMap();

function cacheEntries(cache, source) {
  let entries=cache.get(source);
  if (!entries) {
    entries=new Map();
    cache.set(source,entries);
  }
  return entries;
}

function setBounded(entries,key,value,limit) {
  if (!entries.has(key)) {
    while (entries.size>=limit) entries.delete(entries.keys().next().value);
  }
  entries.set(key,value);
}

function snapshotKey(row) {
  return `${row.report_date}|${row.payload_hash??row.generated_at}`;
}

function selectedPayload(source,row) {
  const entries=cacheEntries(selectedPayloadCache,source);
  const key=snapshotKey(row);
  if (entries.has(key)) return entries.get(key);
  const payload=parse(row);
  setBounded(entries,key,payload,1);
  return payload;
}

function tableExists(db,name) {
  return Boolean(db.prepare(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?"
  ).get(name));
}

function visibleRows(db,table,asOf) {
  const compressed=table.endsWith('_v2');
  const payload=compressed ? 'payload_gzip' : 'payload_json';
  return db.prepare(`
    SELECT report_date,available_at,generated_at,payload_hash,${payload}
    FROM ${table} s
    WHERE available_at<=?
      AND generated_at=(
        SELECT max(generated_at) FROM ${table} n
        WHERE n.report_date=s.report_date AND n.available_at<=?
      )
    ORDER BY report_date DESC
  `).all(asOf,asOf);
}

function visibleSnapshot(source, asOf, reportDate = null) {
  isoDate(asOf);
  if (reportDate) isoDate(reportDate);
  const db=source.insightsDb??source.db;
  const tables=[
    'institutional_13f_insight_snapshots_v2',
    'institutional_13f_insight_snapshots',
  ].filter(table=>tableExists(db,table));
  assert(tables.length, 'institutional_13f_insights_unavailable');
  let visible=[];
  for (const table of tables) {
    visible=visibleRows(db,table,asOf);
    if (visible.length) break;
  }
  assert(visible.length, 'institutional_13f_insights_not_available_at_date');
  const selected = reportDate
    ? visible.find(row => row.report_date === reportDate)
    : visible[0];
  assert(selected, 'institutional_13f_quarter_not_available');
  return {payload:selectedPayload(source,selected), selected, visible, quarters:visible.map(row => row.report_date)};
}

function securityHistories(source, visible, selected, selectedData) {
  const bounded=visible.filter(row=>row.report_date<=selected.report_date);
  const key=bounded.map(snapshotKey).join(';');
  const entries=cacheEntries(historyIndexCache,source);
  if (entries.has(key)) return entries.get(key);
  const histories=new Map();
  for (const snapshot of [...bounded].reverse()) {
    const payload=snapshot===selected ? selectedData : parse(snapshot);
    for (const row of payload?.rows??[]) {
      if (!row?.ticker) continue;
      const history=histories.get(row.ticker)??[];
      history.push({
        reportDate:payload.reportDate??snapshot.report_date,
        availableAt:payload.availableAt??snapshot.available_at,
        holders:row.holders??null,
        institutionalSharesK:row.currentUnitsK??null,
        sharesOutstandingK:row.sharesOutstandingK??null,
        institutionalOwnershipPct:row.institutionalOwnershipPct??null,
      });
      histories.set(row.ticker,history);
    }
  }
  setBounded(entries,key,histories,1);
  return histories;
}

export function institutional13fInsights(source, asOf, reportDate = null, ticker = null) {
  const {payload,selected,visible,quarters}=visibleSnapshot(source,asOf,reportDate);
  const mostIncreased=payload.rows.reduce((best,row)=>(row.increases??0)>(best?.increases??-1)?row:best,null);
  const selectedTicker=typeof ticker==='string' && /^[A-Z][A-Z0-9.-]{0,14}$/.test(ticker)
    ? ticker
    : mostIncreased?.ticker;
  const histories=securityHistories(source,visible,selected,payload);
  const boundedDetails=selectedTicker
    ? {[selectedTicker]:{
      ...(payload.details?.[selectedTicker]??{}),
      history:histories.get(selectedTicker)??[],
    }}
    : {};
  const {details:allDetails,...summary}=payload;
  return {
    ...summary,
    asOf,
    selectedTicker,
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
  const {payload,visible,selected}=visibleSnapshot(source,asOf,reportDate);
  const row=payload.rows.find(item=>item.ticker===ticker);
  assert(row,'institutional_13f_security_not_found');
  return {
    version:payload.version,asOf,reportDate:payload.reportDate,ticker,row,
    details:{
      ...(payload.details?.[ticker]??{}),
      history:securityHistories(source,visible,selected,payload).get(ticker)??[],
    },
  };
}
