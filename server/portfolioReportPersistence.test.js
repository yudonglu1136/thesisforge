import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';

const root=fs.mkdtempSync(path.join(os.tmpdir(),'portfolio-persistence-test-'));
process.env.USER_PORTFOLIO_DATA_DIR=path.join(root,'users');
process.env.SQLITE_DB_PATH=path.join(root,'research.sqlite');
process.env.PORTFOLIO_CREDENTIALS_KEY='synthetic-persistence-secret';
const store=await import('./userPortfolioStore.js');
const {loadPortfolioDashboard,clearPortfolioCache}=await import('./portfolioClient.js');
const {analysePortfolio}=await import('./investmentPortfolio.js');
const originalFetch=globalThis.fetch;
test.after(()=>{globalThis.fetch=originalFetch;store.closeUserPortfolioStores();fs.rmSync(root,{recursive:true,force:true});});

const config=(token='SYNTHETIC_TOKEN_123456',query='123456')=>({ibkrFlexToken:token,ibkrFlexQueryId:query});
const payload=(date='2026-09-09',ticker='AAA')=>({
  generatedAt:'2026-09-10T12:00:00.000Z',source:{userScoped:true,mode:'live',asOf:date,warnings:[]},
  connection:{status:'linked',ibkrFlexToken:'must-not-be-stored'},
  accounts:[{id:'synthetic-account',currency:'USD',value:1200}],
  summary:{totalValue:1200,holdings:1},holdings:[{ticker,quantity:10,value:1200}],
  transactions:[{symbol:ticker,quantity:10}],performance:[{date,value:1200}],
  analysisAccounts:[{currency:'USD',reportDate:date,reportedNav:1200,
    positions:[{ticker,assetCategory:'STK',currency:'USD',quantity:10,price:120,localValue:1200}],
    navHistory:[{date:'2026-09-08',nav:1000},{date,nav:1200}]}]
});
const options=user=>({connectionRevision:store.portfolioConnectionRevision(user),now:new Date('2026-09-12T12:00:00Z')});

test('encrypted report inputs survive restart and preserve owner isolation, credentials and NAV',()=>{
  const a={id:'persistence-owner-a'},b={id:'persistence-owner-b'};
  store.savePortfolioConnection(a,config());store.savePortfolioConnection(b,config('SYNTHETIC_OTHER_123456','234567'));
  store.writeUserPortfolioNavPoint(a,{accountId:'synthetic-account',date:'2026-09-09',nav:1200});
  const expected=payload();store.writeUserPortfolioReport(a,expected,options(a));
  store.closeUserPortfolioStores();
  const restored=store.readUserPortfolioReport(a);
  assert.deepEqual(restored.payload.analysisAccounts,expected.analysisAccounts);
  assert.deepEqual(restored.payload.transactions,expected.transactions);
  assert.equal(restored.payload.connection,undefined);
  assert.equal(restored.reportAsOf,'2026-09-09');
  assert.equal(store.readUserPortfolioReport(b),null);
  assert.equal(store.readPortfolioConnection(a).config.ibkrFlexToken,config().ibkrFlexToken);
  assert.equal(store.readUserPortfolioNavPoints(a,'synthetic-account')[0].nav,1200);
  const db=new DatabaseSync(store.userPortfolioInfo(a).path,{readOnly:true});
  try {
    const row=db.prepare('SELECT encrypted_json FROM portfolio_report_snapshots').get();
    assert.ok(!row.encrypted_json.includes('synthetic-account'));
    assert.ok(!row.encrypted_json.includes('must-not-be-stored'));
  } finally {db.close();}
});

test('failed, partial, sampled, undated and older reports never replace last good report',()=>{
  const user={id:'persistence-validation'};store.savePortfolioConnection(user,config());
  store.writeUserPortfolioReport(user,payload(),options(user));
  for (const mutate of [p=>p.source.mode='sample',p=>p.source.userScoped=false,p=>p.source.asOf=null,
    p=>p.source.asOf='2026-02-30',p=>p.connection.status='linked_partial',p=>p.connection.status='error',
    p=>p.analysisAccounts[0].reportDate=null,p=>p.source.asOf='2027-01-01']) {
    const candidate=payload();mutate(candidate);
    assert.throws(()=>store.writeUserPortfolioReport(user,candidate,options(user)),/not_verified/);
  }
  assert.throws(()=>store.writeUserPortfolioReport(user,payload('2026-09-08'),options(user)),/older_than_saved/);
  assert.equal(store.readUserPortfolioReport(user).reportAsOf,'2026-09-09');
});

