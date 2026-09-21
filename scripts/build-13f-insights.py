#!/usr/bin/env python3
"""Build compact, append-only 13F Insights snapshots from the local Fact OS.

The source-of-truth SF3 Parquet archive remains outside the runtime database.
Each snapshot ranks the complete institutional universe while retaining only a
bounded set of the largest filer examples per security/action for UI detail.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import sqlite3
import gzip
from pathlib import Path

import duckdb


METHOD_VERSION = "institutional-13f-insights-v4"
DETAIL_SECURITY_LIMIT = 750
DETAIL_PER_ACTION = 50


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fact-os", default="data/fact_os/fact_os.duckdb")
    parser.add_argument("--database", default="server/data/guru-analysis.sqlite")
    parser.add_argument("--quarters", type=int, default=20)
    parser.add_argument("--detail-quarters", type=int, default=8)
    return parser.parse_args()


def compact_hash(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), default=str).encode()
    return hashlib.sha256(encoded).hexdigest()


def available_at(report_date: str) -> str:
    # SF3 is quarter-end data and does not retain each source filing timestamp.
    # The 45-day deadline is therefore used as a conservative shared cutoff.
    return (dt.date.fromisoformat(report_date) + dt.timedelta(days=45)).isoformat()


def action_cte(current: str, previous: str) -> str:
    return f"""
      WITH splits AS (
        SELECT ticker, product(value) AS factor
        FROM actions
        WHERE action='split' AND date>'{previous}' AND date<='{current}'
          AND value IS NOT NULL AND value>0
        GROUP BY ticker
      ),
      current_book AS (
        SELECT investorid,ticker,sum(units) AS units,sum(value) AS holding_value
        FROM holdings
        WHERE securitytype='SHR' AND date='{current}'
        GROUP BY investorid,ticker
      ),
      previous_book AS (
        SELECT investorid,ticker,sum(units) AS units,sum(value) AS holding_value
        FROM holdings
        WHERE securitytype='SHR' AND date='{previous}'
        GROUP BY investorid,ticker
      ),
      current_investor AS (
        SELECT investorid,investorname,shrholdings,shrvalue
        FROM holdings_investor WHERE date='{current}'
      ),
      previous_investor AS (
        SELECT investorid,investorname,shrholdings,shrvalue
        FROM holdings_investor WHERE date='{previous}'
      ),
      joined AS (
        SELECT coalesce(c.investorid,p.investorid) investorid,
          coalesce(c.ticker,p.ticker) ticker,
          c.units current_units,p.units previous_units,
          p.units*coalesce(s.factor,1) adjusted_previous_units,
          c.holding_value current_value,p.holding_value previous_value,
          ci.investorname current_investor_name,
          pi.investorname previous_investor_name,
          ci.shrvalue current_book_value,pi.shrvalue previous_book_value,
          CASE
            WHEN ci.investorid IS NULL OR pi.investorid IS NULL THEN 'not_comparable'
            WHEN p.units IS NULL AND c.units>0 THEN 'new'
            WHEN c.units IS NULL AND p.units>0 THEN 'exited'
            WHEN c.units>p.units*coalesce(s.factor,1)*1.001 THEN 'increased'
            WHEN c.units<p.units*coalesce(s.factor,1)*0.999 THEN 'reduced'
            ELSE 'unchanged'
          END AS reported_action,
          coalesce(s.factor,1) split_factor
        FROM current_book c FULL OUTER JOIN previous_book p USING(investorid,ticker)
        LEFT JOIN splits s ON s.ticker=coalesce(c.ticker,p.ticker)
        LEFT JOIN current_investor ci ON ci.investorid=coalesce(c.investorid,p.investorid)
        LEFT JOIN previous_investor pi ON pi.investorid=coalesce(c.investorid,p.investorid)
      )
    """


def aggregate_market(rows: list[dict], segment: str) -> dict:
    selected = [row for row in rows if segment in row["segments"]]
    covered = [
        row for row in selected
        if row.get("marketCapM") and row.get("currentValueM") is not None
    ]
    market_cap = sum(row["marketCapM"] for row in covered)
    institutional_value = sum(row["currentValueM"] for row in covered)
    net_value = sum(row.get("netChangeValueM") or 0 for row in covered)
    return {
        "securities": len(selected),
        "coveredSecurities": len(covered),
        "institutionalValueM": institutional_value,
        "marketCapM": market_cap,
        "institutionalOwnershipPct": None if not market_cap else institutional_value / market_cap * 100,
        "netChangeValueM": net_value,
        "netChangePctMarketCap": None if not market_cap else net_value / market_cap * 100,
    }


def snapshot(
    con: duckdb.DuckDBPyConnection,
    current: str,
    previous: str,
    share_basis_date: str,
    observed_at: str,
    include_details: bool,
) -> tuple[dict, dict]:
    cte = action_cte(current, previous)
    coverage = con.execute(
        f"""{cte}
        SELECT
          (SELECT count(*) FROM holdings_investor WHERE date='{current}') current_filers,
          (SELECT count(*) FROM holdings_investor WHERE date='{previous}') previous_filers,
          count(DISTINCT ticker) securities,
          count(*) FILTER(WHERE reported_action<>'not_comparable') comparable_positions,
          count(*) FILTER(WHERE reported_action='new') new_positions,
          count(*) FILTER(WHERE reported_action='increased') increases,
          count(*) FILTER(WHERE reported_action='reduced') reductions,
          count(*) FILTER(WHERE reported_action='exited') exits,
          count(DISTINCT ticker) FILTER(WHERE split_factor<>1) split_adjusted_securities
        FROM joined"""
    ).fetchone()
    coverage_keys = [
        "currentFilers", "previousFilers", "securities", "comparablePositions",
        "newPositions", "increases", "reductions", "exits", "splitAdjustedSecurities",
    ]
    security_rows = con.execute(
        f"""{cte}, names AS (
          SELECT ticker,name FROM holdings_ticker WHERE date='{current}'
        ), share_counts AS (
          SELECT ticker,sharesbas*sharefactor/1000.0 AS shares_outstanding_k
          FROM fundamentals
          WHERE dimension='ARQ' AND sharesbas>0 AND sharefactor>0
            AND date<='{available_at(current)}' AND reportperiod<='{current}'
          QUALIFY row_number() OVER(
            PARTITION BY ticker ORDER BY reportperiod DESC,date ASC,lastupdated DESC
          )=1
        ), market_caps AS (
          SELECT ticker,marketcap AS market_cap_m
          FROM daily
          WHERE date<='{current}' AND date>='{(dt.date.fromisoformat(current) - dt.timedelta(days=7)).isoformat()}'
            AND marketcap>0
          QUALIFY row_number() OVER(PARTITION BY ticker ORDER BY date DESC)=1
        ), share_basis_splits AS (
          SELECT ticker,product(value) AS factor
          FROM actions
          WHERE action='split' AND date>'{current}' AND date<='{share_basis_date}'
            AND value IS NOT NULL AND value>0
          GROUP BY ticker
        ), listing AS (
          SELECT ticker,exchange,sector,scalemarketcap
          FROM tickers WHERE "table"='SF1'
          QUALIFY row_number() OVER(PARTITION BY ticker ORDER BY lastupdated DESC)=1
        ), nasdaq_rank AS (
          SELECT l.ticker,row_number() OVER(ORDER BY m.market_cap_m DESC,l.ticker) AS rank
          FROM listing l JOIN market_caps m USING(ticker)
          WHERE l.exchange='NASDAQ' AND coalesce(l.sector,'')<>'Financial Services'
        ), sp500_members AS (
          SELECT ticker FROM sp500 WHERE date='{current}' AND action='historical'
        )
        SELECT j.ticker,max(n.name) AS issuer_name,
          count(*) FILTER(WHERE current_units>0) AS holders,
          count(*) FILTER(WHERE reported_action='new') AS new_positions,
          count(*) FILTER(WHERE reported_action='increased') AS increases,
          count(*) FILTER(WHERE reported_action='reduced') AS reductions,
          count(*) FILTER(WHERE reported_action='exited') AS exits,
          sum(current_value) AS total_current_value,
          sum(previous_value) AS total_previous_value,
          sum(current_units) AS total_current_units,
          sum(adjusted_previous_units) AS total_previous_units,
          sum(current_units) FILTER(WHERE reported_action<>'not_comparable') AS comparable_current_units,
          sum(adjusted_previous_units) FILTER(WHERE reported_action<>'not_comparable') AS comparable_previous_units,
          count(*) FILTER(WHERE split_factor<>1) AS split_adjusted,
          max(s.shares_outstanding_k) AS shares_outstanding_k,
          max(m.market_cap_m) AS market_cap_m,
          bool_or(sp.ticker IS NOT NULL) AS is_sp500,
          bool_or(nq.rank<=100) AS is_nasdaq_100_proxy,
          bool_or(l.scalemarketcap='3 - Small') AS is_small_cap,
          max(coalesce(bs.factor,1)) AS share_basis_factor
        FROM joined j LEFT JOIN names n USING(ticker)
        LEFT JOIN share_counts s USING(ticker)
        LEFT JOIN market_caps m USING(ticker)
        LEFT JOIN share_basis_splits bs USING(ticker)
        LEFT JOIN listing l USING(ticker)
        LEFT JOIN nasdaq_rank nq USING(ticker)
        LEFT JOIN sp500_members sp USING(ticker)
        GROUP BY j.ticker"""
    ).fetchall()
    securities = []
    for row in security_rows:
        share_basis_factor = row[19] or 1
        raw_current_units_k = row[9]
        current_units_k = None if raw_current_units_k is None else raw_current_units_k * share_basis_factor
        previous_units_k = None if row[10] is None else row[10] * share_basis_factor
        comparable_current_units_k = None if row[11] is None else row[11] * share_basis_factor
        comparable_previous_units_k = None if row[12] is None else row[12] * share_basis_factor
        shares_outstanding_k = row[14]
        institutional_ownership_pct = (
            None if not shares_outstanding_k or current_units_k is None
            else current_units_k / shares_outstanding_k * 100
        )
        net_units_k = (comparable_current_units_k or 0) - (comparable_previous_units_k or 0)
        implied_price = None if not current_units_k else row[7] * 1000 / current_units_k
        net_change_value_m = None if implied_price is None else net_units_k * implied_price / 1000
        net_change_pct_outstanding = (
            None if not shares_outstanding_k else net_units_k / shares_outstanding_k * 100
        )
        segments = ["all"]
        if row[16]:
            segments.append("sp500")
        if row[17]:
            segments.append("nasdaq100Proxy")
        if row[18]:
            segments.append("smallCap")
        securities.append({
            "ticker": row[0], "name": None if row[1] in (None, "None") else row[1],
            "holders": row[2], "newPositions": row[3], "increases": row[4],
            "reductions": row[5], "exits": row[6], "currentValueM": row[7],
            "previousValueM": row[8], "currentUnitsK": current_units_k,
            "rawCurrentUnitsK": raw_current_units_k,
            "previousUnitsK": previous_units_k, "splitAdjustedFilers": row[13],
            "shareBasisFactor": share_basis_factor,
            "shareBasisDate": share_basis_date,
            "sharesOutstandingK": shares_outstanding_k,
            "marketCapM": row[15],
            "institutionalOwnershipPct": institutional_ownership_pct,
            "netUnitsChangeK": net_units_k,
            "netChangeValueM": net_change_value_m,
            "netChangePctOutstanding": net_change_pct_outstanding,
            "segments": segments,
            "adds": row[3] + row[4], "trims": row[5] + row[6],
            "netFilers": row[3] + row[4] - row[5] - row[6],
        })
    securities.sort(key=lambda row: (-row["holders"], row["ticker"]))
    priority = set()
    for key in ("newPositions", "increases", "reductions", "exits"):
        priority.update(row["ticker"] for row in sorted(securities, key=lambda x: (-x[key], x["ticker"]))[:DETAIL_SECURITY_LIMIT])

    institution_rows = con.execute(
        f"""{cte}
        SELECT investorid,coalesce(max(current_investor_name),max(previous_investor_name)) AS investor_name,
          count(*) FILTER(WHERE current_units>0) AS holding_count,
          count(*) FILTER(WHERE reported_action='new') AS new_positions,
          count(*) FILTER(WHERE reported_action='increased') AS increases,
          count(*) FILTER(WHERE reported_action='reduced') AS reductions,
          count(*) FILTER(WHERE reported_action='exited') AS exits,
          max(current_book_value) AS total_current_value,
          max(previous_book_value) AS total_previous_value
        FROM joined GROUP BY investorid"""
    ).fetchall()
    institutions = [{
        "investorId": row[0], "name": row[1] or row[0], "holdings": row[2],
        "newPositions": row[3], "increases": row[4], "reductions": row[5],
        "exits": row[6], "currentValueM": row[7], "previousValueM": row[8],
        "adds": row[3] + row[4], "trims": row[5] + row[6],
    } for row in institution_rows]
    institutions.sort(key=lambda row: (-(row["adds"] + row["trims"]), row["name"]))

    details = {}
    if include_details and priority:
        values = ",".join("?" for _ in priority)
        detail_rows = con.execute(
            f"""{cte}, ranked AS (
              SELECT *,row_number() OVER(
                PARTITION BY ticker,reported_action
                ORDER BY greatest(coalesce(current_value,0),coalesce(previous_value,0)) DESC,investorid
              ) detail_rank
              FROM joined WHERE reported_action IN ('new','increased','reduced','exited') AND ticker IN ({values})
            )
            SELECT ticker,reported_action,investorid,coalesce(current_investor_name,previous_investor_name),
              current_units,adjusted_previous_units,current_value,previous_value,
              current_value/nullif(current_book_value,0),previous_value/nullif(previous_book_value,0),split_factor
            FROM ranked WHERE detail_rank<=? ORDER BY ticker,reported_action,detail_rank""",
            [*sorted(priority), DETAIL_PER_ACTION],
        ).fetchall()
        for row in detail_rows:
            action = row[1]
            current_value = row[6]
            previous_value = row[7]
            activity_value = previous_value if action == "exited" else current_value
            if current_value is not None and previous_value is not None:
                reported_value_change = current_value - previous_value
            elif action == "new":
                reported_value_change = current_value
            elif action == "exited" and previous_value is not None:
                reported_value_change = -previous_value
            else:
                reported_value_change = None
            details.setdefault(row[0], {}).setdefault(row[1], []).append({
                "investorId": row[2], "name": row[3] or row[2],
                "currentUnitsK": row[4], "previousUnitsK": row[5],
                "currentValueM": current_value, "previousValueM": previous_value,
                "currentWeight": row[8], "previousWeight": row[9],
                "activityValueM": activity_value,
                "reportedValueChangeM": reported_value_change,
                "changePct": (
                    None if action not in ("increased", "reduced") or not row[5]
                    else (row[4] or 0) / row[5] - 1
                ),
                "comparisonBasis": (
                    "prior_reported_position_value" if action == "exited"
                    else "current_reported_position_value" if action == "new"
                    else "split_adjusted_reported_units"
                ),
                "splitAdjusted": row[10] != 1,
            })

    market_overview = {
        segment: aggregate_market(securities, segment)
        for segment in ("all", "sp500", "nasdaq100Proxy", "smallCap")
    }
    summary = {
        "version": METHOD_VERSION,
        "reportDate": current,
        "previousReportDate": previous,
        "shareBasisDate": share_basis_date,
        "availableAt": available_at(current),
        "sourceObservedAt": observed_at,
        "coverage": dict(zip(coverage_keys, coverage)),
        "activity": {
            "newPositions": coverage[4], "increases": coverage[5],
            "reductions": coverage[6], "exits": coverage[7],
        },
        "rows": securities,
        "institutions": institutions,
        "marketOverview": market_overview,
        "marketSegments": [
            {"id": "all", "label": "All covered US equities", "basis": "All covered common-stock securities with a quarter-end market capitalization"},
            {"id": "sp500", "label": "S&P 500 (SPY universe)", "basis": "Sharadar point-in-time S&P 500 constituent snapshot"},
            {"id": "nasdaq100Proxy", "label": "Nasdaq-100 proxy", "basis": "Largest 100 non-financial Nasdaq listings by quarter-end market capitalization; proxy, not official QQQ holdings"},
            {"id": "smallCap", "label": "US small cap", "basis": "Sharadar small-cap scale classification"},
        ],
        "methodology": {
            "universe": "All Sharadar SF3 institutional SHR positions in the selected report quarter",
            "classification": "Quarter-over-quarter reported units, adjusted for split actions between quarter ends",
            "availability": "Quarter-end aggregate; shared availability uses the 45-day 13F deadline because SF3 does not retain each filing timestamp",
            "units": "reported holdings and shares outstanding are thousands; historical reported units are normalized to the latest included quarter's share basis using exact Sharadar split actions; values are USD millions; ownership and net-change ratios are percentages",
            "shareBasis": f"Historical 13F units are multiplied by exact Sharadar split actions after each report date through {share_basis_date}; this changes only the unit of account and does not create an increase or reduction",
            "ownership": "Split-normalized aggregate reported institutional units divided by the latest ARQ basic shares multiplied by the provider share factor; Sharadar does not provide a reliable free-float field, so the denominator is shares outstanding and unavailable denominators remain null",
            "marketOverview": "Aggregate reported common-stock value divided by the sum of unique covered securities' quarter-end Sharadar market capitalizations; it is a coverage-weighted ownership gauge, not total fund AUM or a free-float measure",
            "netChange": "Split-adjusted net reported share change valued at the current quarter's aggregate implied price; netChangePctOutstanding uses total shares outstanding, not free float",
            "detailPolicy": f"Largest {DETAIL_PER_ACTION} reporting institutions per action for leading securities; counts use the full universe",
        },
    }
    return summary, details


def main() -> int:
    args = arguments()
    fact_path = Path(args.fact_os).resolve()
    database_path = Path(args.database).resolve()
    catalog_path = fact_path.parent / "manifests" / "catalog.json"
    catalog = json.loads(catalog_path.read_text())
    source = {
        key: {
            "partitions": catalog["datasets"][key]["partitions"],
            "state": catalog["datasets"][key]["state"],
        }
        for key in (
            "holdings", "holdings_ticker", "holdings_investor", "actions",
            "fundamentals", "daily", "tickers", "sp500",
        )
    }
    observed_at = max(
        catalog["datasets"][key]["state"]["last_success"]
        for key in (
            "holdings", "holdings_ticker", "holdings_investor", "actions",
            "fundamentals", "daily", "tickers", "sp500",
        )
    )
    duck = duckdb.connect(str(fact_path), read_only=True)
    dates = [str(row[0]) for row in duck.execute(
        "SELECT DISTINCT date FROM holdings WHERE securitytype='SHR' ORDER BY date DESC"
    ).fetchall()]
    selected = dates[: max(1, args.quarters) + 1]
    if len(selected) < 2:
        raise RuntimeError("insufficient_holdings_quarters")
    latest_effective_split = duck.execute(
        "SELECT max(date) FROM actions WHERE action='split' AND date<=?",
        [dt.date.today()],
    ).fetchone()[0]
    share_basis_date = str(latest_effective_split or selected[0])
    source_generation = compact_hash({
        "method": METHOD_VERSION,
        "source": source,
        "shareBasisDate": share_basis_date,
    })

    sql = sqlite3.connect(database_path)
    sql.execute("PRAGMA busy_timeout=30000")
    sql.execute("""
      CREATE TABLE IF NOT EXISTS institutional_13f_insight_snapshots_v2(
        report_date TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        available_at TEXT NOT NULL,
        generated_at TEXT NOT NULL,
        payload_hash TEXT NOT NULL,
        payload_gzip BLOB NOT NULL,
        PRIMARY KEY(report_date,source_generation)
      )
    """)
    sql.execute("CREATE INDEX IF NOT EXISTS institutional_13f_insights_v2_available_idx ON institutional_13f_insight_snapshots_v2(available_at,report_date)")
    sql.execute("""
      CREATE TABLE IF NOT EXISTS institutional_13f_insight_details_v1(
        report_date TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        ticker TEXT NOT NULL,
        payload_hash TEXT NOT NULL,
        payload_gzip BLOB NOT NULL,
        PRIMARY KEY(report_date,source_generation,ticker)
      )
    """)
    sql.execute("CREATE INDEX IF NOT EXISTS institutional_13f_details_v1_lookup_idx ON institutional_13f_insight_details_v1(report_date,ticker,source_generation)")
    sql.execute("""
      CREATE TABLE IF NOT EXISTS institutional_13f_market_history_v1(
        report_date TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        segment TEXT NOT NULL,
        available_at TEXT NOT NULL,
        securities INTEGER NOT NULL,
        covered_securities INTEGER NOT NULL,
        institutional_value_m REAL,
        market_cap_m REAL,
        institutional_ownership_pct REAL,
        net_change_value_m REAL,
        net_change_pct_market_cap REAL,
        PRIMARY KEY(report_date,source_generation,segment)
      )
    """)
    sql.execute("CREATE INDEX IF NOT EXISTS institutional_13f_market_history_v1_available_idx ON institutional_13f_market_history_v1(available_at,report_date,segment)")
    sql.execute("""
      CREATE TABLE IF NOT EXISTS institutional_13f_security_history_v1(
        report_date TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        ticker TEXT NOT NULL,
        available_at TEXT NOT NULL,
        holders INTEGER,
        institutional_value_m REAL,
        institutional_shares_k REAL,
        share_basis_factor REAL,
        shares_outstanding_k REAL,
        institutional_ownership_pct REAL,
        PRIMARY KEY(report_date,source_generation,ticker)
      )
    """)
    security_history_columns = {
        row[1] for row in sql.execute("PRAGMA table_info(institutional_13f_security_history_v1)")
    }
    if "institutional_value_m" not in security_history_columns:
        sql.execute(
            "ALTER TABLE institutional_13f_security_history_v1 ADD COLUMN institutional_value_m REAL"
        )
    for column, definition in (("share_basis_factor", "REAL"),):
        if column not in security_history_columns:
            sql.execute(
                f"ALTER TABLE institutional_13f_security_history_v1 ADD COLUMN {column} {definition}"
            )
    sql.execute("CREATE INDEX IF NOT EXISTS institutional_13f_security_history_v1_lookup_idx ON institutional_13f_security_history_v1(ticker,report_date,available_at)")
    before = sql.execute("SELECT count(*) FROM institutional_13f_insight_snapshots_v2").fetchone()[0]
    inserted = []
    generated_at = dt.datetime.now(dt.timezone.utc).isoformat()
    for index in range(len(selected) - 1):
        current, previous = selected[index], selected[index + 1]
        exists = sql.execute(
            "SELECT payload_hash FROM institutional_13f_insight_snapshots_v2 WHERE report_date=? AND source_generation=?",
            (current, source_generation),
        ).fetchone()
        detail_count = sql.execute(
            "SELECT count(*) FROM institutional_13f_insight_details_v1 WHERE report_date=? AND source_generation=?",
            (current, source_generation),
        ).fetchone()[0]
        market_count = sql.execute(
            "SELECT count(*) FROM institutional_13f_market_history_v1 WHERE report_date=? AND source_generation=?",
            (current, source_generation),
        ).fetchone()[0]
        security_history_count = sql.execute(
            "SELECT count(*) FROM institutional_13f_security_history_v1 WHERE report_date=? AND source_generation=?",
            (current, source_generation),
        ).fetchone()[0]
        security_value_count = sql.execute(
            "SELECT count(*) FROM institutional_13f_security_history_v1 WHERE report_date=? AND source_generation=? AND institutional_value_m IS NOT NULL",
            (current, source_generation),
        ).fetchone()[0]
        include_details = index < max(0, args.detail_quarters)
        if exists and market_count == 4 and security_history_count > 0 and security_value_count == security_history_count and (not include_details or detail_count > 0):
            continue
        payload, details = snapshot(
            duck, current, previous, share_basis_date, observed_at, include_details
        )
        encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
        raw = encoded.encode()
        compressed = gzip.compress(raw, compresslevel=9, mtime=0)
        payload_hash = hashlib.sha256(raw).hexdigest()
        with sql:
            if not exists:
                sql.execute(
                    "INSERT INTO institutional_13f_insight_snapshots_v2 VALUES(?,?,?,?,?,?)",
                    (current, source_generation, payload["availableAt"], generated_at, payload_hash, compressed),
                )
            if include_details and detail_count == 0:
                for ticker, detail in details.items():
                    detail_raw = json.dumps(detail, separators=(",", ":"), ensure_ascii=False).encode()
                    sql.execute(
                        "INSERT INTO institutional_13f_insight_details_v1 VALUES(?,?,?,?,?)",
                        (
                            current,
                            source_generation,
                            ticker,
                            hashlib.sha256(detail_raw).hexdigest(),
                            gzip.compress(detail_raw, compresslevel=9, mtime=0),
                        ),
                    )
            if market_count == 0:
                for segment, metrics in payload["marketOverview"].items():
                    sql.execute(
                        "INSERT INTO institutional_13f_market_history_v1 VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                        (
                            current,
                            source_generation,
                            segment,
                            payload["availableAt"],
                            metrics["securities"],
                            metrics["coveredSecurities"],
                            metrics["institutionalValueM"],
                            metrics["marketCapM"],
                            metrics["institutionalOwnershipPct"],
                            metrics["netChangeValueM"],
                            metrics["netChangePctMarketCap"],
                        ),
                    )
            if security_history_count == 0:
                sql.executemany(
                    """INSERT INTO institutional_13f_security_history_v1(
                      report_date,source_generation,ticker,available_at,holders,institutional_value_m,
                      institutional_shares_k,share_basis_factor,
                      shares_outstanding_k,institutional_ownership_pct
                    ) VALUES(?,?,?,?,?,?,?,?,?,?)""",
                    [
                        (
                            current,
                            source_generation,
                            row["ticker"],
                            payload["availableAt"],
                            row["holders"],
                            row["currentValueM"],
                            row["currentUnitsK"],
                            row["shareBasisFactor"],
                            row["sharesOutstandingK"],
                            row["institutionalOwnershipPct"],
                        )
                        for row in payload["rows"]
                    ],
                )
            elif security_value_count < security_history_count:
                sql.executemany(
                    """UPDATE institutional_13f_security_history_v1
                       SET institutional_value_m=?
                       WHERE report_date=? AND source_generation=? AND ticker=?""",
                    [
                        (row["currentValueM"], current, source_generation, row["ticker"])
                        for row in payload["rows"]
                    ],
                )
        inserted.append({
            "reportDate": current, "payloadHash": payload_hash,
            "bytes": len(raw), "compressedBytes": len(compressed),
            "detailRows": len(details),
        })
    after = sql.execute("SELECT count(*) FROM institutional_13f_insight_snapshots_v2").fetchone()[0]
    duplicates = sql.execute("""
      SELECT count(*) FROM (
        SELECT report_date,source_generation,count(*) n
        FROM institutional_13f_insight_snapshots_v2
        GROUP BY report_date,source_generation HAVING n>1
      )
    """).fetchone()[0]
    detail_duplicates = sql.execute("""
      SELECT count(*) FROM (
        SELECT report_date,source_generation,ticker,count(*) n
        FROM institutional_13f_insight_details_v1
        GROUP BY report_date,source_generation,ticker HAVING n>1
      )
    """).fetchone()[0]
    replay = sql.execute(
        "SELECT count(*) FROM institutional_13f_insight_snapshots_v2 WHERE source_generation=?",
        (source_generation,),
    ).fetchone()[0]
    detail_rows = sql.execute("SELECT count(*) FROM institutional_13f_insight_details_v1").fetchone()[0]
    market_rows = sql.execute("SELECT count(*) FROM institutional_13f_market_history_v1").fetchone()[0]
    security_history_rows = sql.execute("SELECT count(*) FROM institutional_13f_security_history_v1").fetchone()[0]
    sql.execute("PRAGMA optimize")
    sql.close()
    duck.close()
    receipt = {
        "methodVersion": METHOD_VERSION,
        "sourceGeneration": source_generation,
        "database": str(database_path),
        "beforeRows": before,
        "afterRows": after,
        "inserted": inserted,
        "sameInputRows": replay,
        "duplicateNaturalKeys": duplicates,
        "detailRows": detail_rows,
        "marketHistoryRows": market_rows,
        "securityHistoryRows": security_history_rows,
        "duplicateDetailNaturalKeys": detail_duplicates,
        "status": "verified" if duplicates == 0 and detail_duplicates == 0 and after >= before else "failed",
    }
    receipt_path = fact_path.parent / "audit" / "13f-insights-build-latest.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    return 0 if receipt["status"] == "verified" else 1


if __name__ == "__main__":
    raise SystemExit(main())
