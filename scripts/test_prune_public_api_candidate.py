import unittest,tempfile,json,hashlib,io,os,time,fcntl,importlib.util
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('prune',Path(__file__).with_name('prune-public-api-candidate.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Tests(unittest.TestCase):
 def setUp(self):
  reader=patch.object(m,'open_reader_check');reader.start();self.addCleanup(reader.stop);self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name).resolve();self.lease=self.root/'leases';self.lease.mkdir();self.gen='a'*64;self.base=self.root/'releases/institutional_13f'/self.gen;self.base.mkdir(parents=True);self.file=self.base/'data.sqlite';self.file.write_bytes(b'public fixture');self.file.chmod(0o444);os.utime(self.base,(time.time()-9*86400,)*2)
  self.sha=hashlib.sha256(self.file.read_bytes()).hexdigest();key='fact-os/published/objects/'+self.sha
  manifest={'groupId':'institutional_13f','generationId':self.gen,'files':[{'path':'data.sqlite','bytes':14,'sha256':self.sha,'key':key}]};raw=json.dumps(manifest).encode();sha=hashlib.sha256(raw).hexdigest();mk='fact-os/published/groups/institutional_13f/'+sha+'.json';self.candidate={'groups':{'institutional_13f':{'generationId':self.gen,'manifestKey':mk,'manifestSha256':sha}}};self.objects={mk:raw,key:b'public fixture'}
  self.s3=type('S3',(),{'get_object':lambda _,**kw:{'Body':io.BytesIO(self.objects[kw['Key']])}})();self.pointer=self.root/'active.json';self.pointer.write_text(json.dumps({'groups':{'institutional_13f':{'generationId':'b'*64}}}))
 def run_prune(self,apply=False):return m.prune(self.root,self.lease,self.candidate,self.s3,'bucket',apply=apply)
 def test_dry_run_apply_idempotence_and_pointer(self):
  before=self.pointer.read_bytes();self.assertEqual(self.run_prune()['status'],'dry_run');self.assertTrue(self.file.exists());self.assertEqual(self.run_prune(True)['deletedFiles'],1);self.assertEqual(self.pointer.read_bytes(),before);self.assertEqual(self.run_prune(True)['deletedFiles'],0)
 def test_active_and_research_protection(self):
  (self.root/'research-active.json').write_text(json.dumps(self.candidate))
  with self.assertRaisesRegex(ValueError,'active_reference'):self.run_prune(True)
  self.assertTrue(self.file.exists())
 def test_remote_corruption(self):
  self.objects['fact-os/published/objects/'+self.sha]=b'wrong'
  with self.assertRaisesRegex(ValueError,'remote_restore_checksum'):self.run_prune(True)
  self.assertTrue(self.file.exists())
 def test_extra_file_and_symlink(self):
  extra=self.base/'unknown';extra.write_text('retain');os.utime(self.base,(time.time()-9*86400,)*2)
  with self.assertRaisesRegex(ValueError,'unlisted'):self.run_prune(True)
  extra.unlink();extra.symlink_to(self.file);os.utime(self.base,(time.time()-9*86400,)*2)
  with self.assertRaisesRegex(ValueError,'symlink'):self.run_prune(True)
 def test_lease_and_retention(self):
  with (self.lease/(hashlib.sha256(str(self.base).encode()).hexdigest()+'.lock')).open('a') as lock:
   fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
   with self.assertRaises(BlockingIOError):self.run_prune(True)
  os.utime(self.base,None)
  with self.assertRaisesRegex(ValueError,'retention'):self.run_prune(True)
 def test_open_reader_blocks_delete(self):
  with patch.object(m,'open_reader_check',side_effect=ValueError('open_reader')):
   with self.assertRaisesRegex(ValueError,'open_reader'):self.run_prune(True)
  self.assertTrue(self.file.exists())
 def test_local_corruption(self):
  self.file.chmod(0o644);self.file.write_bytes(b'changed');self.file.chmod(0o444)
  with self.assertRaisesRegex(ValueError,'checksum'):self.run_prune(True)
 def test_exact_rejected_candidate_retirement_still_protects_active(self):
  os.utime(self.base,None)
  with self.assertRaisesRegex(ValueError,'retention'):self.run_prune()
  result=m.prune(self.root,self.lease,self.candidate,self.s3,'bucket',retired_failed_generation=self.gen)
  self.assertEqual(result['status'],'dry_run');self.assertTrue(self.file.exists())
  self.pointer.write_text(json.dumps(self.candidate))
  with self.assertRaisesRegex(ValueError,'active_reference'):
   m.prune(self.root,self.lease,self.candidate,self.s3,'bucket',apply=True,retired_failed_generation=self.gen)
 def test_operator_retirement_exact_scope_and_integrity(self):
  os.utime(self.base,None)
  with self.assertRaisesRegex(ValueError,'invalid_failed_generation_override'):
   m.prune(self.root,self.lease,self.candidate,self.s3,'bucket',retired_generation='c'*64)
  with patch.object(m,'open_reader_check',side_effect=ValueError('open_reader')):
   with self.assertRaisesRegex(ValueError,'open_reader'):
    m.prune(self.root,self.lease,self.candidate,self.s3,'bucket',apply=True,retired_generation=self.gen)
  self.assertTrue(self.file.exists())
  result=m.prune(self.root,self.lease,self.candidate,self.s3,'bucket',apply=True,retired_generation=self.gen)
  self.assertEqual(result['deletedFiles'],1)
  self.assertEqual(result['operatorRetiredGeneration'],self.gen)
 def test_operator_retirement_never_removes_reference(self):
  self.pointer.write_text(json.dumps(self.candidate))
  with self.assertRaisesRegex(ValueError,'active_reference'):
   m.prune(self.root,self.lease,self.candidate,self.s3,'bucket',apply=True,retired_generation=self.gen)
 def test_rollback_active_pointer_protects_immediate_rollback_generation(self):
  (self.root/'rollback-active.json').write_text(json.dumps(self.candidate))
  with self.assertRaisesRegex(ValueError,'active_reference'):
   self.run_prune(True)
  self.assertTrue(self.file.exists())
 def test_prune_superseded_releases_keeps_active_and_rollback_evicts_older_and_dedups_canonical(self):
  root=self.root/'rolling';lease=root/'leases';lease.mkdir(parents=True)
  objects={}
  s3=type('S3',(),{'get_object':lambda _,**kw:{'Body':io.BytesIO(objects[kw['Key']])}})()
  canonical_bytes=b'immutable-canonical-parquet-payload'
  canonical_sha=hashlib.sha256(canonical_bytes).hexdigest()
  canonical_obj_key='fact-os/published/objects/'+canonical_sha
  objects[canonical_obj_key]=canonical_bytes
  prev_rel=None;releases=[]
  for idx,ch in enumerate(('1','2','3','4'),start=1):
   gen=ch*64;rel_id=hex(idx)[2:].zfill(64)
   # institutional_13f group
   g1_dir=root/'releases/institutional_13f'/gen;g1_dir.mkdir(parents=True)
   payload=f'13f-v{idx}'.encode();sha=hashlib.sha256(payload).hexdigest()
   obj_key='fact-os/published/objects/'+sha;objects[obj_key]=payload
   f1=g1_dir/'13f-insights.sqlite';f1.write_bytes(payload);f1.chmod(0o444);g1_dir.chmod(0o555)
   m1={'groupId':'institutional_13f','generationId':gen,'files':[{'path':'13f-insights.sqlite','bytes':len(payload),'sha256':sha,'key':obj_key}]}
   m1_raw=json.dumps(m1).encode();m1_sha=hashlib.sha256(m1_raw).hexdigest()
   m1_key='fact-os/published/groups/institutional_13f/'+m1_sha+'.json';objects[m1_key]=m1_raw
   # canonical group (independent inodes initially for r3 and r4 so dedup consolidates them)
   c_root=root/'releases/canonical'/gen
   c_dir=c_root/'parquet/stocks';c_dir.mkdir(parents=True)
   rel_part='parquet/stocks/2020-'+'a'*32+'.parquet'
   cf=c_root/rel_part;cf.write_bytes(canonical_bytes);cf.chmod(0o444)
   cat_dir=c_root/'manifests';cat_dir.mkdir(parents=True)
   cat_bytes=json.dumps({'datasets':{'stocks':{'partitions':[{'path':rel_part,'sha256':canonical_sha,'bytes':len(canonical_bytes)}]}}}).encode()
   cat_sha=hashlib.sha256(cat_bytes).hexdigest();cat_obj_key='fact-os/published/objects/'+cat_sha;objects[cat_obj_key]=cat_bytes
   cat_file=cat_dir/'catalog.json';cat_file.write_bytes(cat_bytes);cat_file.chmod(0o444)
   cat_dir.chmod(0o555);c_dir.chmod(0o555);c_dir.parent.chmod(0o555);c_root.chmod(0o555)
   mc={'groupId':'canonical','generationId':gen,'files':[
    {'path':rel_part,'bytes':len(canonical_bytes),'sha256':canonical_sha,'key':canonical_obj_key},
    {'path':'manifests/catalog.json','bytes':len(cat_bytes),'sha256':cat_sha,'key':cat_obj_key},
   ]}
   mc_raw=json.dumps(mc).encode();mc_sha=hashlib.sha256(mc_raw).hexdigest()
   mc_key='fact-os/published/groups/canonical/'+mc_sha+'.json';objects[mc_key]=mc_raw
   desc={'releaseId':rel_id,'previousRelease':prev_rel,'groups':{
    'institutional_13f':{'generationId':gen,'manifestKey':m1_key,'manifestSha256':m1_sha,'root':str(g1_dir)},
    'canonical':{'generationId':gen,'manifestKey':mc_key,'manifestSha256':mc_sha,'root':str(root/'releases/canonical'/gen)},
   }}
   objects['fact-os/published/releases/'+rel_id+'.json']=json.dumps(desc).encode()
   releases.append(desc);prev_rel=rel_id
  (root/'active.json').write_text(json.dumps(releases[3]))
  (root/'rollback-active.json').write_text(json.dumps(releases[2]))
  # Dry run reports 4 superseded group generations (r1 + r2 across 2 groups) without deleting.
  dry=m.prune_superseded_releases(root,lease,s3,'bucket',keep_releases=2,apply=False)
  self.assertEqual(dry['status'],'dry_run')
  self.assertEqual(len(dry['prunedGenerations']),4)
  self.assertTrue((root/'releases/institutional_13f'/('1'*64)).exists())
  # Simulate open reader on r2 institutional_13f: r2 institutional_13f defers, others evict cleanly.
  r2_13f=str((root/'releases/institutional_13f'/('2'*64)).resolve())
  def selective_reader(targets):
   if any(str(t)==r2_13f for t in targets):raise ValueError('open_reader')
  with patch.object(m,'open_reader_check',side_effect=selective_reader):
   partial=m.prune_superseded_releases(root,lease,s3,'bucket',keep_releases=2,apply=True)
  self.assertEqual(len(partial['prunedGenerations']),3)
  self.assertEqual(partial['deferredGenerations'],[{'group':'institutional_13f','generationId':'2'*64,'reason':'open_reader'}])
  self.assertTrue((root/'releases/institutional_13f'/('2'*64)).exists())
  # Once reader closes, next run evicts r2 institutional_13f and consolidates r3+r4 canonical hardlinks.
  final=m.prune_superseded_releases(root,lease,s3,'bucket',keep_releases=2,apply=True)
  self.assertEqual(len(final['prunedGenerations']),1)
  self.assertEqual(final['deferredGenerations'],[])
  self.assertFalse((root/'releases/institutional_13f'/('1'*64)).exists())
  self.assertFalse((root/'releases/institutional_13f'/('2'*64)).exists())
  self.assertTrue((root/'releases/institutional_13f'/('3'*64)).exists())
  self.assertTrue((root/'releases/institutional_13f'/('4'*64)).exists())
  c3=root/'releases/canonical'/('3'*64)/'parquet/stocks'/('2020-'+'a'*32+'.parquet')
  c4=root/'releases/canonical'/('4'*64)/'parquet/stocks'/('2020-'+'a'*32+'.parquet')
  self.assertEqual(c3.stat().st_ino,c4.stat().st_ino)
  self.assertTrue((root/'audit/api-retention-latest.json').is_file())
if __name__=='__main__':unittest.main()
