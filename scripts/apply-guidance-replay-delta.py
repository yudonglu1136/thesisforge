#!/usr/bin/env python3
"""Three-way, copy-only integration of a hash-bound transcript replay.

Financials, official evidence, coverage approvals and newly added issuers remain
untouched. Concurrent changes to the same scalar are conflicts, not overrides.
"""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3

OWNER = 'downloaded_online_earnings_transcript'
META = {'guidance_extraction_version', 'guidance_extracted_at'}
IDENTITY = ('id', 'ticker', 'fiscal_period', 'observed_at', 'source_type',
            'source_url', 'evidence_excerpt', 'speaker', 'speaker_role')
ABSENT = object()


def exact_value(left, right):
    """JSON booleans, numbers, absent fields and null are distinct contracts."""
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(exact_value(left[key], right[key]) for key in left)
    if isinstance(left, (list, tuple)):
        return len(left) == len(right) and all(exact_value(a, b) for a, b in zip(left, right))
    return left == right


def file_hash(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def merge_value(before, after, target, location='row'):
    if exact_value(before, after):
        return target
    if exact_value(before, target) or exact_value(after, target):
        return after
    if all(isinstance(value, dict) for value in (before, after, target)):
        result = {}
        for key in sorted(set(before) | set(after) | set(target)):
            value = merge_value(before.get(key, ABSENT), after.get(key, ABSENT),
                                target.get(key, ABSENT), f'{location}.{key}')
            if value is not ABSENT:
                result[key] = value
        return result
    raise ValueError(f'Concurrent source change requires independent review: {location}')


def same_source_row(left, right):
    """Only JSON serialization may differ after a prior three-way merge.

    No scalar, nested value, field presence, source text or identity is omitted.
    Reject duplicate JSON keys rather than letting a decoder hide a difference.
    """
    if left is None or right is None or left.keys() != right.keys():
        return False
    def unique_object(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Ambiguous duplicate payload key')
            result[key] = value
        return result
    for key in left:
        if key != 'payload_json':
            if left[key] != right[key]:
                return False
        else:
            canonical = lambda raw: json.dumps(json.loads(raw, object_pairs_hook=unique_object),
                sort_keys=True, ensure_ascii=False, separators=(',', ':'), allow_nan=False)
            if canonical(left[key]) != canonical(right[key]):
                return False
    return True


def tables(db):
    return [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]


def table_hash(db, table, excluded_ids=()):
    if table not in tables(db):
        return None
    info = db.execute(f'PRAGMA table_info("{table}")').fetchall()
    keys = [r[1] for r in sorted(info, key=lambda r: r[5]) if r[5]] or [r[1] for r in info]
    order = ','.join('"' + key + '"' for key in keys)
    h = hashlib.sha256()
    excluded = set(excluded_ids)
    for row in db.execute(f'SELECT * FROM "{table}" ORDER BY {order}'):
        if table == 'pit_guidance_events' and row[0] in excluded:
            continue
        if table == 'pit_source_metadata' and row[0] in META | {'source_fingerprint', 'guidance_replay_delta_provenance'}:
            continue
        h.update((json.dumps(tuple(row), separators=(',', ':')) + '\n').encode())
    return h.hexdigest()


def ro(path):
    return sqlite3.connect(Path(path).resolve(strict=True).as_uri() + '?mode=ro', uri=True)


def apply(recipe, output_path, report_path):
    output_path, report_path = Path(output_path).absolute(), Path(report_path).absolute()
    paths = [Path(recipe[k]).resolve(strict=True) for k in ('before', 'after', 'base')]
    if len(set(paths + [output_path, report_path])) != 5 or output_path.exists() or report_path.exists():
        raise ValueError('Distinct immutable inputs and NEW output paths required')
    for key, p in zip(('before', 'after', 'base'), paths):
        if file_hash(p) != recipe[key + 'Sha256']:
            raise ValueError(f'Unmatched reviewed source hash: {key}')
    cutoff = recipe['sourceCutoff']
    with closing(ro(paths[0])) as before, closing(ro(paths[1])) as after, closing(ro(paths[2])) as base:
        for db in (before, after, base):
            if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise ValueError('Input integrity failure')
        if tables(before) != tables(after) or any(table_hash(before, t) != table_hash(after, t)
                for t in tables(before) if t not in {'pit_guidance_events', 'pit_source_metadata'}):
            raise ValueError('Replay changed financials, coverage, reviews or another protected table')
        if table_hash(before, 'pit_source_metadata') != table_hash(after, 'pit_source_metadata'):
            raise ValueError('Replay changed unapproved source metadata')
        cols = [r[1] for r in before.execute('PRAGMA table_info(pit_guidance_events)')]
        for db in (after, base):
            if [r[1] for r in db.execute('PRAGMA table_info(pit_guidance_events)')] != cols:
                raise ValueError('Source schema mismatch')
        old = {r[0]: dict(zip(cols, r)) for r in before.execute('SELECT * FROM pit_guidance_events')}
        new = {r[0]: dict(zip(cols, r)) for r in after.execute('SELECT * FROM pit_guidance_events')}
        current = base.execute('SELECT count(*) FROM pit_guidance_events').fetchone()[0]
        changes = []
        added, deleted, updated, concurrent_preserved = [], [], [], []
        for key in sorted(set(old) | set(new)):
            left, right = old.get(key), new.get(key)
            if left == right:
                continue
            if any(row and (row['source_type'] != OWNER or row['observed_at'] > cutoff)
                   for row in (left, right)):
                raise ValueError('Only dated transcript-owned changes may be integrated')
            found = base.execute('SELECT * FROM pit_guidance_events WHERE id=?', (key,)).fetchone()
            target = dict(zip(cols, found)) if found else None
            if left is None:
                if target is not None:
                    raise ValueError(f'New replay ID collides with existing issuer/source: {key}')
                added.append(key)
                changes.append(('insert', right))
            elif right is None:
                # Removal is limited to exact duplicate metric-owned evidence.
                equivalent = lambda row: all(row.get(k) == left.get(k) for k in
                    (*IDENTITY[1:], 'metric_name', 'value_text'))
                if not same_source_row(target, left) or not any(equivalent(row) for row in new.values()):
                    raise ValueError(f'Removed row is not an unchanged, retained-evidence duplicate: {key}')
                deleted.append(key)
                changes.append(('delete', left))
            else:
                if target is None or any(left.get(k) != right.get(k) or left.get(k) != target.get(k) for k in IDENTITY):
                    raise ValueError(f'Original source identity/date/quote changed: {key}')
                merged = dict(target)
                for field in cols:
                    if left[field] == right[field]:
                        continue
                    if field == 'payload_json':
                        merged[field] = json.dumps(merge_value(json.loads(left[field]), json.loads(right[field]),
                            json.loads(target[field]), key), separators=(',', ':'), ensure_ascii=False)
                    else:
                        merged[field] = merge_value(left[field], right[field], target[field], key + '.' + field)
                updated.append(key)
                if target != left:
                    concurrent_preserved.append(key)
                changes.append(('update', merged))
        changed_ids = added + deleted + updated
        protected = {t: table_hash(base, t, changed_ids if t == 'pit_guidance_events' else ()) for t in tables(base)}
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with output_path.open('xb'):
            pass
        with closing(sqlite3.connect(output_path)) as target:
            base.backup(target)
            with target:
                for operation, row in changes:
                    if operation == 'delete':
                        target.execute('DELETE FROM pit_guidance_events WHERE id=?', (row['id'],))
                    elif operation == 'insert':
                        target.execute(f"INSERT INTO pit_guidance_events VALUES({','.join('?' for _ in cols)})", [row[k] for k in cols])
                    else:
                        target.execute('UPDATE pit_guidance_events SET ' + ','.join('"' + k + '"=?' for k in cols) + ' WHERE id=?',
                                       [row[k] for k in cols] + [row['id']])
                for k in sorted(META):
                    old_meta = before.execute('SELECT value FROM pit_source_metadata WHERE key=?', (k,)).fetchone()
                    new_meta = after.execute('SELECT value FROM pit_source_metadata WHERE key=?', (k,)).fetchone()
                    target_meta = target.execute('SELECT value FROM pit_source_metadata WHERE key=?', (k,)).fetchone()
                    if new_meta != old_meta:
                        merged_meta = merge_value(old_meta, new_meta, target_meta, 'metadata.' + k)
                        if merged_meta:
                            target.execute('INSERT OR REPLACE INTO pit_source_metadata VALUES(?,?)', (k, merged_meta[0]))
                provenance = {'scope': 'three_way_dated_transcript_delta_not_model_or_release_approval',
                              'sourceRecipe': recipe, 'added': len(added), 'deleted': len(deleted), 'updated': len(updated),
                              'concurrentEvidencePreserved': len(concurrent_preserved)}
                encoded = json.dumps(provenance, sort_keys=True, separators=(',', ':'))
                target.execute("INSERT OR REPLACE INTO pit_source_metadata VALUES('guidance_replay_delta_provenance',?)", (encoded,))
                target.execute("INSERT OR REPLACE INTO pit_source_metadata VALUES('source_fingerprint',?)", (hashlib.sha256(encoded.encode()).hexdigest(),))
            actual = {t: table_hash(target, t, changed_ids if t == 'pit_guidance_events' else ()) for t in tables(base)}
            if actual != protected or target.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise ValueError('Protected source records changed during replay integration')
            count = target.execute('SELECT count(*) FROM pit_guidance_events').fetchone()[0]
            if count != current + len(added) - len(deleted):
                raise ValueError('Unexpected source count')
    report = {**provenance, 'releaseAuthorized': False, 'inputEvents': current, 'outputEvents': count,
              'addedIds': added, 'deletedIds': deleted, 'concurrentEvidencePreservedIds': concurrent_preserved,
              'allProtectedTablesAndUnchangedSourceRowsExact': True,
              'outputSha256': file_hash(output_path), 'outputPath': str(output_path)}
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with report_path.open('x') as stream:
        json.dump(report, stream, indent=2)
        stream.write('\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recipe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = apply(json.loads(args.recipe.read_text()), args.output, args.report)
    print(json.dumps({k: v for k, v in result.items() if not k.endswith('Ids')}, indent=2))
