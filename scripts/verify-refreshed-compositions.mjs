// Real-data, read-only population sweep. No rule is silently relaxed and no
// blocked configuration is relabeled ready. Reports every configured manager.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {InvestmentSource} from '../server/investmentSource.js';
import {storedStrategyCatalog} from '../server/strategyDatabase.js';
import {loadCompositionData,runStrategyComposition} from '../server/strategyComposition.js';
import {strategyRules,strategyMetrics} from '../server/strategyLab.js';
import {FACTOR_KEYS} from '../server/strategyEquityMix.js';
import {enabledManager13fGurus} from '../server/gurus.js';
import {signature} from '../server/investmentMath.js';
import {yearsBefore} from './strategy-regression-matrix.mjs';

const [runtime,warehouse,prices,out,cutoff='2026-09-11']=process.argv.slice(2);
assert.ok(runtime&&warehouse&&prices&&out&&!fs.existsSync(out),'new report directory required');
process.env.STRATEGY_DATA_DB_PATH=warehouse;process.env.STRATEGY_COMPOSITION_PRICE_DB_PATH=prices;
fs.mkdirSync(out,{mode:0o700});
const catalog=storedStrategyCatalog(warehouse,cutoff),source=new InvestmentSource(runtime);
assert.deepEqual(catalog.managers.map(g=>g.id).sort(),enabledManager13fGurus.map(g=>g.id).sort(),'complete configured population required');
const families=[];
for(const g of catalog.managers)for(const years of [1,3,5,10])for(const topN of [1,5,10])
  families.push({name:`${g.id}-${years}y-top${topN}`,years,topN,managers:[g.id],weights:{guru:1},filters:topN===5?[null,.3,.5]:[null]});
for(let mask=1;mask<16;mask++)for(const years of [1,5]){
  const enabled=FACTOR_KEYS.filter((_,i)=>mask&(1<<i));
  families.push({name:`factors-${enabled.join('-')}-${years}y`,years,managers:[],weights:{factors:1},factors:{enabled,rankBy:enabled[0]},filters:[null,.3,.5]});
}
for(const index of ['QQQ','SPY','SCHD'])for(const cta of ['KMLM','DBMF'])for(const policy of [{mode:'hold'},...['monthly','quarterly','annually'].map(frequency=>({mode:'scheduled',frequency})),{mode:'tranches'}])
  families.push({name:`${index}-${cta}-${policy.mode}-${policy.frequency??''}`,years:5,managers:[],weights:{[index]:1},cta,ctaPolicy:policy,filters:[null],multiples:[1,1.5]});
