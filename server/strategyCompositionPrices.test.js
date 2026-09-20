import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {compositionPrices,linkedStrategyComparisonPrices} from './strategyCompositionPrices.js';

// Synthetic test data only; never imported into a preview/source database.
function fixture(t) {
  const dir=mkdtempSync(join(tmpdir(),'composition-price-test-')),file=join(dir,'prices.sqlite');
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const db=new DatabaseSync(file);
  db.exec('CREATE TABLE series(symbol TEXT PRIMARY KEY,provider_symbol TEXT,currency TEXT,source_sha256 TEXT,metadata_json TEXT,provider TEXT); CREATE TABLE prices(symbol TEXT,date TEXT,close REAL,adjusted_close REAL,quality_status TEXT)');
  const add=(symbol,{currency='USD',type='ETF',providerSymbol=symbol,provider='sharadar',prices=[['2026-01-02',100],['2026-01-05',110],['2026-01-06',120]]}={})=>{
    db.prepare('INSERT INTO series VALUES(?,?,?,?,?,?)').run(symbol,providerSymbol,currency,'fixture-hash-'+symbol,JSON.stringify({symbol,currency,instrumentType:type}),provider);
    for(const [date,adj] of prices)db.prepare('INSERT INTO prices VALUES(?,?,?,?,?)').run(symbol,date,200,adj,'verified_daily_bar');
  };
  return {file,db,add};
}
test('research prices replace a whole vintage, clip at cutoff, preserve CTA and do not mutate inputs',t=>{
  const {file,db,add}=fixture(t);
  for(const s of ['SPY','QQQ','KMLM'])add(s);
  db.close();
  const old=new Map([['2025-12-31',5],['2026-01-02',9]]);
  const data={priceMaps:new Map([['SPY',old],['QQQ',old],['KMLM',old]]),dates:[...old.keys()],sources:{original:'fixture'}};
  const next=compositionPrices(file,data,'2026-01-05');
  assert.deepEqual([...next.priceMaps.get('QQQ')],[['2026-01-02',100],['2026-01-05',110]]);
  assert.deepEqual(next.dates,['2026-01-02','2026-01-05']);
  assert.equal(next.priceMaps.get('KMLM'),old);
  assert.equal(data.priceMaps.get('QQQ'),old);
  assert.equal(data.sources.compositionPrices,undefined);
  assert.equal(next.sources.compositionPrices.QQQ.rows,2);
  assert.equal(next.sources.original,'fixture');
});
test('unverified currency, provider aliases and invalid adjusted prices cannot replace prior evidence',t=>{
  const {file,db,add}=fixture(t);
  add('AAA',{currency:'EUR',type:'EQUITY'});
  add('BBB',{providerSymbol:'OTHER',type:'EQUITY'});
  add('CCC',{prices:[['2026-01-02',null]]});
  db.close();
  const old=new Map([['2026-01-02',1]]),data={priceMaps:new Map(['AAA','BBB','CCC'].map(s=>[s,old])),dates:['2026-01-02']};
  const next=compositionPrices(file,data,'2026-01-05');
  for(const s of ['AAA','BBB','CCC'])assert.equal(next.priceMaps.get(s),old);
  assert.deepEqual(next.sources.compositionPrices,{});
});
test('an index symbol with equity identity fails instead of running the wrong instrument',t=>{
  const {file,db,add}=fixture(t);add('SCHD',{type:'EQUITY'});db.close();
  assert.throws(()=>compositionPrices(file,{priceMaps:new Map([['SCHD',new Map()]]),dates:[]},'2026-01-05'),/index_identity_mismatch/);
});
test('reviewed Sharadar identity preserves the exact share class and does not accept another class',t=>{
  const {file,db,add}=fixture(t);add('BRK.B',{type:'EQUITY'});
  const setMeta=symbol=>db.prepare('UPDATE series SET metadata_json=?').run(JSON.stringify({symbol,currency:'USD',instrumentType:'EQUITY'}));
  setMeta('BRK.B');
  const old=new Map([['2026-01-02',1]]),data={priceMaps:new Map([['BRK.B',old]]),dates:[...old.keys()]};
  const good=compositionPrices(file,data,'2026-01-05');
  assert.deepEqual([...good.priceMaps.get('BRK.B').values()],[100,110]);
  assert.equal(good.sources.compositionPrices['BRK.B'].providerSymbol,'BRK.B');
  setMeta('BRK-A');assert.equal(compositionPrices(file,data,'2026-01-05').priceMaps.get('BRK.B'),old);
  setMeta('BRK.B');db.exec("UPDATE series SET provider_symbol='BRK.A'");
  assert.equal(compositionPrices(file,data,'2026-01-05').priceMaps.get('BRK.B'),old);db.close();
});
test('linked-model quote repair uses the held class close, never adjusted close or another class, without changing returns',t=>{
  const {file,db,add}=fixture(t);add('GOOG',{type:'EQUITY'});add('GOOGL',{type:'EQUITY'});db.close();
  const old={currency:null,points:new Map()},returns=new Map([['GOOG',new Map([['2026-01-02',99]])]]);
  const data={priceMaps:returns,comparisonPrices:new Map([['GOOG',old],['GOOGL',old]])};
  const out=linkedStrategyComparisonPrices(file,data,'2026-01-05');
  assert.equal(out.priceMaps,returns);assert.equal(data.comparisonPrices.get('GOOG'),old);
  assert.deepEqual([...out.comparisonPrices.get('GOOG').points],[['2026-01-02',200],['2026-01-05',200]]);
  assert.equal(out.comparisonPrices.get('GOOGL'),old);
  assert.equal(out.comparisonPrices.get('GOOG').provenance.symbol,'GOOG');
  assert.equal(out.sources.linkedComparisonPrices.GOOG.field,'close');
});
test('quote repair never overwrites existing evidence, imports future/pre-review bars, or infers USD',t=>{
  const {file,db,add}=fixture(t);
  add('GOOG',{type:'EQUITY',prices:[['2015-01-01',10],['2026-01-02',20],['2027-01-01',30]]});
  const data=old=>({priceMaps:new Map(),comparisonPrices:new Map([['GOOG',old]])});
  const old={currency:'USD',points:new Map([['2026-01-02',123]])};
  assert.equal(linkedStrategyComparisonPrices(file,data(old),'2026-01-05').comparisonPrices.get('GOOG'),old);
  const unknown={currency:null,points:new Map()};
  assert.deepEqual([...linkedStrategyComparisonPrices(file,data(unknown),'2026-01-05').comparisonPrices.get('GOOG').points.keys()],['2026-01-02']);
  for(const sql of ["UPDATE series SET currency='GBP'","UPDATE series SET currency='USD', provider_symbol='GOOGL'",
    "UPDATE series SET provider_symbol='GOOG', metadata_json='{}'"]) {
    db.exec(sql);assert.equal(linkedStrategyComparisonPrices(file,data(unknown),'2026-01-05').comparisonPrices.get('GOOG'),unknown);
  }
  db.close();
});
