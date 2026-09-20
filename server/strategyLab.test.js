import test from 'node:test';
import a from 'node:assert/strict';
import { strategyRules, selectedBook, buildStrategySchedule, valuationDecision, strategyMetrics, applyStrategyCosts, runStrategyLab } from './strategyLab.js';
import { simulateDriftedPortfolio } from './backtestEngine.js';
import { strategyComparisonPrices, strategyEtfs } from './strategyLabSource.js';
import { signature } from './investmentMath.js';

const near=(x,y)=>a.ok(Math.abs(x-y)<1e-9,`${x} != ${y}`);
const dates=Array.from({length:31},(_,i)=>`2026-01-${String(i+1).padStart(2,'0')}`);
const rules=(overrides={})=>strategyRules({managers:['g1'],topN:2,valuationEnabled:true,maxPremium:.3,
  excludedAllocation:'redistribute',cta:'KMLM',ctaWeight:.3,costBps:0,start:dates[1],end:dates.at(-1),asOf:dates.at(-1),...overrides},[{id:'g1'},{id:'g2'}]);
const holding=(ticker,value=100)=>({ticker,priceSymbol:ticker,cusip:'cusip-'+ticker,value,identityResolved:true,issuer:ticker});
function fixture() {
  const priceMaps=new Map(['SPY','A','B','C','KMLM','DBMF'].map(t=>[t,new Map(dates.map((d,i)=>[d,100+(t==='A'?i:t==='B'?-i:t==='KMLM'?i/2:0)]))]));
  const histories=new Map(['g1','g2'].map(g=>[g,[{reportDate:'2025-12-01',publicDate:dates[0],complete:true,accession:g+'-original',holdings:[holding('A',200),holding('B')]}]]));
  const valuations=new Map(['A','B','C'].map(t=>[t,[{date:'2025-12-20',fairValue:100,currency:'USD',version:'synthetic-fixture'}]]));
  const comparisonPrices=new Map(['A','B','C'].map(t=>[t,{currency:'USD',points:new Map(dates.map(d=>[d,100]))}]));
  return {dates,priceMaps,histories,valuations,comparisonPrices,sources:{fixture:true}};
}
test('leverage is additive: preserves all 1x comparisons and changes only the financed result',()=>{
 const d=fixture(),base=runStrategyLab(d,rules()),lev={multiple:1.5,annualRate:.04,reset:'filing'};
 const out=runStrategyLab(d,rules({leverage:lev}));
 a.equal(out.status,'ready');a.equal(base.results.leveraged,undefined);
 for(const k of ['guru','filtered','blend','spy'])a.deepEqual(out.results[k],base.results[k]);
 a.notEqual(out.ruleHash,base.ruleHash);a.ok(out.results.leveraged.financing.interestPaid>0);
 near(out.results.leveraged.equity.at(-1).value,1+1.5*(base.results.blend.equity.at(-1).value-1)-out.results.leveraged.financing.interestPaid);
 const one=runStrategyLab(d,rules({leverage:{...lev,multiple:1}}));a.deepEqual(one,base);
});
test('leverage cannot bypass missing CTA data or the execution gate',()=>{
 const d=fixture(),lev={multiple:2,annualRate:.04,reset:'filing'};d.priceMaps.get('KMLM').delete(dates[5]);
 const out=runStrategyLab(d,rules({leverage:lev}));a.equal(out.status,'blocked');a.equal(out.results.leveraged,undefined);a.equal(out.results.filtered.status,'ready');
});
test('rules validate strict bounds and canonicalize manager identity',()=>{
  a.deepEqual(rules({managers:['g2','g1','g1']}).managers,['g1','g2']);
  for(const v of [{topN:0},{topN:11},{topN:1.5},{managers:[]},{managers:['unknown']},{maxPremium:NaN},{maxPremium:-.1},{cta:'INDEX'},{cta:'none'},{ctaWeight:.9},{ctaWeight:0},{costBps:101},{start:'2026-01-31'},{end:'2026-02-01'},{asOf:'2026-02-30'}])a.throws(()=>rules(v),JSON.stringify(v));
  a.equal(rules({cta:'none',ctaWeight:0,maxPremium:.15,topN:10}).topN,10);
});
test('exact CUSIPs aggregate before Top N; incomplete extracts and amendments fail',()=>{
  const f={holdings:[holding('A',40),holding('B',60),holding('A',40)]};
  a.equal(selectedBook(f,1).holdings[0].ticker,'A');
  a.equal(selectedBook(f,3).error,'insufficient_top_n_extract');
  a.equal(selectedBook({...f,complete:true},3).holdings.length,2);
  a.equal(selectedBook({...f,amendmentUnreviewed:true},1).error,'amendment_requires_reconciliation');
  a.equal(selectedBook({holdings:[holding('A'),{...holding('A'),ticker:'B'}]},1).error,'conflicting_security_identity');
});
test('filings are not executed at their same-day close and future filings cannot leak',()=>{
  const d=fixture();d.histories.get('g1').push({reportDate:dates[9],publicDate:dates[10],complete:true,holdings:[holding('C')]});
  const r=buildStrategySchedule({...d,rules:rules()}).schedule;
  a.deepEqual(r.map(x=>x.executionDate),[dates[1],dates[11]]);
  a.equal(r[1].decisionDate,dates[10]);a.equal(r[0].holdings.length,2);a.equal(r[1].holdings[0].ticker,'C');
  d.histories.get('g1').push({reportDate:'2026-03-01',publicDate:'2026-03-03',complete:true,holdings:[holding('Z')]});
  a.deepEqual(buildStrategySchedule({...d,rules:rules()}).schedule,r);
});
test('reported zero-value rows in full SEC books neither block nor receive allocation',()=>{
 const d=fixture(),baseline=runStrategyLab(d,rules());
 d.histories.get('g1')[0].holdings.push(holding('ZERO',0));
 a.deepEqual(runStrategyLab(d,rules()).results,baseline.results);
 a.equal(selectedBook(d.histories.get('g1')[0],10).holdings.length,2);
 for(const value of [null,undefined,NaN,-1])
  a.equal(selectedBook({complete:true,holdings:[holding('A'),{...holding('BAD'),value}]},1).error,'invalid_selected_book');
 a.equal(selectedBook({complete:true,holdings:[holding('ZERO',0)]},1).error,'insufficient_top_n_extract');
 const conflict={...holding('A',0),ticker:'OTHER'};
 a.equal(selectedBook({complete:true,holdings:[holding('A'),conflict]},1).error,'conflicting_security_identity');
});
test('late older reports never trigger phantom rebalances, costs, filter updates or leverage resets',()=>{
 const d=fixture(),r=rules({costBps:10,leverage:{multiple:1.5,annualRate:.04,reset:'filing'}});
 const before=runStrategyLab(d,r);
 d.histories.get('g1').push({reportDate:'2025-09-30',publicDate:dates[10],accession:'late-old',sourceFailure:'filing_classification_unverified',holdings:[]});
 const after=runStrategyLab(d,r);
 a.deepEqual(after.ledger,before.ledger);a.deepEqual(after.results,before.results);
 // A genuinely new active quarter with identical holdings must still reset.
 d.histories.get('g1').push({...d.histories.get('g1')[0],reportDate:'2025-12-31',publicDate:dates[20],accession:'next-quarter'});
 a.deepEqual(buildStrategySchedule({...d,rules:r}).schedule.map(s=>s.executionDate),[dates[1],dates[21]]);
});
test('an old report and another manager’s current report on the same date only update the current manager',()=>{
 const d=fixture();
 d.histories.get('g1').push({reportDate:'2025-09-30',publicDate:dates[10],complete:true,accession:'old',holdings:[holding('C')]});
 d.histories.get('g2').push({reportDate:'2025-12-31',publicDate:dates[10],complete:true,accession:'new',holdings:[holding('C')]});
 const schedule=buildStrategySchedule({...d,rules:rules({managers:['g1','g2']})}).schedule;
 a.deepEqual(schedule.map(s=>s.executionDate),[dates[1],dates[11]]);
 a.deepEqual(schedule[1].updatedManagers,['g2']);
 a.equal(schedule[1].filings.find(f=>f.guruId==='g1').accession,'g1-original');
});
test('multi-manager overlap merges the same claim and preserves both ranks',()=>{
  const d=fixture();d.histories.get('g2')[0].holdings=[holding('A',200),holding('C')];
  const r=buildStrategySchedule({...d,rules:rules({managers:['g1','g2']})}).schedule[0];
  a.equal(r.holdings.length,3);a.deepEqual(r.holdings[0].managers,['g1','g2']);
  const out=runStrategyLab(d,rules({managers:['g1','g2']}));
  out.ledger[0].holdings.forEach(h=>near(h.originalWeight,1/3));
});
test('same ticker on conflicting share claims cannot collapse',()=>{
  const d=fixture();d.histories.get('g2')[0].holdings=[{...holding('A'),cusip:'other-claim'}];
  a.equal(runStrategyLab(d,rules({managers:['g1','g2']})).failure.code,'conflicting_security_identity');
});
test('missing initial decision day, prior filing and stale filing are explicit failures',()=>{
  const d=fixture();a.equal(buildStrategySchedule({...d,rules:rules({start:dates[0]})}).failure.code,'missing_decision_session');
  d.histories.set('g1',[]);a.equal(runStrategyLab(d,rules()).failure.code,'manager_history_unavailable');
  d.histories.set('g1',[{reportDate:'2020-01-01',publicDate:'2020-02-14',holdings:[holding('A')]}]);
  a.equal(runStrategyLab(d,rules()).failure.code,'stale_manager_filing');
});
test('history boundary reports the actual first stored filing without backfilling or moving the start',()=>{
 const d=fixture(),r=rules();
 d.histories.get('g1')[0].publicDate=dates[10];
 const out=runStrategyLab(d,r);
 a.equal(out.failure.code,'manager_history_unavailable');
 a.equal(out.failure.firstStoredPublicDate,dates[10]);
 a.deepEqual(out.requested,{start:r.start,end:r.end});
 a.equal(out.status,'blocked');
 for(const n of [1,5,10])a.equal(runStrategyLab(d,rules({topN:n})).failure.firstStoredPublicDate,dates[10]);
});
test('PIT valuation uses available node, exact prior close, and comparable currency',()=>{
  const d=fixture(),h=holding('A');
  d.valuations.get('A').push({date:'2026-01-05',fairValue:1000,currency:'USD'});
  a.equal(valuationDecision(h,dates[1],d.valuations,d.comparisonPrices).fairValue,100);
  d.comparisonPrices.get('A').points.delete(dates[1]);a.equal(valuationDecision(h,dates[1],d.valuations,d.comparisonPrices).status,'comparison_price_missing');
  d.comparisonPrices.get('A').currency='GBP';a.equal(valuationDecision(h,dates[1],d.valuations,d.comparisonPrices).status,'currency_unverified');
  a.equal(valuationDecision(h,'2030-01-01',d.valuations,d.comparisonPrices).status,'stale_model');
});
for(const threshold of [.15,.3])test(`premium boundary ${threshold} is strict greater-than, not >=`,()=>{
  const d=fixture();d.comparisonPrices.get('A').points.set(dates[0],100*(1+threshold));
  a.equal(runStrategyLab(d,rules({maxPremium:threshold})).ledger[0].holdings[0].status,'included');
  d.comparisonPrices.get('A').points.set(dates[0],100*(1+threshold)+.01);
  a.equal(runStrategyLab(d,rules({maxPremium:threshold})).ledger[0].holdings[0].status,'expensive');
});
test('expensive slots redistribute to eligible stocks, never backfill lower ranks',()=>{
  const d=fixture();d.comparisonPrices.get('B').points.set(dates[0],140);
  const r=runStrategyLab(d,rules());near(r.ledger[0].holdings[0].targetWeight,.7);near(r.ledger[0].cashWeight,0);
  a.equal(r.ledger[0].holdings.length,2);a.equal(r.ledger[0].holdings[1].targetWeight,0);
  near(runStrategyLab(d,rules({excludedAllocation:'cash'})).ledger[0].cashWeight,.35);
});
test('missing models retain original cash weight even in redistribute mode',()=>{
  const d=fixture();d.valuations.delete('B');const r=runStrategyLab(d,rules());
  near(r.ledger[0].cashWeight,.35);near(r.ledger[0].holdings[0].targetWeight,.35);near(r.summary.minModelCoverage,.5);
});
test('all missing models create explicit cash, not an unavailable or fabricated stock curve',()=>{
  const d=fixture();d.valuations.clear();const r=runStrategyLab(d,rules());
  a.equal(r.status,'ready');near(r.results.filtered.metrics.totalReturn,0);near(r.ledger[0].cashWeight,.7);
  a.equal(r.results.filtered.metrics.sharpeZeroRf,null);
});
test('filter off does not require models and the filtered curve equals the raw curve',()=>{
  const d=fixture();d.valuations.clear();const r=runStrategyLab(d,rules({valuationEnabled:false,cta:'none',ctaWeight:0}));
  a.deepEqual(r.results.filtered,r.results.guru);a.deepEqual(r.results.blend,r.results.guru);a.equal(r.summary.minModelCoverage,null);
});
test('execution gate is before filtering and missing slots never renormalize',()=>{
  const d=fixture();d.histories.get('g1')[0].holdings=Array.from({length:10},(_,i)=>holding('T'+i,100-i));
  for(let i=0;i<9;i++)d.priceMaps.set('T'+i,new Map(dates.map(x=>[x,100])));
  let r=runStrategyLab(d,rules({topN:10,valuationEnabled:false}));a.equal(r.status,'ready');near(r.ledger[0].coverage,.9);near(r.ledger[0].cashWeight,.07);
  d.priceMaps.delete('T8');r=runStrategyLab(d,rules({topN:10}));a.equal(r.failure.code,'execution_coverage_below_90');
});
for(const ctaWeight of [.3,.5])test(`CTA ${ctaWeight} drifts: exact weighted buy-and-hold within interval`,()=>{
  const d=fixture(),r=runStrategyLab(d,rules({ctaWeight}));
  const stock=.5*130/101+.5*70/99,cta=115/100.5;
  near(r.results.blend.equity.at(-1).value,(1-ctaWeight)*stock+ctaWeight*cta);
  near(r.ledger[0].holdings.reduce((s,h)=>s+h.targetWeight,0)+r.ledger[0].ctaWeight+r.ledger[0].cashWeight,1);
});
test('CTA selection changes only blended sleeve; original comparison curves stay fixed',()=>{
  const d=fixture(),a1=runStrategyLab(d,rules()),b=runStrategyLab(d,rules({cta:'DBMF',ctaWeight:.5}));
  a.deepEqual(a1.results.guru,b.results.guru);a.deepEqual(a1.results.filtered,b.results.filtered);
  a.notEqual(a1.results.blend.metrics.totalReturn,b.results.blend.metrics.totalReturn);
});
test('CTA gap and pre-launch window block blend but preserve honest stock comparisons',()=>{
  const d=fixture();d.priceMaps.get('KMLM').delete(dates[5]);const r=runStrategyLab(d,rules());
  a.equal(r.status,'blocked');a.equal(r.results.blend.failure.date,dates[5]);a.equal(r.results.filtered.status,'ready');
  d.priceMaps.get('KMLM').delete(dates[1]);a.equal(runStrategyLab(d,rules()).results.blend.failure.date,dates[1]);
});
test('active price hole is never filled or removed through a date intersection',()=>{
  const d=fixture();d.priceMaps.get('A').delete(dates[6]);const r=runStrategyLab(d,rules());
  a.equal(r.results.guru.failure.code,'missing_active_price');a.equal(r.results.blend.failure.date,dates[6]);
  d.priceMaps.get('SPY').delete(dates[7]);a.equal(runStrategyLab(d,rules()).results.spy.failure.code,'missing_benchmark_price');
});
test('stock conversion transition reports the exact omitted sessions and claims, never a silent shorter curve',()=>{
 const d=fixture();d.actionFor=h=>h.ticker==='A'?{corporateAction:{
  considerationType:'stock',effectiveDate:dates[5],successorFirstTradingDate:dates[7],
  successorTicker:'C',successorSharesPerShare:1.2,actionId:'synthetic-conversion'
 }}:{};
 const out=runStrategyLab(d,rules({valuationEnabled:false,cta:'none',ctaWeight:0}));
 a.equal(out.status,'blocked');a.equal(out.failure.code,'corporate_action_transition_requires_review');
 a.deepEqual(out.failure.missingDates,[dates[5],dates[6]]);
 a.equal(out.failure.date,dates[5]);a.deepEqual(out.failure.tickers,['A']);
 a.equal(out.failure.transitions[0].actions[0].successorTicker,'C');
 a.deepEqual(out.results.blend.equity,[]);a.equal(out.results.spy.status,'ready');
});
test('insufficient history and stale benchmark do not yield headline performance',()=>{
  const d=fixture();a.equal(runStrategyLab(d,rules({start:dates[20]})).failure.code,'insufficient_observations');
  d.dates=dates.slice(0,20);a.equal(runStrategyLab(d,rules()).failure.code,'stale_benchmark');
});
test('entry and both sides of drifted rebalance costs hand reconcile',()=>{
  const gross={quarterContributions:[{contributions:[{ticker:'A',endingWeight:.6},{ticker:'B',endingWeight:.4}]}],equity:[{date:dates[1],value:1},{date:dates[5],value:1.1},{date:dates[10],value:1.2}]};
  const r=applyStrategyCosts(gross,[{executionDate:dates[1],weights:[{ticker:'A',weight:.5},{ticker:'B',weight:.5}]},{executionDate:dates[5],weights:[{ticker:'A',weight:.5},{ticker:'B',weight:.5}]}],10);
  near(r.trades[0].turnover,1);near(r.trades[1].turnover,.2);near(r.equity.at(-1).value,1.2*.999*.9998);
});
test('settled corporate-action cash is not charged a fictional sale',()=>{
  const gross={quarterContributions:[{contributions:[{ticker:'A',endingWeight:1,corporateActionResolution:{considerationType:'cash'}}]}],equity:[{date:dates[1],value:1},{date:dates[5],value:1}]};
  const r=applyStrategyCosts(gross,[{executionDate:dates[1],weights:[{ticker:'A',weight:1}]},{executionDate:dates[5],weights:[]}],10);
  near(r.trades[1].turnover,0);near(r.equity.at(-1).value,.999);
});
test('stock conversion nets successor claim in cost ledger',()=>{
  const gross={quarterContributions:[{contributions:[{ticker:'A',endingWeight:1,corporateActionResolution:{considerationType:'stock',successorTicker:'B'}}]}],equity:[{date:dates[1],value:1},{date:dates[5],value:1}]};
  const r=applyStrategyCosts(gross,[{executionDate:dates[1],weights:[{ticker:'A',weight:1}]},{executionDate:dates[5],weights:[{ticker:'B',weight:1}]}],10);near(r.trades[1].turnover,0);
});
test('metrics independently reconcile calendar CAGR, return and full peak-to-trough loss',()=>{
  const r=strategyMetrics([{date:'2025-01-01',value:.999},{date:'2025-07-01',value:1.2},{date:'2026-01-01',value:.9}]);
  near(r.totalReturn,-.1);near(r.maxDrawdown,-.25);near(r.cagr,.9**(365.25/365)-1);a.ok(r.volatility>0);
});
test('explicit all-cash engine opt-in cannot change existing missing-book fail-closed default',()=>{
  const config={rebalances:[{executionDate:dates[1],weights:[],cashWeight:1,cashReason:'strategy_rules'}],tradingDates:dates.slice(1),endDate:dates.at(-1),priceMaps:fixture().priceMaps};
  a.equal(simulateDriftedPortfolio(config).ok,false);a.equal(simulateDriftedPortfolio({...config,allowExplicitCash:true}).ok,true);
  config.rebalances[0].cashWeight=.8;a.equal(simulateDriftedPortfolio({...config,allowExplicitCash:true}).ok,false);
});
test('outputs deterministic; source maps and normalized rules are never mutated',()=>{
  const d=fixture(),r=rules(),before=signature({histories:[...d.histories],prices:[...d.priceMaps].map(([k,v])=>[k,[...v]]),r});
  a.deepEqual(runStrategyLab(d,r),runStrategyLab(d,r));a.equal(signature({histories:[...d.histories],prices:[...d.priceMaps].map(([k,v])=>[k,[...v]]),r}),before);
});
test('sampled comparison chart is augmented only by actual corroborated close rows',()=>{
  const snap={currency:'USD',priceHistory:[{date:dates[0],close:100,source:'sharadar_fact_os_sep'},{date:dates[2],close:102,source:'sharadar_fact_os_sep'}]};
  const rows=[100,101,102].map((close,i)=>({date:dates[i],close,source:'sharadar_fact_os_sep'}));
  const r=strategyComparisonPrices(snap,rows,dates[2]);a.equal(r.points.get(dates[1]),101);a.equal(r.audits[0].overlaps,2);
  rows[2].close=500;a.equal(strategyComparisonPrices(snap,rows,dates[2]).points.has(dates[1]),false);
  rows.forEach(r=>r.source='unknown');a.equal(strategyComparisonPrices(snap,rows,dates[2]).points.has(dates[1]),false);
  a.equal(strategyComparisonPrices(snap,[],dates[1]).points.has(dates[2]),false);
});
test('ETF source is unavailable when no path is supplied; no automatic synthetic fallback',()=>a.deepEqual(strategyEtfs(''),{}));
