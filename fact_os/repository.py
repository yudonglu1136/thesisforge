"""Local-only semantic facts. Every reader pins one immutable Parquet catalog.

No HTTP, synchronization, or legacy-source dependency belongs in this module.
"""
from datetime import date, timedelta
from enum import Enum
import json
import math
import hashlib
import fcntl
from pathlib import Path
import re
from urllib.parse import parse_qs, urlparse

import duckdb
from .contracts import Contract, ident


class PriceType(str, Enum):
    RAW_CLOSE = 'closeunadj'
    SPLIT_ADJUSTED_CLOSE = 'close'
    TOTAL_RETURN_ADJUSTED_CLOSE = 'closeadj'


class MissingData(LookupError):
    pass


class PITUnavailable(ValueError):
    pass


SECURITY_TABLES = ('SEP', 'SF1', 'SFP', 'stocks', 'fundamentals', 'funds')
INVESTOR_TABLES = ('SF3B', 'holdings_investor')
DIMENSIONS = ('ARQ', 'ARY', 'ART', 'MRQ', 'MRY', 'MRT')
SECURITY_TYPES = ('SHR', 'CLL', 'PUT', 'WNT', 'DBT', 'PRF', 'FND', 'UND')


def _date(value):
    return value if isinstance(value, date) else date.fromisoformat(str(value))


