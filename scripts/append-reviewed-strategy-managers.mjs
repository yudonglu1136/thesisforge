// Local, append-only warehouse supplement through the existing 13F importer.
// Source receipts, cover reconciliation and original publication dates are
// required. No price, financial, user or existing-manager records are replaced.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync,backup} from 'node:sqlite';
import {fileURLToPath} from 'node:url';
import {gurus} from '../server/gurus.js';
import {signature} from '../server/investmentMath.js';
import {importStrategyDatabase,immutableInsert} from '../server/strategyDatabaseImport.js';
import {verifyStrategyDocument} from './recover-strategy-books.mjs';
import {strategyTableHashes} from './rebind-strategy-identities.mjs';
import {openStrategyDatabase} from '../server/strategyDatabase.js';

const sha=v=>crypto.createHash('sha256').update(v).digest('hex');
export function originalCalendar(guru,history,cutoff) {
  const quarters=new Map();
  for(const row of history){
    const f=row.filing;
    if(f?.form!=='13F-HR'||f.isAmendment||f.filerCik!==guru.cik||
      f.reportDate!==row.reportDate||f.filingDate!==row.filingDate||
      !/^\d{4}-\d{2}-\d{2}$/.test(f.reportDate??'')||f.reportDate>f.filingDate||
      !/^\d{4}-\d{2}-\d{2}$/.test(f.filingDate??'')||!/^\d{10}-\d{2}-\d{6}$/.test(f.accessionNumber??''))
      throw Error('untrusted_original_calendar');
    if(f.filingDate>cutoff)continue;
    const prior=quarters.get(f.reportDate);
    if(prior&&prior.filing.accessionNumber!==f.accessionNumber)throw Error('ambiguous_original_calendar');
    // Failed evidence still occupies its actual publication date. The existing
    // importer emits missing_original / blocked, never reuses an older book.
    quarters.set(f.reportDate,{reportDate:f.reportDate,publicDate:f.filingDate,
      commonLongValue:row.commonLongValue,filing:{...f,cik:guru.cik}});
  }
  return [...quarters.values()].sort((a,b)=>a.publicDate.localeCompare(b.publicDate));
}
export function verifiedOriginal(guru,row,receiptFor) {
  const f=row.filing;
  if(f?.form!=='13F-HR'||f.isAmendment||f.filerCik!==guru.cik||f.reportDate!==row.reportDate||
    f.filingDate!==row.filingDate||!f.acceptanceDateTime||!Number.isFinite(Date.parse(f.acceptanceDateTime)))throw Error('original_identity_or_publication_mismatch');
  if(f.componentFilings?.length>1)throw Error('multi_filer_requires_separate_review');
  const url=new URL(f.xmlUrl),coverUrl=new URL('primary_doc.xml',url).href;
  if(url.origin!=='https://www.sec.gov'||url.pathname.split('/')[4]!==String(Number(guru.cik))||
    url.pathname.split('/')[5]!==f.accessionNumber.replaceAll('-',''))throw Error('document_identity_mismatch');
  const receipt=url=>{const r=receiptFor(url);if(!r||r.url!==url||r.status!==200||sha(r.body)!==r.sha256)throw Error('source_receipt_missing_or_corrupt');return r;};
  const info=receipt(url.href);
  let cover;
  if(receiptFor(coverUrl))cover=receipt(coverUrl);
  else {
    // EDGAR's complete submission is also an original SEC source. Preserve
    // its exact bytes/hash and explicitly label the extracted XML, rather
    // than inventing a standalone download receipt.
    const submission=receipt(new URL(f.accessionNumber+'.txt',url).href);
    const documents=[...submission.body.matchAll(/<DOCUMENT>([\s\S]*?)<\/DOCUMENT>/g)]
      .map(m=>m[1]).filter(s=>/^<FILENAME>primary_doc\.xml\s*$/m.test(s));
    const xml=documents.length===1?documents[0].match(/<XML>\s*([\s\S]*?)\s*<\/XML>/)?.[1]:null;
    if(!xml)throw Error('submission_cover_missing_or_ambiguous');
    cover={url:submission.url+'#primary_doc.xml',body:xml,sha256:sha(xml),sourceContainer:submission};
  }
  const checked=verifyStrategyDocument(info.body,cover.body,{reportDate:row.reportDate,cik:guru.cik});
  const common=checked.holdings.reduce((n,h)=>n+h.value,0);
  const scale=[1,1000].find(s=>Number.isFinite(row.commonLongValue)&&common>0&&Math.abs(common*s-row.commonLongValue)<1);
  if(!scale)throw Error('common_book_value_mismatch');
  // Keep the original normalized economic observations as a second check.
  const prior=new Map(row.holdings.filter(h=>h.holdingBucket==='common_long').map(h=>[h.cusip,h]));
  const holdings=checked.holdings.map(h=>{
    const p=prior.get(h.cusip);
    if(!p||p.shares!==h.shares||Math.abs(p.value-h.value*scale)>=1)throw Error('source_holding_mismatch');
    return {...h,value:h.value*scale};
  });
  if(prior.size!==holdings.length)throw Error('source_holding_count_mismatch');
  const documents=[{url:info.url,hash:info.sha256,accessionNumber:f.accessionNumber}];
  return {record:{guruId:guru.id,accessionNumber:f.accessionNumber,reportDate:row.reportDate,publicDate:f.filingDate,
    commonLongValue:common*scale,sourceHash:signature(documents),documents,scale,holdings,
    coverDocuments:[{url:cover.url,hash:cover.sha256,accessionNumber:f.accessionNumber,
      rawRows:checked.rowCount,coverValue:checked.coverValue,reportedValue:checked.reportedValue,
      coverDifference:checked.coverDifference,coverRoundingTolerance:checked.coverRoundingTolerance,
      ...(cover.sourceContainer?{sourceContainer:cover.sourceContainer}:{})}],
    originalFiling:{...f,cik:guru.cik},downloadedAt:info.fetchedAt},info,cover};
}

