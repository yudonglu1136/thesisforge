import { queryFacts, queryFactsBatch, PRICE_TYPES, factGeneration } from './factRepository.js';
import { assert, finite, isoDate, signature } from './investmentMath.js';
import { tickerKey } from './investmentSource.js';
import { opportunityCompanySummary, opportunityValuationBreakdown } from './investmentOpportunities.js';

export const FUNDAMENTAL_RESEARCH_VERSION = 'fundamental-research-v2';
export const FUNDAMENTAL_METHOD_VERSION = 'fact-os-business-change-2026-09-21';
const LENSES = Object.freeze([
  'growth_profit_sync', 'slowing_growth_margin_up', 'profit_cash_weakening',
  'per_share_dilution', 'capital_return_pending', 'operating_pricing_divergence',
]);
const UNIVERSE_CACHE_MS = 5 * 60 * 1000;
let universeCache = null;
const n = value => finite(value) ? value : null;
const delta = (a, b) => finite(a) && finite(b) ? a - b : null;
const ratio = (a, b) => finite(a) && finite(b) && b !== 0 ? a / b : null;
const growth = (a, b) => finite(a) && finite(b) && b > 0 ? a / b - 1 : null;
const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
const score = (...parts) => parts.filter(finite).reduce((total, value) => total + clamp(value, -4, 4), 0);

function text(en, zh) { return { en, zh }; }
function signedPct(value, digits = 1) {
  return finite(value) ? `${value >= 0 ? '+' : ''}${(value * 100).toFixed(digits)}%` : '—';
}
function pp(value) { return finite(value) ? `${value >= 0 ? '+' : ''}${(value * 100).toFixed(1)}pp` : '—'; }

function economicTemplate(company) {
  const haystack = `${company.sector ?? ''} ${company.industry ?? ''} ${company.sicsector ?? ''} ${company.sicindustry ?? ''}`.toLowerCase();
  if (/insurance|reinsurance/.test(haystack)) return 'insurance';
  if (/bank|savings|credit services|lending/.test(haystack)) return 'banking';
  if (/payment|transaction|credit card/.test(haystack)) return 'payments';
  return 'operating_company';
}

function discoveryComparable(company) {
  const m = company.metrics ?? {};
  if (economicTemplate(company) !== 'operating_company') return false;
  if (!finite(m.ttmRevenue) || Math.abs(m.ttmRevenue) < 100_000_000 || (m.quarterCount ?? 0) < 8) return false;
  const boundedGrowth = [m.revenueGrowth, m.priorRevenueGrowth]
    .filter(finite).every(value => Math.abs(value) <= 3);
  const boundedMargins = [m.operatingMargin, m.operatingMarginPriorQuarter,
    m.operatingMarginPriorYear, m.fcfMargin, m.fcfMarginPriorYear]
    .filter(finite).every(value => Math.abs(value) <= 2);
  return boundedGrowth && boundedMargins;
}

