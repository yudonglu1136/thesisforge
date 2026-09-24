import test from 'node:test';
import assert from 'node:assert/strict';
import { loadInvestorStyleDashboard } from './investorStyleDashboard.js';
import { strategyMetrics } from './strategyLab.js';
import { refreshRuleSnapshot } from './rulePortfolioRefresh.js';

function fixture() {
  const p=loadInvestorStyleDashboard(), dates=['2023-01-03','2023-01-04','2023-01-05','2023-01-06'];
  const maps=new Map([['SPY',new Map(dates.map(d=>[d,100]))]]);
  for(const s of p.styles){
    const first=structuredClone(s.quarters[0]); first.nextExecutionDate=dates[2];first.mature=true;
    const second=structuredClone(first);second.quarter='2023-01-04';second.signalDate=second.quarter;
    second.executionDate=dates[2];second.nextExecutionDate=null;second.mature=false;
    second.positions[0].ticker='TESTNEW';
    s.quarters=[first,second];s.corporateActions=[];
    s.trades=[{date:dates[0],turnover:1,costFraction:.0025}];
    s.metrics={...strategyMetrics(dates.slice(0,3).map(date=>({date,value:.9975}))),observations:3,costBps:25};
    for(const q of s.quarters)for(const holding of q.positions) maps.set(holding.ticker,new Map(dates.map(d=>[d,100])));
  }
  p.backtest={from:dates[0],to:dates[2],observations:3,curve:dates.slice(0,3).map(date=>({date,quality_rank:.9975,ackman:.9975,spy:1}))};
  p.dataThrough=dates[2];return {p,maps,dates};
}
test('observed partial quarter is executed and extended without waiting for next quarter',()=>{
  const {p,maps,dates}=fixture(), r=refreshRuleSnapshot(p,maps,dates[3]);
  assert.equal(r.dataThrough,dates[3]);assert.equal(r.backtest.observations,4);
  r.backtest.curve.slice(0,2).forEach((row,i)=>{
    assert.equal(row.date,p.backtest.curve[i].date);
    for(const id of ['quality_rank','ackman','spy'])assert.ok(Math.abs(row[id]-p.backtest.curve[i][id])<1e-12);
  });
  for(const s of r.styles){
    assert.equal(s.trades.length,2);assert.equal(s.quarters.at(-1).mature,false);
    assert.ok(r.backtest.curve.at(-1)[s.id]<.9975,'new quarter is charged actual turnover');
  }
  assert.equal(p.styles[0].trades.length,1,'input not mutated');
});
test('missing held prices, changed prior prices and unobserved/future end fail closed',()=>{
  const {p,maps,dates}=fixture();
  assert.throws(()=>refreshRuleSnapshot(p,maps,'2023-01-07'),/unobserved_refresh_end/);
  maps.get('TESTNEW').delete(dates[3]);
  assert.throws(()=>refreshRuleSnapshot(p,maps,dates[3]),/refresh_price_or_action_gap/);
  maps.get('TESTNEW').set(dates[3],100);
  maps.get(p.styles[0].quarters[0].positions[0].ticker).set(dates[1],110);
  assert.throws(()=>refreshRuleSnapshot(p,maps,dates[3]),/changed_historical_nav/);
  maps.get('SPY').set('2023-07-03',100);
  assert.throws(()=>refreshRuleSnapshot(p,maps,'2023-07-03'),/new_quarter_selection_required/);
});
