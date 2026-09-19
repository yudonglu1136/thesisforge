// Repair missing PRE-2023 originals from the stored SEC document manifest.
// This does not accept later amendments or relax cover/table reconciliation.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {gurus} from '../server/gurus.js';
import {signature} from '../server/investmentMath.js';
import {strategyFilingArtifact} from '../server/strategyFilings.js';
import {verifyStrategyDocument} from './recover-strategy-books.mjs';
const [priorFile,out]=process.argv.slice(2);
if(!priorFile||!out)throw Error('Usage: prior-filings.json NEW_OUTPUT_DIR');
const prior=strategyFilingArtifact(priorFile),priorDir=path.dirname(priorFile);
const problems=JSON.parse(fs.readFileSync(path.join(priorDir,'recovery.json'))).failures;
const manifest=JSON.parse(fs.readFileSync(new URL('../server/config/guru-sec-cusip-manifest.json',import.meta.url)));
fs.mkdirSync(out,{mode:0o700});
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const save=(name,body)=>fs.writeFileSync(path.join(out,name),body,{flag:'wx',mode:0o600});
const copy=(file,expected)=>{
 const body=fs.readFileSync(path.join(priorDir,file));if(hash(body)!==expected)throw Error('prior_document_hash_mismatch');
 const target=path.join(out,file);
 if(fs.existsSync(target)){if(hash(fs.readFileSync(target))!==expected)throw Error('conflicting_document');}
 else save(file,body);
};
for(const r of prior.values())for(const d of r.documents)copy(d.accessionNumber+'.xml',d.hash);
const get=async url=>{
 const u=new URL(url);if(u.origin!=='https://www.sec.gov'||!u.pathname.startsWith('/Archives/edgar/data/'))throw Error('invalid_sec_url');
 const response=await fetch(url,{headers:{'User-Agent':'ThesisForge research engineering contact@thesisforge.tech'},signal:AbortSignal.timeout(20000)});
 if(!response.ok)throw Error('SEC_HTTP_'+response.status);
 const body=await response.text();await new Promise(r=>setTimeout(r,200));return body;
};
const recovered=[],failures=[];
for(const problem of problems) {
 if(problem.error!=='missing_original_metadata'){failures.push(problem);continue;}
 try {
  const g=gurus.find(g=>g.id===problem.guruId);
  const candidates=manifest.filings.filter(f=>f.managerId===g.id&&f.reportDate===problem.reportDate&&f.form==='13F-HR'&&
   f.filingDate<'2023-01-03'&&f.filingDate>=f.reportDate&&[g.cik,...g.alternateCiks??[]].includes(f.cik))
   .sort((a,b)=>a.filingDate.localeCompare(b.filingDate)||a.accessionNumber.localeCompare(b.accessionNumber));
  const m=candidates[0];if(!m||m.documentHashScope!=='document_body')throw Error('original_manifest_unavailable');
  const coverUrl=new URL('primary_doc.xml',m.documentUrl).href;
  const xml=await get(m.documentUrl),cover=await get(coverUrl);
  if(hash(xml)!==m.documentSha256)throw Error('manifest_document_hash_mismatch');
  const v=verifyStrategyDocument(xml,cover,{reportDate:m.reportDate,cik:m.cik});
  const ranked=[...v.holdings].sort((a,b)=>b.value-a.value);
  const selected=ranked.slice(0,m.selectedCommonLongCusipCount);
  if(selected.length!==m.selectedCommonLongCusipCount||Math.abs(selected.reduce((s,h)=>s+h.value,0)-m.selectedCommonLongReportedValue)>.001)
   throw Error('manifest_common_book_mismatch');
  // Before the 2023-01-03 EDGAR change, Column 4 was in thousands of USD.
  // https://www.sec.gov/files/edgar/filermanual/archive/efmvol2-v64.pdf
  // Only those old originals enter this narrowly scoped recovery path.
  const scale=1000,documents=[{url:m.documentUrl,hash:hash(xml),accessionNumber:m.accessionNumber}];
  const record={guruId:g.id,accessionNumber:m.accessionNumber,reportDate:m.reportDate,publicDate:m.filingDate,
   originalFiling:{form:'13F-HR',accessionNumber:m.accessionNumber,cik:m.cik,reportDate:m.reportDate,filingDate:m.filingDate,
    xmlUrl:m.documentUrl,secUrl:coverUrl},
   commonLongValue:v.holdings.reduce((s,h)=>s+h.value*scale,0),holdings:v.holdings.map(h=>({...h,value:h.value*scale})),scale,
   sourceHash:signature(documents),documents,coverDocuments:[{url:coverUrl,hash:hash(cover),accessionNumber:m.accessionNumber,
    manager:v.manager,rawRows:v.rowCount,reportedValue:v.reportedValue,coverValue:v.coverValue,
    coverDifference:v.coverDifference,coverRoundingTolerance:v.coverRoundingTolerance}],
   recoveryPolicy:'exact_manifest_hash; original_pre_2023; full_cover_reconciliation; native_value_thousands',downloadedAt:new Date().toISOString()};
  prior.set(g.id+':'+m.accessionNumber,record);save(m.accessionNumber+'.xml',xml);save(m.accessionNumber+'.cover.xml',cover);
  recovered.push({guruId:g.id,reportDate:m.reportDate,accession:m.accessionNumber,publicDate:m.filingDate});
  console.log(g.id,m.reportDate,'original restored',m.filingDate);
 }catch(e){failures.push({...problem,error:e.message});console.log(problem.guruId,problem.reportDate,'FAILED',e.message);}
}
const records=[...prior.values()];
save('filings.json',JSON.stringify({version:'strategy-original-filings-v1',asOf:'2026-08-28',records,recordsHash:signature(records),failures}));
strategyFilingArtifact(path.join(out,'filings.json'));
save('recovery.json',JSON.stringify({recovered,failures,sourceWrites:0},null,2));
console.log(JSON.stringify({recovered:recovered.length,failures}));
