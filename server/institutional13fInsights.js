import { assert, isoDate } from './investmentMath.js';
import { gunzipSync } from 'node:zlib';

const parse = row => {
  if (!row) return null;
  if (row.payload_gzip) return JSON.parse(gunzipSync(row.payload_gzip).toString('utf8'));
  return JSON.parse(row.payload_json);
};

const selectedPayloadCache = new WeakMap();
const snapshotValueCache = new WeakMap();
const securityHistoryCache = new WeakMap();
const historyIndexCache = new WeakMap();
const tableAvailabilityCache = new WeakMap();
const tableColumnCache = new WeakMap();
const summaryResponseCache = new WeakMap();

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
  const db=source.insightsDb??source.db;
  const compressed=row.snapshot_table.endsWith('_v2');
  const payloadColumn=compressed?'payload_gzip':'payload_json';
  const payload=parse(db.prepare(`SELECT ${payloadColumn} FROM ${row.snapshot_table}
    WHERE report_date=? AND source_generation=? AND generated_at=?`).get(
    row.report_date,row.source_generation,row.generated_at,
  ));
  setBounded(entries,key,payload,8);
  return payload;
}

function snapshotValues(source,row,payload=null) {
  const entries=cacheEntries(snapshotValueCache,source);
  const key=snapshotKey(row);
  if (entries.has(key)) return entries.get(key);
  const data=payload??selectedPayload(source,row);
  const values=new Map((data?.rows??[]).flatMap(item=>item?.ticker&&item.currentValueM!=null
    ?[[item.ticker,item.currentValueM]]:[]));
  setBounded(entries,key,values,24);
  return values;
}

function tableExists(source,name) {
  const db=source.insightsDb??source.db;
  let tables=tableAvailabilityCache.get(source);
  if (!tables) {
    tables=new Set(db.prepare(
      "SELECT name FROM sqlite_master WHERE type='table'"
    ).all().map(row=>row.name));
    tableAvailabilityCache.set(source,tables);
  }
  return tables.has(name);
}

function tableColumns(source,name) {
  let tables=tableColumnCache.get(source);
  if (!tables) {tables=new Map();tableColumnCache.set(source,tables);}
  if (!tables.has(name)) {
    const db=source.insightsDb??source.db;
    tables.set(name,new Set(db.prepare(`PRAGMA table_info(${name})`).all().map(row=>row.name)));
  }
  return tables.get(name);
}

function visibleRows(db,table,asOf) {
  return db.prepare(`
    SELECT report_date,source_generation,available_at,generated_at,payload_hash
    FROM ${table} s
    WHERE available_at<=?
      AND generated_at=(
        SELECT max(generated_at) FROM ${table} n
        WHERE n.report_date=s.report_date AND n.available_at<=?
      )
    ORDER BY report_date DESC
  `).all(asOf,asOf).map(row=>({...row,snapshot_table:table}));
}

function lazyDetail(source, selected, ticker, payload) {
  const db=source.insightsDb??source.db;
  let detail;
  if (tableExists(source,'institutional_13f_insight_details_v1')) {
    const row=db.prepare(`SELECT payload_gzip FROM institutional_13f_insight_details_v1
      WHERE report_date=? AND source_generation=? AND ticker=?`).get(
      selected.report_date,selected.source_generation,ticker,
    );
    if (row?.payload_gzip) detail=parse(row)??{};
  }
  detail??=payload.details?.[ticker]??{};
  return normalizeDetail(detail,payload.institutions);
}

function normalizeDetail(detail,institutions=[]) {
  const filings=new Map((institutions??[]).map(row=>[row.investorId,row]));
  return Object.fromEntries(Object.entries(detail).map(([action,rows])=>[
    action,(rows??[]).filter(row=>{
      const filing=filings.get(row.investorId);
      // Older artifacts may contain every prior holding as an "exit" when the
      // filer itself is absent in the current SF3 quarter (and vice versa for a
      // newly appearing filer). A missing whole filing is not a position move.
      return !filing||(filing.currentValueM!=null&&filing.previousValueM!=null);
    }).map(row=>{
      const current=Number.isFinite(row.currentValueM)?row.currentValueM:null;
      const previous=Number.isFinite(row.previousValueM)?row.previousValueM:null;
      const activityValueM=action==='exited'?previous:current;
      const reportedValueChangeM=current!=null&&previous!=null?current-previous
        :action==='new'?current
          :action==='exited'&&previous!=null?-previous:null;
      return {...row,
        activityValueM,
        reportedValueChangeM,
        // A complete exit is mechanically -100% by definition. Repeating that
        // number for every exited filer is not a useful comparison metric and
        // was easily misread as a portfolio return. Exits are compared by the
        // prior-quarter reported position value instead.
        changePct:['increased','reduced'].includes(action)?row.changePct:null,
        comparisonBasis:action==='exited'?'prior_reported_position_value'
          :action==='new'?'current_reported_position_value'
            :'split_adjusted_reported_units',
      };
    }),
  ]));
}

