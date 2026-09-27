import test from 'node:test';
import assert from 'node:assert/strict';
import {verifyReleasedResearch} from './researchReleaseProbe.js';
const sample=async(_,ticker,asOf)=>({ticker,asOf,quarterly:[{date:asOf}],annual:[{date:asOf}]});
test('Research release requires both statement histories and exact PIT company identity',async()=>{
  assert.equal((await verifyReleasedResearch('2026-09-22',sample)).companies.length,2);
  for(const invalid of [{annual:[]},{quarterly:[]},{ticker:'WRONG'},{asOf:'2026-09-23'},
    {quarterly:[{date:'2026-09-23'}]},{annual:[{}]}]) {
    await assert.rejects(verifyReleasedResearch('2026-09-22',async(...args)=>({...await sample(...args),...invalid})),/research_release_read_invalid/);
  }
});
