// Read-only analysis of stored 13F simulations. No network or source DB writes.
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { gurus } from '../server/gurus.js';
import { auditPayload, measure } from '../server/guruTurnoverMath.js';

const sum = a => a.reduce((s, x) => s + x, 0);
const mean = a => sum(a) / a.length;
const yearsBetween = (a, b) => (Date.parse(b) - Date.parse(a)) / 86400000 / 365.25;
const sd = a => Math.sqrt(sum(a.map(x => (x - mean(a)) ** 2)) / (a.length - 1));
const finite = x => typeof x === 'number' && Number.isFinite(x);
const near = (a, b, label, tolerance = 1e-8) => assert(Math.abs(a - b) <= tolerance, `${label}: ${a} vs ${b}`);
const cash = '__CASH__';

export function correlation(x, y) {
  assert.equal(x.length, y.length);
  if (x.length < 3 || !x.every(finite) || !y.every(finite)) return null;
  const mx = mean(x), my = mean(y);
  const d = Math.sqrt(sum(x.map(a => (a - mx) ** 2)) * sum(y.map(a => (a - my) ** 2)));
  return d ? sum(x.map((a, i) => (a - mx) * (y[i] - my))) / d : null;
}
export function ranks(a) {
  const ordered = a.map((v, i) => ({ v, i })).sort((a, b) => a.v - b.v), result = [];
  for (let i = 0; i < ordered.length;) {
    let j = i + 1;
    while (j < ordered.length && ordered[j].v === ordered[i].v) j++;
    for (let k = i; k < j; k++) result[ordered[k].i] = (i + j + 1) / 2;
    i = j;
  }
  return result;
}
function rng(seed = 20260910) {
  return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}
function quantile(a, p) { const b = [...a].sort((a, b) => a - b), h = (b.length - 1) * p, i = Math.floor(h); return b[i] + (b[Math.ceil(h)] - b[i]) * (h - i); }
export function inference(rows, xKey = 'annualTurnover', yKey = 'cagr', iterations = 10000) {
  const x = rows.map(r => r[xKey]), y = rows.map(r => r[yKey]), random = rng();
  const r = correlation(x, y), rho = correlation(ranks(x), ranks(y));
  if (r == null || rho == null) return { n: rows.length, pearson: r, spearman: rho };
  let pr = 0, ps = 0; const boot = [], bootS = [], rx = ranks(x), ry = ranks(y);
  for (let k = 0; k < iterations; k++) {
    const indices = x.map((_, i) => i);
    for (let i = indices.length - 1; i > 0; i--) { const j = Math.floor(random() * (i + 1)); [indices[i], indices[j]] = [indices[j], indices[i]]; }
    if (Math.abs(correlation(x, indices.map(i => y[i]))) >= Math.abs(r) - 1e-12) pr++;
    if (Math.abs(correlation(rx, indices.map(i => ry[i]))) >= Math.abs(rho) - 1e-12) ps++;
    const sample = x.map(() => Math.floor(random() * x.length));
    const bx = sample.map(i => x[i]), by = sample.map(i => y[i]);
    const br = correlation(bx, by), bs = correlation(ranks(bx), ranks(by));
    if (br != null) boot.push(br);
    if (bs != null) bootS.push(bs);
  }
  const loo = rows.map((_, skip) => correlation(x.filter((_, i) => i !== skip), y.filter((_, i) => i !== skip)));
  return { n: x.length, pearson: r, spearman: rho, pearsonPermutationP: (pr + 1) / (iterations + 1), spearmanPermutationP: (ps + 1) / (iterations + 1), pearsonBootstrap95: [quantile(boot, .025), quantile(boot, .975)], spearmanBootstrap95: [quantile(bootS, .025), quantile(bootS, .975)], leaveOneOutPearsonRange: [Math.min(...loo), Math.max(...loo)], iterations, seed: 20260910 };
}
export { performance, weights, turnover, auditPayload, measure } from '../server/guruTurnoverMath.js';
function cohort(entries, start = null, end = null) {
  start ??= entries.map(e => e.p.window.start).sort().at(-1);
  end ??= entries.map(e => e.p.window.end).sort()[0];
  const candidateDates = entries[0].p.equity.map(e => e.date).filter(d => d >= start && d <= end);
  const calendars = entries.map(e => new Set(e.p.equity.map(p => p.date)));
  const commonDates = new Set(candidateDates.filter(d => calendars.every(c => c.has(d))));
  start = [...commonDates][0]; end = [...commonDates].at(-1);
  const rows = entries.map(e => measure(e, start, end, commonDates)).sort((a, b) => b.annualTurnover - a.annualTurnover);
  rows.forEach((r, i) => { r.rank = i + 1; });
  const stats = data => ({ cagr: inference(data), sharpe: inference(data, 'annualTurnover', 'sharpe') });
  return { start, end, observations: commonDates.size, calendarOmissions: entries.map(e => ({ id: e.g.id, count: e.p.equity.filter(p => p.date >= start && p.date <= end && !commonDates.has(p.date)).length })), rows, correlations: { all: stats(rows), strict: stats(rows.filter(r => r.basis === 'strict')), proxy: stats(rows.filter(r => r.basis === 'proxy')), noRenaissance: stats(rows.filter(r => r.id !== 'renaissance-technologies')), sharpeRf4: inference(rows, 'annualTurnover', 'sharpeRf4'), minBuySellDefinition: { cagr: inference(rows, 'annualSecurityMinTurnover', 'cagr'), sharpe: inference(rows, 'annualSecurityMinTurnover', 'sharpe') } } };
}
function pct(x) { return finite(x) ? `${(x * 100).toFixed(2)}%` : '—'; }
function csv(rows) { const keys = Object.keys(rows[0]); return [keys.join(','), ...rows.map(r => keys.map(k => JSON.stringify(r[k] ?? '')).join(','))].join('\n') + '\n'; }