test('disconnect and replaced account configuration cannot resurrect or publish an old report',()=>{
  const user={id:'persistence-replace'};store.savePortfolioConnection(user,config());
  const old=options(user);store.writeUserPortfolioReport(user,payload(),old);
  store.deletePortfolioConnection(user);assert.equal(store.readUserPortfolioReport(user),null);
  assert.throws(()=>store.writeUserPortfolioReport(user,payload(),old),/connection_changed/);
  store.restorePortfolioConnection(user);assert.equal(store.readUserPortfolioReport(user).reportAsOf,'2026-09-09');
  store.savePortfolioConnection(user,config('SYNTHETIC_REPLACE_123456','345678'));
  assert.equal(store.readUserPortfolioReport(user),null);
  assert.throws(()=>store.writeUserPortfolioReport(user,payload(),old),/connection_changed/);
});

test('successful broker load persists; outage after restart returns the dated report, never empty holdings',async()=>{
  const user={id:'persistence-broker-load'};store.savePortfolioConnection(user,config());
  globalThis.fetch=async input=>{
    const url=new URL(input);assert.equal(url.hostname,'ndcdyn.interactivebrokers.com');
    return {ok:true,text:async()=>url.pathname.endsWith('SendRequest')
      ? '<FlexStatementResponse><Status>Success</Status><ReferenceCode>FIXTURE</ReferenceCode></FlexStatementResponse>'
      : '<FlexQueryResponse><FlexStatements><FlexStatement accountId="FIXTURE" fromDate="20260908" toDate="20260909" currency="USD"><AccountInformation currency="USD"/><EquitySummaryByReportDateInBase total="1200" cash="0" reportDate="20260909"/><OpenPositions><OpenPosition symbol="AAA" assetCategory="STK" currency="USD" quantity="10" markPrice="120" positionValue="1200"/></OpenPositions></FlexStatement></FlexStatements></FlexQueryResponse>'};
  };
  const fresh=await loadPortfolioDashboard({user,forceRefresh:true});
  assert.equal(fresh.freshness?.status,'current_report');
  assert.equal(fresh.holdings[0].ticker,'AAA');
  assert.equal(store.readUserPortfolioReport(user).reportAsOf,'2026-09-09');
  const navDb=new DatabaseSync(store.userPortfolioInfo(user).path,{readOnly:true});
  const navBefore=navDb.prepare('SELECT * FROM portfolio_nav_points ORDER BY account_id,date').all();
  clearPortfolioCache(user);
  const primed=await loadPortfolioDashboard({user,forceRefresh:true,captureNav:false});
  assert.equal(primed.freshness.status,'current_report');
  assert.deepEqual(navDb.prepare('SELECT * FROM portfolio_nav_points ORDER BY account_id,date').all(),navBefore);
  navDb.close();
  clearPortfolioCache(user);store.closeUserPortfolioStores();
  globalThis.fetch=async()=>{throw new Error('Synthetic broker outage');};
  const stale=await loadPortfolioDashboard({user,forceRefresh:true});
  assert.equal(stale.connection.status,'stale_report');
  assert.equal(stale.freshness.status,'stale');
  assert.equal(stale.freshness.reportAsOf,'2026-09-09');
  assert.equal(stale.source.asOf,'2026-09-09');
  assert.equal(stale.source.mode,'saved_broker_report');
  // The HTTP wire format represents any legacy non-finite display input as
  // null; the durable payload must reproduce that same JSON representation.
  assert.deepEqual(stale.holdings,JSON.parse(JSON.stringify(fresh.holdings)));
  assert.deepEqual(stale.analysisAccounts,fresh.analysisAccounts);
  const analysis=analysePortfolio(stale,{asOf:'2026-09-12'});
  assert.equal(analysis.status,'ready');assert.equal(analysis.freshness.status,'stale');
  assert.equal(analysis.groups[0].positions[0].ticker,'AAA');
  assert.deepEqual(analysis.groups[0].reportDates,['2026-09-09']);
  assert.equal(store.readUserPortfolioReport(user).reportAsOf,'2026-09-09');
  const other={id:'persistence-outage-no-report'};store.savePortfolioConnection(other,config());
  const absent=await loadPortfolioDashboard({user:other,forceRefresh:true});
  assert.equal(absent.source.mode,'error');assert.equal(absent.holdings.length,0);
});

