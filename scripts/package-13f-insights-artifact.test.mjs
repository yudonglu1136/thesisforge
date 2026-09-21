import test from 'node:test';
import a from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {packageInstitutional13fArtifact} from './package-13f-insights-artifact.mjs';

test('packages compact summaries with lazy details and market history',t=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'tf-package-13f-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const source=path.join(root,'source.sqlite'),output=path.join(root,'artifact'),db=new DatabaseSync(source);
  db.exec(`CREATE TABLE institutional_13f_insight_snapshots_v2(report_date TEXT,source_generation TEXT,available_at TEXT,generated_at TEXT,payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation));`);
  db.exec(`CREATE TABLE institutional_13f_insight_details_v1(report_date TEXT,source_generation TEXT,ticker TEXT,payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation,ticker));
    CREATE TABLE institutional_13f_market_history_v1(report_date TEXT,source_generation TEXT,segment TEXT,available_at TEXT,securities INTEGER,covered_securities INTEGER,institutional_value_m REAL,market_cap_m REAL,institutional_ownership_pct REAL,net_change_value_m REAL,net_change_pct_market_cap REAL,PRIMARY KEY(report_date,source_generation,segment));
    CREATE TABLE institutional_13f_security_history_v1(report_date TEXT,source_generation TEXT,ticker TEXT,available_at TEXT,holders INTEGER,institutional_value_m REAL,institutional_shares_k REAL,share_basis_factor REAL,shares_outstanding_k REAL,institutional_ownership_pct REAL,PRIMARY KEY(report_date,source_generation,ticker));`);
  db.prepare('INSERT INTO institutional_13f_insight_snapshots_v2 VALUES(?,?,?,?,?,?)')
    .run('2026-06-30','g','2026-08-14','2026-09-20','h',Buffer.from('compressed'));
  db.prepare('INSERT INTO institutional_13f_insight_details_v1 VALUES(?,?,?,?,?)').run('2026-06-30','g','MSFT','d',Buffer.from('detail'));
  db.prepare('INSERT INTO institutional_13f_market_history_v1 VALUES(?,?,?,?,?,?,?,?,?,?,?)').run('2026-06-30','g','all','2026-08-14',1,1,80,100,80,2,2);
  db.prepare('INSERT INTO institutional_13f_security_history_v1 VALUES(?,?,?,?,?,?,?,?,?,?)').run('2026-06-30','g','MSFT','2026-08-14',1,10,20,20,20,100);db.close();
  const manifest=packageInstitutional13fArtifact({source,output,releaseId:'13f-insights-20260921-v3',runtimeRoot:'/var/app/data/13f-insights/releases'});
  a.equal(manifest.version,'institutional-13f-artifact-v5');a.equal(manifest.rows,1);a.equal(manifest.detailRows,1);a.equal(manifest.marketRows,1);a.equal(manifest.securityHistoryRows,1);
  const artifact=new DatabaseSync(path.join(output,'13f-insights.sqlite'),{readOnly:true});
  a.equal(artifact.prepare('SELECT count(*) count FROM institutional_13f_insight_snapshots_v2').get().count,1);
  a.equal(artifact.prepare('SELECT count(*) count FROM institutional_13f_insight_details_v1').get().count,1);
  a.equal(artifact.prepare('SELECT institutional_value_m value FROM institutional_13f_security_history_v1').get().value,10);
  a.equal(artifact.prepare('SELECT share_basis_factor value FROM institutional_13f_security_history_v1').get().value,20);
  a.equal(artifact.prepare("SELECT count(*) count FROM sqlite_master WHERE type='table' AND name='institutional_13f_insight_snapshots'").get().count,0);
  artifact.close();
});
