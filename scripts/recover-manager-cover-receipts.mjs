// Fetch only original SEC cover documents for configured staged 13F filers.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {gurus} from '../server/gurus.js';
const [staged,out,ids]=process.argv.slice(2);
if(!staged||!out||!ids||fs.existsSync(out))throw Error('staged directory, NEW receipt directory and manager IDs required');
process.umask(0o077);fs.mkdirSync(out,{mode:0o700});
const hash=x=>crypto.createHash('sha256').update(x).digest('hex'),urls=new Set();
for(const id of ids.split(',')){
  const guru=gurus.find(g=>g.id===id&&g.type==='manager13f');if(!guru)throw Error('unknown_manager');
  const data=JSON.parse(fs.readFileSync(path.join(staged,id+'.json')));if(data.guru.cik!==guru.cik)throw Error('manager_identity_mismatch');
  for(const row of data.history){
    if(row.reportDate<'2013-03-31')continue; // Older text forms require their existing legacy parser.
    const u=new URL('primary_doc.xml',row.filing.xmlUrl);
    if(u.origin!=='https://www.sec.gov'||u.pathname.split('/')[4]!==String(Number(guru.cik)))throw Error('invalid_source');
    if(!fs.existsSync(path.join(staged,'sec-sources',hash(u.href)+'.json')))urls.add(u.href);
  }
}
const queue=[...urls],report=[];
await Promise.all(Array.from({length:3},async()=>{
  for(let url;url=queue.shift();){
    try{
      const response=await fetch(url,{headers:{'User-Agent':'ThesisForge research engineering contact@thesisforge.tech'},signal:AbortSignal.timeout(20000)});
      const body=await response.text(),receipt={url,status:response.status,sha256:hash(body),body,fetchedAt:new Date().toISOString()};
      fs.writeFileSync(path.join(out,hash(url)+'.json'),JSON.stringify(receipt),{flag:'wx',mode:0o600});
      report.push({url,status:response.status});
    }catch(e){report.push({url,error:e.message});}
    if(report.length%20===0)console.log(JSON.stringify({completed:report.length,total:urls.size}));
    await new Promise(resolve=>setTimeout(resolve,500));
  }
}));
fs.writeFileSync(path.join(out,'report.json'),JSON.stringify({sources:report},null,2),{flag:'wx',mode:0o600});
console.log(JSON.stringify({fetched:report.filter(r=>r.status===200).length,unavailable:report.filter(r=>r.status!==200).length}));
