// AI Insights has one deterministic calculation engine. All percentages are
// fractions; score contributions use points on a 0–100 scale.
export const AI_INSIGHTS_METHOD_VERSION = 'ai-insights-v1';
export const finite = value => typeof value === 'number' && Number.isFinite(value);
const value = n => finite(n) ? n : null;
const ratio = (a, b) => finite(a) && finite(b) && b > 0 ? a / b : null;
const change = (a, b) => { const r = ratio(a, b); return r === null ? null : r - 1; };
const subtract = (a, b) => finite(a) && finite(b) ? a - b : null;
const sum = values => values.length && values.every(finite) ? values.reduce((a, b) => a + b, 0) : null;

export function quarterIndex(quarter) {
  const match = /^(\d{4})Q([1-4])$/.exec(String(quarter));
  return match ? Number(match[1]) * 4 + Number(match[2]) - 1 : null;
}
export function quarterAt(index) { return `${Math.floor(index / 4)}Q${index % 4 + 1}`; }
export function quarterForDate(date) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(date)) ? `${date.slice(0, 4)}Q${Math.ceil(Number(date.slice(5, 7)) / 3)}` : null;
}
function mappedQuarter(row) {
  // Provider calendardate is a fiscal alignment proxy, never reportperiod's
  // calendar quarter. Invalid/non-quarter endpoints must not silently remap.
  return /^(\d{4})-(03-31|06-30|09-30|12-31)$/.test(row.calendardate ?? '')
    ? quarterForDate(row.calendardate) : null;
}
function validDate(date) {
  return /^\d{4}-\d{2}-\d{2}$/.test(date ?? '') && Number.isFinite(Date.parse(date))
    && new Date(date).toISOString().slice(0, 10) === date;
}

export function selectAiInsightsFacts(artifact, asOf) {
  const byPeriod = new Map(), index = new Map(), issues = [];
  for (const row of artifact.facts ?? []) {
    if ((row.dimension && row.dimension !== 'ARQ') || !validDate(row.datekey)
      || !validDate(row.reportperiod) || row.datekey < row.reportperiod || row.datekey > asOf || row.reportperiod > asOf) continue;
    const quarter = mappedQuarter(row);
    if (!quarter) { issues.push({ ticker: row.ticker, code: 'invalid_calendar_mapping' }); continue; }
    const key = `${row.ticker}:${row.reportperiod}`;
    const old = byPeriod.get(key);
    // Same-public-date provider revisions cannot prove intraday availability.
    // Stable sourceRevisionId is the final deterministic tie-break only.
    const revisionOrder = r => `${r.datekey}:${r.source?.observedAt ?? ''}:${r.sourceRevisionId ?? ''}`;
    if (!old || revisionOrder(row) > revisionOrder(old)) byPeriod.set(key, { ...row, quarter });
  }
  for (const row of byPeriod.values()) {
    if (!index.has(row.ticker)) index.set(row.ticker, new Map());
    const periods = index.get(row.ticker), old = periods.get(row.quarter);
    if (old) {
      periods.set(row.quarter, { ticker: row.ticker, quarter: row.quarter, ambiguous: true });
      issues.push({ ticker: row.ticker, quarter: row.quarter, code: 'ambiguous_calendar_mapping' });
    } else periods.set(row.quarter, row);
  }
  return { index, issues };
}

export function revenueUsd(row) {
  if (!row || row.ambiguous) return null;
  if (finite(row.revenueusd)) return row.revenueusd;
  return row.currency === 'USD' && row.currencyBasis !== 'current_financial_master_not_period_verified' ? value(row.revenue) : null;
}
function flowUsd(row, metric) {
  if (!row || !finite(row[metric])) return null;
  if (finite(row.revenueusd) && row.revenueusd > 0 && finite(row.revenue) && row.revenue > 0)
    return row[metric] * row.revenueusd / row.revenue;
  return row.currency === 'USD' && row.currencyBasis !== 'current_financial_master_not_period_verified' ? row[metric] : null;
}
export function capexValue(row) {
  if (!row || row.ambiguous || !finite(row.capex)) return { amount: null, status: 'missing_capex', conversion: null };
  if (row.capex === 0 && row.capexZeroVerified !== true) return { amount: null, rawValue: 0, status: 'provider_zero_unverified', conversion: null };
  // A positive raw cash-flow field is net disposal proceeds, not spending.
  const amount = -row.capex;
  if (finite(row.revenueusd) && finite(row.revenue) && row.revenue > 0 && row.revenueusd > 0) {
    return { amount: amount * row.revenueusd / row.revenue, rawValue: row.capex,
      status: amount < 0 ? 'net_disposal_inflow' : 'ready', conversion: row.revenue === row.revenueusd ? 'provider_usd_revenue_parity' : 'provider_revenue_implied_period_fx' };
  }
  if (row.currency === 'USD' && row.currencyBasis !== 'current_financial_master_not_period_verified') return { amount, rawValue: row.capex, status: amount < 0 ? 'net_disposal_inflow' : 'ready', conversion: 'reported_usd' };
  return { amount: null, rawValue: row.capex, status: 'missing_usd_conversion', conversion: null };
}

