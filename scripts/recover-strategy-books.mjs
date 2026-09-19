// Scoped source recovery, not a production refresh. Read the runtime only;
// write exact SEC evidence and reconciled books into a NEW private directory.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {XMLParser} from 'fast-xml-parser';
import {InvestmentSource} from '../server/investmentSource.js';
import {canonicalStrategyFilings,originalStrategyHistory,parseStrategyInfoTable,strategyFilingArtifact} from '../server/strategyFilings.js';
import {parseDocumentRows} from '../server/strategyDatabaseImport.js';
import {signature} from '../server/investmentMath.js';
const hash=s=>crypto.createHash('sha256').update(s).digest('hex');
const parser=new XMLParser({removeNSPrefix:true,parseTagValue:false});

export function verifyStrategyDocument(xml,cover,{reportDate,cik}) {
  const p=parser.parse(cover).edgarSubmission;
  const h=p?.headerData,c=p?.formData?.coverPage,s=p?.formData?.summaryPage;
  const date=h?.filerInfo?.periodOfReport;
  const iso=/^\d{2}-\d{2}-\d{4}$/.test(date??'')?`${date.slice(6)}-${date.slice(0,2)}-${date.slice(3,5)}`:null;
  if(h?.submissionType!=='13F-HR'||String(c?.isAmendment)==='true'||iso!==reportDate||
    String(h?.filerInfo?.filer?.credentials?.cik).padStart(10,'0')!==String(cik).padStart(10,'0'))throw Error('cover_identity_or_period_mismatch');
  const rows=parseDocumentRows(xml);
  if(rows.some(r=>!r.cusip||!Number.isFinite(r.value)||r.value<0||!Number.isFinite(r.shares)||r.shares<0||!r.title||!['SH','PRN'].includes(r.shareType)))throw Error('invalid_information_table_fields');
  const reportedValue=rows.reduce((n,r)=>n+r.value,0),coverValue=Number(s?.tableValueTotal);
  // Independently rounded whole-unit lines and cover total can differ by at
  // most half a reporting unit per line plus half a unit for the total. Keep
  // both values and the residual; never alter the source amounts to match.
  const coverRoundingTolerance=(rows.length+1)*.5,coverDifference=reportedValue-coverValue;
  if(rows.length!==Number(s?.tableEntryTotal)||!Number.isFinite(coverValue)||Math.abs(coverDifference)>coverRoundingTolerance)throw Error('cover_total_mismatch');
  return {holdings:parseStrategyInfoTable(xml),rowCount:rows.length,reportedValue,coverValue,coverDifference,coverRoundingTolerance,manager:c.filingManager?.name};
}

