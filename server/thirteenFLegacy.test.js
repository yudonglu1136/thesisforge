import assert from 'node:assert/strict';
import test from 'node:test';
import {indexed13fAttachment, parseLegacy13fInformationTable, assertLegacy13fIdentity} from './thirteenFLegacy.js';

const original = (rows, count = rows.length, value = 150) => `<SEC-DOCUMENT>
CONFORMED SUBMISSION TYPE: 13F-HR
<DOCUMENT>
<TYPE>13F-HR
<TEXT>
FORM 13F INFORMATION TABLE
Information Table Entry Total: ${count}
Information Table Value Total: $${value}
<TABLE>
NAME OF ISSUER     TITLE OF CLASS     CUSIP     VALUE (x$1000) SHARES
<S>                <C>                <C>       <C>           <C>
${rows.join('\n')}
</TABLE>
</TEXT>
</DOCUMENT>`;
const alpha = 'ALPHA INC  COM  111111111  100  1,000 SH  SOLE  0  1000  0  0';
const beta = 'BETA INC  CL A  222222222  50  2,000 SH  CALL SOLE  0  2000  0  0';

test('legacy text extracts reported claims without changing units or classifying options as shares', () => {
  const parsed = parseLegacy13fInformationTable(original([alpha, beta]));
  assert.equal(parsed.valueScale, 1000);
  assert.deepEqual(parsed.rows, [
    {nameOfIssuer:'ALPHA INC', titleOfClass:'COM', cusip:'111111111', value:100,
      shrsOrPrnAmt:{sshPrnamt:1000,sshPrnamtType:'SH'},putCall:''},
    {nameOfIssuer:'BETA INC', titleOfClass:'CL A', cusip:'222222222', value:50,
      shrsOrPrnAmt:{sshPrnamt:2000,sshPrnamtType:'SH'},putCall:'CALL'}
  ]);
});

test('legacy parser preserves duplicate source rows for the existing aggregation step', () => {
  assert.equal(parseLegacy13fInformationTable(original([alpha, alpha], 2, 200)).rows.length, 2);
});

test('legacy parser fails closed on amendments, missing units, totals and unreadable rows', () => {
  const good = original([alpha], 1, 100);
  for (const bad of [good.replaceAll('13F-HR', '13F-HR/A'),
    good.replace('(x$1000)', '(unknown)'), original([alpha], 2, 100),
    original([alpha], 1, 101), original([alpha.replace('111111111', '')], 1, 100)]) {
    assert.throws(() => parseLegacy13fInformationTable(bad), /legacy_13f_/);
  }
});

test('blank source class and all-C column markers use existing XML blank-class semantics', () => {
  const text = original([alpha.replace('  COM', '')], 1, 100).replace('<S>', '<C>');
  const row = parseLegacy13fInformationTable(text).rows[0];
  assert.equal(row.nameOfIssuer, 'ALPHA INC');
  assert.equal(row.titleOfClass, '');
});

test('a class word inside an issuer does not consume the actual trailing class', () => {
  const text = original([alpha.replace('ALPHA INC  COM', 'Bldrs Emerging Mkts 50 Adr Ind COM')], 1, 100);
  const row = parseLegacy13fInformationTable(text).rows[0];
  assert.equal(row.nameOfIssuer, 'Bldrs Emerging Mkts 50 Adr Ind');
  assert.equal(row.titleOfClass, 'COM');
});

test('legacy identity uses the actual filer CIK, not the filing-agent accession prefix', () => {
  const identity = {cik:'0001323414',accessionNumber:'0000357298-06-000011',reportDate:'2006-03-31'};
  const text = `<SEC-HEADER>
ACCESSION NUMBER: 0000357298-06-000011
CONFORMED PERIOD OF REPORT: 20060331
CENTRAL INDEX KEY: 0001323414
</SEC-HEADER>`;
  assertLegacy13fIdentity(text, identity);
  for (const patch of [{cik:'0000357298'}, {reportDate:'2006-06-30'}, {accessionNumber:'0000357298-06-000012'}]) {
    assert.throws(() => assertLegacy13fIdentity(text, {...identity,...patch}), /identity_mismatch/);
  }
});

test('SEC filename fallback accepts only the same accession and rejects ambiguous attachments', () => {
  const accession = '0000950123-20-012220';
  assert.equal(indexed13fAttachment(['1642.xml'], accession, '1642.xml'), '1642.xml');
  assert.equal(indexed13fAttachment([`${accession}-1642.xml`], accession, '1642.xml'), `${accession}-1642.xml`);
  assert.equal(indexed13fAttachment(['0000950123-20-000001-1642.xml'], accession, '1642.xml'), '1642.xml');
  assert.throws(() => indexed13fAttachment(['1642.xml', `${accession}-1642.xml`], accession, '1642.xml'), /ambiguous/);
  for (const unsafe of ['../1642.xml', 'a..xml', '/1642.xml', 'https://other.test/1642.xml', '1642.txt', '1642.xml?x=1']) {
    assert.throws(() => indexed13fAttachment([], accession, unsafe), /unsafe/);
  }
});
