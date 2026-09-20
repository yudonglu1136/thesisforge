import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import test, { after } from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-sec-filings-test-"));
const databasePath = path.join(tempDir, "sec.sqlite");
fs.closeSync(fs.openSync(databasePath, "w"));
process.env.SQLITE_DB_PATH = databasePath;
process.env.SYNC_BUNDLED_VALUATION_SNAPSHOTS = "false";
process.env.SYNC_BUNDLED_GURU_BACKTESTS = "false";
process.env.SYNC_BUNDLED_DIVIDEND_CALENDAR = "false";
process.env.SYNC_BUNDLED_PODCAST_INSIGHTS = "false";
process.env.PRICE_CACHE_DIR = path.join(tempDir, "prices");
// These fixtures intentionally test the legacy Yahoo refresh/merge contract.
// Keep them isolated from the canonical Sharadar adapter exercised elsewhere.
process.env.FACT_OS_ENABLED = "0";

const {
  aggregate13fHoldings,
  filingsFromRecentShape,
  informationTableFileNamesFromSubmission,
  infer13fValueScale,
  load13fHoldingHistory,
  normalize13fValueScale,
  parse13fInfoTable,
  refreshGuruExposureSnapshot,
  selectManager13fActivityRows,
  withManager13fPublicTradingStatus
} = await import("./secClient.js");
const {
  filterLedgerAuditedPriceRepairPoints,
  readPriceSeriesFromDb,
  readPriceRepairAudit,
  writeAuditedPriceRepair,
  writePriceSeriesToDb
} = await import("./localDatabase.js");
const {
  enforceAdjustedPriceRequirement,
  loadPriceSeries
} = await import("./marketData.js");

after(() => {
  fs.rmSync(tempDir, { recursive: true, force: true });
});

function informationTableXml(rows) {
  const tags = (row) => `
    <infoTable>
      <nameOfIssuer>${row.issuer}</nameOfIssuer>
      <titleOfClass>${row.title}</titleOfClass>
      <cusip>${row.cusip}</cusip>
      <value>${row.value}</value>
      <shrsOrPrnAmt>
        <sshPrnamt>${row.shares}</sshPrnamt>
        <sshPrnamtType>${row.shareType || "SH"}</sshPrnamtType>
      </shrsOrPrnAmt>
      ${row.putCall ? `<putCall>${row.putCall}</putCall>` : ""}
    </infoTable>`;
  return `<?xml version="1.0" encoding="UTF-8"?>
    <informationTable>${rows.map(tags).join("")}</informationTable>`;
}

test("raw SEC submission recovers a typed 13F information table omitted by index.json", () => {
  const submission = `
<DOCUMENT>
<TYPE>13F-HR
<FILENAME>primary_doc.xml
</DOCUMENT>
<DOCUMENT>
<TYPE>INFORMATION TABLE
<FILENAME>Q12024-tfmlp-info-table.xml
</DOCUMENT>`;

  assert.deepEqual(
    informationTableFileNamesFromSubmission(submission),
    ["Q12024-tfmlp-info-table.xml"]
  );
  assert.throws(
    () => informationTableFileNamesFromSubmission(`
      <DOCUMENT>
      <TYPE>INFORMATION TABLE
      <FILENAME>../outside.xml
      </DOCUMENT>`),
    /invalid information-table attachment name/i
  );
});

test("Baupost-style legacy 13F $000 values are scaled once before aggregation", () => {
  const legacyRows = [
    ["ALPHA CORP", "111111111", 12_500, 10_000_000],
    ["BRAVO CORP", "222222222", 20_000, 8_000_000],
    ["CHARLIE CORP", "333333333", 9_000, 6_000_000],
    ["DELTA CORP", "444444444", 15_000, 5_000_000],
    ["ECHO CORP", "555555555", 8_000, 4_000_000]
  ].map(([issuer, cusip, value, shares]) => ({
    id: `${cusip}-COMMON`,
    issuer,
    title: "COM",
    cusip,
    putCall: "",
    reportedValue: value,
    value,
    shares,
    shareType: "SH"
  }));

  assert.equal(infer13fValueScale(legacyRows), 1000);
  const normalized = normalize13fValueScale(legacyRows);
  assert.deepEqual(normalized.map((row) => row.valueScale), [1000, 1000, 1000, 1000, 1000]);
  assert.equal(normalized[0].reportedValue, 12_500);
  assert.equal(normalized[0].value, 12_500_000);

  const parsed = parse13fInfoTable(informationTableXml(legacyRows));
  assert.equal(parsed.length, 5);
  assert.equal(parsed[0].reportedValue, 12_500);
  assert.equal(parsed[0].value, 12_500_000);
  assert.equal(parsed[0].valueScale, 1000);
  assert.equal(parsed[0].holdingBucket, "common_long");
});

test("Heard EQUITIES titles use the existing unit inference without rescaling dollar filings", () => {
  // Heard 2020 Q4–2021 Q3 uses EQUITIES instead of COM. Its 2021 Q3
  // cover explicitly labels the information-table values as thousands:
  // https://www.sec.gov/Archives/edgar/data/1796409/000179640921000005/xslForm13F_X01/primary_doc.xml
  const rows = [
    ["FICO US", "303250104", 53120, 133490],
    ["TDG US", "893641100", 51097, 81812],
    ["AMT US", "03027X100", 30000, 100000],
    ["BX US", "09260D107", 30000, 300000],
    ["BLK US", "09247X101", 39337, 46900]
  ].map(([issuer, cusip, value, shares]) => ({
    issuer, cusip, value, reportedValue: value, shares,
    title: "EQUITIES", shareType: "SH", putCall: ""
  }));
  assert.equal(infer13fValueScale(rows), 1000);
  const parsed = parse13fInfoTable(informationTableXml(rows));
  assert.equal(parsed[0].reportedValue, 53120);
  assert.equal(parsed[0].value, 53_120_000);
  assert.equal(parsed[0].valueScale, 1000);
  assert.equal(parsed[0].holdingBucket, "common_long");
  const dollarRows = rows.map(row => ({...row, value: row.value * 1000, reportedValue: row.reportedValue * 1000}));
  assert.equal(infer13fValueScale(dollarRows), 1);
  assert.equal(normalize13fValueScale(dollarRows)[0].value, 53_120_000);
  assert.equal(infer13fValueScale(rows.map(row => ({...row, putCall: "PUT"}))), 1);
  assert.equal(infer13fValueScale(rows.slice(0, 4)), 1);
});

