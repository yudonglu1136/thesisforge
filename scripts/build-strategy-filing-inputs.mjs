// Recover only missing ORIGINAL filings from exact stored SEC links. Paid
// runtime tables are read-only; source XML + parsed books go to a new artifact.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { InvestmentSource } from '../server/investmentSource.js';
import { canonicalStrategyFilings,parseStrategyInfoTable } from '../server/strategyFilings.js';
import { signature } from '../server/investmentMath.js';
const [file,output,end='2026-08-28']=process.argv.slice(2);
if(!file||!output)throw new Error('Usage: node scripts/build-strategy-filing-inputs.mjs source.sqlite NEW_OUTPUT_DIR [cutoff]');
fs.mkdirSync(output,{recursive:false,mode:0o700});
const source=new InvestmentSource(file),records=[],failures=[];
try {
  for(const g of source.guruCatalog()) {
    const present=new Set(source.guruHistory(g.id,end).map(x=>x.accessionNumber));
    for(const r of canonicalStrategyFilings(source,g.id,end).filter(r=>!present.has(r.filing.accessionNumber))) {
      try {
        const parts=r.filing.componentFilings?.length?r.filing.componentFilings:[r.filing],all=[],documents=[];
        for(const part of parts) {
          const url=part.xmlUrl;
          if(!url||new URL(url).hostname!=='www.sec.gov')throw new Error('unverified_sec_url');
          const response=await fetch(url,{headers:{'User-Agent':process.env.SEC_USER_AGENT||'ThesisForge/0.1 contact@thesisforge.tech'},signal:AbortSignal.timeout(15000)});
          if(!response.ok)throw new Error('sec_http_'+response.status);
          const xml=await response.text(),hash=crypto.createHash('sha256').update(xml).digest('hex');
          fs.writeFileSync(path.join(output,part.accessionNumber+'.xml'),xml,{flag:'wx',mode:0o600});
          all.push(...parseStrategyInfoTable(xml));documents.push({url,hash,accessionNumber:part.accessionNumber});
          await new Promise(r=>setTimeout(r,250));
        }
        const raw=all.reduce((n,h)=>n+h.value,0),scale=[1,1000].find(s=>Math.abs(raw*s-r.commonLongValue)<Math.max(1,r.commonLongValue*1e-9));
        if(!scale)throw new Error('reported_common_value_does_not_reconcile');
        const record={guruId:g.id,accessionNumber:r.filing.accessionNumber,reportDate:r.reportDate,publicDate:r.publicDate,
          commonLongValue:raw*scale,sourceHash:signature(documents),documents,scale,
          holdings:all.map(h=>({...h,value:h.value*scale})),downloadedAt:new Date().toISOString()};
        records.push(record);console.log(g.id,r.reportDate,record.holdings.length,'reconciled');
      } catch(e) {failures.push({guruId:g.id,accession:r.filing.accessionNumber,error:e.message});console.log(g.id,r.reportDate,e.message);}
    }
  }
  const report={version:'strategy-original-filings-v1',asOf:end,records,recordsHash:signature(records),failures,sourceWrites:source.db.prepare('SELECT total_changes() n').get().n};
  fs.writeFileSync(path.join(output,'filings.json'),JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
  console.log(JSON.stringify({recovered:records.length,failures:failures.length,sourceWrites:report.sourceWrites}));
} finally {source.close();}
