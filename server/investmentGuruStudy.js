// Read-only, cutoff-bounded views of the same audited 13F simulations used by
// the turnover study. Never rerun a user's strategy or mutate a source cache.
import { gurus } from './gurus.js';
import { auditPayload, measure } from './guruTurnoverMath.js';
import { assert, isoDate } from './investmentMath.js';
import { selectManagerBacktestCache, manager13fBacktestMethodVersion } from './backtest.js';

const cache = new WeakMap();
function entriesFor(source) {
  // data_version detects another connection; total_changes detects writes made
  // by the same connection. Neither may leave a rejected generation charted.
  const generation = `${source.db.prepare('PRAGMA data_version').get().data_version}:${source.db.prepare('SELECT total_changes() n').get().n}`;
  const prior = cache.get(source);
  if (prior?.generation === generation) return prior;
  const entries = [], unavailable = [];
  const tables = new Set(source.db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r => r.name));
  const read = table => tables.has(table) ? new Map(source.db.prepare(`SELECT guru_id,payload_json FROM ${table} WHERE years=5`).all().map(r => {
    // One malformed source is unavailable; it must not break every manager.
    try { return [r.guru_id, JSON.parse(r.payload_json)]; } catch { return [r.guru_id, null]; }
  })) : new Map();
  const strict = read('guru_backtests'), proxies = read('guru_backtest_proxies');
  for (const g of gurus.filter(g => g.type === 'manager13f' && !g.disableSimulation)) {
    const s = strict.get(g.id), proxy = proxies.get(g.id);
    try {
      // Use the same identity, method, security-master and per-manager proxy
      // policy as the existing public simulation. A separately plausible CAGR
      // is not authorization to publish an incompatible cache generation.
      const {payload:p} = selectManagerBacktestCache(s,proxy,5,g.id);
      assert(p && ['ready','proxy_ready'].includes(p.status), 'no_comparable_simulation');
      assert(p.method?.benchmark === 'SPY', 'unsupported_simulation_method');
      assert(!p.guru?.id || p.guru.id === g.id, 'simulation_manager_mismatch');
      if(p.status==='proxy_ready' && (s.refreshGeneration || p.refreshGeneration)) {
        assert(s.refreshGeneration && p.refreshGeneration===s.refreshGeneration,'proxy_refresh_generation_mismatch');
      }
      entries.push({g,p,trades:auditPayload(p)});
    } catch { unavailable.push({id:g.id, name:g.name, reason:'simulation_unavailable_or_unreconciled'}); }
  }
  const result = {generation, entries, unavailable, views: new Map(), spanViews: new Map()};
  cache.set(source,result); return result;
}

export function guruStudy(source, asOf, period='common') {
  isoDate(asOf); assert(['common','1Y','3Y'].includes(period),'invalid_comparison_period');
  const stored = entriesFor(source), key = `${asOf}:${period}`;
  if (stored.views.has(key)) return stored.views.get(key);
  const unavailable = [...stored.unavailable];
  const entries = stored.entries.filter(e => {
    if (e.p.equity.filter(p => p.date <= asOf).length >= 3) return true;
    unavailable.push({id:e.g.id,name:e.g.name,reason:'no_history_at_cutoff'}); return false;
  });
  const base = {version:'guru-study-v1',asOf,period,unavailable,rows:[],range:null,benchmark:null,
    method:{version:manager13fBacktestMethodVersion,riskFreeRate:0,costsIncluded:false,retrospective:true,
      turnover:'0.5 × sum(abs(target weight − drifted pre-rebalance weight)), including cash; excluding initial funding and forced corporate actions; divided by elapsed years',
      scope:'Stored 5Y Top-60 disclosed common-long simulations; current manager cohort, not actual fund returns. Subset proxies renormalize covered holdings. Common dates are fixed before UI filters.'}};
  if (!entries.length) return base;
  const sets = entries.map(e => new Set(e.p.equity.map(p=>p.date)));
  let dates = entries[0].p.equity.map(p=>p.date).filter(d=>d<=asOf && sets.every(s=>s.has(d)));
  const availableStart=dates[0], end=dates.at(-1);
  if(period!=='common' && end) {
    const target = `${Number(end.slice(0,4))-Number(period[0])}${end.slice(4)}`;
    dates=dates.filter(d=>d>=target);
  }
  if(dates.length<3) return base;
  const start=dates[0];
  const spanKey = `${start}:${end}:${period}:${entries.map(e=>e.g.id).join(',')}`;
  let computed = stored.spanViews.get(spanKey);
  if (!computed) {
    const commonDates=new Set(dates);
    const rows=entries.map(e=>measure(e,start,end,commonDates));
    // Every benchmark is independently rebased over exactly the same sessions.
    assert(rows.every(r=>Math.abs(r.benchmarkCagr-rows[0].benchmarkCagr)<1e-7 && Math.abs(r.benchmarkSharpe-rows[0].benchmarkSharpe)<1e-7),'benchmark_not_comparable');
    computed = {rows,range:{start,end,years:rows[0].years,observations:dates.length,availableStart},benchmark:{ticker:'SPY',cagr:rows[0].benchmarkCagr,sharpe:rows[0].benchmarkSharpe}};
    if(stored.spanViews.size>=16)stored.spanViews.delete(stored.spanViews.keys().next().value);
    stored.spanViews.set(spanKey,computed);
  }
  const result={...base,...computed};
  if(stored.views.size>=16)stored.views.delete(stored.views.keys().next().value);
  stored.views.set(key,result);return result;
}
