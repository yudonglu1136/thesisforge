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
    SELECT report_date,source_generation,available_at,generated_at,payload_hash,${payload}
    FROM ${table} s
    WHERE available_at<=?
      AND generated_at=(
        SELECT max(generated_at) FROM ${table} n
        WHERE n.report_date=s.report_date AND n.available_at<=?
      )
    ORDER BY report_date DESC
  `).all(asOf,asOf);
}

function lazyDetail(source, selected, ticker, payload) {
  const db=source.insightsDb??source.db;
  if (tableExists(db,'institutional_13f_insight_details_v1')) {
    const row=db.prepare(`SELECT payload_gzip FROM institutional_13f_insight_details_v1
      WHERE report_date=? AND source_generation=? AND ticker=?`).get(
      selected.report_date,selected.source_generation,ticker,
    );
    if (row?.payload_gzip) return parse(row)??{};
  }
  return payload.details?.[ticker]??{};
}

function marketHistory(source, visible, selected) {
  const db=source.insightsDb??source.db;
  if (!tableExists(db,'institutional_13f_market_history_v1')) return [];
  const history=[];
  for (const row of [...visible].reverse()) {
    if (row.report_date>selected.report_date) continue;
    const metrics=db.prepare(`SELECT segment,securities,covered_securities,institutional_value_m,
      market_cap_m,institutional_ownership_pct,net_change_value_m,net_change_pct_market_cap
      FROM institutional_13f_market_history_v1
      WHERE report_date=? AND source_generation=? ORDER BY segment`).all(row.report_date,row.source_generation);
    if (!metrics.length) continue;
    history.push({
      reportDate:row.report_date,
      availableAt:row.available_at,
      segments:Object.fromEntries(metrics.map(item=>[item.segment,{
        securities:item.securities,coveredSecurities:item.covered_securities,
        institutionalValueM:item.institutional_value_m,marketCapM:item.market_cap_m,
        institutionalOwnershipPct:item.institutional_ownership_pct,
        netChangeValueM:item.net_change_value_m,netChangePctMarketCap:item.net_change_pct_market_cap,
      }])),
    });
  }
  return history;
}

function compactRows(rows=[]) {
  return rows.map(row=>({
    ticker:row.ticker,name:row.name??null,holders:row.holders??0,
    newPositions:row.newPositions??0,increases:row.increases??0,
    reductions:row.reductions??0,exits:row.exits??0,
    currentUnitsK:row.currentUnitsK??null,netUnitsChangeK:row.netUnitsChangeK??null,
    netChangeValueM:row.netChangeValueM??null,
    netChangePctOutstanding:row.netChangePctOutstanding??null,
    splitAdjustedFilers:row.splitAdjustedFilers??0,segments:row.segments??['all'],
  }));
}

function compactInstitutions(rows=[]) {
  return rows.map(row=>({
    investorId:row.investorId,name:row.name,holdings:row.holdings??0,
    newPositions:row.newPositions??0,increases:row.increases??0,
    reductions:row.reductions??0,exits:row.exits??0,currentValueM:row.currentValueM??null,
  }));
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

function securityHistory(source, visible, selected, selectedData, ticker) {
  const db=source.insightsDb??source.db;
  if (tableExists(db,'institutional_13f_security_history_v1')) {
    return db.prepare(`SELECT h.report_date reportDate,h.available_at availableAt,h.holders,
      h.institutional_shares_k institutionalSharesK,h.shares_outstanding_k sharesOutstandingK,
      h.institutional_ownership_pct institutionalOwnershipPct
      FROM institutional_13f_security_history_v1 h
      JOIN institutional_13f_insight_snapshots_v2 s
        ON s.report_date=h.report_date AND s.source_generation=h.source_generation
      WHERE h.ticker=? AND h.report_date<=? AND s.available_at<=?
        AND s.generated_at=(SELECT max(n.generated_at) FROM institutional_13f_insight_snapshots_v2 n
          WHERE n.report_date=s.report_date AND n.available_at<=?)
      ORDER BY h.report_date`).all(ticker,selected.report_date,selected.available_at,selected.available_at);
  }
  const bounded=visible.filter(row=>row.report_date<=selected.report_date);
  const key=bounded.map(snapshotKey).join(';');
  const entries=cacheEntries(historyIndexCache,source);
  if (entries.has(key)) return entries.get(key).get(ticker)??[];
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
  return histories.get(ticker)??[];
}

export function institutional13fInsights(source, asOf, reportDate = null, ticker = null) {
  const {payload,selected,visible,quarters}=visibleSnapshot(source,asOf,reportDate);
  const mostIncreased=payload.rows.reduce((best,row)=>(row.increases??0)>(best?.increases??-1)?row:best,null);
  const selectedTicker=typeof ticker==='string' && /^[A-Z][A-Z0-9.-]{0,14}$/.test(ticker)
    ? ticker
    : mostIncreased?.ticker;
  const boundedDetails=selectedTicker
    ? {[selectedTicker]:{
      ...lazyDetail(source,selected,selectedTicker,payload),
      history:securityHistory(source,visible,selected,payload,selectedTicker),
    }}
    : {};
  const {details:allDetails,rows,institutions,...summary}=payload;
  return {
    ...summary,
    rows:compactRows(rows),
    institutions:compactInstitutions(institutions),
    asOf,
    selectedTicker,
    quarters,
    generatedAt: selected.generated_at,
    marketHistory: marketHistory(source,visible,selected),
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
      ...lazyDetail(source,selected,ticker,payload),
      history:securityHistory(source,visible,selected,payload,ticker),
    },
  };
}
