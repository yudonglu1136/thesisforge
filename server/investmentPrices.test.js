import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { investmentCurrentQuotes,preferInvestmentQuote } from './investmentPrices.js';

test('pipeline observations use existing audited aliases without rewriting model data',()=>{
  const db=new DatabaseSync(':memory:'),publicFactsDb=new DatabaseSync(':memory:');
  try {
    db.exec("CREATE TABLE valuation_pit_financials(ticker TEXT,source_ticker TEXT); INSERT INTO valuation_pit_financials VALUES('ALIAS','EXACT')");
    publicFactsDb.exec(`CREATE TABLE investment_current_quotes(ticker TEXT,source_ticker TEXT,price_date TEXT,close REAL,source TEXT,imported_at TEXT,source_hash TEXT,source_generation TEXT);
      INSERT INTO investment_current_quotes VALUES('EXACT','EXACT','2026-09-21',25,'canonical','2026-09-21','source','new-release')`);
    const result=investmentCurrentQuotes({db,publicFactsDb},['ALIAS'],'2026-09-21');
    assert.equal(result.get('ALIAS').value,25);
    assert.equal(result.get('ALIAS').sourceTicker,'EXACT');
    assert.equal(db.prepare("SELECT COUNT(*) n FROM sqlite_master WHERE name='investment_current_quotes'").get().n,0);
    assert.equal(investmentCurrentQuotes({db,publicFactsDb},['ALIAS'],'2026-09-20').size,0);
  } finally {db.close();publicFactsDb.close();}
});

test('append-only quotes choose the latest correction and never leak a future close',()=>{
  const db=new DatabaseSync(':memory:');
  db.exec(`CREATE TABLE investment_current_quotes(
    ticker TEXT,source_ticker TEXT,price_date TEXT,close REAL,source TEXT,
    observed_at TEXT,imported_at TEXT,source_generation TEXT,source_hash TEXT);
    INSERT INTO investment_current_quotes VALUES
      ('AAPL','AAPL','2026-09-17',200,'s','2026-09-18','2026-09-18','g1','a'),
      ('AAPL','AAPL','2026-09-17',201,'s','2026-09-19','2026-09-19','g2','b'),
      ('AAPL','AAPL','2026-09-18',202,'s','2026-09-19','2026-09-19','g2','c');`);
  const source={db};
  assert.equal(investmentCurrentQuotes(source,['AAPL'],'2026-09-17').get('AAPL').value,201);
  assert.equal(investmentCurrentQuotes(source,['AAPL'],'2026-09-18').get('AAPL').value,202);
  assert.equal(investmentCurrentQuotes(source,['AAPL'],'2026-09-16').has('AAPL'),false);
});

test('Fact OS quote supersedes only an older stored quote and preserves currency',()=>{
  const stored={value:190,date:'2026-09-16',currency:'USD',source:'stored'};
  assert.deepEqual(preferInvestmentQuote({value:200,date:'2026-09-17',source:'fact'},stored),
    {value:200,date:'2026-09-17',currency:'USD',source:'fact'});
  assert.equal(preferInvestmentQuote({value:180,date:'2026-09-15'},stored),stored);
});
