import json
import shutil
import tempfile
import unittest
from pathlib import Path
from .store import Store
from .test_store_revision import StoreRevisionTest
from .pipeline.migration import export_authority,restore_metadata


class AuthorityMigrationTest(unittest.TestCase):
    setUp=StoreRevisionTest.setUp
    tearDown=StoreRevisionTest.tearDown
    source=StoreRevisionTest.source
    row=StoreRevisionTest.row

    def test_independent_install_metadata_and_catalog_replay_no_database_copy(self):
        self.store.ingest('stocks',self.source('full.csv',[self.row()]),scope='verified_full_bulk')
        _,manifest=export_authority(self.store)
        self.assertFalse(any(e['path'].endswith('.duckdb') for e in manifest['files']))
        with tempfile.TemporaryDirectory() as directory:
            target=Store(Path(directory))
            for item in manifest['files']:
                destination=target.root/item['path'];destination.parent.mkdir(parents=True,exist_ok=True)
                shutil.copyfile(self.store.root/item['path'],destination)
            self.assertEqual(restore_metadata(target,manifest)['status'],'imported')
            self.assertEqual(restore_metadata(target,manifest)['status'],'already_imported')
            from .repository import FactRepository
            with FactRepository(target.root) as repo:
                self.assertEqual(repo.db.execute('SELECT close FROM stocks').fetchone()[0],10)
            self.assertEqual(json.loads((target.root/'manifests/catalog.json').read_text())['datasets']['stocks']['contentVersion'],
                             json.loads((self.store.root/'manifests/catalog.json').read_text())['datasets']['stocks']['contentVersion'])

    def test_private_metadata_and_altered_manifest_rejected(self):
        _,manifest=export_authority(self.store)
        manifest['metadata']['private_users']={'columns':[],'rows':[]}
        with self.assertRaisesRegex(ValueError,'migration_identity_invalid'):restore_metadata(self.store,manifest)
