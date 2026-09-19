import test from 'node:test';
import assert from 'node:assert/strict';
import {verifyStrategyDocument} from './recover-strategy-books.mjs';
const row=(cusip,title,type,value)=>`<infoTable><nameOfIssuer>Test issuer</nameOfIssuer><titleOfClass>${title}</titleOfClass><cusip>${cusip}</cusip><value>${value}</value><shrsOrPrnAmt><sshPrnamt>10</sshPrnamt><sshPrnamtType>${type}</sshPrnamtType></shrsOrPrnAmt></infoTable>`;
const xml=`<informationTable>${row('037833100','COM','SH',100)}${row('91332UAB7','NOTE 11/1','PRN',200)}</informationTable>`;
const cover=`<edgarSubmission><headerData><submissionType>13F-HR</submissionType><filerInfo><periodOfReport>06-30-2021</periodOfReport><filer><credentials><cik>1</cik></credentials></filer></filerInfo></headerData><formData><coverPage><isAmendment>false</isAmendment><filingManager><name>Test manager</name></filingManager></coverPage><summaryPage><tableEntryTotal>2</tableEntryTotal><tableValueTotal>300</tableValueTotal></summaryPage></formData></edgarSubmission>`;
const identity={reportDate:'2021-06-30',cik:'0000000001'};
test('verify original cover and all lines, exclude debt from common book',()=>{
 const r=verifyStrategyDocument(xml,cover,identity);assert.equal(r.rowCount,2);assert.equal(r.reportedValue,300);assert.equal(r.holdings.length,1);assert.equal(r.holdings[0].cusip,'037833100');
});
test('wrong manager, report period and amendment cannot become verified',()=>{
 assert.throws(()=>verifyStrategyDocument(xml,cover,{...identity,cik:'2'}),/identity_or_period/);
 assert.throws(()=>verifyStrategyDocument(xml,cover,{...identity,reportDate:'2021-03-31'}),/identity_or_period/);
 assert.throws(()=>verifyStrategyDocument(xml,cover.replace('13F-HR','13F-HR/A'),identity),/identity_or_period/);
});
test('missing rows, changed amounts and unknown security fields fail closed',()=>{
 assert.throws(()=>verifyStrategyDocument(xml,cover.replace('<tableEntryTotal>2','<tableEntryTotal>3'),identity),/total_mismatch/);
 assert.throws(()=>verifyStrategyDocument(xml.replace('<value>100','<value>110'),cover,identity),/total_mismatch/);
 assert.throws(()=>verifyStrategyDocument(xml.replace('<sshPrnamtType>SH','<sshPrnamtType>'),cover,identity),/invalid_information_table_fields/);
});
test('bounded whole-unit rounding is recorded without changing holdings',()=>{
 const r=verifyStrategyDocument(xml,cover.replace('<tableValueTotal>300','<tableValueTotal>299'),identity);
 assert.equal(r.coverDifference,1);assert.equal(r.coverRoundingTolerance,1.5);assert.equal(r.holdings[0].value,100);
 assert.throws(()=>verifyStrategyDocument(xml,cover.replace('<tableValueTotal>300','<tableValueTotal>298'),identity),/total_mismatch/);
});
