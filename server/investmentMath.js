import crypto from 'node:crypto';

export const CALC_VERSION = 'investment-dcf-v2-horizon';
export const LEGACY_CALC_VERSION = 'investment-fcfe-v1';
export const RULE_VERSION = 'investment-rules-v1';
export function assert(ok, code) { if (!ok) throw Object.assign(new Error(code), { status: 422 }); }
export const finite = v => typeof v === 'number' && Number.isFinite(v);
export function canonical(v) {
  if (Array.isArray(v)) return v.map(canonical);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map(k => [k, canonical(v[k])]));
  assert(v !== undefined && (typeof v !== 'number' || finite(v)), 'invalid_serializable_value');
  return v;
}
export const signature = v => crypto.createHash('sha256').update(JSON.stringify(canonical(v))).digest('hex');
export function isoDate(v) {
  assert(typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) && !Number.isNaN(Date.parse(v)) && new Date(v).toISOString().slice(0,10) === v, 'invalid_date');
  return v;
}
export function ratio(a,b) { return finite(a) && finite(b) && b > 0 ? a / b : null; }
export function change(a,b) { const r = ratio(a,b); return r === null ? null : r - 1; }
export function percentile(value, history) {
  const samples = history.filter(finite);
  return finite(value) && samples.length >= 4 ? samples.filter(x => x <= value).length / samples.length : null;
}

const arrayOf = (value, horizon, predicate) =>
  Array.isArray(value) && value.length === horizon && value.every(predicate);

export function validateOperatingScenario(a) {
  assert(a && a.method === 'operating_fcff' && a.discountType === 'WACC', 'fcff_requires_WACC');
  assert(a.timing === 'year_end' && a.ownership === 'enterprise', 'unsupported_cashflow_basis');
  assert(finite(a.wacc) && a.wacc >= .04 && a.wacc <= .30, 'invalid_WACC');
  assert(finite(a.g) && a.g >= 0 && a.g <= .05 && a.wacc - a.g >= .015, 'invalid_terminal_spread');
  const horizon = a.horizonYears ?? a.growth?.length;
  assert(horizon === 5 || horizon === 10, 'invalid_forecast_horizon');
  assert(arrayOf(a.growth, horizon, x => finite(x) && x > -.95 && x <= 2), 'invalid_growth_path');
  assert(arrayOf(a.ebitMargin, horizon, x => finite(x) && x >= -1 && x <= 1), 'invalid_ebit_margin_path');
  assert(arrayOf(a.cashTaxRate, horizon, x => finite(x) && x >= 0 && x <= .6), 'invalid_cash_tax_path');
  assert(arrayOf(a.dnaMargin, horizon, x => finite(x) && x >= 0 && x <= 1), 'invalid_dna_path');
  assert(arrayOf(a.capexMargin, horizon, x => finite(x) && x >= 0 && x <= 2), 'invalid_capex_path');
  assert(arrayOf(a.nwcInvestmentMargin, horizon, x => finite(x) && x >= -1 && x <= 1), 'invalid_nwc_path');
  for (const key of ['netDebtM', 'nciM', 'nonOperatingAssetsM'])
    assert(finite(a[key] ?? 0), `invalid_${key}`);
}

