// Read-only numerical equivalence benchmark against a preserved implementation.
// This is a local cold/warm measurement, not a production concurrency SLA.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {InvestmentSource} from '../server/investmentSource.js';
import {signature} from '../server/investmentMath.js';
import {buildFundamentals} from '../server/investmentFundamentals.js';
const [runtime,beforeFile,reportFile]=process.argv.slice(2);
assert.ok(runtime&&beforeFile&&reportFile&&!fs.existsSync(reportFile));
const preserved=beforeFile.endsWith('.json')?JSON.parse(fs.readFileSync(beforeFile,'utf8')):null;
const beforeCode=preserved?null:fs.readFileSync(beforeFile,'utf8').replaceAll("from './",`from '${new URL('../server/',import.meta.url).href}`);
const before=beforeCode?(await import('data:text/javascript;base64,'+Buffer.from(beforeCode).toString('base64'))).buildFundamentals:null;
const dates=['2021-09-09'];
for(let year=2021;year<=2026;year++)for(const md of ['03-31','06-30','09-30','12-31']){
  const d=`${year}-${md}`;if(d>dates[0]&&d<'2026-09-11')dates.push(d);
}
dates.push('2026-09-11');
if(preserved){assert.equal(preserved.runtime,runtime);assert.deepEqual(preserved.dates,dates);}
const results=preserved?{before_cold:preserved.before_cold,before_warm:preserved.before_warm,before_samples:preserved.before_samples}:{};
for(const [name,build] of [...(before?[['before',before]]:[]),['after',buildFundamentals]]){
  const source=new InvestmentSource(runtime),samples=[];
  try {
    for(const mode of ['cold','warm']){
      const start=performance.now(),hashes=[];
      for(const date of dates){const tick=performance.now(),r=build(source,date);hashes.push(signature(r));
        if(mode==='cold')samples.push({date,ms:Math.round(performance.now()-tick),companies:r.companies.length});}
      results[`${name}_${mode}`]={ms:Math.round(performance.now()-start),hashes};
      console.log(JSON.stringify({name,mode,ms:results[`${name}_${mode}`].ms,dates:dates.length}));
    }
    results[`${name}_samples`]=samples;
  }finally{source.close();}
}
assert.deepEqual(results.after_cold.hashes,results.before_cold.hashes);
assert.deepEqual(results.after_warm.hashes,results.before_cold.hashes);
assert.deepEqual(results.before_warm.hashes,results.before_cold.hashes);
fs.writeFileSync(reportFile,JSON.stringify({status:'identical',runtime,dates,sourceWrites:0,
  scope:'One local process; full-company payload equivalence at each cutoff; not a load-test SLA.',...results},null,2),{flag:'wx',mode:0o600});
