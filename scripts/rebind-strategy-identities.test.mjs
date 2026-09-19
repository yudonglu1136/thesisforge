import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {rebindIdentities,strategyTableHashes,resolveStoredHolding} from './rebind-strategy-identities.mjs';
import {holdingResolutionVersion} from '../server/cusipOverrides.js';
import {manager13fCorporateActionCatalogVersion} from '../server/corporateActions.js';

test('identity rebind recomputes stale mappings from filed CUSIP, preserves every non-target table, and refuses action drift',async t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tf-rebind-test-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const input=path.join(dir,'source.sqlite'),out=path.join(dir,'candidate.sqlite');
  const db=new DatabaseSync(input);db.exec(fs.readFileSync(new URL('../server/strategyDatabaseSchema.sql',import.meta.url),'utf8'));
  db.prepare('INSERT INTO warehouse_meta VALUES(1,1,?,?,\'complete\',?,?,?,?)').run('2026-09-10','2026-09-11','old-security',manager13fCorporateActionCatalogVersion,'prior','{}');
  db.prepare('INSERT INTO source_documents VALUES(?,?,?,?,?,?)').run('s','fixture','test','a'.repeat(64),'fixture','2026-09-10');
  db.exec(`INSERT INTO managers(id,display_name,simulation_enabled,identity_status,source_id) VALUES('test','Test',1,'configured_unreviewed','s');
    INSERT INTO filings(id,manager_id,accession,report_date,public_date,form,book_scope,classification_status,row_count,source_id,payload_hash)
    VALUES('f','test','a','2025-12-31','2026-02-15','13F-HR','original_common_book','verified',1,'s','hash');
    INSERT INTO filing_holdings(filing_id,ordinal,cusip,reported_ticker,issuer,security_title,amount_type,put_call,reported_shares,value_usd,claim_type,classification_status)
    VALUES('f',0,'037833100','WRONG','APPLE INC','COM','SH','',123,456,'common','verified');
    INSERT INTO holding_resolutions VALUES('f',0,'WRONG','WRONG','resolved','old','old-security');`);
  const before=strategyTableHashes(db);fs.writeFileSync(input+'.import.json',JSON.stringify(before));db.close();
  const result=await rebindIdentities(input,out);
  assert.equal(result.rowsRecomputed,1);assert.equal(result.resolutionChanges,1);assert.equal(result.sourceWrites,0);
  assert.deepEqual(result.changedTables,['holding_resolutions','source_documents']);
  const check=new DatabaseSync(out,{readOnly:true});
  const r=check.prepare('SELECT * FROM holding_resolutions').get();assert.equal(r.ticker,'AAPL');assert.equal(r.resolution_version,holdingResolutionVersion());
  const filed=check.prepare('SELECT reported_ticker,reported_shares,value_usd FROM filing_holdings').get();
  assert.deepEqual({...filed},{reported_ticker:'WRONG',reported_shares:123,value_usd:456});check.close();
  const second=path.join(dir,'again.sqlite'),repeat=await rebindIdentities(out,second);
  assert.equal(repeat.resolutionChanges,0);assert.equal(repeat.tableHashes.holding_resolutions,result.tableHashes.holding_resolutions);
  const source=new DatabaseSync(input);source.exec("UPDATE warehouse_meta SET action_version='unknown-actions'");source.close();
  await assert.rejects(rebindIdentities(input,path.join(dir,'rejected.sqlite')),/corporate_actions/);
  assert.equal(fs.existsSync(path.join(dir,'rejected.sqlite')),false);
});
test('unknown filed CUSIP does not become a verified identity just because a ticker is supplied',()=>{
  const r=resolveStoredHolding({filing_id:'f',ordinal:0,cusip:'000000000',reported_ticker:'AAPL',issuer:'UNKNOWN',security_title:'COM',amount_type:'SH',put_call:''});
  assert.equal(r.status,'unresolved');assert.equal(r.price_symbol,null);
});