export function calculateOperatingScenario(base, a) {
  validateOperatingScenario(a);
  assert(finite(base.revenueM) && base.revenueM > 0 && finite(base.sharesM) && base.sharesM > 0, 'missing_or_invalid_actual_base');
  let revenue = base.revenueM;
  const forecast = a.growth.map((growth, index) => {
    revenue *= 1 + growth;
    const ebitM = revenue * a.ebitMargin[index];
    // Losses do not create an invented cash-tax benefit. A user who has
    // verified NOL value can express it in non-operating assets explicitly.
    const cashTaxM = Math.max(0, ebitM) * a.cashTaxRate[index];
    const nopatM = ebitM - cashTaxM;
    const dnaM = revenue * a.dnaMargin[index];
    const capexM = revenue * a.capexMargin[index];
    const nwcInvestmentM = revenue * a.nwcInvestmentMargin[index];
    const fcffM = nopatM + dnaM - capexM - nwcInvestmentM;
    const year = index + 1;
    const discountFactor = (1 + a.wacc) ** year;
    return {year, growth, revenueM: revenue, ebitMargin: a.ebitMargin[index], ebitM,
      cashTaxRate: a.cashTaxRate[index], cashTaxM, nopatM, dnaM, capexM,
      nwcInvestmentM, fcffM, discountFactor, pvM: fcffM / discountFactor};
  });
  const explicitPvM = forecast.reduce((sum, row) => sum + row.pvM, 0);
  const terminalCashFlowM = forecast.at(-1).fcffM * (1 + a.g);
  const terminalValueM = terminalCashFlowM / (a.wacc - a.g);
  const terminalPvM = terminalValueM / ((1 + a.wacc) ** forecast.length);
  const enterpriseValueM = explicitPvM + terminalPvM;
  const netDebtM = a.netDebtM ?? 0;
  const nciM = a.nciM ?? 0;
  const nonOperatingAssetsM = a.nonOperatingAssetsM ?? 0;
  const equityValueM = enterpriseValueM - netDebtM - nciM + nonOperatingAssetsM;
  const fairValue = equityValueM / base.sharesM;
  const financingNeedM = forecast.reduce((sum, row) => sum + Math.max(0, -row.fcffM), 0);
  return {calcVersion:'investment-fcff-v1-horizon',method:'operating_fcff',currency:base.currency,
    horizonYears:forecast.length,terminalYear:forecast.length,
    formula:`Revenue → EBIT → cash operating tax → NOPAT + D&A - capex - ΔNWC = FCFF; enterprise value = explicit PV + terminal PV; equity value = enterprise value - net debt - NCI + non-operating assets; per share = equity value / shares`,
    forecast,fairValue,enterpriseValueM,equityValueM,explicitPvM,terminalCashFlowM,
    terminalValueM,terminalPvM,terminalShare:enterpriseValueM===0?null:terminalPvM/enterpriseValueM,
    netDebtM,nciM,nonOperatingAssetsM,financingNeedM,
    negativeExplicitYears:forecast.filter(row=>row.fcffM<0).map(row=>row.year),
    signature:signature({calcVersion:'investment-fcff-v1-horizon',base,assumptions:a})};
}

export function validateScenario(a) {
  if (a?.method === 'operating_fcff') return validateOperatingScenario(a);
  assert(a && a.method === 'parent_fcfe' && a.discountType === 'Ke', 'fcfe_requires_Ke');
  assert(a.timing === 'year_end' && a.ownership === 'parent_common', 'unsupported_cashflow_basis');
  assert(finite(a.ke) && a.ke >= .04 && a.ke <= .30, 'invalid_Ke');
  assert(finite(a.g) && a.g >= 0 && a.g <= .05 && a.ke - a.g >= .015, 'invalid_terminal_spread');
  const horizon=a.horizonYears??a.growth?.length;
  assert(horizon===5||horizon===10,'invalid_forecast_horizon');
  assert(Array.isArray(a.growth) && a.growth.length === horizon && a.growth.every(x => finite(x) && x > -.95 && x <= 2), 'invalid_growth_path');
  // Negative explicit-period FCFE is economically possible. It is preserved
  // and reported as a financing need instead of being clipped to zero.
  assert(Array.isArray(a.margin) && a.margin.length === horizon && a.margin.every(x => finite(x) && x >= -.9 && x <= .9), 'invalid_fcfe_margin_path');
  assert(!('netDebtDeduction' in a) && !('nciDeduction' in a) && !('dividendAddition' in a), 'duplicate_equity_claim_adjustment');
}

