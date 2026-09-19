"""Offline bounded-pagination protocol tests."""
import threading
import time
import unittest

from .pagination import PaginationError, ordered_pages, page_hash, parallel_verify


class PaginationTest(unittest.TestCase):
    def test_full_pages_ordered_and_parallel_memory_bounded(self):
        data = [{'n': n} for n in range(31)]
        active = peak = 0
        lock = threading.Lock()
        def fetch(offset):
            nonlocal active, peak
            with lock:
                active += 1
                peak = max(peak, active)
            time.sleep(.005)
            with lock: active -= 1
            return data[offset:offset + 5]
        pages = list(ordered_pages(fetch, 5, workers=3))
        self.assertEqual([offset for offset, _ in pages], [0, 5, 10, 15, 20, 25, 30, 31])
        self.assertEqual([row for _, rows in pages for row in rows], data)
        self.assertGreater(peak, 1)
        self.assertLessEqual(peak, 3)
        self.assertEqual(parallel_verify(fetch, [(o, page_hash(r)) for o, r in pages], 3), len(pages))

    def test_clamped_first_page_advances_by_actual_length(self):
        data = list(range(13)); calls = []
        def fetch(offset):
            calls.append(offset)
            return data[offset:offset + 3]
        pages = list(ordered_pages(fetch, 100, 8))
        self.assertEqual(calls, [0, 3, 6, 9, 12, 13])
        self.assertEqual([row for _, rows in pages for row in rows], data)

    def test_later_short_page_switches_to_actual_length(self):
        data = list(range(29)); calls = []
        def fetch(offset):
            calls.append(offset)
            return data[offset:offset + (5 if offset == 0 else 2)]
        pages = list(ordered_pages(fetch, 5, 4))
        self.assertEqual([row for _, rows in pages for row in rows], data)
        self.assertEqual([offset for offset, _ in pages], [0] + list(range(5, 30, 2)))
        # Speculative offsets after 5 are discarded; actual offset 7 is queried.
        self.assertIn(7, calls)

    def test_empty_first_page_only_fetches_zero_and_verifies(self):
        calls = []
        def fetch(offset): calls.append(offset); return []
        pages = list(ordered_pages(fetch, 10, 8))
        self.assertEqual(pages, [(0, [])])
        parallel_verify(fetch, [(0, page_hash([]))], 8)
        self.assertEqual(calls, [0, 0])

    def test_concurrent_fetch_failure_invalidates_run(self):
        def fetch(offset):
            if offset == 10: raise RuntimeError('upstream failed')
            return list(range(offset, offset + 5))
        pages = ordered_pages(fetch, 5, 3)
        self.assertEqual(next(pages), (0, list(range(5))))
        with self.assertRaisesRegex(RuntimeError, 'upstream failed'): list(pages)

    def test_second_pass_mutation_and_exception_abort(self):
        data = list(range(12))
        fetch = lambda offset: data[offset:offset + 5]
        expected = [(o, page_hash(r)) for o, r in ordered_pages(fetch, 5, 2)]
        data[7] = -1
        with self.assertRaisesRegex(PaginationError, 'changed during sync'):
            parallel_verify(fetch, expected, 3)
        def fails(offset): raise RuntimeError('verification failed')
        with self.assertRaisesRegex(RuntimeError, 'verification failed'):
            parallel_verify(fails, expected, 3)

    def test_terminal_empty_is_also_verified(self):
        data = list(range(10))
        fetch = lambda offset: data[offset:offset + 5]
        expected = [(o, page_hash(r)) for o, r in ordered_pages(fetch, 5, 2)]
        data.append(10)
        with self.assertRaisesRegex(PaginationError, 'changed during sync'):
            parallel_verify(fetch, expected, 2)

    def test_nonadvancing_pages_and_holes_fail_closed(self):
        with self.assertRaisesRegex(PaginationError, 'did not advance'):
            list(ordered_pages(lambda _: [1, 2], 2, 2))
        def hole(offset): return [] if offset == 2 else [offset, offset + 1]
        with self.assertRaisesRegex(PaginationError, 'follows terminal empty'):
            list(ordered_pages(hole, 2, 3))

    def test_hash_and_protocol_validation(self):
        self.assertEqual(page_hash([{'a': 1, 'b': 2}]), page_hash([{'b': 2, 'a': 1}]))
        for size, workers in [(0, 1), (1, 0), (True, 1), (1, 33)]:
            with self.assertRaises(ValueError): list(ordered_pages(lambda _: [], size, workers))
        with self.assertRaisesRegex(PaginationError, 'list of rows'):
            list(ordered_pages(lambda _: {}, 2, 2))
        with self.assertRaisesRegex(PaginationError, 'exceeded'):
            list(ordered_pages(lambda _: [1, 2, 3], 2, 2))
        for expected in [[], [(1, page_hash([]))], [(0, page_hash([1]))],
                         [(0, page_hash([])), (1, page_hash([]))],
                         [(0, page_hash([1])), (0, page_hash([]))]]:
            with self.assertRaises(PaginationError): parallel_verify(lambda _: [], expected)


if __name__ == '__main__': unittest.main()
