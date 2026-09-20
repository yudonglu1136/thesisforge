import test from 'node:test';
import a from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {packageInstitutional13fArtifact} from './package-13f-insights-artifact.mjs';

test('packages only the compact append-only v2 13F table',t=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'tf-package-13f-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const source=path.join(root,'source.sqlite'),output=path.join(root,'artifact'),db=new DatabaseSync(source);
  db.exec(`CREATE TABLE institutional_13f_insight_snapshots_v2(report_date TEXT,source_generation TEXT,available_at TEXT,generated_at TEXT,payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation));`);
  db.prepare('INSERT INTO institutional_13f_insight_snapshots_v2 VALUES(?,?,?,?,?,?)')
    .run('2026-06-30','g','2026-08-14','2026-09-20','h',Buffer.from('compressed'));db.close();
  const manifest=packageInstitutional13fArtifact({source,output,releaseId:'13f-insights-20260920-v2',runtimeRoot:'/var/app/data/13f-insights/releases'});
  a.equal(manifest.version,'institutional-13f-artifact-v2');a.equal(manifest.rows,1);
  const artifact=new DatabaseSync(path.join(output,'13f-insights.sqlite'),{readOnly:true});
  a.equal(artifact.prepare('SELECT count(*) count FROM institutional_13f_insight_snapshots_v2').get().count,1);
  a.equal(artifact.prepare("SELECT count(*) count FROM sqlite_master WHERE type='table' AND name='institutional_13f_insight_snapshots'").get().count,0);
  artifact.close();
});
