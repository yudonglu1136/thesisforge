import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { isoDate } from './investmentMath.js';
import { AI_INSIGHTS_METHOD_VERSION, GROWTH_COMPONENTS, QUALITY_COMPONENTS, finite,
  quarterIndex, quarterAt, quarterForDate, selectAiInsightsFacts, companyQuarter,
  scoreCompanies, aggregateQuarter, capexValue, deterministicInsights } from './aiInsightsMetrics.js';

const DEFAULT_ROOT = fileURLToPath(new URL('../data/fact_os/', import.meta.url));
const MAX_ARTIFACT_BYTES = 64 * 1024 * 1024;
const MAX_MODEL_BYTES = 32 * 1024 * 1024;
const digest = input => crypto.createHash('sha256').update(input).digest('hex');
function error(code, status = 422) { return Object.assign(new Error(code), { status }); }
function badRequest(ok, code) { if (!ok) throw error(code); }
function quarterOrNull(q) { return q == null || q === '' ? null : String(q).toUpperCase().replace(/[- /]/g, ''); }
function snapshotToken(artifact, asOf, quarter, window) {
  const raw = JSON.stringify({ g: artifact.generationId, a: asOf, q: quarter, w: window,
    m: AI_INSIGHTS_METHOD_VERSION, u: artifact.universeVersion });
  return `${Buffer.from(raw).toString('base64url')}.${digest(raw).slice(0, 16)}`;
}
function parseSnapshot(token) {
  badRequest(typeof token === 'string' && token.length < 1024 && /^[A-Za-z0-9_-]+\.[a-f0-9]{16}$/.test(token), 'invalid_ai_insights_snapshot');
  const [base, hash] = token.split('.');
  const raw = Buffer.from(base, 'base64url').toString('utf8');
  badRequest(digest(raw).slice(0, 16) === hash, 'invalid_ai_insights_snapshot');
  let parsed;
  try { parsed = JSON.parse(raw); } catch { throw error('invalid_ai_insights_snapshot'); }
  badRequest(parsed.m === AI_INSIGHTS_METHOD_VERSION && typeof parsed.g === 'string'
    && /^[A-Za-z0-9_-]{1,128}$/.test(parsed.g), 'unsupported_ai_insights_snapshot');
  return parsed;
}

function metadata(artifact, context) {
  return { snapshotId: context.snapshotId, asOf: context.asOf, selectedQuarter: context.quarter,
    availableQuarters: context.availableQuarters, context, status: 'ready',
    methodologyVersion: AI_INSIGHTS_METHOD_VERSION, universeVersion: artifact.universeVersion,
    catalogGeneration: artifact.sourceManifestSha256, generatedAt: artifact.generatedAt };
}
function lightMetric(metric) {
  // Contributions are selected-quarter detail. Avoid repeating the full issuer
  // roster three times per chart point in the initial API payload.
  const compact = comparison => ({ current: comparison.current, prior: comparison.prior,
    delta: comparison.delta, growth: comparison.growth, comparable: comparison.comparable,
    priorQuarter: comparison.priorQuarter });
  return { ...metric, yoyComparison: compact(metric.yoyComparison), qoqComparison: compact(metric.qoqComparison) };
}
function rowSummary(row) {
  const { scoreBreakdown, ...summary } = row;
  return summary;
}
function rankedRows(rows, rank) {
  return rows.filter(r => finite(r[`${rank}Score`])).sort((a, b) => b[`${rank}Score`] - a[`${rank}Score`] || a.ticker.localeCompare(b.ticker));
}
function publicEvidence(row) {
  if (!row || row.ambiguous) return [];
  return ['revenue', 'revenueusd', 'gp', 'opinc', 'netinc', 'ncfo', 'capex', 'sbcomp', 'assets'].map(metric => ({
    metric, value: finite(row[metric]) ? row[metric] : null,
    unit: metric === 'revenueusd' ? 'USD' : row.currency ?? 'unknown',
    quarter: row.quarter, reportperiod: row.reportperiod, datekey: row.datekey,
    sourceRevisionId: row.sourceRevisionId ?? null, availabilityPrecision: 'date', source: row.source ?? null,
  }));
}