// This is an explicit user sandbox, not a replacement for the issuer's released
// blended valuation. Growth/margins are assumptions; revenue and shares are PIT.
export function calculateScenario(base, a) {
  if (a?.method === 'operating_fcff') return calculateOperatingScenario(base, a);
  validateScenario(a);
  assert(finite(base.revenueM) && base.revenueM > 0 && finite(base.sharesM) && base.sharesM > 0, 'missing_or_invalid_actual_base');
  let revenue = base.revenueM;
  const forecast = a.growth.map((growth, i) => {
    revenue *= 1 + growth;
    return { year: i+1, growth, revenueM: revenue, fcfeMargin: a.margin[i], fcfeM: revenue * a.margin[i] };
  });
  const annualCashFlows=forecast.map(x=>({
    year:x.year,valueM:x.fcfeM,discountFactor:(1+a.ke)**x.year,
    presentValueM:x.fcfeM/((1+a.ke)**x.year),
  }));
  const explicitPresentValueM=annualCashFlows.reduce((sum,row)=>sum+row.presentValueM,0);
  const terminalCashFlowM=forecast.at(-1).fcfeM*(1+a.g);
  const terminalValueM=terminalCashFlowM/(a.ke-a.g);
  const terminalPresentValueM=terminalValueM/((1+a.ke)**forecast.length);
  const equityValueM=explicitPresentValueM+terminalPresentValueM;
  const fairValue=equityValueM/base.sharesM;
  const financingNeedM=forecast.reduce((sum,row)=>sum+Math.max(0,-row.fcfeM),0);
  return {
    calcVersion: CALC_VERSION, currency: base.currency,
    horizonYears:forecast.length,terminalYear:forecast.length,
    formula:`FCFE[t] = Revenue[0] × product(1 + growth[1..t]) × margin[t]; PV = sum(FCFE[t]/(1+Ke)^t) + FCFE[${forecast.length}]*(1+g)/(Ke-g)/(1+Ke)^${forecast.length}; per share = PV/shares`,
    forecast:forecast.map((x,i) => ({ ...x, discountFactor: annualCashFlows[i].discountFactor, pvM:annualCashFlows[i].presentValueM })),
    fairValue,equityValueM,
    explicitPvM:explicitPresentValueM,terminalCashFlowM,terminalValueM,
    terminalPvM:terminalPresentValueM,terminalShare:equityValueM===0?null:terminalPresentValueM/equityValueM,
    financingNeedM,negativeExplicitYears:forecast.filter(row=>row.fcfeM<0).map(row=>row.year),
    netDebtDeductedM:0, nciDeductedM:0,
    signature:signature({ calcVersion:CALC_VERSION, base, assumptions:a }),
  };
}

export function reverseScenario(base, a, price, variable = 'growth', targetReturn = a.ke) {
  if (a?.method === 'operating_fcff')
    return reverseOperatingScenario(base, a, price, variable, targetReturn ?? a.wacc);
  assert(finite(price) && price > 0, 'invalid_reverse_price');
  assert(variable === 'growth' || variable === 'terminal_margin', 'invalid_reverse_variable');
  const horizon=a.horizonYears??a.growth.length;
  const runScenario = v => calculateScenario(base, { ...a,horizonYears:horizon,ke:targetReturn,
    ...(variable === 'growth' ? { growth:Array(horizon).fill(v) } : { margin:[...a.margin.slice(0,horizon-1),v] }),
  });
  const run=v=>runScenario(v).fairValue;
  let low = variable === 'growth' ? -.5 : .001;
  let high = variable === 'growth' ? 1 : .9;
  const bounds = [low,high];
  const samples=240,points=[];
  for(let i=0;i<=samples;i++){
    const value=low+(high-low)*i/samples;
    const fairValue=run(value);
    if(finite(fairValue))points.push({value,fairValue,residual:fairValue-price});
  }
  const brackets=[];
  for(let i=1;i<points.length;i++){
    const left=points[i-1],right=points[i];
    if(left.residual===0)brackets.push([left.value,left.value]);
    else if(left.residual*right.residual<0)brackets.push([left.value,right.value]);
  }
  const roots=[];
  for(const bracket of brackets){
    let [aLow,aHigh]=bracket;
    if(aLow!==aHigh)for(let i=0;i<90;i++){
      const mid=(aLow+aHigh)/2;
      if((run(aLow)-price)*(run(mid)-price)<=0)aHigh=mid;else aLow=mid;
    }
    const value=(aLow+aHigh)/2;
    if(!roots.some(root=>Math.abs(root-value)<1e-8))roots.push(value);
  }
  const monotonic=points.slice(1).every((point,index)=>point.fairValue>=points[index].fairValue)
    ||points.slice(1).every((point,index)=>point.fairValue<=points[index].fairValue);
  if(!roots.length)return {status:'outside_bounds',variable,bounds,targetReturn,price,value:null,
    diagnostics:{converged:false,rootCount:0,monotonic,samples,rangeValues:points.length?{low:points[0].fairValue,high:points.at(-1).fairValue}:null}};
  if(roots.length>1)return {status:'multiple_solutions',variable,bounds,targetReturn,price,value:null,
    roots:roots.map(value=>({value,residual:run(value)-price})),diagnostics:{converged:false,rootCount:roots.length,monotonic,samples}};
  const value=roots[0],scenario=runScenario(value),residual=scenario.fairValue-price;
  return { status:'solved', variable, value, targetReturn, price, residual, bounds,scenario,
    diagnostics:{converged:Math.abs(residual)<=Math.max(1e-8,price*1e-9),rootCount:1,monotonic,samples,verifiedForwardValue:scenario.fairValue},
    fixed: variable === 'growth' ? `All ${horizon} FCFE margins, Ke and g fixed; solve one constant annual revenue-growth parameter.` : `Revenue growth and years 1–${horizon-1} margins fixed; solve year ${horizon} and perpetual FCFE margin.` };
}

