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
from pathlib import Path

import duckdb


METHOD_VERSION = "institutional-13f-insights-v1"
DETAIL_SECURITY_LIMIT = 750
DETAIL_PER_ACTION = 8


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fact-os", default="data/fact_os/fact_os.duckdb")
    parser.add_argument("--database", default="server/data/guru-analysis.sqlite")
    parser.add_argument("--quarters", type=int, default=8)
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


def snapshot(con: duckdb.DuckDBPyConnection, current: str, previous: str, observed_at: str) -> dict:
    cte = action_cte(current, previous)
    coverage = con.execute(
        f"""{cte}
        SELECT
          (SELECT count(*) FROM holdings_investor WHERE date='{current}') current_filers,
          (SELECT count(*) FROM holdings_investor WHERE date='{previous}') previous_filers,
          count(DISTINCT ticker) securities,
          count(*) comparable_positions,
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
          count(*) FILTER(WHERE split_factor<>1) AS split_adjusted
        FROM joined j LEFT JOIN names n USING(ticker)
        GROUP BY j.ticker"""
    ).fetchall()
    securities = []
    for row in security_rows:
        securities.append({
            "ticker": row[0], "name": None if row[1] in (None, "None") else row[1],
            "holders": row[2], "newPositions": row[3], "increases": row[4],
            "reductions": row[5], "exits": row[6], "currentValueM": row[7],
            "previousValueM": row[8], "currentUnitsK": row[9],
            "previousUnitsK": row[10], "splitAdjustedFilers": row[11],
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
    if priority:
        values = ",".join("?" for _ in priority)
        detail_rows = con.execute(
            f"""{cte}, ranked AS (
              SELECT *,row_number() OVER(
                PARTITION BY ticker,reported_action
                ORDER BY greatest(coalesce(current_value,0),coalesce(previous_value,0)) DESC,investorid
              ) detail_rank
              FROM joined WHERE reported_action<>'unchanged' AND ticker IN ({values})
            )
            SELECT ticker,reported_action,investorid,coalesce(current_investor_name,previous_investor_name),
              current_units,adjusted_previous_units,current_value,previous_value,
              current_value/nullif(current_book_value,0),previous_value/nullif(previous_book_value,0),split_factor
            FROM ranked WHERE detail_rank<=? ORDER BY ticker,reported_action,detail_rank""",
            [*sorted(priority), DETAIL_PER_ACTION],
        ).fetchall()
        for row in detail_rows:
            details.setdefault(row[0], {}).setdefault(row[1], []).append({
                "investorId": row[2], "name": row[3] or row[2],
                "currentUnitsK": row[4], "previousUnitsK": row[5],
                "currentValueM": row[6], "previousValueM": row[7],
                "currentWeight": row[8], "previousWeight": row[9],
                "changePct": None if not row[5] else (row[4] or 0) / row[5] - 1,
                "splitAdjusted": row[10] != 1,
            })

    return {
        "version": METHOD_VERSION,
        "reportDate": current,
        "previousReportDate": previous,
        "availableAt": available_at(current),
        "sourceObservedAt": observed_at,
        "coverage": dict(zip(coverage_keys, coverage)),
        "activity": {
            "newPositions": coverage[4], "increases": coverage[5],
            "reductions": coverage[6], "exits": coverage[7],
        },
        "rows": securities,
        "institutions": institutions,
        "details": details,
        "methodology": {
            "universe": "All Sharadar SF3 institutional SHR positions in the selected report quarter",
            "classification": "Quarter-over-quarter reported units, adjusted for split actions between quarter ends",
            "availability": "Quarter-end aggregate; shared availability uses the 45-day 13F deadline because SF3 does not retain each filing timestamp",
            "units": "units are thousands; values are USD millions",
            "detailPolicy": f"Largest {DETAIL_PER_ACTION} reporting institutions per action for leading securities; counts use the full universe",
        },
    }


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
        for key in ("holdings", "holdings_ticker", "holdings_investor", "actions")
    }
    source_generation = compact_hash({"method": METHOD_VERSION, "source": source})
    observed_at = max(
        catalog["datasets"][key]["state"]["last_success"]
        for key in ("holdings", "holdings_ticker", "holdings_investor", "actions")
    )
    duck = duckdb.connect(str(fact_path), read_only=True)
    dates = [str(row[0]) for row in duck.execute(
        "SELECT DISTINCT date FROM holdings WHERE securitytype='SHR' ORDER BY date DESC"
    ).fetchall()]
    selected = dates[: max(1, args.quarters) + 1]
    if len(selected) < 2:
        raise RuntimeError("insufficient_holdings_quarters")

    sql = sqlite3.connect(database_path)
    sql.execute("PRAGMA busy_timeout=30000")
    sql.execute("""
      CREATE TABLE IF NOT EXISTS institutional_13f_insight_snapshots(
        report_date TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        available_at TEXT NOT NULL,
        generated_at TEXT NOT NULL,
        payload_hash TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        PRIMARY KEY(report_date,source_generation)
      )
    """)
    sql.execute("CREATE INDEX IF NOT EXISTS institutional_13f_insights_available_idx ON institutional_13f_insight_snapshots(available_at,report_date)")
    before = sql.execute("SELECT count(*) FROM institutional_13f_insight_snapshots").fetchone()[0]
    inserted = []
    generated_at = dt.datetime.now(dt.timezone.utc).isoformat()
    for index in range(len(selected) - 1):
        current, previous = selected[index], selected[index + 1]
        exists = sql.execute(
            "SELECT payload_hash FROM institutional_13f_insight_snapshots WHERE report_date=? AND source_generation=?",
            (current, source_generation),
        ).fetchone()
        if exists:
            continue
        payload = snapshot(duck, current, previous, observed_at)
        encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
        payload_hash = hashlib.sha256(encoded.encode()).hexdigest()
        with sql:
            sql.execute(
                "INSERT INTO institutional_13f_insight_snapshots VALUES(?,?,?,?,?,?)",
                (current, source_generation, payload["availableAt"], generated_at, payload_hash, encoded),
            )
        inserted.append({"reportDate": current, "payloadHash": payload_hash, "bytes": len(encoded)})
    after = sql.execute("SELECT count(*) FROM institutional_13f_insight_snapshots").fetchone()[0]
    duplicates = sql.execute("""
      SELECT count(*) FROM (
        SELECT report_date,source_generation,count(*) n
        FROM institutional_13f_insight_snapshots
        GROUP BY report_date,source_generation HAVING n>1
      )
    """).fetchone()[0]
    replay = sql.execute(
        "SELECT count(*) FROM institutional_13f_insight_snapshots WHERE source_generation=?",
        (source_generation,),
    ).fetchone()[0]
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
        "status": "verified" if duplicates == 0 and after >= before else "failed",
    }
    receipt_path = fact_path.parent / "audit" / "13f-insights-build-latest.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    return 0 if receipt["status"] == "verified" else 1


if __name__ == "__main__":
    raise SystemExit(main())