async function main() {
  const [sourceFile,output,ids,firstReport='2021-06-30',end='2026-08-28',priorFile]=process.argv.slice(2);
  if(!sourceFile||!output||!ids)throw Error('Usage: source.sqlite NEW_OUTPUT_DIR manager-ids [first-report] [cutoff] [prior-filings.json]');
  if(!/^\d{4}-\d{2}-\d{2}$/.test(firstReport)||!/^\d{4}-\d{2}-\d{2}$/.test(end))throw Error('invalid_date');
  fs.mkdirSync(output,{recursive:false,mode:0o700});
  const source=new InvestmentSource(sourceFile),records=strategyFilingArtifact(priorFile),failures=[],recovered=[];
  const save=(name,body)=>fs.writeFileSync(path.join(output,name),body,{flag:'wx',mode:0o600});
  const fetchSec=async url=>{
    if(new URL(url).origin!=='https://www.sec.gov'||!new URL(url).pathname.startsWith('/Archives/edgar/data/'))throw Error('invalid_sec_url');
    const cache=path.join(output,hash(url)+'.response');
    if(fs.existsSync(cache))return fs.readFileSync(cache,'utf8');
    const r=await fetch(url,{headers:{'User-Agent':'ThesisForge research engineering contact@thesisforge.tech'},signal:AbortSignal.timeout(20000)});
    if(!r.ok)throw Error('SEC_HTTP_'+r.status);
    const body=await r.text();fs.writeFileSync(cache,body,{flag:'wx',mode:0o600});
    await new Promise(resolve=>setTimeout(resolve,150));return body;
  };
  try {
    for(const id of ids.split(',')) {
      if(!source.guruCatalog().some(g=>g.id===id))throw Error('unknown_manager');
      const canon=new Map(canonicalStrategyFilings(source,id,end).map(r=>[r.reportDate,r]));
      for(const f of originalStrategyHistory(source,id,end,records).filter(f=>f.reportDate>=firstReport)) {
        try {
          const r=canon.get(f.reportDate),filing=r?.filing??f.filing;
          const accession=filing?.accessionNumber;
          if(!accession||filing.form!=='13F-HR')throw Error('missing_original_metadata');
          const parts=filing.componentFilings?.length?filing.componentFilings:[filing],holdings=[],documents=[],coverDocuments=[];
          let allReported=0;
          for(const part of parts) {
            const url=part.xmlUrl,coverUrl=new URL('primary_doc.xml',url).href;
            const xml=await fetchSec(url),cover=await fetchSec(coverUrl);
            const verified=verifyStrategyDocument(xml,cover,{reportDate:f.reportDate,cik:part.filerCik??part.cik??new URL(url).pathname.split('/')[4]});
            allReported+=verified.reportedValue;holdings.push(...verified.holdings);
            documents.push({url,hash:hash(xml),accessionNumber:part.accessionNumber});
            coverDocuments.push({url:coverUrl,hash:hash(cover),accessionNumber:part.accessionNumber,manager:verified.manager,rawRows:verified.rowCount,
              reportedValue:verified.reportedValue,coverValue:verified.coverValue,coverDifference:verified.coverDifference,coverRoundingTolerance:verified.coverRoundingTolerance});
            const name=part.accessionNumber+'.xml',target=path.join(output,name);
            if(fs.existsSync(target)){if(hash(fs.readFileSync(target))!==hash(xml))throw Error('conflicting_document');}else save(name,xml);
            const coverName=part.accessionNumber+'.cover.xml';if(!fs.existsSync(path.join(output,coverName)))save(coverName,cover);
          }
          const common=holdings.reduce((n,h)=>n+h.value,0),expected=r?.commonLongValue??f.reported13fValue;
          const raw=r?.commonLongValue?common:allReported;
          const scale=[1,1000].find(s=>Number.isFinite(expected)&&Math.abs(raw*s-expected)<Math.max(1,expected*1e-9));
          if(!scale)throw Error('source_value_does_not_reconcile');
          const aggregated=new Map();
          for(const h of holdings){const old=aggregated.get(h.id);aggregated.set(h.id,old?{...old,value:old.value+h.value*scale,shares:old.shares+h.shares}:{...h,value:h.value*scale});}
          const record={guruId:id,accessionNumber:accession,reportDate:f.reportDate,publicDate:[f.filingDate,r?.publicDate].filter(Boolean).sort().at(-1),
            commonLongValue:common*scale,sourceHash:signature(documents),documents,coverDocuments,scale,holdings:[...aggregated.values()],downloadedAt:new Date().toISOString()};
          records.set(id+':'+accession,record);recovered.push({guruId:id,reportDate:f.reportDate,accession,holdings:record.holdings.length});
          console.log(id,f.reportDate,'verified',record.holdings.length);
        }catch(e){failures.push({guruId:id,reportDate:f.reportDate,error:e.message});console.log(id,f.reportDate,'FAILED',e.message);}
      }
    }
    // Keep the earlier artifact's unrelated, exact evidence intact.
    for(const r of records.values())for(const d of r.documents){const to=path.join(output,d.accessionNumber+'.xml');if(!fs.existsSync(to)){
      const from=path.join(path.dirname(priorFile),d.accessionNumber+'.xml'),body=fs.readFileSync(from);
      if(hash(body)!==d.hash)throw Error('prior_document_hash_mismatch');save(d.accessionNumber+'.xml',body);
    }}
    const rows=[...records.values()];
    save('filings.json',JSON.stringify({version:'strategy-original-filings-v1',asOf:end,records:rows,recordsHash:signature(rows),failures},null,2));
    save('recovery.json',JSON.stringify({recovered,failures,sourceWrites:source.db.prepare('SELECT total_changes() n').get().n},null,2));
    console.log(JSON.stringify({recovered:recovered.length,failures}));
    if(failures.length)process.exitCode=1;
  }finally{source.close();}
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))await main();
