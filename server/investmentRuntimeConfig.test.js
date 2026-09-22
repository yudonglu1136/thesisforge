import test from 'node:test';
import a from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import express from 'express';
import { DatabaseSync } from 'node:sqlite';
import { holdingResolutionVersion } from './cusipOverrides.js';
import { manager13fCorporateActionCatalogVersion } from './corporateActions.js';
import { INVESTMENT_RELEASE_VERSION, INVESTMENT_REQUIRED_SOURCE_TABLES, resolveInvestmentRuntimeConfig, validateAiInsightsArtifact, validateInstitutional13fArtifact, validateInvestmentRelease, verifiedInvestmentOwner } from './investmentRuntimeConfig.js';
import { investmentProductionIdentity } from './investmentRoutes.js';
import { InvestmentStore } from './investmentStore.js';
import { portfolioResponsePrivacy } from './portfolioHttp.js';
import { strategyWorkerLimits } from './strategyLabRoutes.js';

function fixture(t) {
  const root=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'tf-investment-runtime-')));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const release=path.join(root,'release');fs.mkdirSync(release);
  const manifestPath=path.join(release,'manifest.json');
  const paths={releaseId:'test-release-20260912'},files={};
  for(const key of ['research','strategy','composition']) {
    const file=path.join(release,`${key}.sqlite`),data=Buffer.from(`Synthetic fixture: ${key}`);
    fs.writeFileSync(file,data,{mode:0o600}); paths[key]=file;
    files[key]={path:file,bytes:data.length,sha256:crypto.createHash('sha256').update(data).digest('hex')};
  }
  const manifest={version:INVESTMENT_RELEASE_VERSION,releaseId:paths.releaseId,state:'verified',cutoff:'2026-09-11',
    checks:{integrity:'ok',schema:'pass',sourceAlignment:'pass',privateDataExcluded:true},files};
  fs.writeFileSync(manifestPath,JSON.stringify(manifest),{mode:0o600});
  return {root,paths,manifest,manifestPath,options:{manifestPath,trustedUid:fs.statSync(manifestPath).uid}};
}

