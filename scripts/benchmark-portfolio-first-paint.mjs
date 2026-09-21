#!/usr/bin/env node
import { performance } from 'node:perf_hooks';
import path from 'node:path';
import { InvestmentSource } from '../server/investmentSource.js';
import { buildPortfolioAnalysis } from '../server/investmentPortfolio.js';
import { portfolioValuations } from '../server/portfolioRisk.js';

function argument(name, fallback) {
  const index=process.argv.indexOf(`--${name}`);
  return index>=0?process.argv[index+1]:fallback;
}
function percentile(rows,p) {
  const sorted=[...rows].sort((a,b)=>a-b);
  return sorted[Math.min(sorted.length-1,Math.floor((sorted.length-1)*p))];
}
function timing(rows) {
  return {samples:rows.length,medianMs:percentile(rows,.5),p95Ms:percentile(rows,.95),minMs:Math.min(...rows),maxMs:Math.max(...rows)};
}

const database=path.resolve(argument('database','data/releases/thesisforge-20260920-v3/research.sqlite'));
const strategy=path.resolve(argument('strategy','data/releases/thesisforge-20260920-v3/strategy.sqlite'));
const samples=Math.max(3,Number.parseInt(argument('samples','60'),10)||60);
const asOf=argument('as-of','2026-09-20');
process.env.STRATEGY_DATA_DB_PATH=strategy;

const tickers=['GOOG','NVDA','PLTR','ISRG','AVGO','MSFT','AMZN'];
const positions=tickers.map((ticker,index)=>({ticker,name:ticker,assetCategory:'STK',currency:'USD',
  quantity:10+index,price:100+index*10,localValue:(10+index)*(100+index*10)}));
const reportedNav=positions.reduce((total,row)=>total+row.localValue,0);
const payload={source:{mode:'live',userScoped:true},connection:{status:'linked'},analysisAccounts:[{
  currency:'USD',reportDate:'2026-09-18',reportedNav,positions,
}]};

function isolated(run) {
  const source=new InvestmentSource(database);
  const started=performance.now();
  try {run(source);} finally {source.close();}
  return performance.now()-started;
}

// The old first paint loaded the full market valuation map even when the
// account held only a few securities. This isolates that dominant cold step.
const oldFullUniverse=[];
const optimizedCold=[];
for(let index=0;index<3;index++) {
  oldFullUniverse.push(isolated(source=>portfolioValuations(source,asOf)));
  optimizedCold.push(isolated(source=>buildPortfolioAnalysis(source,payload,asOf,{summary:true})));
}

const warmSource=new InvestmentSource(database);
const warm=[];
try {
  buildPortfolioAnalysis(warmSource,payload,asOf,{summary:true});
  for(let index=0;index<samples;index++) {
    const started=performance.now();
    buildPortfolioAnalysis(warmSource,payload,asOf,{summary:true});
    warm.push(performance.now()-started);
  }
} finally {warmSource.close();}

const before=timing(oldFullUniverse),after=timing(optimizedCold);
const improvementPct=before.medianMs>0?(before.medianMs-after.medianMs)/before.medianMs*100:null;
process.stdout.write(`${JSON.stringify({
  schemaVersion:1,
  benchmark:'portfolio-first-paint',
  generatedAt:new Date().toISOString(),
  inputs:{database,strategy,asOf,tickers,samples},
  before:{scope:'full-universe valuation load on first paint',...before},
  after:{scope:'portfolio-only summary build',...after},
  improvementPct,
  warmSummary:timing(warm),
  limitations:['Local read-only benchmark; not production network latency.','Synthetic holdings contain no private portfolio data.'],
},null,2)}\n`);
