import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {loadInvestorStyleDashboard} from './investorStyleDashboard.js';
import {strategyMetrics} from './strategyLab.js';
import {buildRulePortfolioBundle,validateRulePortfolioBundle} from './rulePortfolioBundleBuild.js';

function fixture(t){
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'rule-bundle-build-'));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const dates=['2026-07-01','2026-07-02','2026-07-03'],ratios=[1,1.01,1.005],dashboards={},prices={};
  for(const universe of ['all','sp500','nasdaq100']){
    const d=loadInvestorStyleDashboard({universe});d.version='investor-style-dashboard-v3';
    d.dataThrough=dates.at(-1);
    d.backtest={from:dates[0],to:dates.at(-1),observations:3,curve:dates.map((date,i)=>({date,spy:ratios[i]}))};
    prices[universe]=new Map([['SPY',new Map(dates.map((date,i)=>[date,100*ratios[i]]))]]);
    for(const style of d.styles){
      delete style.coverage;style.corporateActions=[];
      const q=style.quarters.at(-1);q.nextExecutionDate=null;q.mature=false;style.quarters=[q];
      const invested=q.positions.reduce((n,p)=>n+p.weight,0),cost=invested*.0025;
      style.trades=[{date:dates[0],turnover:invested,costFraction:cost}];
      for(const p of q.positions)prices[universe].set(p.ticker,new Map(dates.map((date,i)=>[date,100*ratios[i]])));
      const curve=dates.map((date,i)=>({date,value:(1-cost)*(q.cashWeight+invested*ratios[i])}));
      style.metrics={...strategyMetrics(curve),observations:3,costBps:25};
      d.backtest.curve.forEach((r,i)=>r[style.id]=curve[i].value);
    }
    dashboards[universe]=d;
  }
  return {output:path.join(root,'bundle'),dashboards,prices,sourceGeneration:'a'.repeat(64),sourceManifestSha256:'b'.repeat(64)};
}
test('atomic bundle is replayable and identical rerun is a no-op',t=>{
  const f=fixture(t),r=buildRulePortfolioBundle(f);
  assert.equal(r.status,'verified');assert.equal(Object.keys(r.universes).length,3);
  assert.equal(loadInvestorStyleDashboard({bundleRoot:f.output,universe:'sp500'}).dataThrough,'2026-07-03');
  const stat=fs.statSync(path.join(f.output,'rule-manifest.json'));
  assert.equal(buildRulePortfolioBundle(f).status,'unchanged');
  assert.equal(fs.statSync(path.join(f.output,'rule-manifest.json')).mtimeMs,stat.mtimeMs);
  fs.chmodSync(path.join(f.output,'sp500.json'),0o644);
  fs.appendFileSync(path.join(f.output,'sp500.json'),' ');
  assert.throws(()=>validateRulePortfolioBundle(f.output),/bundle_snapshot_mismatch/);
});
test('one failed member leaves no partial bundle; missing matrix is rejected',t=>{
  const f=fixture(t);f.prices.sp500.delete(f.dashboards.sp500.styles[0].quarters[0].positions[0].ticker);
  assert.throws(()=>buildRulePortfolioBundle(f));
  assert.equal(fs.existsSync(f.output),false);
  assert.deepEqual(fs.readdirSync(path.dirname(f.output)),[]);
  delete f.dashboards.nasdaq100;
  assert.throws(()=>buildRulePortfolioBundle(f),/matrix_incomplete/);
});
