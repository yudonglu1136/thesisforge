import fs from 'node:fs';
import crypto from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {setTimeout as pause} from 'node:timers/promises';

const args=Object.fromEntries(process.argv.slice(2).map((x,i,a)=>x.startsWith('--')?[x.slice(2),a[i+1]]:null).filter(Boolean));
const file=args.db,envFile=args['env-file'];
if(!file||!fs.existsSync(file))throw Error('Pass --db existing private hedge.sqlite');
const apiKey=process.env.POLYGON_API_KEY??(envFile?fs.readFileSync(envFile,'utf8').match(/^POLYGON_API_KEY\s*=\s*(.+)$/m)?.[1]?.trim().replace(/^['"]|['"]$/g,''):null);
if(!apiKey)throw Error('POLYGON_API_KEY required on the server only');
const now=new Date();
const eastern=new Intl.DateTimeFormat('en-CA',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit'}).format(now);
const previous=new Date(eastern+'T12:00:00Z');previous.setUTCDate(previous.getUTCDate()-1);
while([0,6].includes(previous.getUTCDay()))previous.setUTCDate(previous.getUTCDate()-1);
const end=args.end??previous.toISOString().slice(0,10),start=args.start??'2026-04-17';
if(!/^\d{4}-\d{2}-\d{2}$/.test(end)||end>=eastern||start>end)throw Error('Use a completed, prior-session date range');
const db=new DatabaseSync(file);db.exec('PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL;');
db.exec(fs.readFileSync(new URL('../server/hedgeSchema.sql',import.meta.url),'utf8'));
const id=crypto.randomUUID(),started=new Date().toISOString();
let requests=0,failed=0,bars=0,empty=0,cacheHits=0;
const full=args.scope==='monthly-full';
const report={scope:full?'QQQ standard monthly expirations; strikes in $5 increments; 70–115% of observed underlying range':'QQQ next three monthly expirations (at least 20 DTE); $25 strike grid; approximately 85–110% of spot; existing archive preserved',start,end,snapshotStatus:null};
db.prepare('INSERT INTO hedge_sync_runs VALUES(?,?,?,?,?,?)').run(id,started,null,end,'running',JSON.stringify(report));
function cleanPayload(value){
 if(Array.isArray(value))return value.map(cleanPayload);
 if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).filter(([k])=>!/^api_?key$|^authorization$/i.test(k)).map(([k,v])=>[k,cleanPayload(v)]));
 if(typeof value==='string')return value.replace(/([?&]apiKey=)[^&\s]+/gi,'$1REDACTED').replaceAll(apiKey,'REDACTED');return value;
}
let nextRequestAt=0;
async function get(endpoint,parameters={},cache=true){
 const u=new URL(endpoint,'https://api.polygon.io');
 if(u.origin!=='https://api.polygon.io')throw Error('Unexpected API pagination host');
 u.searchParams.delete('apiKey');for(const [k,v] of Object.entries(parameters))u.searchParams.set(k,String(v));
 u.searchParams.sort();const key=crypto.createHash('sha256').update(u.pathname+u.search).digest('hex');
 const old=db.prepare('SELECT * FROM hedge_requests WHERE id=?').get(key);
 if(cache&&old?.status==='ok'){cacheHits++;return JSON.parse(old.raw_json);}
 for(let attempt=0;attempt<4;attempt++){
  const slot=Math.max(Date.now(),nextRequestAt);nextRequestAt=slot+13000;
  await pause(Math.max(0,slot-Date.now()));
  let response;
  try{response=await fetch(u,{headers:{Authorization:'Bearer '+apiKey},signal:AbortSignal.timeout(25000)});}catch{if(attempt<3){await pause(1000*(attempt+1));continue;}failed++;return null;}
  requests++;
  if(response.status===429||response.status>=500){await pause(response.status===429?30000:1000*(attempt+1));if(attempt<3)continue;}
  let payload;try{payload=cleanPayload(await response.json());}catch{payload={status:'invalid_json'};}
  const ok=response.ok&&['OK','DELAYED'].includes(payload.status);
  db.prepare(`INSERT INTO hedge_requests VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET status=excluded.status,http_status=excluded.http_status,row_count=excluded.row_count,fetched_at=excluded.fetched_at,raw_json=excluded.raw_json`)
   .run(key,u.pathname,JSON.stringify(Object.fromEntries(u.searchParams)),ok?'ok':'error',response.status,payload.results?.length??0,new Date().toISOString(),JSON.stringify(payload));
  if(!ok){failed++;return null;}await pause(75);return payload;
 }
 return null;
}
async function pages(endpoint,parameters){let rows=[],next=endpoint,p=parameters;while(next){const j=await get(next,p);if(!j)return null;rows.push(...(j.results??[]));next=j.next_url??null;p={};}return rows;}
const putBar=db.prepare('INSERT INTO hedge_bars VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(ticker,date,provider,adjustment) DO NOTHING');
function storeBars(ticker,rows){
 db.exec('BEGIN IMMEDIATE');try{for(const b of rows){
  const date=new Date(b.t).toISOString().slice(0,10);
  if(date>end||date<start||!(b.c>0)||![b.o,b.h,b.l,b.c,b.v].every(Number.isFinite)||b.l>Math.min(b.o,b.c)||b.h<Math.max(b.o,b.c)||b.v<0)continue;
  const old=db.prepare("SELECT * FROM hedge_bars WHERE ticker=? AND date=? AND provider='polygon_api' AND adjustment='raw'").get(ticker,date);
  if(old&&['open','high','low','close','volume'].some((k,i)=>old[k]!==[b.o,b.h,b.l,b.c,b.v][i]))throw Error('Same-provider bar conflict; stored history preserved');
  bars+=Number(putBar.run(ticker,date,'polygon_api','raw',b.o,b.h,b.l,b.c,b.v,new Date().toISOString()).changes);
 }db.exec('COMMIT');}catch(e){db.exec('ROLLBACK');throw e;}
}
function monthly(date){const d=new Date(date+'T12:00:00Z');return d.getUTCDay()===5&&d.getUTCDate()>=15&&d.getUTCDate()<=21;}
try{
 const underlying=await get(`/v2/aggs/ticker/QQQ/range/1/day/${start}/${end}`,{adjusted:false,sort:'asc',limit:50000});
 if(!underlying?.results?.length)throw Error('No authorized underlying observations');
 storeBars('QQQ',underlying.results);
 const last=underlying.results.at(-1),effectiveEnd=new Date(last.t).toISOString().slice(0,10);
 report.effectiveEnd=effectiveEnd;report.underlyingClose=last.c;
 const priorProbe=db.prepare("SELECT http_status FROM hedge_requests WHERE endpoint='/v3/snapshot/options/QQQ' ORDER BY fetched_at DESC LIMIT 1").get();
 const probe=priorProbe?.http_status===403?null:await get('/v3/snapshot/options/QQQ',{limit:1},false);
 report.snapshotStatus=probe?'accessible_not_used_for_historical_fills':'unavailable_by_plan';
 const min=full?Math.floor(Math.min(...underlying.results.map(x=>x.c))*.7/5)*5:Math.floor(last.c*.85/25)*25;
 const max=full?Math.ceil(Math.max(...underlying.results.map(x=>x.c))*1.15/5)*5:Math.ceil(last.c*1.1/25)*25;
 const far=new Date(end+'T12:00:00Z');far.setUTCMonth(far.getUTCMonth()+6);
 const ref=[];
 if(full)for(const expired of [true,false]){
  const rows=await pages('/v3/reference/options/contracts',{underlying_ticker:'QQQ',as_of:effectiveEnd,expired,'expiration_date.gte':start,'expiration_date.lte':far.toISOString().slice(0,10),'strike_price.gte':min,'strike_price.lte':max,limit:1000,sort:'ticker',order:'asc'});
  if(!rows)throw Error('Contract reference pagination incomplete');ref.push(...rows);
 }
 else {
  const expirations=[];
  for(let month=0;expirations.length<3;month++){
   const d=new Date(end+'T12:00:00Z');d.setUTCDate(1);d.setUTCMonth(d.getUTCMonth()+month);
   while(d.getUTCDay()!==5)d.setUTCDate(d.getUTCDate()+1);d.setUTCDate(d.getUTCDate()+14);
   if((d-new Date(end+'T12:00:00Z'))/86400000>=20)expirations.push(d.toISOString().slice(0,10));
  }
  report.expirations=expirations;
  for(const expiration of expirations){
   const rows=await pages('/v3/reference/options/contracts',{underlying_ticker:'QQQ',as_of:effectiveEnd,expiration_date:expiration,'strike_price.gte':min,'strike_price.lte':max,limit:1000,sort:'ticker',order:'asc'});
   if(!rows)throw Error('Contract reference pagination incomplete');ref.push(...rows);
  }
 }
 const contracts=[...new Map(ref.map(c=>[c.ticker,c])).values()];
 const putContract=db.prepare('INSERT INTO hedge_contracts VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(ticker,as_of,provider) DO NOTHING');
 db.exec('BEGIN IMMEDIATE');try{for(const c of contracts){
  const standard=c.underlying_ticker==='QQQ'&&c.shares_per_contract===100&&!c.additional_underlyings?.length&&/^O:QQQ\d{6}[CP]\d{8}$/.test(c.ticker);
  putContract.run(c.ticker,effectiveEnd,'polygon_api',c.underlying_ticker,c.expiration_date,c.contract_type,c.strike_price,c.shares_per_contract??null,c.exercise_style??null,standard?1:0,JSON.stringify(c));
 }db.exec('COMMIT');}catch(e){db.exec('ROLLBACK');throw e;}
 const grid=full?5:25;
 const selected=contracts.filter(c=>c.shares_per_contract===100&&!c.additional_underlyings?.length&&monthly(c.expiration_date)&&Math.abs(c.strike_price/grid-Math.round(c.strike_price/grid))<1e-8&&/^O:QQQ\d{6}[CP]\d{8}$/.test(c.ticker));
 report.contracts=contracts.length;report.selectedContracts=selected.length;report.strikes=[min,max];
 console.log(JSON.stringify({phase:'contracts',...report}));
 let index=0,completed=0;
 await Promise.all(Array.from({length:4},async()=>{while(index<selected.length){const c=selected[index++];
  const until=c.expiration_date<effectiveEnd?c.expiration_date:effectiveEnd;
  const j=await get(`/v2/aggs/ticker/${c.ticker}/range/1/day/${start}/${until}`,{adjusted:false,sort:'asc',limit:50000});
  if(j){if(j.next_url)throw Error('Unexpected truncated daily response');storeBars(c.ticker,j.results??[]);if(!j.results?.length)empty++;}
  completed++;if(completed%10===0)console.log(JSON.stringify({phase:'daily',completed,total:selected.length,requests,failed,bars}));
 }}));
 const allowedFailures=priorProbe?.http_status===403?0:(probe?0:1);
 const result={...report,requests,cacheHits,failed,empty,insertedBars:bars,status:failed>allowedFailures?'partial':'complete_scoped_eod',
  historicalQuoteCoverage:'not_available',pitContractSelection:'current_reference_not_historical_listed_universe',completedAt:new Date().toISOString()};
 db.prepare('UPDATE hedge_sync_runs SET completed_at=?,status=?,report_json=? WHERE id=?').run(result.completedAt,result.status,JSON.stringify(result),id);
 console.log(JSON.stringify(result,null,2));if(result.status==='partial')process.exitCode=2;
}catch(e){db.prepare('UPDATE hedge_sync_runs SET completed_at=?,status=?,report_json=? WHERE id=?').run(new Date().toISOString(),'failed',JSON.stringify({...report,error:e.message}),id);throw e;}
finally{db.close();}
