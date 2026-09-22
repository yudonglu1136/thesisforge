"""Bounded AI Insights read model, built from one pinned canonical catalog.

This module has no upstream HTTP access and never changes canonical facts. It
preserves every available ARQ datekey revision, including nulls and signed capex.
The API selects the public-date cutoff; this artifact is not a trading backtest.
"""
from contextlib import contextmanager
from datetime import date, datetime, timezone
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import uuid

from .contracts import ident
from .repository import FactRepository, MissingData, _cik

BUILDER_VERSION = 'ai-insights-artifact-v3'
METHODOLOGY_VERSION = 'ai-insights-v1'
DEFAULT_UNIVERSE = Path(__file__).resolve().parents[1] / 'server/config/ai-insights-universe.json'
FINANCIAL_FIELDS = (
    'revenue', 'revenueusd', 'gp', 'opinc', 'ebit', 'netinc', 'netinccmn',
    'ncfo', 'capex', 'fcf', 'sbcomp', 'assets', 'cashneq', 'debt', 'inventory',
    'receivables', 'sharesbas', 'shareswa', 'shareswadil', 'intexp', 'fxusd',
)
SCOPE_ACTIONS = ('spinoff', 'spunofffrom', 'acquisitionof', 'mergerfrom', 'mergerto', 'spacmerger')


def _json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False,
                      default=lambda item: item.isoformat() if isinstance(item, (date, datetime)) else str(item)).encode()


def _hash(value):
    return hashlib.sha256(_json_bytes(value)).hexdigest()


def _timestamp():
    return datetime.now(timezone.utc).isoformat()


