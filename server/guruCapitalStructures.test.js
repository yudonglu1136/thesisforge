import test from 'node:test';
import assert from 'node:assert/strict';
import { gurus } from './gurus.js';
import { assertCapitalStructureCoverage, guruCapitalStructure } from './guruCapitalStructures.js';

const managers=gurus.filter(g=>g.type==='manager13f');
const ids=category=>managers.filter(g=>guruCapitalStructure(g).category===category).map(g=>g.id).sort();

test('every manager 13F has an explicit conservative capital-structure class',()=>{
  assert.equal(managers.length,33);
  assert.equal(assertCapitalStructureCoverage(gurus),true);
  assert.deepEqual(ids('permanent'),['chamath-palihapitiya','george-soros','tom-gayner','warren-buffett']);
  assert.deepEqual(ids('mixed'),['baillie-gifford','bill-ackman']);
  assert.deepEqual(ids('owner_controlled'),['david-tepper','stanley-druckenmiller']);
  assert.deepEqual(ids('archived'),['nick-sleep-qais-zakaria']);
  assert.equal(ids('external_client').length,24);
});

test('family and mixed pools are never presented as strict permanent capital',()=>{
  for(const category of ['mixed','owner_controlled','external_client','archived'])
    for(const id of ids(category))assert.equal(guruCapitalStructure(id).permanentCapital,false,id);
  for(const id of ids('permanent')) {
    const row=guruCapitalStructure(id);
    assert.equal(row.permanentCapital,true);
    assert.match(row.evidenceUrl,/^https:\/\//);
  }
});
