import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {reportAnalysisAccounts} from './portfolioReport.js';
import {portfolioIncome, portfolioPassiveIncome} from './portfolioIncome.js';
import {importOwnerReport, localOwnerPortfolio} from './portfolioSnapshotStore.js';

const receipt = (type, amount, symbol, extra = {}) => ({type, amount, symbol, currency:'USD', dateTime:'20260105;120000', ...extra});
const statement = () => ({accountId:'test-owner-only', fromDate:'20260101', toDate:'20260131',
  AccountInformation:{currency:'USD', primaryEmail:'synthetic@example.test'},
  CashTransactions:{CashTransaction:[receipt('Dividends',100,'AAA'),receipt('Bond Interest Received',80,'BOND'),
    receipt('Broker Interest Received',5,''),receipt('Payment In Lieu Of Dividends',15,'BBB'),
    receipt('Dividends',-2,'AAA'),receipt('Withholding Tax',-15,'AAA'),receipt('Broker Interest Paid',-20,''),
    receipt('Bond Interest Paid',-4,'BOND'),receipt('Deposits/Withdrawals',1000,''),receipt('Other Fees',-3,'')]},
  // These are deliberately unrelated to actual received income.
  ChangeInDividendAccruals:{amount:9999}, OpenPosition:{symbol:'NOT_INCOME',positionValue:50000},
});
const accounts = s => reportAnalysisAccounts({FlexStatement:s});
test('income is the positive cash receipt distribution, not accruals, NAV, P&L or net yield',()=>{
  const result = portfolioIncome(accounts(statement()));
  assert.equal(result.status,'ready');assert.equal(result.grossReceived,200);assert.equal(result.reversals,-2);
  assert.equal(result.eventCount,5);assert.equal(result.byInstrument.length,4);
  assert.deepEqual(result.byType.map(r=>r.amount),[100,80,5,15]);
  assert.equal(result.byInstrument.reduce((s,r)=>s+r.weight,0),1);
  assert.ok(result.byInstrument.every(r=>r.amount>0));
});
test('income FX is transaction-date reported FX, never an assumed current rate',()=>{
  const s=statement();s.CashTransactions.CashTransaction=[receipt('Dividends',20,'AAA',{currency:'GBP',fxRateToBase:1.25})];
  assert.equal(portfolioIncome(accounts(s)).grossReceived,25);
  const e=accounts(s)[0].historyEvidence.income[0];
  assert.equal(e.sourceAmount,20);assert.equal(e.sourceCurrency,'GBP');assert.equal(e.fxRateToBase,1.25);
  delete s.CashTransactions.CashTransaction[0].fxRateToBase;
  assert.equal(portfolioIncome(accounts(s)).grossReceived,null);
});
test('missing sections, unknown categories, invalid dates/amounts/currencies and duplicates fail closed',()=>{
  for(const mutate of [s=>delete s.CashTransactions,
    s=>s.CashTransactions.CashTransaction.push(receipt('Unrecognized income',4,'AAA')),
    s=>s.CashTransactions.CashTransaction.push({...s.CashTransactions.CashTransaction[0]}),
    s=>s.CashTransactions.CashTransaction[0].dateTime='20260230',
    s=>s.CashTransactions.CashTransaction[0].dateTime='20260201',
    s=>s.CashTransactions.CashTransaction[0].amount='',
    s=>s.CashTransactions.CashTransaction[0].currency='',
    s=>s.CashTransactions.CashTransaction[0].symbol='']) {
    const s=statement();mutate(s);const result=portfolioIncome(accounts(s));
    assert.equal(result.grossReceived,null);assert.deepEqual(result.byInstrument,[]);
  }
});
test('explicit empty, zero and negative-only receipt histories do not invent a pie',()=>{
  for(const cash of [[],[receipt('Dividends',0,'AAA')],[receipt('Dividends',-10,'AAA')]]) {
    const s=statement();s.CashTransactions={CashTransaction:cash};const result=portfolioIncome(accounts(s));
    assert.equal(result.status,'ready');assert.equal(result.grossReceived,0);assert.deepEqual(result.byInstrument,[]);
  }
});
test('multi-account income uses a common report period, preserves same receipts across different accounts',()=>{
  const a=accounts(statement())[0],b=structuredClone(a);
  assert.equal(portfolioIncome([a,b]).grossReceived,400);
  b.historyEvidence.fromDate='2026-01-06';assert.equal(portfolioIncome([a,b]).grossReceived,0);
  b.historyEvidence.incomeStatus='cash_section_missing';assert.equal(portfolioIncome([a,b]).grossReceived,null);
});
test('v4 stores income structurally with provenance; pre-income snapshots stay readable and explicitly unavailable',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'income-test-'));
  try {
    const file=path.join(dir,'test.sqlite');
    const imported=importOwnerReport({report:{FlexStatement:statement()},file,expectedEmail:'synthetic@example.test',
      metadata:{source:'synthetic fixture',retrievedAt:'2026-02-01',sha256:'a'.repeat(64)}});
    const env={API_AUTH_DEV_BYPASS:'true',INVESTMENT_WORKFLOW_ENABLED:'true',LOCAL_OWNER_PORTFOLIO_DB:file,LOCAL_OWNER_PORTFOLIO_HASH:imported.ownerHash};
    const loaded=localOwnerPortfolio({id:'local-dev-user'},env);
    assert.equal(portfolioIncome(loaded.analysisAccounts).grossReceived,200);
    assert.ok(!JSON.stringify(loaded).includes('synthetic@example.test'));
    assert.ok(!JSON.stringify(loaded).includes('test-owner-only'));
    const db=new DatabaseSync(file);assert.equal(db.prepare('select count(*) n from income_events').get().n,5);
    assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check,'ok');
    db.exec("UPDATE snapshot SET version='owner-portfolio-v3'; DROP TABLE income_events;");db.close();
    assert.equal(portfolioIncome(localOwnerPortfolio({id:'local-dev-user'},env).analysisAccounts).grossReceived,null);
  } finally {fs.rmSync(dir,{recursive:true,force:true});}
});
test('passiveIncome confirms cash dividends and expired OTM short calls while isolating open, early-closed and assigned calls',()=>{
  const s=statement();
  s.fromDate='20260101';s.toDate='20260228';
  s.Trades={Trade:[
    // 1. Confirmed expired worthless short Call (+240)
    {tradeID:'T1',assetCategory:'OPT',symbol:'NVDA  260116C00250000',description:'NVDA 16JAN26 250 C',
      transactionType:'BookTrade',openCloseIndicator:'C',buySell:'BUY',quantity:2,tradePrice:0,proceeds:0,
      tradeDate:'20260116',expiry:'20260116',strike:250,fifoPnlRealized:240,currency:'USD',fxRateToBase:1},
    // 2. Early bought-to-close short Call (+90) -> NOT expired, must NOT enter passiveIncome
    {tradeID:'T2',assetCategory:'OPT',symbol:'GOOG  260220C00400000',description:'GOOG 20FEB26 400 C',
      transactionType:'ExchTrade',openCloseIndicator:'C',buySell:'BUY',quantity:1,tradePrice:0.5,proceeds:-50,
      tradeDate:'20260205',expiry:'20260220',strike:400,fifoPnlRealized:90,currency:'USD',fxRateToBase:1},
    // 3. Assigned ITM short Call (fifoPnlRealized = 0) -> NOT expired worthless income
    {tradeID:'T3',assetCategory:'OPT',symbol:'GOOG  260116C00330000',description:'GOOG 16JAN26 330 C',
      transactionType:'BookTrade',openCloseIndicator:'C',buySell:'BUY',quantity:1,tradePrice:0,proceeds:0,
      tradeDate:'20260116',expiry:'20260116',strike:330,fifoPnlRealized:0,currency:'USD',fxRateToBase:1},
    // 4. Long Call expired worthless (-15) -> NOT short call income
    {tradeID:'T4',assetCategory:'OPT',symbol:'QQQ   260116C00750000',description:'QQQ 16JAN26 750 C',
      transactionType:'BookTrade',openCloseIndicator:'C',buySell:'SELL',quantity:-1,tradePrice:0,proceeds:0,
      tradeDate:'20260116',expiry:'20260116',strike:750,fifoPnlRealized:-15,currency:'USD',fxRateToBase:1},
    // 5. Expired Put (+180) -> Put, NOT Call
    {tradeID:'T5',assetCategory:'OPT',symbol:'SPCX  260116P00095000',description:'SPCX 16JAN26 95 P',
      transactionType:'BookTrade',openCloseIndicator:'C',buySell:'BUY',quantity:1,tradePrice:0,proceeds:0,
      tradeDate:'20260116',expiry:'20260116',strike:95,fifoPnlRealized:180,currency:'USD',fxRateToBase:1},
  ]};
  s.OpenPosition=[
    {symbol:'PLTR  260320C00250000',description:'PLTR 20MAR26 250 C',assetCategory:'OPT',currency:'USD',
      quantity:-3,markPrice:0.5,positionValue:-150,costBasisMoney:-420,strike:250,expiry:'20260320',multiplier:100},
  ];
  const accs=accounts(s);
  const passive=portfolioPassiveIncome(accs,'USD');
  assert.equal(passive.status,'ready');
  // Dividends (100) + PIL Dividends (15) = 115; Bond/Cash interest excluded from dividend stream
  assert.equal(passive.dividends.grossAmount,115);
  assert.equal(passive.dividends.withholdingTax,-15);
  assert.equal(passive.dividends.netAmount,100);
  // Only T1 (+240) qualifies as confirmed expired short Call
  assert.equal(passive.expiredCalls.amount,240);
  assert.equal(passive.expiredCalls.settlementCount,1);
  assert.equal(passive.expiredCalls.contractCount,2);
  assert.equal(passive.totalConfirmed,355);
  assert.equal(passive.monthly.length,2);
  assert.equal(passive.monthly[0].month,'2026-01');
  assert.equal(passive.monthly[0].dividends,115);
  assert.equal(passive.monthly[0].expiredCalls,240);
  assert.equal(passive.pendingShortCalls.confirmed,false);
  assert.equal(passive.pendingShortCalls.count,1);
  assert.equal(passive.pendingShortCalls.totalContracts,3);
  assert.equal(passive.pendingShortCalls.collectedPremium,420);

  // Also verify v4 fallback when expiredShortCalls array was not stored on an older saved account
  const legacyAcc=structuredClone(accs[0]);
  delete legacyAcc.historyEvidence.expiredCallsStatus;
  delete legacyAcc.historyEvidence.expiredShortCalls;
  const fallback=portfolioPassiveIncome([legacyAcc],'USD');
  assert.equal(fallback.status,'ready');
  assert.equal(fallback.expiredCalls.amount,240);
});

