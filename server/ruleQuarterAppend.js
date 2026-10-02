import {createHash} from 'node:crypto';
import {qualityRankWeights} from './rulePortfolioWeights.js';
import {validateInvestorStyleDashboard} from './investorStyleDashboard.js';

function nextQuarter(q){const d=new Date(`${q}T00:00:00Z`);return new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+4,0)).toISOString().slice(0,10);}
// The packet is emitted by the existing fixed-rule feature/selection builder,
// not supplied by a browser. New entries cannot edit prior ranks or holdings.
export function appendRuleQuarterSelections(source,packet,{sourceGeneration,tradingDates,end}){
  if(packet?.lineage?.sourceGeneration!==sourceGeneration||packet.lineage?.sourceWrites!==false||
    packet.lineage?.forwardOutcomeColumnsRead!==false||
    (packet.universe?.id??'all')!==(source.universe?.id??'all'))throw new Error('quarter_selection_source_mismatch');
  if(Object.keys(packet.schedules??{}).sort().join(',')!=='ackman,quality_rank')throw new Error('quarter_selection_matrix_incomplete');
  if((packet.actions??[]).some(a=>a.corporateAction?.effectiveDate>source.dataThrough))
    throw new Error('quarter_corporate_action_review_required');
  const result=structuredClone(source),newSymbols={};
  for(const style of result.styles){
    const additions=packet.schedules[style.id];
    if(!Array.isArray(additions))throw new Error('quarter_selection_matrix_incomplete');
    let previous=style.quarters.at(-1);
    for(const input of additions){
      const q=structuredClone(input),expected=nextQuarter(previous.quarter);
      const signal=tradingDates.filter(d=>d<=q.quarter).at(-1),entry=tradingDates.find(d=>d>q.quarter);
      if(q.quarter!==expected||!signal||!entry||q.signalDate!==signal||q.executionDate!==entry||
        entry<=source.dataThrough||entry>end)throw new Error('quarter_selection_clock_invalid');
      if(!Array.isArray(q.positions)||q.positions.length>(style.id==='quality_rank'?10:20))throw new Error('quarter_selection_invalid');
      const allocation=style.id==='quality_rank'?qualityRankWeights(q.positions):{
        positions:q.positions.map(p=>({...p,weight:.05})),cashWeight:1-q.positions.length*.05};
      q.positions=allocation.positions.map(p=>({...p,
        previousTargetWeight:previous.positions.find(r=>r.ticker===p.ticker)?.weight??0,
        action:previous.positions.some(r=>r.ticker===p.ticker)?'rebalance':'new'}));
      q.cashWeight=allocation.cashWeight;q.tickers=q.positions.map(p=>p.ticker);q.selectedCount=q.positions.length;
      q.entered=q.tickers.filter(t=>!previous.positions.some(p=>p.ticker===t));
      q.retained=q.tickers.filter(t=>previous.positions.some(p=>p.ticker===t));
      q.exits=previous.positions.filter(p=>!q.tickers.includes(p.ticker)).map(p=>({ticker:p.ticker,previousTargetWeight:p.weight,weight:0}));
      q.exited=q.exits.map(p=>p.ticker);q.mature=false;q.nextExecutionDate=null;
      previous.nextExecutionDate=q.executionDate;
      for(const p of q.positions)newSymbols[p.ticker]??=q.executionDate;
      style.quarters.push(q);previous=q;
    }
    if(end>nextQuarter(previous.quarter))throw new Error('new_quarter_selection_required');
  }
  result.lineage={...result.lineage,quarterAppend:{method:'existing_rules_append_only_v1',
    packetSha256:createHash('sha256').update(JSON.stringify(packet)).digest('hex'),sourceGeneration}};
  validateInvestorStyleDashboard(result);
  return {snapshot:result,newSymbols};
}
