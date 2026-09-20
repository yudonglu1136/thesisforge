// Read-only official-source inventory. Does not publish or infer a new 13F book.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {gurus} from '../server/gurus.js';
const [file,cutoff,out]=process.argv.slice(2);
if(!file||!/^\d{4}-\d{2}-\d{2}$/.test(cutoff??'')||!out||fs.existsSync(out))throw Error('Usage: strategy.sqlite cutoff NEW_PRIVATE_DIRECTORY');
fs.mkdirSync(out,{mode:0o700});
const db=new DatabaseSync(file,{readOnly:true}),targets=gurus.filter(g=>g.type==='manager13f');
const report={cutoff,checkedAt:new Date().toISOString(),sourceGeneration:db.prepare('SELECT manifest_hash FROM warehouse_meta').get().manifest_hash,managers:[],sourceWrites:0};
for(const g of targets){
 const stored=db.prepare('SELECT accession,public_date,report_date FROM filings WHERE manager_id=? ORDER BY public_date DESC').all(g.id);
 const row={id:g.id,storedLatest:stored[0]??null,filers:[],unimported:[]};
 for(const raw of [g.cik,...(g.alternateCiks??[])].filter(Boolean)){
  const cik=String(raw).padStart(10,'0'),url=`https://data.sec.gov/submissions/CIK${cik}.json`;
  try{
   const res=await fetch(url,{headers:{'User-Agent':process.env.SEC_USER_AGENT||'ThesisForge/0.1 contact@thesisforge.tech'},signal:AbortSignal.timeout(15000)});
   if(!res.ok)throw Error('sec_http_'+res.status);
   const body=await res.text(),payload=JSON.parse(body);if(String(payload.cik).padStart(10,'0')!==cik)throw Error('cik_mismatch');
   fs.writeFileSync(path.join(out,`${g.id}-${cik}.json`),body,{flag:'wx',mode:0o600});
   const recent=payload.filings?.recent??{},observations=(recent.form??[]).flatMap((form,i)=>/^13F-(HR|NT)(\/A)?$/.test(form)&&recent.filingDate[i]<=cutoff?[{form,accession:recent.accessionNumber[i],publicDate:recent.filingDate[i],reportDate:recent.reportDate[i],acceptedAt:recent.acceptanceDateTime?.[i],document:recent.primaryDocument?.[i]}]:[]);
   row.filers.push({cik,url,sha256:crypto.createHash('sha256').update(body).digest('hex'),latest:observations[0]??null});
   row.unimported.push(...observations.filter(f=>f.publicDate>=(stored[0]?.public_date??'2026-06-01')&&!stored.some(s=>s.accession===f.accession)).map(f=>({...f,cik})));
  }catch(e){row.filers.push({cik,error:e.message});}
 }
 report.managers.push(row);console.log(JSON.stringify({manager:g.id,newFilings:row.unimported.length,errors:row.filers.filter(f=>f.error).length}));
}
report.sourceWrites=db.prepare('SELECT total_changes() n').get().n;db.close();
fs.writeFileSync(path.join(out,'audit.json'),JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
