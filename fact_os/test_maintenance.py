import json
import os
import shutil
import tempfile
import time
import unittest
from pathlib import Path

from .maintenance import collect_unreferenced, prune_writer_retention
from .pipeline.ledger import Ledger
from .pipeline.snapshots import freeze
from .repository import FactRepository
from .store import Store


class MaintenanceTest(unittest.TestCase):
    def test_raw_and_pinned_readers_are_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);store=Store(root/'warehouse')
            store.install_contract('stocks','CREATE TABLE IF NOT EXISTS "stocks" ("ticker" TEXT,"date" TEXT,"close" REAL,"closeadj" REAL,"closeunadj" REAL,PRIMARY KEY ("ticker","date"));')
            source=root/'input.csv';source.write_text('ticker,date,close,closeadj,closeunadj\nABC,2020-01-02,1,1,1\n')
            store.ingest('stocks',source,scope='verified_full_bulk')
            active=next((store.root/'parquet/stocks').glob('*.parquet'))
            for value in ('a','b'):
                copy=active.with_name('2020-'+value*32+'.parquet');shutil.copyfile(active,copy)
                timestamp=time.time()-9*86400;os.utime(copy,(timestamp,timestamp))
            raw=store.root/'raw/permanent.zip';raw.write_bytes(b'preserved')
            with FactRepository(store.root):
                self.assertEqual(collect_unreferenced(store,apply=True)['status'],'readers_active')
            preview=collect_unreferenced(store)
            self.assertEqual(len(preview['candidates']),1)
            self.assertEqual(preview['deleted_files'],0)
            result=collect_unreferenced(store,apply=True)
            self.assertEqual(result['deleted_files'],1)
            self.assertTrue(active.exists());self.assertEqual(raw.read_bytes(),b'preserved')
            self.assertEqual(len(list(active.parent.glob('*.parquet'))),2)

    def test_prune_writer_retention_retires_expired_pins_hardlinks_and_derived_caches(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            store = Store(root / 'warehouse')
            store.install_contract(
                'stocks',
                'CREATE TABLE IF NOT EXISTS "stocks" ("ticker" TEXT,"date" TEXT,"close" REAL,'
                '"closeadj" REAL,"closeunadj" REAL,PRIMARY KEY ("ticker","date"));',
            )
            old_ts = time.time() - 12 * 86400
            mid_ts = time.time() - 10 * 86400

            def ingest_and_freeze(price, version, backdate=None):
                csv_path = root / f'input-{version}.csv'
                csv_path.write_text(f'ticker,date,close,closeadj,closeunadj\nABC,2020-01-02,{price},{price},{price}\n')
                store.ingest('stocks', csv_path, scope='verified_full_bulk')
                snap = freeze(store, code_version=version)
                part_rel = snap.inputs['stocks']['partitions'][0]['path']
                part_path = store.root / part_rel
                pin_path = store.root / 'sync/snapshot-pins' / f'{snap.snapshotId}.json'
                snap_dir = store.root / 'snapshots' / snap.snapshotId
                pin_value = json.loads(pin_path.read_text())
                self.assertIn('createdAt', pin_value)
                if backdate is not None:
                    os.utime(part_path, (backdate, backdate))
                    os.utime(pin_path, (backdate, backdate))
                    os.utime(snap_dir, (backdate, backdate))
                return snap, part_path, pin_path, snap_dir

            s1, p1, pin1, dir1 = ingest_and_freeze(1, 'v1', backdate=old_ts)
            s2, p2, pin2, dir2 = ingest_and_freeze(2, 'v2', backdate=mid_ts)
            s3, p3, _, _ = ingest_and_freeze(3, 'v3')
            s4, p4, _, _ = ingest_and_freeze(4, 'v4')

            # Record s2 as a verified run in Ledger so min_runs=2 protects it even past 7 days.
            ledger = Ledger(store)
            for run_id, snap_id, pub_status in (
                ('run-2', s2.snapshotId, 'verified'),
                ('run-4', s4.snapshotId, 'verified'),
            ):
                receipt = {
                    'runId': run_id,
                    'profile': 'aws-data-daily',
                    'scheduledFor': '2026-11-01T04:30:00Z',
                    'startedAt': '2026-11-01T04:30:01Z',
                    'finishedAt': '2026-11-01T04:35:00Z',
                    'status': 'succeeded',
                    'snapshotId': snap_id,
                    'tasks': {},
                    'groups': {},
                }
                ledger.run(run_id, 'aws-data-daily', receipt['scheduledFor'], snap_id, 'succeeded', receipt=receipt)
                ledger.publication(receipt, pub_status, {'releaseId': 'f' * 64})

            # Non-pipeline pin (saved-research) older than 30 days must never be retired.
            research_parquet = p4.with_name('2020-' + 'e' * 32 + '.parquet')
            shutil.copyfile(p4, research_parquet)
            very_old = time.time() - 30 * 86400
            os.utime(research_parquet, (very_old, very_old))
            research_pin = store.root / 'sync/snapshot-pins' / ('e' * 64 + '.json')
            research_pin.write_text(json.dumps({
                'snapshotId': 'e' * 64,
                'reason': 'saved-research',
                'paths': [str(research_parquet.relative_to(store.root))],
            }))
            os.utime(research_pin, (very_old, very_old))

            # Derived pipeline caches: 4 generations (2 old >7d, 2 recent), read-only 0o444/0o555.
            task_root = store.root / 'derived/pipeline/institutional_13f'
            builds = {}
            for idx, (char, age) in enumerate([('1', old_ts), ('2', mid_ts), ('3', None), ('4', None)], start=1):
                gen = char * 64
                bdir = task_root / gen
                bdir.mkdir(parents=True)
                sqlite_file = bdir / '13f-insights.sqlite'
                sqlite_file.write_bytes(b'x' * 128)
                sqlite_file.chmod(0o444)
                bdir.chmod(0o555)
                if age is not None:
                    os.utime(sqlite_file, (age, age))
                    os.utime(bdir, (age, age))
                builds[idx] = bdir

            # Protect build #2 via audit/pipeline/latest.json receipt reference.
            audit_dir = store.root / 'audit/pipeline'
            audit_dir.mkdir(parents=True, exist_ok=True)
            (audit_dir / 'latest.json').write_text(json.dumps({
                'runId': 'run-latest',
                'snapshotId': s4.snapshotId,
                'tasks': {'institutional_13f': {'artifactId': '2' * 64}},
            }))

            # Permanent/protected directories must never be touched regardless of age.
            raw_zip = store.root / 'raw/vendor-history.zip'
            raw_zip.write_bytes(b'raw-forever')
            ai_keep = store.root / 'derived/ai-insights/preserved.json'
            ai_keep.parent.mkdir(parents=True, exist_ok=True)
            ai_keep.write_text('{"ok":true}')
            boot_keep = store.root / 'derived/rule-bootstrap/preserved.json'
            boot_keep.parent.mkdir(parents=True, exist_ok=True)
            boot_keep.write_text('{"ok":true}')
            for perm in (raw_zip, ai_keep, boot_keep):
                os.utime(perm, (very_old, very_old))

            # Active reader blocks retention safely.
            with FactRepository(store.root):
                busy = prune_writer_retention(
                    store, retention_days=7, min_runs=2, min_snapshots=2, min_task_generations=2, apply=True
                )
                self.assertEqual(busy['status'], 'readers_active')
            self.assertTrue(pin1.exists())

            # Dry-run accurately reports s1 + build #1 + p1 without mutating disk.
            dry = prune_writer_retention(
                store, retention_days=7, min_runs=2, min_snapshots=2, min_task_generations=2, apply=False
            )
            self.assertEqual(dry['status'], 'dry_run')
            self.assertEqual(dry['retirable_snapshot_pins'], 1)
            self.assertEqual(dry['retired_snapshot_pins'], 0)
            self.assertEqual(dry['reclaimable_snapshot_dirs'], 1)
            self.assertEqual(dry['reclaimable_derived_dirs'], 1)
            self.assertEqual(len(dry['candidates']), 1)
            self.assertTrue(pin1.exists())
            self.assertTrue(dir1.exists())
            self.assertTrue(p1.exists())
            self.assertTrue(builds[1].exists())

            # Apply retires s1 pin, removes s1 hardlink tree, collects p1, and evicts build #1.
            applied = prune_writer_retention(
                store, retention_days=7, min_runs=2, min_snapshots=2, min_task_generations=2, apply=True
            )
            self.assertEqual(applied['status'], 'collected')
            self.assertEqual(applied['retired_snapshot_pins'], 1)
            self.assertEqual(applied['deleted_snapshot_dirs'], 1)
            self.assertEqual(applied['evicted_derived_dirs'], 1)
            self.assertEqual(applied['deleted_parquet_files'], 1)

            self.assertFalse(pin1.exists())
            self.assertFalse(dir1.exists())
            self.assertFalse(p1.exists())
            self.assertFalse(builds[1].exists())

            # Protected artifacts remain untouched.
            self.assertTrue(pin2.exists())
            self.assertTrue(dir2.exists())
            self.assertTrue(p2.exists())
            self.assertTrue(p3.exists())
            self.assertTrue(p4.exists())
            self.assertTrue(research_pin.exists())
            self.assertTrue(research_parquet.exists())
            self.assertTrue(builds[2].exists())
            self.assertTrue(builds[3].exists())
            self.assertTrue(builds[4].exists())
            self.assertEqual(raw_zip.read_bytes(), b'raw-forever')
            self.assertTrue(ai_keep.exists())
            self.assertTrue(boot_keep.exists())
            self.assertTrue((audit_dir / 'retired-snapshot-pins-latest.json').is_file())
            self.assertTrue((audit_dir / 'retention-latest.json').is_file())

    def test_prune_writer_retention_fails_closed_on_corrupt_pin_or_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(Path(temp) / 'warehouse')
            pins = store.root / 'sync/snapshot-pins'
            pins.mkdir(parents=True, exist_ok=True)
            bad_pin = pins / ('a' * 64 + '.json')
            bad_pin.write_text('{"paths":"not-a-list"}')
            with self.assertRaisesRegex(ValueError, 'invalid_snapshot_pin'):
                prune_writer_retention(store, apply=True)
            bad_pin.unlink()

            old_ts = time.time() - 12 * 86400
            task_root = store.root / 'derived/pipeline/public_observations'
            for char in ('1', '2'):
                d = task_root / (char * 64)
                d.mkdir(parents=True)
                f = d / 'observations.sqlite'
                f.write_bytes(b'ok')
                os.utime(f, (old_ts, old_ts))
                os.utime(d, (old_ts, old_ts))
            evil = task_root / ('1' * 64) / 'escape.lnk'
            evil.symlink_to(store.root / 'raw')
            os.utime(task_root / ('1' * 64), (old_ts - 60, old_ts - 60))
            with self.assertRaisesRegex(ValueError, 'symlink_in_retention_target'):
                prune_writer_retention(store, min_task_generations=1, apply=True)
            self.assertTrue((task_root / ('1' * 64) / 'observations.sqlite').exists())


if __name__=='__main__':unittest.main()
