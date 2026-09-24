"""Historical universe membership from the pinned canonical repository.

Sharadar's quarterly constituent snapshots plus effective-date changes; never
use its current list for historical selection. Financial/classification vintage
limitations of the parent research rules still apply.
"""
from datetime import date
import hashlib
import json


def sp500_members_at(rows, signal_date, minimum=400):
    snapshots = [d for d, action, _ in rows if action == 'historical' and d <= signal_date]
    if not snapshots:
        raise ValueError('membership_snapshot_missing:' + signal_date)
    baseline = max(snapshots)
    if (date.fromisoformat(signal_date) - date.fromisoformat(baseline)).days > 100:
        raise ValueError('membership_snapshot_stale:' + signal_date)
    members = {t for d, action, t in rows if action == 'historical' and d == baseline}
    events = sorted({(d, action, t) for d, action, t in rows
                     if baseline < d <= signal_date and action in ('added', 'removed')})
    for day in sorted({d for d, _, _ in events}):
        added = {t for d, action, t in events if d == day and action == 'added'}
        removed = {t for d, action, t in events if d == day and action == 'removed'}
        if added & removed:
            raise ValueError('membership_conflicting_event:' + day)
        members.difference_update(removed)
        members.update(added)
    if not minimum <= len(members) <= 550:
        raise ValueError('membership_incomplete:' + signal_date)
    evidence = dict(snapshotDate=baseline, effectiveThrough=signal_date, memberCount=len(members),
                    fingerprint=hashlib.sha256(json.dumps([baseline, events, sorted(members)],
                                                         separators=(',', ':')).encode()).hexdigest())
    return members, evidence


def select_universe(frame, membership):
    missing = set(frame.q.unique()) - membership.keys()
    if missing:
        raise ValueError('membership_quarter_missing:' + ','.join(sorted(missing)))
    return frame[[t in membership[q] for q, t in zip(frame.q, frame.ticker)]].copy()


def qqq_members_at(snapshots, signal_date):
    # Filing-day timestamps can be after the signal close. With daily metadata
    # only, conservatively wait until a later date, never assume intraday access.
    visible = [s for s in snapshots if s['filed'] < signal_date and s['period'] <= signal_date]
    if not visible:
        raise ValueError('membership_snapshot_missing:' + signal_date)
    # A late amendment of an old period must not displace a newer portfolio.
    snapshot = max(visible, key=lambda s: (s['period'], s['filed'], s['accession']))
    if (date.fromisoformat(signal_date)-date.fromisoformat(snapshot['period'])).days > 190:
        raise ValueError('membership_snapshot_stale:' + signal_date)
    members = snapshot['members']
    if len(members) != snapshot['sourceMemberCount'] or not 95 <= len(members) <= 115:
        raise ValueError('membership_incomplete:' + signal_date)
    ids = {m['permaticker'] for m in members}
    if len(ids) != len(members):
        raise ValueError('membership_duplicate_identity')
    evidence = dict(snapshotDate=snapshot['period'], filed=snapshot['filed'],
        accession=snapshot['accession'], sourceUrl=snapshot['sourceUrl'],
        sourceSha256=snapshot['sourceSha256'], memberCount=len(members),
        ageDays=(date.fromisoformat(signal_date)-date.fromisoformat(snapshot['period'])).days,
        effectiveThrough=signal_date,
        fingerprint=hashlib.sha256(json.dumps(snapshot, sort_keys=True, separators=(',', ':')).encode()).hexdigest())
    return ids, evidence
