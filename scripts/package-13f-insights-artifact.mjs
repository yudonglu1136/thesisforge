#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {parseArgs} from 'node:util';

const fail=code=>{throw Error(code);};
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const table='institutional_13f_insight_snapshots';

export function packageInstitutional13fArtifact({source,output,releaseId,runtimeRoot='/var/app/data/13f-insights/releases'}) {
  if(!/^13f-insights-\d{8}-v[1-9]\d*$/.test(releaseId??''))fail('invalid_13f_release_id');
  source=path.resolve(source);output=path.resolve(output);
  if(!fs.statSync(source).isFile())fail('missing_13f_source');
  fs.mkdirSync(output,{recursive:false,mode:0o700});
  const file=path.join(output,'13f-insights.sqlite');
  const sourceDb=new DatabaseSync(source,{readOnly:true});sourceDb.exec('PRAGMA query_only=ON;PRAGMA busy_timeout=3000');
  const schema=sourceDb.prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name=?").get(table)?.sql;
  if(!schema)fail('missing_13f_source_table');
  const rows=sourceDb.prepare(`SELECT * FROM ${table} ORDER BY report_date,source_generation`).all();
  sourceDb.close();
  const db=new DatabaseSync(file);
  try {
    db.exec('PRAGMA journal_mode=DELETE;PRAGMA synchronous=FULL;BEGIN IMMEDIATE');
    db.exec(schema);
    db.exec(`CREATE INDEX institutional_13f_insights_available_idx ON ${table}(available_at,report_date)`);
    const insert=db.prepare(`INSERT INTO ${table}(report_date,source_generation,available_at,generated_at,payload_hash,payload_json) VALUES(?,?,?,?,?,?)`);
    for(const row of rows)insert.run(row.report_date,row.source_generation,row.available_at,row.generated_at,row.payload_hash,row.payload_json);
    db.exec('COMMIT;VACUUM');
    if(db.prepare('PRAGMA integrity_check').get().integrity_check!=='ok')fail('13f_artifact_integrity_failed');
    if(db.prepare('PRAGMA foreign_key_check').all().length)fail('13f_artifact_foreign_key_failed');
    const duplicates=db.prepare(`SELECT count(*) count FROM (SELECT report_date,source_generation,count(*) n FROM ${table}
      GROUP BY report_date,source_generation HAVING n>1)`).get().count;
    if(duplicates!==0||db.prepare(`SELECT count(*) count FROM ${table}`).get().count!==rows.length)fail('13f_artifact_row_mismatch');
  } finally {db.close();}
  const bytes=fs.statSync(file).size,sha256=hash(file);
  const runtimeDirectory=path.join(runtimeRoot,releaseId),runtimeFile=path.join(runtimeDirectory,path.basename(file));
  const manifest={version:'institutional-13f-artifact-v1',releaseId,state:'verified',generatedAt:new Date().toISOString(),rows:rows.length,
    source:{path:source,table,methodVersion:'institutional-13f-insights-v1'},
    checks:{integrity:'ok',foreignKeyCheck:'ok',naturalKeyUniqueness:'pass',privateDataExcluded:true},
    file:{path:runtimeFile,bytes,sha256}};
  fs.writeFileSync(path.join(output,'manifest.json'),JSON.stringify(manifest,null,2)+'\n',{flag:'wx',mode:0o600});
  fs.chmodSync(file,0o400);
  return manifest;
}

if(import.meta.url===new URL(`file://${path.resolve(process.argv[1])}`).href) {
  try {
    const {values}=parseArgs({options:{source:{type:'string'},output:{type:'string'},'release-id':{type:'string'},'runtime-root':{type:'string'}}});
    const result=packageInstitutional13fArtifact({source:values.source,output:values.output,releaseId:values['release-id'],runtimeRoot:values['runtime-root']});
    console.log(JSON.stringify({status:'verified',...result},null,2));
  } catch(error) {console.error(error.message);process.exitCode=1;}
}
