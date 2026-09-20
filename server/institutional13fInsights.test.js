import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { institutional13fInsights, institutional13fInsightDetail } from './institutional13fInsights.js';
import { InvestmentSource } from './investmentSource.js';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { gzipSync } from 'node:zlib';

function fixture() {
  const db = new DatabaseSync(':memory:');
  db.exec(`CREATE TABLE institutional_13f_insight_snapshots(
    report_date TEXT,source_generation TEXT,available_at TEXT,generated_at TEXT,
    payload_hash TEXT,payload_json TEXT,PRIMARY KEY(report_date,source_generation));`);
  const insert = db.prepare('INSERT INTO institutional_13f_insight_snapshots VALUES(?,?,?,?,?,?)');
  const payload = (reportDate,offset) => JSON.stringify({
    version:'institutional-13f-insights-v2',reportDate,coverage:{currentFilers:8581,securities:7926},
    rows:[
      {ticker:'MSFT',increases:2841,holders:6200+offset,currentUnitsK:7100000+offset,sharesOutstandingK:7430000,institutionalOwnershipPct:95.6},
      {ticker:'NVDA',increases:2780,holders:5900+offset,currentUnitsK:2100000+offset,sharesOutstandingK:2440000,institutionalOwnershipPct:86.1},
    ],institutions:[{investorId:'BLKROK',name:'BLACKROCK'}],
    details:{MSFT:{increased:[{investorId:'BLKROK'}]},NVDA:{increased:[{investorId:'VANGRD'}]}}
  });
  insert.run('2026-03-31','g1','2026-05-15','2026-09-19T00:00:00Z','h1',payload('2026-03-31',0));
  insert.run('2026-06-30','g1','2026-08-14','2026-09-19T00:00:00Z','h2',payload('2026-06-30',20));
  return {db};
}

test('13F insights exposes all-filer snapshots without a Guru selection',()=>{
  const source=fixture();
  const result=institutional13fInsights(source,'2026-09-18');
  assert.equal(result.reportDate,'2026-06-30');
  assert.equal(result.coverage.currentFilers,8581);
  assert.equal(result.coverage.scope,'all_sf3_institutional_filers');
  assert.equal(result.coverage.selectedGuruCount,null);
  assert.deepEqual(result.quarters,['2026-06-30','2026-03-31']);
  assert.deepEqual(Object.keys(result.details),['MSFT']);
  assert.deepEqual(result.details.MSFT.history.map(row=>row.reportDate),['2026-03-31','2026-06-30']);
  assert.equal(result.details.MSFT.history[1].institutionalOwnershipPct,95.6);
  assert.equal(JSON.stringify(result).includes('VANGRD'),false);
});

test('13F security detail is lazy and quarter-bound',()=>{
  const source=fixture();
  const result=institutional13fInsightDetail(source,'NVDA','2026-09-18','2026-06-30');
  assert.equal(result.ticker,'NVDA');
  assert.equal(result.details.increased[0].investorId,'VANGRD');
  assert.equal(result.details.history.length,2);
  assert.throws(()=>institutional13fInsightDetail(source,'UNKNOWN','2026-09-18'),/institutional_13f_security_not_found/);
});

test('13F insights honors the PIT availability cutoff and exact quarter',()=>{
  const source=fixture();
  const prior=institutional13fInsights(source,'2026-06-01');
  assert.equal(prior.reportDate,'2026-03-31');
  assert.throws(()=>institutional13fInsights(source,'2026-06-01','2026-06-30'),/institutional_13f_quarter_not_available/);
});

test('13F insights prefers the compact append-only v2 artifact',()=>{
  const source=fixture();
  source.db.exec(`CREATE TABLE institutional_13f_insight_snapshots_v2(
    report_date TEXT,source_generation TEXT,available_at TEXT,generated_at TEXT,
    payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation));`);
  const payload=JSON.stringify({
    version:'institutional-13f-insights-v2',reportDate:'2026-06-30',
    coverage:{currentFilers:9000,securities:8000},
    rows:[{ticker:'MSFT',increases:3000,holders:6500,currentUnitsK:7200000}],
    institutions:[],details:{MSFT:{increased:[]}},
  });
  source.db.prepare('INSERT INTO institutional_13f_insight_snapshots_v2 VALUES(?,?,?,?,?,?)')
    .run('2026-06-30','v2','2026-08-14','2026-09-20T00:00:00Z','v2hash',gzipSync(payload));
  const result=institutional13fInsights(source,'2026-09-18');
  assert.equal(result.version,'institutional-13f-insights-v2');
  assert.equal(result.coverage.currentFilers,9000);
});

test('13F insights may be mounted as a separate read-only artifact',t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tf-13f-source-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const research=path.join(dir,'research.sqlite'),insights=path.join(dir,'insights.sqlite');
  const researchDb=new DatabaseSync(research);researchDb.exec('CREATE TABLE fixture(value TEXT)');researchDb.close();
  const fixtureSource=fixture(),backup=new DatabaseSync(insights);
  backup.exec(`CREATE TABLE institutional_13f_insight_snapshots(
    report_date TEXT,source_generation TEXT,available_at TEXT,generated_at TEXT,
    payload_hash TEXT,payload_json TEXT,PRIMARY KEY(report_date,source_generation));`);
  const insert=backup.prepare('INSERT INTO institutional_13f_insight_snapshots VALUES(?,?,?,?,?,?)');
  for(const row of fixtureSource.db.prepare('SELECT * FROM institutional_13f_insight_snapshots').all())
    insert.run(row.report_date,row.source_generation,row.available_at,row.generated_at,row.payload_hash,row.payload_json);
  backup.close();fixtureSource.db.close();
  const source=new InvestmentSource(research,{insightsFile:insights});t.after(()=>source.close());
  assert.equal(institutional13fInsights(source,'2026-09-18').coverage.currentFilers,8581);
  assert.equal(source.db.prepare("SELECT count(*) count FROM sqlite_master WHERE name='institutional_13f_insight_snapshots'").get().count,0);
});
