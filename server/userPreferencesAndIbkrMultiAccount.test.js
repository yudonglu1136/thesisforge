import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'user-prefs-ibkr-multi-'));
process.env.USER_PORTFOLIO_DATA_DIR = path.join(root, 'users');
process.env.SQLITE_DB_PATH = path.join(root, 'research.sqlite');
process.env.PORTFOLIO_CREDENTIALS_KEY = 'synthetic-prefs-ibkr-secret';

const store = await import('./userPortfolioStore.js');
const { loadPortfolioDashboard, clearPortfolioCache, loadIbkrFlexXml } = await import('./portfolioClient.js');
const { loadQqqSchdRotationDashboard, analyzeQqqSchdRotationRange } = await import('./qqqSchdRotationStrategy.js');
const { loadInvestorStyleDashboard } = await import('./investorStyleDashboard.js');
const originalFetch = globalThis.fetch;

test.after(() => {
  globalThis.fetch = originalFetch;
  store.closeUserPortfolioStores();
  fs.rmSync(root, { recursive: true, force: true });
});

test('per-user language habit persists independently per user without creating empty DBs on cold read', () => {
  const zhUser = { id: 'habit-user-zh' };
  const enUser = { id: 'habit-user-en' };

  const cold = store.readUserPreferences(zhUser);
  assert.equal(cold.configured, false);
  assert.equal(cold.language, null);
  assert.equal(store.userPortfolioInfo(zhUser).exists, false);

  const savedZh = store.writeUserPreferences(zhUser, { language: 'zh-CN', colorBlind: true });
  assert.equal(savedZh.configured, true);
  assert.equal(savedZh.language, 'zh');
  assert.equal(savedZh.colorBlind, true);

  const savedEn = store.writeUserPreferences(enUser, { language: 'en' });
  assert.equal(savedEn.language, 'en');
  assert.equal(savedEn.colorBlind, null);

  store.closeUserPortfolioStores();

  assert.equal(store.readUserPreferences(zhUser).language, 'zh');
  assert.equal(store.readUserPreferences(zhUser).colorBlind, true);
  assert.equal(store.readUserPreferences(enUser).language, 'en');
  assert.throws(() => store.writeUserPreferences(zhUser, { language: 'fr' }), /Unsupported language/);
});

test('addPortfolioAccount deduplicates same Query ID on token rotation and cleans failed stale accounts when requested', async () => {
  const user = { id: 'ibkr-multi-fix-user' };

  // 1. User has an old broken account 1200999
  store.savePortfolioConnection(user, {
    ibkrFlexToken: 'SYNTHETIC_EXPIRED_TOKEN_001',
    ibkrFlexQueryId: '1200999',
  });

  globalThis.fetch = async input => {
    const url = new URL(input);
    const q = url.searchParams.get('q');
    if (url.pathname.endsWith('SendRequest') && q === '1200999') {
      return {
        ok: true,
        text: async () =>
          '<FlexStatementResponse><Status>Fail</Status><ErrorCode>1012</ErrorCode><ErrorMessage>Token has expired.</ErrorMessage></FlexStatementResponse>',
      };
    }
    if (url.pathname.endsWith('SendRequest')) {
      return {
        ok: true,
        text: async () =>
          '<FlexStatementResponse><Status>Success</Status><ReferenceCode>REF_VALID</ReferenceCode></FlexStatementResponse>',
      };
    }
    return {
      ok: true,
      text: async () =>
        '<FlexQueryResponse><FlexStatements><FlexStatement accountId="U_VALID" fromDate="20261116" toDate="20261117" currency="USD"><AccountInformation currency="USD"/><EquitySummaryByReportDateInBase total="50000" cash="5000" reportDate="20261117"/><OpenPositions><OpenPosition symbol="NVDA" assetCategory="STK" currency="USD" quantity="100" markPrice="450" positionValue="45000"/></OpenPositions></FlexStatement></FlexStatements></FlexQueryResponse>',
    };
  };

  clearPortfolioCache(user);
  const failedFirst = await loadPortfolioDashboard({ user, forceRefresh: true });
  assert.equal(failedFirst.connection.status, 'error');
  const statusAfterFail = store.readPortfolioConnectionStatus(user);
  assert.equal(statusAfterFail.accounts[0].syncStatus, 'failed');
  assert.match(statusAfterFail.accounts[0].lastError, /1012|Token has expired/);

  // 2. User adds valid Yodlee account (1712970) with replaceFailedAccounts: true
  const added = store.addPortfolioAccount(user, {
    label: 'Yodlee',
    ibkrFlexToken: 'SYNTHETIC_VALID_YODLEE_TOKEN',
    ibkrFlexQueryId: '1712970',
    replaceFailedAccounts: true,
  });
  assert.equal(added.accountCount, 1);
  assert.equal(added.accounts[0].queryId, '1712970');

  clearPortfolioCache(user);
  const synced = await loadPortfolioDashboard({ user, forceRefresh: true });
  assert.equal(synced.connection.status, 'linked');
  assert.equal(synced.holdings[0].ticker, 'NVDA');

  const verifiedStatus = store.readPortfolioConnectionStatus(user);
  assert.equal(verifiedStatus.accounts.length, 1);
  assert.equal(verifiedStatus.accounts[0].syncStatus, 'verified');

  // 3. Rotating token for the same Query ID (1712970) replaces in-place instead of creating a duplicate
  const rotated = store.addPortfolioAccount(user, {
    label: 'Yodlee Renewed',
    ibkrFlexToken: 'SYNTHETIC_RENEWED_YODLEE_TOKEN',
    ibkrFlexQueryId: '1712970',
  });
  assert.equal(rotated.accountCount, 1);
  assert.equal(rotated.accounts[0].label, 'Yodlee Renewed');

  // 4. Adding a second account ('Zimeng', 1708499) that later expires, then renewing 'Zimeng' with a brand-new IBKR Query ID (1712999) replaces the failed 'Zimeng' card instead of creating 3 accounts!
  store.addPortfolioAccount(user, {
    label: 'Zimeng',
    ibkrFlexToken: 'SYNTHETIC_OLD_ZIMENG_TOKEN',
    ibkrFlexQueryId: '1708499',
  });
  store.writePortfolioAccountSyncStatuses(user, [
    { accountId: store.readPortfolioConnectionStatus(user).accounts.find(a => a.queryId === '1712970').id, queryId: '1712970', ok: true, holdingsCount: 5 },
    { accountId: store.readPortfolioConnectionStatus(user).accounts.find(a => a.queryId === '1708499').id, queryId: '1708499', ok: false, error: 'Error 1025 expired' },
  ]);
  const renewedNewQueryId = store.addPortfolioAccount(user, {
    label: 'Zimeng',
    ibkrFlexToken: 'SYNTHETIC_NEW_ZIMENG_TOKEN',
    ibkrFlexQueryId: '1712999',
  });
  assert.equal(renewedNewQueryId.accountCount, 2);
  assert.deepEqual(
    renewedNewQueryId.accounts.map(a => a.queryId),
    ['1712970', '1712999'],
  );
});