function marketHistory(source, visible, selected) {
  const db=source.insightsDb??source.db;
  if (!tableExists(source,'institutional_13f_market_history_v1')) return [];
  const bounded=visible.filter(row=>row.report_date<=selected.report_date);
  const visibleByKey=new Map(bounded.map(row=>[
    `${row.report_date}|${row.source_generation}`,row,
  ]));
  const grouped=new Map();
  const metrics=db.prepare(`SELECT report_date,source_generation,segment,securities,covered_securities,
    institutional_value_m,market_cap_m,institutional_ownership_pct,net_change_value_m,
    net_change_pct_market_cap FROM institutional_13f_market_history_v1
    WHERE report_date<=? ORDER BY report_date,segment`).all(selected.report_date);
  for (const item of metrics) {
    const key=`${item.report_date}|${item.source_generation}`;
    if (!visibleByKey.has(key)) continue;
    const segmentRows=grouped.get(key)??[];
    segmentRows.push(item);
    grouped.set(key,segmentRows);
  }
  return [...bounded].reverse().flatMap(row=>{
    const items=grouped.get(`${row.report_date}|${row.source_generation}`)??[];
    if (!items.length) return [];
    return [{
      reportDate:row.report_date, availableAt:row.available_at,
      segments:Object.fromEntries(items.map(item=>[item.segment,{
        securities:item.securities,coveredSecurities:item.covered_securities,
        institutionalValueM:item.institutional_value_m,marketCapM:item.market_cap_m,
        institutionalOwnershipPct:item.institutional_ownership_pct,
        netChangeValueM:item.net_change_value_m,netChangePctMarketCap:item.net_change_pct_market_cap,
      }])),
    }];
  });
}

function compactRows(rows=[]) {
  return rows.map(row=>({
    ticker:row.ticker,name:row.name??null,holders:row.holders??0,
    newPositions:row.newPositions??0,increases:row.increases??0,
    reductions:row.reductions??0,exits:row.exits??0,
    currentUnitsK:row.currentUnitsK??null,netUnitsChangeK:row.netUnitsChangeK??null,
    netChangeValueM:row.netChangeValueM??null,
    netChangePctOutstanding:row.netChangePctOutstanding??null,
    institutionalOwnershipPct:row.institutionalOwnershipPct??null,
    splitAdjustedFilers:row.splitAdjustedFilers??0,segments:row.segments??['all'],
  }));
}

function visibleSnapshot(source, asOf, reportDate = null) {
  isoDate(asOf);
  if (reportDate) isoDate(reportDate);
  const db=source.insightsDb??source.db;
  const tables=[
    'institutional_13f_insight_snapshots_v2',
    'institutional_13f_insight_snapshots',
  ].filter(table=>tableExists(source,table));
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
  const bounded=visible.filter(row=>row.report_date<=selected.report_date);
  const cacheKey=`${bounded.map(snapshotKey).join(';')}|${ticker}`;
  const cached=cacheEntries(securityHistoryCache,source);
  if (cached.has(cacheKey)) return cached.get(cacheKey);
  if (tableExists(source,'institutional_13f_security_history_v1')) {
    const hasValue=tableColumns(source,'institutional_13f_security_history_v1').has('institutional_value_m');
    const history=db.prepare(`SELECT h.report_date reportDate,h.available_at availableAt,h.holders,
      h.institutional_shares_k institutionalSharesK,h.shares_outstanding_k sharesOutstandingK,
      h.institutional_ownership_pct institutionalOwnershipPct,
      ${hasValue?'h.institutional_value_m':'NULL'} institutionalValueM
      FROM institutional_13f_security_history_v1 h
      JOIN institutional_13f_insight_snapshots_v2 s
        ON s.report_date=h.report_date AND s.source_generation=h.source_generation
      WHERE h.ticker=? AND h.report_date<=? AND s.available_at<=?
        AND s.generated_at=(SELECT max(n.generated_at) FROM institutional_13f_insight_snapshots_v2 n
          WHERE n.report_date=s.report_date AND n.available_at<=?)
      ORDER BY h.report_date`).all(ticker,selected.report_date,selected.available_at,selected.available_at);
    if (history.every(row=>row.institutionalValueM!=null)) {
      setBounded(cached,cacheKey,history,96);
      return history;
    }
    const values=new Map();
    for (const snapshot of [...bounded].reverse()) {
      const value=snapshotValues(source,snapshot,snapshot===selected?selectedData:null).get(ticker);
      if (value!=null) values.set(snapshot.report_date,value);
    }
    const enriched=history.map(row=>({...row,
      institutionalValueM:row.institutionalValueM??values.get(row.reportDate)??null,
    }));
    setBounded(cached,cacheKey,enriched,96);
    return enriched;
  }
  const key=bounded.map(snapshotKey).join(';');
  const entries=cacheEntries(historyIndexCache,source);
  if (entries.has(key)) {
    const history=entries.get(key).get(ticker)??[];
    setBounded(cached,cacheKey,history,96);
    return history;
  }
  const histories=new Map();
  for (const snapshot of [...bounded].reverse()) {
    const payload=snapshot===selected ? selectedData : selectedPayload(source,snapshot);
    for (const row of payload?.rows??[]) {
      if (!row?.ticker) continue;
      const history=histories.get(row.ticker)??[];
      history.push({
        reportDate:payload.reportDate??snapshot.report_date,
        availableAt:payload.availableAt??snapshot.available_at,
        holders:row.holders??null,
        institutionalValueM:row.currentValueM??null,
        institutionalSharesK:row.currentUnitsK??null,
        sharesOutstandingK:row.sharesOutstandingK??null,
        institutionalOwnershipPct:row.institutionalOwnershipPct??null,
      });
      histories.set(row.ticker,history);
    }
  }
  setBounded(entries,key,histories,1);
  const history=histories.get(ticker)??[];
  setBounded(cached,cacheKey,history,96);
  return history;
}

