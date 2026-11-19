import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "portfolio-nav-continuity-test-"));
process.env.USER_PORTFOLIO_DATA_DIR = path.join(root, "users");
process.env.SQLITE_DB_PATH = path.join(root, "research.sqlite");
process.env.PORTFOLIO_CREDENTIALS_KEY = "synthetic-nav-continuity-secret";

const store = await import("./userPortfolioStore.js");
const { loadPortfolioDashboard, clearPortfolioCache } = await import("./portfolioClient.js");
const { analysePortfolio } = await import("./investmentPortfolio.js");
const originalFetch = globalThis.fetch;

test.after(() => {
  globalThis.fetch = originalFetch;
  store.closeUserPortfolioStores();
  fs.rmSync(root, { recursive: true, force: true });
});

function buildEquityRows(pairs) {
  return pairs
    .map(
      ([d, total, cash = 1000]) =>
        `<EquitySummaryByReportDateInBase reportDate="${d.replaceAll("-", "")}" total="${total}" cash="${cash}"/>`
    )
    .join("");
}

test("multi-account sync preserves full older-account NAV curve across new-account addition and IBKR 365d history rate limits", async () => {
  const user = { id: "owner-multi-account-continuity" };
  store.savePortfolioConnection(user, {
    ibkrFlexToken: "TOKEN_LEGACY_123456",
    ibkrFlexQueryId: "1200871",
    label: "IBKR account 1"
  });

  const legacyDates = [
    ["2025-11-14", 310455.63],
    ["2025-11-17", 312100.0],
    ["2025-12-12", 346800.0],
    ["2025-12-15", 347202.09],
    ["2026-11-13", 440990.16],
    ["2026-11-16", 425100.0],
    ["2026-11-17", 416800.0]
  ];
  const secondaryDates = [
    ["2025-12-15", 485.0],
    ["2026-11-13", 78544.28],
    ["2026-11-16", 78527.0],
    ["2026-11-17", 78404.16]
  ];

  // Phase 1: Legacy single account syncs with 365-day history
  globalThis.fetch = async (input) => {
    const url = new URL(input);
    const periodDays = url.searchParams.get("p");
    if (url.pathname.endsWith("SendRequest")) {
      const code = periodDays ? "LEGACY_HIST" : "LEGACY_CUR";
      return {
        ok: true,
        text: async () =>
          `<FlexStatementResponse><Status>Success</Status><ReferenceCode>${code}</ReferenceCode></FlexStatementResponse>`
      };
    }
    const ref = url.searchParams.get("q");
    if (ref === "LEGACY_HIST") {
      return {
        ok: true,
        text: async () =>
          `<FlexQueryResponse><FlexStatements><FlexStatement accountId="U_LEGACY" fromDate="20251114" toDate="20261117" currency="USD">` +
          `<AccountInformation accountId="U_LEGACY" currency="USD"/>` +
          buildEquityRows(legacyDates) +
          `<Trades><Trade tradeID="T1" tradeDate="20251117" symbol="NVDA" assetCategory="STK" currency="USD" fifoPnlRealized="1250"/></Trades>` +
          `<CashTransactions/>` +
          `</FlexStatement></FlexStatements></FlexQueryResponse>`
      };
    }
    return {
      ok: true,
      text: async () =>
        `<FlexQueryResponse><FlexStatements><FlexStatement accountId="U_LEGACY" fromDate="20261117" toDate="20261117" currency="USD">` +
        `<AccountInformation accountId="U_LEGACY" currency="USD"/>` +
        `<EquitySummaryByReportDateInBase reportDate="20261117" total="416800" cash="1000"/>` +
        `<OpenPositions><OpenPosition symbol="NVDA" assetCategory="STK" currency="USD" quantity="1000" markPrice="415.9" positionValue="415900"/></OpenPositions>` +
        `</FlexStatement></FlexStatements></FlexQueryResponse>`
    };
  };

  const phase1 = await loadPortfolioDashboard({ user, forceRefresh: true });
  assert.equal(phase1.connection.status, "linked");
  // Verify all multi-day EquitySummaryByReportDateInBase rows were durably persisted to portfolio_nav_points
  const storedLegacyNav = store.readUserPortfolioNavPoints(user, "U_LEGACY");
  assert.equal(storedLegacyNav.length, legacyDates.length);
  assert.equal(storedLegacyNav[0].date, "2025-11-14");
  assert.equal(storedLegacyNav[0].nav, 310455.63);
  assert.equal(storedLegacyNav.at(-1).nav, 416800); // Exact reportedNav, not approximate holdings sum (416900)

  // Phase 2: User adds a newly funded secondary account (opened/funded 2025-12-14 -> first positive NAV 2025-12-15)
  store.addPortfolioAccount(user, {
    ibkrFlexToken: "TOKEN_SECOND_654321",
    ibkrFlexQueryId: "1712970",
    label: "Zimeng"
  });
  clearPortfolioCache(user);

  globalThis.fetch = async (input) => {
    const url = new URL(input);
    const q = url.searchParams.get("q");
    const periodDays = url.searchParams.get("p");
    if (url.pathname.endsWith("SendRequest")) {
      const code = `${q}_${periodDays ? "HIST" : "CUR"}`;
      return {
        ok: true,
        text: async () =>
          `<FlexStatementResponse><Status>Success</Status><ReferenceCode>${code}</ReferenceCode></FlexStatementResponse>`
      };
    }
    if (q === "1200871_HIST") {
      return {
        ok: true,
        text: async () =>
          `<FlexQueryResponse><FlexStatements><FlexStatement accountId="U_LEGACY" fromDate="20251118" toDate="20261117" currency="USD">` +
          `<AccountInformation accountId="U_LEGACY" currency="USD"/>` +
          buildEquityRows(legacyDates.slice(2)) +
          `<Trades><Trade tradeID="T1" tradeDate="20251212" symbol="NVDA" assetCategory="STK" currency="USD" fifoPnlRealized="1250"/></Trades>` +
          `<CashTransactions/>` +
          `</FlexStatement></FlexStatements></FlexQueryResponse>`
      };
    }
    if (q === "1200871_CUR") {
      return {
        ok: true,
        text: async () =>
          `<FlexQueryResponse><FlexStatements><FlexStatement accountId="U_LEGACY" fromDate="20261117" toDate="20261117" currency="USD">` +
          `<AccountInformation accountId="U_LEGACY" currency="USD"/>` +
          `<EquitySummaryByReportDateInBase reportDate="20261117" total="416800" cash="1000"/>` +
          `<OpenPositions><OpenPosition symbol="NVDA" assetCategory="STK" currency="USD" quantity="1000" markPrice="415.9" positionValue="415900"/></OpenPositions>` +
          `</FlexStatement></FlexStatements></FlexQueryResponse>`
      };
    }
    if (q === "1712970_HIST") {
      return {
        ok: true,
        text: async () =>
          `<FlexQueryResponse><FlexStatements><FlexStatement accountId="U_SECOND" fromDate="20251118" toDate="20261117" currency="USD">` +
          `<AccountInformation accountId="U_SECOND" currency="USD" dateOpened="20251120"/>` +
          `<EquitySummaryByReportDateInBase reportDate="20251212" total="0" cash="0"/>` +
          buildEquityRows(secondaryDates) +
          `<Trades/>` +
          `<CashTransactions><CashTransaction transactionID="DEP1" dateTime="20251214" type="Deposits/Withdrawals" currency="USD" amount="485"/></CashTransactions>` +
          `</FlexStatement></FlexStatements></FlexQueryResponse>`
      };
    }
    return {
      ok: true,
      text: async () =>
        `<FlexQueryResponse><FlexStatements><FlexStatement accountId="U_SECOND" fromDate="20261117" toDate="20261117" currency="USD">` +
        `<AccountInformation accountId="U_SECOND" currency="USD" dateOpened="20251120"/>` +
        `<EquitySummaryByReportDateInBase reportDate="20261117" total="78404.16" cash="404.16"/>` +
        `<OpenPositions><OpenPosition symbol="AAPL" assetCategory="STK" currency="USD" quantity="300" markPrice="260" positionValue="78000"/></OpenPositions>` +
        `</FlexStatement></FlexStatements></FlexQueryResponse>`
    };
  };

  const phase2 = await loadPortfolioDashboard({ user, forceRefresh: true });
  const analysis2 = analysePortfolio(phase2, { asOf: "2026-11-17" });
  const g2 = analysis2.groups[0];
  assert.equal(g2.home.nav.status, "ready");
  // Pre-inception dates (2025-11-14, 2025-11-17, 2025-12-12) MUST be preserved as U_LEGACY + $0!
  assert.deepEqual(
    g2.home.nav.rows.map((r) => r.date),
    ["2025-11-14", "2025-11-17", "2025-12-12", "2025-12-15", "2026-11-13", "2026-11-16", "2026-11-17"]
  );
  assert.equal(g2.home.nav.rows[0].nav, 310455.63);
  assert.equal(Number(g2.home.nav.rows[3].nav.toFixed(2)), 347687.09); // 347202.09 + 485.00

  // Phase 3: Next morning (2026-11-18) sync where IBKR 365-day history queries fail with Error 1018 rate limit!
  clearPortfolioCache(user);
  globalThis.fetch = async (input) => {
    const url = new URL(input);
    const q = url.searchParams.get("q");
    const periodDays = url.searchParams.get("p");
    if (url.pathname.endsWith("SendRequest")) {
      if (periodDays) {
        return {
          ok: true,
          text: async () =>
            `<FlexStatementResponse><Status>Fail</Status><ErrorCode>1015</ErrorCode><ErrorMessage>History query temporarily unavailable.</ErrorMessage></FlexStatementResponse>`
        };
      }
      return {
        ok: true,
        text: async () =>
          `<FlexStatementResponse><Status>Success</Status><ReferenceCode>${q}_DAY</ReferenceCode></FlexStatementResponse>`
      };
    }
    if (q === "1200871_DAY") {
      return {
        ok: true,
        text: async () =>
          `<FlexQueryResponse><FlexStatements><FlexStatement accountId="U_LEGACY" fromDate="20261118" toDate="20261118" currency="USD">` +
          `<AccountInformation accountId="U_LEGACY" currency="USD"/>` +
          `<EquitySummaryByReportDateInBase reportDate="20261118" total="416337.80" cash="1037.80"/>` +
          `<OpenPositions><OpenPosition symbol="NVDA" assetCategory="STK" currency="USD" quantity="1000" markPrice="415.4011" positionValue="415401.10"/></OpenPositions>` +
          `</FlexStatement></FlexStatements></FlexQueryResponse>`
      };
    }
    return {
      ok: true,
      text: async () =>
        `<FlexQueryResponse><FlexStatements><FlexStatement accountId="U_SECOND" fromDate="20261118" toDate="20261118" currency="USD">` +
        `<AccountInformation accountId="U_SECOND" currency="USD" dateOpened="20251120"/>` +
        `<EquitySummaryByReportDateInBase reportDate="20261118" total="78632.90" cash="432.90"/>` +
        `<OpenPositions><OpenPosition symbol="AAPL" assetCategory="STK" currency="USD" quantity="300" markPrice="260.6667" positionValue="78200"/></OpenPositions>` +
        `</FlexStatement></FlexStatements></FlexQueryResponse>`
    };
  };

  const phase3 = await loadPortfolioDashboard({ user, forceRefresh: true });
  const analysis3 = analysePortfolio(phase3, { asOf: "2026-11-18" });
  const g3 = analysis3.groups[0];
  assert.equal(g3.home.nav.status, "ready");
  assert.deepEqual(
    g3.home.nav.rows.map((r) => r.date),
    [
      "2025-11-14",
      "2025-11-17",
      "2025-12-12",
      "2025-12-15",
      "2026-11-13",
      "2026-11-16",
      "2026-11-17",
      "2026-11-18"
    ]
  );
  assert.equal(g3.home.nav.rows[0].nav, 310455.63);
  assert.equal(Number(g3.home.nav.rows.at(-1).nav.toFixed(2)), 494970.7);
  // Ordinary read without contacting broker also preserves all 8 dates and exact NAVs
  clearPortfolioCache(user);
  globalThis.fetch = async () => {
    throw new Error("Ordinary read must not contact IBKR");
  };
  const cachedRead = await loadPortfolioDashboard({ user, includeAnalytics: false });
  const cachedAnalysis = analysePortfolio(cachedRead, { asOf: "2026-11-18" });
  const gCached = cachedAnalysis.groups[0];
  assert.equal(gCached.home.nav.rows.length, 8);
  assert.equal(gCached.home.nav.rows[0].date, "2025-11-14");
  assert.equal(Number(gCached.home.nav.rows.at(-1).nav.toFixed(2)), 494970.7);
});