function rowAt(periods, q, offset = 0) {
  const row = periods?.get(quarterAt(quarterIndex(q) + offset));
  return row?.ambiguous ? null : row ?? null;
}
function comparablePeriods(current, prior, quarters) {
  if (!current || !prior) return false;
  const days = (Date.parse(current.reportperiod) - Date.parse(prior.reportperiod)) / 86400000;
  return quarters === 1 ? days >= 60 && days <= 120 : days >= 330 && days <= 400;
}
function ttmRows(periods, quarter, offset = 0) {
  const rows = Array.from({ length: 4 }, (_, i) => rowAt(periods, quarter, offset - i));
  if (rows.some(r => !r) || new Set(rows.map(r => r.currency)).size !== 1 || !rows[0].currency) return null;
  // Unusual fiscal transitions cannot be made comparable merely by labels.
  for (let i = 0; i < 3; i++) {
    const days = (Date.parse(rows[i].reportperiod) - Date.parse(rows[i + 1].reportperiod)) / 86400000;
    if (days < 60 || days > 120) return null;
  }
  return rows;
}
function ttm(rows, key) { return rows ? sum(rows.map(r => value(r[key]))) : null; }
function annualGrowth(periods, quarter, offset = 0) {
  const current = rowAt(periods, quarter, offset), prior = rowAt(periods, quarter, offset - 4);
  return comparablePeriods(current, prior, 4) ? change(revenueUsd(current), revenueUsd(prior)) : null;
}

function scopeChecks(company, periods, quarter, asOf) {
  const current = rowAt(periods, quarter);
  const actions = (company.corporateActions ?? []).filter(a => a.date <= asOf && a.knownAt <= asOf);
  const crossing = offset => {
    const base = rowAt(periods, quarter, offset);
    return current && base && actions.some(action => action.date > base.reportperiod && action.date <= current.reportperiod);
  };
  const review = company.comparabilityReviewRequired && company.comparabilityKnownAt <= asOf;
  // The earliest endpoint of two four-quarter windows is q-7; the first
  // quarter's beginning is q-8's end. Scoring needs the entire scope bridge.
  const earliest = rowAt(periods, quarter, -8)?.reportperiod
    ?? (rowAt(periods, quarter, -7) ? new Date(Date.parse(rowAt(periods, quarter, -7).reportperiod) - 100 * 86400000).toISOString().slice(0, 10) : null);
  const eightQuarterCrossing = current && earliest && actions.some(a => a.date > earliest && a.date <= current.reportperiod);
  return { actions, growth: review || crossing(-1) || crossing(-4) || crossing(-5) || eightQuarterCrossing,
    quality: review || eightQuarterCrossing, review: !!review };
}

export const GROWTH_COMPONENTS = Object.freeze([
  { metric: 'revenueYoY', weight: .40, direction: 'higher' },
  { metric: 'revenueQoQ', weight: .30, direction: 'higher' },
  { metric: 'yoyAcceleration', weight: .15, direction: 'higher' },
  { metric: 'ttmGrossProfitYoY', weight: .15, direction: 'higher' },
]);
export const QUALITY_COMPONENTS = Object.freeze([
  { metric: 'ttmOperatingMargin', weight: .25, direction: 'higher' },
  { metric: 'ttmFcfMargin', weight: .25, direction: 'higher' },
  { metric: 'accrualRatio', weight: .20, direction: 'lower' },
  { metric: 'sbcRatio', weight: .15, direction: 'lower' },
  { metric: 'ttmGrossMarginYoYChange', weight: .15, direction: 'higher' },
]);