function solveOneParameter({runScenario, price, variable, bounds, fixed}) {
  const [low,high]=bounds,samples=320,points=[];
  for(let i=0;i<=samples;i++){
    const value=low+(high-low)*i/samples;
    try { const scenario=runScenario(value);points.push({value,fairValue:scenario.fairValue,residual:scenario.fairValue-price,scenario}); }
    catch(error){if(!error.status)throw error;}
  }
  const brackets=[];
  for(let i=1;i<points.length;i++){
    const left=points[i-1],right=points[i];
    if(left.residual===0)brackets.push([left.value,left.value]);
    else if(left.residual*right.residual<0)brackets.push([left.value,right.value]);
  }
  const roots=[];
  for(const bracket of brackets){
    let [aLow,aHigh]=bracket;
    if(aLow!==aHigh)for(let i=0;i<100;i++){
      const mid=(aLow+aHigh)/2;
      if((runScenario(aLow).fairValue-price)*(runScenario(mid).fairValue-price)<=0)aHigh=mid;else aLow=mid;
    }
    const value=(aLow+aHigh)/2;
    if(!roots.some(root=>Math.abs(root-value)<1e-8))roots.push(value);
  }
  const monotonic=points.slice(1).every((point,index)=>point.fairValue>=points[index].fairValue)
    ||points.slice(1).every((point,index)=>point.fairValue<=points[index].fairValue);
  if(!roots.length)return {status:'outside_bounds',variable,bounds,price,value:null,
    diagnostics:{converged:false,rootCount:0,monotonic,samples,rangeValues:points.length?{low:Math.min(...points.map(x=>x.fairValue)),high:Math.max(...points.map(x=>x.fairValue))}:null}};
  if(roots.length>1)return {status:'multiple_solutions',variable,bounds,price,value:null,
    roots:roots.map(value=>({value,residual:runScenario(value).fairValue-price})),diagnostics:{converged:false,rootCount:roots.length,monotonic,samples}};
  const value=roots[0],scenario=runScenario(value),residual=scenario.fairValue-price;
  return {status:'solved',variable,value,price,residual,bounds,scenario,fixed,
    diagnostics:{converged:Math.abs(residual)<=Math.max(1e-8,price*1e-9),rootCount:1,monotonic,samples,verifiedForwardValue:scenario.fairValue}};
}

