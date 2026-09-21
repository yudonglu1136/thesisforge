// A saved report is useful during an outage, but is not a successful new sync.
export function portfolioSyncResult(portfolio, now = new Date()) {
  const connectionStatus = portfolio?.connection?.status;
  const degraded = portfolio?.freshness?.status === "stale"
    || connectionStatus === "stale_report"
    || connectionStatus === "linked_partial";
  // Absence of an error is not proof of a verified broker refresh. Only the
  // two complete connection states can authorize a success message.
  const linked = connectionStatus === "linked" || connectionStatus === "linked_empty";
  const failed = !degraded && !linked;
  const ok = linked && !degraded;
  const income = portfolio?.analysisAccounts?.length
    ? portfolio.analysisAccounts.every((account) => account?.historyEvidence?.incomeStatus === "ready")
      ? "ready"
      : "cash_transactions_required"
    : "report_inputs_unavailable";
  return {
    status: degraded ? "degraded" : failed ? "failed" : "success",
    response: {
      ok,
      ...(ok ? { syncedAt: now.toISOString() } : {}),
      connection: portfolio?.connection,
      summary: portfolio?.summary,
      ...(portfolio?.source?.asOf ? {reportDate: portfolio.source.asOf} : {}),
      ...(portfolio?.source?.historyQueryStatus
        ? {historyStatus: portfolio.source.historyQueryStatus}
        : {}),
      ...(portfolio?.analysisAccounts?.length ? {incomeStatus: income} : {}),
      portfolio
    }
  };
}