function signalsFor(company) {
  if (!discoveryComparable(company)) return [];
  const m = company.metrics ?? {};
  const revenueDelta = delta(m.revenueGrowth, m.priorRevenueGrowth);
  const marginDelta = delta(m.operatingMargin, m.operatingMarginPriorQuarter);
  const marginYearDelta = delta(m.operatingMargin, m.operatingMarginPriorYear);
  const cashDelta = delta(m.fcfMargin, m.fcfMarginPriorYear);
  const cfoDelta = delta(m.cfoMargin, m.cfoMarginPriorYear);
  const capexDelta = delta(m.capexIntensity, m.capexIntensityPriorYear);
  const perShareLag = delta(m.perShareIncomeGrowth, m.netIncomeGrowth);
  const signals = [];
  const add = (id, priority, summary, question, evidence) => signals.push({ id, priority, summary, question, evidence });

  if (finite(m.revenueGrowth) && m.revenueGrowth > 0 && finite(marginYearDelta) && marginYearDelta >= .005) {
    add('growth_profit_sync', score(m.revenueGrowth / .10, marginYearDelta / .02),
      text(`Revenue grew ${signedPct(m.revenueGrowth)} while TTM operating margin improved ${pp(marginYearDelta)} year over year.`,
        `收入同比增长 ${signedPct(m.revenueGrowth)}，TTM 经营利润率同比改善 ${pp(marginYearDelta)}。`),
      text('Is the margin gain structural, or mainly mix, pricing or temporary cost timing?', '利润率改善来自结构性效率，还是业务组合、定价或费用确认时点？'),
      ['revenueGrowth', 'operatingMargin', 'operatingMarginPriorYear']);
  }
  if (finite(revenueDelta) && revenueDelta <= -.02 && finite(m.revenueGrowth) && m.revenueGrowth > 0 && finite(marginDelta) && marginDelta >= .0025) {
    add('slowing_growth_margin_up', score(Math.abs(revenueDelta) / .04, marginDelta / .01),
      text(`Growth slowed ${pp(revenueDelta)}, but TTM operating margin improved ${pp(marginDelta)} from the prior quarter.`,
        `收入增速放缓 ${pp(revenueDelta)}，但 TTM 经营利润率较上一季度改善 ${pp(marginDelta)}。`),
      text('Can operating leverage persist if growth slows again?', '如果增速继续放缓，经营杠杆还能否持续？'),
      ['revenueGrowth', 'priorRevenueGrowth', 'operatingMargin', 'operatingMarginPriorQuarter']);
  }
  if (finite(marginYearDelta) && marginYearDelta > .005 && ((finite(cashDelta) && cashDelta <= -.01) || (finite(cfoDelta) && cfoDelta <= -.01))) {
    add('profit_cash_weakening', score(marginYearDelta / .02, Math.abs(cashDelta ?? cfoDelta) / .02),
      text(`Operating margin improved ${pp(marginYearDelta)}, while cash conversion weakened ${pp(cashDelta ?? cfoDelta)}.`,
        `经营利润率改善 ${pp(marginYearDelta)}，但现金转化走弱 ${pp(cashDelta ?? cfoDelta)}。`),
      text('Which disclosed working-capital, tax or non-cash items explain the gap?', '哪些已披露的营运资本、税项或非现金项目解释了差异？'),
      ['operatingMargin', 'operatingMarginPriorYear', 'fcfMargin', 'fcfMarginPriorYear']);
  }
  if (finite(m.dilutedSharesGrowth) && m.dilutedSharesGrowth >= .02 && (finite(m.revenueGrowth) && m.revenueGrowth > 0 || finite(m.netIncomeGrowth) && m.netIncomeGrowth > 0)) {
    add('per_share_dilution', score(m.dilutedSharesGrowth / .03, Math.abs(perShareLag ?? 0) / .05),
      text(`Diluted shares increased ${signedPct(m.dilutedSharesGrowth)}; per-share earnings growth lagged total earnings by ${pp(perShareLag)}.`,
        `摊薄股数增加 ${signedPct(m.dilutedSharesGrowth)}；每股利润增速落后利润总额 ${pp(perShareLag)}。`),
      text('Are buybacks offsetting employee issuance, and what does net common financing actually show?', '回购是否抵消了员工股权发行？股票净融资实际说明什么？'),
      ['dilutedSharesGrowth', 'netIncomeGrowth', 'perShareIncomeGrowth', 'netCommonFinancing']);
  }
  if (finite(capexDelta) && capexDelta >= .002 && finite(m.capexIntensityPriorYear) && m.capexIntensity >= m.capexIntensityPriorYear * 1.15 && (!finite(m.preTaxCapitalReturn) || m.preTaxCapitalReturn < .15)) {
    add('capital_return_pending', score(capexDelta / .01, finite(m.preTaxCapitalReturn) ? (.15 - m.preTaxCapitalReturn) / .05 : 1),
      text(`Capital spending intensity rose ${pp(capexDelta)}; the pre-tax capital-return check is ${signedPct(m.preTaxCapitalReturn)}.`,
        `资本开支强度上升 ${pp(capexDelta)}；税前资本回报核验值为 ${signedPct(m.preTaxCapitalReturn)}。`),
      text('What milestone would show that the additional capital is earning an adequate return?', '什么经营里程碑能够证明新增资本开始获得足够回报？'),
      ['capexIntensity', 'capexIntensityPriorYear', 'preTaxCapitalReturn']);
  }
  const priceReturn = n(company.market?.priceReturn);
  if (finite(priceReturn) && finite(marginYearDelta) &&
      (marginYearDelta >= .01 && priceReturn <= -.10 || marginYearDelta <= -.01 && priceReturn >= .10)) {
    add('operating_pricing_divergence', score(Math.abs(marginYearDelta) / .02, Math.abs(priceReturn) / .20),
      text(`TTM operating margin changed ${pp(marginYearDelta)}, while the split-adjusted share price changed ${signedPct(priceReturn)} over the one-year window.`,
        `TTM 经营利润率变动 ${pp(marginYearDelta)}，同期一年拆股调整股价变动 ${signedPct(priceReturn)}。`),
      text('Is price discounting a reversal in the operating change, or missing evidence already visible in the filing?', '价格是在计价经营变化反转，还是忽略了财报中已出现的证据？'),
      ['operatingMargin', 'operatingMarginPriorYear', 'priceReturn']);
  }
  return signals.sort((a, b) => b.priority - a.priority || a.id.localeCompare(b.id));
}

