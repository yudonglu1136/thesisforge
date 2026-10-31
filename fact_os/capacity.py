"""Worker free-space floor, separate from known incoming payload bytes."""
import shutil

WORKER_RESERVE_BYTES = 2 * 1024**3


def capacity_budget(root, additional_bytes=0):
    if not isinstance(additional_bytes, int) or additional_bytes < 0:
        raise ValueError('invalid_capacity_estimate')
    free = shutil.disk_usage(root).free
    return {'freeBytes': free, 'estimatedAdditionalBytes': additional_bytes,
            'reserveBytes': WORKER_RESERVE_BYTES,
            'requiredFreeBytes': WORKER_RESERVE_BYTES + additional_bytes,
            'status': 'ready' if free >= WORKER_RESERVE_BYTES + additional_bytes else 'blocked'}
