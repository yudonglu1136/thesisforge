import fs from 'node:fs';
import {DatabaseSync} from 'node:sqlite';
import {HedgeSource} from '../server/hedgeLab.js';
import {calculateStrategyHedge} from '../server/strategyHedge.js';
const file=process.argv[2];if(!file||!fs.existsSync(file))throw Error('Pass a local hedge.sqlite file');
const db=new DatabaseSync(file,{readOnly:true});
const scalar=sql=>Object.values(db.prepare(sql).get())[0];
const report={schema:'hedge-data-audit-v1',integrity:scalar('PRAGMA integrity_check'),
 tables:db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'hedge_%' ORDER BY name").all().map(r=>({name:r.name,rows:scalar(`SELECT count(*) FROM ${r.name}`)})),
 bars:db.prepare('SELECT provider,count(*) rows,count(DISTINCT ticker) tickers,min(date) first,max(date) last FROM hedge_bars GROUP BY provider').all(),
 invalidApiBars:scalar("SELECT count(*) FROM hedge_bars WHERE provider='polygon_api' AND (close IS NULL OR close<=0 OR low>high OR volume<0)"),
 legacyStandardClaims:scalar("SELECT count(*) FROM hedge_contracts WHERE provider!='polygon_api' AND standard=1"),
 credentialUrlLeaks:scalar("SELECT count(*) FROM hedge_requests WHERE raw_json LIKE '%apiKey=%' OR endpoint LIKE '%apiKey=%'"),
 sync:db.prepare('SELECT status,started_at,completed_at FROM hedge_sync_runs ORDER BY started_at DESC LIMIT 1').get(),
};
db.close();
const source=new HedgeSource(file);try{
 const c=source.catalog();report.available={date:c.date,quoteBasis:c.quoteBasis,contracts:c.chain.length,expiries:c.expiries};
 report.experiments=[];
 for(const expiry of c.expiries.filter(x=>x.puts>=2&&x.calls>=1))for(const type of ['protective_put','collar','put_spread']){
  const r=calculateStrategyHedge({managers:['audit_configuration'],topN:5,valuationEnabled:true,cta:'KMLM',ctaWeight:.3,
   start:'2025-08-28',end:'2026-08-28',hedge:{type,date:c.date,expiry:expiry.expiry,capital:250000,coverage:1,beta:1,ctaReturn:0}},c);
  report.experiments.push({type,expiry:r.expiry,durationDays:r.durationDays,status:r.status,contracts:r.contracts,
    finiteResults:r.results.every(x=>x.curve.every(p=>Number.isFinite(p.pnl)&&Number.isFinite(p.price))),historicalOverlay:r.historicalOverlay.status});
 }
}finally{source.close();}
report.status=report.integrity==='ok'&&report.invalidApiBars===0&&report.legacyStandardClaims===0&&report.credentialUrlLeaks===0&&report.experiments.length>0&&report.experiments.every(x=>x.finiteResults)?'pass':'fail';
console.log(JSON.stringify(report,null,2));if(report.status!=='pass')process.exitCode=1;