export function analyzeFundamentalUniverse(raw, { lens = 'slowing_growth_margin_up', search = '', limit = 80,
  minRevenueGrowth = null, minOperatingMargin = null, minFcfMargin = null } = {}) {
  assert(raw?.version === 'fact-fundamental-universe-v1', 'invalid_fundamental_fact_payload');
  lens = LENSES.includes(lens) ? lens : LENSES[0];
  search = String(search ?? '').trim().toLowerCase().slice(0, 80);
  limit = clamp(Number.parseInt(limit, 10) || 80, 1, 200);
  const threshold=value=>value==null||value===''?null:finite(Number(value))
    ?clamp(Number(value),-2,3):null;
  minRevenueGrowth=threshold(minRevenueGrowth);
  minOperatingMargin=threshold(minOperatingMargin);
  minFcfMargin=threshold(minFcfMargin);
  const companies = raw.companies.map(company => {
    const template = economicTemplate(company), signals = signalsFor(company);
    return { ...company, economicTemplate: template, signals,
      changes: {
        revenueGrowth: delta(company.metrics?.revenueGrowth, company.metrics?.priorRevenueGrowth),
        operatingMargin: delta(company.metrics?.operatingMargin, company.metrics?.operatingMarginPriorQuarter),
        fcfMargin: delta(company.metrics?.fcfMargin, company.metrics?.fcfMarginPriorYear),
      } };
  });
  let rows = companies.filter(company => !search || `${company.ticker} ${company.name}`.toLowerCase().includes(search));
  if (!search) rows = rows.filter(company => company.signals.some(signal => signal.id === lens));
  rows=rows.filter(company=>{
    const metrics=company.metrics??{};
    return (minRevenueGrowth==null||(finite(metrics.revenueGrowth)&&metrics.revenueGrowth>=minRevenueGrowth))
      &&(minOperatingMargin==null||(finite(metrics.operatingMargin)&&metrics.operatingMargin>=minOperatingMargin))
      &&(minFcfMargin==null||(finite(metrics.fcfMargin)&&metrics.fcfMargin>=minFcfMargin));
  });
  rows = rows.map(company => ({ ...company, primarySignal: company.signals.find(signal => signal.id === lens) ?? company.signals[0] ?? null }))
    .filter(company => search || company.primarySignal)
    .sort((a, b) => (b.primarySignal?.priority ?? -Infinity) - (a.primarySignal?.priority ?? -Infinity) ||
      String(b.available_at).localeCompare(String(a.available_at)) || a.ticker.localeCompare(b.ticker));
  const counts = Object.fromEntries(LENSES.map(id => [id, companies.filter(company => company.signals.some(signal => signal.id === id)).length]));
  return { version: FUNDAMENTAL_RESEARCH_VERSION, methodVersion: FUNDAMENTAL_METHOD_VERSION,
    asOf: raw.as_of, catalogGeneration: raw.catalog_generation, lens, search,
    filters:{minRevenueGrowth,minOperatingMargin,minFcfMargin},
    rows: rows.slice(0, limit), totalMatches: rows.length, counts,
    coverage: { factCompanies: companies.length, withSignals: companies.filter(company => company.signals.length).length,
      latestAvailableAt: companies.map(company => company.available_at).filter(Boolean).sort().at(-1) ?? null },
    rankingBasis: text('Signal magnitude, evidence completeness and filing recency; ticker is only the final tie-break.',
      '按变化幅度、证据完整度和披露新近程度排序；股票代码只用于最终并列排序。'),
    definitions: { reported: 'ARQ latest revision visible by as-of date', ttm: 'sum of four complete reported quarters',
      discoveryGuardrail: 'operating companies with eight comparable quarters, at least 100m reported TTM revenue, |growth|<=300% and |margin|<=200%; all fact companies remain searchable',
      missing: 'null is preserved and never treated as zero', methodVersion: FUNDAMENTAL_METHOD_VERSION } };
}

export async function buildFundamentalDiscovery(asOf, options = {}) {
  isoDate(asOf);
  const raw = await loadFundamentalUniverse(asOf);
  return analyzeFundamentalUniverse(raw, options);
}

export async function fundamentalCompanyIndex(asOf,{search='',limit=120}={}) {
  isoDate(asOf);
  return queryFacts('get_fundamental_company_index', [asOf], { search,limit });
}

async function loadFundamentalUniverse(asOf) {
  const now = Date.now();
  const generation=await factGeneration();
  if (universeCache?.asOf === asOf && universeCache.generation===generation && universeCache.expiresAt > now) return universeCache.raw;
  const raw = await queryFacts('get_fundamental_change_universe', [asOf], { limit: 6000 });
  // Keep exactly one full-universe payload. FactRepository already owns the durable
  // generation-aware cache; this short-lived reference avoids cloning ~13 MB for
  // every lens/search request while preserving bounded memory and refresh cadence.
  universeCache = { asOf, generation, expiresAt: now + UNIVERSE_CACHE_MS, raw };
  return raw;
}

