// Read-only, full-population diagnostics. This is not a valuation release gate.
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { pathToFileURL } from 'node:url';
import { sourceNode } from '../server/investmentSource.js';
import { personalScenarioPackage, calculateScenario, finite } from '../server/investmentMath.js';
import { auditGuidanceCoverageRelease } from '../server/guidanceCoverageReleaseAudit.js';
import { inspectStoredGuidanceLineage, inspectStoredIndependentGuidanceAmounts,
  inspectStoredPlusMinusGuidance } from '../server/verifyPitValuationRelease.js';

const histogram = rows => rows.reduce((r, x) => (r[x.code] = (r[x.code] || 0) + 1, r), {});
export function auditResearchForecastGuidance(file, asOf) {
  const db = new DatabaseSync(file, { readOnly: true });
  try {
    db.exec('PRAGMA query_only=ON');
    const metadata = Object.fromEntries(db.prepare('SELECT key,value FROM valuation_pit_source_metadata').all().map(r => [r.key,r.value]));
    const required = db.prepare('SELECT DISTINCT ticker FROM valuation_pit_financials ORDER BY ticker').all().map(r => r.ticker);
    const guidance = auditGuidanceCoverageRelease({
      rows: db.prepare('SELECT * FROM valuation_pit_guidance WHERE observed_at<=? ORDER BY ticker,fiscal_period,observed_at,source_database,source_id').iterate(asOf),
      financialRows: db.prepare('SELECT ticker,available_at,currency,payload_json FROM valuation_pit_financials WHERE available_at<=? ORDER BY ticker,available_at DESC').iterate(asOf),
      modelRuns: db.prepare('SELECT ticker,fiscal_period,as_of_date,input_json FROM valuation_pit_model_runs WHERE as_of_date<=? ORDER BY ticker,fiscal_period,as_of_date').iterate(asOf),
      requiredTickers: required,
      noQuantifiedTickers: JSON.parse(metadata.guidance_no_quantified_tickers || '[]'),
    });
    const { rejectedEventKeys, ...coverage } = guidance;
    const checks = {
      coverage,
      amounts: inspectStoredIndependentGuidanceAmounts(db, rejectedEventKeys),
      plusMinus: inspectStoredPlusMinusGuidance(db, rejectedEventKeys),
      lineage: inspectStoredGuidanceLineage(db, metadata.guidance_extraction_version),
    };
    const current = db.prepare(`WITH ranked AS (SELECT *,ROW_NUMBER() OVER
      (PARTITION BY ticker ORDER BY as_of_date DESC,model_version DESC) n
      FROM valuation_pit_model_runs WHERE as_of_date<=?) SELECT * FROM ranked WHERE n=1 ORDER BY ticker`).all(asOf);
    const forecast = [], failures = [];
    for (const row of current) {
      try {
        const n = sourceNode(row), s = n.score;
        const quote = db.prepare("SELECT json_extract(payload_json,'$.currency') currency FROM valuation_ticker_snapshots WHERE ticker=?").get(row.ticker);
        const currency = n.input.sourceRecord?.currency ?? quote?.currency;
        const base = {...n.actual,currency};
        const p = personalScenarioPackage(base,s,currency === quote?.currency);
        const a = p.templates?.Base;
        const result = a ? calculateScenario(base,a) : null;
        const legacyFirstGrowth = finite(s.valuationRevenue) && base.revenueM>0 ? s.valuationRevenue/base.revenueM-1 : null;
        const collapsedTtmAnchor = s.methodWeights?.['fcfe-dcf']>0 && legacyFirstGrowth===0 && finite(s.revenueGrowth) && s.revenueGrowth!==0;
        const item = {ticker:row.ticker,period:row.fiscal_period,modelDate:row.as_of_date,
          available:!!a,legacyFirstGrowth,collapsedTtmAnchor,normalizedGrowthPct:s.revenueGrowth??null,
          firstGrowth:a?.growth[0]??null,firstRevenueM:result?.forecast[0].revenueM??null,
          firstMargin:a?.margin[0]??null,seed:p.reconciliation?.seedVersion??null,
          basis:p.reconciliation?.basis??null,publishedDcf:s.equityDcf?.fairValue??null,
          scenarioDcf:result?.fairValue??null,guidanceMode:n.guidance?.guidanceSelection?.revenue?.mode??null};
        forecast.push(item);
        if(a && collapsedTtmAnchor && a.growth[0]===0) failures.push({code:'ttm_base_misrepresented_as_zero_growth',ticker:row.ticker});
        if(result && s.methodWeights?.['fcfe-dcf']>0) {
          for(let i=0;i<5;i++) if(Math.abs(result.forecast[i].fcfeM-s.equityDcf.annualCashFlows[i].fcfM)>1e-7*Math.max(1,Math.abs(result.forecast[i].fcfeM)))
            failures.push({code:'published_cashflow_reconciliation_failed',ticker:row.ticker,year:i+1});
        }
      } catch(e) {failures.push({code:'forecast_audit_failed',ticker:row.ticker,error:e.message});}
    }
    return {schemaVersion:1,asOf,generatedAt:new Date().toISOString(),
      scope:'All stored guidance and its model consumption; current research forecasts. Automated original-excerpt checks, not a fresh reread of every source document; not a production release.',
      requiredTickers:required,currentCompanies:current.length,checks,forecast,forecastFailures:failures,
      summary:{guidanceRows:coverage.rawStats?.events,modelRuns:coverage.modelRunsAudited,
        guidanceFailureCounts:histogram(Object.values(checks).flatMap(c=>c.failures)),
        forecastFailureCounts:histogram(failures),legacyCollapsedTtmAnchors:forecast.filter(r=>r.collapsedTtmAnchor).length,
        supportedForecasts:forecast.filter(r=>r.available).length}};
  } finally {db.close();}
}
if (process.argv[1] && import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href) {
  const [file,asOf,out]=process.argv.slice(2);
  if(!file||!/^\d{4}-\d{2}-\d{2}$/.test(asOf)||!out) throw new Error('Usage: audit-research-forecast-guidance.mjs <db> <as-of> <private-report.json>');
  const report=auditResearchForecastGuidance(file,asOf);
  fs.mkdirSync(path.dirname(path.resolve(out)),{recursive:true,mode:0o700});
  fs.writeFileSync(out,JSON.stringify(report,null,2)+'\n',{mode:0o600});
  console.log(JSON.stringify(report.summary,null,2));
}
