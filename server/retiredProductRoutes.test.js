import assert from 'node:assert/strict';
import test from 'node:test';
import { isRetiredApiPath, registerRetiredProductRoutes } from './retiredProductRoutes.js';

test('retired modules and aliases cannot reach old snapshot APIs', () => {
  for (const route of ['/api/ontology/health','/api/ontology/overview','/api/strategies',
    '/api/strategies/legacy/snapshot','/api/decision/company/PLTR','/api/market/companies/PLTR',
    '/api/overview','/api/graph','/api/methodology','/api/timeline','/api/rankings',
    '/api/company/PLTR','/api/snapshot','/api/investment/value-flow','/api/dbmf?refresh=1','/API/ONTOLOGY/',
    '/api/%6fntology/overview']) assert.equal(isRetiredApiPath(route),true,route);
});

test('current research, Guru, portfolio, factor and CTA routes remain available', () => {
  for (const route of ['/api/gurus','/api/gurus/bill-ackman','/api/valuation','/api/valuation/PLTR',
    '/api/portfolio','/api/health','/api/admin/system-health','/api/investment/discover','/api/investment/ai-insights',
    '/api/investment/strategy-lab','/api/investment/strategy-backtests','/api/marketplace',
    '/api/strategies-extra','/api/ontology-extra','/api/graphing']) assert.equal(isRetiredApiPath(route),false,route);
});

test('retired requests return a data-free no-store 410 before authentication or network access', () => {
  let middleware;
  registerRetiredProductRoutes({use:fn=>{middleware=fn;}});
  for(const method of ['GET','POST','DELETE','HEAD']) {
    const output={headers:{}};
    const response={setHeader:(k,v)=>{output.headers[k]=v;},status:s=>{output.status=s;return response;},json:b=>{output.body=b;}};
    middleware({method,path:'/api/ontology/overview'},response,()=>assert.fail('Retired request continued'));
    assert.deepEqual(output,{headers:{'Cache-Control':'no-store'},status:410,body:{error:'module_retired'}});
  }
  let continued=false;
  middleware({path:'/api/investment/strategy-backtests'},{},()=>{continued=true;});
  assert.equal(continued,true);
});