export function companyQuarter(company, periods, quarter, asOf) {
  const current = rowAt(periods, quarter), previous = rowAt(periods, quarter, -1), yearAgo = rowAt(periods, quarter, -4);
  const rows = ttmRows(periods, quarter), priorRows = ttmRows(periods, quarter, -4);
  const revenue = revenueUsd(current), yoy = annualGrowth(periods, quarter);
  const ttmRevenue = ttm(rows, 'revenue'), priorRevenue = ttm(priorRows, 'revenue');
  const ttmGrossProfit = ttm(rows, 'gp'), priorGrossProfit = ttm(priorRows, 'gp');
  const comparableTtmCurrency = rows && priorRows && rows[0].currency === priorRows[0].currency;
  const qoq = comparablePeriods(current, previous, 1) ? change(revenue, revenueUsd(previous)) : null;
  const oldPrior = rowAt(periods, quarter, -5);
  const priorYearQoQ = comparablePeriods(yearAgo, oldPrior, 1) ? change(revenueUsd(yearAgo), revenueUsd(oldPrior)) : null;
  const ttmCashFlow = ttm(rows, 'ncfo');
  const cashKnown = rows && rows.every(r => finite(r.capex) && (r.capex !== 0 || r.capexZeroVerified));
  const ttmFcf = cashKnown && finite(ttmCashFlow) ? ttmCashFlow + ttm(rows, 'capex') : null;
  const cashQualityIssues = rows?.some(r => r.capex > 0) ? ['net_disposal_inflow_requires_bridge'] : [];
  const averageAssets = current && yearAgo && finite(current.assets) && finite(yearAgo.assets)
    && current.currency === yearAgo.currency ? (current.assets + yearAgo.assets) / 2 : null;
  const historicalEligibility = company.firstPriceDate && company.firstPriceDate > asOf ? 'before_first_price_proxy' : 'fixed_current_basket';
  const scope = scopeChecks(company, periods, quarter, asOf);
  const missingReasons = !current ? [periods?.get(quarter)?.ambiguous ? 'ambiguous_calendar_mapping' : 'not_disclosed_as_of'] : [];
  if (current && revenue === null) missingReasons.push('missing_usd_revenue');
  return {
    ticker: company.ticker, name: company.name ?? company.ticker, issuerId: company.issuerId ?? null,
    group: company.group, sector: company.sector, sectorLabel: company.sectorLabel ?? null,
    capexGroup: company.capexGroup ?? null, quarter, currency: 'USD', financialCurrency: current?.currency ?? null,
    reportperiod: current?.reportperiod ?? null, datekey: current?.datekey ?? null,
    fiscalperiod: current?.fiscalperiod ?? null, sourceRevisionId: current?.sourceRevisionId ?? null,
    revenue, revenueYoY: yoy, revenueQoQ: qoq,
    revenueYoYDelta: subtract(revenue, revenueUsd(yearAgo)), revenueQoQDelta: subtract(revenue, revenueUsd(previous)),
    yoyAcceleration: subtract(yoy, annualGrowth(periods, quarter, -1)),
    priorYearQoQ, qoqSeasonalityDifference: subtract(qoq, priorYearQoQ),
    ttmRevenue: rows ? sum(rows.map(revenueUsd)) : null,
    ttmOperatingMargin: ratio(ttm(rows, 'opinc'), ttmRevenue), ttmFcfMargin: ratio(ttmFcf, ttmRevenue),
    ttmCfoMargin: ratio(ttmCashFlow, ttmRevenue), ttmGrossMargin: ratio(ttmGrossProfit, ttmRevenue),
    ttmGrossProfitYoY: rows && priorRows ? change(sum(rows.map(r => flowUsd(r, 'gp'))), sum(priorRows.map(r => flowUsd(r, 'gp')))) : null,
    ttmGrossMarginYoYChange: comparableTtmCurrency ? subtract(ratio(ttmGrossProfit, ttmRevenue), ratio(priorGrossProfit, priorRevenue)) : null,
    sbcRatio: ratio(ttm(rows, 'sbcomp'), ttmRevenue),
    accrualRatio: ratio(subtract(ttm(rows, 'netinc'), ttmCashFlow), averageAssets),
    ttmFcfLessSbcMargin: ratio(subtract(ttmFcf, ttm(rows, 'sbcomp')), ttmRevenue),
    historicalEligibility, firstPriceDate: company.firstPriceDate ?? null,
    scopeWarning: company.scopeWarning ?? null, classificationBasis: company.classificationBasis ?? 'current_registry_retrospective_not_historical_investable',
    comparability: { growth: scope.growth ? 'scope_bridge_required' : 'reported_basis',
      quality: scope.quality ? 'scope_bridge_required' : 'reported_basis', events: scope.actions,
      reviewRequired: scope.review, organicGrowthVerified: false },
    cashQualityIssues, status: missingReasons.length ? 'missing' : 'ready', missingReasons,
    growthScore: null, qualityScore: null, compositeScore: null,
    scoreBreakdown: {}, scoreStatus: {}, rank: {},
  };
}

