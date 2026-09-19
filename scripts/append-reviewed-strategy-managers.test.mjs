import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {verifiedOriginal,originalCalendar} from './append-reviewed-strategy-managers.mjs';
import {originalStrategyHistory} from '../server/strategyFilings.js';
import {DatabaseSync} from 'node:sqlite';

function fixture({coverTotal=10,coverCount=1}={}){
  const guru={id:'synthetic-manager',cik:'0000000123'};
  const info='<informationTable><infoTable><nameOfIssuer>Fixture</nameOfIssuer><titleOfClass>COM</titleOfClass><cusip>037833100</cusip><value>10</value><shrsOrPrnAmt><sshPrnamt>20</sshPrnamt><sshPrnamtType>SH</sshPrnamtType></shrsOrPrnAmt></infoTable></informationTable>';
  const cover=`<edgarSubmission><headerData><submissionType>13F-HR</submissionType><filerInfo><periodOfReport>06-30-2026</periodOfReport><filer><credentials><cik>123</cik></credentials></filer></filerInfo></headerData><formData><coverPage><isAmendment>false</isAmendment></coverPage><summaryPage><tableEntryTotal>${coverCount}</tableEntryTotal><tableValueTotal>${coverTotal}</tableValueTotal></summaryPage></formData></edgarSubmission>`;
  const root='https://www.sec.gov/Archives/edgar/data/123/000000012326000001/';
  const receipt=(url,body)=>({url,body,status:200,sha256:crypto.createHash('sha256').update(body).digest('hex'),fetchedAt:'2026-09-12T00:00:00Z'});
  const receipts=new Map([[root+'info.xml',receipt(root+'info.xml',info)],[root+'primary_doc.xml',receipt(root+'primary_doc.xml',cover)]]);
  const row={reportDate:'2026-06-30',filingDate:'2026-08-14',commonLongValue:10000,
    filing:{form:'13F-HR',filerCik:guru.cik,reportDate:'2026-06-30',filingDate:'2026-08-14',acceptanceDateTime:'2026-08-14T17:00:00Z',accessionNumber:'0000000123-26-000001',xmlUrl:root+'info.xml'},
    holdings:[{cusip:'037833100',shares:20,value:10000,holdingBucket:'common_long'}]};
  return {guru,row,receipts,get:url=>receipts.get(url)};
}
test('existing SEC parser reconciles exact shares/value and preserves original dates and raw rounding residual',()=>{
  const f=fixture({coverTotal:9});const result=verifiedOriginal(f.guru,f.row,f.get).record;
  assert.equal(result.scale,1000);assert.equal(result.holdings[0].value,10000);
  assert.equal(result.holdings[0].shares,20);assert.equal(result.publicDate,'2026-08-14');
  assert.equal(result.coverDocuments[0].coverDifference,1);assert.equal(result.coverDocuments[0].reportedValue,10);
  assert.equal(result.originalFiling.cik,f.guru.cik);
});
test('wrong manager, corrupted receipt, cover mismatch and changed holdings never become verified',()=>{
  const f=fixture();assert.throws(()=>verifiedOriginal({...f.guru,cik:'0000000999'},f.row,f.get),/identity/);
  f.receipts.values().next().value.sha256='0'.repeat(64);
  assert.throws(()=>verifiedOriginal(f.guru,f.row,f.get),/receipt/);
  for(const option of [{coverTotal:7},{coverCount:2}]){
    const x=fixture(option);assert.throws(()=>verifiedOriginal(x.guru,x.row,x.get),/cover_total_mismatch/);
  }
  const x=fixture();x.row.holdings[0].shares=21;
  assert.throws(()=>verifiedOriginal(x.guru,x.row,x.get),/source_holding_mismatch/);
});
test('original submission XML extraction retains its exact enclosing SEC source',()=>{
  const f=fixture(),url=[...f.receipts.keys()].find(x=>x.endsWith('primary_doc.xml'));
  const body='<DOCUMENT>\n<FILENAME>primary_doc.xml\n<TEXT>\n<XML>'+f.receipts.get(url).body+'</XML>\n</TEXT>\n</DOCUMENT>';
  f.receipts.delete(url);
  const sourceUrl=new URL(f.row.filing.accessionNumber+'.txt',url).href;
  const receipt={url:sourceUrl,status:200,body,sha256:crypto.createHash('sha256').update(body).digest('hex')};
  f.receipts.set(sourceUrl,receipt);
  const record=verifiedOriginal(f.guru,f.row,f.get).record;
  assert.deepEqual(record.coverDocuments[0].sourceContainer,receipt);
  assert.equal(record.coverDocuments[0].url,sourceUrl+'#primary_doc.xml');
});
test('a failed original remains a dated blocker, not an invisible gap in history',()=>{
  const f=fixture({coverCount:2}),calendar=originalCalendar(f.guru,[f.row],'2026-09-11');
  const db=new DatabaseSync(':memory:');
  try {
    db.exec('CREATE TABLE guru_backtests(guru_id TEXT,years INTEGER,payload_json TEXT)');
    db.prepare('INSERT INTO guru_backtests VALUES (?,?,?)').run(f.guru.id,0,JSON.stringify({rebalances:calendar}));
    const history=originalStrategyHistory({db,guruHistory:()=>[]},f.guru.id,'2026-09-11',new Map());
    assert.equal(history.length,1);assert.equal(history[0].missingOriginal,true);
    assert.equal(history[0].filingDate,'2026-08-14');assert.deepEqual(history[0].topHoldings,[]);
  } finally {db.close();}
  assert.throws(()=>originalCalendar({...f.guru,cik:'0000000999'},[f.row],'2026-09-11'),/untrusted/);
  assert.deepEqual(originalCalendar(f.guru,[f.row],'2026-08-13'),[]);
});
