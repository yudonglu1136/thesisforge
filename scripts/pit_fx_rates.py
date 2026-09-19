#!/usr/bin/env python3
"""Point-in-time ECB reference FX rates for valuation source construction."""

from __future__ import annotations

import bisect
import csv
import datetime as dt
import io
import json
import math
import os
import time
from pathlib import Path

import requests


ECB_BASE = "https://data-api.ecb.europa.eu/service/data/EXR"
IMPORT_VERSION = "ecb-reference-fx-v2-2026-08-29"
MAX_RATE_AGE_DAYS = 10
DEFAULT_CACHE_PATH = Path(
    os.environ.get(
        "PIT_FX_CACHE_PATH",
        Path.home() / ".cache/guru-intelligence/ecb-reference-fx.json",
    )
)
USER_AGENT = "Guru Intelligence data engineering luyudong1136@gmail.com"


def iso_date(value) -> str:
    if isinstance(value, (dt.date, dt.datetime)):
        return value.date().isoformat() if isinstance(value, dt.datetime) else value.isoformat()
    return str(value or "")[:10]


def ecb_url(currency: str, start: str, end: str) -> str:
    return (
        f"{ECB_BASE}/D.{currency.upper()}.EUR.SP00.A"
        f"?startPeriod={start}&endPeriod={end}&format=csvdata"
    )


def parse_currency_csv(text: str, currency: str, start: str, end: str, url: str) -> list[dict]:
    """A successful HTTP response is not proof of series, units or timeliness."""
    expected_key = f"EXR.D.{currency}.EUR.SP00.A"
    rows = {}
    for row in csv.DictReader(io.StringIO(text)):
        if not row.get("TIME_PERIOD") or not row.get("OBS_VALUE"):
            continue
        if (row.get("KEY") != expected_key or row.get("CURRENCY") != currency
                or row.get("CURRENCY_DENOM") != "EUR" or row.get("FREQ") != "D"
                or row.get("UNIT") != currency or row.get("UNIT_MULT") != "0"):
            raise ValueError(f"Unexpected ECB series or units for {currency}/EUR")
        date = dt.date.fromisoformat(row["TIME_PERIOD"]).isoformat()
        if not start <= date <= end:
            raise ValueError(f"ECB observation outside requested dates: {date}")
        value = float(row["OBS_VALUE"])
        if not math.isfinite(value) or value <= 0:
            raise ValueError(f"Invalid ECB observation for {currency}: {value}")
        if date in rows and rows[date]["units_per_eur"] != value:
            raise ValueError(f"Conflicting ECB observations for {currency} on {date}")
        rows[date] = {"currency": currency, "rate_date": date, "units_per_eur": value,
                      "source_url": url, "extraction_version": IMPORT_VERSION}
    return sorted(rows.values(), key=lambda row: row["rate_date"])


def fetch_currency(currency: str, start: str, end: str) -> list[dict]:
    currency = currency.upper()
    url = ecb_url(currency, start, end)
    last_error = None
    for attempt in range(4):
        try:
            response = requests.get(
                url,
                headers={"User-Agent": USER_AGENT, "Accept": "text/csv,*/*"},
                timeout=90,
            )
            response.raise_for_status()
            rows = parse_currency_csv(response.text, currency, start, end, url)
            if not rows:
                raise RuntimeError(
                    f"ECB returned no {currency}/EUR rates for {start} through {end}"
                )
            return rows
        except Exception as error:  # requests raises several transport/status subclasses
            last_error = error
            if attempt < 3:
                time.sleep(1.0 * (2**attempt))
    raise RuntimeError(f"ECB {currency}/EUR request failed: {last_error}")


def read_cache(path: Path | None) -> list[dict]:
    if not path or not path.exists():
        return []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    rows = payload.get("rates", []) if isinstance(payload, dict) else []
    return [
        row
        for row in rows
        if row.get("currency") and row.get("rate_date") and row.get("units_per_eur")
    ]


def write_cache(path: Path | None, rows: list[dict]) -> None:
    if not path:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": IMPORT_VERSION,
        "source": "European Central Bank Data API daily reference rates",
        "rates": sorted(
            rows, key=lambda row: (str(row["currency"]), str(row["rate_date"]))
        ),
    }
    path.write_text(f"{json.dumps(payload, separators=(',', ':'))}\n", encoding="utf-8")