function latestReported(rows) {
  const latest = new Map();
  for (const row of rows ?? []) {
    const existing = latest.get(row.reportperiod);
    if (!existing || String(row.date) > String(existing.date)) latest.set(row.reportperiod, row);
  }
  return [...latest.values()].sort((a, b) => String(b.reportperiod).localeCompare(String(a.reportperiod)));
}

function sumWindow(rows, start, field) {
  const values = rows.slice(start, start + 4).map(row => n(row[field]));
  return values.length === 4 && values.every(finite) ? values.reduce((a, b) => a + b, 0) : null;
}

export function buildFundamentalSeries(quarterly) {
  const rows = latestReported(quarterly);
  return rows.map((row, index) => {
    const revenue = sumWindow(rows, index, 'revenue'), opinc = sumWindow(rows, index, 'opinc');
    const fcf = sumWindow(rows, index, 'fcf'), cfo = sumWindow(rows, index, 'ncfo');
    const yearRevenue = n(rows[index + 4]?.revenue), currentRevenue = n(row.revenue);
    return { periodEnd: row.reportperiod, availableAt: row.date, fiscalPeriod: row.fiscalperiod,
      quarterlyRevenue: currentRevenue, revenueGrowth: growth(currentRevenue, yearRevenue),
      ttmRevenue: revenue, operatingMargin: ratio(opinc, revenue), fcfMargin: ratio(fcf, revenue),
      cfoMargin: ratio(cfo, revenue), source: row.provenance };
  }).filter(row => row.ttmRevenue != null).reverse();
}

function metricRow(id, label, value, comparison, formula, status = null) {
  return { id, label, value: n(value), comparison: n(comparison), formula, status: status ?? (finite(value) ? 'available' : 'missing') };
}

