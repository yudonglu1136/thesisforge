import test from 'node:test';
import assert from 'node:assert/strict';
import { analysisFailureCode } from './analysisFailure.js';

test('analysis workers preserve diagnostic codes without exposing paths or private messages',()=>{
  assert.equal(analysisFailureCode({code:'local_data_unavailable'}),'local_data_unavailable');
  assert.equal(analysisFailureCode(new Error('rule_analysis_nav_mismatch')),'rule_analysis_nav_mismatch');
  assert.equal(analysisFailureCode(new Error('ENOENT /private/account/secret')),'analysis_build_failed');
  assert.equal(analysisFailureCode({code:'ERR_WORKER_OUT_OF_MEMORY'}),'analysis_memory_limit');
});
