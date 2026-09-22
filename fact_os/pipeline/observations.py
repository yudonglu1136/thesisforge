"""Canonical quote/annual-quality projection; no model or private DB writes."""
from datetime import timedelta
from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3
from ..repository import FactRepository
from ..store import checksum
from .contracts import digest
from .registry import PROJECT


def quality_logic():
    spec=importlib.util.spec_from_file_location('canonical_annual_quality',PROJECT/'scripts/import-investment-quality.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def build_observations(source,destination,generation):
    """Project exact canonical symbols. Audited application aliases stay in the
    existing model/source mapping and are applied only by the consumer.
    """
    destination=Path(destination);destination.parent.mkdir(parents=True,exist_ok=True)
    temporary=destination.with_suffix('.building.sqlite')
    if temporary.exists():temporary.unlink()  # only this unfinished derived candidate
    quality=quality_logic()
    with FactRepository(source) as repo,closing(sqlite3.connect(temporary)) as output:
        output.executescript('''CREATE TABLE investment_current_quotes(
          ticker TEXT,source_ticker TEXT,price_date TEXT,close REAL CHECK(close>0),source TEXT,
          observed_at TEXT,imported_at TEXT,source_generation TEXT,source_hash TEXT,
          PRIMARY KEY(ticker,price_date,source_hash));
          CREATE INDEX quote_latest ON investment_current_quotes(ticker,price_date DESC);
          CREATE TABLE investment_quality_annual(
          ticker TEXT,source_ticker TEXT,fiscal_year INTEGER,report_period TEXT,available_at TEXT,
          dimension TEXT CHECK(dimension='ART'),roic REAL,operating_margin REAL,fcf_margin REAL,cash_conversion REAL,
          raw_roic REAL,ebit REAL,invested_capital_avg REAL,revenue REAL,operating_income REAL,cfo REAL,capex REAL,
          net_income REAL,issues_json TEXT,source_hash TEXT,
          PRIMARY KEY(ticker,report_period,available_at,source_hash));
          CREATE INDEX quality_pit ON investment_quality_annual(ticker,available_at,report_period);
          CREATE TABLE projection_metadata(key TEXT PRIMARY KEY,value TEXT);''')
        # Keep identity ambiguity explicit: do not guess a reused symbol or
        # replace the existing canonical security master with a parallel list.
        repo.db.execute('''CREATE TEMP VIEW mapped_symbols AS
            SELECT ticker FROM tickers WHERE "table" IN ('SEP','SF1','stocks','fundamentals')
            GROUP BY ticker HAVING count(DISTINCT permaticker)=1''')
        maximum=repo.db.execute('SELECT max(date) FROM stocks').fetchone()[0]
        if maximum is None:raise ValueError('canonical_quote_source_empty')
        minimum=maximum-timedelta(days=45)
        cursor=repo.db.execute('''SELECT s.ticker,s.date,s.close,s.lastupdated,s._observed_at
            FROM stocks s JOIN mapped_symbols m USING(ticker)
            WHERE s.date>=? AND s.close>0 AND isfinite(s.close)
            ORDER BY s.ticker,s.date''',[minimum])
        price_count=0
        while rows:=cursor.fetchmany(5000):
            records=[]
            for ticker,day,close,updated,ingested in rows:
                source_hash=digest({'ticker':ticker,'date':day,'close':close,'lastupdated':updated})
                # Preserve canonical observation time; a new projection is
                # not a new economic observation or artificial fresh price.
                records.append((ticker,ticker,str(day),close,'Sharadar SEP via ThesisForge Fact OS',
                                str(ingested),str(ingested),generation,source_hash))
            output.executemany('INSERT INTO investment_current_quotes VALUES(?,?,?,?,?,?,?,?,?)',records)
            price_count+=len(records)
        columns=','.join('f.'+name for name in quality.COLUMNS)
        cursor=repo.db.execute(f'''SELECT {columns} FROM fundamentals f
            JOIN mapped_symbols m USING(ticker) WHERE f.dimension='ART'
            AND f.fiscalperiod LIKE '%-Q4' ORDER BY f.ticker,f.reportperiod,f.date''')
        raw=[dict(zip(quality.COLUMNS,row)) for row in cursor.fetchall()]
        records=[result for row in quality.first_reports(raw)
                 if (result:=quality.observation(row,row['ticker'])) is not None]
        if not records or not price_count:raise ValueError('public_observation_projection_empty')
        output.executemany('INSERT INTO investment_quality_annual VALUES('+','.join('?'*20)+')',records)
        metadata={'schemaVersion':'canonical-public-observations-v1','generationId':generation,
            'priceRows':price_count,'qualityRows':len(records),'priceStart':str(minimum),'priceEnd':str(maximum),
            'qualityMethod':'annual-quality-v1','identityPolicy':'exact_unambiguous_canonical_symbol',
            'historicalQuotes':'45-day current-quote projection; full history remains in canonical Fact OS',
            'observationTime':'canonical ingestion timestamp; never projection build time'}
        output.executemany('INSERT INTO projection_metadata VALUES(?,?)',[(k,json.dumps(v)) for k,v in metadata.items()])
        output.commit()
        if output.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise ValueError('projection_integrity_failed')
    if destination.exists():
        if checksum(destination)!=checksum(temporary):raise ValueError('immutable_observation_projection_conflict')
        temporary.unlink()
    else:temporary.replace(destination)
    return metadata