test("Trian's latest JHG row keeps its value but is marked non-public for downstream UI", () => {
  const holding = withManager13fPublicTradingStatus(
    "nelson-peltz",
    "2026-06-30",
    {
      issuer: "Janus Henderson Group plc",
      cusip: "G4474Y214",
      ticker: "JHG",
      value: 1_000_000
    }
  );

  assert.equal(holding.value, 1_000_000);
  assert.equal(holding.publicTradingStatus, "private_after_reported_quarter");
  assert.equal(holding.publicReplicable, false);
  assert.equal(holding.publicTrading.syntheticPriceUsed, false);
  assert.match(holding.publicTrading.reasonEn, /Public trading ended/);
  assert.match(holding.publicTrading.reasonZh, /公开交易/);

  assert.deepEqual(
    withManager13fPublicTradingStatus("george-soros", "2026-06-30", {
      cusip: "G4474Y214",
      ticker: "JHG"
    }),
    { cusip: "G4474Y214", ticker: "JHG" }
  );
});

test("Appaloosa-style PUT rows remain outside the common-long book", () => {
  const parsed = parse13fInfoTable(informationTableXml([
    {
      issuer: "APPLE INC",
      title: "COM",
      cusip: "037833100",
      value: 125_000_000,
      shares: 500_000
    },
    {
      issuer: "APPLE INC",
      title: "COM",
      cusip: "037833100",
      value: 80_000_000,
      shares: 320_000,
      putCall: "PUT"
    }
  ]));

  assert.equal(parsed.length, 2);
  assert.deepEqual(parsed.map((row) => row.id), ["037833100-COMMON", "037833100-PUT"]);
  assert.equal(parsed.find((row) => row.putCall === "").holdingBucket, "common_long");
  assert.equal(parsed.find((row) => row.putCall === "PUT").holdingBucket, "option");
});

test("Defender's reported BioTime identity uses the documented continuous Lineage shares", () => {
  const holdings = parse13fInfoTable(informationTableXml([
    {issuer:'BIOTIME INC',title:'COM',cusip:'09066L105',value:4269000,shares:3198000},
    {issuer:'AGEX THERAPEUTICS INC',title:'COM',cusip:'00848H108',value:938000,shares:447000}
  ]));
  assert.equal(holdings.find(h => h.cusip === '09066L105').ticker, 'LCTX');
  assert.equal(holdings.find(h => h.cusip === '09066L105').issuer, 'BIOTIME INC');
  assert.notEqual(holdings.find(h => h.cusip === '00848H108').ticker, 'LCTX');
});

test("Third Point-style non-common claims do not enter common longs", () => {
  const parsed = parse13fInfoTable(informationTableXml([
    {
      issuer: "ORDINARY ISSUER",
      title: "COM",
      cusip: "100000001",
      value: 50_000_000,
      shares: 1_000_000
    },
    {
      issuer: "DEBT ISSUER",
      title: "NOTE 3.750% 5/0",
      cusip: "100000002",
      value: 40_000_000,
      shares: 40_000
    },
    {
      issuer: "PREFERRED ISSUER",
      title: "6.875% CON PFD A",
      cusip: "100000003",
      value: 30_000_000,
      shares: 300_000
    },
    {
      issuer: "WARRANT ISSUER",
      title: "*W EXP 01/16/2030",
      cusip: "100000004",
      value: 20_000_000,
      shares: 2_000_000
    },
    {
      issuer: "PRINCIPAL ISSUER",
      title: "NOTE",
      cusip: "100000005",
      value: 10_000_000,
      shares: 10_000,
      shareType: "PRN"
    }
  ]));

  assert.deepEqual(
    parsed.filter((row) => row.holdingBucket === "common_long").map((row) => row.cusip),
    ["100000001"]
  );
  assert.deepEqual(
    parsed.filter((row) => row.holdingBucket === "other_reported").map((row) => row.cusip),
    ["100000002", "100000003", "100000004", "100000005"]
  );
});

test("duplicate common-long CUSIP rows aggregate value and shares exactly once", () => {
  const parsed = parse13fInfoTable(informationTableXml([
    {
      issuer: "DUPLICATE CORP",
      title: "COM",
      cusip: "200000001",
      value: 15_000_000,
      shares: 300_000
    },
    {
      issuer: "DUPLICATE CORP",
      title: "COM",
      cusip: "200000001",
      value: 10_000_000,
      shares: 200_000
    }
  ]));

  assert.equal(parsed.length, 1);
  assert.equal(parsed[0].value, 25_000_000);
  assert.equal(parsed[0].reportedValue, 25_000_000);
  assert.equal(parsed[0].shares, 500_000);
  assert.equal(parsed[0].sourceRows, 2);
  assert.equal(parsed[0].holdingBucket, "common_long");

  const direct = aggregate13fHoldings([
    { id: "200000001-COMMON", issuer: "DUPLICATE CORP", value: 2, reportedValue: 2, shares: 1 },
    { id: "200000001-COMMON", issuer: "DUPLICATE CORP", value: 3, reportedValue: 3, shares: 4 }
  ]);
  assert.deepEqual(
    direct.map(({ value, reportedValue, shares, sourceRows }) => ({ value, reportedValue, shares, sourceRows })),
    [{ value: 5, reportedValue: 5, shares: 5, sourceRows: 2 }]
  );
});

test("economic placeholder CUSIPs fail before issuer resolution or duplicate aggregation", () => {
  const rows = [
    { issuer: "BERKSHIRE HATHAWAY CLASS B", title: "COM", cusip: "000000nan", value: 49_888_398, shares: 99_233 },
    { issuer: "COSTCO WHSL CORP NEW", title: "COM", cusip: "000000nan", value: 8_000_000, shares: 10_000 }
  ];
  assert.throws(() => parse13fInfoTable(informationTableXml(rows), {
    guruId: "john-stamas", reportDate: "2025-09-30", accessionNumber: "0001766929-25-000005"
  }), (error) => {
    assert.equal(error.code, "invalid_13f_identifier");
    assert.equal(error.sourceRecord.cusip, "000000NAN");
    assert.equal(error.sourceRecord.accessionNumber, "0001766929-25-000005");
    return true;
  });
  for (const cusip of ["000000NAN", "000000000", "NULL", "N/A", "NONE"]) {
    assert.throws(() => aggregate13fHoldings(rows.map((row) => ({
      ...row, cusip, ticker: "COST", id: `${cusip}-COMMON`
    }))), { code: "invalid_13f_identifier" });
  }
  const emptySentinel = parse13fInfoTable(informationTableXml([
    { issuer: "NONE", title: "NONE", cusip: "000000000", value: 0, shares: 0 }
  ]));
  assert.equal(emptySentinel[0].value, 0);
});