function productionFixture(t) {
  const f=fixture(t),users=path.join(f.root,'users');fs.mkdirSync(users,{mode:0o700});
  const legacy=path.join(f.root,'legacy.sqlite');new DatabaseSync(legacy).close();
  for(const file of Object.values(f.paths).filter(value=>value.endsWith('.sqlite'))) fs.unlinkSync(file);
  const source=new DatabaseSync(f.paths.research);
  for(const table of INVESTMENT_REQUIRED_SOURCE_TABLES)source.exec(`CREATE TABLE ${table}(fixture TEXT)`);
  source.close();
  const warehouse=new DatabaseSync(f.paths.strategy);
  warehouse.exec('CREATE TABLE warehouse_meta(id INTEGER PRIMARY KEY,schema_version INTEGER,state TEXT,manifest_hash TEXT,security_version TEXT,action_version TEXT,cutoff TEXT)');
  warehouse.prepare('INSERT INTO warehouse_meta VALUES(1,1,?,?,?,?,?)').run('complete','f'.repeat(64),holdingResolutionVersion(),manager13fCorporateActionCatalogVersion,f.manifest.cutoff);warehouse.close();
  const prices=new DatabaseSync(f.paths.composition);prices.exec('CREATE TABLE series(symbol TEXT);CREATE TABLE prices(symbol TEXT)');prices.close();
  const updateManifest=()=>{
    for(const [key,file] of Object.entries(f.paths).filter(([key])=>['research','strategy','composition'].includes(key))) {
      const bytes=fs.readFileSync(file);f.manifest.files[key].bytes=bytes.length;f.manifest.files[key].sha256=crypto.createHash('sha256').update(bytes).digest('hex');
    }
    fs.writeFileSync(f.manifestPath,JSON.stringify(f.manifest));
  };
  updateManifest();
  const aiRoot=path.join(f.root,'ai-insights'),aiDirectory=path.join(aiRoot,'derived/ai-insights/generations');
  fs.mkdirSync(aiDirectory,{recursive:true});
  const aiGeneration='a'.repeat(64),aiSourceGeneration='b'.repeat(64),aiDependency='c'.repeat(64);
  const aiArtifact={schemaVersion:1,builderVersion:'ai-insights-artifact-v3',methodologyVersion:'ai-insights-v1',
    generationId:aiGeneration,generatedAt:'2026-09-22T00:00:00Z',sourceManifestSha256:aiSourceGeneration,
    dependencySha256:aiDependency,universeVersion:'test',companies:[],facts:[]};
  const aiArtifactPath=path.join(aiDirectory,`${aiGeneration}.json`),aiArtifactBytes=Buffer.from(JSON.stringify(aiArtifact));
  fs.writeFileSync(aiArtifactPath,aiArtifactBytes);
  const aiCurrent={schemaVersion:1,builderVersion:'ai-insights-artifact-v3',generationId:aiGeneration,
    generatedAt:aiArtifact.generatedAt,sourceManifestSha256:aiSourceGeneration,dependencySha256:aiDependency,
    universeVersion:'test',universeSha256:'d'.repeat(64),artifactPath:`derived/ai-insights/generations/${aiGeneration}.json`,
    artifactSha256:crypto.createHash('sha256').update(aiArtifactBytes).digest('hex'),bytes:aiArtifactBytes.length,
    rowCount:0,companyCount:0,inventory:{}};
  const aiManifestPath=path.join(aiRoot,'derived/ai-insights/manifest.json'),aiSidecarPath=path.join(aiDirectory,`${aiGeneration}.manifest.json`);
  fs.writeFileSync(aiManifestPath,JSON.stringify(aiCurrent));fs.writeFileSync(aiSidecarPath,JSON.stringify(aiCurrent));
  const aiFiles=[aiManifestPath,aiArtifactPath,aiSidecarPath].map(file=>({relativePath:path.relative(aiRoot,file),bytes:fs.statSync(file).size,
    sha256:crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}));
  const aiReleasePath=path.join(aiRoot,'release-manifest.json');
  fs.writeFileSync(aiReleasePath,JSON.stringify({version:'ai-insights-runtime-release-v1',releaseId:'ai-insights-20260922-v1',state:'verified',
    currentGeneration:aiGeneration,sourceManifestSha256:aiSourceGeneration,checks:{schema:'pass',privateDataExcluded:true,immutableGenerations:'pass'},files:aiFiles}));
  for(const file of [...aiFiles.map(entry=>path.join(aiRoot,entry.relativePath)),aiReleasePath])fs.chmodSync(file,0o400);
  // The pure validator separately tests owner mismatch. Simulate the trusted
  // root installer only for this local HTTP/schema test (never in runtime).
  const originalStat=fs.statSync;t.mock.method(fs,'statSync',(file,...args)=>{
    const result=originalStat(file,...args);if(file===f.manifestPath||String(file).startsWith(aiRoot))result.uid=0;
    if(file===aiRoot)result.mode&=~0o222;return result;
  });
  const env={NODE_ENV:'production',INVESTMENT_WORKFLOW_ENABLED:'true',SQLITE_DB_PATH:legacy,USER_PORTFOLIO_DATA_DIR:users,
    INVESTMENT_SOURCE_DB_PATH:f.paths.research,INVESTMENT_DB_PATH:path.join(users,'investment.sqlite'),
    STRATEGY_DATA_DB_PATH:f.paths.strategy,STRATEGY_COMPOSITION_PRICE_DB_PATH:f.paths.composition,
    INVESTMENT_RELEASE_MANIFEST_PATH:f.manifestPath,INVESTMENT_RELEASE_ID:f.paths.releaseId,
    AI_INSIGHTS_ROOT:aiRoot,AI_INSIGHTS_RELEASE_MANIFEST_PATH:aiReleasePath};
  return {...f,env,updateManifest,aiRoot,aiReleasePath};
}

