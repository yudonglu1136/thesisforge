# Public daily source 503 recovery

The November 3 scheduled run failed on holdings HTTP 503. Thirteen other
sources succeeded; canonical and institutional groups were blocked. Strategy
built but was not published. The November 2 serving pointer was retained.

The source query already had four attempts, but HTTP 5xx without Retry-After
waited only about 1/2/4 seconds. Apply the existing shared 30/60/120-second
cooldown to HTTP 500/502/503/504 as well as 429. Respect longer bounded provider
hints, keep four attempts, and emit only status/attempt/delay metadata. No
schema, completeness, identity, history or publication gates change. Persistent
errors remain failures; no unconditional whole-table retry is introduced.

Deploy only the exact sync.py patch onto the current immutable worker release,
fenced by its existing SHA-256. Preserve its dependencies and prior release.
Pause public scheduling for validation; restore original schedule after success
or restore prior code on failure. No private jobs or capacity changes.
Production recovery is not proven by tests: require all fourteen sources, six
groups, atomic strategy curve/ledger install and actual API ACK. Store actual
run and activation evidence under data/fact_os/audit.

The first manual repair recovered real funds HTTP 503 responses after 30/60
second cooldowns, but holdings still exhausted retries. A second candidate
reduces holdings CSV requests from 100,000 to 10,000 rows, using the existing
exhaustive ticker-range splitting and second-pass verification. It does not
cap total holdings or change the three-quarter refresh window. This is a
request-size mitigation pending real provider validation, not proof that the
upstream outage is resolved. Targeted sync/extraction/worker tests: 77 passed.
