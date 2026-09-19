// Recompute ONLY the derived holding-resolution layer in a new generation.
// Never relabel a stale warehouse as current without replaying every source row.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync,backup} from 'node:sqlite';
import {fileURLToPath} from 'node:url';
import {tickerResolutionForHolding,priceSymbolResolutionForHolding,holdingResolutionVersion} from '../server/cusipOverrides.js';
import {manager13fCorporateActionCatalogVersion} from '../server/corporateActions.js';
import {signature} from '../server/investmentMath.js';
import {enabledManager13fGurus} from '../server/gurus.js';

export function resolveStoredHolding(row) {
  const input={cusip:row.cusip,id:row.reported_id,issuer:row.issuer,title:row.security_title,
    shareType:row.amount_type,putCall:row.put_call,shares:row.reported_shares,value:row.value_usd,
    ticker:row.reported_ticker,guruId:row.manager_id,reportDate:row.report_date,accessionNumber:row.accession};
  const resolution=tickerResolutionForHolding(input),price=priceSymbolResolutionForHolding(input);
  const resolved=resolution.status==='resolved'&&resolution.source!=='curated_issuer_override';
  return {filing_id:row.filing_id,ordinal:row.ordinal,ticker:resolved?resolution.ticker:row.reported_ticker,
    price_symbol:resolved?price.symbol:null,status:resolved?'resolved':'unresolved',
    resolution_source:resolution.source??null,resolution_version:holdingResolutionVersion()};
}
export function strategyTableHashes(db) {
  const counts={},tableHashes={};
  for(const {name:table} of db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name!='warehouse_meta' ORDER BY name").all()){
    if(!/^[a-z_]+$/.test(table))throw Error('unexpected_table');
    counts[table]=db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n;
    const cols=db.prepare(`PRAGMA table_info(${table})`).all(),fields=cols.map(c=>c.name).filter(c=>table!=='source_documents'||!['content','stored_at'].includes(c));
    const order=cols.filter(c=>c.pk).sort((a,b)=>a.pk-b.pk).map(c=>c.name),hash=crypto.createHash('sha256');
    for(const r of db.prepare(`SELECT ${fields.join(',')} FROM ${table} ORDER BY ${order.join(',')}`).iterate())hash.update(JSON.stringify(r)+'\n');
    tableHashes[table]=hash.digest('hex');
  }
  return {counts,tableHashes};
}
export async function rebindIdentities(input,output) {
  if(!path.isAbsolute(input)||!path.isAbsolute(output)||!fs.statSync(input).isFile()||fs.existsSync(output))throw Error('new_absolute_candidate_required');
  const source=new DatabaseSync(input,{readOnly:true});source.exec('PRAGMA query_only=ON; BEGIN');
  let db;
  try {
    const meta=source.prepare('SELECT * FROM warehouse_meta WHERE id=1').get();
    if(meta?.schema_version!==1||meta.state!=='complete'||!meta.manifest_hash)throw Error('source_warehouse_incomplete');
    if(meta.action_version!==manager13fCorporateActionCatalogVersion)throw Error('corporate_actions_require_separate_migration');
    const before=strategyTableHashes(source);
    const manifest=JSON.parse(fs.readFileSync(input+'.import.json','utf8'));
    if(signature(before.tableHashes)!==signature(manifest.tableHashes))throw Error('source_manifest_drift');
    await backup(source,output);fs.chmodSync(output,0o600);db=new DatabaseSync(output);
    db.exec('PRAGMA foreign_keys=ON; BEGIN IMMEDIATE');
    const sourceRows=db.prepare(`SELECT h.*,f.manager_id,f.report_date,f.accession FROM filing_holdings h JOIN filings f ON f.id=h.filing_id ORDER BY h.filing_id,h.ordinal`).all();
    if(sourceRows.length!==before.counts.filing_holdings)throw Error('orphan_source_holdings');
    const old=new Map(db.prepare('SELECT * FROM holding_resolutions').all().map(r=>[r.filing_id+':'+r.ordinal,r]));
    db.exec('DELETE FROM holding_resolutions');
    const insert=db.prepare('INSERT INTO holding_resolutions VALUES (?,?,?,?,?,?,?)');
    const changes=[];let unresolved=0;
    for(const row of sourceRows){
      const next=resolveStoredHolding(row),prior=old.get(row.filing_id+':'+row.ordinal);
      insert.run(...Object.values(next));
      if(next.status!=='resolved')unresolved++;
      if(!prior||['ticker','price_symbol','status','resolution_source'].some(k=>next[k]!==prior[k]))
        changes.push({filing:row.filing_id,ordinal:row.ordinal,cusip:row.cusip,before:prior??null,after:next});
    }
    const now=new Date().toISOString(),evidence={previousVersion:meta.security_version,version:holdingResolutionVersion(),
      sourceGeneration:meta.manifest_hash,rowsRecomputed:sourceRows.length,unresolved,changes,
      resolverSha256:crypto.createHash('sha256').update(fs.readFileSync(new URL('../server/cusipOverrides.js',import.meta.url))).digest('hex'),
      policy:'Replayed original filed CUSIP/share-class/manager/date context using the same resolver as strategy import. No holdings, prices, corporate actions, financials or user data changed.'};
    const content=JSON.stringify(evidence),hash=crypto.createHash('sha256').update(content).digest('hex');
    db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(signature(['identity_rebind',hash]),'identity_rebind','local:strategy-identity-replay',hash,content,now);
    const {counts,tableHashes}=strategyTableHashes(db),changedTables=Object.keys(tableHashes).filter(t=>tableHashes[t]!==before.tableHashes[t]);
    if(changedTables.some(t=>!['source_documents','holding_resolutions'].includes(t)))throw Error('protected_table_changed');
    const sourceCounts=JSON.parse(meta.source_counts_json),manifestHash=signature({cutoff:meta.cutoff,counts,sourceCounts,tableHashes,security:holdingResolutionVersion(),actions:meta.action_version});
    db.prepare('UPDATE warehouse_meta SET security_version=?,generated_at=?,manifest_hash=? WHERE id=1').run(holdingResolutionVersion(),now,manifestHash);
    if(db.prepare('PRAGMA foreign_key_check').all().length)throw Error('foreign_key_failure');
    db.exec('COMMIT');
    if(db.prepare('PRAGMA integrity_check').get().integrity_check!=='ok')throw Error('integrity_failure');
    const managers=new Set(db.prepare('SELECT id FROM managers WHERE simulation_enabled=1').all().map(r=>r.id));
    const report={schemaVersion:1,cutoff:meta.cutoff,counts,tableHashes,sourceCounts,manifestHash,
      sourceGeneration:meta.manifest_hash,changedTables,rowsRecomputed:sourceRows.length,resolutionChanges:changes.length,
      unresolved,previousVersion:meta.security_version,securityVersion:holdingResolutionVersion(),
      missingCatalogManagers:enabledManager13fGurus.filter(g=>!managers.has(g.id)).map(g=>g.id),
      coverageIssues:'Prior source findings retained; this is identity replay, not certification of all manager histories.',
      integrity:'ok',foreignKeys:0,sourceWrites:source.prepare('SELECT total_changes() n').get().n};
    fs.writeFileSync(output+'.import.json',JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
    return report;
  }finally{db?.close();source.close();}
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [input,out]=process.argv.slice(2);
  if(!input||!out)throw Error('Usage: ABS_SOURCE.sqlite ABS_NEW_CANDIDATE.sqlite');
  process.umask(0o077);fs.mkdirSync(path.dirname(out),{recursive:true,mode:0o700});
  console.log(JSON.stringify(await rebindIdentities(input,out)));
}