function detailSections(company, metrics, bundle, valuation, peerContext) {
  const template = economicTemplate(company), specialist = template !== 'operating_company';
  return [
    { id: 'growth_profit', title: text('How growth becomes profit', '增长如何变成利润'), rows: [
      metricRow('revenueGrowth', text('Quarterly revenue growth', '单季度收入同比'), metrics.revenueGrowth, metrics.priorRevenueGrowth, 'quarter revenue / same quarter prior year − 1'),
      metricRow('grossMargin', text('TTM gross margin', 'TTM 毛利率'), metrics.grossMargin, metrics.grossMarginPriorQuarter, 'TTM gross profit / TTM revenue'),
      metricRow('operatingMargin', text('TTM operating margin', 'TTM 经营利润率'), metrics.operatingMargin, metrics.operatingMarginPriorQuarter, 'TTM operating income / TTM revenue'),
    ]},
    { id: 'profit_cash', title: text('How profit becomes cash', '利润如何变成现金'), rows: [
      metricRow('cfoMargin', text('TTM CFO margin', 'TTM 经营现金流率'), metrics.cfoMargin, metrics.cfoMarginPriorYear, 'TTM operating cash flow / TTM revenue'),
      metricRow('fcfMargin', text('TTM FCF margin', 'TTM 自由现金流率'), metrics.fcfMargin, metrics.fcfMarginPriorYear, 'TTM reported FCF / TTM revenue'),
      metricRow('sbcMargin', text('TTM SBC / revenue', 'TTM 股权激励 / 收入'), metrics.sbcMargin, null, 'TTM stock-based compensation / TTM revenue'),
      metricRow('workingCapital', text('Working-capital balance', '营运资本余额'), bundle.quarterly?.[0]?.workingcapital, null, 'reported balance; not presented as a cash-flow contribution'),
    ]},
    { id: 'per_share', title: text('What shareholders receive per share', '股东每股得到什么'), rows: [
      metricRow('netIncomeGrowth', text('TTM common net-income growth', 'TTM 普通股净利润增长'), metrics.netIncomeGrowth, null, 'current TTM / prior-year TTM − 1'),
      metricRow('perShareIncomeGrowth', text('TTM income per diluted share growth', 'TTM 摊薄每股利润增长'), metrics.perShareIncomeGrowth, null, '(TTM common income / diluted shares) growth'),
      metricRow('dilutedSharesGrowth', text('Diluted share-count growth', '摊薄股数增长'), metrics.dilutedSharesGrowth, null, 'latest diluted shares / year-ago diluted shares − 1'),
      metricRow('netCommonFinancing', text('Net common-stock financing', '普通股净融资'), metrics.netCommonFinancing, null, 'reported net cash from common issuance and repurchase; not gross buybacks'),
      metricRow('dividends', text('Last-12-month split-adjusted dividends', '近 12 个月拆股调整后股息'), bundle.recentDividends?.reduce((sum, row) => sum + (n(row.value) ?? 0), 0), null, 'sum of observed ex-date USD/share actions in the trailing 365 days; payment date unavailable', bundle.recentDividends?.length ? 'available' : 'not_observed'),
    ]},
    { id: 'capital', title: text('How much capital growth consumes', '增长消耗多少资本'), rows: [
      metricRow('capexIntensity', text('TTM capex intensity', 'TTM 资本开支强度'), metrics.capexIntensity, metrics.capexIntensityPriorYear, 'absolute TTM capex / TTM revenue'),
      metricRow('preTaxCapitalReturn', text('Pre-tax capital return check', '税前资本回报核验'), metrics.preTaxCapitalReturn, null, 'TTM EBIT / average reported invested capital'),
      metricRow('debt', text('Reported debt', '披露债务'), metrics.debt, null, 'latest reported debt balance'),
      metricRow('interestCoverage', text('Pre-tax interest coverage', '税前利息保障倍数'), metrics.interestCoverage, null, 'TTM EBIT / absolute TTM interest expense'),
    ]},
    { id: 'pricing', title: text('What the current price requires', '当前价格隐含怎样的经营要求'), rows: [
      metricRow('marketPrice', text('Latest split-adjusted close', '最新拆股调整收盘价'), bundle.price?.value, null, 'Sharadar split-adjusted close as of requested cutoff', bundle.price ? 'available' : 'missing'),
      metricRow('modelGap', text('Optional valuation-model gap', '可选估值模型差距'), valuation?.modelGap, null, 'model value / comparable market price − 1', valuation?.valuationStatus ?? 'not_modeled'),
    ], note: specialist ? text('Specialist financial metrics are not available in the current Fact OS schema; generic operating ratios are not treated as decision-grade for this business model.', '当前 Fact OS 尚无该类金融企业的专用指标；通用经营比率不会被视作可直接决策的证据。') : null },
    { id: 'history_peers', title: text('Relative to its history and economic peers', '相对自身历史与经济同业'), rows: [
      metricRow('peerRevenueGrowthPercentile', text('Revenue-growth peer percentile', '收入增长同业分位'), peerContext?.revenueGrowthPercentile, null, 'percentile within the same economic template and reviewed industry/sector candidate set', peerContext?.status ?? 'missing'),
      metricRow('peerOperatingMarginPercentile', text('Operating-margin peer percentile', '经营利润率同业分位'), peerContext?.operatingMarginPercentile, null, 'percentile within the same economic template and reviewed industry/sector candidate set', peerContext?.status ?? 'missing'),
      metricRow('peerFcfMarginPercentile', text('FCF-margin peer percentile', 'FCF 利润率同业分位'), peerContext?.fcfMarginPercentile, null, 'percentile within the same economic template and reviewed industry/sector candidate set', peerContext?.status ?? 'missing'),
    ], note: text(`Candidate peer set: ${peerContext?.count ?? 0}. Economic-model classification is applied before vendor industry labels; the set remains a research aid, not a mechanically approved peer group.`, `候选同业：${peerContext?.count ?? 0} 家。先按经济模式分类，再参考供应商行业标签；该集合只是研究辅助，并非机械确认的同业组。`) },
  ];
}

function percentile(values, selected) {
  const usable = values.filter(finite).sort((a, b) => a - b);
  if (!finite(selected) || usable.length < 5) return null;
  const below = usable.filter(value => value < selected).length;
  const equal = usable.filter(value => value === selected).length;
  return (below + equal * .5) / usable.length;
}

function buildPeerContext(company, raw) {
  const template = economicTemplate(company);
  const all = (raw?.companies ?? []).filter(row => row.ticker !== company.ticker && economicTemplate(row) === template);
  const industry = String(company.industry ?? '').trim().toLowerCase();
  const sector = String(company.sector ?? '').trim().toLowerCase();
  let peers = all.filter(row => industry && String(row.industry ?? '').trim().toLowerCase() === industry);
  if (peers.length < 5) peers = all.filter(row => sector && String(row.sector ?? '').trim().toLowerCase() === sector);
  if (peers.length < 5) peers = all;
  const metric = key => peers.map(row => row.metrics?.[key]);
  const own = company.metrics ?? {};
  return {
    status: peers.length >= 5 ? 'available' : 'insufficient_peer_count',
    count: peers.length,
    basis: 'economic_template_then_industry_or_sector_review_candidate',
    revenueGrowthPercentile: percentile(metric('revenueGrowth'), own.revenueGrowth),
    operatingMarginPercentile: percentile(metric('operatingMargin'), own.operatingMargin),
    fcfMarginPercentile: percentile(metric('fcfMargin'), own.fcfMargin),
  };
}

