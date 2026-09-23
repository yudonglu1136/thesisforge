import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'guru-price-batch-'));
process.env.SQLITE_DB_PATH = ':memory:';
process.env.FACT_OS_ENABLED = '1';
process.env.FACT_OS_ROOT = root;
process.env.FACT_OS_PYTHON = path.join(root, 'synthetic-reader');
for (const key of ['SYNC_BUNDLED_VALUATION_SNAPSHOTS', 'SYNC_BUNDLED_GURU_BACKTESTS', 'SYNC_BUNDLED_DIVIDEND_CALENDAR', 'SYNC_BUNDLED_PODCAST_INSIGHTS']) process.env[key] = 'false';
await fs.mkdir(path.join(root, 'manifests'));
await fs.writeFile(path.join(root, 'manifests/catalog.json'), '{"generation":"fixture"}');
await fs.writeFile(process.env.FACT_OS_PYTHON, `#!${process.execPath}
const fs = require('node:fs');
const root=process.argv[process.argv.indexOf('--root')+1];
let input='';process.stdin.on('data',d=>input+=d);process.stdin.on('end',()=>{
 const request=JSON.parse(input);fs.appendFileSync(root+'/calls.jsonl',JSON.stringify(request)+'\\n');
 const read=r=>r.args[0]==='MISSING'?{ok:false,error:{code:'security_not_found',message:'Missing security'}}:{ok:true,result:[{date:r.args[1],value:123.456789,security_id:'fixture-'+r.args[0],provenance:{generation:'fixture',priceType:r.args[3]}}]};
 process.stdout.write(JSON.stringify(request.batch?{ok:true,result:request.batch.map(read)}:read(request)));
});
`, {mode:0o755});
const market = await import('./marketData.js');
const calls = async () => (await fs.readFile(path.join(root,'calls.jsonl'),'utf8')).trim().split('\n').map(JSON.parse);
const request = symbol => ({symbol,start:'2021-09-23',end:'2026-09-21',priceType:'TOTAL_RETURN_ADJUSTED_CLOSE',requireAdjusted:true});
const stable = ({generatedAt,...value}) => value;
test.after(async()=>fs.rm(root,{recursive:true,force:true}));

test('canonical batch uses one existing RPC with exact security, interval and price basis', async()=>{
 assert.equal(typeof market.loadPriceSeriesBatch,'function');
 const requests=['SPY','MSFT','MISSING','NVDA'].map(request);
 const before=await calls().catch(()=>[]);
 const results=await market.loadPriceSeriesBatch(requests);
 const after=await calls();
 assert.equal(after.length-before.length,1);
 assert.equal(after.at(-1).batch.length,4);
 assert.deepEqual(after.at(-1).batch[1],{method:'get_price_history',args:['MSFT','2021-09-23','2026-09-21','TOTAL_RETURN_ADJUSTED_CLOSE'],kwargs:{dataset:'auto'}});
 assert.equal(results[2].status,'unavailable');
 assert.equal(results[2].error,'security_not_found');
 assert.deepEqual(results[2].points,[]);
 for(let i=0;i<requests.length;i++){
  const {symbol,...options}=requests[i];
  assert.deepEqual(stable(results[i]),stable(await market.loadPriceSeries(symbol,options)));
 }
 assert.equal((await calls()).length,after.length,'single reads reuse the same canonical request cache');
});

test('batch rejects implicit price basis before starting any reader',async()=>{
 await assert.rejects(market.loadPriceSeriesBatch([{symbol:'MSFT',start:'2021-01-01',end:'2026-01-01'}]),{code:'explicit_price_basis_required'});
});

test('bounded batches preserve identity and order without spilling large history responses',async()=>{
 const requests=Array.from({length:19},(_,i)=>request('TEST'+i));
 const before=(await calls()).length;
 const result=await market.loadPriceSeriesBatch(requests);
 const added=(await calls()).slice(before);
 assert.ok(added.length>=3);
 assert.ok(added.every(c=>c.batch.length<=8));
 assert.deepEqual(result.map(r=>r.symbol),requests.map(r=>r.symbol));
 assert.ok(result.every(r=>r.points[0].adjustedClose===123.456789));
});

test('missing canonical runtime fails closed, never substituting released SQLite or network',async()=>{
 process.env.FACT_OS_PYTHON=path.join(root,'missing-reader');
 const results=await market.loadPriceSeriesBatch([request('MSFT'),request('NVDA')]);
 assert.ok(results.every(r=>r.status==='unavailable'&&r.error==='local_runtime_unavailable'&&r.points.length===0));
});
