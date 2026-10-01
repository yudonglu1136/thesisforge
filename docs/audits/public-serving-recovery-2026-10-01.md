# Public serving recovery — 2026-10-01

## Root cause and deployed correction

Product artifacts had been reused by hardlink, conflicting with the existing
production validators' single-link inode contract. Commit
`1b1f721eb5fd4e4be451e5b991f8e8ec5a7781f5` preserves those validators and uses
checksum-verified independent product files, including interrupted-install
recovery. Canonical Parquet reuse remains unchanged. EB is Ready on
`public-inode-1b1f721`; previous application is `public-daily-3909366`.

Tests: 262 Fact OS tests; 1,755 Node tests passed, 15 skipped, zero failed.
Full Fact OS storage audit passed; the eleven previously documented layout
findings were not deleted or ignored to force a pass.

## Actual publication recovery

The user explicitly requested continued repair and activation. Publication-only
resume reused the October 1 scheduled run, without source fetch or rebuild:

- Run: `ee36138a5421566bf5af96387dca9c3c3d14ad529677abf0673ae0dc35f93298`.
- Worker SSM: `466bd7d2-d282-4758-9a35-fbb828f79849` (Success).
- Installer SSM: `7337f0c2-d3ec-4ca1-86d9-2bef26d20372` (Success).
- Independent live ACK: `c0d7109a-b3d8-4f66-bc2c-9b703f5b7198` (Success).
- Serving release: `e7be0d842e359b7b9efebc860a28bec54b513946c441c3f2eef7621bb5fa004b`.
- Prior serving release retained: `075134daa3dac8f423445dd36f285e8e79ca8f4351a9c7df8f8d1058ffaee554`.

All fourteen source statuses and six tasks passed. Zero payload objects were
uploaded during resume. S3 active pointer, host active pointer, and independent
live API ACK have the same serving release and run. Every group generation
matches the separate data-ready candidate; root release IDs need not match
because the publication chains have different parents.

Actual API-user canonical reads and all product validators passed. Independent
ACK reports Fundamentals ready (5,430 companies, latest available 2026-09-30),
Research ready (AMZN 8 quarterly / 8 annual periods; PLTR 8 / 6), and all eight
public-analysis jobs ready. No secret value or private account was accessed or
published by these operational checks.

## Automatic path and remaining limitations

Scheduler remains ENABLED, `07:30 Asia/Riyadh`. RunDocument 6 includes
`--data-only --activate-daily`; InstallDocument 2 invokes the installed script
from `/var/app/current`. Its configured instance `i-0eabc67533fb38fca` matches
the current EB environment. No schedule, instance size, private job or source
credential changed during this recovery.

This is a **manual recovery**, not a successful scheduled acceptance. The
October 1 Step Functions execution remains FAILED historically; the next real
scheduled execution must be inspected by the existing read-only monitor.

The strategy precomputations still load reviewed static curve snapshots ending
2026-09-21 for all three universes. Their ready status does NOT establish fresh
strategy NAV. Automatic quarterly selection, price replay and reconciled ledger
publication are still a separate unresolved implementation gap. Do not relabel
those snapshots as current or relax historical NAV/action validation.

API free space after acceptance: 4,481,683,456 bytes (about 4.17 GiB).
Capacity is finite and remains a daily gate; this repair does not certify
indefinite retention capacity. No old data was deleted and no disk expanded.
Application and retained data-pointer rollback remain separate operations;
use the documented installer validation and expected-release fence.
