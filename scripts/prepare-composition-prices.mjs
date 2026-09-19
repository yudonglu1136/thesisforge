// New private research-price generation. Original serving/harvest DBs are read-only.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync,backup} from 'node:sqlite';
import {confirmPriceSeries} from './append-all-local-prices.mjs';

const [input,out,cutoff]=process.argv.slice(2);
if(!input||!out||fs.existsSync(out)||!/^\d{4}-\d{2}-\d{2}$/.test(cutoff??''))throw Error('Usage: existing_harvest.sqlite NEW_PRIVATE_DIRECTORY YYYY-MM-DD');
process.umask(0o077);fs.mkdirSync(out,{mode:0o700});
const origin=new DatabaseSync(input,{readOnly:true});
await backup(origin,path.join(out,'prices.sqlite'));origin.close();
const db=new DatabaseSync(path.join(out,'prices.sqlite'));
db.exec('CREATE TABLE source_responses(symbol TEXT,endpoint TEXT,sha256 TEXT,content TEXT,PRIMARY KEY(symbol,endpoint))');
try {
  const first='2011-01-01';
  const fetchChart=async endpoint=>{
    const url=`https://${endpoint}.finance.yahoo.com/v8/finance/chart/SCHD?period1=${Date.parse(first)/1000}&period2=${Date.parse(cutoff)/1000+86400}&interval=1d&events=div%2Csplits&includeAdjustedClose=true`;
    const response=await fetch(url,{headers:{'User-Agent':'Mozilla/5.0 ThesisForge research'},signal:AbortSignal.timeout(25000)});
    if(!response.ok)throw Error('price_provider_http_'+response.status);
    const content=await response.text(),c=JSON.parse(content).chart?.result?.[0];
    if(c?.meta?.symbol!=='SCHD'||c.meta.currency!=='USD'||c.meta.instrumentType!=='ETF')throw Error('index_identity_mismatch');
    const quote=c.indicators.quote[0],adj=c.indicators.adjclose?.[0]?.adjclose,rows=[];
    for(const [i,t] of c.timestamp.entries()){
      const date=new Date(t*1000).toISOString().slice(0,10);if(date>cutoff)continue;
      const close=quote.close[i],value=adj?.[i],high=quote.high[i],low=quote.low[i];
      if(![close,value,high,low].every(v=>Number.isFinite(v)&&v>0)||close<low||close>high)throw Error('invalid_index_bar_'+date);
      rows.push({date,open:quote.open[i],high,low,close,adjusted_close:value,volume:quote.volume[i],quality_status:'verified_daily_bar'});
    }
    if(rows.at(-1)?.date!==cutoff||new Set(rows.map(r=>r.date)).size!==rows.length)throw Error('index_history_incomplete');
    return {url,content,c,rows,sha:crypto.createHash('sha256').update(content).digest('hex')};
  };
  const a=await fetchChart('query1'),b=await fetchChart('query2');
  confirmPriceSeries(a.rows,new Map(b.rows.map(r=>[r.date,{close:r.close,adj:r.adjusted_close}])));
  db.exec('BEGIN IMMEDIATE');
  for(const [endpoint,v] of [['query1',a],['query2',b]])db.prepare('INSERT INTO source_responses VALUES(?,?,?,?)').run('SCHD',endpoint,v.sha,v.content);
  db.prepare('INSERT INTO series VALUES(?,?,?,?,?,?,?,?,?,?)').run('SCHD','SCHD','USD',a.rows[0].date,cutoff,a.rows.length,a.sha,JSON.stringify(a.c.meta),JSON.stringify(a.c.events??{}),'current');
  const insert=db.prepare('INSERT INTO prices VALUES(?,?,?,?,?,?,?,?,?)');
  for(const r of a.rows)insert.run('SCHD',r.date,r.open,r.high,r.low,r.close,r.adjusted_close,r.volume,r.quality_status);
  db.prepare('INSERT INTO audit VALUES(?,?)').run('SCHD',JSON.stringify({symbol:'SCHD',source:a.url,first:a.rows[0].date,last:cutoff,status:'current',rows:a.rows.length,sourceHash:a.sha,confirmationHash:b.sha,currency:'USD',metadata:a.c.meta}));
  db.exec('COMMIT');
  const report={cutoff,sourceDatabase:path.resolve(input),scope:'Immutable full-vintage research returns; separate from legacy Guru series. SCHD confirmed against both chart endpoints.',SCHD:{first:a.rows[0].date,last:cutoff,rows:a.rows.length,sha256:a.sha,confirmation:b.sha}};
  fs.writeFileSync(path.join(out,'manifest.json'),JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
  console.log(JSON.stringify(report));
}finally{db.close();}
