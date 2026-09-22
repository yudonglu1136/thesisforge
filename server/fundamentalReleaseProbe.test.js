import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyReleasedFundamentals } from './fundamentalReleaseProbe.js';

const snapshot = () => ({asOf:'2026-09-22',catalogGeneration:'fixture-generation',
  coverage:{factCompanies:5419,latestAvailableAt:'2026-09-21'},
  rows:[{ticker:'UBER',available_at:'2026-08-05'}]});

test('release ACK warms the same discovery path and returns compact coverage only',async()=>{
  let calls=0;
  const result=await verifyReleasedFundamentals('2026-09-22',async (asOf,options)=>{
    calls++; assert.equal(asOf,'2026-09-22');assert.deepEqual(options,{lens:'all',limit:1});return snapshot();
  });
  assert.equal(calls,1);assert.equal(result.status,'ready');assert.equal(result.factCompanies,5419);
  assert.equal(result.rows,undefined);
});

test('release cannot ACK a missing, future or wrong-cutoff discovery',async()=>{
  for(const mutate of [s=>{s.rows=[];},s=>{s.asOf='2026-09-23';},
    s=>{s.rows[0].available_at='2026-09-23';},s=>{s.coverage.factCompanies=0;}]) {
    const value=snapshot();mutate(value);
    await assert.rejects(verifyReleasedFundamentals('2026-09-22',async()=>value),/fundamental_release_read_invalid/);
  }
  await assert.rejects(verifyReleasedFundamentals('2026-09-22',async()=>{throw Error('reader_failed');}),/reader_failed/);
});