export function reverseOperatingScenario(base, a, price, variable='growth', targetReturn=a.wacc) {
  assert(finite(price) && price > 0, 'invalid_reverse_price');
  assert(['growth','mature_ebit_margin','reinvestment'].includes(variable), 'invalid_reverse_variable');
  const horizon=a.horizonYears??a.growth.length;
  const runScenario=value=>calculateOperatingScenario(base,{...a,wacc:targetReturn,
    ...(variable==='growth'?{growth:Array(horizon).fill(value)}:{}),
    ...(variable==='mature_ebit_margin'?{ebitMargin:Array.from({length:horizon},(_,i)=>a.ebitMargin[0]+(value-a.ebitMargin[0])*i/(horizon-1))}:{}),
    ...(variable==='reinvestment'?{nwcInvestmentMargin:Array(horizon).fill(value)}:{}),
  });
  const bounds=variable==='growth'?[-.5,1]:variable==='mature_ebit_margin'?[-.5,.8]:[-.5,.8];
  const fixed=variable==='growth'
    ? 'EBIT margin, cash tax, D&A, capex, reinvestment, WACC and terminal growth fixed; solve one constant revenue-growth parameter.'
    : variable==='mature_ebit_margin'
    ? 'Revenue growth and cash conversion fixed; solve one mature EBIT margin with a linear transition from Year 1.'
    : 'Revenue growth, EBIT margin, tax, D&A, capex, WACC and terminal growth fixed; solve one ΔNWC/revenue parameter.';
  return {...solveOneParameter({runScenario,price,variable,bounds,fixed}),targetReturn};
}

export function operatingIsoValueCurve(base,a,price,{growthRange=[-.1,.5],marginRange=[-.1,.5],steps=25}={}) {
  assert(finite(price)&&price>0,'invalid_reverse_price');
  assert(Number.isInteger(steps)&&steps>=5&&steps<=100,'invalid_curve_steps');
  const horizon=a.horizonYears??a.growth.length,points=[];
  for(let i=0;i<=steps;i++){
    const growth=growthRange[0]+(growthRange[1]-growthRange[0])*i/steps;
    const solved=reverseOperatingScenario(base,{...a,growth:Array(horizon).fill(growth)},price,'mature_ebit_margin',a.wacc);
    if(solved.status==='solved'&&solved.value>=marginRange[0]&&solved.value<=marginRange[1])
      points.push({growth,matureEbitMargin:solved.value,residual:solved.residual,verifiedValue:solved.scenario.fairValue});
  }
  return {status:points.length?'calculated':'no_solutions_in_bounds',price,growthRange,marginRange,points,
    note:'Each point is one growth/mature-margin combination that reproduces price; the market price does not identify a unique operating forecast.'};
}
export function sensitivity(base,a) {
  if(a?.method==='operating_fcff')return [-.01,0,.01].flatMap(dw=>[-.005,0,.005].map(dg=>{
    const wacc=a.wacc+dw,g=a.g+dg;
    try{return {wacc,g,fairValue:calculateOperatingScenario(base,{...a,wacc,g}).fairValue};}
    catch{return {wacc,g,fairValue:null};}
  }));
  return [-.01,0,.01].flatMap(dk => [-.005,0,.005].map(dg => {
    const ke=a.ke+dk,g=a.g+dg;
    try { return {ke,g,fairValue:calculateScenario(base,{...a,ke,g}).fairValue}; }
    catch { return {ke,g,fairValue:null}; }
  }));
}
export const FORECAST_SEED_VERSION = 'research-revenue-path-v2';
export function scenarioTemplates(base, dcf, growth) {
  if (dcf?.annualCashFlows?.length !== 5 || !(base.revenueM > 0)) return null;
  let revenue=base.revenueM;
  // Cash-flow growth and the revenue base of an earnings multiple are NOT an
  // annual revenue forecast. In particular, forwardRevenueYears=0 says TTM,
  // not "management expects zero growth next year". Require an explicit path.
  if(!Array.isArray(growth) || growth.length!==5 || !growth.every(finite)) return null;
  const margin=dcf.annualCashFlows.map((r,i) => { revenue*=1+growth[i]; return r.fcfM/revenue; });
  const a={method:'parent_fcfe',discountType:'Ke',ownership:'parent_common',timing:'year_end',ke:dcf.discountRate,g:dcf.terminalGrowth,growth,margin};
  try { validateScenario(a); } catch { return null; }
  return { Base:a, Bear:{...a,ke:Math.min(.3,a.ke+.01),growth:growth.map(x=>Math.max(-.949,x-.05)),margin:margin.map(x=>Math.max(.001,x-.03))},
    Bull:{...a,ke:Math.max(.04,a.g+.015,a.ke-.01),growth:growth.map(x=>Math.min(2,x+.05)),margin:margin.map(x=>Math.min(.9,x+.03))} };
}