test("corrupt 13F holdings and exposure abort instead of silently skipping the quarter", async () => {
  const originalFetch = globalThis.fetch;
  const reportDate = "2025-09-30";
  const accessionNumber = "0001766929-25-000005";
  const xml = informationTableXml([
    { issuer: "COSTCO WHSL CORP NEW", title: "COM", cusip: "000000nan", value: 100, shares: 1 }
  ]);
  globalThis.fetch = async (url) => {
    const sourceUrl = String(url);
    if (sourceUrl.includes("data.sec.gov/submissions/")) {
      return new Response(JSON.stringify({ filings: { recent: {
        form: ["13F-HR"], accessionNumber: [accessionNumber], reportDate: [reportDate],
        filingDate: ["2025-10-29"], acceptanceDateTime: ["2025-10-29T15:36:04.000Z"],
        primaryDocument: ["primary_doc.xml"]
      }, files: [] } }), { status: 200 });
    }
    if (sourceUrl.endsWith("/index.json")) {
      return new Response(JSON.stringify({ directory: { item: [
        { name: "primary_doc.xml", type: "text.gif" },
        { name: "informationTable.xml", type: "text.gif" }
      ] } }), { status: 200 });
    }
    if (sourceUrl.endsWith("/informationTable.xml")) return new Response(xml, { status: 200 });
    throw new Error(`Unexpected test URL: ${sourceUrl}`);
  };
  try {
    await assert.rejects(load13fHoldingHistory({
      id: "john-stamas", type: "manager13f", cik: "0001766929"
    }, { years: 0, limit: 0 }), (error) => {
      assert.equal(error.code, "invalid_13f_identifier");
      assert.equal(error.sourceRecord.reportDate, reportDate);
      assert.equal(error.sourceRecord.accessionNumber, accessionNumber);
      assert.equal(error.sourceRecord.filerCik, "0001766929");
      assert.match(error.sourceRecord.sourceUrl, /176692925000005\/informationTable.xml$/);
      assert.match(error.sourceRecord.sourceSha256, /^[a-f0-9]{64}$/);
      return true;
    });
    await assert.rejects(refreshGuruExposureSnapshot("john-stamas", {
      limit: 40, persist: false
    }), (error) => {
      assert.equal(error.code, "invalid_13f_identifier");
      assert.equal(error.sourceRecord.accessionNumber, accessionNumber);
      assert.match(error.sourceRecord.sourceSha256, /^[a-f0-9]{64}$/);
      return true;
    });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("Renaissance-scale 13F activity represents every action without squeezing out larger positions", () => {
  const actionRows = (action, count, valueOffset) => Array.from({ length: count }, (_, index) => {
    const economicValue = valueOffset - index;
    const currentValue = action === "sold_out"
      ? 0
      : action === "reduced"
        ? economicValue
        : economicValue * 2;
    const previousValue = action === "new"
      ? 0
      : action === "increased"
        ? economicValue
        : economicValue * 2;
    return {
      id: `${action}-${String(index).padStart(3, "0")}`,
      ticker: `${action.slice(0, 2).toUpperCase()}${String(index).padStart(3, "0")}`,
      action,
      value: currentValue,
      previousValue,
      changeShares: currentValue - previousValue
    };
  });
  const activity = [
    ...actionRows("new", 100, 10_000),
    ...actionRows("increased", 100, 9_000),
    ...actionRows("reduced", 100, 8_000),
    ...actionRows("sold_out", 100, 7_000)
  ];

  const selected = selectManager13fActivityRows(activity, { limit: 80 });
  const selectedFromReverse = selectManager13fActivityRows([...activity].reverse(), { limit: 80 });
  const counts = Object.fromEntries(
    ["new", "increased", "reduced", "sold_out"].map((action) => [
      action,
      selected.filter((row) => row.action === action).length
    ])
  );

  assert.equal(selected.length, 80);
  assert.equal(selectManager13fActivityRows(activity, { limit: 1_000 }).length, 80);
  assert.deepEqual(counts, { new: 56, increased: 8, reduced: 8, sold_out: 8 });
  assert.deepEqual(
    selected.map((row) => row.id),
    selectedFromReverse.map((row) => row.id),
    "selection and ordering do not depend on SEC source-row order"
  );
  for (const action of ["increased", "reduced", "sold_out"]) {
    assert.deepEqual(
      selected.filter((row) => row.action === action).map((row) => row.id),
      Array.from({ length: 8 }, (_, index) => `${action}-${String(index).padStart(3, "0")}`),
      `${action} keeps its most economically important rows`
    );
  }
  assert.deepEqual(
    selected.filter((row) => row.action === "new").map((row) => row.id),
    Array.from({ length: 56 }, (_, index) => `new-${String(index).padStart(3, "0")}`),
    "large positions compete globally for capacity after every action receives eight rows"
  );
});

test("manager 13F activity selection reallocates unused category capacity by economic importance", () => {
  const activity = [
    ...Array.from({ length: 90 }, (_, index) => ({
      id: `new-${String(index).padStart(3, "0")}`,
      ticker: `N${String(index).padStart(3, "0")}`,
      action: "new",
      value: 10_000 - index,
      previousValue: 0
    })),
    { id: "exit", ticker: "EXIT", action: "sold_out", value: 0, previousValue: 5_000 },
    { id: "add", ticker: "ADD", action: "increased", value: 4_000, previousValue: 1_000 },
    { id: "trim", ticker: "TRIM", action: "reduced", value: 1_000, previousValue: 3_000 }
  ];

  const selected = selectManager13fActivityRows(activity, { limit: 80 });

  assert.equal(selected.length, 80);
  assert.deepEqual(
    Object.fromEntries(["new", "increased", "reduced", "sold_out"].map((action) => [
      action,
      selected.filter((row) => row.action === action).length
    ])),
    { new: 77, increased: 1, reduced: 1, sold_out: 1 }
  );
  assert.ok(selected.some((row) => row.id === "new-076"));
  assert.ok(!selected.some((row) => row.id === "new-077"));
});

test("Pabrai parser preserves FCAU display identity and audited STLA price alias", () => {
  const [holding] = parse13fInfoTable(informationTableXml([{
    issuer: "FIAT CHRYSLER AUTOMOBILES N",
    title: "COM",
    cusip: "N31738102",
    value: 100_000_000,
    shares: 8_000_000
  }]), {
    guruId: "mohnish-pabrai",
    reportDate: "2019-12-31",
    accessionNumber: "0001549575-20-000002"
  });

  assert.equal(holding.ticker, "FCAU");
  assert.equal(holding.priceSymbol, "STLA");
  assert.equal(holding.priceSymbolAudit.displayTicker, "FCAU");
  assert.equal(holding.priceSymbolAudit.provider, "Sharadar SEP");
  assert.equal(holding.priceSymbolAudit.tickerChangeEffectiveDate, "2021-01-19");
});

test("Pabrai Berkshire malformed CUSIP repair is exact-filing scoped", () => {
  const xml = informationTableXml([{
    issuer: "BERKSHIRE HATHAWAY INC DEL",
    title: "CL B",
    cusip: "84670702",
    value: 6_848_000,
    shares: 47_000
  }]);
  const exact = parse13fInfoTable(xml, {
    guruId: "mohnish-pabrai",
    reportDate: "2016-09-30",
    accessionNumber: "0001549575-16-000021"
  });
  const wrongAccession = parse13fInfoTable(xml, {
    guruId: "mohnish-pabrai",
    reportDate: "2016-09-30",
    accessionNumber: "0001549575-16-000020"
  });

  assert.equal(exact[0].ticker, "BRK.B");
  assert.equal(wrongAccession[0].ticker, "");
  assert.equal(wrongAccession[0].priceSymbol, undefined);
});

test("SEC recent filing normalization retains acceptanceDateTime and amendment state", () => {
  const rows = filingsFromRecentShape({
    form: ["13F-HR", "13F-HR/A"],
    accessionNumber: ["0001", "0002"],
    filingDate: ["2024-05-15", "2024-06-01"],
    acceptanceDateTime: ["2024-05-15T17:31:12.000Z", "2024-06-01T11:00:00.000Z"],
    reportDate: ["2024-03-31", "2024-03-31"],
    primaryDocument: ["original.xml", "amendment.xml"]
  });

  assert.equal(rows[0].acceptanceDateTime, "2024-05-15T17:31:12.000Z");
  assert.equal(rows[0].isAmendment, false);
  assert.equal(rows[1].acceptanceDateTime, "2024-06-01T11:00:00.000Z");
  assert.equal(rows[1].isAmendment, true);
});

test("adjusted close survives the SQLite price cache round trip", () => {
  writePriceSeriesToDb("TEST", [{
    date: "2024-01-02",
    open: 99,
    high: 101,
    low: 98,
    close: 100,
    adjustedClose: 95,
    volume: 1000
  }], "fixture");

  const points = readPriceSeriesFromDb("TEST", "2024-01-01", "2024-01-03");
  assert.equal(points.length, 1);
  assert.equal(points[0].close, 100);
  assert.equal(points[0].adjustedClose, 95);
});

test("a generic cache write cannot inherit adjusted close from an older source", () => {
  writePriceSeriesToDb("NOADJINHERIT", [{
    date: "2024-01-02",
    close: 100,
    adjustedClose: 95
  }], "older-source");
  writePriceSeriesToDb("NOADJINHERIT", [{
    date: "2024-01-02",
    close: 101,
    adjustedClose: null
  }], "newer-source-without-adjustment");

  const points = readPriceSeriesFromDb("NOADJINHERIT", "2024-01-02", "2024-01-02");
  assert.equal(points.length, 1);
  assert.equal(points[0].close, 101);
  assert.equal(points[0].adjustedClose, null);
  assert.equal(points[0].source, "newer-source-without-adjustment");
});

test("audited price repair validates and atomically records exact adjusted rows", () => {
  writePriceSeriesToDb("SPY", [{
    date: "2026-08-28",
    open: 650,
    high: 655,
    low: 645,
    close: 652,
    adjustedClose: 652,
    volume: 50_000_000
  }], "fixture");
  for (const symbol of ["REPAIRA", "REPAIRB", "REPAIRC", "NO-PARTIAL-A", "NO-PARTIAL-B"]) {
    writePriceSeriesToDb(symbol, [{
      date: "2026-08-27",
      open: 10,
      high: 11,
      low: 9,
      close: 10,
      adjustedClose: 10,
      volume: 1000
    }], "fixture");
  }
  writePriceSeriesToDb("REPAIRC", [{
    date: "2026-08-28",
    open: 40,
    high: 42,
    low: 39,
    close: 41,
    volume: 3000
  }], "incomplete-fixture");
  const audit = writeAuditedPriceRepair([
    {
      symbol: "repairb",
      date: "2026-08-28",
      open: 20,
      high: 22,
      low: 19,
      close: 21,
      adjustedClose: 20.5,
      volume: 2000
    },
    {
      symbol: "REPAIRA",
      date: "2026-08-28",
      open: 10,
      high: 11,
      low: 9,
      close: 10.5,
      adjustedClose: 10.25,
      volume: 1000
    },
    {
      symbol: "REPAIRC",
      date: "2026-08-28",
      open: 40.00002,
      high: 42.00002,
      low: 39.00002,
      close: 41.00002,
      adjustedClose: 40.75,
      volume: 3001
    }
  ], {
    provider: "fixture-provider",
    reason: "Restore an independently verified missing trading session.",
    snapshotId: "snap-00000000000000000",
    sourceReference: "Fixture provider request dated 2026-08-28.",
    operator: "node-test",
    affectedGuruIds: ["bill-ackman"]
  });

  assert.equal(audit.rowCount, 3);
  assert.equal(audit.insertedRows, 2);
  assert.equal(audit.completedRows, 1);
  assert.deepEqual(audit.symbols, ["REPAIRA", "REPAIRB", "REPAIRC"]);
  assert.deepEqual(audit.dates, ["2026-08-28"]);
  assert.match(audit.auditId, /^price-repair-/);
  assert.match(audit.payloadSha256, /^[a-f0-9]{64}$/);
  const repaired = readPriceSeriesFromDb("REPAIRA", "2026-08-28", "2026-08-28");
  assert.equal(repaired.length, 1);
  assert.equal(repaired[0].adjustedClose, 10.25);
  assert.equal(repaired[0].source, "audited:fixture-provider");
  const storedAudit = readPriceRepairAudit(audit.auditId);
  assert.equal(storedAudit.snapshotId, "snap-00000000000000000");
  assert.equal(
    storedAudit.policy,
    "insert_missing_or_complete_null_fields_verified_spy_session"
  );
  assert.deepEqual(storedAudit.affectedGuruIds, ["bill-ackman"]);
  assert.deepEqual(
    storedAudit.rows.map((row) => row.symbol),
    ["REPAIRA", "REPAIRB", "REPAIRC"]
  );
  assert.deepEqual(
    storedAudit.beforeRows.map((row) => [row.symbol, row.action]),
    [
      ["REPAIRA", "insert"],
      ["REPAIRB", "insert"],
      ["REPAIRC", "complete-null-fields"]
    ]
  );
  const completed = readPriceSeriesFromDb("REPAIRC", "2026-08-28", "2026-08-28");
  assert.equal(completed[0].close, 41);
  assert.equal(completed[0].adjustedClose, 40.75);
  assert.equal(completed[0].volume, 3000);
  assert.equal(completed[0].source, "audited:fixture-provider");
  assert.equal(filterLedgerAuditedPriceRepairPoints(completed).length, 1);
  assert.equal(filterLedgerAuditedPriceRepairPoints([{
    ...completed[0],
    volume: 3001
  }]).length, 0);

  const failureDb = new DatabaseSync(databasePath);
  failureDb.exec(`
    CREATE TRIGGER abort_test_price_repair
    BEFORE INSERT ON price_points
    WHEN NEW.symbol = 'NO-PARTIAL-B'
    BEGIN
      SELECT RAISE(ABORT, 'forced transaction failure');
    END;
  `);
  failureDb.close();

  assert.throws(() => writeAuditedPriceRepair([
    {
      symbol: "NO-PARTIAL-A",
      date: "2026-08-28",
      open: 30,
      high: 31,
      low: 29,
      close: 30,
      adjustedClose: 30,
      volume: 1000
    },
    {
      symbol: "NO-PARTIAL-B",
      date: "2026-08-28",
      open: 31,
      high: 32,
      low: 30,
      close: 31,
      adjustedClose: 31,
      volume: 2000
    }
  ], {
    provider: "fixture-provider",
    reason: "This database failure must roll back every inserted row.",
    snapshotId: "snap-00000000000000000",
    sourceReference: "Fixture provider request dated 2026-08-28.",
    operator: "node-test",
    affectedGuruIds: ["bill-ackman"]
  }), /forced transaction failure/);
  assert.deepEqual(
    readPriceSeriesFromDb("NO-PARTIAL-A", "2026-08-28", "2026-08-28"),
    []
  );
  assert.deepEqual(
    readPriceSeriesFromDb("NO-PARTIAL-B", "2026-08-28", "2026-08-28"),
    []
  );
});

test("released Sharadar SQLite prices are served without a network request", async () => {
  writePriceSeriesToDb("SHARADARFIXTURE", [
    { date: "2024-01-02", close: 101, adjustedClose: 100 },
    { date: "2024-01-03", close: 102, adjustedClose: 101 }
  ], "sharadar_fact_os_sep");
  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => { fetchCalls += 1; throw new Error("network must not be used"); };
  try {
    const result = await loadPriceSeries("SHARADARFIXTURE", {
      start: "2024-01-02", end: "2024-01-03", requireAdjusted: true,
      expectedTradingDates: ["2024-01-02", "2024-01-03"]
    });
    assert.equal(result.source, "sqlite");
    assert.equal(result.returnBasis, "total_return_adjusted_close");
    assert.equal(result.points.length, 2);
    assert.equal(fetchCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("missing or incomplete released prices fail closed without a provider request", async () => {
  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => { fetchCalls += 1; throw new Error("network must not be used"); };
  try {
    const result = await loadPriceSeries("NOLOCALSHARADAR", {
      start: "2024-01-02", end: "2024-01-03", requireAdjusted: true
    });
    assert.equal(result.source, "unavailable");
    assert.equal(result.failure.code, "adjusted_close_unavailable");
    assert.equal(result.upstreamSource, "sharadar_sqlite");
    assert.equal(fetchCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test.skip("retired legacy chart normalization retains adjusted close for historical test fixtures", () => {
  const points = normalizeYahooChartPoints({
    timestamp: [1704153600],
    indicators: {
      quote: [{
        open: [100], high: [102], low: [99], close: [101], volume: [1234]
      }],
      adjclose: [{ adjclose: [97.5] }]
    }
  }, "TEST");

  assert.equal(points.length, 1);
  assert.equal(points[0].close, 101);
  assert.equal(points[0].adjustedClose, 97.5);
});

test.skip("adjusted-close requirement fails closed when Yahoo omits one or every adjusted row", () => {
  const partialPoints = normalizeYahooChartPoints({
    timestamp: [1704153600, 1704240000],
    indicators: {
      quote: [{ close: [101, 102] }],
      adjclose: [{ adjclose: [97.5, null] }]
    }
  }, "TEST");
  const partial = enforceAdjustedPriceRequirement({
    symbol: "TEST",
    source: "yahoo",
    returnBasis: "unadjusted_close",
    points: partialPoints
  }, {
    start: "2024-01-02",
    end: "2024-01-03",
    requireAdjusted: true
  });
  assert.equal(partial.source, "unavailable");
  assert.equal(partial.returnBasis, "unavailable");
  assert.deepEqual(partial.points, []);
  assert.equal(partial.failure.code, "adjusted_close_unavailable");
  assert.equal(partial.failure.adjustedPointCount, 1);
  assert.equal(partial.observedAdjustedPoints, undefined);

  const intervalAwarePartial = enforceAdjustedPriceRequirement({
    symbol: "TEST",
    source: "yahoo",
    returnBasis: "unadjusted_close",
    points: partialPoints
  }, {
    start: "2024-01-02",
    end: "2024-01-03",
    requireAdjusted: true,
    expectedTradingDates: ["2024-01-02", "2024-01-03"]
  });
  assert.deepEqual(intervalAwarePartial.points, []);
  assert.deepEqual(
    intervalAwarePartial.observedAdjustedPoints.map((point) => point.date),
    ["2024-01-02"]
  );
  assert.equal(intervalAwarePartial.failure.code, "expected_internal_session_gap");
  assert.deepEqual(intervalAwarePartial.failure.missingDates, ["2024-01-03"]);

  const missingPoints = normalizeYahooChartPoints({
    timestamp: [1704153600, 1704240000],
    indicators: { quote: [{ close: [101, 102] }] }
  }, "TEST");
  const missing = enforceAdjustedPriceRequirement({
    symbol: "TEST",
    source: "yahoo",
    returnBasis: "unadjusted_close",
    points: missingPoints
  }, {
    start: "2024-01-02",
    end: "2024-01-03",
    requireAdjusted: true
  });
  assert.equal(missing.source, "unavailable");
  assert.deepEqual(missing.points, []);
  assert.equal(missing.failure.adjustedPointCount, 0);
  assert.match(missing.failure.policy, /fail_closed/);
});

test.skip("loadPriceSeries cannot publish partially adjusted Yahoo history", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({
    ok: true,
    json: async () => ({
      chart: {
        result: [{
          timestamp: [1704153600, 1704240000],
          indicators: {
            quote: [{ close: [101, 102] }],
            adjclose: [{ adjclose: [97.5, null] }]
          }
        }]
      }
    })
  });

  try {
    const series = await loadPriceSeries("ADJMISSFIXTURE", {
      start: "2024-01-02",
      end: "2024-01-03",
      requireAdjusted: true
    });
    assert.equal(series.source, "unavailable");
    assert.equal(series.returnBasis, "unavailable");
    assert.deepEqual(series.points, []);
    assert.equal(series.failure.code, "adjusted_close_unavailable");
    assert.equal(series.failure.observedPointCount, 2);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test.skip("a truncated adjusted SQLite series is refreshed for the requested range", async () => {
  writePriceSeriesToDb("TRUNCATEDFIXTURE", [
    {
      date: "2024-01-02",
      close: 101,
      adjustedClose: 101
    },
    {
      date: "2024-01-03",
      close: 102,
      adjustedClose: 102
    }
  ], "truncated-fixture");

  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    return {
      ok: true,
      json: async () => ({
        chart: {
          result: [{
            timestamp: [1672704000, 1704153600, 1704240000],
            indicators: {
              quote: [{ close: [80, 101, 102] }],
              adjclose: [{ adjclose: [79, 101, 102] }]
            }
          }]
        }
      })
    };
  };

  try {
    const series = await loadPriceSeries("TRUNCATEDFIXTURE", {
      start: "2023-01-01",
      end: "2024-01-03",
      requireAdjusted: true
    });
    assert.equal(fetchCalls, 1);
    assert.equal(series.source, "yahoo+sqlite-merged");
    assert.equal(series.returnBasis, "total_return_adjusted_close");
    assert.equal(series.points[0]?.date, "2023-01-03");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test.skip("an adjusted SQLite series with an internal benchmark-session gap is refreshed", async () => {
  writePriceSeriesToDb("GAPFIXTURE", [
    {
      date: "2024-01-02",
      close: 101,
      adjustedClose: 101
    },
    {
      date: "2024-01-04",
      close: 103,
      adjustedClose: 103
    }
  ], "gap-fixture");

  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    return {
      ok: true,
      json: async () => ({
        chart: {
          result: [{
            timestamp: [1704153600, 1704240000, 1704326400],
            indicators: {
              quote: [{ close: [101, 102, 103] }],
              adjclose: [{ adjclose: [101, 102, 103] }]
            }
          }]
        }
      })
    };
  };

  try {
    const series = await loadPriceSeries("GAPFIXTURE", {
      start: "2024-01-02",
      end: "2024-01-04",
      requireAdjusted: true,
      expectedTradingDates: ["2024-01-02", "2024-01-03", "2024-01-04"]
    });
    assert.equal(fetchCalls, 1);
    assert.equal(series.source, "yahoo+sqlite-merged");
    assert.deepEqual(series.points.map((point) => point.date), [
      "2024-01-02",
      "2024-01-03",
      "2024-01-04"
    ]);

    globalThis.fetch = async () => {
      throw new Error("complete SQLite history should not refetch");
    };
    const cached = await loadPriceSeries("GAPFIXTURE", {
      start: "2024-01-02",
      end: "2024-01-04",
      requireAdjusted: true,
      expectedTradingDates: ["2024-01-02", "2024-01-03", "2024-01-04"]
    });
    assert.equal(cached.source, "sqlite");
    assert.equal(cached.points.length, 3);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test.skip("a fresh provider internal-session gap is retried once with provider rows only", async () => {
  writePriceSeriesToDb("RETRYFIXTURE", [
    { date: "2024-01-02", close: 101, adjustedClose: 101 },
    { date: "2024-01-03", close: 999, adjustedClose: 999 },
    { date: "2024-01-04", close: 103, adjustedClose: 103 }
  ], "unledgered-stale-row");

  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    const retry = fetchCalls === 2;
    return {
      ok: true,
      json: async () => ({
        chart: {
          result: [{
            timestamp: retry
              ? [1704240000]
              : [1704153600, 1704326400],
            indicators: {
              quote: [{ close: retry ? [102] : [101, 103] }],
              adjclose: [{ adjclose: retry ? [102] : [101, 103] }]
            }
          }]
        }
      })
    };
  };

  try {
    const series = await loadPriceSeries("RETRYFIXTURE", {
      start: "2023-01-01",
      end: "2024-01-04",
      requireAdjusted: true,
      expectedTradingDates: ["2024-01-02", "2024-01-03", "2024-01-04"]
    });
    assert.equal(fetchCalls, 2);
    assert.equal(series.providerAttempts, 2);
    assert.deepEqual(series.expectedInternalSessionRetry, {
      attempted: true,
      initialMissingDates: ["2024-01-03"],
      remainingMissingDates: [],
      alternateHostAttempted: true,
      alternateHost: "query1.finance.yahoo.com"
    });
    assert.deepEqual(series.points.map((point) => point.date), [
      "2024-01-02",
      "2024-01-03",
      "2024-01-04"
    ]);
    assert.equal(series.points[1].adjustedClose, 102);
    assert.equal(
      readPriceSeriesFromDb("RETRYFIXTURE", "2024-01-03", "2024-01-03")[0].source,
      "yahoo"
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test.skip("an incomplete primary Yahoo response uses exact rows from the alternate Yahoo chart host", async () => {
  const originalFetch = globalThis.fetch;
  const requestedHosts = [];
  globalThis.fetch = async (url) => {
    const hostname = new URL(url).hostname;
    requestedHosts.push(hostname);
    const alternate = hostname === "query1.finance.yahoo.com";
    return {
      ok: true,
      json: async () => ({
        chart: {
          result: [{
            timestamp: alternate
              ? [1704240000, 1704326400]
              : [1704153600, 1704326400],
            indicators: {
              quote: [{ close: alternate ? [102, 999] : [101, 103] }],
              adjclose: [{ adjclose: alternate ? [102, 999] : [101, 103] }]
            }
          }]
        }
      })
    };
  };

  try {
    const series = await loadPriceSeries("ALTERNATEHOSTFIXTURE", {
      start: "2023-01-01",
      end: "2024-01-04",
      requireAdjusted: true,
      expectedTradingDates: ["2024-01-02", "2024-01-03", "2024-01-04"]
    });
    assert.deepEqual(requestedHosts, [
      "query2.finance.yahoo.com",
      "query1.finance.yahoo.com"
    ]);
    assert.equal(series.providerAttempts, 2);
    assert.deepEqual(series.providerHosts, [
      "query2.finance.yahoo.com",
      "query1.finance.yahoo.com"
    ]);
    assert.equal(series.source, "yahoo+sqlite-merged");
    assert.equal(series.returnBasis, "total_return_adjusted_close");
    assert.deepEqual(series.expectedInternalSessionRetry, {
      attempted: true,
      initialMissingDates: ["2024-01-03"],
      remainingMissingDates: [],
      alternateHostAttempted: true,
      alternateHost: "query1.finance.yahoo.com"
    });
    assert.deepEqual(series.points.map((point) => point.date), [
      "2024-01-02",
      "2024-01-03",
      "2024-01-04"
    ]);
    assert.equal(series.points[1].adjustedClose, 102);
    assert.equal(series.points[2].adjustedClose, 103);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test.skip("a transient Yahoo transport failure is retried without weakening adjusted-price checks", async () => {
  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    if (fetchCalls === 1) {
      return {
        ok: false,
        status: 503,
        headers: { get: (name) => name.toLowerCase() === "retry-after" ? "0" : null }
      };
    }
    return {
      ok: true,
      json: async () => ({
        chart: {
          result: [{
            timestamp: [1704153600, 1704240000, 1704326400],
            indicators: {
              quote: [{ close: [101, 102, 103] }],
              adjclose: [{ adjclose: [101, 102, 103] }]
            }
          }]
        }
      })
    };
  };

  try {
    const series = await loadPriceSeries("TRANSPORTRETRYFIXTURE", {
      start: "2024-01-02",
      end: "2024-01-04",
      requireAdjusted: true,
      expectedTradingDates: ["2024-01-02", "2024-01-03", "2024-01-04"]
    });
    assert.equal(fetchCalls, 2);
    assert.equal(series.providerAttempts, 2);
    assert.equal(series.source, "yahoo+sqlite-merged");
    assert.equal(series.returnBasis, "total_return_adjusted_close");
    assert.equal(series.failure, undefined);
    assert.deepEqual(series.points.map((point) => point.date), [
      "2024-01-02",
      "2024-01-03",
      "2024-01-04"
    ]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test.skip("exhausted Yahoo transport retries still fail closed with auditable attempt metadata", async () => {
  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    return {
      ok: false,
      status: 503,
      headers: { get: (name) => name.toLowerCase() === "retry-after" ? "0" : null }
    };
  };

  try {
    const series = await loadPriceSeries("TRANSPORTFAILFIXTURE", {
      start: "2024-01-02",
      end: "2024-01-04",
      requireAdjusted: true,
      expectedTradingDates: ["2024-01-02", "2024-01-03", "2024-01-04"]
    });
    assert.equal(fetchCalls, 3);
    assert.equal(series.providerAttempts, 3);
    assert.equal(series.source, "unavailable");
    assert.equal(series.returnBasis, "unavailable");
    assert.deepEqual(series.points, []);
    assert.equal(series.failure.code, "adjusted_close_unavailable");
    assert.deepEqual(series.providerFailure, {
      code: "yahoo_transport_unavailable",
      status: 503,
      retryable: true,
      attempts: 3,
      message: "Yahoo chart failed 503 for TRANSPORTFAILFIXTURE"
    });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test.skip("an audited SQLite point is merged after an upstream IPO-range refresh", async () => {
  writePriceSeriesToDb("SPY", [
    { date: "2024-01-02", close: 470, adjustedClose: 470 },
    { date: "2024-01-03", close: 471, adjustedClose: 471 },
    { date: "2024-01-04", close: 472, adjustedClose: 472 }
  ], "fixture");
  writePriceSeriesToDb("AUDMERGE", [
    {
      date: "2024-01-02",
      open: 100,
      high: 102,
      low: 99,
      close: 101,
      adjustedClose: 101,
      volume: 1000
    },
    {
      date: "2024-01-04",
      open: 102,
      high: 104,
      low: 101,
      close: 103,
      adjustedClose: 103,
      volume: 1200
    }
  ], "old-yahoo-cache");
  writeAuditedPriceRepair([{
    symbol: "AUDMERGE",
    date: "2024-01-03",
    open: 101,
    high: 103,
    low: 100,
    close: 102,
    adjustedClose: 102,
    volume: 1100
  }], {
    provider: "fixture-provider",
    reason: "Restore the independently verified missing internal session.",
    snapshotId: "snap-00000000000000000",
    sourceReference: "Fixture provider request dated 2024-01-03.",
    operator: "node-test",
    affectedGuruIds: ["bill-ackman"]
  });

  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    return {
      ok: true,
      json: async () => ({
        chart: {
          result: [{
            timestamp: [1704153600, 1704326400],
            indicators: {
              quote: [{ close: [101, 103] }],
              adjclose: [{ adjclose: [101, 103] }]
            }
          }]
        }
      })
    };
  };

  try {
    const series = await loadPriceSeries("AUDMERGE", {
      start: "2023-01-01",
      end: "2024-01-04",
      requireAdjusted: true,
      expectedTradingDates: ["2024-01-02", "2024-01-03", "2024-01-04"]
    });
    assert.equal(fetchCalls, 2);
    assert.equal(series.source, "yahoo+sqlite-merged");
    assert.equal(series.cache, "refreshed-merged");
    assert.deepEqual(series.points.map((point) => point.date), [
      "2024-01-02",
      "2024-01-03",
      "2024-01-04"
    ]);
    assert.equal(series.points[1].source, "audited:fixture-provider");

    globalThis.fetch = async () => {
      throw new Error("the merged JSON cache should satisfy the second request");
    };
    const cached = await loadPriceSeries("AUDMERGE", {
      start: "2023-01-01",
      end: "2024-01-04",
      requireAdjusted: true,
      expectedTradingDates: ["2024-01-02", "2024-01-03", "2024-01-04"]
    });
    assert.equal(cached.cache, "hit");
    assert.equal(fetchCalls, 2);
    assert.equal(
      readPriceSeriesFromDb("AUDMERGE", "2024-01-03", "2024-01-03")[0].source,
      "audited:fixture-provider"
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test.skip("an unledgered stale SQLite point cannot fill a fresh upstream gap", async () => {
  writePriceSeriesToDb("UNTRUSTEDMERGEFIXTURE", [
    { date: "2024-01-02", close: 101, adjustedClose: 101 },
    { date: "2024-01-03", close: 102, adjustedClose: 102 },
    { date: "2024-01-04", close: 103, adjustedClose: 103 }
  ], "old-yahoo-cache");

  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    return {
      ok: true,
      json: async () => ({
        chart: {
          result: [{
            timestamp: [1704153600, 1704326400],
            indicators: {
              quote: [{ close: [101, 103] }],
              adjclose: [{ adjclose: [101, 103] }]
            }
          }]
        }
      })
    };
  };

  try {
    const series = await loadPriceSeries("UNTRUSTEDMERGEFIXTURE", {
      start: "2023-01-01",
      end: "2024-01-04",
      requireAdjusted: true,
      expectedTradingDates: ["2024-01-02", "2024-01-03", "2024-01-04"]
    });
    assert.equal(fetchCalls, 2);
    assert.equal(series.source, "unavailable");
    assert.equal(series.upstreamSource, "yahoo");
    assert.equal(series.returnBasis, "unavailable");
    assert.deepEqual(series.points, []);
    assert.deepEqual(
      series.observedAdjustedPoints.map((point) => point.date),
      ["2024-01-02", "2024-01-04"]
    );
    assert.equal(series.failure.code, "expected_internal_session_gap");
    assert.equal(
      series.failure.policy,
      "fail_closed_after_dual_host_provider_retry_without_unledgered_db_fill"
    );
    assert.equal(series.failure.providerAttempts, 2);
    assert.deepEqual(series.failure.missingDates, ["2024-01-03"]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test.skip("a fresh upstream row without adjusted close cannot inherit a stale DB value", async () => {
  writePriceSeriesToDb("FRESHNULL", [{
    date: "2024-01-02",
    close: 101,
    adjustedClose: 99
  }], "old-yahoo-cache");

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({
    ok: true,
    json: async () => ({
      chart: {
        result: [{
          timestamp: [1704153600],
          indicators: {
            quote: [{ close: [101] }],
            adjclose: [{ adjclose: [null] }]
          }
        }]
      }
    })
  });

  try {
    const series = await loadPriceSeries("FRESHNULL", {
      start: "2023-01-01",
      end: "2024-01-02",
      requireAdjusted: true
    });
    assert.equal(series.source, "unavailable");
    assert.equal(series.returnBasis, "unavailable");
    assert.deepEqual(series.points, []);
    assert.equal(series.failure.adjustedPointCount, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test.skip("a rejected Yahoo refresh cannot poison the next adjusted-price call", async () => {
  writePriceSeriesToDb("FRESHNULLTWICE", [{
    date: "2024-01-10",
    close: 110,
    adjustedClose: 90
  }], "old-yahoo-cache");

  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    return {
      ok: true,
      json: async () => ({
        chart: {
          result: [{
            timestamp: [1704153600, 1704844800],
            indicators: {
              quote: [{ close: [100, 110] }],
              adjclose: [{ adjclose: [100, null] }]
            }
          }]
        }
      })
    };
  };

  const request = {
    start: "2024-01-01",
    end: "2024-01-10",
    requireAdjusted: true
  };

  try {
    const first = await loadPriceSeries("FRESHNULLTWICE", request);
    const second = await loadPriceSeries("FRESHNULLTWICE", request);

    for (const series of [first, second]) {
      assert.equal(series.source, "unavailable");
      assert.equal(series.returnBasis, "unavailable");
      assert.deepEqual(series.points, []);
      assert.equal(series.failure.code, "adjusted_close_unavailable");
      assert.equal(series.failure.adjustedPointCount, 1);
    }
    assert.equal(fetchCalls, 2);
    assert.deepEqual(
      readPriceSeriesFromDb("FRESHNULLTWICE", "2024-01-01", "2024-01-10")
        .map((point) => [point.date, point.adjustedClose, point.source]),
      [["2024-01-10", 90, "old-yahoo-cache"]]
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test.skip("fully adjusted delisted history can defer endpoint coverage to active-holding checks", () => {
  const payload = {
    symbol: "DELISTED",
    source: "yahoo",
    returnBasis: "total_return_adjusted_close",
    points: [
      { date: "2024-01-02", close: 100, adjustedClose: 100 },
      { date: "2024-01-03", close: 101, adjustedClose: 101 }
    ]
  };
  const securitySeries = enforceAdjustedPriceRequirement(payload, {
    start: "2024-01-02",
    end: "2024-02-01",
    requireAdjusted: true
  });
  assert.equal(securitySeries.source, "yahoo");
  assert.equal(securitySeries.points.length, 2);

  const benchmarkSeries = enforceAdjustedPriceRequirement(payload, {
    start: "2024-01-02",
    end: "2024-02-01",
    requireAdjusted: true,
    requireFullRange: true
  });
  assert.equal(benchmarkSeries.source, "unavailable");
  assert.equal(benchmarkSeries.failure.requireFullRange, true);
  assert.equal(benchmarkSeries.failure.rangeCovered, false);
});
