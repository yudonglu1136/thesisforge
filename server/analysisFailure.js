// Error messages can contain file paths or account data. Only stable, reviewed
// codes may cross a worker boundary or be included in operational receipts.
const codes = new Set([
  'local_runtime_unavailable', 'local_data_unavailable', 'local_snapshot_changed',
  'local_query_timeout', 'local_query_failed', 'local_result_too_large',
  'research_release_unavailable', 'investment_runtime_unavailable',
  'rule_analysis_nav_mismatch', 'rule_analysis_cost_mismatch',
  'rule_analysis_schedule_mismatch', 'rule_analysis_identity_conflict',
  'rule_analysis_prices_unavailable', 'rule_analysis_generation_changed',
  'missing_execution_price', 'missing_active_price', 'unresolved_corporate_action',
  'immutable_public_analysis_conflict', 'public_analysis_worker_timeout',
  'portfolio_analysis_worker_timeout', 'snapshot_write_failed', 'analysis_memory_limit',
  'rule_ledger_archive_changed', 'rule_ledger_archive_invalid', 'rule_ledger_snapshot_mismatch',
]);
export function analysisFailureCode(error) {
  if (error?.code === 'ERR_WORKER_OUT_OF_MEMORY') return 'analysis_memory_limit';
  return [error?.code,error?.message].find(code=>codes.has(code)) ?? 'analysis_build_failed';
}