// Publishing and private underwriting are separate permissions. An earnings-only
// operating company gets an explicitly labeled analyst starting hypothesis, not
// a new published DCF. Customer cash, financial and NCI routes remain excluded.
export function personalScenarioPackage(base, score, currencyComparable) {
  if (!currencyComparable || !['operating_company','multi_method_growth'].includes(score.modelRoute)
    || !finite(base.revenueM) || base.revenueM <= 0 || !finite(base.sharesM) || base.sharesM <= 0)
    return {templates:null,reconciliation:null};
  if (score.methodWeights?.['fcfe-dcf'] === 0 && score.equityDcf == null) {
    const clamp=(v,lo,hi)=>Math.min(hi,Math.max(lo,v));
    const growthAnchor=finite(score.revenueGrowth)?score.revenueGrowth/100:.05;
    const cycle=finite(score.cycleFcfMargin)&&score.cycleSampleCount>=4&&score.cycleFcfMargin>0;
    const actual=ratio(base.fcfM,base.revenueM);
    const marginAnchor=cycle?score.cycleFcfMargin/100:actual>0?actual:.03;
    const firstGrowth=clamp(growthAnchor,-.5,.5),fcfeMargin=clamp(marginAnchor,.001,.6);
    // Fade the observed growth anchor to 2.5% over five years. Applying a past
    // CFO-capex margin as future parent cash conversion is an analyst assumption
    // (including recovery if current cash flow is negative), never a source fact.
    return {templates:{Base:{method:'parent_fcfe',discountType:'Ke',ownership:'parent_common',timing:'year_end',
      growth:Array.from({length:5},(_,i)=>firstGrowth+(.025-firstGrowth)*i/4),margin:Array(5).fill(fcfeMargin),ke:.10,g:.025}},
    reconciliation:{basis:'user_defined_cashflow_path',standaloneValue:null,publishedDcfValue:null,difference:null,
      seedVersion:'personal-starting-hypothesis-v1',
      startingForecast:{growthAnchor,firstGrowth,finalGrowth:.025,
        growthBasis:finite(score.revenueGrowth)?'stored_pit_normalized_growth':'illustrative_5_percent',
        marginAnchor,fcfeMargin,marginBasis:cycle?'stored_cycle_cfo_minus_capex_margin':actual>0?'reported_ttm_cfo_minus_capex_margin':'illustrative_3_percent',
        sampleCount:cycle?score.cycleSampleCount:null,recoveryAssumed:!(actual>0),
        bounds:{firstGrowth:[-.5,.5],margin:[.001,.6]},notManagementGuidance:true},
      startingRates:{ke:.10,g:.025,basis:'illustrative_editable_defaults_not_issuer_guidance'},
      revenuePath:'Editable analyst seed: normalized PIT growth fades to 2.5% in year five; cash conversion uses a positive historical cycle margin, then positive TTM margin, otherwise an illustrative 3%. Historical CFO minus capex is not verified parent FCFE. No change to the published valuation.'}};
  }
  if (!(score.methodWeights?.['fcfe-dcf'] > 0)) return {templates:null,reconciliation:null};
  const dcf=score.equityDcf;
  const growthAnchor=finite(score.revenueGrowth)?score.revenueGrowth/100
    :finite(dcf?.initialGrowth)?dcf.initialGrowth:null;
  if(growthAnchor===null || !finite(dcf?.terminalGrowth)) return {templates:null,reconciliation:null};
  const firstGrowth=Math.min(.5,Math.max(-.5,growthAnchor));
  const growth=Array.from({length:5},(_,i)=>firstGrowth+(dcf.terminalGrowth-firstGrowth)*i/4);
  const templates=scenarioTemplates(base,dcf,growth);
  if(!templates) return {templates:null,reconciliation:null};
  let raw;
  try {raw=calculateScenario(base,templates.Base);} catch {return {templates:null,reconciliation:null};}
  const published=score.equityDcf.fairValue;
  return {templates,reconciliation:{
    basis:'released_cashflow_path_before_post_dcf_adjustments',
    seedVersion:FORECAST_SEED_VERSION,
    startingForecast:{growthAnchor,firstGrowth,finalGrowth:dcf.terminalGrowth,
      growthBasis:finite(score.revenueGrowth)?score.growthInput?.guidanceWeight>0?'stored_model_growth_with_guidance_component':'stored_pit_normalized_growth':'stored_dcf_growth_assumption',
      sampleCount:score.growthInput?.normalizedSampleCount??null,
      window:score.growthInput?.normalizedWindow??null,
      guidanceWeight:score.growthInput?.guidanceWeight??null,
      marginBasis:'published_cashflow_divided_by_projected_revenue',
      bounds:{firstGrowth:[-.5,.5]},notManagementGuidance:true},
    standaloneValue:raw.fairValue,publishedDcfValue:published??null,
    difference:finite(published)?raw.fairValue-published:null,
    cycleHaircut:finite(score.cycleHaircut)?score.cycleHaircut:null,
    revenuePath:'Editable revenue hypothesis: the stored normalized growth anchor fades to terminal growth over five model years. FCFE margins are back-solved to preserve each released cash flow; they are not independent management margin guidance. TTM valuation bases and fiscal-year or quarterly guidance amounts are not mapped to a rolling forecast year.',
  }};
}

