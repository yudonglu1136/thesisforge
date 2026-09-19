import fs from 'node:fs';
import { InvestmentSource } from '../server/investmentSource.js';
import { earningsResearch } from '../server/investmentEarnings.js';
import { calculateScenario } from '../server/investmentMath.js';

const [file, asOf, out] = process.argv.slice(2);
if (!file || !asOf || !out) throw new Error('Usage: verify-research-guidance-population.mjs <read-only-db> <as-of> <new-report.json>');
if(fs.existsSync(out)) throw new Error('Use a new report file');
const source = new InvestmentSource(file);
const results = [];
try {
  for (const ticker of source.availableTickers()) {
    const start=performance.now();
    try {
      const c=source.company(ticker,asOf), q=earningsResearch(source,ticker,asOf);
      const same=JSON.stringify(c.guidance.evidence)===JSON.stringify(q.selected.guidance);
      if(!same)throw new Error('latest_guidance_surfaces_disagree');
      const result=c.templates?.Base?calculateScenario(c.base,c.templates.Base):null;
      if(c.guidance.evidence.some(e=>e.observedAt>c.snapshot.availableAt))throw new Error('future_guidance');
      if(c.guidance.evidence.some(e=>e.disposition==='research_only'&&(e.amount!==null||e.growthYoy!==null)))throw new Error('research_only_scalar_exposed');
      results.push({ticker,status:'pass',history:c.history.length,quarterCount:q.periods.length,
        supported:!!result,firstGrowth:result?.forecast[0].growth??null,
        guidanceStatus:c.guidance.audit.status,guidanceExcerpts:c.guidance.evidence.length,
        ms:performance.now()-start});
    }catch(e){results.push({ticker,status:'fail',error:e.message});}
  }
} finally {source.close();}
const summary={asOf,tickers:results.length,passed:results.filter(r=>r.status==='pass').length,
  supportedForecasts:results.filter(r=>r.supported).length,
  historicalNodesRead:results.reduce((n,r)=>n+(r.history??0),0),
  failures:results.filter(r=>r.status==='fail')};
fs.writeFileSync(out,JSON.stringify({summary,results},null,2)+'\n',{mode:0o600});
console.log(JSON.stringify(summary,null,2));
if(summary.failures.length)process.exitCode=1;
