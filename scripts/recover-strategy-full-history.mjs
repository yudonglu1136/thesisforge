// Stage original disclosures for the complete enabled population, including
// quarters dropped by bounded UI/backtest caches. No canonical DB writes.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {gurus} from '../server/gurus.js';
import {signature} from '../server/investmentMath.js';
import {strategyFilingArtifact} from '../server/strategyFilings.js';
import {verifyStrategyDocument} from './recover-strategy-books.mjs';

const [priorFile,out,firstReport='2016-06-30',cutoff='2026-08-28']=process.argv.slice(2);
if(!priorFile||!out||fs.existsSync(out))throw Error('Usage: prior-filings.json NEW_OUTPUT_DIR [first-report] [cutoff]');
const manifest=JSON.parse(fs.readFileSync(new URL('../server/config/guru-sec-cusip-manifest.json',import.meta.url)));
if(signature({managers:manifest.managers,filings:manifest.filings,cusips:manifest.cusips})!==manifest.recordsSha256)throw Error('manifest_hash_mismatch');
const records=strategyFilingArtifact(priorFile),priorDir=path.dirname(priorFile);
const population=gurus.filter(g=>g.type==='manager13f'&&!g.disableSimulation);
fs.mkdirSync(out,{mode:0o700});
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const save=(name,body)=>fs.writeFileSync(path.join(out,name),body,{flag:'wx',mode:0o600});
for(const r of records.values())for(const d of r.documents) {
 const bytes=fs.readFileSync(path.join(priorDir,d.accessionNumber+'.xml'));
 if(hash(bytes)!==d.hash)throw Error('prior_document_hash_mismatch');
 const destination=path.join(out,d.accessionNumber+'.xml');
 if(!fs.existsSync(destination))save(d.accessionNumber+'.xml',bytes);
 else if(hash(fs.readFileSync(destination))!==d.hash)throw Error('conflicting_document');
}
for(const r of records.values())for(const d of r.coverDocuments??[]) {
 const name=d.accessionNumber+'.cover.xml',from=path.join(priorDir,name);
 if(!fs.existsSync(from))continue; // Older artifacts retain cover hashes only.
 const bytes=fs.readFileSync(from);
 if(hash(bytes)!==d.hash)throw Error('prior_cover_hash_mismatch');
 if(!fs.existsSync(path.join(out,name)))save(name,bytes);
}
const groups=new Map();
for(const f of manifest.filings)if(population.some(g=>g.id===f.managerId)&&f.form==='13F-HR'&&
 f.reportDate>=firstReport&&f.filingDate<=cutoff) {
 const k=f.managerId+':'+f.reportDate;if(!groups.has(k))groups.set(k,[]);groups.get(k).push(f);
}
const tasks=[...groups.values()].filter(fs=>!fs.some(f=>records.has(f.managerId+':'+f.accessionNumber)));
const failures=[],recovered=[],startedAt=new Date().toISOString();
save('plan.json',JSON.stringify({startedAt,cutoff,firstReport,managers:population.map(g=>g.id),manifestHash:manifest.recordsSha256,
 existingRecords:records.size,quartersToReview:tasks.length,sourceWrites:0},null,2));
