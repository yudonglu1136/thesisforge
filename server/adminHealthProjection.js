// Reuse the bounded, independently audited public health result. Admin must not
// label quarterly facts stale using the old daily background-job cadence.
export function projectAdminHealth(admin, publicHealth) {
  const service = {...admin.service, status:'success', checkedAt:admin.generatedAt};
  if (!Array.isArray(publicHealth?.modules)) return {...admin, service};
  const ids = {guru_snapshots:'guru_data', valuation_database:'valuation', guru_backtest_refresh:'guru_backtests'};
  const modules = new Map(publicHealth.modules.map(m => [m.id, m]));
  const state = value => ({healthy:'success', stale:'warning'}[value] ?? value ?? 'unknown');
  const project = (job, module) => module ? {
    ...job, status:state(module.state), message:module.message ?? '',
    freshness:module.freshness, verificationAsOf:publicHealth.generatedAt,
    latestAt:module.freshness?.latestAt ?? job.latestAt,
    sourceAsOf:module.freshness?.sourceAsOf ?? null,
    observedAt:module.freshness?.observedAt ?? null,
    lastRunStatus:job.status,
  } : job;
  const jobs = (admin.jobs ?? []).filter(j=>j.id!=='market_prices').map(j => project(j, modules.get(ids[j.id])));
  if (modules.has('market_prices')) jobs.push(project({id:'market_prices', label:'Guru market prices'}, modules.get('market_prices')));
  const statuses = [state(publicHealth.status), state(admin.database?.status), ...jobs.map(j=>j.status)];
  const status = ['failed','error','unknown','warning','running'].find(s=>statuses.includes(s)) ?? 'success';
  return {...admin, service, jobs, status, ok:!['failed','error','unknown'].includes(status)};
}
