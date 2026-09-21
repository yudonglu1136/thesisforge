import { assert, finite, calculateScenario, CALC_VERSION } from './investmentMath.js';
import { tickerKey } from './investmentSource.js';

// Immutable revisions keep automatic worksheets separate from explicitly
// confirmed scenarios/decisions. Owner always comes from authenticated identity.
export function worksheetState(store,owner,ticker,asOf) {
  const rows=store.db.prepare(`SELECT * FROM investment_events WHERE owner=? AND ticker=?
    AND kind IN ('valuation_draft','scenario') AND json_extract(payload_json,'$.asOf')<=?
    ORDER BY seq DESC`).all(owner,ticker,asOf);
  // Preserve explicitly named legacy acceptance checks in version history,
  // without mistaking them for a user's intended default forecast.
  const eligible=rows.filter(r=>r.kind==='valuation_draft'||!/^LOCAL QA\s*[—–-]/.test(JSON.parse(r.payload_json).name??''));
  return {activeWorksheet:store.decode(eligible[0]),worksheetIgnoredTestVersions:rows.length-eligible.length,
    worksheetHead:rows.find(r=>JSON.parse(r.payload_json).asOf===asOf)?.id??null};
}

export function saveWorksheet(service,owner,body) {
  const ticker=tickerKey(body.ticker),asOf=service.date(body.asOf);
  return service.store.write(owner,'valuation_draft',ticker,body.operationId,body,()=>{
    const current=worksheetState(service.store,owner,ticker,asOf);
    if(body.expectedHead!==current.worksheetHead)
      throw Object.assign(new Error('worksheet_changed_in_another_session'),{status:409});
    const c=service.source.company(ticker,asOf);
    assert(c.templates,'scenario_method_not_supported');
    assert(body.snapshotId===c.snapshot.id,'actual_base_changed_reload');
    assert(typeof body.name==='string'&&body.name.length<=80,'invalid_scenario_name');
    assert(typeof body.hypothesis==='string'&&body.hypothesis.length<=4000,'invalid_hypothesis');
    const a=body.assumptions;
    const fcfe=a&&a.method==='parent_fcfe'&&a.discountType==='Ke'&&a.ownership==='parent_common'&&a.timing==='year_end';
    const fcff=a&&a.method==='operating_fcff'&&a.discountType==='WACC'&&a.ownership==='enterprise'&&a.timing==='year_end';
    assert(fcfe||fcff,'unsupported_cashflow_basis');
    const allowed=fcfe
      ?['method','discountType','ownership','timing','horizonYears','growth','margin','ke','g']
      :['method','discountType','ownership','timing','horizonYears','growth','ebitMargin','cashTaxRate','dnaMargin','capexMargin','nwcInvestmentMargin','wacc','g','netDebtM','nciM','nonOperatingAssetsM'];
    assert(Object.keys(a).every(k=>allowed.includes(k)),'invalid_worksheet_fields');
    const numeric=v=>v===null||(finite(v)&&Math.abs(v)<=1000);
    const horizon=a.horizonYears??a.growth?.length;
    const paths=fcfe?['growth','margin']:['growth','ebitMargin','cashTaxRate','dnaMargin','capexMargin','nwcInvestmentMargin'];
    const scalars=fcfe?['ke','g']:['wacc','g','netDebtM','nciM','nonOperatingAssetsM'];
    assert((horizon===5||horizon===10)
      &&paths.every(k=>Array.isArray(a[k])&&a[k].length===horizon&&a[k].every(numeric))
      &&scalars.every(k=>numeric(a[k])),'invalid_worksheet_inputs');
    if(body.parentId){const p=service.store.get(owner,body.parentId,'scenario');assert(p.ticker===ticker,'scenario_ticker_mismatch');}
    let result=null,validationError=null;
    try {result=calculateScenario(c.base,a);}catch(e){if(!e.status)throw e;validationError=e.message;}
    // Partial/invalid hypotheses can be remembered, but never produce a fake
    // value or become an actionable scenario. Result is always server-derived.
    return {asOf,name:body.name,hypothesis:body.hypothesis,assumptions:a,
      parentId:body.parentId??null,snapshot:c.snapshot,templateReconciliation:c.templateReconciliation??null,
      result,validationError,calcVersion:result?.calcVersion??CALC_VERSION,ownershipConfirmed:false};
  });
}