const get=async url=>{
 const u=new URL(url);
 if(u.origin!=='https://www.sec.gov'||!u.pathname.startsWith('/Archives/edgar/data/'))throw Error('invalid_sec_url');
 for(let attempt=0;attempt<3;attempt++) {
  try {
   const r=await fetch(url,{headers:{'User-Agent':'ThesisForge research engineering contact@thesisforge.tech'},signal:AbortSignal.timeout(20000)});
   if(!r.ok) {
    if(attempt<2&&[429,500,502,503,504].includes(r.status)) {await r.body?.cancel();await new Promise(r=>setTimeout(r,1000*(attempt+1)));continue;}
    throw Error('SEC_HTTP_'+r.status);
   }
   const bytes=await r.text();await new Promise(r=>setTimeout(r,150));return bytes;
  } catch(error) {
   if(attempt===2||!['TimeoutError','TypeError'].includes(error.name))throw error;
   await new Promise(r=>setTimeout(r,1000*(attempt+1)));
  }
 }
};
for(const candidates of tasks) {
 const m=[...candidates].sort((a,b)=>a.filingDate.localeCompare(b.filingDate)||a.accessionNumber.localeCompare(b.accessionNumber))[0];
 try {
  const g=population.find(g=>g.id===m.managerId);
  if(g.id==='chamath-palihapitiya'&&g.cik==='0001607841')throw Error('manager_identity_mismatch');
  if(new Set(candidates.map(f=>f.cik)).size>1)throw Error('multiple_original_entities_requires_merge');
  if(![g.cik,...g.alternateCiks??[]].includes(m.cik)||m.reportDate>m.filingDate||m.documentHashScope!=='document_body')throw Error('unverified_manifest_identity');
  const coverUrl=new URL('primary_doc.xml',m.documentUrl).href;
  const priorXml=path.join(priorDir,m.accessionNumber+'.xml');
  const xml=fs.existsSync(priorXml)&&hash(fs.readFileSync(priorXml))===m.documentSha256
   ?fs.readFileSync(priorXml,'utf8'):await get(m.documentUrl);
  // Cover bodies from failed quarters are re-fetched; do not trust an
  // unvalidated local cover simply because its filename matches an accession.
  const cover=await get(coverUrl);
  save(m.accessionNumber+'.xml',xml);save(m.accessionNumber+'.cover.xml',cover);
  if(hash(xml)!==m.documentSha256)throw Error('manifest_document_hash_mismatch');
  const v=verifyStrategyDocument(xml,cover,{reportDate:m.reportDate,cik:m.cik});
  const selected=[...v.holdings].sort((a,b)=>b.value-a.value).slice(0,m.selectedCommonLongCusipCount);
  if(selected.length!==m.selectedCommonLongCusipCount||
   Math.abs(selected.reduce((s,h)=>s+h.value,0)-m.selectedCommonLongReportedValue)>.001)throw Error('manifest_selected_book_mismatch');
  // SEC's Column 4 changed from $000 to dollars on 2023-01-03. The
  // source-native unit is selected by filing date, never inferred from price.
  const scale=m.filingDate<'2023-01-03'?1000:1;
  const documents=[{url:m.documentUrl,hash:hash(xml),accessionNumber:m.accessionNumber}];
  const record={guruId:g.id,accessionNumber:m.accessionNumber,reportDate:m.reportDate,publicDate:m.filingDate,
   originalFiling:{form:'13F-HR',accessionNumber:m.accessionNumber,cik:m.cik,reportDate:m.reportDate,filingDate:m.filingDate,xmlUrl:m.documentUrl,secUrl:coverUrl},
   commonLongValue:v.holdings.reduce((s,h)=>s+h.value*scale,0),holdings:v.holdings.map(h=>({...h,value:h.value*scale})),scale,
   documents,sourceHash:signature(documents),coverDocuments:[{url:coverUrl,hash:hash(cover),accessionNumber:m.accessionNumber,manager:v.manager,
    rawRows:v.rowCount,reportedValue:v.reportedValue,coverValue:v.coverValue,coverDifference:v.coverDifference,coverRoundingTolerance:v.coverRoundingTolerance}],
   recoveryPolicy:'exact_manifest_document_hash; cover_identity_count_total; independent_manifest_selected_book; source_native_units',downloadedAt:new Date().toISOString()};
  records.set(g.id+':'+m.accessionNumber,record);
  recovered.push({guruId:g.id,reportDate:m.reportDate,publicDate:m.filingDate,accession:m.accessionNumber,holdings:record.holdings.length});
  console.log(JSON.stringify({completed:recovered.length+failures.length,total:tasks.length,...recovered.at(-1)}));
 } catch(error) {
  failures.push({guruId:m.managerId,reportDate:m.reportDate,accession:m.accessionNumber,error:error.message});
  console.log(JSON.stringify({completed:recovered.length+failures.length,total:tasks.length,...failures.at(-1)}));
 }
}
const rows=[...records.values()];
save('filings.json',JSON.stringify({version:'strategy-original-filings-v1',asOf:cutoff,records:rows,recordsHash:signature(rows),failures}));
strategyFilingArtifact(path.join(out,'filings.json'));
save('recovery.json',JSON.stringify({startedAt,finishedAt:new Date().toISOString(),recovered,failures,sourceWrites:0},null,2));
console.log(JSON.stringify({recovered:recovered.length,failures:failures.length,totalRecords:records.size}));
if(failures.length)process.exitCode=1;
