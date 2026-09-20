import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

import {
  cusipsFromInformationTable,
  holdingsFromInformationTable,
  informationTableFromSubmissionText,
  parseArgs,
  selectTopCommonLongHoldings
} from "../scripts/build-guru-sec-cusip-manifest.mjs";

test("SEC manifest supports an explicit addition scope without changing its default population", () => {
  const args = ["--output", "/tmp/manifest-test.json", "--generated-at", "2026-09-01T00:00:00Z"];
  assert.equal(parseArgs(args).managerIds, undefined);
  assert.deepEqual(parseArgs([...args, "--include-disabled", "--manager-ids", "william-heard,john-stamas"]).managerIds,
    ["william-heard", "john-stamas"]);
});

test("SEC manifest parser extracts deterministic exact CUSIPs and source identity", () => {
  const xml = `
    <informationTable xmlns="http://www.sec.gov/edgar/document/thirteenf/informationtable">
      <infoTable>
        <nameOfIssuer>  Example   Holdings Inc. </nameOfIssuer>
        <titleOfClass>COM</titleOfClass>
        <cusip>123456789</cusip>
      </infoTable>
      <infoTable>
        <nameOfIssuer>Foreign Example PLC</nameOfIssuer>
        <titleOfClass>SPONSORED ADS</titleOfClass>
        <cusip>g12345678</cusip>
      </infoTable>
      <infoTable>
        <nameOfIssuer>Duplicate Row</nameOfIssuer>
        <titleOfClass>CALL</titleOfClass>
        <cusip>123456789</cusip>
      </infoTable>
    </informationTable>`;

  assert.deepEqual(cusipsFromInformationTable(xml), ["123456789", "G12345678"]);
  assert.deepEqual(holdingsFromInformationTable(xml).map(({ cusip, issuer }) => ({ cusip, issuer })), [
    { cusip: "123456789", issuer: "Duplicate Row" },
    { cusip: "123456789", issuer: "Example Holdings Inc." },
    { cusip: "G12345678", issuer: "Foreign Example PLC" }
  ]);
});

test("SEC manifest selection aggregates duplicate CUSIPs before top-N ranking", () => {
  const selected = selectTopCommonLongHoldings([
    { cusip: "111111111", issuer: "Alpha", title: "COM", putCall: "", shareType: "SH", reportedValue: 40 },
    { cusip: "111111111", issuer: "Alpha A", title: "COM", putCall: "", shareType: "SH", reportedValue: 35 },
    { cusip: "222222222", issuer: "Beta", title: "COM", putCall: "", shareType: "SH", reportedValue: 60 },
    { cusip: "333333333", issuer: "Gamma", title: "CALL", putCall: "CALL", shareType: "SH", reportedValue: 1000 },
    { cusip: "444444444", issuer: "Delta", title: "PRN", putCall: "", shareType: "PRN", reportedValue: 1000 }
  ], 1);

  assert.equal(selected.length, 1);
  assert.equal(selected[0].cusip, "111111111");
  assert.equal(selected[0].reportedValue, 75);
  assert.deepEqual([...selected[0].issuerNames].sort(), ["Alpha", "Alpha A"]);
});

test("SEC manifest parser recovers an information table embedded only in the full submission", () => {
  const submission = `
<DOCUMENT>
<TYPE>13F-HR
<FILENAME>primary_doc.xml
<XML><edgarSubmission /></XML>
</DOCUMENT>
<DOCUMENT>
<TYPE>INFORMATION TABLE
<FILENAME>Q12024-info-table.xml
<XML>
<informationTable>
  <infoTable><nameOfIssuer>Example Inc.</nameOfIssuer><titleOfClass>COM</titleOfClass><cusip>123456789</cusip></infoTable>
</informationTable>
</XML>
</DOCUMENT>`;

  const embedded = informationTableFromSubmissionText(submission);
  assert.equal(embedded.documentName, "Q12024-info-table.xml");
  assert.deepEqual(cusipsFromInformationTable(embedded.xml), ["123456789"]);
  assert.equal(informationTableFromSubmissionText("<DOCUMENT><TYPE>13F-HR</DOCUMENT>"), null);
});

test("SEC manifest builder has no database or derived-cache input option", () => {
  const source = fs.readFileSync(
    new URL("../scripts/build-guru-sec-cusip-manifest.mjs", import.meta.url),
    "utf8"
  );
  assert.doesNotMatch(source, /--(?:guru-)?db|sqlite3|readGuruBacktest|readGuruSnapshot/i);
  assert.match(source, /data\.sec\.gov\/submissions/);
  assert.match(source, /www\.sec\.gov\/Archives\/edgar\/data/);
});

test("committed SEC filing lineage identifies the hashed document body or embedded XML scope", () => {
  const manifest = JSON.parse(fs.readFileSync(
    new URL("./config/guru-sec-cusip-manifest.json", import.meta.url),
    "utf8"
  ));
  for (const filing of manifest.filings) {
    assert.ok(filing.documentName, `${filing.accessionNumber} lacks documentName`);
    assert.match(filing.documentSha256, /^[a-f0-9]{64}$/);
    assert.ok(
      ["document_body", "embedded_information_table_xml"].includes(filing.documentHashScope),
      `${filing.accessionNumber} has an unknown document hash scope`
    );
    if (filing.documentHashScope === "embedded_information_table_xml") {
      assert.match(filing.documentUrl, /\.txt$/i);
      assert.match(filing.documentContainerSha256, /^[a-f0-9]{64}$/);
    } else {
      assert.equal(filing.documentContainerSha256, undefined);
    }
  }

  const peltz2024Q1 = manifest.filings.find(
    (filing) => filing.accessionNumber === "0001345471-24-000018"
  );
  assert.ok(peltz2024Q1);
  assert.equal(peltz2024Q1.documentHashScope, "document_body");
  assert.match(peltz2024Q1.documentUrl, /Q12024-tfmlp-info-table\.xml$/i);
});