def _atomic(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        with temporary.open('xb') as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def _writer(root):
    """Use the canonical writer lease without opening or mutating its database."""
    (root / 'sync').mkdir(parents=True, exist_ok=True)
    with (root / 'sync/writer.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def load_universe(path=DEFAULT_UNIVERSE):
    universe = json.loads(Path(path).read_text())
    companies = universe.get('companies', [])
    tickers = [company.get('ticker') for company in companies]
    if universe.get('schemaVersion') != 1 or not companies or len(companies) > 250:
        raise ValueError('invalid or unbounded AI Insights universe')
    if len(set(tickers)) != len(tickers) or any(not re.fullmatch(r'[A-Z0-9.\-]{1,12}', ticker or '') for ticker in tickers):
        raise ValueError('duplicate or invalid AI Insights ticker')
    if any(company.get('group') not in ('hardware', 'software', 'capex') for company in companies):
        raise ValueError('invalid AI Insights company group')
    return universe


def collect(repo, universe):
    """One bounded fundamentals query, one small ticker-dimension query."""
    repo._require('fundamentals')
    repo._require('tickers')
    tickers = sorted(company['ticker'] for company in universe['companies'])
    marks = ','.join('?' for _ in tickers)
    masters = repo._rows(f'SELECT * FROM tickers WHERE ticker IN ({marks}) '
                         'AND "table" IN (\'SF1\',\'fundamentals\',\'SEP\',\'stocks\') '
                         'ORDER BY ticker,"table",permaticker', tickers)
    corporate_actions = {ticker: [] for ticker in tickers}
    if 'actions' in repo._datasets:
        action_marks = ','.join('?' for _ in SCOPE_ACTIONS)
        actions = repo._rows(f'SELECT * FROM actions WHERE ticker IN ({marks}) '
            f'AND action IN ({action_marks}) ORDER BY ticker,date,action,contraticker', [*tickers, *SCOPE_ACTIONS])
        if len(actions) > 5000:
            raise ValueError('AI Insights corporate actions exceed bounded row budget')
        for row in actions:
            source = repo._lineage('actions', row)
            event = {'date': str(row['date']), 'knownAt': str(row['date']), 'type': row['action'],
                'counterpartyTicker': row.get('contraticker'), 'counterpartyName': row.get('contraname'),
                'basis': 'provider_effective_date_proxy',
                'source': {'source': source['source'], 'table': source['table'], 'key': source['key'],
                    'observedAt': source['observed_at'], 'ingestionRun': source['ingestion_run'],
                    'catalogGeneration': source['catalog_generation'], 'qualityIssues': source['quality_issues']}}
            # Evidence identity follows the source fact, not the catalog that
            # happened to expose it. A price-only publication must not mint a
            # new corporate-action revision.
            event['sourceRevisionId'] = 'action:' + _hash({
                'date': event['date'], 'type': event['type'],
                'counterpartyTicker': event['counterpartyTicker'],
                'counterpartyName': event['counterpartyName'],
                'sourceTable': source['table'], 'sourceKey': source['key'],
                'qualityIssues': source['quality_issues'],
            })
            corporate_actions[row['ticker']].append(event)
    companies = []
    issuers = set()
    for definition in universe['companies']:
        ticker = definition['ticker']
        identities = [row for row in masters if row['ticker'] == ticker]
        perms = {row['permaticker'] for row in identities}
        ciks = {cik for row in identities if (cik := _cik(row.get('secfilings')))}
        if len(perms) != 1 or len(ciks) > 1:
            raise MissingData(f'{ticker}: missing or ambiguous security identity')
        issuer = f'sec:cik:{next(iter(ciks))}' if ciks else f'sharadar:security:{next(iter(perms))}'
        if issuer in issuers:
            raise ValueError('duplicate issuer across AI Insights companies')
        issuers.add(issuer)
        financial = [row for row in identities if row['table'] in ('fundamentals', 'SF1')]
        master = max(financial or identities, key=lambda row: str(row.get('lastupdated') or ''))
        companies.append({**definition, 'issuerId': issuer,
            'securityId': f'sharadar:security:{next(iter(perms))}',
            'identityStatus': 'verified_cik' if ciks else 'provider_security_identity',
            'currency': master.get('currency'), 'listingDate': None,
            'firstPriceDate': master.get('firstpricedate'),
            'firstPriceDateBasis': 'current_security_master_first_price_proxy',
            'businessModelGroup': definition.get('businessModelGroup', definition['group']),
            'supplyChainStage': definition['sector'], 'sourceUrl': master.get('secfilings'),
            'corporateActions': corporate_actions[ticker],
            'corporateActionsCoverage': 'provider_actions_not_complete_scope_bridge' if 'actions' in repo._datasets else 'unavailable',
            'classificationBasis': universe['classificationBasis'], 'classificationKnownAt': universe['knownAt']})
    columns = {name for name, _ in repo._contracts['fundamentals'].columns}
    required = {'ticker', 'dimension', 'date', 'reportperiod', 'calendardate'}
    if not required.issubset(columns):
        raise MissingData('fundamentals: AI Insights quarter/date contract unavailable')
    metadata = ['ticker', 'dimension', 'calendardate', 'date', 'reportperiod', 'fiscalperiod', 'lastupdated']
    selected = [field for field in [*metadata, *FINANCIAL_FIELDS] if field in columns]
    # _quality_issues was added after early generations. Repository binding uses
    # union_by_name, and old stores may omit the column entirely.
    bound_columns = {row[0] for row in repo.db.execute('DESCRIBE fundamentals').fetchall()}
    selected += [field for field in ('_ingestion_run', '_observed_at', '_quality_issues') if field in bound_columns]
    raw_rows = repo._rows('SELECT ' + ','.join(map(ident, selected)) +
        f" FROM fundamentals WHERE ticker IN ({marks}) AND dimension='ARQ' "
        'ORDER BY ticker,calendardate,reportperiod,date', tickers)
    if len(raw_rows) > 100000:
        raise ValueError('AI Insights artifact exceeds bounded row budget')
    currency = {company['ticker']: company['currency'] for company in companies}
    natural_keys, facts = set(), []
    for row in raw_rows:
        key = {field: row[field] for field in repo._contracts['fundamentals'].keys}
        key_id = _hash(key)
        if key_id in natural_keys:
            raise ValueError('duplicate AI Insights source natural key')
        natural_keys.add(key_id)
        for field in FINANCIAL_FIELDS:
            value = row.get(field)
            if isinstance(value, float) and not math.isfinite(value):
                raise ValueError('non-finite financial source value')
        fact = {field: row.get(field) for field in ('ticker', 'dimension', 'calendardate', 'reportperiod', 'fiscalperiod', *FINANCIAL_FIELDS)}
        fact.update({'datekey': row['date'], 'currency': currency[row['ticker']],
            'capexStatus': 'missing' if row.get('capex') is None else
                           'provider_zero_unverified' if row['capex'] == 0 else
                           'net_disposal_inflow' if row['capex'] > 0 else 'reported_net_cash_proxy',
            'source': {'source': 'Sharadar', 'table': 'fundamentals', 'key': key,
                'lastupdated': row.get('lastupdated'), 'observedAt': row.get('_observed_at'),
                'ingestionRun': row.get('_ingestion_run'), 'catalogGeneration': repo.generation,
                'qualityIssues': row.get('_quality_issues') or None}})
        # A same-datekey provider rewrite has a distinct evidence identity. Its
        # presence does not prove that the old provider content was archived.
        fact['sourceRevisionId'] = 'sf1:' + _hash({
            'sourceTable': fact['source']['table'],
            'sourceKey': fact['source']['key'],
            'lastupdated': fact['source']['lastupdated'],
            'qualityIssues': fact['source']['qualityIssues'],
            'values': {field: fact.get(field) for field in (
                'ticker', 'dimension', 'calendardate', 'reportperiod',
                'fiscalperiod', *FINANCIAL_FIELDS,
            )},
            'datekey': fact['datekey'], 'currency': fact['currency'],
            'capexStatus': fact['capexStatus'],
        })
        facts.append(fact)
    if not facts:
        raise MissingData('AI Insights universe has no ARQ history')
    return companies, facts


def _inventory(facts):
    by_company = {}
    for row in facts:
        available, period = str(row['datekey']), str(row['reportperiod'])
        item = by_company.setdefault(row['ticker'], {'rowCount': 0, 'oldestDatekey': available, 'oldestPeriod': period})
        item['rowCount'] += 1
        item['oldestDatekey'] = min(item['oldestDatekey'], available)
        item['oldestPeriod'] = min(item['oldestPeriod'], period)
    return {'rowCount': len(facts), 'oldestDatekey': min(str(row['datekey']) for row in facts),
            'oldestPeriod': min(str(row['reportperiod']) for row in facts), 'companies': by_company}


def _dependency_fingerprint(companies, facts, universe_sha256):
    """Fingerprint only inputs that can change the AI analysis."""
    company_inputs = [{
        'ticker': row['ticker'], 'issuerId': row['issuerId'],
        'securityId': row['securityId'], 'identityStatus': row['identityStatus'],
        'currency': row.get('currency'), 'group': row.get('group'),
        'sector': row.get('sector'), 'businessModelGroup': row.get('businessModelGroup'),
        'classificationKnownAt': row.get('classificationKnownAt'),
        'corporateActionRevisionIds': [event['sourceRevisionId'] for event in row.get('corporateActions', [])],
    } for row in companies]
    return _hash({
        'builderVersion': BUILDER_VERSION,
        'universeSha256': universe_sha256,
        'companies': company_inputs,
        'financialRevisionIds': [row['sourceRevisionId'] for row in facts],
    })


def _generation_manifest(root, artifact_path, artifact, artifact_bytes):
    manifest = {key: artifact[key] for key in ('schemaVersion', 'builderVersion', 'generationId', 'generatedAt',
        'sourceManifestSha256', 'dependencySha256', 'universeVersion', 'universeSha256')}
    manifest.update({'artifactPath': str(artifact_path.relative_to(root)),
        'artifactSha256': hashlib.sha256(artifact_bytes).hexdigest(), 'bytes': len(artifact_bytes),
        'rowCount': len(artifact['facts']), 'companyCount': len(artifact['companies']), 'inventory': artifact['inventory']})
    return manifest


def _archive_manifest(directory, manifest):
    generation = manifest.get('generationId', '')
    if not re.fullmatch(r'[a-f0-9]{64}', generation):
        raise ValueError('invalid AI Insights archived generation identity')
    path = directory / 'generations' / f'{generation}.manifest.json'
    encoded = _json_bytes(manifest)
    if path.exists():
        if path.read_bytes() != encoded:
            raise ValueError('AI Insights immutable generation manifest conflict')
    else:
        _atomic(path, encoded)


def build_ai_insights(root, *, universe_path=DEFAULT_UNIVERSE):
    root = Path(root).resolve()
    universe = load_universe(universe_path)
    registry_hash = _hash(universe)
    directory = root / 'derived/ai-insights'
    manifest_path = directory / 'manifest.json'
    audit_path = root / 'audit' / ('ai-insights-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S') + '-' + uuid.uuid4().hex[:8] + '.json')
    with _writer(root), FactRepository(root) as repo:
        if not repo.generation:
            raise MissingData('AI Insights requires a published immutable catalog')
        previous = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
        if previous:
            relative = Path(previous.get('artifactPath', ''))
            old_path = (root / relative).resolve()
            if relative.is_absolute() or not old_path.is_relative_to(directory / 'generations'):
                raise ValueError('AI Insights manifest artifact path escapes generations')
            old_bytes = old_path.read_bytes()
            if hashlib.sha256(old_bytes).hexdigest() != previous['artifactSha256']:
                raise ValueError('AI Insights prior artifact checksum mismatch')
            # Keep the checksum contract alongside each retained generation so
            # pinned historical reads have the same integrity as latest reads.
            _archive_manifest(directory, previous)
        companies, facts = collect(repo, universe)
        dependency_hash = _dependency_fingerprint(companies, facts, registry_hash)
        if previous:
            if (previous.get('dependencySha256') == dependency_hash and
                    previous.get('universeSha256') == registry_hash and previous.get('builderVersion') == BUILDER_VERSION):
                receipt = {'status': 'no_op', 'generationId': previous['generationId'],
                    'sourceManifestSha256': repo.generation, 'manifestUnchanged': True,
                    'dependencySha256': dependency_hash,
                    'sameInputReplay': True, 'canonicalFactsUnchanged': True,
                    'before': previous['inventory'], 'after': previous['inventory'],
                    'auditedAt': _timestamp()}
                _atomic(audit_path, _json_bytes(receipt))
                return {**receipt, 'manifestPath': str(manifest_path), 'auditPath': str(audit_path)}
        inventory = _inventory(facts)
        if previous and previous.get('universeSha256') == registry_hash:
            before = previous['inventory']
            for ticker, old in before['companies'].items():
                current = inventory['companies'].get(ticker)
                if not current or current['rowCount'] < old['rowCount'] or current['oldestDatekey'] > old['oldestDatekey'] or current['oldestPeriod'] > old['oldestPeriod']:
                    raise ValueError(f'{ticker}: historical AI Insights rows regressed; prior manifest retained')
        core = {'schemaVersion': 1, 'builderVersion': BUILDER_VERSION,
            'methodologyVersion': METHODOLOGY_VERSION, 'universeVersion': universe['universeVersion'],
            'universeSha256': registry_hash, 'sourceManifestSha256': repo.generation,
            'dependencySha256': dependency_hash,
            'companies': companies, 'facts': facts, 'inventory': inventory,
            'basis': {'publicTime': 'provider_datekey_day_precision',
                'revisionPolicy': 'latest_eligible_ARQ_by_datekey_at_query_cutoff',
                'historicalScope': universe['classificationBasis'],
                'quarterAlignment': 'provider_calendardate_with_actual_reportperiod_preserved',
                'revenue': universe['revenueBasis'], 'capex': 'negative_of_signed_net_cash_capex_proxy',
                'currency': 'current_financial_master_currency_plus_reported_fxusd_and_revenueusd',
                'limitation': 'Available ARQ revisions do not prove a complete archive of same-date provider rewrites.'}}
        encoded = _json_bytes(core)
        replay_companies, replay_facts = collect(repo, universe)
        replay_core = {**core, 'companies': replay_companies, 'facts': replay_facts,
                       'inventory': _inventory(replay_facts)}
        if encoded != _json_bytes(replay_core):
            raise ValueError('AI Insights same-input replay differs')
        generation = hashlib.sha256(encoded).hexdigest()
        artifact = {**core, 'generationId': generation, 'generatedAt': _timestamp()}
        artifact_path = directory / 'generations' / f'{generation}.json'
        # Identical content already published in a retained generation is reused.
        if artifact_path.exists():
            artifact_bytes = artifact_path.read_bytes()
            existing = json.loads(artifact_bytes)
            existing_core = {key: value for key, value in existing.items() if key not in ('generationId', 'generatedAt')}
            if existing.get('generationId') != generation or _json_bytes(existing_core) != encoded:
                raise ValueError('AI Insights immutable generation conflict')
            artifact = existing
        else:
            artifact_bytes = _json_bytes(artifact)
            if len(artifact_bytes) > 32 * 1024 * 1024:
                raise ValueError('AI Insights artifact exceeds 32 MiB byte budget')
            _atomic(artifact_path, artifact_bytes)
        # The writer lease should make this invariant automatic. Fail closed if
        # a non-cooperating process replaced the source catalog during the read.
        if hashlib.sha256((root / 'manifests/catalog.json').read_bytes()).hexdigest() != repo.generation:
            raise ValueError('canonical catalog changed during AI Insights build')
        manifest = _generation_manifest(root, artifact_path, artifact, artifact_bytes)
        receipt = {'status': 'published', 'generationId': generation, 'sourceManifestSha256': repo.generation,
            'dependencySha256': dependency_hash,
            'before': previous['inventory'] if previous else None, 'after': inventory,
            'naturalKeysUnique': True, 'sameInputReplay': True, 'canonicalFactsUnchanged': True,
            'manifestPath': str(manifest_path), 'artifactPath': str(artifact_path), 'bytes': len(artifact_bytes),
            'auditedAt': _timestamp()}
        _atomic(audit_path, _json_bytes(receipt))
        _archive_manifest(directory, manifest)
        _atomic(manifest_path, _json_bytes(manifest))
        return {**receipt, 'auditPath': str(audit_path)}
