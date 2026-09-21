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
      {ticker:'MSFT',increases:2841,holders:6200+offset,currentValueM:3200000+offset,currentUnitsK:7100000+offset,sharesOutstandingK:7430000,institutionalOwnershipPct:95.6},
      {ticker:'NVDA',increases:2780,holders:5900+offset,currentValueM:2800000+offset,currentUnitsK:2100000+offset,sharesOutstandingK:2440000,institutionalOwnershipPct:86.1},
    ],institutions:[{investorId:'BLKROK',name:'BLACKROCK'}],
    details:{MSFT:{increased:[{investorId:'BLKROK'}]},NVDA:{increased:[{investorId:'VANGRD'}]}}
  });
  insert.run('2026-03-31','g1','2026-05-15','2026-09-19T00:00:00Z','h1',payload('2026-03-31',0));
  insert.run('2026-06-30','g1','2026-08-14','2026-09-19T00:00:00Z','h2',payload('2026-06-30',20));
  return {db};
}

test('13F insights exposes all-filer snapshots without a Guru selection',()=>{
  const source=fixture();
  const result=institutional13fInsights(source,'2026-09-18',null,'MSFT');
  assert.equal(result.reportDate,'2026-06-30');
  assert.equal(result.coverage.currentFilers,8581);
  assert.equal(result.coverage.scope,'all_sf3_institutional_filers');
  assert.equal(result.coverage.selectedGuruCount,null);
  assert.deepEqual(result.quarters,['2026-06-30','2026-03-31']);
  assert.equal(result.selectedTicker,'MSFT');
  assert.deepEqual(Object.keys(result.details),['MSFT']);
  assert.deepEqual(result.details.MSFT.history.map(row=>row.reportDate),['2026-03-31','2026-06-30']);
  assert.equal(result.details.MSFT.history[1].institutionalOwnershipPct,95.6);
  assert.equal(result.details.MSFT.history[1].institutionalValueM,3200020);
  assert.equal(JSON.stringify(result).includes('VANGRD'),false);
});

test('13F summary route is bounded, ranked and omits the retired institution directory',()=>{
  const source=fixture();
  const result=institutional13fInsights(source,'2026-09-18',null,{
    action:'increased',rank:'institutions',segment:'all',limit:20,
  });
  assert.deepEqual(result.rows.map(row=>row.ticker),['MSFT','NVDA']);
  assert.equal(result.totalMatches,2);
  assert.equal(result.rowLimit,20);
  assert.equal('institutions' in result,false);
  assert.deepEqual(result.details,{});
  assert.equal(result.actionLeaders.increased[0].ticker,'MSFT');
});

test('13F summary search, action, segment and percentage rank stay server bounded',()=>{
  const source=fixture();
  const result=institutional13fInsights(source,'2026-09-18',null,{
    action:'increased',rank:'sharesHeldPct',segment:'all',search:'nvd',limit:20,
  });
  assert.deepEqual(result.rows.map(row=>row.ticker),['NVDA']);
  assert.equal(result.totalMatches,1);
  assert.equal(result.rows[0].institutionalOwnershipPct,86.1);
});

test('13F insights keeps the requested stock and its chart history aligned',()=>{
  const source=fixture();
  const result=institutional13fInsights(source,'2026-09-18',null,'NVDA');
  assert.equal(result.selectedTicker,'NVDA');
  assert.deepEqual(Object.keys(result.details),['NVDA']);
  assert.deepEqual(result.details.NVDA.history.map(row=>row.reportDate),['2026-03-31','2026-06-30']);
});

test('13F security detail is lazy and quarter-bound',()=>{
  const source=fixture();
  const result=institutional13fInsightDetail(source,'NVDA','2026-09-18','2026-06-30');
  assert.equal(result.ticker,'NVDA');
  assert.equal(result.details.increased[0].investorId,'VANGRD');
  assert.equal(result.details.history.length,2);
  assert.throws(()=>institutional13fInsightDetail(source,'UNKNOWN','2026-09-18'),/institutional_13f_security_not_found/);
});

test('13F exited institutions compare prior reported value instead of repeating minus 100 percent',()=>{
  const source=fixture();
  const current=source.db.prepare("SELECT payload_json FROM institutional_13f_insight_snapshots WHERE report_date='2026-06-30'").get();
  const payload=JSON.parse(current.payload_json);
  payload.institutions.push({investorId:'EXIT',name:'Exited Capital',currentValueM:1000,previousValueM:1200});
  source.db.prepare("UPDATE institutional_13f_insight_snapshots SET payload_json=? WHERE report_date='2026-06-30'").run(JSON.stringify(payload));
  source.db.exec(`CREATE TABLE institutional_13f_insight_details_v1(
    report_date TEXT,source_generation TEXT,ticker TEXT,payload_hash TEXT,payload_gzip BLOB,
    PRIMARY KEY(report_date,source_generation,ticker));`);
  source.db.prepare('INSERT INTO institutional_13f_insight_details_v1 VALUES(?,?,?,?,?)').run(
    '2026-06-30','g1','MSFT','exit-detail',gzipSync(JSON.stringify({exited:[{
      investorId:'EXIT',name:'Exited Capital',currentValueM:null,previousValueM:425,
      currentUnitsK:null,previousUnitsK:10,changePct:-1,
    }]})),
  );
  const result=institutional13fInsightDetail(source,'MSFT','2026-09-18','2026-06-30');
  const exit=result.details.exited[0];
  assert.equal(exit.activityValueM,425);
  assert.equal(exit.reportedValueChangeM,-425);
  assert.equal(exit.changePct,null);
  assert.equal(exit.comparisonBasis,'prior_reported_position_value');
});

