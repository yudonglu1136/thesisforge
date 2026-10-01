import test from 'node:test';
import assert from 'node:assert/strict';
import { extendPublishedPriceVintage } from './rulePriceVintage.js';

const snapshot={dataThrough:'2026-09-21',snapshotId:'abc',backtest:{curve:[
  {date:'2026-09-18',spy:1},{date:'2026-09-21',spy:1.1}]},styles:[{id:'quality_rank',corporateActions:[]}]};
function fixture(){return {version:'rule-range-attribution-v2',snapshotId:'abc',styles:[{id:'quality_rank',days:[
  {date:'2026-09-18',positions:new Map([['A',{price:100,basis:'total_return_adjusted_close'}]])},
  {date:'2026-09-21',positions:new Map([['A',{price:110,basis:'total_return_adjusted_close'}]])}
],events:[]}]};}
test('retain recorded prices; append observed returns in their original adjusted units',()=>{
  const current=new Map([['A',new Map([['2026-09-18',49],['2026-09-21',55],['2026-09-22',60]])],
    ['SPY',new Map([['2026-09-21',550],['2026-09-22',560]])]]);
  const out=extendPublishedPriceVintage(snapshot,fixture(),current);
  assert.equal(out.prices.get('A').get('2026-09-18'),100);
  assert.equal(out.prices.get('A').get('2026-09-22'),120);
  assert.ok(Math.abs(out.prices.get('SPY').get('2026-09-22')-1.12)<1e-12);
  assert.equal(out.bridges.A.factor,2);
  assert.equal(current.get('A').get('2026-09-18'),49);
});
test('missing anchor, stale ledger, inconsistent observations and invalid marks fail closed',()=>{
  assert.throws(()=>extendPublishedPriceVintage(snapshot,fixture(),new Map([['A',new Map([['2026-09-22',120]])]])),/anchor_missing/);
  const stale=fixture();stale.snapshotId='different';
  assert.throws(()=>extendPublishedPriceVintage(snapshot,stale,new Map()),/snapshot_mismatch/);
  const inconsistent=fixture();inconsistent.styles[0].events=[{ticker:'A',tradedTicker:'A',date:'2026-09-21',price:111,side:'sell',basis:'total_return_adjusted_close'}];
  assert.throws(()=>extendPublishedPriceVintage(snapshot,inconsistent,new Map()),/conflicting_price/);
  const invalid=fixture();invalid.styles[0].days[0].positions.get('A').price=0;
  assert.throws(()=>extendPublishedPriceVintage(snapshot,invalid,new Map()),/invalid_price/);
});
test('exchange equivalent marks are resolved from existing audited entitlement, not treated as traded quotes',()=>{
  const s=structuredClone(snapshot);s.styles[0].corporateActions=[{ticker:'OLD',successorTicker:'NEW',effectiveDate:'2026-09-20',considerationType:'stock_and_cash',successorSharesPerShare:2,terminalCashEntitlementPerShare:10}];
  const l=fixture();l.styles[0].days[1].positions=new Map([['OLD',{price:110,basis:'equivalent_source_adjusted_unit'}]]);
  const result=extendPublishedPriceVintage(s,l,new Map([['NEW',new Map([['2026-09-21',50],['2026-09-22',55]])]]));
  assert.equal(result.prices.get('NEW').get('2026-09-21'),50);
  assert.equal(result.prices.get('NEW').get('2026-09-22'),55);
  assert.equal(result.prices.has('OLD'),false);
});