export function aiInsightsMethodology() {
  return {
    methodologyVersion: AI_INSIGHTS_METHOD_VERSION, percentageScale: 'fraction', currency: 'USD',
    title: { en: 'AI Insights methodology', zh: 'AI Insights 计算口径' },
    periodMapping: 'provider_calendardate_fiscal_alignment', revisionPolicy: 'latest_available_arq_as_of_date',
    pitMode: 'public_date_proxy_reconstruction', universeMode: 'fixed_current_basket',
    capexBasis: 'net_cash_proxy', capexFormula: '-signed_provider_capex',
    weightedGrowth: 'sum(current matched issuers) / sum(prior matched issuers) - 1',
    contribution: '(issuer current - issuer prior) / sum(matched prior)',
    growthScore: GROWTH_COMPONENTS, qualityScore: QUALITY_COMPONENTS,
    composite: [{ metric: 'growthScore', weight: .5 }, { metric: 'qualityScore', weight: .5 }],
    minimumPeerCount: 8, missingScoreInputs: 'unavailable_no_reweighting',
    percentile: 'midrank_in_complete_metric_cohort_within_hardware_or_software',
    qoqSeasonality: 'unadjusted', scorePurpose: 'operating_comparison_not_expected_stock_return',
    limitations: [
      { code: 'company_revenue_proxy', en: 'The revenue series sum covered companies’ total revenue, including non-AI businesses. Supply-chain revenue can overlap and is not added to capital investment.', zh: '收入序列为覆盖公司的集团总收入，含非AI业务。上下游收入可能重叠，不与资本投入相加。' },
      { code: 'capex_proxy', en: 'Capital investment is a net cash-flow proxy; it can include non-AI spending and asset disposals. Unverified provider zeros are unavailable, not zero spending.', zh: '资本投入是净现金流代理，可能包括非AI投入和资产处置。未经核实的供应商零值作为缺失，不视为没有投入。' },
      { code: 'date_proxy_pit', en: 'PIT uses report end and provider disclosure date. Historical source rewrites at the same disclosure date are not guaranteed to reproduce what the platform stored then.', zh: 'PIT按报告期末及供应商披露日期筛选。同一披露日后的供应商历史改写，不保证重现平台当时保存的版本。' },
      { code: 'retrospective_universe', en: 'Historical views use today’s fixed coverage basket and retrospective classifications, not a historical investable universe.', zh: '历史视图使用当前固定覆盖篮子和回溯分类，不代表当时可投资公司池。' },
      { code: 'fiscal_alignment', en: 'Quarters are aligned by provider fiscal-calendar mapping. Actual report ends may differ; QoQ is not seasonally adjusted.', zh: '季度按供应商财季映射对齐，实际报告期末可能不同；QoQ未季调。' },
      { code: 'cash_screening', en: 'Visible net disposal inflows suspend cash-quality scores. Gross asset-sale effects and other cash-classification changes are not comprehensively screened.', zh: '可见净处置流入会暂停现金质量评分；未全面筛查毛额资产出售及其他现金分类变化。' },
      { code: 'fx_proxy', en: 'Reported USD revenue is used directly. Capex and gross-profit growth use the USD/raw revenue ratio as an explicit provider-implied period FX proxy when available.', zh: '收入直接使用供应商美元收入；资本投入与毛利增长在可得时用美元/原币收入比作为明确标注的期间汇率代理。' },
      { code: 'scope_bridges', en: 'Known mergers and spin-offs suspend affected comparable growth and scores until a scope bridge is available. Pre-spin subsidiary revenue is excluded when its parent is in the same aggregate.', zh: '已知并购及拆分影响的可比增长和评分在口径桥接前暂停；同一聚合内已有母公司时，不再加入子公司的拆分前收入。' },
    ],
  };
}