function scorePercentile(raw, cohort, metric, direction) {
  const less = cohort.filter(r => r[metric] < raw).length;
  const equal = cohort.filter(r => r[metric] === raw).length;
  const percentile = 100 * (less + (equal - 1) / 2) / (cohort.length - 1);
  return direction === 'lower' ? 100 - percentile : percentile;
}
export function scoreCompanies(rows) {
  for (const group of ['hardware', 'software']) {
    const peers = rows.filter(r => r.group === group && r.historicalEligibility !== 'before_first_price_proxy');
    for (const [scoreName, components] of [['growth', GROWTH_COMPONENTS], ['quality', QUALITY_COMPONENTS]]) {
      const eligible = row => components.every(c => finite(row[c.metric])) && (scoreName !== 'quality' || !row.cashQualityIssues.length)
        && row.comparability?.[scoreName] !== 'scope_bridge_required';
      const cohort = peers.filter(eligible);
      for (const row of rows.filter(r => r.group === group)) {
        const reasons = components.filter(c => !finite(row[c.metric])).map(c => `missing_${c.metric}`);
        if (scoreName === 'quality') reasons.push(...row.cashQualityIssues);
        if (row.comparability?.[scoreName] === 'scope_bridge_required') reasons.push('scope_bridge_required');
        if (row.historicalEligibility === 'before_first_price_proxy') reasons.push('before_first_price_proxy');
        if (cohort.length < 8) reasons.push('insufficient_peer_cohort');
        row.scoreStatus[scoreName] = { status: reasons.length ? 'unavailable' : 'ready', reasons, peerGroup: group, eligiblePeers: cohort.length };
        const scored = !reasons.length;
        row.scoreBreakdown[scoreName] = components.map(component => {
          const raw = value(row[component.metric]);
          const percentile = scored ? scorePercentile(raw, cohort, component.metric, component.direction) : null;
          return { ...component, raw, percentile, contribution: percentile === null ? null : percentile * component.weight,
            peerGroup: group, eligiblePeers: cohort.length };
        });
        row[`${scoreName}Score`] = scored ? sum(row.scoreBreakdown[scoreName].map(c => c.contribution)) : null;
      }
    }
    for (const row of peers) {
      row.compositeScore = finite(row.growthScore) && finite(row.qualityScore) ? (row.growthScore + row.qualityScore) / 2 : null;
      row.scoreStatus.composite = { status: finite(row.compositeScore) ? 'ready' : 'unavailable',
        reasons: finite(row.compositeScore) ? [] : ['requires_growth_and_quality_scores'], peerGroup: group };
      row.scoreBreakdown.composite = [{ metric: 'growthScore', raw: row.growthScore, weight: .5, contribution: finite(row.growthScore) ? row.growthScore / 2 : null },
        { metric: 'qualityScore', raw: row.qualityScore, weight: .5, contribution: finite(row.qualityScore) ? row.qualityScore / 2 : null }];
    }
    for (const name of ['growth', 'quality', 'composite']) {
      const sorted = peers.filter(r => finite(r[`${name}Score`])).sort((a, b) => b[`${name}Score`] - a[`${name}Score`] || a.ticker.localeCompare(b.ticker));
      sorted.forEach((row, i) => { row.rank[name] = i + 1; });
    }
  }
  return rows;
}