test('workflow stays disabled without probing files; preview accepts separate source without changing legacy roots',t=>{
  a.equal(resolveInvestmentRuntimeConfig({NODE_ENV:'production'}),null);
  const {root}=fixture(t);
  const config=resolveInvestmentRuntimeConfig({INVESTMENT_WORKFLOW_ENABLED:'true',SQLITE_DB_PATH:path.join(root,'legacy.sqlite'),
    INVESTMENT_SOURCE_DB_PATH:path.join(root,'new-source.sqlite'),INVESTMENT_DB_PATH:path.join(root,'private/investment.sqlite')});
  a.equal(config.research,path.join(root,'new-source.sqlite'));
  a.equal(config.investment,path.join(root,'private/investment.sqlite'));a.equal(config.production,false);
  a.equal(fs.existsSync(path.join(root,'private')),false);
});

test('13F sidecar requires exact immutable bytes and natural-key uniqueness',t=>{
  const root=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'tf-13f-artifact-')));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const file=path.join(root,'13f.sqlite'),manifestPath=path.join(root,'manifest.json'),db=new DatabaseSync(file);
  db.exec(`CREATE TABLE institutional_13f_insight_snapshots(report_date TEXT,source_generation TEXT,available_at TEXT,generated_at TEXT,payload_hash TEXT,payload_json TEXT,PRIMARY KEY(report_date,source_generation));
    INSERT INTO institutional_13f_insight_snapshots VALUES('2026-06-30','g','2026-08-14','2026-09-20','h','{}');`);db.close();
  const bytes=fs.readFileSync(file),trustedUid=fs.statSync(file).uid;
  const manifest={version:'institutional-13f-artifact-v1',state:'verified',rows:1,
    checks:{integrity:'ok',naturalKeyUniqueness:'pass',privateDataExcluded:true},
    file:{path:file,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')}};
  fs.writeFileSync(manifestPath,JSON.stringify(manifest));fs.chmodSync(file,0o400);fs.chmodSync(manifestPath,0o400);
  a.equal(validateInstitutional13fArtifact(file,manifestPath,{trustedUid}).rows,1);
  fs.chmodSync(file,0o600);fs.appendFileSync(file,'changed');fs.chmodSync(file,0o400);
  a.throws(()=>validateInstitutional13fArtifact(file,manifestPath,{trustedUid}),/manifest|hash|file is not a database|database disk image/);
});

test('13F sidecar accepts the compact v2 artifact without allowing mixed tables',t=>{
  const root=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'tf-13f-v2-artifact-')));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const file=path.join(root,'13f.sqlite'),manifestPath=path.join(root,'manifest.json'),db=new DatabaseSync(file);
  db.exec(`CREATE TABLE institutional_13f_insight_snapshots_v2(report_date TEXT,source_generation TEXT,available_at TEXT,generated_at TEXT,payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation));`);
  db.prepare('INSERT INTO institutional_13f_insight_snapshots_v2 VALUES(?,?,?,?,?,?)')
    .run('2026-06-30','g','2026-08-14','2026-09-20','h',Buffer.from('gzip-fixture'));db.close();
  const bytes=fs.readFileSync(file),trustedUid=fs.statSync(file).uid;
  const manifest={version:'institutional-13f-artifact-v2',state:'verified',rows:1,table:'institutional_13f_insight_snapshots_v2',
    checks:{integrity:'ok',naturalKeyUniqueness:'pass',privateDataExcluded:true},
    file:{path:file,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')}};
  fs.writeFileSync(manifestPath,JSON.stringify(manifest));fs.chmodSync(file,0o400);fs.chmodSync(manifestPath,0o400);
  a.equal(validateInstitutional13fArtifact(file,manifestPath,{trustedUid}).rows,1);
  manifest.table='institutional_13f_insight_snapshots';
  fs.chmodSync(manifestPath,0o600);fs.writeFileSync(manifestPath,JSON.stringify(manifest));fs.chmodSync(manifestPath,0o400);
  a.throws(()=>validateInstitutional13fArtifact(file,manifestPath,{trustedUid}),/manifest_invalid/);
});

