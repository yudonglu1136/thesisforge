import importlib.util
import fcntl
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fact_os.store import checksum

spec=importlib.util.spec_from_file_location('dedup',Path(__file__).with_name('deduplicate-canonical-release-files.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)


class DedupTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve();self.paths=[]
        for name in ('a','b'):
            base=self.root/'releases/canonical'/(name*64)
            file=base/'parquet/stocks/2026.parquet';file.parent.mkdir(parents=True)
            file.write_bytes(b'fixed-public-test-bytes');file.chmod(0o444)
            catalog=base/'manifests/catalog.json';catalog.parent.mkdir()
            catalog.write_text(json.dumps({'datasets':{'stocks':{'partitions':[
                {'path':'parquet/stocks/2026.parquet','sha256':checksum(file),'bytes':file.stat().st_size}]}}}))
            self.paths.append(file)

    def test_dry_run_and_apply_preserve_paths_bytes_reader_and_pointer(self):
        a,b=self.paths;active=self.root/'active.json';active.write_text('unchanged')
        old_reader=b.open('rb');self.addCleanup(old_reader.close)
        self.assertEqual(module.consolidate(self.root)['plannedPaths'],1)
        self.assertFalse(os.path.samefile(a,b))
        report=module.consolidate(self.root,apply=True)
        self.assertEqual(report['status'],'verified');self.assertTrue(os.path.samefile(a,b))
        self.assertEqual(old_reader.read(),a.read_bytes())
        self.assertEqual(active.read_text(),'unchanged')
        self.assertEqual(module.consolidate(self.root,apply=True)['plannedPaths'],0)
        self.assertEqual(b.stat().st_mode & 0o777,0o444)

    def test_corruption_fails_before_any_replacement(self):
        b=self.paths[1];b.chmod(0o644);b.write_bytes(b'x'*b.stat().st_size);b.chmod(0o444)
        with self.assertRaisesRegex(ValueError,'checksum'):module.consolidate(self.root,apply=True)
        self.assertFalse(os.path.samefile(*self.paths))
        self.assertEqual(json.loads(next((self.root/'audit').glob('*.json')).read_text())['status'],'failed')

    def test_writable_or_symlink_partition_rejected(self):
        b=self.paths[1];b.chmod(0o644)
        with self.assertRaisesRegex(ValueError,'immutable'):module.consolidate(self.root)
        b.unlink();b.symlink_to(self.paths[0])
        with self.assertRaisesRegex(ValueError,'escape'):module.consolidate(self.root)

    def test_failed_replace_preserves_original_and_permissions(self):
        b=self.paths[1];mode=b.parent.stat().st_mode & 0o777
        with patch.object(module.os,'replace',side_effect=OSError('injected')):
            with self.assertRaises(OSError):module.consolidate(self.root,apply=True)
        self.assertFalse(os.path.samefile(*self.paths))
        self.assertEqual(self.paths[0].read_bytes(),b.read_bytes())
        self.assertEqual(b.parent.stat().st_mode & 0o777,mode)
        self.assertFalse(list(b.parent.glob('.deduplicate-*')))

    def test_install_lock_and_noncanonical_files_are_preserved(self):
        other=self.root/'releases/ai_insights'/('c'*64)/'data.sqlite'
        other.parent.mkdir(parents=True);other.write_bytes(self.paths[0].read_bytes())
        before=other.stat().st_ino
        with (self.root/'install.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):module.consolidate(self.root,apply=True)
        module.consolidate(self.root,apply=True)
        self.assertEqual(other.stat().st_ino,before)
        self.assertEqual(other.stat().st_nlink,1)


if __name__=='__main__':unittest.main()
