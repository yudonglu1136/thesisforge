import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {analysePortfolio} from './investmentPortfolio.js';
import {portfolioPassiveIncome} from './portfolioIncome.js';
import {reportAnalysisAccounts} from './portfolioReport.js';
import {portfolioMarketContext} from './portfolioRisk.js';
import {
  addPortfolioAccount,
  removePortfolioAccount,
  readPortfolioConnectionStatus,
} from './userPortfolioStore.js';

test('analysePortfolio exposes costBasis, avgCost, unrealizedPnl, unrealizedPct, accountNumbers and accountMeta', () => {
  const payload = {
    source: {userScoped: true, mode: 'multi_account_live'},
    connection: {status: 'linked'},
    analysisAccounts: [
      {
        accountId: 'U1111111',
        label: 'Main Margin',
        currency: 'USD',
        reportDate: '2026-11-17',
        reportedNav: 12000,
        positions: [
          {
            ticker: 'NVDA',
            name: 'NVIDIA CORP',
            assetCategory: 'STK',
            currency: 'USD',
            quantity: 20,
            price: 150,
            localValue: 3000,
            costBasisMoney: 2000,
            fxRateToBase: 1,
          },
        ],
      },
      {
        accountId: 'U2222222',
        label: 'IRA Account',
        currency: 'USD',
        reportDate: '2026-11-17',
        reportedNav: 8000,
        positions: [
          {
            ticker: 'NVDA',
            name: 'NVIDIA CORP',
            assetCategory: 'STK',
            currency: 'USD',
            quantity: 10,
            price: 150,
            localValue: 1500,
            costBasisMoney: 1300,
            fxRateToBase: 1,
          },
        ],
      },
    ],
  };

  const result = analysePortfolio(payload, {asOf: '2026-11-17'});
  assert.equal(result.status, 'ready');
  const usd = result.groups[0];
  assert.equal(usd.accountCount, 2);
  assert.equal(usd.accountMeta.length, 2);
  assert.equal(usd.accountMeta[0].label, 'Main Margin');
  assert.equal(usd.accountMeta[1].label, 'IRA Account');

  const nvda = usd.positions.find((p) => p.ticker === 'NVDA');
  assert.ok(nvda);
  assert.deepEqual(nvda.accountNumbers, [1, 2]);
  assert.equal(nvda.quantity, 30);
  assert.equal(nvda.costBasis, 3300);
  assert.equal(nvda.avgCost, 110);
  assert.equal(nvda.unrealizedPnl, 1200);
  assert.ok(Math.abs(nvda.unrealizedPct - 1200 / 3300) < 1e-9);
});

test('portfolioPassiveIncome exposes totalConfirmedNet and pendingShortPuts collateral & premium', () => {
  const flex = {
    FlexStatement: {
      accountId: 'U8888888',
      fromDate: '20260101',
      toDate: '20260331',
      AccountInformation: {currency: 'USD', primaryEmail: 'synthetic@example.test'},
      CashTransactions: {
        CashTransaction: [
          {
            transactionID: 'DIV1',
            type: 'Dividends',
            amount: 200,
            symbol: 'QQQ',
            currency: 'USD',
            fxRateToBase: 1,
            dateTime: '20260215;120000',
          },
          {
            transactionID: 'TAX1',
            type: 'Withholding Tax',
            amount: -30,
            symbol: 'QQQ',
            currency: 'USD',
            fxRateToBase: 1,
            dateTime: '20260215;120000',
          },
        ],
      },
      Trades: {
        Trade: [
          {
            tradeID: 'CALL1',
            assetCategory: 'OPT',
            symbol: 'PLTR  260220C00250000',
            description: 'PLTR 20FEB26 250 C',
            transactionType: 'BookTrade',
            openCloseIndicator: 'C',
            buySell: 'BUY',
            quantity: 1,
            tradePrice: 0,
            proceeds: 0,
            tradeDate: '20260220',
            expiry: '20260220',
            strike: 250,
            fifoPnlRealized: 140,
            currency: 'USD',
            fxRateToBase: 1,
          },
        ],
      },
      OpenPosition: [
        {
          symbol: 'NVDA  260417P00120000',
          description: 'NVDA 17APR26 120 P',
          assetCategory: 'OPT',
          currency: 'USD',
          quantity: -2,
          markPrice: 1.5,
          positionValue: -300,
          costBasisMoney: -560,
          strike: 120,
          expiry: '20260417',
          multiplier: 100,
        },
      ],
    },
  };
  const accs = reportAnalysisAccounts(flex);
  const passive = portfolioPassiveIncome(accs, 'USD');
  assert.equal(passive.status, 'ready');
  assert.equal(passive.totalConfirmed, 340); // 200 gross + 140 call
  assert.equal(passive.totalConfirmedNet, 310); // 170 net dividend + 140 call
  assert.equal(passive.pendingShortPuts.count, 1);
  assert.equal(passive.pendingShortPuts.totalContracts, 2);
  assert.equal(passive.pendingShortPuts.collectedPremium, 560);
  assert.equal(passive.pendingShortPuts.collateralExposure, 24000);
});

