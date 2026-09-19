"""Contracts are parsed from captured official DDL, never inferred from sample rows."""
from dataclasses import dataclass
import hashlib
import re
import sqlite3

TABLES = ('tickers', 'stocks', 'funds', 'fundamentals', 'daily', 'actions',
          'holdings', 'holdings_ticker', 'holdings_investor', 'events', 'insiders',
          'descriptions', 'metrics', 'sp500')
REQUIRED = frozenset(TABLES[:9])
DATE_FIELDS = frozenset(('date', 'calendardate', 'reportperiod', 'lastupdated',
    'firstadded', 'firstpricedate', 'lastpricedate', 'firstquarter', 'lastquarter',
    'transactiondate', 'dateexercisable', 'expirationdate'))

def ident(value):
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', value):
        raise ValueError('invalid SQL identifier')
    return '"' + value + '"'

@dataclass(frozen=True)
class Contract:
    table: str
    columns: tuple
    keys: tuple
    digest: str

    @classmethod
    def from_ddl(cls, table, ddl):
        if table not in TABLES:
            raise ValueError('unsupported dataset')
        # Do not execute arbitrary upstream SQL. Extract only its declared table
        # and UNIQUE index declarations, and evaluate those in an in-memory DB.
        match = re.search(r'CREATE TABLE IF NOT EXISTS "' + table + r'"\s*\([\s\S]*?\);', ddl)
        if not match:
            raise ValueError('official CREATE TABLE missing')
        sql = match.group()
        if not re.fullmatch(r'[\w\s"(),;]+', sql):
            raise ValueError('unexpected schema grammar')
        db = sqlite3.connect(':memory:')
        try:
            db.execute(sql)
            rows = db.execute(f'PRAGMA table_info({ident(table)})').fetchall()
            keys = tuple(r[1] for r in sorted(rows, key=lambda r:r[5]) if r[5])
            if not keys:
                unique = re.search(r'CREATE UNIQUE INDEX IF NOT EXISTS "\w+" ON "' + table + r'" \(([^)]+)\)', ddl)
                if unique:
                    keys = tuple(re.findall(r'"([a-z_]+)"', unique[1]))
            columns = tuple((r[1], 'DATE' if r[1] in DATE_FIELDS else
                {'INTEGER':'BIGINT','REAL':'DOUBLE','TEXT':'VARCHAR'}[r[2]]) for r in rows)
            if not keys or not set(keys).issubset(dict(columns)):
                raise ValueError('no verified natural key')
            return cls(table, columns, keys, hashlib.sha256(ddl.encode()).hexdigest())
        finally:
            db.close()