test('passiveIncome computes multi-year annual summaries and strict same-period YoY comparisons',()=>{
  const s=statement();
  s.fromDate='20250101';s.toDate='20260630';
  s.CashTransactions={CashTransaction:[
    receipt('Dividends',120,'QQQ',{transactionID:'D25A',dateTime:'20250315;120000'}),
    receipt('Dividends',180,'QQQ',{transactionID:'D25B',dateTime:'20250915;120000'}),
    receipt('Dividends',150,'QQQ',{transactionID:'D26A',dateTime:'20260315;120000'}),
  ]};
  s.Trades={Trade:[
    {tradeID:'C25A',assetCategory:'OPT',symbol:'NVDA  250221C00200000',description:'NVDA 21FEB25 200 C',
      transactionType:'BookTrade',openCloseIndicator:'C',buySell:'BUY',quantity:1,tradePrice:0,proceeds:0,
      tradeDate:'20250221',expiry:'20250221',strike:200,fifoPnlRealized:280,currency:'USD',fxRateToBase:1},
    {tradeID:'C25B',assetCategory:'OPT',symbol:'NVDA  251121C00220000',description:'NVDA 21NOV25 220 C',
      transactionType:'BookTrade',openCloseIndicator:'C',buySell:'BUY',quantity:1,tradePrice:0,proceeds:0,
      tradeDate:'20251121',expiry:'20251121',strike:220,fifoPnlRealized:400,currency:'USD',fxRateToBase:1},
    {tradeID:'C26A',assetCategory:'OPT',symbol:'NVDA  260220C00260000',description:'NVDA 20FEB26 260 C',
      transactionType:'BookTrade',openCloseIndicator:'C',buySell:'BUY',quantity:2,tradePrice:0,proceeds:0,
      tradeDate:'20260220',expiry:'20260220',strike:260,fifoPnlRealized:450,currency:'USD',fxRateToBase:1},
  ]};
  const passive=portfolioPassiveIncome(accounts(s),'USD');
  assert.deepEqual(passive.availableYears,['2026','2025']);
  const y2026=passive.annual['2026'];
  const y2025=passive.annual['2025'];
  // 2026 YTD (Jan-Jun): 150 div + 450 call = 600
  assert.equal(y2026.totalConfirmed,600);
  assert.equal(y2026.isYtd,true);
  assert.equal(y2026.monthly.length,12);
  // Same-period YoY compares 2026-01-01..2026-06-30 (600) strictly against 2025-01-01..2025-06-30 (120 + 280 = 400),
  // NOT full-year 2025 (980)!
  assert.equal(y2026.yoy.status,'full_same_period');
  assert.equal(y2026.yoy.priorFrom,'2025-01-01');
  assert.equal(y2026.yoy.priorTo,'2025-06-30');
  assert.equal(y2026.yoy.currentTotal,600);
  assert.equal(y2026.yoy.priorTotal,400);
  assert.equal(y2026.yoy.deltaTotal,200);
  assert.ok(Math.abs(y2026.yoy.pctTotal-0.5)<1e-12);
  assert.equal(y2026.yoy.deltaCalls,170);
  assert.equal(y2026.yoy.deltaDividends,30);
  // 2025 full year: 300 div + 680 call = 980, baseline year with no 2024 history
  assert.equal(y2025.totalConfirmed,980);
  assert.equal(y2025.isFullYear,true);
  assert.equal(y2025.yoy.status,'prior_year_unavailable');
});
