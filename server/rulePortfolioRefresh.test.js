import test from 'node:test';
import assert from 'node:assert/strict';
import { loadInvestorStyleDashboard } from './investorStyleDashboard.js';
import { strategyMetrics } from './strategyLab.js';
import { refreshRuleSnapshot } from './rulePortfolioRefresh.js';

function fixture() {
  const p=loadInvestorStyleDashboard(), dates=['2023-01-03','2023-01-04','2023-01-05','2023-01-06'];
  const maps=new Map([['SPY',new Map(dates.map(d=>[d,100]))]]);
  p.version='investor-style-dashboard-v3';
  for(const s of p.styles){
    delete s.coverage;
    const first=structuredClone(s.quarters[0]); first.quarter='2022-12-31';first.signalDate=first.quarter;
    first.executionDate=dates[0];first.nextExecutionDate=dates[2];first.mature=true;
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

test('v4 refresh keeps an unpriced gap and independently funds the later segment',()=>{
  const {p,maps,dates}=fixture();
  const end='2023-01-10';
  for(const values of maps.values()) { values.set('2023-01-09',100);values.set(end,100); }
  p.version='investor-style-dashboard-v4';
  p.dataThrough='2023-01-09';
  const observed=[...dates,'2023-01-09'];
  for(const s of p.styles) {
    const second=s.quarters[1];
    second.quarter='2023-01-05';second.signalDate=second.quarter;second.executionDate=dates[3];
    s.quarters[0].nextExecutionDate=dates[3];
    // Each independent period begins with the same verified allocations.
    second.positions=structuredClone(s.quarters[0].positions);
    s.trades=[{date:dates[0],turnover:1,costFraction:.0025}];
    s.coverage={segments:[{from:dates[0],to:p.dataThrough}],gaps:[]};
    if(s.id==='ackman') {
      s.coverage={segments:[{from:dates[0],to:dates[1]},{from:dates[3],to:p.dataThrough}],
        gaps:[{from:dates[2],to:dates[2],reason:'unpriced_right',sourceUrl:'https://www.sec.gov/'}]};
      s.trades.push({date:dates[3],turnover:1,costFraction:.0025});
      s.metrics={totalReturn:null,cagr:null,maxDrawdown:null,volatility:null,sharpeZeroRf:null,observations:4,costBps:25};
    } else s.metrics={...strategyMetrics(observed.map(date=>({date,value:.9975}))),observations:5,costBps:25};
  }
  p.backtest={from:dates[0],to:p.dataThrough,observations:5,
    curve:observed.map(date=>({date,quality_rank:.9975,ackman:date===dates[2]?null:.9975,spy:1}))};
  const r=refreshRuleSnapshot(p,maps,end), a=r.styles[1];
  assert.equal(r.backtest.curve.find(row=>row.date===dates[2]).ackman,null);
  assert.deepEqual(a.coverage.gaps,p.styles[1].coverage.gaps);
  assert.equal(a.coverage.segments[0].to,dates[1]);
  assert.equal(a.coverage.segments[1].to,end);
  assert.equal(a.metrics.totalReturn,null);
  assert.equal(a.metrics.observations,5);
  assert.ok(Math.abs(a.trades[1].turnover-1)<1e-12,'new funding is not a fictional trade across the gap');
  assert.equal(a.quarters[0].mature,false,'a quarter spanning the gap is not complete');
  assert.ok(Math.abs(r.backtest.curve.at(-1).ackman-.9975)<1e-12);
  assert.deepEqual(refreshRuleSnapshot(r,maps,end).backtest,r.backtest,'repeated refresh is deterministic');
});
