import assert from 'node:assert/strict';
import test from 'node:test';
import {additionIds, validateHistory} from '../scripts/stage-guru-additions.mjs';
import {gurus} from './gurus.js';

const guru = gurus.find(g => g.id === 'michael-cuggino');
const quarter = () => ({reportDate:'2026-06-30',filing:{filerCik:guru.cik,accessionNumber:'0001193125-26-353582'},
  commonLongValue:300,reported13fTableValue:350,holdings:[
    {id:'A-COMMON',shares:10,value:100,pctPortfolio:1/3},
    {id:'B-COMMON',shares:20,value:200,pctPortfolio:2/3},
    {id:'A-PUT',shares:5,value:50,pctPortfolio:0}
  ]});

test('staging is restricted to the four requested configured managers', () => {
  assert.deepEqual(additionIds, ['william-heard','evan-mcgoff','michael-cuggino','john-stamas']);
  for (const id of additionIds) assert.equal(gurus.find(g => g.id === id).type, 'manager13f');
});

test('staging reconciles common weights while retaining excluded source claim values', () => {
  assert.deepEqual(validateHistory(guru, [quarter()]), []);
});

test('staging rejects cross-filer, duplicate, invalid-number and weight/value errors', () => {
  const wrong = quarter(); wrong.filing.filerCik = '0000357298';
  assert.match(validateHistory(guru, [wrong]).join(), /wrong_cik/);
  assert.match(validateHistory(guru, [quarter(),quarter()]).join(), /duplicate_accession/);
  assert.match(validateHistory(guru, [quarter(),quarter()]).join(), /duplicate_quarter/);
  const duplicate = quarter(); duplicate.holdings.push({...duplicate.holdings[0]});
  assert.match(validateHistory(guru, [duplicate]).join(), /duplicate_holding/);
  assert.match(validateHistory(guru, [duplicate]).join(), /weight_total/);
  assert.match(validateHistory(guru, [duplicate]).join(), /reported_value_total/);
  const missing = quarter(); missing.holdings[0].shares = null;
  assert.match(validateHistory(guru, [missing]).join(), /invalid_number/);
});
