import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {importStrategyDatabase} from '../server/strategyDatabaseImport.js';

const options={};
for(let i=2;i<process.argv.length;i+=2) {
 const name=process.argv[i],value=process.argv[i+1];
 if(!['--source','--output','--as-of','--etfs','--filings','--evidence','--generated-at'].includes(name)||!value||options[name])throw Error('Invalid arguments. See docs/strategy-database.md');
 options[name]=value;
}
for(const name of ['--source','--output','--as-of','--etfs','--filings'])if(!options[name])throw Error('Missing '+name);
const output=path.resolve(options['--output']);
if(fs.existsSync(output))throw Error('Refusing to overwrite an existing generation: '+output);
fs.mkdirSync(path.dirname(output),{recursive:true,mode:0o700});
const staged=output+'.building-'+randomUUID();
const evidenceFiles=options['--evidence']?JSON.parse(fs.readFileSync(options['--evidence'],'utf8')):[];
try {
 const report=importStrategyDatabase({sourceFile:options['--source'],targetFile:staged,cutoff:options['--as-of'],etfFile:options['--etfs'],filingFile:options['--filings'],evidenceFiles,
  generatedAt:options['--generated-at'],progress:phase=>console.log(JSON.stringify({phase,time:new Date().toISOString()}))});
 fs.chmodSync(staged,0o600);
 // Link is atomic and no-clobber, unlike rename over an existing destination.
 fs.linkSync(staged,output);fs.unlinkSync(staged);
 fs.writeFileSync(output+'.import.json',JSON.stringify({...report,database:output},null,2),{flag:'wx',mode:0o600});
 console.log(JSON.stringify({...report,database:output},null,2));
}catch(error) {
 console.error(JSON.stringify({status:'failed',error:error.message,unpublishedCandidate:staged}));
 process.exitCode=1;
}