families.push({name:'all-components',years:5,managers:['bill-ackman','li-lu','dev-kantesaria'],weights:{guru:.2,factors:.2,QQQ:.2,SPY:.2,SCHD:.2},filters:[null,.3,.5]});
const rows=[],journal=fs.openSync(out+'/cases.jsonl','wx',0o600),startedAt=new Date().toISOString();
let loadedManager=null,managerData=null;
const near=(a,b)=>assert.ok(Number.isFinite(a)&&Number.isFinite(b)&&Math.abs(a-b)<1e-8,`${a} != ${b}`);
try {
  for(const f of families){
    const common={managers:f.managers,topN:f.topN??5,valuationEnabled:true,maxPremium:.3,
      excludedAllocation:'fully_invested',cta:f.cta??'none',ctaWeight:f.cta ? .3 : 0,costBps:10,
      start:yearsBefore(cutoff,f.years),end:cutoff,asOf:cutoff,leverage:{multiple:1,annualRate:.04,reset:'filing'},
      equityMix:{weights:f.weights,factors:f.factors},...(f.ctaPolicy?{ctaPolicy:f.ctaPolicy}:{})};
    let data,loadError;const begin=performance.now();
    try{
      if(f.weights.guru===1&&f.managers.length===1){
        // The serving adapter loads each manager's full disclosed Top-10
        // history irrespective of requested N. Reuse that immutable 10Y input
        // for shorter runs; still execute and verify every rule separately.
        const id=f.managers[0];
        if(loadedManager!==id){
          managerData=loadCompositionData(source,strategyRules({...common,start:yearsBefore(cutoff,10),topN:10},catalog.managers));
          loadedManager=id;
        }
        data=managerData;
      }else data=loadCompositionData(source,strategyRules(common,catalog.managers));
    }catch(e){loadError=e;}
    for(const premium of f.filters)for(const multiple of f.multiples??[1]){
      const rules=strategyRules({...common,valuationEnabled:premium!==null,maxPremium:premium??.3,leverage:{...common.leverage,multiple}},catalog.managers);
      let row;
      try {
        if(loadError)throw loadError;
        const result=runStrategyComposition(data,rules);
        assert.equal(result.ruleHash,signature(rules));
        assert.equal(result.sources.generation,catalog.storage.generation);
        for(const entry of result.ledger??[]){
          assert.ok(entry.filings.every(x=>x.publicDate<entry.executionDate));
          assert.ok(entry.holdings.every(x=>!x.modelDate||x.modelDate<=entry.decisionDate));
          assert.ok(entry.holdings.every(x=>!x.availableAt||x.availableAt<=entry.decisionDate));
        }
        for(const curve of Object.values(result.results??{})){
          if(curve.status!=='ready'){assert.ok(curve.failure?.code);assert.equal(curve.equity?.length??0,0);continue;}
          assert.deepEqual(curve.equity.map(x=>x.date),data.dates.filter(d=>d>=rules.start&&d<=cutoff));
          assert.equal(curve.equity.at(-1).date,cutoff);assert.ok(curve.equity.every(x=>Number.isFinite(x.value)&&x.value>0));
          const recalculated=strategyMetrics(curve.equity);
          for(const k of ['cagr','maxDrawdown','volatility','endingValue'])near(curve.metrics[k],recalculated[k]);
        }
        if(result.status==='ready'){
          const final=multiple>1?result.results.leveraged:result.results.blend;assert.equal(final.status,'ready');
          for(const snap of result.holdingSnapshots){near(snap.cashWeight,0);near(snap.positions.reduce((n,p)=>n+p.weight,0),1);}
        }else assert.ok(result.failure?.code,'blocked result requires a reason');
        row={name:f.name,premium,multiple,status:result.status,failure:result.failure??null,
          snapshots:result.holdingSnapshots?.length??0,
          curves:Object.fromEntries(Object.entries(result.results??{}).map(([k,v])=>[k,{status:v.status,last:v.equity?.at(-1)?.date,rows:v.equity?.length??0,metrics:v.metrics}]))};
      }catch(e){row={name:f.name,premium,multiple,status:'verification_error',failure:{code:e.message}};}
      row.elapsedMs=Math.round(performance.now()-begin);rows.push(row);fs.writeSync(journal,JSON.stringify(row)+'\n');
      if(rows.length%20===0||row.status==='verification_error')console.log(JSON.stringify({completed:rows.length,...row,curves:undefined}));
    }
  }
}finally{fs.closeSync(journal);source.close();}
const counts={};for(const r of rows)counts[r.status]=(counts[r.status]??0)+1;
const failures={};for(const r of rows.filter(r=>r.status!=='ready'))failures[r.failure?.code??'unknown']=(failures[r.failure?.code??'unknown']??0)+1;
const summary={status:counts.verification_error?'fail':'validated_with_explicit_blocks',allConfigurationsReady:rows.every(r=>r.status==='ready'),
  cutoff,generation:catalog.storage.generation,startedAt,finishedAt:new Date().toISOString(),cases:rows.length,counts,failures,
  managers:catalog.managers.map(g=>g.id),nonemptyFactorSubsets:15,filters:['off','30%','50%'],sourceWrites:0,
  scope:'Every manager: Top 1/5/10 across 1/3/5/10 years; Top 5 with filters off/30%/50%. All 15 factor subsets at 1/5Y. Three index ETFs, two CTA ETFs, five CTA policies and 1x/1.5x. Not every continuous parameter combination. Uses currently stored issuer coverage, not a survivorship-free universe.'};
fs.writeFileSync(out+'/summary.json',JSON.stringify(summary,null,2),{flag:'wx',mode:0o600});console.log(JSON.stringify(summary));
if(counts.verification_error)process.exitCode=1;
