import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {opportunityQuality} from './investmentQuality.js';

function fixture(t) {
  const db=new DatabaseSync(':memory:'); t.after(()=>db.close());
  db.exec(`CREATE TABLE investment_quality_annual(ticker TEXT,source_ticker TEXT,fiscal_year INT,report_period TEXT,available_at TEXT,dimension TEXT,roic REAL,invested_capital_avg REAL,operating_margin REAL,fcf_margin REAL,cash_conversion REAL,issues_json TEXT,source_hash TEXT)`);
  const add=(ticker,year,extra={})=> {
    const r={ticker,source_ticker:ticker,fiscal_year:year,report_period:`${year}-12-31`,available_at:`${year+1}-02-15`,dimension:'ART',roic:.2,invested_capital_avg:100,operating_margin:.3,fcf_margin:.1,cash_conversion:1.2,issues_json:'[]',source_hash:'fixture',...extra};
    db.prepare('INSERT INTO investment_quality_annual VALUES('+Object.keys(r).map(()=>'?').join(',')+')').run(...Object.values(r));
  };
  return {db,add};
}
test('quality is optional and missing storage does not replace valuations or invent data',()=>{
  const db=new DatabaseSync(':memory:');assert.equal(opportunityQuality({db},'2026-08-28').size,0);db.close();
});
test('annual data respects availability, ignores MR dimensions, and bounds distinct history',t=>{
  const {db,add}=fixture(t);for(let y=2000;y<=2026;y++)add('TEST',y);
  add('RESTATED',2025,{dimension:'MRT'});add('FUTURE',2025,{available_at:'2026-09-01'});
  const q=opportunityQuality({db},'2026-08-28');assert.equal(q.size,1);
  assert.equal(q.get('TEST').years.length,10);assert.equal(q.get('TEST').years[0].year,2025);
  assert.equal(q.get('TEST').years[0].roic,.2);assert.equal(q.get('TEST').source,'Jansen / Sharadar SF1');
  assert.equal(opportunityQuality({db},'2026-02-14').get('TEST').years[0].year,2024);
});
test('missing and invalid denominators remain null, stale data labelled and exact symbols retained',t=>{
  const {db,add}=fixture(t);add('OLD',2021);add('A.B',2025,{invested_capital_avg:-100});add('NULL',2025,{roic:null,fcf_margin:null,cash_conversion:null});
  const q=opportunityQuality({db},'2026-08-28');assert.equal(q.get('OLD').status,'stale');
  assert.equal(q.get('A.B').years[0].roic,null);assert.equal(q.get('NULL').years[0].fcfMargin,null);
  assert.equal(q.has('AB'),false);
});
test('replayed and revised rows never create duplicate fiscal years or replace the first publication',t=>{
  const {db,add}=fixture(t);
  add('TEST',2025,{available_at:'2026-02-15',roic:.21,source_hash:'first'});
  add('TEST',2025,{available_at:'2026-05-15',roic:.35,source_hash:'later-revision'});
  const q=opportunityQuality({db},'2026-08-28').get('TEST');
  assert.equal(q.years.length,1);
  assert.equal(q.years[0].roic,.21);
  assert.equal(q.years[0].sourceHash,'first');
});
