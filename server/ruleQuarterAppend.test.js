import test from 'node:test';
import assert from 'node:assert/strict';
import {loadInvestorStyleDashboard} from './investorStyleDashboard.js';
import {appendRuleQuarterSelections} from './ruleQuarterAppend.js';
import {extendPublishedPriceVintage} from './rulePriceVintage.js';

function fixture(){
  const source=loadInvestorStyleDashboard(),generation='c'.repeat(64);
  const schedules=Object.fromEntries(source.styles.map(s=>{const q=structuredClone(s.quarters.at(-1));
    return [s.id,[{...q,quarter:'2026-09-30',signalDate:'2026-09-30',executionDate:'2026-10-01',nextExecutionDate:null}]];}));
  return {source,packet:{lineage:{sourceGeneration:generation,sourceWrites:false,forwardOutcomeColumnsRead:false},schedules},
    options:{sourceGeneration:generation,tradingDates:[...source.backtest.curve.map(r=>r.date),'2026-09-30','2026-10-01','2026-10-02'],end:'2026-10-02'}};
}
test('quarter append preserves old selections and uses the actual next session',()=>{
  const {source,packet,options}=fixture(),before=structuredClone(source);
  const {snapshot}=appendRuleQuarterSelections(source,packet,options);
  assert.deepEqual(source,before);
  for(const s of snapshot.styles){
    const previous=before.styles.find(x=>x.id===s.id);
    assert.deepEqual(s.quarters.slice(0,-2),previous.quarters.slice(0,-1));
    assert.equal(s.quarters.at(-2).nextExecutionDate,'2026-10-01');
    assert.equal(s.quarters.at(-1).executionDate,'2026-10-01');
    assert.equal(s.quarters.at(-1).quarter,'2026-09-30');
  }
});
test('missing quarter, wrong generation, forward disclosure and new actions fail closed',()=>{
  for(const edit of [p=>p.lineage.sourceGeneration='bad',p=>p.schedules.ackman=[],
    p=>p.schedules.quality_rank[0].executionDate='2026-10-02',
    p=>p.schedules.quality_rank[0].positions[0].sourceDates.ttm_date='2026-10-01',
    p=>p.actions=[{corporateAction:{effectiveDate:'2026-09-25'}}]]){
    const {source,packet,options}=fixture();edit(packet);
    assert.throws(()=>appendRuleQuarterSelections(source,packet,options));
  }
});
test('newly selected stock requires explicit post-parent entry and actual price',()=>{
  const snapshot={snapshotId:'a',dataThrough:'2026-09-30',styles:[],backtest:{curve:[{date:'2026-09-30',spy:1}]}},
    ledger={snapshotId:'a',styles:[]},current=new Map([['NEW',new Map([['2026-10-01',10],['2026-10-02',11]])]]);
  assert.throws(()=>extendPublishedPriceVintage(snapshot,ledger,current),/anchor_missing/);
  const result=extendPublishedPriceVintage(snapshot,ledger,current,{newSymbols:{NEW:'2026-10-01'}});
  assert.equal(result.prices.get('NEW').get('2026-10-02'),11);
  assert.throws(()=>extendPublishedPriceVintage(snapshot,ledger,current,{newSymbols:{NEW:'2026-10-03'}}),/new_entry_missing/);
  assert.throws(()=>extendPublishedPriceVintage(snapshot,ledger,current,{newSymbols:{NEW:'2026-09-30'}}),/anchor_missing/);
});
