import assert from "node:assert/strict";
import test from "node:test";

import {
  londonMarketTicker,
  marketTickerCandidates,
  portfolioDisplayTicker,
  valuationTickerCandidates,
  valuationLookupKeysForSnapshot,
  valuationMarketPriceSymbol
} from "./tickerAliases.js";

test("IBKR-style London tickers normalize to dot-L display symbols", () => {
  assert.equal(portfolioDisplayTicker("LSEGL"), "LSEG.L");
  assert.equal(portfolioDisplayTicker("AZNL"), "AZN.L");
  assert.equal(portfolioDisplayTicker("DGEL", { currency: "GBP" }), "DGE.L");
  assert.equal(portfolioDisplayTicker("HSBA", { currency: "GBP" }), "HSBA.L");
  assert.equal(portfolioDisplayTicker("GOOGL", { currency: "USD" }), "GOOGL");
  assert.deepEqual(marketTickerCandidates("GOOGL", { currency: "USD" }), ["GOOGL"]);
});

test("London aliases resolve to local valuation snapshot keys", () => {
  assert.deepEqual(valuationTickerCandidates("LSEGL").slice(0, 3), [
    "LSEGL",
    "LSEG",
    "LSEG.L"
  ]);
  assert.deepEqual(valuationTickerCandidates("LSEG.L").slice(0, 2), ["LSEG.L", "LSEG"]);
  assert.deepEqual(valuationTickerCandidates("AZNL").slice(0, 3), ["AZNL", "AZN", "AZN.L"]);
});

test("GBP valuation snapshots expose London aliases without mapping US names accidentally", () => {
  assert.deepEqual(
    valuationLookupKeysForSnapshot({ ticker: "LSEG", currency: "GBP", name: "London Stock Exchange Group" }),
    ["LSEG", "LSEG.L", "LSEGL"]
  );
  assert.deepEqual(
    valuationLookupKeysForSnapshot({ ticker: "GOOGL", currency: "USD", name: "Alphabet" }),
    ["GOOGL"]
  );
});

test("market data keeps canonical London aliases", () => {
  assert.equal(londonMarketTicker("LSEGL"), "LSEG.L");
  assert.deepEqual(marketTickerCandidates("AZNL"), ["AZN.L", "AZNL", "AZN"]);
});

test("valuation models map London issuers to the stored local-market price symbol", () => {
  assert.equal(valuationMarketPriceSymbol("AZN"), "AZN.L");
  assert.equal(valuationMarketPriceSymbol("LSEG"), "LSEG.L");
  assert.equal(valuationMarketPriceSymbol("BA.L"), "BA.L");
  assert.equal(valuationMarketPriceSymbol("DGE.L"), "DGE.L");
  assert.equal(valuationMarketPriceSymbol("GOOGL"), "GOOGL");
});