function addPricingSignal(signals, metrics, priceHistory) {
  if (!Array.isArray(priceHistory) || priceHistory.length < 2) return signals;
  const start = priceHistory[0]?.value, end = priceHistory.at(-1)?.value;
  const priceReturn = growth(end, start), fundamentalDelta = delta(metrics.operatingMargin, metrics.operatingMarginPriorYear);
  if (finite(priceReturn) && finite(fundamentalDelta) && fundamentalDelta >= .01 && priceReturn <= -.10) {
    return [...signals, { id: 'operating_pricing_divergence', priority: score(fundamentalDelta / .02, Math.abs(priceReturn) / .20),
      summary: text(`TTM operating margin improved ${pp(fundamentalDelta)}, while the split-adjusted share price changed ${signedPct(priceReturn)} over the comparison window.`, `TTM 经营利润率改善 ${pp(fundamentalDelta)}，同期拆股调整股价变动 ${signedPct(priceReturn)}。`),
      question: text('Is the market discounting a reversal, or overlooking durable operating improvement?', '市场是在计价改善反转，还是忽视了可持续的经营改善？'),
      evidence: ['operatingMargin', 'operatingMarginPriorYear', 'priceReturn'] }];
  }
  return signals;
}

function importantEvidence(company, signals) {
  const m = company.metrics ?? {};
  const candidates = [...signals];
  const add = (id, value, summary, evidence) => {
    if (finite(value) && !candidates.some(item => item.id === id))
      candidates.push({ id, priority: Math.abs(value), summary, question: text('What disclosed driver best explains this change?', '哪项已披露驱动最能解释这一变化？'), evidence });
  };
  add('revenue_growth_evidence', m.revenueGrowth,
    text(`Quarterly revenue changed ${signedPct(m.revenueGrowth)} year over year.`, `单季度收入同比变动 ${signedPct(m.revenueGrowth)}。`), ['revenueGrowth']);
  const operatingDelta = delta(m.operatingMargin, m.operatingMarginPriorYear);
  add('operating_margin_evidence', operatingDelta,
    text(`TTM operating margin changed ${pp(operatingDelta)} year over year.`, `TTM 经营利润率同比变动 ${pp(operatingDelta)}。`), ['operatingMargin', 'operatingMarginPriorYear']);
  const cashDelta = delta(m.fcfMargin, m.fcfMarginPriorYear);
  add('fcf_margin_evidence', cashDelta,
    text(`TTM FCF margin changed ${pp(cashDelta)} year over year.`, `TTM FCF 利润率同比变动 ${pp(cashDelta)}。`), ['fcfMargin', 'fcfMarginPriorYear']);
  add('share_count_evidence', m.dilutedSharesGrowth,
    text(`Diluted share count changed ${signedPct(m.dilutedSharesGrowth)} year over year.`, `摊薄股数同比变动 ${signedPct(m.dilutedSharesGrowth)}。`), ['dilutedSharesGrowth']);
  return candidates.slice(0, 3);
}

function startDate(asOf, days) {
  const date = new Date(`${asOf}T00:00:00Z`); date.setUTCDate(date.getUTCDate() - days); return date.toISOString().slice(0, 10);
}