export function aggregateQuarter(companies, index, quarter, metric = 'revenue', { asOf = '9999-12-31' } = {}) {
  const members = new Map(companies.map(c => [c.ticker, c]));
  const exclusion = (ticker, offset) => {
    const company = members.get(ticker), row = rowAt(index.get(ticker), quarter, offset);
    if (company?.firstPriceDate && company.firstPriceDate > asOf) return 'before_first_price_proxy';
    const spin = (company?.corporateActions ?? []).find(action => action.type === 'spunofffrom'
      && action.knownAt <= asOf && members.has(action.counterpartyTicker)
      && row && row.reportperiod <= action.date);
    return spin ? 'pre_spin_parent_overlap' : null;
  };
  const get = (ticker, offset) => {
    if (exclusion(ticker, offset)) return null;
    const row = rowAt(index.get(ticker), quarter, offset);
    return metric === 'capex' ? capexValue(row).amount : revenueUsd(row);
  };
  const pairExclusion = (company, offset) => {
    const currentRow = rowAt(index.get(company.ticker), quarter), base = rowAt(index.get(company.ticker), quarter, offset);
    if (!currentRow || !base) return null;
    return (company.corporateActions ?? []).some(a => a.knownAt <= asOf && a.date > base.reportperiod && a.date <= currentRow.reportperiod)
      ? 'scope_bridge_required' : null;
  };
  const current = companies.map(c => ({ ...c, value: get(c.ticker, 0) }));
  const disclosed = current.filter(c => finite(c.value));
  const compare = offset => {
    const paired = disclosed.map(c => ({ ...c, prior: get(c.ticker, offset) })).filter(c => finite(c.prior)
      && comparablePeriods(rowAt(index.get(c.ticker), quarter), rowAt(index.get(c.ticker), quarter, offset), -offset)
      && !pairExclusion(c, offset));
    const prior = sum(paired.map(c => c.prior)), amount = sum(paired.map(c => c.value));
    return { current: amount, prior, delta: subtract(amount, prior), growth: change(amount, prior), comparable: paired.length,
      priorQuarter: quarterAt(quarterIndex(quarter) + offset),
      contributions: paired.map(c => ({ ticker: c.ticker, name: c.name, current: c.value, prior: c.prior,
        delta: c.value - c.prior, weight: ratio(c.prior, prior), contribution: ratio(c.value - c.prior, prior) }))
        .sort((a, b) => Math.abs(b.delta) - Math.abs(a.delta) || a.ticker.localeCompare(b.ticker)),
      excluded: companies.filter(c => !paired.some(p => p.ticker === c.ticker)).map(c => ({ ticker: c.ticker,
        reason: exclusion(c.ticker, 0) || exclusion(c.ticker, offset) || pairExclusion(c, offset)
          || (!finite(get(c.ticker, 0)) ? 'missing_current' : !finite(get(c.ticker, offset)) ? 'missing_base' : 'non_comparable_period_length') })) };
  };
  const yoy = compare(-4), qoq = compare(-1);
  return { amount: sum(disclosed.map(c => c.value)), disclosedTotal: sum(disclosed.map(c => c.value)),
    yoy: yoy.growth, qoq: qoq.growth, unit: 'USD',
    coverage: { expected: companies.length, disclosed: disclosed.length, yoyComparable: yoy.comparable, qoqComparable: qoq.comparable },
    missing: current.filter(c => !finite(c.value)).map(c => ({ ticker: c.ticker, reason: exclusion(c.ticker, 0) || (metric === 'capex'
      ? capexValue(rowAt(index.get(c.ticker), quarter)).status : 'missing_revenue_as_of') })),
    yoyComparison: yoy, qoqComparison: qoq,
    ...(metric === 'capex' ? { breakdown: Object.fromEntries(['big4', 'neocloud'].map(group => [group,
      sum(disclosed.filter(c => c.capexGroup === group).map(c => c.value))])) } : {}),
  };
}

export function deterministicInsights(summary, companies) {
  const insights = [], bilingual = (en, zh) => ({ en, zh });
  for (const group of ['hardware', 'software']) {
    const eligible = companies.filter(r => r.group === group && finite(r.yoyAcceleration)
      && r.comparability?.growth !== 'scope_bridge_required' && r.historicalEligibility !== 'before_first_price_proxy');
    if (eligible.length) {
      const accelerated = eligible.filter(r => r.yoyAcceleration > 0);
      insights.push({ code: `${group}_growth_breadth`, group,
        title: bilingual(`${group === 'hardware' ? 'Hardware' : 'Software'} growth breadth`, `${group === 'hardware' ? '硬件' : '软件'}增长广度`),
        summary: bilingual(`${accelerated.length} of ${eligible.length} comparable companies accelerated revenue YoY.`, `${eligible.length} 家可比公司中，${accelerated.length} 家的收入同比增速加快。`),
        evidence: { accelerating: accelerated.length, comparable: eligible.length, tickers: accelerated.map(r => r.ticker),
          revenueWeightedShare: ratio(sum(accelerated.map(r => r.revenue)) ?? 0, sum(eligible.map(r => r.revenue))) } });
    }
  }
  const gap = subtract(summary.capex.yoy, summary.hardware.yoy);
  if (finite(gap)) insights.push({ code: 'capex_hardware_growth_gap',
    title: bilingual('Capital investment / hardware growth gap', '资本投入与硬件增长差'),
    summary: bilingual(`Capital investment YoY minus hardware revenue YoY: ${(gap * 100).toFixed(1)} pp. This is a growth-rate comparison, not a return on investment.`,
      `资本投入同比减硬件收入同比为 ${(gap * 100).toFixed(1)} 个百分点。这是增速比较，不是投资回报率。`),
    evidence: { capexYoY: summary.capex.yoy, hardwareYoY: summary.hardware.yoy, gap,
      capexComparable: summary.capex.coverage.yoyComparable, hardwareComparable: summary.hardware.coverage.yoyComparable } });
  return insights.slice(0, 3);
}