test('loadIbkrFlexXml retries Error 1019 statement generation in progress', async () => {
  let stmtCalls = 0;
  globalThis.fetch = async input => {
    const url = new URL(input);
    if (url.pathname.endsWith('SendRequest')) {
      return {
        ok: true,
        text: async () =>
          '<FlexStatementResponse><Status>Success</Status><ReferenceCode>REF_1019</ReferenceCode></FlexStatementResponse>',
      };
    }
    stmtCalls += 1;
    if (stmtCalls === 1) {
      return {
        ok: true,
        text: async () =>
          '<FlexStatementResponse><Status>Warn</Status><ErrorCode>1019</ErrorCode><ErrorMessage>Statement generation in progress. Please try again shortly.</ErrorMessage></FlexStatementResponse>',
      };
    }
    return {
      ok: true,
      text: async () =>
        '<FlexQueryResponse><FlexStatements><FlexStatement fromDate="20261101" toDate="20261117"/></FlexStatements></FlexQueryResponse>',
    };
  };
  const parsed = await loadIbkrFlexXml('1712970', { ibkrFlexToken: 'SYNTHETIC_TOKEN_1019' });
  assert.equal(stmtCalls, 2);
  assert.ok(parsed.FlexQueryResponse);
});

test('liveRadar diagnostics stay dynamically aligned with scalar gauges and summary/curve flags trim payload weight', () => {
  const dash = loadQqqSchdRotationDashboard({ mode: 'm6', window: 'live_2011' });
  const radar = dash.liveRadar;
  const closeStr = `$${Number(radar.qqqClose).toFixed(2)}`;
  const rightCond = radar.nextTriggers.rightSideTrendBuy.conditions[0].current;
  assert.ok(rightCond.includes(closeStr), `Expected ${rightCond} to include ${closeStr}`);

  const fullRange = analyzeQqqSchdRotationRange({
    mode: 'm6',
    window: 'live_2011',
    snapshotId: dash.snapshotId,
    start: '2020-01-02',
    end: '2024-12-31',
    includeCurve: true,
  });
  const slimRange = analyzeQqqSchdRotationRange({
    mode: 'm6',
    window: 'live_2011',
    snapshotId: dash.snapshotId,
    start: '2020-01-02',
    end: '2024-12-31',
    includeCurve: false,
  });
  assert.ok(fullRange.curve.length > 1000);
  assert.equal(slimRange.curve.length, 0);
  assert.deepEqual(slimRange.metrics, fullRange.metrics);

  const summaryStyles = loadInvestorStyleDashboard({ universe: 'all', summaryOnly: true });
  assert.equal(summaryStyles.summaryOnly, true);
  assert.equal(summaryStyles.backtest, undefined);
  assert.ok(JSON.stringify(summaryStyles).length < 5000);
});
