import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {spawnSync} from 'node:child_process';

// Explicit local copies only. Neither credentials nor the source project's code
// are copied. A new destination is mandatory; failed candidates remain private.
const args=Object.fromEntries(process.argv.slice(2).map((x,i,a)=>x.startsWith('--')?[x.slice(2),a[i+1]]:null).filter(Boolean));
const source=path.resolve(args.source??'../qqq-options-backtest');
const dest=path.resolve(args.output??'output/hedge-data-20260910');
if(fs.existsSync(dest))throw Error('Choose a NEW output directory; originals are never overwritten');
fs.mkdirSync(dest,{recursive:true,mode:0o700});
const started=new Date().toISOString();
const originals=[['raw','data/raw/options_data.db'],['normalized','data/normalized/options_normalized.db']];
const copies=[];
for(const [kind,relative] of originals){
 const from=path.join(source,relative),to=path.join(dest,kind+'.sqlite');
 const result=spawnSync('sqlite3',['-readonly',from,`.backup '${to.replaceAll("'","''")}'`],{encoding:'utf8'});
 if(result.status!==0)throw Error('SQLite source backup failed: '+kind);
 fs.chmodSync(to,0o600);const hash=crypto.createHash('sha256');
 for await(const chunk of fs.createReadStream(to))hash.update(chunk);
 copies.push({kind,path:to,sha256:hash.digest('hex')});
 console.log(JSON.stringify({copied:kind,bytes:fs.statSync(to).size}));
}
const target=path.join(dest,'hedge.sqlite'),db=new DatabaseSync(target);
fs.chmodSync(target,0o600);
db.exec(fs.readFileSync(new URL('../server/hedgeSchema.sql',import.meta.url),'utf8'));
db.prepare('ATTACH DATABASE ? AS raw').run(copies[0].path);
db.prepare('ATTACH DATABASE ? AS normalized').run(copies[1].path);
db.exec('BEGIN IMMEDIATE');
try {
 db.exec(`INSERT INTO hedge_contracts SELECT ticker,as_of,'polygon_legacy_reference',underlying_ticker,
 expiration_date,contract_type,strike_price,NULL,NULL,0,
 json_object('ticker',ticker,'strike_price',strike_price,'expiration_date',expiration_date,'as_of',as_of)
 FROM raw.option_contracts WHERE underlying_ticker='QQQ';
 INSERT INTO hedge_bars SELECT option_ticker,date,COALESCE(source,'legacy_option_daily'),'unknown',open,high,low,close,volume,'${started}'
 FROM raw.option_open_close WHERE option_ticker LIKE 'O:QQQ%';
 INSERT INTO hedge_bars SELECT ticker,date,'legacy_underlying','unknown',open,high,low,close,volume,'${started}'
 FROM raw.underlying_daily WHERE ticker='QQQ';
 INSERT INTO hedge_observations SELECT ticker,trade_date,'legacy_normalized:'||source,expiration,type,strike,underlying_close,
 bid,ask,last,volume,open_interest,implied_volatility,delta,gamma,theta,vega,
 'legacy_unverified_quote_time_and_greeks',
 json_object('mid',mid,'dte',dte,'source',source)
 FROM normalized.option_quotes WHERE underlying='QQQ';
 INSERT INTO hedge_observations SELECT option_ticker,capture_date,'legacy_chain_capture',expiration_date,contract_type,strike_price,
 underlying_price,last_quote_bid,last_quote_ask,last_trade_price,day_volume,open_interest,implied_volatility,delta,gamma,theta,vega,
 'legacy_unverified_quote_time',json_object('day_close',day_close,'updated_at_ns',updated_at_ns,'capture_source',capture_source)
 FROM raw.option_chain_capture WHERE underlying_ticker='QQQ';`);
 for(const copy of copies)db.prepare('INSERT INTO hedge_sources VALUES(?,?,?,?,?,?)').run(copy.sha256,copy.kind,copy.path,copy.sha256,started,0);
 db.prepare('INSERT INTO hedge_meta VALUES(?,?)').run('schema_version','1');
 db.prepare('INSERT INTO hedge_meta VALUES(?,?)').run('source_project',source);
 db.exec('COMMIT');
}catch(e){db.exec('ROLLBACK');throw e;}
const counts=Object.fromEntries(['hedge_contracts','hedge_bars','hedge_observations'].map(t=>[t,db.prepare(`SELECT count(*) n FROM ${t}`).get().n]));
const integrity=db.prepare('PRAGMA integrity_check').get().integrity_check;
db.close();
const report={source,database:target,started,copies,counts,integrity,sourceWrites:0,
 limitations:['Legacy contract multipliers not independently verified','Legacy quote times and calculated Greeks not accepted for execution']};
fs.writeFileSync(path.join(dest,'import.json'),JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
console.log(JSON.stringify(report,null,2));