def _previous_quarter(value):
    q = _date(value)
    if (q.month, q.day) not in ((3, 31), (6, 30), (9, 30), (12, 31)):
        raise ValueError('quarter-end required')
    return q.replace(day=1, month=((q.month - 1) // 3) * 3 + 1) - timedelta(days=1)


def _literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def _cik(value):
    """Only an explicit SEC URL establishes issuer/filer identity."""
    parsed = urlparse(value or '')
    if parsed.hostname not in ('sec.gov', 'www.sec.gov'):
        return None
    query = {key.lower(): val for key, val in parse_qs(parsed.query).items()}
    candidate = (query.get('cik') or [None])[0]
    if candidate is None:
        match = re.search(r'/data/(\d+)(?:/|$)', parsed.path, re.I)
        candidate = match[1] if match else None
    return str(int(candidate)) if candidate and candidate.isdigit() and int(candidate) > 0 else None


class FactRepository:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.db, self._reader_lock = None, None
        if not (self.root / 'manifests/catalog.json').exists() and not (self.root / 'fact_os.duckdb').exists():
            raise MissingData('local Fact OS has not been backfilled')
        # GC takes this lock exclusively before unlinking retired generations.
        # Hold it before reading the catalog, throughout the pinned snapshot.
        # Creating an advisory lock is the only on-disk mutation by a reader.
        (self.root / 'sync').mkdir(exist_ok=True)
        self._reader_lock = (self.root / 'sync/readers.lock').open('a')
        try:
            fcntl.flock(self._reader_lock, fcntl.LOCK_SH)
            self._open_snapshot()
        except Exception:
            self.close()
            raise

    def _open_snapshot(self):
        self._contracts, self._states, self._datasets = {}, {}, set()
        self._identities, self._investors = {}, None
        self._master_ready = False
        manifest = self.root / 'manifests' / 'catalog.json'
        if manifest.exists():
            manifest_bytes = manifest.read_bytes()
            catalog = json.loads(manifest_bytes)
            if catalog.get('version') != 1:
                raise MissingData('unsupported Fact OS catalog version')
            self.generation = hashlib.sha256(manifest_bytes).hexdigest()
            self.db = duckdb.connect(':memory:')
            self.db.execute("SET memory_limit='512MB'")
            self.db.execute('SET threads=2')
            try:
                for table, item in catalog.get('datasets', {}).items():
                    self._contracts[table] = Contract.from_ddl(table, item['ddl'])
                    self._states[table] = item.get('state') or {}
                    files = []
                    for part in item.get('partitions', []):
                        relative = Path(part['path'])
                        path = (self.root / relative).resolve()
                        if relative.is_absolute() or not path.is_relative_to(self.root / 'parquet'):
                            raise MissingData('catalog partition path escapes the local Parquet store')
                        if not path.is_file():
                            raise MissingData(f'{table}: catalog partition file is missing')
                        files.append(str(path))
                    self._bind(table, files)
            except Exception:
                self.db.close()
                raise
        else:
            # Compatibility with older archives only. New stores publish JSON
            # atomically, so ordinary readers never lock the writer's DuckDB.
            self.generation = None
            if not (self.root / 'fact_os.duckdb').exists():
                raise MissingData('local Fact OS has not been backfilled')
            self.db = duckdb.connect(str(self.root / 'fact_os.duckdb'), read_only=True)
            for table, ddl in self.db.execute('SELECT dataset,ddl FROM contracts').fetchall():
                self._contracts[table] = Contract.from_ddl(table, ddl)
            self._states = {row['dataset']: row for row in self._rows('SELECT * FROM sync_state')}
            for (table,) in self.db.execute('SELECT DISTINCT dataset FROM partitions').fetchall():
                files = [str(self.root / row[0]) for row in self.db.execute(
                    'SELECT path FROM partitions WHERE dataset=? ORDER BY bucket', [table]).fetchall()]
                self._bind(table, files)

    def _bind(self, table, files):
        if files:
            self.db.execute(f'CREATE TEMP VIEW {ident(table)} AS SELECT * FROM read_parquet([' +
                            ','.join(_literal(path) for path in files) + '], union_by_name=true)')
            self._datasets.add(table)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def close(self):
        try:
            if self.db is not None:
                self.db.close()
                self.db = None
        finally:
            if self._reader_lock is not None:
                fcntl.flock(self._reader_lock, fcntl.LOCK_UN)
                self._reader_lock.close()
                self._reader_lock = None

    def _rows(self, sql, params=()):
        cur = self.db.execute(sql, params)
        names = [column[0] for column in cur.description]
        return [dict(zip(names, row)) for row in cur.fetchall()]

    def _require(self, table):
        if table not in self._datasets:
            raise MissingData(f'{table}: no local dataset; network fallback is disabled')

    def _lineage(self, table, row):
        return {'source': 'Sharadar', 'table': table,
                'key': {key: row[key] for key in self._contracts[table].keys},
                'lastupdated': row.get('lastupdated'), 'ingestion_run': row['_ingestion_run'],
                'observed_at': row['_observed_at'], 'catalog_generation': self.generation,
                'quality_issues': row.get('_quality_issues') or None}

    def get_coverage(self):
        return [{'dataset': table, **state, 'locally_available': table in self._datasets}
                for table, state in sorted(self._states.items())]

    def _master(self):
        self._require('tickers')
        if not self._master_ready:
            # Materialize this small dimension once, not one Parquet scan per
            # holding. All indexes are private to this read-only fact session.
            self.db.execute('CREATE TEMP TABLE _master AS SELECT * FROM tickers')
            self.db.execute('CREATE INDEX _master_ticker ON _master(ticker)')
            self.db.execute('CREATE INDEX _master_perm ON _master(permaticker)')
            self._master_ready = True

    def resolve_security(self, ticker):
        ticker = str(ticker).strip()
        if ticker in self._identities:
            return self._identities[ticker]
        self._master()
        clause = '"table" IN (' + ','.join('?' for _ in SECURITY_TABLES) + ')'
        by_id = ticker.startswith('sharadar:security:')
        field, value = ('permaticker', ticker.rsplit(':', 1)[1]) if by_id else ('ticker', ticker.upper())
        rows = self._rows(f'SELECT * FROM _master WHERE {field}=? AND {clause}', [value, *SECURITY_TABLES])
        alias_evidence = []
        if not rows and not by_id and 'actions' in self._datasets:
            # Merger, spinoff and relatedticker links do NOT establish one security.
            alias_evidence = self._rows("SELECT * FROM actions WHERE contraticker=? AND action IN ('tickerchangefrom','tickerchangeto')", [value])
            candidates = sorted({row['ticker'] for row in alias_evidence})
            if candidates:
                marks = ','.join('?' for _ in candidates)
                rows = self._rows(f'SELECT * FROM _master WHERE ticker IN ({marks}) AND {clause}', [*candidates, *SECURITY_TABLES])
        identities = {str(row['permaticker']) for row in rows}
        if len(identities) != 1:
            raise MissingData('security identity missing or ambiguous; supply a verified security mapping')
        perm = next(iter(identities))
        rows = self._rows(f'SELECT * FROM _master WHERE permaticker=? AND {clause}', [perm, *SECURITY_TABLES])
        ciks = {cik for row in rows if (cik := _cik(row.get('secfilings')))}
        if len(ciks) > 1:
            raise MissingData('conflicting issuer CIK metadata for one security')
        latest = max(rows, key=lambda row: (str(row.get('lastpricedate') or ''),
                    str(row.get('lastupdated') or ''), row['ticker'] == value, row['ticker']))
        price_datasets = sorted({{'SEP':'stocks','stocks':'stocks','SFP':'funds','funds':'funds'}[row['table']]
                                for row in rows if row['table'] in ('SEP','stocks','SFP','funds')})
        result = {'security_id': f'sharadar:security:{perm}',
                  'company_id': f'sec:cik:{next(iter(ciks))}' if ciks else None,
                  'ticker': latest['ticker'], 'requested_ticker': ticker,
                  'permaticker': latest['permaticker'], 'aliases': sorted({row['ticker'] for row in rows}),
                  'company_identity_status': 'verified_cik' if ciks else 'unresolved',
                  'price_datasets': price_datasets,
                  'price_dataset': price_datasets[0] if len(price_datasets)==1 else None,
                  'identity_basis': 'current_security_master_not_historical_universe',
                  'provenance': [self._lineage('tickers', row) for row in rows] +
                                [self._lineage('actions', row) for row in alias_evidence]}
        self._identities[ticker] = result
        return result

    def get_ticker_history(self, ticker):
        identity = self.resolve_security(ticker)
        self._require('actions')
        marks = ','.join('?' for _ in identity['aliases'])
        rows = self._rows(f"SELECT * FROM actions WHERE ticker IN ({marks}) AND action IN ('tickerchangefrom','tickerchangeto') ORDER BY date,action", identity['aliases'])
        events = {}
        for row in rows:
            event = events.setdefault(row['date'], {'effective_date': row['date'], 'from_ticker': None,
                'to_ticker': None, 'security_id': identity['security_id'], 'company_id': identity['company_id'], 'provenance': []})
            field = 'from_ticker' if row['action'] == 'tickerchangefrom' else 'to_ticker'
            if event[field] not in (None, row['contraticker']):
                raise MissingData('conflicting ticker-change history')
            event[field] = row['contraticker']
            event['provenance'].append(self._lineage('actions', row))
        return list(events.values())

    def _security_rows(self, table, identity, condition='', params=(), order='date'):
        self._require(table)
        aliases = identity['aliases']
        marks = ','.join('?' for _ in aliases)
        rows = self._rows(f'SELECT * FROM {ident(table)} WHERE ticker IN ({marks})' +
                         (' AND ' + condition if condition else '') + f' ORDER BY {order}', [*aliases, *params])
        # Retained old-name archives may coexist with rewired current history.
        # Deduplicate identical facts only. Conflicts are explicit, not guessed.
        keys = [key for key in self._contracts[table].keys if key != 'ticker']
        seen, result = {}, []
        ignored = {'ticker', 'lastupdated', '_ingestion_run', '_observed_at'}
        for row in rows:
            key = tuple(row[field] for field in keys)
            comparable = {field: value for field, value in row.items() if field not in ignored}
            if key in seen:
                if seen[key] != comparable:
                    raise MissingData(f'{table}: conflicting retained ticker-alias facts')
                continue
            seen[key] = comparable
            result.append(row)
        return result

    def _price_basis(self, price_type):
        if isinstance(price_type, PriceType):
            return price_type
        try:
            return PriceType[str(price_type)]
        except KeyError as exc:
            raise ValueError('explicit RAW_CLOSE, SPLIT_ADJUSTED_CLOSE or TOTAL_RETURN_ADJUSTED_CLOSE required') from exc

    def _price_result(self, row, basis, identity, dataset):
        value = row[basis.value]
        if value is None or not math.isfinite(value) or value <= 0:
            raise MissingData(f'{dataset}: invalid {basis.name} observation')
        return {'date': row['date'], 'value': value, 'price_type': basis.name,
                'security_id': identity['security_id'], 'company_id': identity['company_id'],
                'ticker': identity['ticker'], 'currency': 'USD',
                'available_at': row['date'], 'availability_precision': 'session_date_end_of_day',
                'adjustment_basis': 'vendor_current_adjustment_factors' if basis != PriceType.RAW_CLOSE else 'historical_quoted_price',
                'provenance': self._lineage(dataset, row)}

    def _price_dataset(self, dataset, identity):
        if dataset == 'auto':
            dataset = identity['price_dataset']
            if dataset is None:
                raise MissingData('security master does not establish one unambiguous price dataset')
        return dataset

    def get_price_history(self, ticker, start, end, price_type, *, dataset='auto'):
        identity = self.resolve_security(ticker)
        dataset = self._price_dataset(dataset, identity)
        if dataset not in ('stocks', 'funds'):
            raise ValueError('invalid price dataset')
        basis = self._price_basis(price_type)
        if _date(start) > _date(end):
            raise ValueError('start must not be after end')
        rows = self._security_rows(dataset, identity, 'date BETWEEN ? AND ?', [start, end])
        return [self._price_result(row, basis, identity, dataset) for row in rows]

    def get_price(self, ticker, as_of, price_type, *, dataset='auto'):
        identity = self.resolve_security(ticker)
        dataset = self._price_dataset(dataset, identity)
        if dataset not in ('stocks', 'funds'):
            raise ValueError('invalid price dataset')
        self._require(dataset)
        basis = self._price_basis(price_type)
        marks = ','.join('?' for _ in identity['aliases'])
        last = self.db.execute(f'SELECT max(date) FROM {ident(dataset)} WHERE ticker IN ({marks}) AND date<=?', [*identity['aliases'], as_of]).fetchone()[0]
        if last is None:
            return None
        rows = self._security_rows(dataset, identity, 'date=?', [last])
        return self._price_result(rows[0], basis, identity, dataset)

    def get_prices(self, tickers, as_of, price_type, *, dataset='auto'):
        self._price_basis(price_type)
        if dataset == 'auto':
            requested = list(dict.fromkeys(tickers))
            grouped = {'stocks': [], 'funds': []}
            result = dict.fromkeys(requested)
            for ticker in requested:
                try:
                    known_dataset = self._price_dataset('auto', self.resolve_security(ticker))
                    grouped[known_dataset].append(ticker)
                except MissingData:
                    pass
            for known_dataset, group in grouped.items():
                if group and known_dataset in self._datasets:
                    result.update(self.get_prices(group, as_of, price_type, dataset=known_dataset))
            return result
        if dataset not in ('stocks', 'funds'):
            raise ValueError('invalid price dataset')
        self._require(dataset)
        basis = self._price_basis(price_type)
        requested = list(dict.fromkeys(tickers))
        identities = {}
        for ticker in requested:
            try:
                identities[ticker] = self.resolve_security(ticker)
            except MissingData:
                # A private/non-US or ambiguous security must not erase valid
                # observations for the remainder of a dashboard's batch.
                pass
        if not identities:
            return dict.fromkeys(requested)
        pairs = [(ticker, alias) for ticker, identity in identities.items() for alias in identity['aliases']]
        values = ','.join('(?,?)' for _ in pairs)
        rows = self._rows(f'SELECT p.*,requested FROM {ident(dataset)} p JOIN (VALUES {values}) wanted(requested,alias) ON p.ticker=wanted.alias WHERE p.date<=? QUALIFY p.date=max(p.date) OVER (PARTITION BY requested)',
                          [item for pair in pairs for item in pair] + [as_of])
        result = dict.fromkeys(requested)
        invalid = set()
        for row in rows:
            ticker = row.pop('requested')
            if ticker in invalid:
                continue
            try:
                fact = self._price_result(row, basis, identities[ticker], dataset)
                if result[ticker] is not None and result[ticker]['value'] != fact['value']:
                    raise MissingData(f'{dataset}: conflicting retained ticker-alias prices')
                result[ticker] = fact
            except MissingData:
                # Fail this security closed, not every unrelated quote in the
                # dashboard. Singular methods retain the explicit exception.
                result[ticker] = None
                invalid.add(ticker)
        return result

    def get_latest_fundamentals(self, tickers, dimension='ART', *, as_of=None):
        """Batch latest report period, then latest eligible filing within it."""
        self._require('fundamentals')
        if dimension not in DIMENSIONS:
            raise ValueError('invalid dimension')
        if as_of is not None and not dimension.startswith('AR'):
            raise PITUnavailable('MR dimensions contain restatements; historical as-of requires AR')
        requested = list(dict.fromkeys(tickers))
        identities = {}
        for ticker in requested:
            try:
                identities[ticker] = self.resolve_security(ticker)
            except MissingData:
                pass
        if not identities:
            return dict.fromkeys(requested)
        pairs = [(ticker, alias) for ticker, identity in identities.items() for alias in identity['aliases']]
        values = ','.join('(?,?)' for _ in pairs)
        params = [item for pair in pairs for item in pair] + [dimension]
        condition = 'p.dimension=?'
        if dimension.startswith('AR'):
            condition += ' AND p.reportperiod<=p.date'
        if as_of is not None:
            condition += ' AND p.date<=? AND p.reportperiod<=?'
            params += [as_of, as_of]
        rows = self._rows(f'SELECT p.*,requested FROM fundamentals p JOIN (VALUES {values}) wanted(requested,alias) ON p.ticker=wanted.alias WHERE {condition} QUALIFY dense_rank() OVER (PARTITION BY requested ORDER BY p.reportperiod DESC,p.date DESC)=1', params)
        result = dict.fromkeys(requested)
        invalid = set()
        for row in rows:
            ticker = row.pop('requested')
            if ticker in invalid:
                continue
            identity = identities[ticker]
            fact = {**row, 'security_id': identity['security_id'], 'company_id': identity['company_id'],
                'period_end': row['reportperiod'], 'datekey': row['date'],
                'available_at': row['date'] if dimension.startswith('AR') else None,
                'pit_basis': 'as_reported_filing_date_day_precision' if dimension.startswith('AR') else 'restated_non_pit',
                'provenance': self._lineage('fundamentals', row)}
            if result[ticker] is not None:
                ignored = {'ticker', 'lastupdated', '_ingestion_run', '_observed_at', 'provenance'}
                if {k:v for k,v in fact.items() if k not in ignored} != {k:v for k,v in result[ticker].items() if k not in ignored}:
                    result[ticker] = None
                    invalid.add(ticker)
                    continue
            result[ticker] = fact
        return result

    _FUNDAMENTAL_RESEARCH_FIELDS = (
        'ticker', 'dimension', 'calendardate', 'date', 'reportperiod', 'fiscalperiod',
        'lastupdated', 'revenue', 'gp', 'opinc', 'ebit', 'netinccmn', 'ncfo', 'capex',
        'fcf', 'sbcomp', 'rnd', 'sgna', 'sharesbas', 'shareswa', 'shareswadil',
        'ncfcommon', 'ncfdiv', 'invcap', 'debt', 'cashneq', 'intexp',
        'workingcapital', 'assets', 'equity', 'deposits', 'roic', 'dps', 'currency',
    )

    @staticmethod
    def _finite_number(value):
        return value if isinstance(value, (int, float)) and math.isfinite(value) else None

    @classmethod
    def _research_point(cls, row, lineage):
        point = {field: row.get(field) for field in cls._FUNDAMENTAL_RESEARCH_FIELDS if field in row}
        point.update({'period_end': row['reportperiod'], 'available_at': row['date'],
                      'pit_basis': 'as_reported_filing_date_day_precision',
                      'provenance': lineage})
        return point

    @classmethod
    def _quarter_metrics(cls, points):
        """Deterministic, null-preserving metrics from comparable reported quarters."""
        by_rank = {point['quarter_rank']: point for point in points}

        def n(rank, field):
            return cls._finite_number(by_rank.get(rank, {}).get(field))

        def sum4(start, field):
            values = [n(rank, field) for rank in range(start, start + 4)]
            return sum(values) if all(value is not None for value in values) else None

        def ratio(a, b):
            return a / b if a is not None and b is not None and b != 0 else None

        def growth(a, b):
            return a / b - 1 if a is not None and b is not None and b > 0 else None

        latest, year_ago = by_rank.get(1), by_rank.get(5)
        previous, previous_year = by_rank.get(2), by_rank.get(6)
        current = {field: sum4(1, field) for field in
                   ('revenue', 'gp', 'opinc', 'ebit', 'netinccmn', 'ncfo', 'capex',
                    'fcf', 'sbcomp', 'rnd', 'sgna', 'ncfcommon', 'ncfdiv', 'intexp')}
        prior_q = {field: sum4(2, field) for field in current}
        prior_y = {field: sum4(5, field) for field in current}
        latest_shares = n(1, 'shareswadil') or n(1, 'sharesbas')
        year_shares = n(5, 'shareswadil') or n(5, 'sharesbas')
        current_eps = ratio(current['netinccmn'], latest_shares)
        prior_eps = ratio(prior_y['netinccmn'], year_shares)
        current_invcap, prior_invcap = n(1, 'invcap'), n(5, 'invcap')
        average_invcap = (current_invcap + prior_invcap) / 2 if current_invcap is not None and prior_invcap is not None else None
        return {
            'revenueGrowth': growth(n(1, 'revenue'), n(5, 'revenue')),
            'priorRevenueGrowth': growth(n(2, 'revenue'), n(6, 'revenue')),
            'ttmRevenue': current['revenue'], 'ttmRevenuePriorQuarter': prior_q['revenue'],
            'ttmRevenuePriorYear': prior_y['revenue'],
            'grossMargin': ratio(current['gp'], current['revenue']),
            'grossMarginPriorQuarter': ratio(prior_q['gp'], prior_q['revenue']),
            'operatingMargin': ratio(current['opinc'], current['revenue']),
            'operatingMarginPriorQuarter': ratio(prior_q['opinc'], prior_q['revenue']),
            'operatingMarginPriorYear': ratio(prior_y['opinc'], prior_y['revenue']),
            'cfoMargin': ratio(current['ncfo'], current['revenue']),
            'cfoMarginPriorYear': ratio(prior_y['ncfo'], prior_y['revenue']),
            'fcfMargin': ratio(current['fcf'], current['revenue']),
            'fcfMarginPriorYear': ratio(prior_y['fcf'], prior_y['revenue']),
            'sbcMargin': ratio(current['sbcomp'], current['revenue']),
            'capexIntensity': ratio(abs(current['capex']) if current['capex'] is not None else None, current['revenue']),
            'capexIntensityPriorYear': ratio(abs(prior_y['capex']) if prior_y['capex'] is not None else None, prior_y['revenue']),
            'dilutedSharesGrowth': growth(latest_shares, year_shares),
            'netIncomeGrowth': growth(current['netinccmn'], prior_y['netinccmn']),
            'perShareIncomeGrowth': growth(current_eps, prior_eps),
            'netCommonFinancing': current['ncfcommon'],
            'netDividendCashFlow': current['ncfdiv'],
            'preTaxCapitalReturn': ratio(current['ebit'], average_invcap),
            'vendorReportedRoic': n(1, 'roic'),
            'debt': n(1, 'debt'), 'cash': n(1, 'cashneq'),
            'interestCoverage': ratio(current['ebit'], abs(current['intexp']) if current['intexp'] is not None else None),
            'latestQuarterRevenue': n(1, 'revenue'),
            'latestQuarterOperatingIncome': n(1, 'opinc'),
            'latestQuarterFcf': n(1, 'fcf'),
            'latestDilutedShares': latest_shares,
            'ttmOperatingIncome': current['opinc'], 'ttmCfo': current['ncfo'],
            'ttmFcf': current['fcf'], 'ttmSbc': current['sbcomp'],
            'quarterCount': len(points),
            'annualComparisonReady': latest is not None and year_ago is not None,
            'sequentialComparisonReady': latest is not None and previous is not None,
            'priorSequentialYearReady': previous is not None and previous_year is not None,
        }

    def get_fundamental_change_universe(self, as_of, *, limit=6000):
        """One compact PIT scan for discovery; no valuation-model dependency."""
        self._require('fundamentals')
        self._master()
        limit = int(limit)
        if limit < 1 or limit > 10000:
            raise ValueError('fundamental universe limit must be between 1 and 10000')
        cutoff = _date(as_of)
        prior_date = cutoff - timedelta(days=365)
        price_start = prior_date - timedelta(days=35)
        fields = ','.join('f.' + ident(field) for field in self._FUNDAMENTAL_RESEARCH_FIELDS if field != 'currency')
        fields += ',f._ingestion_run,f._observed_at,f._quality_issues'
        rows = self._rows(f'''WITH revisions AS (
              SELECT {fields}, ROW_NUMBER() OVER (
                PARTITION BY f.ticker,f.reportperiod ORDER BY f.date DESC,f.lastupdated DESC
              ) revision_rank
              FROM fundamentals f
              WHERE f.dimension='ARQ' AND f.date<=? AND f.reportperiod<=f.date AND f.reportperiod<=?
            ), ranked AS (
              SELECT *,ROW_NUMBER() OVER(PARTITION BY ticker ORDER BY reportperiod DESC,date DESC) quarter_rank
              FROM revisions WHERE revision_rank=1
            ), master AS (
              SELECT ticker,name,exchange,category,sector,industry,sicsector,sicindustry,currency,location,
                permaticker,lastquarter,lastpricedate,secfilings,companysite
              FROM _master WHERE "table"='SF1' AND COALESCE(isdelisted,'N')='N'
              QUALIFY ROW_NUMBER() OVER(PARTITION BY ticker ORDER BY lastupdated DESC,permaticker DESC)=1
            ), eligible AS (
              SELECT ranked.ticker FROM ranked JOIN master USING(ticker)
              WHERE quarter_rank=1 ORDER BY reportperiod DESC,ranked.ticker LIMIT ?
            ), prices AS (
              SELECT stocks.ticker,
                arg_max(close,date) current_price,
                arg_max(close,date) FILTER (WHERE date<=?) prior_price
              FROM stocks JOIN eligible USING(ticker)
              WHERE date BETWEEN ? AND ? AND close IS NOT NULL AND close>0
              GROUP BY stocks.ticker
            )
            SELECT ranked.*,master.name,master.exchange,master.category,master.sector,master.industry,
              master.sicsector,master.sicindustry,master.currency,master.location,master.permaticker,
              master.lastquarter,master.lastpricedate,master.secfilings,master.companysite,
              prices.current_price,prices.prior_price
            FROM ranked JOIN eligible USING(ticker) LEFT JOIN master USING(ticker)
              LEFT JOIN prices USING(ticker)
            WHERE quarter_rank<=8 ORDER BY ticker,quarter_rank''',
            [as_of, as_of, limit, prior_date, price_start, cutoff])
        grouped = {}
        for row in rows:
            grouped.setdefault(row['ticker'], []).append(row)
        companies = []
        for ticker, points in grouped.items():
            latest = points[0]
            metrics = self._quarter_metrics(points)
            companies.append({
                'ticker': ticker, 'name': latest.get('name') or ticker,
                'exchange': latest.get('exchange'), 'category': latest.get('category'),
                'sector': latest.get('sector'), 'industry': latest.get('industry'),
                'sicsector': latest.get('sicsector'), 'sicindustry': latest.get('sicindustry'),
                'currency': latest.get('currency'), 'location': latest.get('location'),
                'security_id': f"sharadar:security:{latest['permaticker']}" if latest.get('permaticker') is not None else None,
                'period_end': latest['reportperiod'], 'available_at': latest['date'],
                'fiscal_period': latest.get('fiscalperiod'), 'metrics': metrics,
                'market': {'currentPrice': latest.get('current_price'),
                           'priorYearPrice': latest.get('prior_price'),
                           'priceReturn': (latest['current_price'] / latest['prior_price'] - 1)
                           if self._finite_number(latest.get('current_price')) is not None and
                              self._finite_number(latest.get('prior_price')) is not None and latest['prior_price'] > 0 else None,
                           'priceBasis': 'Sharadar split-adjusted close',
                           'comparisonDate': prior_date.isoformat()},
                'source': {'dataset': 'SF1', 'dimension': 'ARQ',
                           'period_end': latest['reportperiod'], 'available_at': latest['date'],
                           'pit_basis': 'as_reported_latest_visible_revision',
                           'catalog_generation': self.generation,
                           'provenance': self._lineage('fundamentals', latest)},
            })
        return {'version': 'fact-fundamental-universe-v1', 'as_of': str(as_of),
                'catalog_generation': self.generation, 'companies': companies}

    def get_fundamental_company_index(self, as_of, *, search='', limit=120):
        """Compact Fact OS company search pool; no prices, metrics or model dependency."""
        self._require('fundamentals')
        self._master()
        limit = int(limit)
        if limit < 1 or limit > 500:
            raise ValueError('fundamental company index limit must be between 1 and 500')
        search = str(search or '').strip().lower()
        if len(search) > 80:
            raise ValueError('fundamental company search too long')
        pattern = f'%{search}%'
        rows = self._rows('''WITH latest AS (
              SELECT f.ticker,f.reportperiod,f.date,ROW_NUMBER() OVER(
                PARTITION BY f.ticker ORDER BY f.reportperiod DESC,f.date DESC,f.lastupdated DESC
              ) rank
              FROM fundamentals f
              WHERE f.dimension='ARQ' AND f.date<=? AND f.reportperiod<=f.date AND f.reportperiod<=?
            ), master AS (
              SELECT ticker,name,permaticker
              FROM _master WHERE "table" IN ('SF1','stocks')
              QUALIFY ROW_NUMBER() OVER(PARTITION BY ticker ORDER BY
                CASE WHEN "table"='SF1' THEN 0 ELSE 1 END,lastupdated DESC,permaticker DESC)=1
            )
            SELECT latest.ticker,master.name,latest.reportperiod,latest.date,master.permaticker
            FROM latest JOIN master USING(ticker) WHERE latest.rank=1
              AND (?='' OR lower(latest.ticker) LIKE ? OR lower(master.name) LIKE ?)
            ORDER BY CASE WHEN lower(latest.ticker)=? THEN 0
              WHEN lower(latest.ticker) LIKE ? THEN 1
              WHEN lower(master.name) LIKE ? THEN 2 ELSE 3 END,latest.ticker LIMIT ?''',
            [as_of, as_of, search, pattern, pattern, search, f'{search}%', f'{search}%', limit])
        return {'version': 'fact-fundamental-company-index-v1', 'as_of': str(as_of),
                'catalog_generation': self.generation, 'companies': [{
                    'ticker': row['ticker'], 'name': row.get('name') or row['ticker'],
                    'period_end': row['reportperiod'],
                    'available_at': row['date'],
                    'security_id': f"sharadar:security:{row['permaticker']}"
                    if row.get('permaticker') is not None else None,
                } for row in rows]}

    def get_fundamental_research(self, ticker, as_of, *, quarters=16, years=8):
        """Bounded source facts for one company; restated dimensions are never mixed into PIT."""
        quarters, years = int(quarters), int(years)
        if not 4 <= quarters <= 40 or not 1 <= years <= 20:
            raise ValueError('invalid fundamental research history bound')
        identity = self.resolve_security(ticker)
        self._master()
        rows = self._security_rows('fundamentals', identity,
            "dimension IN ('ARQ','ARY') AND date<=? AND reportperiod<=date AND reportperiod<=?",
            [as_of, as_of], 'dimension,reportperiod,date')
        latest = {}
        for row in rows:
            latest[(row['dimension'], row['reportperiod'])] = row
        quarterly = sorted((row for (dimension, _), row in latest.items() if dimension == 'ARQ'),
                           key=lambda row: (row['reportperiod'], row['date']), reverse=True)[:quarters]
        annual = sorted((row for (dimension, _), row in latest.items() if dimension == 'ARY'),
                        key=lambda row: (row['reportperiod'], row['date']), reverse=True)[:years]
        masters = self._rows("SELECT * FROM _master WHERE permaticker=? AND \"table\"='SF1' ORDER BY lastupdated DESC", [identity['permaticker']])
        master = masters[0] if masters else {}
        return {
            'version': 'fact-fundamental-research-v1', 'as_of': str(as_of),
            'ticker': identity['ticker'], 'identity': identity,
            'company': {key: master.get(key) for key in ('name','exchange','category','sector','industry','sicsector','sicindustry','currency','location','companysite','secfilings')},
            'quarterly': [self._research_point(row, self._lineage('fundamentals', row)) for row in quarterly],
            'annual': [self._research_point(row, self._lineage('fundamentals', row)) for row in annual],
            'reported_basis': 'ARQ/ARY latest revision visible by the requested as-of date',
            'restated_basis': 'withheld_in_historical_pit; MRQ/MRY are not mixed with as-reported facts',
            'catalog_generation': self.generation,
        }

    def get_fundamentals(self, ticker, dimension='ART', *, as_of=None):
        if dimension not in DIMENSIONS:
            raise ValueError('invalid dimension')
        if as_of is not None and not dimension.startswith('AR'):
            raise PITUnavailable('MR dimensions contain restatements; historical as-of requires AR')
        identity = self.resolve_security(ticker)
        condition, params = 'dimension=?', [dimension]
        if dimension.startswith('AR'):
            condition += ' AND reportperiod<=date'
        if as_of is not None:
            condition += ' AND date<=? AND reportperiod<=?'
            params += [as_of, as_of]
        rows = self._security_rows('fundamentals', identity, condition, params, 'date,reportperiod')
        return [{**row, 'security_id': identity['security_id'], 'company_id': identity['company_id'],
                 'period_end': row['reportperiod'], 'datekey': row['date'],
                 'available_at': row['date'] if dimension.startswith('AR') else None,
                 'pit_basis': 'as_reported_filing_date_day_precision' if dimension.startswith('AR') else 'restated_non_pit',
                 'provenance': self._lineage('fundamentals', row)} for row in rows]

    def get_dividends(self, ticker, start, end):
        identity = self.resolve_security(ticker)
        rows = self._security_rows('actions', identity, "action='dividend' AND date BETWEEN ? AND ?", [start, end])
        # Official descriptions/actiontypes/dividend: USD/share, adjusted for
        # stock splits and stock dividends. Date is EX date, not payment date.
        return [{'date': row['date'], 'ex_date': row['date'], 'payment_date': None,
                 'value': row['value'], 'unit': 'USD/share', 'currency': 'USD',
                 'basis': 'split_and_stock_dividend_adjusted_per_share',
                 'security_id': identity['security_id'], 'company_id': identity['company_id'],
                 'cash_accounting_ready': False, 'available_at': None,
                 'provenance': self._lineage('actions', row)} for row in rows]

    def _holdings_pit(self, as_of):
        if as_of is not None:
            raise PITUnavailable('SF3 has no filing availability timestamp; quarter date is not knowledge date')

    def _holding_ticker(self, ticker):
        try:
            return self.resolve_security(ticker)['ticker']
        except MissingData:
            if str(ticker).startswith('sharadar:security:'):
                raise
            # SF3 covers securities outside the price/fundamentals master too.
            # Retain their explicit vendor ticker without inventing an identity.
            return str(ticker).upper()

    def _holding(self, row):
        try:
            identity = self.resolve_security(row['ticker'])
        except MissingData:
            identity = {'security_id': None, 'company_id': None}
        return {'quarter': row['date'], 'ticker': row['ticker'],
                'security_id': identity['security_id'], 'company_id': identity['company_id'],
                'security_identity_status': 'verified' if identity['security_id'] else 'unresolved',
                'institutional_investor_id': 'sharadar:investor:' + row['investorid'],
                'investor_id': row['investorid'], 'security_type': row['securitytype'],
                'units': row['units'] * 1000 if row['units'] is not None else None,
                'value_usd': row['value'] * 1000000 if row['value'] is not None else None,
                'available_at': None, 'pit_supported': False, 'provenance': self._lineage('holdings', row)}

    def _type_filter(self, security_type):
        if security_type == 'CALL':
            security_type = 'CLL'  # Legacy caller alias; the returned fact stays CLL.
        if security_type is not None and security_type not in SECURITY_TYPES:
            raise ValueError('unsupported Sharadar security_type; use null for all types')
        return (' AND securitytype=?', [security_type]) if security_type else ('', [])

    def get_institutional_holdings(self, ticker, quarter, security_type='SHR', *, as_of=None):
        self._require('holdings')
        self._holdings_pit(as_of)
        _previous_quarter(quarter)
        ticker = self._holding_ticker(ticker)
        clause, params = self._type_filter(security_type)
        rows = self._rows('SELECT * FROM holdings WHERE ticker=? AND date=?' + clause + ' ORDER BY value DESC,investorid,securitytype', [ticker, quarter, *params])
        return [self._holding(row) for row in rows]

    def get_institutional_ownership_history(self, ticker, *, as_of=None):
        self._require('holdings_ticker')
        self._holdings_pit(as_of)
        ticker = self._holding_ticker(ticker)
        rows = self._rows('SELECT * FROM holdings_ticker WHERE ticker=? ORDER BY date', [ticker])
        result, previous = [], None
        fields = ('institutional_holder_count', 'institutional_share_units', 'institutional_share_value_usd', 'total_institutional_value_usd', 'percent_of_total')
        for row in rows:
            current = {'ticker': ticker, 'quarter': row['date'], 'institutional_holder_count': row['shrholders'],
                'institutional_share_units': None if row['shrunits'] is None else row['shrunits'] * 1000,
                'institutional_share_value_usd': None if row['shrvalue'] is None else row['shrvalue'] * 1000000,
                'total_institutional_value_usd': None if row['totalvalue'] is None else row['totalvalue'] * 1000000,
                'percent_of_total': row['percentoftotal'],
                'percent_of_total_unit': 'percent',
                'percent_basis': 'share of aggregate institutional portfolio value, not issuer ownership',
                'available_at': None, 'pit_supported': False, 'provenance': self._lineage('holdings_ticker', row)}
            prior = previous if previous and previous['quarter'] == _previous_quarter(row['date']) else None
            for field in fields:
                current['previous_' + field] = prior[field] if prior else None
                current['qoq_' + field] = current[field] - prior[field] if prior and current[field] is not None and prior[field] is not None else None
            result.append(current)
            previous = current
        return result

    def _complete_quarters(self, quarter):
        self._require('holdings')
        q, previous = _date(quarter), _previous_quarter(quarter)
        state = self._states.get('holdings', {})
        if (not state.get('backfill_complete') or not state.get('min_date') or not state.get('max_date') or
                _date(state['min_date']) > previous or _date(state['max_date']) < q):
            raise MissingData('complete current and prior SF3 quarter coverage required')
        if self.db.execute('SELECT count(DISTINCT date) FROM holdings WHERE date IN (?,?)', [previous, q]).fetchone()[0] != 2:
            raise MissingData('current or preceding SF3 quarter is absent')
        return q, previous

    def _changes(self, old, new, q, previous):
        result = []
        for key in sorted(old.keys() | new.keys()):
            before, after = old.get(key), new.get(key)
            pu, cu = before['units'] if before else 0, after['units'] if after else 0
            if pu is None or cu is None:
                raise MissingData('missing units cannot classify a holder change')
            change = 'NEW' if before is None else 'EXITED' if after is None else 'INCREASED' if cu > pu else 'DECREASED' if cu < pu else 'UNCHANGED'
            sample = after or before
            result.append({'investor_id': sample['investor_id'],
                'institutional_investor_id': sample['institutional_investor_id'], 'ticker': sample['ticker'],
                'security_id': sample['security_id'], 'company_id': sample['company_id'],
                'quarter': q, 'previous_quarter': previous, 'security_type': sample['security_type'], 'change': change,
                'previous_units': pu, 'current_units': cu, 'unit_change': cu - pu,
                'percentage_change': (cu / pu - 1) * 100 if pu else None,
                'previous_value_usd': before['value_usd'] if before else 0,
                'current_value_usd': after['value_usd'] if after else 0,
                'available_at': None, 'pit_supported': False,
                'change_basis': 'reported_units_not_split_adjusted_trading_intent',
                'provenance': [row['provenance'] for row in (before, after) if row]})
        return result

    def get_holder_changes(self, ticker, quarter, security_type='SHR', *, as_of=None):
        self._holdings_pit(as_of)
        q, previous = self._complete_quarters(quarter)
        old = {(row['investor_id'], row['security_type']): row for row in self.get_institutional_holdings(ticker, previous, security_type)}
        new = {(row['investor_id'], row['security_type']): row for row in self.get_institutional_holdings(ticker, q, security_type)}
        self._require('holdings_investor')
        ids = sorted({key[0] for key in old.keys() | new.keys()})
        names = {}
        if ids:
            rows = self._rows('SELECT investorid,investorname FROM holdings_investor WHERE date<=? AND investorid IN (' + ','.join('?' for _ in ids) + ') QUALIFY row_number() OVER (PARTITION BY investorid ORDER BY date DESC)=1', [q, *ids])
            names = {row['investorid']: row['investorname'] for row in rows}
        return [{**row, 'investor_name': names.get(row['investor_id'])} for row in self._changes(old, new, q, previous)]

    def get_investor_portfolio(self, investor_id, quarter, security_type='SHR', *, as_of=None):
        self._require('holdings')
        self._holdings_pit(as_of)
        _previous_quarter(quarter)
        investor_id = str(investor_id).removeprefix('sharadar:investor:')
        clause, params = self._type_filter(security_type)
        rows = self._rows('SELECT * FROM holdings WHERE investorid=? AND date=?' + clause + ' ORDER BY value DESC,ticker,securitytype', [investor_id, quarter, *params])
        total = sum(row['value'] for row in rows) if rows and all(row['value'] is not None for row in rows) else None
        return [{**self._holding(row), 'rank': index + 1,
                 'portfolio_weight': row['value'] / total if total else None,
                 'weight_basis': f'reported_{security_type or "all_security_types"}_value_not_entire_fund_nav'} for index, row in enumerate(rows)]

    def get_investor_changes(self, investor_id, quarter, security_type='SHR', *, as_of=None):
        self._holdings_pit(as_of)
        q, previous = self._complete_quarters(quarter)
        old = {(row['ticker'], row['security_type']): row for row in self.get_investor_portfolio(investor_id, previous, security_type)}
        new = {(row['ticker'], row['security_type']): row for row in self.get_investor_portfolio(investor_id, q, security_type)}
        return self._changes(old, new, q, previous)

    def get_investors(self):
        self._master()
        if self._investors is None:
            rows = self._rows('SELECT * FROM _master WHERE "table" IN (?,?) ORDER BY ticker', INVESTOR_TABLES)
            grouped = {}
            for row in rows:
                grouped.setdefault(row['ticker'], []).append(row)
            self._investors = []
            for investor_id, group in grouped.items():
                ciks = {cik for row in group if (cik := _cik(row.get('secfilings')))}
                if len(ciks) > 1:
                    raise MissingData(f'{investor_id}: conflicting institutional filer CIK metadata')
                latest = max(group, key=lambda row: (str(row.get('lastquarter') or ''), str(row.get('lastupdated') or '')))
                self._investors.append({'investor_id': investor_id,
                    'institutional_investor_id': 'sharadar:investor:' + investor_id,
                    'name': latest.get('name'), 'investor_name': latest.get('name'),
                    'cik': next(iter(ciks)) if ciks else None, 'permaticker': latest['permaticker'],
                    'first_quarter': latest.get('firstquarter'), 'last_quarter': latest.get('lastquarter'),
                    'provenance': [self._lineage('tickers', row) for row in group]})
        return self._investors

    def resolve_investor(self, investor_id=None, *, cik=None, name=None):
        if sum(value is not None for value in (investor_id, cik, name)) != 1:
            raise ValueError('supply exactly one investor_id, exact CIK, or exact official name')
        key = str(investor_id).removeprefix('sharadar:investor:') if investor_id is not None else None
        normalized_cik = str(int(str(cik))) if cik is not None and str(cik).isdigit() else None
        rows = [row for row in self.get_investors() if
                (key is not None and row['investor_id'] == key) or
                (normalized_cik is not None and row['cik'] == normalized_cik) or
                (name is not None and row['name'] == name)]
        if len(rows) != 1:
            raise MissingData('institutional investor mapping is missing or ambiguous; no fuzzy matching permitted')
        return rows[0]

    def get_investor_history(self, investor_id, *, as_of=None):
        self._holdings_pit(as_of)
        self._require('holdings_investor')
        investor_id = str(investor_id).removeprefix('sharadar:investor:')
        rows = self._rows('SELECT * FROM holdings_investor WHERE investorid=? ORDER BY date', [investor_id])
        return [{**row, 'quarter': row['date'], 'investor_id': investor_id,
                 'institutional_investor_id': 'sharadar:investor:' + investor_id,
                 'available_at': None, 'pit_supported': False,
                 'value_usd': row['totalvalue'] * 1000000 if row.get('totalvalue') is not None else None,
                 'share_value_usd': row['shrvalue'] * 1000000 if row.get('shrvalue') is not None else None,
                 'reported_positions': sum(row[field] for field in ('shrholdings','cllholdings','putholdings','wntholdings','dbtholdings','prfholdings','fndholdings','undholdings'))
                    if all(row.get(field) is not None for field in ('shrholdings','cllholdings','putholdings','wntholdings','dbtholdings','prfholdings','fndholdings','undholdings')) else None,
                 'provenance': self._lineage('holdings_investor', row)} for row in rows]

    def get_metric_history(self, ticker, metric_id, *, as_of=None, dimension='ART'):
        from .registry import METRICS
        if metric_id not in METRICS:
            raise ValueError('unknown canonical metric')
        metric = METRICS[metric_id]
        table = metric['table']
        if table == 'fundamentals':
            rows = self.get_fundamentals(ticker, dimension, as_of=as_of)
        elif table == 'daily':
            identity = self.resolve_security(ticker)
            rows = self._security_rows('daily', identity, 'date<=?' if as_of else '', [as_of] if as_of else [])
        elif table == 'holdings_ticker':
            self._holdings_pit(as_of)
            self._require(table)
            rows = self._rows('SELECT * FROM holdings_ticker WHERE ticker=? ORDER BY date', [self._holding_ticker(ticker)])
        else:
            raise ValueError('unsupported metric source')
        try:
            identity = self.resolve_security(ticker)
        except MissingData:
            identity = {'security_id': None, 'company_id': None}
        result = []
        for row in rows:
            if metric['field'] not in row:
                raise MissingData(f'{metric_id}: source field is absent from the local contract')
            value = row[metric['field']]
            result.append({'metric_id': metric_id, 'ticker': ticker,
                'security_id': identity['security_id'], 'company_id': identity['company_id'],
                'value': value * metric['scale'] if value is not None else None,
                'unit': metric['unit'], 'currency': 'USD' if metric['unit'] == 'USD' else None,
                'date': row['date'], 'period_end': row.get('reportperiod', row['date']),
                'available_at': None if table == 'holdings_ticker' else row.get('available_at', row['date']),
                'dimension': row.get('dimension'), 'pit_supported': table != 'holdings_ticker' and not str(row.get('dimension', '')).startswith('MR'),
                'provenance': row.get('provenance') or self._lineage(table, row)})
            if metric['unit'] == 'reporting_currency':
                # SF1 facts have native amounts but no row-level currency code.
                # Today's TICKERS currency is not historical currency evidence.
                result[-1].update({'currency_basis': 'historical_reporting_currency_unavailable',
                    'currency_pit_supported': False, 'currency_provenance': []})
        return result

    def _current_reporting_currency(self, ticker):
        identity = self.resolve_security(ticker)
        # TICKERS.currency is table-specific: SEP/SFP describe the quote currency,
        # whereas only SF1 identifies the company's reporting currency. Match
        # the exact security ID, never a similar name, related ticker or issuer.
        rows = self._rows('SELECT * FROM _master WHERE "table"=\'SF1\' AND permaticker=?',
                          [identity['permaticker']])
        currencies = {str(row.get('currency') or '').strip().upper() for row in rows}
        valid = bool(rows) and all(re.fullmatch(r'[A-Z]{3}', value) for value in currencies)
        currency = next(iter(currencies)) if valid and len(currencies) == 1 else None
        basis = ('current_sf1_master_not_historical' if currency is not None else
                 'current_sf1_master_currency_ambiguous' if valid else
                 'current_sf1_master_currency_unavailable')
        return {'currency': currency, 'currency_basis': basis, 'currency_pit_supported': False,
                'currency_provenance': [self._lineage('tickers', row) for row in rows]}

    def get_metric(self, ticker, metric_id, **kwargs):
        rows = self.get_metric_history(ticker, metric_id, **kwargs)
        # A late amendment of an old period cannot displace newer fiscal data.
        latest = max(rows, key=lambda row: (row['period_end'], row['date'])) if rows else None
        if latest and latest['unit'] == 'reporting_currency' and kwargs.get('as_of') is None:
            latest.update(self._current_reporting_currency(ticker))
        return latest
