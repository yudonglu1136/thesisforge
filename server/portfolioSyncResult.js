// A saved report is useful during an outage, but is not a successful new sync.
export function portfolioSyncResult(portfolio, now = new Date()) {
  const degraded = portfolio?.freshness?.status === "stale"
    || portfolio?.connection?.status === "stale_report"
    || portfolio?.connection?.status === "linked_partial";
  const failed = portfolio?.connection?.status === "error";
  const ok = !degraded && !failed;
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
