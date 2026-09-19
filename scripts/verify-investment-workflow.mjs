// Private local-data acceptance run. No network and no writes to the source DB.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { InvestmentSource } from '../server/investmentSource.js';
import { InvestmentStore } from '../server/investmentStore.js';
import { InvestmentService } from '../server/investmentService.js';
import { calculateScenario, reverseScenario, signature } from '../server/investmentMath.js';

const [sourcePath,outputDir]=process.argv.slice(2);
if(!sourcePath||!outputDir)throw new Error('Usage: node scripts/verify-investment-workflow.mjs <read-only-source.sqlite> <private-output-directory>');
fs.mkdirSync(outputDir,{recursive:true,mode:0o700});
const file=path.join(outputDir,`verification-${crypto.randomUUID()}.sqlite`);
let store=new InvestmentStore(file);
const source=new InvestmentSource(sourcePath);
const service=new InvestmentService(source,store,()=> '2026-09-08');
const report={status:'pass',sourcePath,sourceReadOnly:true,decisionDb:file,retrospective:true,results:[]};
const op=()=>crypto.randomUUID();
for(const ticker of ['ISRG','MSFT']){
  const before=service.research('local-acceptance',ticker,'2026-06-01');
  const assumptions=before.templates.Base;
  const result=calculateScenario(before.base,assumptions);
  assert.ok(Math.abs(result.fairValue-before.published.dcf)<1e-8);
  const independent=result.forecast.reduce((s,r,i)=>s+r.fcfeM/(1+assumptions.ke)**(i+1),0)
    +result.forecast[4].fcfeM*(1+assumptions.g)/(assumptions.ke-assumptions.g)/(1+assumptions.ke)**5;
  assert.ok(Math.abs(result.fairValue-independent/before.base.sharesM)<1e-8);
  const reverse=reverseScenario(before.base,assumptions,before.snapshot.price.value);
  assert.equal(reverse.status,'solved');assert.ok(Math.abs(reverse.residual)<1e-8);
  const scenario=service.saveScenario('local-acceptance',{operationId:op(),ticker,asOf:'2026-06-01',snapshotId:before.snapshot.id,name:'Baseline research',assumptions,ownershipConfirmed:true});
  const decision=service.saveDecision('local-acceptance',{operationId:op(),ticker,asOf:'2026-06-01',action:'Invest',scenarioId:scenario.id,units:10,targetWeight:.05,notes:'Local acceptance: review revenue growth below 30%, not an investment recommendation.',rules:[{metric:'revenueGrowth',operator:'lt',threshold:.3,consecutive:1,scope:'new_financial_periods',severity:'review'}]});
  const original=signature(decision);
  store.close();store=new InvestmentStore(file);service.store=store;
  assert.equal(signature(store.get('local-acceptance',decision.id)),original);
  const review=service.reviewContext('local-acceptance',decision.id,'2026-08-28');
  assert.ok(review.reviewRequired);assert.ok(review.now.snapshot.periodEnd>decision.snapshot.periodEnd);
  assert.deepEqual(review.activeScenario.assumptions,assumptions);
  const maintain=service.saveReview('local-acceptance',{operationId:op(),decisionId:decision.id,expectedHeadId:review.headId,asOf:'2026-08-28',action:'Maintain',notes:'Acceptance test: preserve original assumptions.'});
  assert.equal(maintain.scenario.id,scenario.id);
  const newAssumptions={...assumptions,ke:assumptions.ke+.01};
  const newScenario=service.saveScenario('local-acceptance',{operationId:op(),ticker,asOf:'2026-08-28',snapshotId:review.now.snapshot.id,name:'Higher discount-rate sensitivity',parentId:scenario.id,assumptions:newAssumptions,ownershipConfirmed:true});
  const changed=service.saveReview('local-acceptance',{operationId:op(),decisionId:decision.id,expectedHeadId:maintain.id,asOf:'2026-08-28',action:'Change',scenarioId:newScenario.id,notes:'Acceptance test: explicit new discount rate, not an automatic update.'});
  assert.equal(changed.scenario.id,newScenario.id);
  assert.equal(signature(store.get('local-acceptance',decision.id)),original);
  report.results.push({ticker,beforePeriod:before.snapshot.period,afterPeriod:review.now.snapshot.period,
    baselineDcf:result.fairValue,publishedStandaloneDcf:before.published.dcf,
    reverseGrowth:reverse.value,reverseResidual:reverse.residual,
    sameAssumptionsNewActuals:review.sameAssumptions.fairValue,newScenarioValue:newScenario.result.fairValue,
    trigger:review.triggers[0].status,restartPreserved:true,maintainPreserved:true,changeCreatedNewVersion:true,originalUnchanged:true,
    sourceHash:before.snapshot.source.hash,calculationSignature:result.signature});
}
const again=new InvestmentSource(sourcePath);
for(const row of report.results){const c=again.company(row.ticker,'2026-06-01');assert.equal(c.snapshot.source.hash,row.sourceHash);assert.equal(calculateScenario(c.base,c.templates.Base).signature,row.calculationSignature);}
again.close();source.close();store.close();
fs.writeFileSync(path.join(outputDir,'acceptance.json'),JSON.stringify(report,null,2),{mode:0o600});
console.log(JSON.stringify(report,null,2));
