import {createHash} from 'node:crypto';

// Offline only: exact canonical total-return-adjusted marks, never quote-close
// substitution or forward filling. Keep already published benchmark history.
export function attachQqqBenchmark(parent, snapshot, history, sourceGeneration) {
  if(snapshot.universe?.id!=='nasdaq100')return snapshot;
  const result=structuredClone(snapshot),curve=result.backtest.curve;
  const marks=new Map();
  for(const row of history){
    if(!/^\d{4}-\d{2}-\d{2}$/.test(row.date??'')||marks.has(row.date)||!Number.isFinite(row.value)||row.value<=0)
      throw new Error('qqq_benchmark_invalid_mark');
    marks.set(row.date,row.value);
  }
  if(!curve.length||curve.some(r=>!marks.has(r.date)))throw new Error('qqq_benchmark_session_gap');
  const old=parent.backtest.curve;
  const hasPublished=old.some(r=>r.qqq!==undefined);
  if(hasPublished&&old.some(r=>!Number.isFinite(r.qqq)||r.qqq<=0))throw new Error('qqq_benchmark_invalid_parent');
  const published=new Map(hasPublished?old.map(r=>[r.date,r.qqq]):[]);
  const anchor=hasPublished?old.at(-1):curve[0];
  if(!marks.has(anchor.date))throw new Error('qqq_benchmark_anchor_missing');
  const base=marks.get(anchor.date),nav=hasPublished?anchor.qqq:1;
  for(const row of curve)row.qqq=published.get(row.date)??nav*marks.get(row.date)/base;
  result.backtest.qqqBenchmark={id:'qqq',ticker:'QQQ',provider:'Fact OS',
    priceType:'total_return_adjusted_close',currency:'USD',costBps:0,
    sourceGeneration,sourceSha256:createHash('sha256').update(JSON.stringify(history)).digest('hex'),
    historyPolicy:'preserve_published_nav_then_relative_total_return',from:curve[0].date,to:curve.at(-1).date};
  return result;
}
