import test from 'node:test';
import assert from 'node:assert/strict';
import {valuationModelRoute} from './valuationModelRoute.js';

test('explicit route is authoritative and legacy profiles map to their original branches',()=>{
  assert.equal(valuationModelRoute({modelRoute:'reviewed'}),'reviewed');
  assert.equal(valuationModelRoute({profile:'insurance'}),'financial_institution');
  assert.equal(valuationModelRoute({profile:'asset_manager'}),'customer_cash_earnings');
  assert.equal(valuationModelRoute({profile:'emerging_biotech'}),'revenue_stage');
  assert.equal(valuationModelRoute({profile:'software_growth'}),'multi_method_growth');
  assert.equal(valuationModelRoute({profile:'mega_cap_platform'}),'operating_company');
  assert.equal(valuationModelRoute({profile:'unknown_future_profile'}),null);
  assert.equal(valuationModelRoute({}),null);
});