export async function appendReviewedManagers(input,stagedDirectory,outputDirectory,ids,extraReceipts) {
  if(![input,stagedDirectory,outputDirectory].every(path.isAbsolute)||fs.existsSync(outputDirectory)||!ids?.length||new Set(ids).size!==ids.length)throw Error('new_absolute_output_and_unique_managers_required');
  const source=openStrategyDatabase(input),catalog=ids.map(id=>gurus.find(g=>g.id===id&&g.type==='manager13f'));
  if(catalog.some(g=>!g)||ids.some(id=>source.db.prepare('SELECT 1 FROM managers WHERE id=?').get(id))){source.close();throw Error('only_missing_configured_managers_allowed');}
  fs.mkdirSync(outputDirectory,{mode:0o700});
  const write=(name,value)=>fs.writeFileSync(path.join(outputDirectory,name),typeof value==='string'?value:JSON.stringify(value,null,2),{flag:'wx',mode:0o600});
  let db;
  try {
    const before=strategyTableHashes(source.db),priorManifest=JSON.parse(fs.readFileSync(input+'.import.json'));
    if(signature(before.tableHashes)!==signature(priorManifest.tableHashes))throw Error('source_manifest_drift');
    const records=[],failures=[],calendars=[];
    const receiptFor=url=>{
      for(const root of [extraReceipts,path.join(stagedDirectory,'sec-sources')].filter(Boolean)){
        const file=path.join(root,sha(url)+'.json');
        if(fs.existsSync(file)){const r=JSON.parse(fs.readFileSync(file));if(r.status===200)return r;}
      }
      return null;
    };
    for(const guru of catalog){
      const staged=JSON.parse(fs.readFileSync(path.join(stagedDirectory,guru.id+'.json')));
      if(staged.guru.id!==guru.id||staged.guru.cik!==guru.cik)throw Error('staged_manager_identity_mismatch');
      calendars.push({id:guru.id,rebalances:originalCalendar(guru,staged.history,source.meta.cutoff)});
      const seen=new Set();
      for(const row of staged.history){
        if(row.filingDate>source.meta.cutoff)continue;
        try {
          const {record,info,cover}=verifiedOriginal(guru,row,receiptFor);
          if(seen.has(record.reportDate))throw Error('duplicate_original_quarter');
          seen.add(record.reportDate);records.push(record);
          write(record.accessionNumber+'.xml',info.body);write(record.accessionNumber+'.cover.xml',cover.body);
        }catch(e){failures.push({manager: guru.id,reportDate:row.reportDate,accession:row.filing?.accessionNumber,reason:e.message});}
      }
      for(const e of staged.excludedFilings??[])failures.push({manager:guru.id,excludedSource:e});
      if(!records.some(r=>r.guruId===guru.id))throw Error('no_verified_originals:'+guru.id);
    }
    write('filings.json',{version:'strategy-original-filings-v1',asOf:source.meta.cutoff,records,recordsHash:signature(records),failures});
    // Empty source schema is an input adapter, not fabricated financial data.
    // OriginalFiling evidence drives history through originalStrategyHistory.
    const emptyFile=path.join(outputDirectory,'empty-source.sqlite'),empty=new DatabaseSync(emptyFile);
    empty.exec('CREATE TABLE guru_backtests(guru_id TEXT,years INTEGER,payload_json TEXT); CREATE TABLE guru_exposure_snapshots(guru_id TEXT PRIMARY KEY,payload_json TEXT)');
    for(const c of calendars)empty.prepare('INSERT INTO guru_backtests VALUES (?,?,?)').run(c.id,0,JSON.stringify({rebalances:c.rebalances}));
    empty.close();
    const fragmentFile=path.join(outputDirectory,'managers-fragment.sqlite');
    const fragmentReport=importStrategyDatabase({sourceFile:emptyFile,targetFile:fragmentFile,cutoff:source.meta.cutoff,
      catalog,filingFile:path.join(outputDirectory,'filings.json'),manifestFile:path.join(stagedDirectory,'additions-sec-manifest.json')});
    write('managers-fragment.sqlite.import.json',fragmentReport);
    const target=path.join(outputDirectory,'strategy.sqlite');await backup(source.db,target);fs.chmodSync(target,0o600);
    db=new DatabaseSync(target);db.exec('PRAGMA foreign_keys=ON; BEGIN IMMEDIATE');
    db.prepare('ATTACH DATABASE ? AS supplement').run(fragmentFile);
    const tables=['source_documents','managers','manager_entities','filing_manifest','document_holdings','filings','filing_holdings','holding_resolutions','coverage_issues'];
    for(const table of tables)for(const row of db.prepare(`SELECT * FROM supplement.${table}`).iterate()){
      if(table==='source_documents'){
        const old=db.prepare('SELECT * FROM source_documents WHERE id=?').get(row.id);
        if(old){
          if(['kind','locator','sha256','content'].some(k=>old[k]!==row[k]))throw Error('source_document_conflict');
          continue; // Same immutable document: retain its original import time.
        }
      }
      immutableInsert(db,table,row);
    }
    const after=strategyTableHashes(db),changed=Object.keys(after.tableHashes).filter(t=>before.tableHashes[t]!==after.tableHashes[t]);
    if(changed.some(t=>!tables.includes(t)))throw Error('protected_table_changed');
    db.prepare('ATTACH DATABASE ? AS previous').run(input);
    for(const table of tables){
      if(db.prepare(`SELECT COUNT(*) n FROM (SELECT * FROM previous.${table} EXCEPT SELECT * FROM main.${table})`).get().n)throw Error('prior_record_changed:'+table);
    }
    const sourceCounts=JSON.parse(source.meta.source_counts_json),manifestHash=signature({cutoff:source.meta.cutoff,...after,sourceCounts,security:source.meta.security_version,actions:source.meta.action_version});
    db.prepare('UPDATE warehouse_meta SET generated_at=?,manifest_hash=? WHERE id=1').run(new Date().toISOString(),manifestHash);
    if(db.prepare('PRAGMA foreign_key_check').all().length)throw Error('foreign_key_failure');db.exec('COMMIT');
    if(db.prepare('PRAGMA integrity_check').get().integrity_check!=='ok')throw Error('integrity_failure');
    const counts=catalog.map(g=>({id:g.id,cik:g.cik,...db.prepare('SELECT COUNT(*) filings,MIN(report_date) firstReport,MAX(report_date) lastReport FROM filings WHERE manager_id=?').get(g.id)}));
    const report={schemaVersion:1,cutoff:source.meta.cutoff,...after,sourceCounts,manifestHash,sourceGeneration:source.meta.manifest_hash,
      changedTables:changed,managers:counts,verifiedOriginals:records.length,unacceptedOriginals:failures,
      sourceWrites:source.db.prepare('SELECT total_changes() n').get().n,oldRecordsChanged:0,integrity:'ok',foreignKeys:0,
      policy:'Existing parser/importer and cover-rounding policy; missing evidence remains excluded. This is not acceptance of every historical simulation.'};
    write('strategy.sqlite.import.json',report);return report;
  }finally{db?.close();source.close();}
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const [input,staged,out,ids,extraReceipts]=process.argv.slice(2);process.umask(0o077);
  const report=await appendReviewedManagers(input,staged,out,ids?.split(','),extraReceipts);
  console.log(JSON.stringify({...report,tableHashes:undefined,unacceptedOriginals:report.unacceptedOriginals.length}));
}
