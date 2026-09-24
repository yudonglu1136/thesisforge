import test from 'node:test';
import a from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {packageInstitutional13fArtifact} from './package-13f-insights-artifact.mjs';
import {validateInstitutional13fArtifact} from '../server/investmentRuntimeConfig.js';

test('packages compact summaries with lazy details and market history',t=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'tf-package-13f-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const source=path.join(root,'source.sqlite'),output=path.join(root,'artifact'),db=new DatabaseSync(source);
  db.exec(`CREATE TABLE institutional_13f_insight_snapshots_v2(report_date TEXT,source_generation TEXT,available_at TEXT,generated_at TEXT,payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation));`);
  db.exec(`CREATE TABLE institutional_13f_insight_details_v1(report_date TEXT,source_generation TEXT,ticker TEXT,payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation,ticker));
    CREATE TABLE institutional_13f_market_history_v1(report_date TEXT,source_generation TEXT,segment TEXT,available_at TEXT,securities INTEGER,covered_securities INTEGER,institutional_value_m REAL,market_cap_m REAL,institutional_ownership_pct REAL,net_change_value_m REAL,net_change_pct_market_cap REAL,PRIMARY KEY(report_date,source_generation,segment));
    CREATE TABLE institutional_13f_security_history_v1(report_date TEXT,source_generation TEXT,ticker TEXT,available_at TEXT,holders INTEGER,institutional_value_m REAL,institutional_shares_k REAL,share_basis_factor REAL,shares_outstanding_k REAL,institutional_ownership_pct REAL,PRIMARY KEY(report_date,source_generation,ticker));
    CREATE TABLE institutional_13f_active_snapshots_v1(report_date TEXT,source_generation TEXT,available_at TEXT,generated_at TEXT,payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation));
    CREATE TABLE institutional_13f_active_details_v1(report_date TEXT,source_generation TEXT,ticker TEXT,payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation,ticker));`);
  db.prepare('INSERT INTO institutional_13f_insight_snapshots_v2 VALUES(?,?,?,?,?,?)')
    .run('2026-06-30','g','2026-08-14','2026-09-20','h',Buffer.from('compressed'));
  db.prepare('INSERT INTO institutional_13f_insight_details_v1 VALUES(?,?,?,?,?)').run('2026-06-30','g','MSFT','d',Buffer.from('detail'));
  db.prepare('INSERT INTO institutional_13f_market_history_v1 VALUES(?,?,?,?,?,?,?,?,?,?,?)').run('2026-06-30','g','all','2026-08-14',1,1,80,100,80,2,2);
  db.prepare('INSERT INTO institutional_13f_security_history_v1 VALUES(?,?,?,?,?,?,?,?,?,?)').run('2026-06-30','g','MSFT','2026-08-14',1,10,20,20,20,100);
  db.prepare('INSERT INTO institutional_13f_active_snapshots_v1 VALUES(?,?,?,?,?,?)').run('2026-06-30','active-g','2026-08-14','2026-09-22','active-h',Buffer.from('active'));
  db.prepare('INSERT INTO institutional_13f_active_details_v1 VALUES(?,?,?,?,?)').run('2026-06-30','active-g','MSFT','active-detail-h',Buffer.from('active-detail'));
  db.close();
  const manifest=packageInstitutional13fArtifact({source,output,releaseId:'13f-insights-20260921-v3',runtimeRoot:'/var/app/data/13f-insights/releases'});
  a.equal(manifest.version,'institutional-13f-artifact-v6');a.equal(manifest.rows,1);a.equal(manifest.detailRows,1);a.equal(manifest.marketRows,1);a.equal(manifest.securityHistoryRows,1);a.equal(manifest.activeRows,1);a.equal(manifest.activeDetailRows,1);
  const artifact=new DatabaseSync(path.join(output,'13f-insights.sqlite'),{readOnly:true});
  a.equal(artifact.prepare('SELECT count(*) count FROM institutional_13f_insight_snapshots_v2').get().count,1);
  a.equal(artifact.prepare('SELECT count(*) count FROM institutional_13f_insight_details_v1').get().count,1);
  a.equal(artifact.prepare('SELECT institutional_value_m value FROM institutional_13f_security_history_v1').get().value,10);
  a.equal(artifact.prepare('SELECT share_basis_factor value FROM institutional_13f_security_history_v1').get().value,20);
  a.equal(artifact.prepare('SELECT count(*) count FROM institutional_13f_active_snapshots_v1').get().count,1);
  a.equal(artifact.prepare('SELECT count(*) count FROM institutional_13f_active_details_v1').get().count,1);
  a.equal(artifact.prepare("SELECT count(*) count FROM sqlite_master WHERE type='table' AND name='institutional_13f_insight_snapshots'").get().count,0);
  artifact.close();
  const augmented=new DatabaseSync(source);
  augmented.exec(`CREATE TABLE institutional_13f_active_sectors_v1(report_date TEXT,source_generation TEXT,sector TEXT,payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation,sector));`);
  augmented.prepare('INSERT INTO institutional_13f_active_sectors_v1 VALUES(?,?,?,?,?)').run('2026-06-30','active-g','Technology','sector-h',Buffer.from('sector'));
  // Old generations must not leak into the published sidecar.
  augmented.prepare('INSERT INTO institutional_13f_active_sectors_v1 VALUES(?,?,?,?,?)').run('2026-06-30','old','Technology','old-h',Buffer.from('old'));
  augmented.close();
  const installRoot=fs.realpathSync(root),releaseId='13f-insights-20260922-v12';
  const sectorPath=path.join(installRoot,releaseId,'13f-insights.sqlite');
  const manifestPath=path.join(installRoot,releaseId,'manifest.json');
  const next=packageInstitutional13fArtifact({source,output:path.join(installRoot,releaseId),releaseId,runtimeRoot:installRoot});
  a.equal(next.version,'institutional-13f-artifact-v7');a.equal(next.sectorRows,1);
  fs.chmodSync(manifestPath,0o400);
  a.equal(validateInstitutional13fArtifact(sectorPath,manifestPath,{trustedUid:process.getuid()}).sectorRows,1);
  const sectorArtifact=new DatabaseSync(sectorPath,{readOnly:true});
  a.equal(sectorArtifact.prepare('SELECT source_generation FROM institutional_13f_active_sectors_v1').get().source_generation,'active-g');
  sectorArtifact.close();
});

test('Elastic Beanstalk 13F installer supports instance-role S3 reads with exact bucket and release paths',()=>{
  const hook=fs.readFileSync(path.resolve('.platform/hooks/postdeploy/05-install-13f-insights.sh'),'utf8');
  a.match(hook,/THESISFORGE_13F_INSTALL_DB_S3_URI/);
  a.match(hook,/THESISFORGE_13F_INSTALL_MANIFEST_S3_URI/);
  a.match(hook,/parsed\.scheme == "s3"/);
  a.match(hook,/parsed\.netloc == "thesisforge-production-378477120101-us-east-1"/);
  a.match(hook,/aws s3 cp "\$\{database_source\}"/);
  a.match(hook,/aws s3 cp "\$\{manifest_source\}"/);
  a.match(hook,/--region us-east-1 --only-show-errors/);
});