test('13F sidecar accepts the evidence-led v5 artifact with complete detail tables',t=>{
  const root=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'tf-13f-v5-artifact-')));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const file=path.join(root,'13f.sqlite'),manifestPath=path.join(root,'manifest.json'),db=new DatabaseSync(file);
  db.exec(`CREATE TABLE institutional_13f_insight_snapshots_v2(report_date TEXT,source_generation TEXT,available_at TEXT,generated_at TEXT,payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation));
    CREATE TABLE institutional_13f_insight_details_v1(report_date TEXT,source_generation TEXT,ticker TEXT,payload_hash TEXT,payload_gzip BLOB,PRIMARY KEY(report_date,source_generation,ticker));
    CREATE TABLE institutional_13f_market_history_v1(report_date TEXT,source_generation TEXT,segment TEXT,PRIMARY KEY(report_date,source_generation,segment));
    CREATE TABLE institutional_13f_security_history_v1(report_date TEXT,source_generation TEXT,ticker TEXT,PRIMARY KEY(report_date,source_generation,ticker));
    INSERT INTO institutional_13f_insight_snapshots_v2 VALUES('2026-06-30','g','2026-08-14','2026-09-21','h',X'00');
    INSERT INTO institutional_13f_insight_details_v1 VALUES('2026-06-30','g','MSFT','h',X'00');
    INSERT INTO institutional_13f_market_history_v1 VALUES('2026-06-30','g','all');
    INSERT INTO institutional_13f_security_history_v1 VALUES('2026-06-30','g','MSFT');`);db.close();
  const bytes=fs.readFileSync(file),trustedUid=fs.statSync(file).uid;
  const manifest={version:'institutional-13f-artifact-v5',state:'verified',rows:1,detailRows:1,marketRows:1,securityHistoryRows:1,
    table:'institutional_13f_insight_snapshots_v2',checks:{integrity:'ok',naturalKeyUniqueness:'pass',privateDataExcluded:true},
    file:{path:file,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')}};
  fs.writeFileSync(manifestPath,JSON.stringify(manifest));fs.chmodSync(file,0o400);fs.chmodSync(manifestPath,0o400);
  a.equal(validateInstitutional13fArtifact(file,manifestPath,{trustedUid}).version,'institutional-13f-artifact-v5');
});

test('reviewed manifest validates exact versions paths sizes and distinct physical files without scanning large payloads',t=>{
  const {manifest,paths,options}=fixture(t);
  a.equal(validateInvestmentRelease(manifest,paths,options),manifest);
  for(const mutate of [m=>m.state='staged',m=>m.releaseId='different-release',m=>m.version='other',
    m=>m.checks.privateDataExcluded=false,m=>m.checks.integrity='pending',m=>m.cutoff='2026-02-30',
    m=>m.files.strategy.bytes++,m=>m.files.research.sha256='unverified',m=>m.files.composition.path=paths.strategy]) {
    const changed=structuredClone(manifest);mutate(changed);a.throws(()=>validateInvestmentRelease(changed,paths,options));
  }
});

test('manifest trust and public artifacts reject writable metadata, wrong root owner, symlink and pending WAL',t=>{
  const {manifest,paths,options,root,manifestPath}=fixture(t);
  a.throws(()=>validateInvestmentRelease(manifest,paths,{...options,trustedUid:-1}),/permissions/);
  fs.chmodSync(manifestPath,0o666);a.throws(()=>validateInvestmentRelease(manifest,paths,options),/permissions/);fs.chmodSync(manifestPath,0o600);
  fs.chmodSync(paths.research,0o666);a.throws(()=>validateInvestmentRelease(manifest,paths,options),/file_mismatch/);fs.chmodSync(paths.research,0o600);
  fs.writeFileSync(`${paths.research}-wal`,'pending');a.throws(()=>validateInvestmentRelease(manifest,paths,options),/pending_wal/);fs.unlinkSync(`${paths.research}-wal`);
  const link=path.join(root,'release','linked.sqlite');fs.symlinkSync(paths.research,link);
  const linked=structuredClone(manifest);linked.files.research.path=link;
  a.throws(()=>validateInvestmentRelease(linked,{...paths,research:link},options),/path_mismatch/);
});

