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
test('SendRequest retries transient Error 1018 rate limits without delaying permanent errors',async()=>{
  let sendAttempts=0;
  globalThis.fetch=async u=>{
    const url=new URL(u);
    if(url.pathname.endsWith('SendRequest')) {
      sendAttempts+=1;
      if(sendAttempts===1) {
        return {ok:true,text:async()=>'<FlexStatementResponse><Status>Fail</Status><ErrorCode>1018</ErrorCode><ErrorMessage>Too many requests have been made from this token. Please try again shortly.</ErrorMessage></FlexStatementResponse>'};
      }
      return {ok:true,text:async()=>'<FlexStatementResponse><Status>Success</Status><ReferenceCode>FIXTURE2</ReferenceCode></FlexStatementResponse>'};
    }
    return {ok:true,text:async()=>'<FlexQueryResponse><FlexStatements><FlexStatement fromDate="20250910" toDate="20260909" /></FlexStatements></FlexQueryResponse>'};
  };
  await loadIbkrFlexXml('12345',{ibkrFlexToken:'synthetic-token'},{periodDays:365,sendRetryDelays:[0,5,10]});
  assert.equal(sendAttempts,2);
  let badAttempts=0;
  globalThis.fetch=async()=>{badAttempts+=1;return {ok:true,text:async()=>'<FlexStatementResponse><Status>Fail</Status><ErrorCode>1015</ErrorCode><ErrorMessage>Token is invalid.</ErrorMessage></FlexStatementResponse>'};};
  await assert.rejects(()=>loadIbkrFlexXml('12345',{ibkrFlexToken:'synthetic-token'},{sendRetryDelays:[0,5000]}),/Token is invalid/);
  assert.equal(badAttempts,1);
});
