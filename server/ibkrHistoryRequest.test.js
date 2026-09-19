import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const dir=fs.mkdtempSync(path.join(os.tmpdir(),'ibkr-history-request-'));
process.env.SQLITE_DB_PATH=path.join(dir,'public.sqlite');process.env.USER_PORTFOLIO_DATA_DIR=path.join(dir,'private');
const {loadIbkrFlexXml}=await import('./portfolioClient.js');
const originalFetch=globalThis.fetch;
test.after(()=>{globalThis.fetch=originalFetch;fs.rmSync(dir,{recursive:true,force:true});});
test('period override reaches only the allowed SendRequest, never GetStatement',async()=>{
  const calls=[];
  globalThis.fetch=async u=>{const url=new URL(u);calls.push(url);
    return {ok:true,text:async()=>url.pathname.endsWith('SendRequest')
      ?'<FlexStatementResponse><Status>Success</Status><ReferenceCode>FIXTURE</ReferenceCode></FlexStatementResponse>'
      :'<FlexQueryResponse><FlexStatements><FlexStatement fromDate="20250910" toDate="20260909" /></FlexStatements></FlexQueryResponse>'};};
  await loadIbkrFlexXml('12345',{ibkrFlexToken:'synthetic-token'},{periodDays:365});
  assert.equal(calls.length,2);assert.equal(calls[0].searchParams.get('p'),'365');
  assert.equal(calls[1].searchParams.has('p'),false);assert.equal(calls[1].searchParams.get('q'),'FIXTURE');
  calls.length=0;
  await assert.rejects(()=>loadIbkrFlexXml('12345',{ibkrFlexToken:'synthetic-token'},{periodDays:366}),/invalid_report_period/);
  await assert.rejects(()=>loadIbkrFlexXml('12345',{ibkrFlexToken:'synthetic-token',ibkrFlexBaseUrl:'https://example.test'}),/not allowed/);
  assert.equal(calls.length,0);
});