test('public/private collision including hard links fails before creating or mutating stores',t=>{
  const {root,paths}=fixture(t),privateFile=path.join(root,'private.sqlite');fs.linkSync(paths.research,privateFile);
  const base={INVESTMENT_WORKFLOW_ENABLED:'true',SQLITE_DB_PATH:paths.research,INVESTMENT_DB_PATH:privateFile};
  a.throws(()=>resolveInvestmentRuntimeConfig(base),/collision/);
  a.throws(()=>resolveInvestmentRuntimeConfig({...base,INVESTMENT_DB_PATH:paths.research}),/separate|collision/);
});

test('production refuses local owner identity or implicit new data paths before any mutation',t=>{
  const {root}=fixture(t),base={NODE_ENV:'production',INVESTMENT_WORKFLOW_ENABLED:'true',
    SQLITE_DB_PATH:path.join(root,'legacy.sqlite'),INVESTMENT_DB_PATH:path.join(root,'users/investment.sqlite')};
  for(const overrides of [{API_AUTH_DEV_BYPASS:'true'},{AUTH_DEV_BYPASS:'true'},{LOCAL_OWNER_PORTFOLIO_DB:'/private/owner.sqlite'},{LOCAL_OWNER_PORTFOLIO_HASH:'private'}])
    a.throws(()=>resolveInvestmentRuntimeConfig({...base,...overrides}),/local_identity_forbidden/);
  a.throws(()=>resolveInvestmentRuntimeConfig(base),/explicit_paths/);
  a.equal(fs.existsSync(path.join(root,'users')),false);
});

test('production read-only preflight accepts the reviewed schemas without creating user data or touching the legacy database',t=>{
  const {env}=productionFixture(t),before=fs.readFileSync(env.SQLITE_DB_PATH);
  const config=resolveInvestmentRuntimeConfig(env);
  a.equal(config.production,true);a.equal(config.cutoff,'2026-09-11');a.equal(config.research,env.INVESTMENT_SOURCE_DB_PATH);
  a.deepEqual(fs.readFileSync(env.SQLITE_DB_PATH),before);a.equal(fs.existsSync(env.INVESTMENT_DB_PATH),false);
});

test('production requires a verified AI Insights release and rejects corrupt or mismatched generations',t=>{
  const {env,aiRoot,aiReleasePath}=productionFixture(t);
  a.throws(()=>resolveInvestmentRuntimeConfig({...env,AI_INSIGHTS_ROOT:undefined}),/ai_insights_artifact_root_required/);
  a.throws(()=>resolveInvestmentRuntimeConfig({...env,AI_INSIGHTS_RELEASE_MANIFEST_PATH:undefined}),/ai_insights_release_manifest_required/);
  const release=JSON.parse(fs.readFileSync(aiReleasePath,'utf8'));
  release.currentGeneration='e'.repeat(64);
  fs.chmodSync(aiReleasePath,0o600);fs.writeFileSync(aiReleasePath,JSON.stringify(release));fs.chmodSync(aiReleasePath,0o400);
  a.throws(()=>validateAiInsightsArtifact(aiRoot,aiReleasePath,{trustedUid:fs.statSync(aiReleasePath).uid}),/current_generation_missing|identity_mismatch/);
});

test('production preflight rejects copied local account tables and existing broker-store destinations',t=>{
  const {env,updateManifest}=productionFixture(t);
  const privateDb=new DatabaseSync(env.INVESTMENT_DB_PATH);privateDb.exec('CREATE TABLE portfolio_credentials(owner TEXT)');privateDb.close();
  a.throws(()=>resolveInvestmentRuntimeConfig(env),/private_store_schema_conflict/);
  a.throws(()=>new InvestmentStore(env.INVESTMENT_DB_PATH,undefined,{verifiedOwnersOnly:true}),/private_store_schema_conflict/);
  const source=new DatabaseSync(env.INVESTMENT_SOURCE_DB_PATH);source.exec('CREATE TABLE portfolio_nav_points(owner TEXT)');source.close();updateManifest();
  a.throws(()=>resolveInvestmentRuntimeConfig(env),/unexpected_source_table/);
});