export const MONITOR_METRICS=['revenueGrowth','operatingMargin','fcfMargin','capexIntensity'];
export function validateRules(rules) {
  assert(Array.isArray(rules) && rules.length <= 12, 'invalid_rules');
  for(const r of rules) {
    assert(MONITOR_METRICS.includes(r.metric) && ['lt','gt'].includes(r.operator), 'invalid_rule_metric');
    assert(finite(r.threshold) && r.threshold >= -10 && r.threshold <= 10, 'invalid_rule_threshold');
    assert(Number.isInteger(r.consecutive) && r.consecutive>=1 && r.consecutive<=8, 'invalid_consecutive_periods');
    assert(r.scope === 'new_financial_periods' && ['info','review'].includes(r.severity), 'invalid_rule_scope');
  }
}
export function evaluateRules(rules, history, baselinePeriodEnd, asOf) {
  validateRules(rules); isoDate(asOf);
  const byPeriod=new Map();
  for(const row of [...history].sort((a,b)=>a.availableAt.localeCompare(b.availableAt))) {
    if(row.availableAt<=asOf && row.periodEnd>baselinePeriodEnd && !byPeriod.has(row.periodEnd)) byPeriod.set(row.periodEnd,row);
  }
  const rows=[...byPeriod.values()].sort((a,b)=>a.periodEnd.localeCompare(b.periodEnd));
  return rules.map(rule => {
    const observations=rows.slice(-rule.consecutive);
    const complete=observations.length===rule.consecutive && observations.every(r=>finite(r.metrics[rule.metric]));
    // A missing intervening quarter must not masquerade as consecutive reports.
    const continuous=observations.every((r,i)=>!i || (Date.parse(r.periodEnd)-Date.parse(observations[i-1].periodEnd))/86400000<=120);
    const triggered=complete && continuous && observations.every(r=>rule.operator==='lt' ? r.metrics[rule.metric]<rule.threshold : r.metrics[rule.metric]>rule.threshold);
    return {rule,ruleVersion:RULE_VERSION,status:!complete||!continuous?'insufficient_data':triggered?'review_required':'not_triggered',
      observations:observations.map(r=>({period:r.period,periodEnd:r.periodEnd,availableAt:r.availableAt,value:r.metrics[rule.metric],source:r.source}))};
  });
}

