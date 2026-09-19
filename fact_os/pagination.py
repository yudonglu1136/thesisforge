"""Bounded parallel pagination; publication belongs to the calling synchronizer.

Both passes must finish before the caller publishes staged rows. An empty page
is included in the first pass and must be re-read in the verification pass.
No HTTP, data storage, retries, or rate-limit policy is implemented here.
"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
from itertools import islice
import json


class PaginationError(RuntimeError):
    pass


def page_hash(rows):
    """Stable content digest, independent of dictionary insertion order."""
    return hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()


def _settings(page_size, workers):
    if isinstance(page_size, bool) or not isinstance(page_size, int) or page_size < 1:
        raise ValueError('page_size must be a positive integer')
    if isinstance(workers, bool) or not isinstance(workers, int) or not 1 <= workers <= 32:
        raise ValueError('workers must be between 1 and 32')


def _rows(fetch, offset, page_size=None):
    rows = fetch(offset)
    if not isinstance(rows, list):
        raise PaginationError('fetch must return a list of rows')
    if page_size is not None and len(rows) > page_size:
        raise PaginationError('upstream exceeded requested page size')
    return rows


def ordered_pages(fetch, page_size, workers=8):
    """Yield ``(offset, rows)`` through a terminal empty page, in source order.

    A full first page permits fixed-offset parallel batches. Any short page,
    including a server-clamped first page, permanently switches this run to
    sequential requests advancing by the actual row count. Speculatively
    fetched pages after a short page are discarded, never used to skip rows.
    At most ``workers`` requests/results are outstanding in any one batch.
    Exceptions invalidate the entire run, including previously yielded rows.
    """
    _settings(page_size, workers)
    offset = 0
    rows = _rows(fetch, offset, page_size)
    previous_hash = None
    parallel = len(rows) == page_size and workers > 1
    with ThreadPoolExecutor(max_workers=workers) as pool:
        while True:
            digest = page_hash(rows)
            if rows and digest == previous_hash:
                raise PaginationError('upstream pagination did not advance')
            yield offset, rows
            if not rows:
                return
            previous_hash = digest
            offset += len(rows)
            if not parallel:
                rows = _rows(fetch, offset, page_size)
                continue

            rows = None  # Do not retain the previous page during the next batch.
            offsets = [offset + index * page_size for index in range(workers)]
            # Resolve the entire bounded batch before yielding any of it: even
            # an error in a later speculative request invalidates this run.
            futures = [pool.submit(_rows, fetch, start, page_size) for start in offsets]
            batch = [future.result() for future in futures]
            for index, candidate in enumerate(batch):
                offset, rows = offsets[index], candidate
                if len(rows) < page_size:
                    parallel = False
                    if not rows and any(batch[index + 1:]):
                        raise PaginationError('nonempty page follows terminal empty page')
                    break
                # Leave the last full page for the outer loop, which starts
                # the next batch. Earlier full pages can now stream to disk.
                if index == len(batch) - 1:
                    break
                digest = page_hash(rows)
                if digest == previous_hash:
                    raise PaginationError('upstream pagination did not advance')
                yield offset, rows
                previous_hash = digest
            del batch, futures, candidate


def parallel_verify(fetch, expected_hashes, workers=8):
    """Re-read every ``(offset, digest)`` in bounded batches; return page count.

    The ordered expected sequence must begin at zero and end with the hash of
    an empty page. Any exception, mutation, duplicate/out-of-order offset, or
    absent terminal empty page raises instead of permitting publication.
    ``fetch`` must use exactly the same query parameters as the first pass.
    """
    _settings(1, workers)
    iterator = iter(expected_hashes)
    previous_offset = -1
    previous_digest = None
    count = 0
    empty_digest = page_hash([])
    with ThreadPoolExecutor(max_workers=workers) as pool:
        while batch := list(islice(iterator, workers)):
            for offset, digest in batch:
                if not isinstance(offset, int) or offset < 0 or offset <= previous_offset:
                    raise PaginationError('verification offsets must increase')
                if count == 0 and offset != 0:
                    raise PaginationError('verification must start at offset zero')
                if previous_digest == empty_digest:
                    raise PaginationError('verification contains pages after terminal empty page')
                previous_offset, previous_digest = offset, digest
                count += 1
            futures = [pool.submit(_rows, fetch, offset) for offset, _ in batch]
            for (_, expected), future in zip(batch, futures):
                if page_hash(future.result()) != expected:
                    raise PaginationError('upstream changed during sync; local history retained')
            del futures, future
    if count == 0 or previous_digest != empty_digest:
        raise PaginationError('verification requires a terminal empty page')
    return count