test('production preflight rejects local-dev journal owners and stale warehouse schema identities',t=>{
  const {env,updateManifest}=productionFixture(t);
  const store=new InvestmentStore(env.INVESTMENT_DB_PATH);
  store.write('local-dev-user','strategy','','preview_fixture_1234',{},()=>({fixture:true}));store.close();
  a.throws(()=>resolveInvestmentRuntimeConfig(env),/unverified_owner/);
  a.throws(()=>new InvestmentStore(env.INVESTMENT_DB_PATH,undefined,{verifiedOwnersOnly:true}),/unverified_owner/);
  const warehouse=new DatabaseSync(env.STRATEGY_DATA_DB_PATH);warehouse.exec("UPDATE warehouse_meta SET security_version='old'");warehouse.close();updateManifest();
  a.throws(()=>resolveInvestmentRuntimeConfig(env),/strategy_database_version_mismatch/);
});

test('production append-only journal accepts verified UUID owner and remains isolated after reopen',t=>{
  const {root}=fixture(t),file=path.join(root,'journal.sqlite'),owner=crypto.randomUUID(),other=crypto.randomUUID();
  const store=new InvestmentStore(file,undefined,{verifiedOwnersOnly:true});
  const saved=store.write(owner,'strategy_lab','','test_operation_12345',{rule:1},()=>({asOf:'2026-09-11',rule:1}));
  for(const invalid of ['local-dev-user','admin','',null,'../user']) {
    a.equal(verifiedInvestmentOwner(invalid),false);
    a.throws(()=>store.write(invalid,'strategy_lab','','test_operation_12345',{rule:1},()=>({rule:1})),/unauthorized/);
  }
  a.throws(()=>store.get(other,saved.id),/record_not_found/);store.close();
  const reopened=new InvestmentStore(file,undefined,{verifiedOwnersOnly:true});
  a.equal(reopened.list(owner)[0].id,saved.id);a.deepEqual(reopened.list(other),[]);reopened.close();
});

test('production investment route identity requires matching verified bearer subject, not user or owner overrides',async t=>{
  const id=crypto.randomUUID();
  const app=express();app.use('/api/investment',portfolioResponsePrivacy);
  app.use((req,_,next)=>{if(req.headers['x-fixture-user'])req.user={id:req.headers['x-fixture-user']};if(req.headers['x-fixture-verified'])req.auth={user:{id:req.headers['x-fixture-verified']}};next();});
  app.use('/api/investment',investmentProductionIdentity);app.get('/api/investment/test',(req,res)=>res.json({owner:req.user.id}));
  const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));t.after(()=>new Promise(r=>server.close(r)));
  for(const headers of [{},{'x-fixture-user':id},{'x-fixture-user':id,'x-fixture-verified':crypto.randomUUID()},
    {'x-fixture-user':'local-dev-user','x-fixture-verified':'local-dev-user'}]) {
    const r=await fetch(`http://127.0.0.1:${server.address().port}/api/investment/test?owner=${id}`,{headers});
    a.equal(r.status,401);a.match(r.headers.get('cache-control'),/no-store/);a.match(r.headers.get('vary'),/Authorization/);
  }
  const r=await fetch(`http://127.0.0.1:${server.address().port}/api/investment/test?owner=other`,{headers:{'x-fixture-user':id,'x-fixture-verified':id}});
  a.equal(r.status,200);a.deepEqual(await r.json(),{owner:id});
});

test('production strategy compute fits a single bounded worker instead of an unbounded queue',()=>{
  const limits=strategyWorkerLimits({NODE_ENV:'production'});
  a.equal(limits.maxActive,1);a.equal(limits.resourceLimits.maxOldGenerationSizeMb,512);
  a.equal(strategyWorkerLimits({NODE_ENV:'test'}).maxActive,2);
});