export async function buildFundamentalCompany(source, ticker, asOf, options = {}) {
  ticker = tickerKey(ticker); isoDate(asOf);
  const requests = [
    { method: 'get_fundamental_research', args: [ticker, asOf], kwargs: { quarters: 16, years: 8 } },
    { method: 'get_price_history', args: [ticker, startDate(asOf, 400), asOf, PRICE_TYPES.SPLIT_ADJUSTED_CLOSE] },
    { method: 'get_price', args: [ticker, asOf, PRICE_TYPES.SPLIT_ADJUSTED_CLOSE] },
    { method: 'get_dividends', args: [ticker, startDate(asOf, 3650), asOf] },
  ];
  const responses = await queryFactsBatch(requests);
  if (!responses[0]?.ok) throw Object.assign(new Error('fundamental_facts_unavailable'), { status: 422 });
  const bundle = responses[0].result;
  bundle.priceHistory = responses[1]?.ok ? responses[1].result : [];
  bundle.price = responses[2]?.ok ? responses[2].result : null;
  bundle.dividends = responses[3]?.ok ? responses[3].result : [];
  bundle.recentDividends = bundle.dividends.filter(row => String(row.date ?? row.exDate ?? '') >= startDate(asOf, 365));
  const series = buildFundamentalSeries(bundle.quarterly);
  const latest = bundle.quarterly?.[0];
  const rawCompany = { ticker, ...bundle.company, period_end: latest?.reportperiod, available_at: latest?.date,
    metrics: FactMetricsForDetail(bundle.quarterly) };
  let signals = signalsFor(rawCompany);
  if (discoveryComparable(rawCompany)) {
    signals = addPricingSignal(signals, rawCompany.metrics, bundle.priceHistory);
  }
  let valuation = null;
  try {
    valuation = opportunityCompanySummary(source, ticker, asOf);
    valuation.breakdown=opportunityValuationBreakdown(source,ticker,asOf);
  } catch { valuation = { valuationStatus: 'not_modeled', modelGap: null, breakdown:null }; }
  let peerContext = { status: 'unavailable', count: 0 };
  try { peerContext = buildPeerContext(rawCompany, await loadFundamentalUniverse(asOf)); } catch { /* peer context is an optional comparison layer */ }
  const focused = LENSES.includes(options.lens) ? signals.find(signal => signal.id === options.lens) : null;
  const primary = focused ?? signals[0] ?? { id: 'insufficient_comparable_history', priority: 0,
    summary: text('The latest reported facts are available, but comparable evidence is incomplete.', '最新披露事实可用，但可比证据尚不完整。'),
    question: text('Which missing period or specialist KPI is required before drawing a conclusion?', '在形成结论前，还缺哪个期间或专用业务指标？'), evidence: [] };
  const counter = counterEvidence(rawCompany.metrics, bundle);
  return { version: FUNDAMENTAL_RESEARCH_VERSION, methodVersion: FUNDAMENTAL_METHOD_VERSION,
    ticker, asOf, company: rawCompany, identity: bundle.identity, reportedBasis: bundle.reported_basis,
    restatedBasis: bundle.restated_basis, economicTemplate: economicTemplate(rawCompany),
    judgment: primary, importantChanges: importantEvidence(rawCompany,
      [primary, ...signals.filter(signal => signal.id !== primary.id)]), counterEvidence: counter,
    trend: series, sections: detailSections(rawCompany, rawCompany.metrics, bundle, valuation, peerContext),
    peerContext,
    valuation, price: bundle.price, priceHistory: bundle.priceHistory,
    dividends: bundle.dividends, quarterly: bundle.quarterly.slice(0, 8), annual: bundle.annual,
    sources: bundle.quarterly.slice(0, 8).map(row => ({ periodEnd: row.reportperiod, availableAt: row.date,
      fiscalPeriod: row.fiscalperiod, provenance: row.provenance })),
    researchGaps: researchGaps(rawCompany, bundle), catalogGeneration: bundle.catalog_generation };
}

export function FactMetricsForDetail(quarterly) {
  const rows = latestReported(quarterly);
  const q = rank => rows[rank - 1] ?? {};
  const sum = (start, field) => sumWindow(rows, start - 1, field);
  const current = Object.fromEntries(['revenue','gp','opinc','ebit','netinccmn','ncfo','capex','fcf','sbcomp','ncfcommon','ncfdiv','intexp'].map(field => [field, sum(1, field)]));
  const priorQ = Object.fromEntries(Object.keys(current).map(field => [field, sum(2, field)]));
  const priorY = Object.fromEntries(Object.keys(current).map(field => [field, sum(5, field)]));
  const shares = n(q(1).shareswadil) ?? n(q(1).sharesbas), oldShares = n(q(5).shareswadil) ?? n(q(5).sharesbas);
  const avgCapital = finite(q(1).invcap) && finite(q(5).invcap) ? (q(1).invcap + q(5).invcap) / 2 : null;
  return { quarterCount: rows.length,
    annualComparisonReady: Boolean(rows[0] && rows[4]),
    sequentialComparisonReady: Boolean(rows[0] && rows[1]),
    priorSequentialYearReady: Boolean(rows[1] && rows[5]),
    revenueGrowth: growth(q(1).revenue, q(5).revenue), priorRevenueGrowth: growth(q(2).revenue, q(6).revenue),
    ttmRevenue: current.revenue, grossMargin: ratio(current.gp, current.revenue), grossMarginPriorQuarter: ratio(priorQ.gp, priorQ.revenue),
    operatingMargin: ratio(current.opinc, current.revenue), operatingMarginPriorQuarter: ratio(priorQ.opinc, priorQ.revenue), operatingMarginPriorYear: ratio(priorY.opinc, priorY.revenue),
    cfoMargin: ratio(current.ncfo, current.revenue), cfoMarginPriorYear: ratio(priorY.ncfo, priorY.revenue),
    fcfMargin: ratio(current.fcf, current.revenue), fcfMarginPriorYear: ratio(priorY.fcf, priorY.revenue), sbcMargin: ratio(current.sbcomp, current.revenue),
    capexIntensity: ratio(finite(current.capex) ? Math.abs(current.capex) : null, current.revenue), capexIntensityPriorYear: ratio(finite(priorY.capex) ? Math.abs(priorY.capex) : null, priorY.revenue),
    dilutedSharesGrowth: growth(shares, oldShares), netIncomeGrowth: growth(current.netinccmn, priorY.netinccmn),
    perShareIncomeGrowth: growth(ratio(current.netinccmn, shares), ratio(priorY.netinccmn, oldShares)),
    netCommonFinancing: current.ncfcommon, netDividendCashFlow: current.ncfdiv,
    preTaxCapitalReturn: ratio(current.ebit, avgCapital), debt: n(q(1).debt), cash: n(q(1).cashneq),
    interestCoverage: ratio(current.ebit, finite(current.intexp) ? Math.abs(current.intexp) : null),
    ttmOperatingIncome: current.opinc, ttmCfo: current.ncfo, ttmFcf: current.fcf, ttmSbc: current.sbcomp };
}