test('ordinary portfolio reads use the saved owner report without contacting the broker',async()=>{
  const user={id:'persistence-fast-read'};store.savePortfolioConnection(user,config());
  store.writeUserPortfolioReport(user,payload(),options(user));
  store.writeUserPortfolioNavPoint(user,{accountId:'synthetic-account',date:'2026-09-07',nav:900});
  store.writeUserPortfolioNavPoint(user,{accountId:'synthetic-account',date:'2026-09-09',nav:1200});
  clearPortfolioCache(user);
  let brokerRequests=0;
  globalThis.fetch=async()=>{brokerRequests+=1;throw new Error('ordinary reads must not contact IBKR');};
  const saved=await loadPortfolioDashboard({user,includeAnalytics:false});
  assert.equal(brokerRequests,0);
  assert.equal(saved.freshness.status,'current_report');
  assert.equal(saved.freshness.reportAsOf,'2026-09-09');
  assert.equal(saved.connection.status,'linked');
  assert.equal(saved.holdings[0].ticker,'AAA');
  assert.deepEqual(saved.analysisAccounts[0].navHistory.map(row=>row.date),[
    '2026-09-07','2026-09-08','2026-09-09'
  ]);
  assert.equal(saved.analysisAccounts[0].navHistoryStatus.pointCount,3);
});

test('history query failure refreshes current holdings while retaining only verified historical evidence',async()=>{
  const connection={...config(),ibkrFlexHistoryQueryId:'987654'};
  const existing={id:'persistence-history-existing'},first={id:'persistence-history-first'};
  store.savePortfolioConnection(existing,connection);store.savePortfolioConnection(first,connection);
  const complete=payload();complete.analysisAccounts[0].historyEvidence={fromDate:'2026-01-01',toDate:'2026-09-09',tradeStatus:'ready',realized:[{pnl:50}]};
  store.writeUserPortfolioReport(existing,complete,options(existing));
  globalThis.fetch=async input=>{
    const url=new URL(input);
    if(url.searchParams.get('q')==='987654')throw new Error('Synthetic history query failure');
    return {ok:true,text:async()=>url.pathname.endsWith('SendRequest')
      ? '<FlexStatementResponse><Status>Success</Status><ReferenceCode>FIXTURE</ReferenceCode></FlexStatementResponse>'
      : '<FlexQueryResponse><FlexStatements><FlexStatement accountId="FIXTURE" fromDate="20260908" toDate="20260909" currency="USD"><AccountInformation currency="USD"/><EquitySummaryByReportDateInBase total="1200" cash="0" reportDate="20260909"/><OpenPositions><OpenPosition symbol="AAA" assetCategory="STK" currency="USD" quantity="10" markPrice="120" positionValue="1200"/></OpenPositions></FlexStatement></FlexStatements></FlexQueryResponse>'};
  };
  const fresh=await loadPortfolioDashboard({user:existing,forceRefresh:true});
  assert.equal(fresh.freshness.status,'current_report');
  assert.equal(fresh.source.historyQueryStatus,'error');
  assert.deepEqual(fresh.analysisAccounts[0].historyEvidence,complete.analysisAccounts[0].historyEvidence);
  assert.equal(fresh.analysisAccounts[0].historyEvidenceStatus,'retained_from_last_verified_report');
  assert.equal(store.readUserPortfolioReport(existing).payload.analysisAccounts[0].historyEvidenceStatus,
    'retained_from_last_verified_report');
  const current=await loadPortfolioDashboard({user:first,forceRefresh:true});
  assert.equal(current.connection.status,'linked');assert.equal(current.holdings[0].ticker,'AAA');
  assert.equal(current.freshness.status,'current_report');
  assert.equal(current.source.historyQueryStatus,'error');
  assert.equal(store.readUserPortfolioReport(first).reportAsOf,'2026-09-09');
});

