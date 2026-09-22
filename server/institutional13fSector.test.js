import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {gzipSync} from 'node:zlib';
import {createHash} from 'node:crypto';
import {institutional13fSectorDetail} from './institutional13fInsights.js';

function fixture() {
  const db=new DatabaseSync(':memory:');
  db.exec(`CREATE TABLE institutional_13f_active_snapshots_v1(report_date TEXT,source_generation TEXT,
    available_at TEXT,generated_at TEXT,payload_hash TEXT,payload_gzip BLOB);
    CREATE TABLE institutional_13f_active_sectors_v1(report_date TEXT,source_generation TEXT,
    sector TEXT,payload_hash TEXT,payload_gzip BLOB);`);
  db.prepare('INSERT INTO institutional_13f_active_snapshots_v1 VALUES(?,?,?,?,?,?)').run(
    '2026-06-30','g1','2026-08-14','2026-09-22','summary',gzipSync(JSON.stringify({
      rows:[],reportDate:'2026-06-30',previousReportDate:'2026-03-31',availableAt:'2026-08-14',
    })));
  const bytes=Buffer.from(JSON.stringify({version:'active-sector-v1',sector:'Technology',summary:{netProxyM:11},
    stocks:Array.from({length:61},(_,i)=>({ticker:`T${i}`,name:`Company ${i}`,netProxyM:60-i,rank:i+1})),
    managers:[{investorId:'A',netProxyM:-5}],industries:[]}));
  db.prepare('INSERT INTO institutional_13f_active_sectors_v1 VALUES(?,?,?,?,?)').run(
    '2026-06-30','g1','Technology',createHash('sha256').update(bytes).digest('hex'),gzipSync(bytes));
  return {db};
}

test('sector drill-down is lazy, bounded, pinned and preserves complete totals',()=>{
  const source=fixture();
  const result=institutional13fSectorDetail(source,'Technology','2026-09-21','2026-06-30', {generation:'g1',offset:20,limit:20});
  assert.equal(result.total,61);assert.equal(result.rows.length,20);assert.equal(result.rows[0].ticker,'T20');
  assert.equal(result.summary.netProxyM,11);assert.equal(result.sourceGeneration,'g1');
  assert.equal('stocks' in result,false);assert.equal('managers' in result,false);
  assert.equal(institutional13fSectorDetail(source,'Technology','2026-09-21',null,{view:'managers',direction:'reducing'}).total,1);
});
test('sector drill-down rejects future quarters, generation races and missing data',()=>{
  const source=fixture();
  assert.throws(()=>institutional13fSectorDetail(source,'Technology','2026-07-01','2026-06-30'));
  assert.throws(()=>institutional13fSectorDetail(source,'Technology','2026-09-21',null,{generation:'g2'}),/generation_changed/);
  assert.throws(()=>institutional13fSectorDetail(source,'Unknown','2026-09-21'),/sector_unavailable/);
});
test('sector filtering never recalculates population ranks or totals',()=>{
  const result=institutional13fSectorDetail(fixture(),'Technology','2026-09-21',null,{search:'Company 23'});
  assert.equal(result.rows[0].rank,24);assert.equal(result.total,1);assert.equal(result.summary.netProxyM,11);
});
test('corrupt sector payload fails closed',()=>{
  const source=fixture();source.db.exec("UPDATE institutional_13f_active_sectors_v1 SET payload_hash='bad'");
  assert.throws(()=>institutional13fSectorDetail(source,'Technology','2026-09-21'),/sector_integrity/);
});