export function run(dbPath, outPath) {
  const executedAt = new Date().toISOString(), db = new DatabaseSync(dbPath, { readOnly: true });
  db.exec('BEGIN'); // One consistent read snapshot, even if the app writes elsewhere.
  const queries = { strict: 'SELECT guru_id, years, generated_at, payload_json FROM guru_backtests WHERE years IN (5, 10) ORDER BY guru_id, years', proxy: 'SELECT guru_id, years, generated_at, payload_json FROM guru_backtest_proxies WHERE years IN (5, 10) ORDER BY guru_id, years', exposure: 'SELECT guru_id, generated_at, payload_json FROM guru_exposure_snapshots ORDER BY guru_id' };
  const raw = Object.fromEntries(Object.entries(queries).map(([k, q]) => [k, db.prepare(q).all()]));
  db.exec('COMMIT'); db.close();
  const parsed = kind => new Map(raw[kind].map(r => [`${r.guru_id}:${r.years}`, JSON.parse(r.payload_json)]));
  const strict = parsed('strict'), proxy = parsed('proxy'), enabled = gurus.filter(g => g.type === 'manager13f' && !g.disableSimulation);
  const entries = [], exclusions = [], sources = [];
  for (const g of enabled) for (const window of [5, 10]) {
    const s = strict.get(`${g.id}:${window}`), px = proxy.get(`${g.id}:${window}`);
    const p = s?.status === 'ready' ? s : px?.status === 'proxy_ready' ? px : null;
    if (!p) { exclusions.push({ id: g.id, window, reason: 'No ready strict or proxy payload' }); continue; }
    try {
      assert.equal(p.method.years, window); assert.equal(p.method.version, 'manager13f-drifted-total-return-v9');
      assert.equal(p.method.securityMasterVersion, 'holding-resolution-v1-99230d9f3aa4b341');
      if (p.status === 'proxy_ready') { assert.equal(p.proxy.strictFailureGeneratedAt, s.generatedAt); assert.equal(p.proxy.securityMasterVersion, s.method.securityMasterVersion); assert(p.proxy.minimumSelectedBookCoverage >= .3); assert(p.proxy.minimumIncludedPositions >= 2); }
      else assert(p.rebalances.every(r => r.coveragePct >= .9 - 1e-10));
      entries.push({ g, window, p, trades: auditPayload(p) });
      sources.push({ id: g.id, window, status: p.status, generatedAt: p.generatedAt, method: p.method.version, securityMaster: p.method.securityMasterVersion, sha256: createHash('sha256').update(JSON.stringify(p)).digest('hex') });
    } catch (error) { exclusions.push({ id: g.id, window, reason: error.message }); }
  }
  const five = entries.filter(e => e.window === 5);
  assert.equal(five.length, enabled.length, JSON.stringify(exclusions));
  const primary = cohort(five), end = primary.end;
  const periods = { primary, trailing3Y: cohort(five, `${Number(end.slice(0, 4)) - 3}${end.slice(4)}`, end), trailing1Y: cohort(five, `${Number(end.slice(0, 4)) - 1}${end.slice(4)}`, end) };
  const strict10 = entries.filter(e => e.window === 10 && e.p.status === 'ready');
  if (strict10.length >= 3) periods.longHistoryStrictOnly = cohort(strict10);
  // Require at least eight calendar years to avoid calling a four-year
  // intersection a long-horizon robustness check. This leaves 26 managers.
  const long = entries.filter(e => e.window === 10 && yearsBetween(e.p.window.start, end) >= 8);
  if (long.length >= 3) {
    periods.longHistoryAvailable = cohort(long);
    // Same managers AND same stored portfolio variants; only change dates.
    periods.sameLongCohortRecent = cohort(long, primary.start, end);
  }
  const exposure = raw.exposure.map(r => ({ id: r.guru_id, p: JSON.parse(r.payload_json) }));
  const legacy = exposure.filter(e => enabled.some(g => g.id === e.id)).map(e => {
    const h = [...(e.p.history ?? [])].sort((a, b) => a.reportDate.localeCompare(b.reportDate));
    const latest = h.at(-1); return { id: e.id, latestQuarter: latest?.reportDate, latestReportedValueChangeProxy: latest?.turnoverProxy ?? null, observations: h.length, warning: 'NOT trading turnover; includes market moves and subscriptions/redemptions.' };
  }).sort((a, b) => (b.latestReportedValueChangeProxy ?? -1) - (a.latestReportedValueChangeProxy ?? -1));
  const excludedProfiles = gurus.filter(g => !enabled.includes(g)).map(g => ({ id: g.id, name: g.name, type: g.type, reason: g.disableSimulation ? 'Archived / disabled 13F simulation' : 'Not a comparable manager13f portfolio' }));
  const result = { executedAt, database: resolve(dbPath), catalogCount: gurus.length, eligibleCount: enabled.length, sourceQueries: queries, sources, exclusions, excludedProfiles, periods, legacy, trades: five.map(e => ({ id: e.g.id, rows: e.trades })), checks: { sourceDatabaseReadOnly: true, dailyAndQuarterAttributionReconciled: true, storedCagrAndSharpeReproduced: true, initialFundingExcluded: true, forcedCorporateActionsAreNotTrades: true } };
  mkdirSync(outPath, { recursive: true });
  writeFileSync(resolve(outPath, 'analysis.json'), JSON.stringify(result, null, 2));
  writeFileSync(resolve(outPath, 'all-gurus-ranked.csv'), csv(primary.rows));
  writeFileSync(resolve(outPath, 'legacy-value-change-proxy.csv'), csv(legacy));
  const table = ['| 排名 | Guru | 年化换手率 | CAGR | Sharpe | 回测口径 |', '|---:|---|---:|---:|---:|---|', ...primary.rows.map(r => `| ${r.rank} | ${r.name} | ${pct(r.annualTurnover)} | ${pct(r.cagr)} | ${r.sharpe.toFixed(3)} | ${r.basis} |`)].join('\n');
  const statsLines = Object.entries(periods).flatMap(([key, p]) => Object.entries(p.correlations).filter(([k]) => ['all', 'strict', 'proxy', 'noRenaissance'].includes(k)).flatMap(([c, metrics]) => ['cagr', 'sharpe'].map(m => { const s = metrics[m]; return `| ${key} | ${p.start} → ${p.end} | ${c} | ${m} | ${s.n} | ${s.pearson?.toFixed(4) ?? '—'} | ${s.spearman?.toFixed(4) ?? '—'} | ${s.pearsonPermutationP?.toFixed(4) ?? '—'} | ${s.spearmanPermutationP?.toFixed(4) ?? '—'} |`; })));
  writeFileSync(resolve(outPath, 'README.md'), `# Guru 换手率与收益的横截面分析\n\n读取时间：${executedAt}\n\n范围：${gurus.length} 个数据库目录人物；${enabled.length} 个可回测的 13F 管理人。主表 ${primary.start} 至 ${primary.end}，${primary.observations} 个共同净值日期，实际 ${primary.rows[0].years.toFixed(2)} 年，不冒充完整五年。\n\n## 全部排序（高到低）\n\n${table}\n\nstrict：Top-60 已披露普通股复制组合，未覆盖权重留现金。proxy：剔除不可定价股票后重新归一化的公开持仓子集。两者都不是基金实盘回报；Renaissance 更不是 Medallion。\n\n## 相关性及敏感性\n\n| 区间组 | 日期 | 样本 | 指标 | N | Pearson r | Spearman ρ | Pearson 置换 p | Spearman 置换 p |\n|---|---|---|---|---:|---:|---:|---:|---:|\n${statsLines.join('\n')}\n\n## 口径\n\n- 单次单边换手 = 0.5 × Σ所有股票及现金 |新目标权重 − 调仓前漂移权重|；年化 = 区间各次换手之和 / 实际年数。100% 表示一年累计换掉约一整本组合。初次建仓不计；比较期起点之前及起点当天的交易不计。不是直接对比两个季度目标权重；市场价格漂移已从买卖中分离。\n- 经济身份处理：被现金收购的旧持仓归为现金，股票转换归为实际后继证券，不把强制公司行动当作主动卖买。现金残差、季度贡献、每日净值、已存 CAGR/Sharpe 逐项核对。\n- 同时保存证券买入/卖出较小者的年化口径、双边成交量及敏感性结果。\n- CAGR 为每日净值起终点几何年化；Sharpe 为日收益均值 / 样本标准差 × √252，无风险利率 0%，与网站现有回测一致；另做固定 4% 无风险利率敏感性，不代表历史真实无风险利率。\n- 股息及拆股调整收盘价；没有交易成本、滑点、税、基金费、真实现金或空头。模型调仓在 SEC 公开之后，不代表管理人的真实交易时间。\n- 共同日期由全部曲线交集取得，不前填；遗漏情况在 analysis.json。价格库源自已有 SEC + Yahoo / SQLite 回测缓存，本任务未补数据或查询 API。\n- 原库 turnoverProxy = 季末市值绝对变化之和 / 两期平均组合市值 / 2，含市场涨跌、申赎以及披露范围变化；单独导出，不拿它当基金真实交易换手率。\n- 主分析为同期横截面描述，不是预测验证。当前存续管理人样本存在幸存者/选择偏差，共同持股使各观察不独立，行业风格、集中度、现金与覆盖率均可能混杂。10,000 次置换 p 和管理人自助抽样 95% 区间仅为探索性统计，不是因果证明，多次检验未做显著性筛选。\n\n## 数据覆盖\n\n${primary.rows.filter(r => r.basis === 'proxy').map(r => `- ${r.name}: 代理曲线，历史最低选定书本覆盖 ${pct(r.minimumCoverage)}。`).join('\n')}\n\n未参与的目录人物：\n${excludedProfiles.map(g => `- ${g.name} (${g.type}): ${g.reason}`).join('\n')}\n\n其他排除：${JSON.stringify(exclusions)}\n\n## 复核\n\n只读输入：${resolve(dbPath)}\n\n脚本：scripts/analyze-guru-turnover.mjs；单元测试：scripts/analyze-guru-turnover.test.mjs。analysis.json 包含实际 SQL、源快照 SHA-256、逐次换手、全部统计及检查结果。\n`);
  console.log(JSON.stringify({ output: resolve(outPath), exclusions, window: [primary.start, primary.end], counts: { all: five.length, strict: five.filter(e => e.p.status === 'ready').length }, rows: primary.rows.map(r => ({ rank: r.rank, name: r.name, turnover: pct(r.annualTurnover), cagr: pct(r.cagr), sharpe: r.sharpe.toFixed(3), basis: r.basis })), correlations: primary.correlations }, null, 2));
  return result;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) run(process.argv[2] ?? 'output/investment-workflow-20260908/runtime.sqlite', process.argv[3] ?? 'output/guru-turnover-20260910');