const actionKey=action=>({new:'newPositions',reduced:'reductions',exited:'exits'}[action]??'increases');

function queryOptions(input) {
  if (typeof input==='string') return queryOptions({ticker:input,includeDetail:true});
  const value=input&&typeof input==='object'?input:{};
  const action=['new','increased','reduced','exited'].includes(value.action)?value.action:'increased';
  const rank=['amount','shareChange','institutions','sharesHeldPct'].includes(value.rank)?value.rank:'amount';
  const segment=['all','sp500','nasdaq100Proxy','smallCap'].includes(value.segment)?value.segment:'all';
  const search=String(value.search??'').trim().slice(0,80).toLowerCase();
  const parsedLimit=Number.parseInt(value.limit,10);
  const limit=Number.isInteger(parsedLimit)?Math.min(200,Math.max(20,parsedLimit)):100;
  const ticker=typeof value.ticker==='string'&&/^[A-Z][A-Z0-9.-]{0,14}$/.test(value.ticker)
    ?value.ticker:null;
  return {action,rank,segment,search,limit,ticker,includeDetail:Boolean(value.includeDetail)};
}

function rankedRows(rows,options) {
  const key=actionKey(options.action);
  const filtered=rows.filter(row=>(row[key]??0)>0
    &&(options.segment==='all'||(row.segments??[]).includes(options.segment))
    &&(!options.search||`${row.ticker??''} ${row.name??''}`.toLowerCase().includes(options.search)));
  const metric=row=>options.rank==='shareChange'?Math.abs(row.netChangePctOutstanding??0)
    :options.rank==='institutions'?(row.holders??0)
      :options.rank==='sharesHeldPct'?(row.institutionalOwnershipPct??0)
        :Math.abs(row.netChangeValueM??0);
  filtered.sort((left,right)=>metric(right)-metric(left)
    ||(right[key]??0)-(left[key]??0)
    ||String(left.ticker).localeCompare(String(right.ticker)));
  return filtered;
}

function actionLeaders(rows) {
  return Object.fromEntries(['new','increased','reduced','exited'].map(action=>{
    const key=actionKey(action);
    const leaders=[...rows].filter(row=>(row[key]??0)>0)
      .sort((left,right)=>(right[key]??0)-(left[key]??0)
        ||String(left.ticker).localeCompare(String(right.ticker)))
      .slice(0,2);
    return [action,compactRows(leaders)];
  }));
}

export function institutional13fInsights(source, asOf, reportDate = null, input = null) {
  const options=queryOptions(input);
  const {payload,selected,visible,quarters}=visibleSnapshot(source,asOf,reportDate);
  const responseKey=`${snapshotKey(selected)}|${asOf}|${options.action}|${options.rank}|${options.segment}|${options.search}|${options.limit}|${options.ticker??''}|${options.includeDetail}`;
  const responseEntries=cacheEntries(summaryResponseCache,source);
  if (responseEntries.has(responseKey)) return responseEntries.get(responseKey);
  const matches=rankedRows(payload.rows??[],options);
  const requestedRow=options.ticker
    ?matches.find(row=>row.ticker===options.ticker)
    :null;
  const selectedTicker=requestedRow?.ticker??matches[0]?.ticker??null;
  const boundedDetails=options.includeDetail&&selectedTicker
    ? {[selectedTicker]:{
      ...lazyDetail(source,selected,selectedTicker,payload),
      history:securityHistory(source,visible,selected,payload,selectedTicker),
    }}
    : {};
  const {details:allDetails,rows,institutions,...summary}=payload;
  const response={
    ...summary,
    rows:compactRows(matches.slice(0,options.limit)),
    totalMatches:matches.length,
    rowLimit:options.limit,
    actionLeaders:actionLeaders(rows??[]),
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
  setBounded(responseEntries,responseKey,response,96);
  return response;
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
