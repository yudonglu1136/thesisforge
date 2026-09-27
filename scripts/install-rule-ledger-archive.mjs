import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';
import {fileURLToPath} from 'node:url';
import {loadInvestorStyleDashboard} from '../server/investorStyleDashboard.js';
import {readRuleLedgerArchive,ruleLedgerArchiveIdentity} from '../server/ruleLedgerArchive.js';

const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const fail=code=>{throw new Error(code);};
const writeImmutable=(file,bytes)=>{
  const fd=fs.openSync(file,'wx',0o444);
  try{fs.writeFileSync(fd,bytes);fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
};
export function installRuleLedgerArchive({source,root,expectedManifest,load=loadInvestorStyleDashboard}) {
  if(!/^[a-f0-9]{64}$/.test(expectedManifest??''))fail('archive_digest_required');
  source=path.resolve(source);root=path.resolve(root);
  if(source===root)fail('archive_source_is_destination');
  for(const base of [source,root]){
    for(let p=base;;p=path.dirname(p)){
      if(fs.existsSync(p)&&fs.lstatSync(p).isSymbolicLink())fail('archive_symlink_forbidden');
      if(p===path.dirname(p))break;
    }
  }
  const raw=fs.readFileSync(path.join(source,'manifest.json'));
  if(sha(raw)!==expectedManifest)fail('archive_manifest_checksum_mismatch');
  const manifest=JSON.parse(raw),universes=['all','sp500','nasdaq100'];
  if(JSON.stringify(Object.keys(manifest.entries??{}).sort())!==JSON.stringify([...universes].sort()))fail('archive_universe_mismatch');
  // Validate the exact deployed code's snapshots before modifying any pointer.
  for(const universe of universes)readRuleLedgerArchive(load({universe}),{root:source,identity:expectedManifest});
  fs.mkdirSync(root,{recursive:true,mode:0o755});
  const lock=path.join(root,'.install.lock'),fd=fs.openSync(lock,'wx',0o600);
  try{
    for(const entry of Object.values(manifest.entries)){
      const file=path.join(root,entry.file),bytes=fs.readFileSync(path.join(source,entry.file));
      if(fs.existsSync(file)){
        if(fs.lstatSync(file).isSymbolicLink()||sha(fs.readFileSync(file))!==entry.sha256)fail('archive_immutable_conflict');
      }else writeImmutable(file,bytes);
      fs.chmodSync(file,0o444);
    }
    const history=path.join(root,'manifests');fs.mkdirSync(history,{recursive:true,mode:0o755});
    const active=path.join(root,'manifest.json');
    if(fs.existsSync(active)){
      const old=fs.readFileSync(active),oldFile=path.join(history,`${sha(old)}.json`);
      if(!fs.existsSync(oldFile))writeImmutable(oldFile,old);
    }
    const saved=path.join(history,`${expectedManifest}.json`);
    if(!fs.existsSync(saved))writeImmutable(saved,raw);
    if(ruleLedgerArchiveIdentity(root)!==expectedManifest){
      const temp=path.join(root,`.manifest.${process.pid}.part`),handle=fs.openSync(temp,'wx',0o444);
      try{fs.writeFileSync(handle,raw);fs.fsyncSync(handle);}finally{fs.closeSync(handle);}
      fs.renameSync(temp,active);
      const directory=fs.openSync(root,'r');try{fs.fsyncSync(directory);}finally{fs.closeSync(directory);}
    }
    return {status:'installed',manifestSha256:expectedManifest,universes,apiActivation:'not_requested'};
  }finally{fs.closeSync(fd);fs.unlinkSync(lock);}
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const {values}=parseArgs({options:{source:{type:'string'},root:{type:'string'},sha256:{type:'string'}}});
  console.log(JSON.stringify(installRuleLedgerArchive({source:values.source,root:values.root,expectedManifest:values.sha256})));
}