test('partial multi-account refresh keeps the last complete dated portfolio',async()=>{
  const user={id:'persistence-multi'};
  store.savePortfolioConnection(user,{accounts:[config(),config('SYNTHETIC_SECOND_123456','234567')]});
  const complete=payload();complete.accounts.push({id:'second',currency:'USD',value:1200});
  complete.analysisAccounts.push({...complete.analysisAccounts[0],accountNumber:2});
  store.writeUserPortfolioReport(user,complete,options(user));
  globalThis.fetch=async input=>{
    const url=new URL(input);
    if(url.searchParams.get('q')==='234567')throw new Error('Synthetic second account outage');
    return {ok:true,text:async()=>url.pathname.endsWith('SendRequest')
      ? '<FlexStatementResponse><Status>Success</Status><ReferenceCode>FIRST</ReferenceCode></FlexStatementResponse>'
      : '<FlexQueryResponse><FlexStatements><FlexStatement accountId="FIRST" fromDate="20260909" toDate="20260910" currency="USD"><AccountInformation currency="USD"/><EquitySummaryByReportDateInBase total="1400" reportDate="20260910"/><OpenPosition symbol="BBB" assetCategory="STK" currency="USD" quantity="10" markPrice="140" positionValue="1400"/></FlexStatement></FlexStatements></FlexQueryResponse>'};
  };
  const result=await loadPortfolioDashboard({user,forceRefresh:true});
  assert.equal(result.freshness.status,'stale');assert.equal(result.accounts.length,2);
  assert.equal(result.source.asOf,'2026-09-09');assert.equal(result.holdings[0].ticker,'AAA');
  assert.equal(store.readUserPortfolioReport(user).reportAsOf,'2026-09-09');
});

test('in-flight broker result cannot publish after the connection is replaced',async()=>{
  const user={id:'persistence-inflight'};store.savePortfolioConnection(user,config());
  let changed=false;
  globalThis.fetch=async input=>{
    const url=new URL(input);
    if(!changed){changed=true;store.savePortfolioConnection(user,config('SYNTHETIC_NEW_123456','345678'));}
    return {ok:true,text:async()=>url.pathname.endsWith('SendRequest')
      ? '<FlexStatementResponse><Status>Success</Status><ReferenceCode>OLD</ReferenceCode></FlexStatementResponse>'
      : '<FlexQueryResponse><FlexStatements><FlexStatement accountId="OLD" fromDate="20260908" toDate="20260909" currency="USD"><AccountInformation currency="USD"/><EquitySummaryByReportDateInBase total="1200" reportDate="20260909"/><OpenPosition symbol="OLD" assetCategory="STK" currency="USD" quantity="10" markPrice="120" positionValue="1200"/></FlexStatement></FlexStatements></FlexQueryResponse>'};
  };
  const result=await loadPortfolioDashboard({user,forceRefresh:true});
  assert.equal(result.source.mode,'error');assert.equal(result.holdings.length,0);
  assert.equal(store.readUserPortfolioReport(user),null);
  assert.equal(store.readPortfolioConnection(user).config.ibkrFlexQueryId,'345678');
});

test('report ciphertext is bound to its owner and fails if moved to another owner store',()=>{
  const a={id:'persistence-aad-a'},b={id:'persistence-aad-b'};
  for(const user of [a,b])store.savePortfolioConnection(user,config());
  store.writeUserPortfolioReport(a,payload(),options(a));
  const source=new DatabaseSync(store.userPortfolioInfo(a).path,{readOnly:true});
  const target=new DatabaseSync(store.userPortfolioInfo(b).path);
  try {
    const row=source.prepare('SELECT * FROM portfolio_report_snapshots').get();
    target.prepare('INSERT INTO portfolio_report_snapshots VALUES(?,?,?,?,?,?)')
      .run(row.provider,store.portfolioConnectionRevision(b),row.report_date,row.retrieved_at,row.payload_sha256,row.encrypted_json);
  } finally {source.close();target.close();}
  assert.throws(()=>store.readUserPortfolioReport(b));
});
