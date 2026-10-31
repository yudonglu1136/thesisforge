import unittest
from types import SimpleNamespace
from unittest.mock import patch
from .capacity import capacity_budget, WORKER_RESERVE_BYTES


class CapacityTests(unittest.TestCase):
    def test_exact_two_gib_floor_and_no_fictitious_increment(self):
        for free, expected in [(WORKER_RESERVE_BYTES-1, 'blocked'),
                               (WORKER_RESERVE_BYTES, 'ready'),
                               (3*1024**3, 'ready'), (16424022016, 'ready')]:
            with patch('shutil.disk_usage', return_value=SimpleNamespace(free=free)):
                result=capacity_budget('.')
            self.assertEqual(result['status'],expected)
            self.assertEqual(result['estimatedAdditionalBytes'],0)
            self.assertEqual(result['requiredFreeBytes'],2*1024**3)

    def test_known_incoming_bytes_do_not_consume_reserve(self):
        with patch('shutil.disk_usage',return_value=SimpleNamespace(free=3*1024**3)):
            self.assertEqual(capacity_budget('.',1024**3)['status'],'ready')
            self.assertEqual(capacity_budget('.',1024**3+1)['status'],'blocked')
        with self.assertRaises(ValueError):capacity_budget('.',-1)
