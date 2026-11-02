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
if __name__=='__main__':unittest.main()
