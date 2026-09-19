import os
import shutil
import tempfile
import time
import unittest
from pathlib import Path

from .maintenance import collect_unreferenced
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


if __name__=='__main__':unittest.main()