export function createAiInsightsService({ factRoot = process.env.FACT_OS_ROOT || DEFAULT_ROOT, artifactLoader = null, now = () => new Date() } = {}) {
  const root = path.resolve(factRoot), artifacts = new Map(), models = new Map();
  let modelBytes = 0;

  function loadArtifact(generation = null) {
    if (artifactLoader) return artifactLoader(generation);
    let manifest;
    if (!generation) {
      try { manifest = JSON.parse(fs.readFileSync(path.join(root, 'derived/ai-insights/manifest.json'), 'utf8')); }
      catch { throw error('ai_insights_data_not_published', 503); }
      generation = manifest.generationId;
    }
    badRequest(typeof generation === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(generation), 'invalid_ai_insights_generation');
    const cached = artifacts.get(generation);
    if (cached) return cached;
    const expectedPath = path.join(root, 'derived/ai-insights/generations', `${generation}.json`);
    if (!manifest) {
      try { manifest = JSON.parse(fs.readFileSync(path.join(root, 'derived/ai-insights/generations', `${generation}.manifest.json`), 'utf8')); }
      catch { throw error('ai_insights_snapshot_expired', 410); }
    }
    if (manifest.generationId !== generation) throw error('ai_insights_manifest_invalid', 503);
    if (manifest && path.resolve(root, manifest.artifactPath ?? '') !== expectedPath) throw error('ai_insights_manifest_invalid', 503);
    let bytes;
    try {
      if (fs.statSync(expectedPath).size > MAX_ARTIFACT_BYTES) throw error('ai_insights_artifact_too_large', 503);
      bytes = fs.readFileSync(expectedPath);
    } catch (failure) {
      if (failure.status) throw failure;
      throw error('ai_insights_data_not_published', 503);
    }
    if (manifest && digest(bytes) !== manifest.artifactSha256) throw error('ai_insights_artifact_checksum_mismatch', 503);
    let artifact;
    try { artifact = JSON.parse(bytes); } catch { throw error('ai_insights_artifact_invalid', 503); }
    if (artifact.schemaVersion !== 1 || artifact.generationId !== generation || !Array.isArray(artifact.companies)
      || !Array.isArray(artifact.facts)) throw error('ai_insights_artifact_invalid', 503);
    if (artifact.methodologyVersion !== AI_INSIGHTS_METHOD_VERSION) throw error('ai_insights_methodology_mismatch', 503);
    // At most two immutable source generations, plus bounded derived models.
    if (artifacts.size >= 2) artifacts.delete(artifacts.keys().next().value);
    artifacts.set(generation, artifact);
    return artifact;
  }

  function model(query = {}) {
    const pinned = query.snapshotId ? parseSnapshot(query.snapshotId) : null;
    const artifact = loadArtifact(pinned?.g);
    const asOf = isoDate(query.asOf || pinned?.a || now().toISOString().slice(0, 10));
    badRequest(asOf <= now().toISOString().slice(0, 10), 'ai_insights_future_as_of');
    const window = query.window == null || query.window === '' ? pinned?.w ?? 8 : Number(query.window);
    badRequest([8, 12, 20].includes(window), 'invalid_ai_insights_window');
    badRequest(!query.capexBasis || query.capexBasis === 'net_cash_proxy', 'unsupported_ai_insights_capex_basis');
    if (pinned) badRequest(pinned.a === asOf && pinned.w === window && pinned.u === artifact.universeVersion, 'ai_insights_snapshot_context_mismatch');
    const { index, issues } = selectAiInsightsFacts(artifact, asOf);
    const availableQuarters = [...new Set([...index.values()].flatMap(periods => [...periods.keys()]))]
      .filter(q => quarterIndex(q) <= quarterIndex(quarterForDate(asOf))).sort((a, b) => quarterIndex(b) - quarterIndex(a));
    // The newest early filer can already carry the next fiscal alignment
    // quarter. Open on the latest broad cohort, keeping the sparse quarter
    // selectable rather than replacing any company's missing observation.
    const defaultQuarter = availableQuarters.find(q => {
      const big4 = artifact.companies.filter(c => c.group === 'capex' && c.capexGroup === 'big4');
      const big4Complete = big4.length && big4.every(c => finite(capexValue(index.get(c.ticker)?.get(q)).amount));
      return big4Complete && ['hardware', 'software'].every(group => {
        const cohort = artifact.companies.filter(c => c.group === group);
        return cohort.length && cohort.filter(c => finite(index.get(c.ticker)?.get(q)?.revenueusd)).length / cohort.length >= .6;
      });
    }) || availableQuarters[0] || quarterForDate(asOf);
    const quarter = quarterOrNull(query.quarter ?? query.selectedQuarter) || pinned?.q || defaultQuarter;
    badRequest(quarterIndex(quarter) !== null && quarterIndex(quarter) >= 1900 * 4 && quarterIndex(quarter) <= quarterIndex(quarterForDate(asOf)), 'invalid_ai_insights_quarter');
    if (pinned) badRequest(quarter === pinned.q, 'ai_insights_snapshot_context_mismatch');
    const snapshotId = snapshotToken(artifact, asOf, quarter, window);
    if (models.has(snapshotId)) return models.get(snapshotId).value;
    const context = { snapshotId, asOf, quarter, selectedQuarter: quarter, window, availableQuarters,
      methodologyVersion: AI_INSIGHTS_METHOD_VERSION, universeVersion: artifact.universeVersion,
      catalogGeneration: artifact.sourceManifestSha256, generationId: artifact.generationId,
      generatedAt: artifact.generatedAt, basis: 'net_cash_investment_proxy', capexBasis: 'net_cash_proxy',
      periodMapping: 'provider_calendardate_fiscal_alignment', pitMode: 'latest_as_known',
      availabilityPrecision: 'date', universeMode: 'fixed_current_basket',
      revisionPolicy: 'latest_available_arq_as_of_date',
      classificationBasis: 'current_registry_retrospective_not_historical_investable' };
    context.defaultQuarterPolicy = 'latest_big4_complete_and_sixty_percent_revenue_coverage';
    context.latestReportedQuarter = availableQuarters[0] ?? null;
    const byGroup = Object.fromEntries(['capex', 'hardware', 'software'].map(group => [group, artifact.companies.filter(c => c.group === group)]));
    const metricFor = q => ({ quarter: q, capex: aggregateQuarter(byGroup.capex, index, q, 'capex', { asOf }),
      hardware: aggregateQuarter(byGroup.hardware, index, q, 'revenue', { asOf }), software: aggregateQuarter(byGroup.software, index, q, 'revenue', { asOf }) });
    const quarters = Array.from({ length: window }, (_, i) => quarterAt(quarterIndex(quarter) - window + i + 1));
    const points = quarters.map(metricFor), current = points.at(-1);
    const summary = { capex: current.capex, hardware: current.hardware, software: current.software };
    const companies = scoreCompanies(artifact.companies.filter(c => c.group !== 'capex').map(c => companyQuarter(c, index.get(c.ticker), quarter, asOf)));
    const capexComposition = byGroup.capex.map(company => {
      const periods = index.get(company.ticker), fact = periods?.get(quarter), metric = aggregateQuarter([company], index, quarter, 'capex', { asOf });
      const capex = capexValue(fact);
      return { ticker: company.ticker, name: company.name, capexGroup: company.capexGroup, group: company.group,
        subgroup: company.capexGroup, sector: company.sector, amount: metric.amount, yoy: metric.yoy, qoq: metric.qoq,
        reportperiod: fact?.reportperiod ?? null, datekey: fact?.datekey ?? null, status: capex.status,
        conversion: capex.conversion, rawValue: capex.rawValue ?? null, sourceRevisionId: fact?.sourceRevisionId ?? null };
    });
    const sectors = [...new Set(artifact.companies.filter(c => c.group !== 'capex').map(c => c.sector))].map(id => {
      const cohort = artifact.companies.filter(c => c.group !== 'capex' && c.sector === id);
      return { id, label: cohort[0].sectorLabel ?? id, group: cohort[0].group,
        series: quarters.map(q => ({ quarter: q, ...lightMetric(aggregateQuarter(cohort, index, q, 'revenue', { asOf })) })) };
    });
    const base = metadata(artifact, context);
    const overview = { ...base, summary,
      series: points.map(p => ({ quarter: p.quarter, capex: lightMetric(p.capex), hardware: lightMetric(p.hardware), software: lightMetric(p.software) })),
      capexComposition, sectors, companies: companies.map(rowSummary),
      insights: deterministicInsights(summary, companies),
      rankings: Object.fromEntries(['growth', 'quality', 'composite'].map(rank => [rank, rankedRows(companies, rank).slice(0, 8).map(rowSummary)])),
      coverage: Object.fromEntries(Object.entries(summary).map(([key, val]) => [key, val.coverage])),
      methodology: aiInsightsMethodology(), dataIssues: issues,
    };
    if (Object.values(summary).every(m => m.coverage.disclosed === 0)) overview.status = 'empty';
    else if (Object.values(summary).some(m => m.coverage.disclosed < m.coverage.expected)) overview.status = 'partial';
    const result = { artifact, index, context, companies, quarters, overview };
    const byteCount = Buffer.byteLength(JSON.stringify(overview))
      + Buffer.byteLength(JSON.stringify([...index.values()].map(periods => [...periods.values()])))
      + Buffer.byteLength(JSON.stringify(artifact));
    while (models.size >= 6 || modelBytes + byteCount > MAX_MODEL_BYTES) {
      const oldest = models.keys().next().value;
      if (oldest === undefined) break;
      modelBytes -= models.get(oldest).bytes;
      models.delete(oldest);
    }
    models.set(snapshotId, { value: result, bytes: byteCount }); modelBytes += byteCount;
    return result;
  }

  function detail(ticker, query = {}, existing = null) {
    ticker = String(ticker ?? '').toUpperCase();
    const state = existing || model(query), { artifact, index, context, quarters } = state;
    const company = artifact.companies.find(c => c.ticker === ticker);
    if (!company) throw error('ai_insights_company_not_covered', 404);
    const row = state.companies.find(c => c.ticker === ticker) || companyQuarter(company, index.get(ticker), context.quarter, context.asOf);
    const periods = index.get(ticker);
    return { ...metadata(artifact, context), company: row,
      history: quarters.map(q => companyQuarter(company, periods, q, context.asOf)),
      evidence: publicEvidence(periods?.get(context.quarter)),
      comparisonEvidence: Array.from({ length: 8 }, (_, offset) => ({
        quarter: quarterAt(quarterIndex(context.quarter) - offset),
        role: offset === 0 ? 'current' : offset === 1 ? 'qoq_base_and_ttm' : offset === 4 ? 'yoy_base_and_prior_ttm' : 'ttm_component',
        facts: publicEvidence(periods?.get(quarterAt(quarterIndex(context.quarter) - offset))),
      })),
      sourceRefs: [...new Set(Array.from({ length: 8 }, (_, offset) => periods?.get(quarterAt(quarterIndex(context.quarter) - offset))?.sourceRevisionId).filter(Boolean))],
      coverage: { currentDisclosed: !!periods?.get(context.quarter), historyDisclosed: quarters.filter(q => periods?.has(q)).length,
        expectedHistory: quarters.length }, methodology: aiInsightsMethodology() };
  }

  return {
    overview(query = {}) { return model(query).overview; },
    rankings(query = {}) {
      const state = model(query);
      const group = query.universe || query.group || 'all';
      badRequest(['all', 'hardware', 'software'].includes(group), 'invalid_ai_insights_group');
      const rank = query.rank || 'composite';
      badRequest(['growth', 'quality', 'composite'].includes(rank), 'invalid_ai_insights_rank');
      const sortAliases = { revenue_yoy: 'revenueYoY', revenue_qoq: 'revenueQoQ', revenue_delta: 'revenueYoYDelta',
        acceleration: 'yoyAcceleration', revenue: 'revenue', growth: 'growthScore', quality: 'qualityScore', composite: 'compositeScore' };
      const sort = sortAliases[query.sort] || (Object.values(sortAliases).includes(query.sort) ? query.sort : null) || (query.sort ? null : `${rank}Score`);
      badRequest(sort, 'invalid_ai_insights_sort');
      const search = String(query.search ?? '').slice(0, 80).trim().toLowerCase();
      let rows = state.companies.filter(r => (group === 'all' || r.group === group) && (!query.sector || r.sector === query.sector)
        && (!search || `${r.ticker} ${r.name}`.toLowerCase().includes(search)));
      if (query.minRevenue != null && query.minRevenue !== '') {
        badRequest(Number.isFinite(Number(query.minRevenue)) && Number(query.minRevenue) >= 0, 'invalid_min_revenue');
        rows = rows.filter(r => finite(r.revenue) && r.revenue >= Number(query.minRevenue));
      }
      rows.sort((a, b) => (finite(b[sort]) ? b[sort] : -Infinity) - (finite(a[sort]) ? a[sort] : -Infinity) || a.ticker.localeCompare(b.ticker));
      const offset = Number(query.offset ?? 0), limit = Number(query.limit ?? 100);
      badRequest(Number.isInteger(offset) && offset >= 0 && Number.isInteger(limit) && limit > 0 && limit <= 200, 'invalid_ai_insights_pagination');
      return { ...metadata(state.artifact, state.context), rows: rows.slice(offset, offset + limit).map(rowSummary), total: rows.length,
        rank, sort, offset, limit, benchmark: 'fixed_asof_quarter_group_before_display_filters' };
    },
    company: detail,
    compare(query = {}) {
      const tickers = [...new Set(String(query.tickers ?? '').toUpperCase().split(',').map(t => t.trim()).filter(Boolean))];
      badRequest(tickers.length >= 2 && tickers.length <= 4, 'ai_insights_compare_requires_two_to_four');
      const state = model(query);
      return { ...metadata(state.artifact, state.context), companies: tickers.map(ticker => detail(ticker, query, state)) };
    },
    methodology: aiInsightsMethodology,
  };
}