class FxRateBook:
    def __init__(self, rows: list[dict]):
        self.rows = sorted(
            [
                {
                    "currency": str(row["currency"]).upper(),
                    "rate_date": iso_date(row["rate_date"]),
                    "units_per_eur": float(row["units_per_eur"]),
                    "source_url": str(row.get("source_url") or ""),
                    "extraction_version": str(
                        row.get("extraction_version") or IMPORT_VERSION
                    ),
                }
                for row in rows
            ],
            key=lambda row: (row["currency"], row["rate_date"]),
        )
        self._by_currency: dict[str, list[dict]] = {}
        self._dates: dict[str, list[str]] = {}
        for row in self.rows:
            if not math.isfinite(row["units_per_eur"]) or row["units_per_eur"] <= 0:
                raise ValueError("Nonfinite or nonpositive FX observation")
            dt.date.fromisoformat(row["rate_date"])
            self._by_currency.setdefault(row["currency"], []).append(row)
        for currency, currency_rows in self._by_currency.items():
            self._dates[currency] = [row["rate_date"] for row in currency_rows]

    def rate_at_or_before(self, currency: str, as_of) -> dict | None:
        currency = currency.upper()
        date_text = iso_date(as_of)
        if currency == "EUR":
            return {
                "currency": "EUR",
                "rate_date": date_text,
                "units_per_eur": 1.0,
                "source_url": "ECB EUR reference base",
                "extraction_version": IMPORT_VERSION,
            }
        dates = self._dates.get(currency, [])
        index = bisect.bisect_right(dates, date_text) - 1
        return self._by_currency[currency][index] if index >= 0 else None

    def conversion(self, source_currency: str, target_currency: str, as_of) -> dict:
        source_currency = source_currency.upper()
        target_currency = target_currency.upper()
        source = self.rate_at_or_before(source_currency, as_of)
        target = self.rate_at_or_before(target_currency, as_of)
        if not source or not target:
            raise RuntimeError(
                f"Missing ECB PIT FX rate for {source_currency}->{target_currency} at {iso_date(as_of)}"
            )
        for row in (source, target):
            age = (dt.date.fromisoformat(iso_date(as_of)) - dt.date.fromisoformat(row["rate_date"])).days
            if not 0 <= age <= MAX_RATE_AGE_DAYS:
                raise RuntimeError(f"Stale ECB PIT FX rate for {row['currency']} at {iso_date(as_of)}: {age} days old")
        conversion_rate = target["units_per_eur"] / source["units_per_eur"]
        if not math.isfinite(conversion_rate) or not conversion_rate > 0:
            raise RuntimeError(
                f"Invalid ECB PIT FX rate for {source_currency}->{target_currency} at {iso_date(as_of)}"
            )
        return {
            "sourceCurrency": source_currency,
            "targetCurrency": target_currency,
            "conversionRate": conversion_rate,
            "formula": "target units per EUR / source units per EUR",
            "sourceRateDate": source["rate_date"],
            "targetRateDate": target["rate_date"],
            "sourceUnitsPerEur": source["units_per_eur"],
            "targetUnitsPerEur": target["units_per_eur"],
            "sourceUrl": target["source_url"] or source["source_url"],
            "extractionVersion": IMPORT_VERSION,
        }

    @classmethod
    def from_connection(cls, connection) -> "FxRateBook":
        present = connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pit_fx_reference_rates'"
        ).fetchone()
        if not present:
            return cls([])
        columns = {
            row[1]
            for row in connection.execute("PRAGMA table_info(pit_fx_reference_rates)")
        }
        version_expression = (
            "extraction_version"
            if "extraction_version" in columns
            else f"'{IMPORT_VERSION}'"
        )
        rows = [
            dict(zip(
                (
                    "currency",
                    "rate_date",
                    "units_per_eur",
                    "source_url",
                    "extraction_version",
                ),
                row,
            ))
            for row in connection.execute(
                "SELECT currency,rate_date,units_per_eur,source_url,"
                f"{version_expression} FROM pit_fx_reference_rates"
            )
        ]
        return cls(rows)


def rate_book_for_range(
    start,
    end,
    currencies=("USD", "GBP"),
    cache_path: Path | None = DEFAULT_CACHE_PATH,
) -> FxRateBook:
    start_date = dt.date.fromisoformat(iso_date(start))
    end_date = dt.date.fromisoformat(iso_date(end))
    request_start = (start_date - dt.timedelta(days=10)).isoformat()
    request_end = end_date.isoformat()
    currencies = tuple(sorted({str(currency).upper() for currency in currencies} - {"EUR"}))
    cached_rows = read_cache(cache_path)
    cached_book = FxRateBook(cached_rows)

    def cache_covers(currency: str) -> bool:
        first = cached_book.rate_at_or_before(currency, start_date)
        last = cached_book.rate_at_or_before(currency, end_date)
        if not first or not last:
            return False
        return all(0 <= (date - dt.date.fromisoformat(row["rate_date"])).days <= MAX_RATE_AGE_DAYS
                   for date, row in ((start_date, first), (end_date, last)))

    merged = {
        (row["currency"], row["rate_date"]): row
        for row in cached_rows
    }
    for currency in currencies:
        if cache_covers(currency):
            continue
        for row in fetch_currency(currency, request_start, request_end):
            merged[(row["currency"], row["rate_date"])] = row
    rows = list(merged.values())
    write_cache(cache_path, rows)
    book = FxRateBook(rows)
    for currency in currencies:
        for date in (start_date, end_date):
            row = book.rate_at_or_before(currency, date)
            if not row:
                raise RuntimeError(f"ECB cache does not cover {currency}/EUR for {start_date} through {end_date}")
            age = (date - dt.date.fromisoformat(row["rate_date"])).days
            if age > MAX_RATE_AGE_DAYS:
                raise RuntimeError(f"Stale ECB PIT FX coverage for {currency}/EUR at {date}: {age} days old")
    return book


def replace_sqlite_rates(connection, rate_book: FxRateBook, imported_at: str) -> int:
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS pit_fx_reference_rates (
          currency TEXT NOT NULL,
          rate_date TEXT NOT NULL,
          units_per_eur REAL NOT NULL,
          source_url TEXT NOT NULL,
          extraction_version TEXT NOT NULL,
          imported_at TEXT NOT NULL,
          PRIMARY KEY (currency, rate_date)
        );
        DELETE FROM pit_fx_reference_rates;
        """
    )
    rows = [
        (
            row["currency"],
            row["rate_date"],
            row["units_per_eur"],
            row["source_url"],
            row["extraction_version"],
            imported_at,
        )
        for row in rate_book.rows
    ]
    connection.executemany(
        "INSERT INTO pit_fx_reference_rates VALUES (?,?,?,?,?,?)", rows
    )
    return len(rows)
