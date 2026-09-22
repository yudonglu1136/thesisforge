import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from .pipeline.publisher import prepare,activate,load_active
from .pipeline.installer import install
from .pipeline.contracts import digest


class Missing(Exception):
    response={'Error':{'Code':'NoSuchKey'}}


class MemoryS3:
    def __init__(self):self.objects={};self.calls=[]
    def head_object(self,*,Bucket,Key):
        if Key not in self.objects:raise Missing()
        body,metadata=self.objects[Key]
        return {'ContentLength':len(body),'Metadata':metadata,'ETag':hashlib.sha256(body).hexdigest()}
    def put_object(self,*,Bucket,Key,Body,Metadata=None,IfMatch=None,IfNoneMatch=None,**kwargs):
        if IfNoneMatch and Key in self.objects:raise ValueError('precondition_failed')
        if IfMatch and self.head_object(Bucket=Bucket,Key=Key)['ETag']!=IfMatch:raise ValueError('precondition_failed')
        body=Body.read() if hasattr(Body,'read') else Body
        self.objects[Key]=(body,Metadata or {});self.calls.append(Key)
    def get_object(self,*,Bucket,Key):
        info=self.head_object(Bucket=Bucket,Key=Key)
        return {**info,'Body':io.BytesIO(self.objects[Key][0])}
    def download_fileobj(self,bucket,key,stream):stream.write(self.objects[key][0])


class PublicationTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.store=SimpleNamespace(root=self.root)
        self.s3=MemoryS3()
        file=self.root/'source.sqlite';file.write_bytes(b'synthetic-public-data')
        entry={'path':file.name,'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'bytes':file.stat().st_size}
        self.receipt={'runId':'run1','snapshotId':'s','groups':{'institutional_13f':{'groupId':'institutional_13f',
            'generationId':'a'*64,'members':{'all':'a','active':'a'},'inputVector':{},'compatibilityVersion':'fixture',
            'requiredMatrix':['all','active'],'checks':{'fixture':'pass'},'files':[entry]}}}

    def candidate(self):return prepare(self.s3,'bucket',self.store,self.receipt)[0]
    def ack(self,candidate):return {'status':'verified','releaseId':candidate['releaseId'],
        'actualApiUserRead':True,'canonicalReadVerified':True}

    def test_upload_alone_is_not_activation(self):
        candidate=self.candidate()
        self.assertEqual(load_active(self.s3,'bucket'),(None,None))
        with self.assertRaises(ValueError):activate(self.s3,'bucket',candidate,None,{'status':'uploaded'})
        activate(self.s3,'bucket',candidate,None,self.ack(candidate))
        self.assertEqual(load_active(self.s3,'bucket')[0]['releaseId'],candidate['releaseId'])

    def test_unchanged_publication_reuses_objects_and_preserves_active_bytes(self):
        candidate=self.candidate();activate(self.s3,'bucket',candidate,None,self.ack(candidate))
        previous,etag=load_active(self.s3,'bucket');calls=len(self.s3.calls)
        replay,result=prepare(self.s3,'bucket',self.store,self.receipt,previous)
        self.assertEqual(result['status'],'unchanged');self.assertEqual(len(self.s3.calls),calls)
        activate(self.s3,'bucket',replay,etag,self.ack(replay))
        self.assertEqual(load_active(self.s3,'bucket')[1],etag)

    def test_old_worker_cannot_overwrite_new_release(self):
        candidate=self.candidate();activate(self.s3,'bucket',candidate,None,self.ack(candidate))
        newer={**candidate,'releaseId':'b'*64}
        with self.assertRaisesRegex(ValueError,'stale_worker_fence'):activate(self.s3,'bucket',newer,None,self.ack(newer))

    def test_failed_activated_probe_restores_previous_pointer(self):
        candidate=self.candidate();target=self.root/'installed'
        first=install(self.s3,'bucket',candidate,target,validate_group=lambda *args:None,
            probe=lambda c,active:self.ack(c))
        before=(target/'active.json').read_bytes()
        newer={**candidate,'releaseId':'b'*64}
        def fail(c,active):
            if active:raise ValueError('actual_api_probe_failed')
            return {}
        with self.assertRaisesRegex(ValueError,'actual_api_probe_failed'):
            install(self.s3,'bucket',newer,target,validate_group=lambda *args:None,probe=fail,expected_release=first['releaseId'])
        self.assertEqual((target/'active.json').read_bytes(),before)

    def test_corrupt_object_never_gets_an_active_pointer(self):
        candidate=self.candidate()
        key=next(key for key in self.s3.objects if '/objects/' in key)
        self.s3.objects[key]=(b'corrupt',self.s3.objects[key][1])
        target=self.root/'installed'
        with self.assertRaisesRegex(ValueError,'download_checksum_mismatch'):
            install(self.s3,'bucket',candidate,target,validate_group=lambda *args:None,probe=lambda *args:{})
        self.assertFalse((target/'active.json').exists())

    def test_missing_atomic_group_keeps_previous_group_reference(self):
        first=self.candidate()
        receipt={**self.receipt,'groups':{}}
        retained,result=prepare(self.s3,'bucket',self.store,receipt,first)
        self.assertEqual(retained['groups'],first['groups'])
        self.assertEqual(result['status'],'unchanged')

    def test_validator_failure_does_not_activate(self):
        candidate=self.candidate()
        def fail(*args):raise ValueError('schema_or_identity_invalid')
        with self.assertRaisesRegex(ValueError,'schema_or_identity_invalid'):
            install(self.s3,'bucket',candidate,self.root/'installed',validate_group=fail,probe=lambda *args:{})
        self.assertFalse((self.root/'installed/active.json').exists())