test('portfolioMarketContext computes ready risk metrics from provided Fact OS priceSeries when SQLite price_points is empty', () => {
  const db = new DatabaseSync(':memory:');
  db.exec(`
    CREATE TABLE price_points(symbol TEXT, date TEXT, close REAL, adjusted_close REAL, source TEXT);
    CREATE TABLE valuation_pit_model_runs(
      ticker TEXT, as_of_date TEXT, fiscal_period TEXT, model_version TEXT,
      financial_available_at TEXT, guidance_max_observed_at TEXT, input_json TEXT, output_json TEXT
    );
    CREATE TABLE valuation_ticker_snapshots(ticker TEXT PRIMARY KEY, payload_json TEXT);
  `);
  const dates = Array.from({length: 80}, (_, idx) => {
    const dt = new Date(Date.UTC(2026, 5, 1 + idx));
    return dt.toISOString().slice(0, 10);
  });
  const spyPoints = dates.map((date, idx) => ({date, adjustedClose: 500 * (1 + idx * 0.001)}));
  const nvdaPoints = dates.map((date, idx) => ({date, adjustedClose: 100 * (1 + idx * 0.002)}));
  const priceSeries = new Map([
    ['SPY', spyPoints],
    ['NVDA', nvdaPoints],
  ]);
  const source = {db};
  const payload = {
    analysisAccounts: [
      {currency: 'USD', navHistory: []},
    ],
  };
  const analysis = {
    groups: [
      {
        currency: 'USD',
        longValue: 10000,
        grossExposure: 10000,
        reportedNav: 10000,
        cash: 0,
        positions: [
          {ticker: 'NVDA', kind: 'equity', currency: 'USD', quantity: 100, value: 10000},
        ],
      },
    ],
  };
  const out = portfolioMarketContext(source, analysis, payload, dates.at(-1), {
    priceSeries,
    spyUniverse: {generatedAt: '2099-01-01', companies: []},
  });
  assert.equal(out.groups[0].risk.status, 'ready');
  assert.equal(out.groups[0].risk.observations ?? out.groups[0].risk.metrics.observations, 79);
  db.close();
});

test('removePortfolioAccount removes a single IBKR query while preserving remaining linked accounts', () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'm5-portfolio-store-'));
  const prevRoot = process.env.USER_DATA_DIR;
  const prevKey = process.env.PORTFOLIO_CREDENTIALS_KEY;
  process.env.USER_DATA_DIR = tempRoot;
  process.env.PORTFOLIO_CREDENTIALS_KEY =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  try {
    const user = {id: '00000000-0000-4000-8000-000000000555'};
    addPortfolioAccount(user, {
      label: 'Primary IBKR',
      ibkrFlexQueryId: '111111',
      ibkrFlexToken: 'secret-token-111111-valid',
    });
    addPortfolioAccount(user, {
      label: 'Secondary IBKR',
      ibkrFlexQueryId: '222222',
      ibkrFlexToken: 'secret-token-222222-valid',
    });
    assert.equal(readPortfolioConnectionStatus(user).accounts.length, 2);

    const afterRemove = removePortfolioAccount(user, '111111');
    assert.equal(afterRemove.accounts.length, 1);
    assert.equal(afterRemove.accounts[0].queryId, '222222');
  } finally {
    if (prevRoot === undefined) {
      delete process.env.USER_DATA_DIR;
    } else {
      process.env.USER_DATA_DIR = prevRoot;
    }
    if (prevKey === undefined) {
      delete process.env.PORTFOLIO_CREDENTIALS_KEY;
    } else {
      process.env.PORTFOLIO_CREDENTIALS_KEY = prevKey;
    }
    fs.rmSync(tempRoot, {recursive: true, force: true});
  }
});