test('13F detail does not infer exits when an entire filer is missing this quarter',()=>{
  const source=fixture();
  const current=source.db.prepare("SELECT payload_json FROM institutional_13f_insight_snapshots WHERE report_date='2026-06-30'").get();
  const payload=JSON.parse(current.payload_json);
  payload.institutions.push({investorId:'MISSING',name:'Missing Filing',currentValueM:null,previousValueM:900});
  source.db.prepare("UPDATE institutional_13f_insight_snapshots SET payload_json=? WHERE report_date='2026-06-30'").run(JSON.stringify(payload));
  source.db.exec(`CREATE TABLE institutional_13f_insight_details_v1(
    report_date TEXT,source_generation TEXT,ticker TEXT,payload_hash TEXT,payload_gzip BLOB,
    PRIMARY KEY(report_date,source_generation,ticker));`);
  source.db.prepare('INSERT INTO institutional_13f_insight_details_v1 VALUES(?,?,?,?,?)').run(
    '2026-06-30','g1','MSFT','missing-detail',gzipSync(JSON.stringify({exited:[{
      investorId:'MISSING',name:'Missing Filing',previousValueM:425,changePct:-1,
    }]})),
  );
  const result=institutional13fInsightDetail(source,'MSFT','2026-09-18','2026-06-30');
  assert.deepEqual(result.details.exited,[]);
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
  const result=institutional13fInsights(source,'2026-09-18',null,'MSFT');
  assert.equal(result.version,'institutional-13f-insights-v2');
  assert.equal(result.coverage.currentFilers,9000);
});

test('13F v4 loads split-normalized share history without embedding the full detail book',()=>{
  const source=fixture();
  source.db.exec(`CREATE TABLE institutional_13f_insight_snapshots_v2(
    report_date TEXT,source_generation TEXT,available_at TEXT,generated_at TEXT,
    payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation));
    CREATE TABLE institutional_13f_insight_details_v1(
      report_date TEXT,source_generation TEXT,ticker TEXT,payload_hash TEXT,payload_gzip BLOB,
      PRIMARY KEY(report_date,source_generation,ticker));
    CREATE TABLE institutional_13f_market_history_v1(
      report_date TEXT,source_generation TEXT,segment TEXT,available_at TEXT,securities INTEGER,
      covered_securities INTEGER,institutional_value_m REAL,market_cap_m REAL,
      institutional_ownership_pct REAL,net_change_value_m REAL,net_change_pct_market_cap REAL,
      PRIMARY KEY(report_date,source_generation,segment));
    CREATE TABLE institutional_13f_security_history_v1(
      report_date TEXT,source_generation TEXT,ticker TEXT,available_at TEXT,holders INTEGER,
      institutional_value_m REAL,institutional_shares_k REAL,share_basis_factor REAL,shares_outstanding_k REAL,
      institutional_ownership_pct REAL,
      PRIMARY KEY(report_date,source_generation,ticker));`);
  for(const [date,available,holders] of [['2026-03-31','2026-05-15',6200],['2026-06-30','2026-08-14',6220]]) {
    const currentValueM=date==='2026-06-30'?80:70;
    const splitFactor=date==='2026-06-30'?1:20;
    const payload=JSON.stringify({version:'institutional-13f-insights-v4',reportDate:date,availableAt:available,shareBasisDate:'2026-06-30',
      coverage:{currentFilers:9000,securities:8000},rows:[{ticker:'MSFT',increases:3000,holders,currentValueM,currentUnitsK:7200000}],institutions:[],
      marketOverview:{all:{institutionalOwnershipPct:80}}});
    source.db.prepare('INSERT INTO institutional_13f_insight_snapshots_v2 VALUES(?,?,?,?,?,?)').run(date,'v3',available,'2026-09-21T00:00:00Z',date,gzipSync(payload));
    source.db.prepare('INSERT INTO institutional_13f_market_history_v1 VALUES(?,?,?,?,?,?,?,?,?,?,?)').run(date,'v3','all',available,8000,7000,80,100,80,2,2);
    source.db.prepare('INSERT INTO institutional_13f_security_history_v1 VALUES(?,?,?,?,?,?,?,?,?,?)')
      .run(date,'v3','MSFT',available,holders,currentValueM,7200000,splitFactor,7430000,95.6);
  }
  source.db.prepare('INSERT INTO institutional_13f_insight_details_v1 VALUES(?,?,?,?,?)')
    .run('2026-06-30','v3','MSFT','detail',gzipSync(JSON.stringify({increased:[{investorId:'VANGRD'}]})));
  const result=institutional13fInsights(source,'2026-09-18',null,'MSFT');
  assert.equal(result.version,'institutional-13f-insights-v4');
  assert.equal(result.details.MSFT.increased[0].investorId,'VANGRD');
  assert.deepEqual(result.marketHistory.map(row=>row.reportDate),['2026-03-31','2026-06-30']);
  assert.equal(result.marketHistory[1].segments.all.institutionalOwnershipPct,80);
  assert.deepEqual(result.details.MSFT.history.map(row=>row.institutionalValueM),[70,80]);
  assert.deepEqual(result.details.MSFT.history.map(row=>row.institutionalSharesK),[7200000,7200000]);
  assert.deepEqual(result.details.MSFT.history.map(row=>row.institutionalSharesRawK),[360000,7200000]);
  assert.deepEqual(result.details.MSFT.history.map(row=>row.shareBasisDate),['2026-06-30','2026-06-30']);
  assert.deepEqual(result.details.MSFT.history.map(row=>row.shareBasisFactor),[20,1]);
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
