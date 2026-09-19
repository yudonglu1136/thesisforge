// Read-only real-source smoke audit. Writes only a new diagnostic report.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { InvestmentSource } from '../server/investmentSource.js';
import { loadStrategyData, strategyCatalog } from '../server/strategyLabSource.js';
import { runStrategyLab, strategyRules } from '../server/strategyLab.js';

const [file,etfFile,reportPath]=process.argv.slice(2);
if(!file||!etfFile||!reportPath)throw new Error('Usage: node scripts/verify-strategy-lab.mjs runtime.sqlite etfs.json new-report.json');
const source=new InvestmentSource(file), reports=[];
try {
  const catalog=strategyCatalog(source,'2026-08-28',etfFile);
  const cases=[
    {name:'Buffett Top 5 / 30% / KMLM 30%',managers:['warren-buffett']},
    {name:'Buffett Top 5 / 15% / KMLM 30%',managers:['warren-buffett'],maxPremium:.15},
    {name:'Buffett Top 5 / 30% / DBMF 50%',managers:['warren-buffett'],cta:'DBMF',ctaWeight:.5},
    {name:'Buffett Top 10 / no filter / no CTA',managers:['warren-buffett'],topN:10,valuationEnabled:false,cta:'none',ctaWeight:0},
    {name:'Ackman Top 5 / DBMF 50% / 1Y',managers:['bill-ackman'],start:'2025-08-28',cta:'DBMF',ctaWeight:.5},
    {name:'Buffett + Ackman Top 3 / KMLM 30% / 1Y',managers:['warren-buffett','bill-ackman'],topN:3,start:'2025-08-28'},
    {name:'Ackman original quarterly replay / 5Y',managers:['bill-ackman'],start:'2021-08-28'},
    {name:'KMLM pre-inception / 2019–2020',managers:['warren-buffett'],topN:1,valuationEnabled:false,start:'2019-08-28',end:'2020-08-28',expectedFailure:'cta_history_missing'},
    {name:'Stan Moss unreconciled original / 3Y',managers:['stan-moss'],valuationEnabled:false,expectedFailure:'original_filing_missing'},
  ];
  for(const {name,expectedFailure,...options} of cases) {
    const rules=strategyRules({topN:5,valuationEnabled:true,maxPremium:.3,excludedAllocation:'redistribute',cta:'KMLM',ctaWeight:.3,costBps:10,start:'2023-08-28',end:'2026-08-28',asOf:'2026-08-28',...options},catalog.managers);
    const start=performance.now(),data=loadStrategyData(source,rules,etfFile),loaded=performance.now();
    const result=runStrategyLab(data,rules),finished=performance.now();
    assert.deepEqual(runStrategyLab(data,rules),result);
    for(const event of result.ledger??[]) {
      const sum=event.holdings.reduce((n,h)=>n+h.targetWeight,0)+event.cashWeight+event.ctaWeight;
      assert.ok(Math.abs(sum-1)<1e-8);
      assert.ok(event.holdings.every(h=>!h.modelDate||h.modelDate<=event.decisionDate));
      assert.ok(event.filings.every(f=>f.publicDate<event.executionDate));
    }
    if(expectedFailure)assert.equal(result.failure?.code,expectedFailure);
    else assert.equal(result.status,'ready',name+': '+JSON.stringify(result.failure));
    if(name==='Buffett Top 5 / 30% / KMLM 30%')assert.equal(result.summary.rebalances,13);
    const report={name,rules,status:result.status,failure:result.failure??null,
      sourceMs:loaded-start,computeMs:finished-loaded,elapsedMs:finished-start,
      ruleHash:result.ruleHash,dataHash:result.dataHash??null,effective:result.effective??null,
      coverage:result.summary?{rebalances:result.summary.rebalances,execution:result.summary.minExecutionCoverage,valuation:result.summary.minModelCoverage,latestCash:result.summary.latest.cashWeight}:null,
      results:Object.fromEntries(Object.entries(result.results??{}).map(([k,r])=>[k,{status:r.status,failure:r.failure??null,metrics:r.metrics??null}]))};
    reports.push(report);console.log(JSON.stringify(report));
  }
  const changes=source.db.prepare('SELECT total_changes() n').get().n;assert.equal(changes,0);
  assert.equal(source.db.prepare('PRAGMA query_only').get().query_only,1);
  const report={generatedAt:new Date().toISOString(),source:path.resolve(file),etfArtifact:path.resolve(etfFile),sourceWrites:changes,catalogManagers:catalog.managers.length,reports};
  fs.mkdirSync(path.dirname(reportPath),{recursive:true});fs.writeFileSync(reportPath,JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
} finally {source.close();}