function counterEvidence(metrics, bundle) {
  if (finite(metrics.netIncomeGrowth) && metrics.netIncomeGrowth < -.10) return { severity: 'warning',
    statement: text(`TTM common net income declined ${signedPct(metrics.netIncomeGrowth)} despite the operating signal.`, `尽管存在经营改善信号，TTM 普通股净利润仍下降 ${signedPct(metrics.netIncomeGrowth)}。`), sourceMetric: 'netIncomeGrowth' };
  if (finite(metrics.sbcMargin) && metrics.sbcMargin > .10) return { severity: 'warning',
    statement: text(`Stock-based compensation equals ${signedPct(metrics.sbcMargin)} of TTM revenue.`, `股权激励相当于 TTM 收入的 ${signedPct(metrics.sbcMargin)}。`), sourceMetric: 'sbcMargin' };
  return { severity: 'gap', statement: text('Fact OS does not cover company-specific operating KPIs or explain causality; the filing must be checked before attributing the change.', 'Fact OS 不覆盖公司专用经营 KPI，也不能解释因果；归因前必须核对财报原文。'), sourceMetric: null,
    sourceAvailableAt: bundle.quarterly?.[0]?.date ?? null };
}

function researchGaps(company, bundle) {
  const gaps = [];
  if (company.ticker === 'UBER') gaps.push(text('Gross Bookings, Trips and take rate are not in the current Fact OS schema.', '当前 Fact OS 不包含 Gross Bookings、Trips 和 take rate。'));
  if (economicTemplate(company) !== 'operating_company') gaps.push(text('Specialist balance-sheet and regulatory KPIs are required for this economic model.', '该经济模式需要专用资产负债表和监管指标。'));
  if ((bundle.quarterly ?? []).length < 8) gaps.push(text('Fewer than eight comparable reported quarters are available.', '可比的已报告季度少于八个。'));
  return gaps;
}

function observationSnapshot(detail) {
  return { asOf: detail.asOf, ticker: detail.ticker, methodVersion: detail.methodVersion,
    catalogGeneration: detail.catalogGeneration, judgment: detail.judgment,
    evidence: detail.importantChanges, counterEvidence: detail.counterEvidence,
    metrics: detail.company.metrics, periodEnd: detail.company.period_end,
    availableAt: detail.company.available_at, valuationStatus: detail.valuation?.valuationStatus ?? 'not_modeled' };
}

export async function saveFundamentalObservation(service, owner, body) {
  const ticker = tickerKey(body.ticker), asOf = service.date(body.asOf);
  const detail = await buildFundamentalCompany(service.source, ticker, asOf, { lens: body.lens });
  const note = String(body.note ?? '').trim().slice(0, 1200);
  return service.store.write(owner, 'fundamental_observation', ticker, body.operationId, body,
    () => ({ baseline: observationSnapshot(detail), note, status: 'open', retrospective: true }));
}

export function listFundamentalObservations(service, owner, ticker = null) {
  const rows = service.store.list(owner, 'fundamental_observation');
  return { version: 'fundamental-observations-v1', rows: ticker ? rows.filter(row => row.ticker === tickerKey(ticker)) : rows };
}

export async function reviewFundamentalObservation(service, owner, id, asOf) {
  const observation = service.store.get(owner, id, 'fundamental_observation');
  const current = await buildFundamentalCompany(service.source, observation.ticker, service.date(asOf),
    { lens: observation.baseline?.judgment?.id });
  const snapshot = observation.baseline;
  const now = observationSnapshot(current);
  return { version: 'fundamental-observation-review-v1', observation, asOf: current.asOf, now,
    changed: snapshot.catalogGeneration !== now.catalogGeneration || snapshot.periodEnd !== now.periodEnd,
    comparableMethod: snapshot.methodVersion === now.methodVersion,
    comparisonId: signature({ id, snapshot, now }) };
}