export function compareGuruShares(previous,current,{splitFactor=null}={}) {
  if(!previous || !current || previous.cusip!==current.cusip) return {status:'not_comparable',sharesChange:null};
  if(!finite(splitFactor)||splitFactor<=0) return {status:'corporate_action_unverified',sharesChange:null,reportedPreviousShares:previous.shares,reportedCurrentShares:current.shares};
  const sharesChange=change(current.shares,previous.shares*splitFactor);
  return {status:sharesChange===null?'missing':sharesChange<0?'reported_reduction':sharesChange>0?'reported_increase':'unchanged',sharesChange,
    previousShares:previous.shares, currentShares:current.shares,splitFactor,weightChange:finite(previous.weight)&&finite(current.weight)?current.weight-previous.weight:null};
}
export function overlap(fundamental,shadow) {
  const f=new Map(fundamental.map(x=>[x.ticker,x.weight])); const s=new Map(shadow.map(x=>[x.ticker,x.weight]));
  return [...new Set([...f.keys(),...s.keys()])].sort().map(ticker=>({ticker,fundamentalWeight:f.get(ticker)??0,shadowWeight:s.get(ticker)??0,
    deviation:(f.get(ticker)??0)-(s.get(ticker)??0),kind:f.has(ticker)&&s.has(ticker)?'shared':f.has(ticker)?'user_added':'not_in_fundamental'}));
}

// Integration seam for a separately verified CTA engine. No observations are
// fabricated, aligned by forward-fill, or substituted with company returns.
export function sleeveRisk({equityNav,ctaNav,ctaWeight,annualRiskFree=0}) {
  if(!Array.isArray(ctaNav)||!ctaNav.length)return {status:'cta_not_connected',metrics:null};
  assert(Array.isArray(equityNav)&&equityNav.length>=3,'insufficient_equity_nav');
  assert(finite(ctaWeight)&&ctaWeight>=0&&ctaWeight<=1,'invalid_cta_allocation');
  assert(finite(annualRiskFree)&&annualRiskFree>=0&&annualRiskFree<1,'invalid_risk_free');
  function validate(rows){rows.forEach((r,i)=>{isoDate(r.date);assert(finite(r.nav)&&r.nav>0,'invalid_nav');if(i)assert(r.date>rows[i-1].date,'duplicate_or_unsorted_nav');});}
  validate(equityNav);validate(ctaNav);
  assert(equityNav.length===ctaNav.length&&equityNav.every((r,i)=>r.date===ctaNav[i].date),'unaligned_nav_sessions');
  const e=equityNav.slice(1).map((r,i)=>r.nav/equityNav[i].nav-1),c=ctaNav.slice(1).map((r,i)=>r.nav/ctaNav[i].nav-1);
  const combined=e.map((r,i)=>(1-ctaWeight)*r+ctaWeight*c[i]);
  const mean=v=>v.reduce((a,b)=>a+b,0)/v.length;
  const sd=v=>Math.sqrt(v.reduce((s,x)=>s+(x-mean(v))**2,0)/(v.length-1));
  const stats=r=>{let nav=1,peak=1,dd=0;for(const x of r){nav*=1+x;peak=Math.max(peak,nav);dd=Math.min(dd,nav/peak-1);}const vol=sd(r)*Math.sqrt(252);
    return {totalReturn:nav-1,volatility:vol,maxDrawdown:dd,sharpe:vol>0?(mean(r)*252-annualRiskFree)/vol:null};};
  const covariance=e.reduce((s,x,i)=>s+(x-mean(e))*(c[i]-mean(c)),0)/(e.length-1);
  return {status:'calculated',version:'sleeve-risk-v1',method:'daily_constant_weight_rebalance_gross_of_costs_252_sessions',annualRiskFree,ctaWeight,
    equity:stats(e),cta:stats(c),combined:stats(combined),correlation:sd(e)>0&&sd(c)>0?covariance/(sd(e)*sd(c)):null};
}
