#!/usr/bin/env python3
"""Build conservative active-manager 13F research snapshots.

The complete SF3 universe remains the source of truth.  This derivative keeps
only managers that pass an explicit, conservative active-management screen.
Banks/custodians, broker-dealers, explicit index complexes, asset owners and
unknown/mixed filers stay excluded.  Reported quarter-end value changes are
never labelled as trades or flows.
"""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
import fcntl
import sqlite3
import stat
import sys
from pathlib import Path
from statistics import median

import duckdb
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from fact_os.repository import FactRepository
from active_sector_analysis import sector_analysis


METHOD_VERSION = "institutional-active-13f-v2"
DETAIL_SECURITY_LIMIT = 600
DETAIL_PER_ACTION = 40
IMPORTANT_PER_DIRECTION = 8

PASSIVE_IDS = {
    "BLKROK", "VANGRD", "STASTR", "VANGPM", "GEODEC", "CHASCH",
    "VANFID", "VANGU2", "VANGU3", "RHUMBL",
}
KNOWN_ACTIVE_IDS = {
    "FIDLTY", "PRICTR", "WORLDX", "RESEAR", "WELLIN", "MASSAC",
    "FISHER", "AQRCAP", "ALLIAN", "ARROWS", "AMECEN", "DODCOX",
    "PRIMEC", "JENNIS", "DESHAW", "MILLEN", "NORDEA", "TWOSIG",
    "CLEARB", "BOSTON", "TROWEP", "BERHAT",
}
PASSIVE_PHRASES = (
    "VANGUARD", "BLACKROCK", "STATE STREET", "GEODE CAPITAL",
    "SCHWAB INVESTMENT MANAGEMENT", "RHUMBLINE", "INDEX MANAGEMENT",
    "INDEX FUND", "SSGA FUNDS MANAGEMENT",
)
CUSTODY_BANK_PHRASES = (
    "BANK OF ", " BANK ", "BANCORP", "BANCO ", "BANQUE ",
    "BANK AG", "BANK PLC", "BANK LTD", "TRUST COMPANY", "TRUST CO",
    "SECURITIES LLC", "SECURITIES INC", "SECURITIES LTD",
    "FINANCIAL MARKETS", "JPMORGAN CHASE", "MORGAN STANLEY",
    "GOLDMAN SACHS GROUP", "CITIGROUP", "WELLS FARGO", "BARCLAYS",
    "BNP PARIBAS", "DEUTSCHE BANK", "UBS GROUP", "HSBC HOLDINGS",
    "ROYAL BANK", "NORTHERN TRUST", "BANK OF NEW YORK MELLON",
)
ASSET_OWNER_PHRASES = (
    "PENSION", "RETIREMENT SYSTEM", "RETIREMENT FUND", "INSURANCE COMPANY",
    "MUTUAL AUTOMOBILE INSURANCE", "NATIONAL BANK", "CENTRAL BANK",
    "SOVEREIGN", "TREASURER", "UNIVERSITY", "FOUNDATION", "ENDOWMENT",
    "INVESTMENT BOARD", "PUBLIC EMPLOYEES", "PUBLIC SCHOOL",
)
ACTIVE_PHRASES = (
    "CAPITAL MANAGEMENT", "ASSET MANAGEMENT", "INVESTMENT MANAGEMENT",
    "FUND MANAGEMENT", "FUND MANAGERS", "CAPITAL PARTNERS",
    "INVESTMENT PARTNERS", "ASSET MANAGERS", "CAPITAL ADVISORS",
    "CAPITAL ADVISERS", "INVESTMENT ADVISORS", "INVESTMENT ADVISERS",
    "HEDGE FUND", "MANAGEMENT LP", "MANAGEMENT LLP", "MANAGEMENT LLC",
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fact-os", default="data/fact_os/fact_os.duckdb")
    parser.add_argument(
        "--database",
        default="/private/tmp/thesisforge-13f-active-source.sqlite",
    )
    parser.add_argument(
        "--base-database",
        default="data/releases/thesisforge-20260920-v3/13f-insights-20260921-v8/13f-insights.sqlite",
    )
    parser.add_argument("--quarters", type=int, default=12)
    return parser.parse_args()


def compact_hash(value: object) -> str:
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"), default=str).encode()
    return hashlib.sha256(raw).hexdigest()


def available_at(report_date: str) -> str:
    return (dt.date.fromisoformat(report_date) + dt.timedelta(days=45)).isoformat()


def normalized_name(name: str | None) -> str:
    return f" {str(name or '').upper().replace('&', ' AND ')} "


def classify_manager(
    investor_id: str,
    name: str | None,
    holdings: int | None,
    value_m: float | None,
) -> tuple[str, str, str]:
    """Return (bucket, confidence, reason) with unknown excluded by default."""
    identity = str(investor_id or "").upper()
    manager = normalized_name(name)
    if identity in PASSIVE_IDS or any(term in manager for term in PASSIVE_PHRASES):
        return "excluded_passive_index", "high", "explicit_passive_or_index_complex"
    if any(term in manager for term in CUSTODY_BANK_PHRASES):
        return "excluded_bank_custody", "high", "bank_custody_broker_dealer_filer"
    if any(term in manager for term in ASSET_OWNER_PHRASES):
        return "excluded_asset_owner", "high", "asset_owner_not_active_fund_manager"
    if identity in KNOWN_ACTIVE_IDS:
        return "active", "high", "curated_active_manager_identity"
    count = int(holdings or 0)
    value = float(value_m or 0)
    if (
        any(term in manager for term in ACTIVE_PHRASES)
        and 1 < count <= 1800
        and value >= 50
    ):
        return "active", "medium", "manager_name_and_portfolio_structure_proxy"
    return "excluded_unknown_mixed", "low", "insufficient_evidence_of_active_fund_scope"


def action_cte(current: str, previous: str) -> str:
    return f"""
      WITH splits AS (
        SELECT ticker,product(value) factor FROM actions
        WHERE action='split' AND date>'{previous}' AND date<='{current}'
          AND value IS NOT NULL AND value>0 GROUP BY ticker
      ), current_book AS (
        SELECT investorid,ticker,sum(units) current_units,sum(value) current_value
        FROM holdings WHERE securitytype='SHR' AND date='{current}'
        GROUP BY investorid,ticker
      ), previous_book AS (
        SELECT investorid,ticker,sum(units) previous_units,sum(value) previous_value
        FROM holdings WHERE securitytype='SHR' AND date='{previous}'
        GROUP BY investorid,ticker
      ), current_investor AS (
        SELECT investorid,investorname,shrholdings,shrvalue
        FROM holdings_investor WHERE date='{current}'
      ), previous_investor AS (
        SELECT investorid,investorname,shrholdings,shrvalue
        FROM holdings_investor WHERE date='{previous}'
      ), joined AS (
        SELECT coalesce(c.investorid,p.investorid) investorid,
          coalesce(c.ticker,p.ticker) ticker,
          c.current_units,p.previous_units,
          p.previous_units*coalesce(s.factor,1) adjusted_previous_units,
          c.current_value,p.previous_value,
          ci.investorname current_investor_name,
          pi.investorname previous_investor_name,
          ci.shrvalue current_book_value,pi.shrvalue previous_book_value,
          CASE
            WHEN ci.investorid IS NULL OR pi.investorid IS NULL THEN 'not_comparable'
            WHEN p.previous_units IS NULL AND c.current_units>0 THEN 'new'
            WHEN c.current_units IS NULL AND p.previous_units>0 THEN 'exited'
            WHEN c.current_units>p.previous_units*coalesce(s.factor,1)*1.001 THEN 'increased'
            WHEN c.current_units<p.previous_units*coalesce(s.factor,1)*0.999 THEN 'reduced'
            ELSE 'unchanged'
          END reported_action,
          coalesce(s.factor,1) split_factor
        FROM current_book c FULL OUTER JOIN previous_book p USING(investorid,ticker)
        LEFT JOIN splits s ON s.ticker=coalesce(c.ticker,p.ticker)
        LEFT JOIN current_investor ci ON ci.investorid=coalesce(c.investorid,p.investorid)
        LEFT JOIN previous_investor pi ON pi.investorid=coalesce(c.investorid,p.investorid)
      ), active_joined AS (
        SELECT j.*,a.confidence active_confidence,a.reason active_reason
        FROM joined j JOIN active_manager_ids a USING(investorid)
      )
    """


def listing_ctes(current: str, share_basis_date: str) -> str:
    return f"""
      , names AS (SELECT ticker,name FROM holdings_ticker WHERE date='{current}')
      , share_counts AS (
        SELECT ticker,sharesbas*sharefactor/1000.0 shares_outstanding_k
        FROM fundamentals
        WHERE dimension='ARQ' AND sharesbas>0 AND sharefactor>0
          AND date<='{available_at(current)}' AND reportperiod<='{current}'
        QUALIFY row_number() OVER(
          PARTITION BY ticker ORDER BY reportperiod DESC,date ASC,lastupdated DESC
        )=1
      ), market_caps AS (
        SELECT ticker,marketcap market_cap_m FROM daily
        WHERE date<='{current}' AND date>='{(dt.date.fromisoformat(current)-dt.timedelta(days=7)).isoformat()}'
          AND marketcap>0
        QUALIFY row_number() OVER(PARTITION BY ticker ORDER BY date DESC)=1
      ), share_basis_splits AS (
        SELECT ticker,product(value) factor FROM actions
        WHERE action='split' AND date>'{current}' AND date<='{share_basis_date}'
          AND value IS NOT NULL AND value>0 GROUP BY ticker
      ), listing AS (
        SELECT ticker,coalesce(sector,'Unclassified') sector,exchange,scalemarketcap
        FROM tickers WHERE "table"='SF1'
        QUALIFY row_number() OVER(PARTITION BY ticker ORDER BY lastupdated DESC)=1
      ), nasdaq_rank AS (
        SELECT l.ticker,row_number() OVER(ORDER BY m.market_cap_m DESC,l.ticker) rank
        FROM listing l JOIN market_caps m USING(ticker)
        WHERE l.exchange='NASDAQ' AND l.sector<>'Financial Services'
      ), sp500_members AS (
        SELECT ticker FROM sp500 WHERE date='{current}' AND action='historical'
      )
    """


def manager_universe(con: duckdb.DuckDBPyConnection, current: str, previous: str):
    rows = con.execute(
        """WITH current_investor AS (
             SELECT investorid,investorname,shrholdings,shrvalue
             FROM holdings_investor WHERE date=?
           ), previous_investor AS (
             SELECT investorid,investorname,shrholdings,shrvalue
             FROM holdings_investor WHERE date=?
           )
           SELECT coalesce(c.investorid,p.investorid),
                  coalesce(c.investorname,p.investorname),
                  c.shrholdings,c.shrvalue,p.shrholdings,p.shrvalue
           FROM current_investor c FULL OUTER JOIN previous_investor p
             USING(investorid)""",
        [current, previous],
    ).fetchall()
    classifications = []
    for row in rows:
        bucket, confidence, reason = classify_manager(row[0], row[1], row[2] or row[4], row[3] or row[5])
        classifications.append({
            "investorId": row[0], "name": row[1] or row[0], "bucket": bucket,
            "confidence": confidence, "reason": reason,
            "currentHoldings": row[2], "currentValueM": row[3],
            "previousHoldings": row[4], "previousValueM": row[5],
        })
    return classifications


def stock_rows(
    con: duckdb.DuckDBPyConnection,
    cte: str,
    current: str,
    share_basis_date: str,
) -> list[dict]:
    sql = cte + listing_ctes(current, share_basis_date) + """
      SELECT j.ticker,max(n.name),count(*) FILTER(WHERE current_units>0),
        count(*) FILTER(WHERE reported_action='new'),
        count(*) FILTER(WHERE reported_action='increased'),
        count(*) FILTER(WHERE reported_action='reduced'),
        count(*) FILTER(WHERE reported_action='exited'),
        sum(current_value),sum(previous_value),sum(current_units),
        sum(adjusted_previous_units),
        sum(current_units) FILTER(WHERE reported_action<>'not_comparable'),
        sum(adjusted_previous_units) FILTER(WHERE reported_action<>'not_comparable'),
        count(*) FILTER(WHERE split_factor<>1),max(sc.shares_outstanding_k),
        max(mc.market_cap_m),bool_or(sp.ticker IS NOT NULL),
        bool_or(nq.rank<=100),bool_or(l.scalemarketcap='3 - Small'),
        max(coalesce(bs.factor,1))
      FROM active_joined j LEFT JOIN names n USING(ticker)
      LEFT JOIN share_counts sc USING(ticker) LEFT JOIN market_caps mc USING(ticker)
      LEFT JOIN share_basis_splits bs USING(ticker) LEFT JOIN listing l USING(ticker)
      LEFT JOIN nasdaq_rank nq USING(ticker) LEFT JOIN sp500_members sp USING(ticker)
      GROUP BY j.ticker
    """
    output = []
    for row in con.execute(sql).fetchall():
        factor = row[19] or 1
        current_units = None if row[9] is None else row[9] * factor
        previous_units = None if row[10] is None else row[10] * factor
        comparable_current = None if row[11] is None else row[11] * factor
        comparable_previous = None if row[12] is None else row[12] * factor
        shares_outstanding = row[14]
        net_units = (comparable_current or 0) - (comparable_previous or 0)
        implied_price = None if not current_units else row[7] * 1000 / current_units
        segments = ["all"]
        if row[16]: segments.append("sp500")
        if row[17]: segments.append("nasdaq100Proxy")
        if row[18]: segments.append("smallCap")
        output.append({
            "ticker": row[0], "name": None if row[1] in (None, "None") else row[1],
            "holders": row[2], "newPositions": row[3], "increases": row[4],
            "reductions": row[5], "exits": row[6], "currentValueM": row[7],
            "previousValueM": row[8], "currentUnitsK": current_units,
            "rawCurrentUnitsK": row[9], "previousUnitsK": previous_units,
            "splitAdjustedFilers": row[13], "shareBasisFactor": factor,
            "shareBasisDate": share_basis_date, "sharesOutstandingK": shares_outstanding,
            "marketCapM": row[15],
            "institutionalOwnershipPct": None if not shares_outstanding or current_units is None else current_units/shares_outstanding*100,
            "netUnitsChangeK": net_units,
            "netChangeValueM": None if implied_price is None else net_units*implied_price/1000,
            "netChangePctOutstanding": None if not shares_outstanding else net_units/shares_outstanding*100,
            "segments": segments, "adds": row[3]+row[4], "trims": row[5]+row[6],
            "netFilers": row[3]+row[4]-row[5]-row[6],
        })
    output.sort(key=lambda item: (-item["holders"], item["ticker"]))
    return output


def detail_payloads(
    con: duckdb.DuckDBPyConnection,
    cte: str,
    securities: list[dict],
    current: str,
    previous: str,
) -> dict:
    priority: set[str] = set()
    for key in ("newPositions", "increases", "reductions", "exits"):
        priority.update(row["ticker"] for row in sorted(securities, key=lambda item: (-item[key], item["ticker"]))[:DETAIL_SECURITY_LIMIT])
    if not priority:
        return {}
    values = ",".join("?" for _ in priority)
    rows = con.execute(
        cte + f""", ranked AS (
          SELECT *,row_number() OVER(PARTITION BY ticker,reported_action
            ORDER BY abs(coalesce(current_value,0)-coalesce(previous_value,0)) DESC,
              greatest(coalesce(current_value,0),coalesce(previous_value,0)) DESC,investorid) detail_rank
          FROM active_joined WHERE reported_action IN ('new','increased','reduced','exited')
            AND ticker IN ({values})
        )
        SELECT ticker,reported_action,investorid,
          coalesce(current_investor_name,previous_investor_name),
          current_units,adjusted_previous_units,current_value,previous_value,
          current_value/nullif(current_book_value,0),
          previous_value/nullif(previous_book_value,0),split_factor,detail_rank
        FROM ranked WHERE detail_rank<=? ORDER BY ticker,reported_action,detail_rank""",
        [*sorted(priority), DETAIL_PER_ACTION],
    ).fetchall()
    details: dict[str, dict] = {}
    changes: dict[str, list] = {}
    for row in rows:
        ticker, action = row[0], row[1]
        current_units, previous_units = row[4], row[5]
        current_value, previous_value = row[6], row[7]
        current_weight, previous_weight = row[8], row[9]
        reported_value_change = (
            current_value-previous_value if current_value is not None and previous_value is not None
            else current_value if action == "new"
            else -previous_value if action == "exited" and previous_value is not None else None
        )
        item = {
            "investorId": row[2], "name": row[3] or row[2],
            "currentUnitsK": current_units, "previousUnitsK": previous_units,
            "currentValueM": current_value, "previousValueM": previous_value,
            "currentWeight": current_weight, "previousWeight": previous_weight,
            "activityValueM": previous_value if action == "exited" else current_value,
            "reportedValueChangeM": reported_value_change,
            "changePct": None if action not in ("increased", "reduced") or not previous_units else (current_units or 0)/previous_units-1,
            "comparisonBasis": "prior_reported_position_value" if action == "exited" else "current_reported_position_value" if action == "new" else "split_adjusted_reported_units",
            "splitAdjusted": row[10] != 1,
        }
        details.setdefault(ticker, {}).setdefault(action, []).append(item)
        changes.setdefault(ticker, []).append({**item, "action": action})
    security_map = {row["ticker"]: row for row in securities}
    for ticker, items in changes.items():
        ranked = sorted(items, key=lambda item: abs(item.get("reportedValueChangeM") or 0), reverse=True)
        adding = [item for item in ranked if item["action"] in ("new", "increased")][:IMPORTANT_PER_DIRECTION]
        reducing = [item for item in ranked if item["action"] in ("reduced", "exited")][:IMPORTANT_PER_DIRECTION]
        important = []
        for item in adding + reducing:
            action = item["action"]
            current_weight, previous_weight = item.get("currentWeight"), item.get("previousWeight")
            weight_bps = None if current_weight is None or previous_weight is None else (current_weight-previous_weight)*10000
            tags = []
            if action == "new" and (current_weight or 0) >= .005: tags.append("meaningful_new_position")
            if action == "increased" and weight_bps is not None: tags.append("shares_and_weight_up" if weight_bps>0 else "shares_up_weight_down")
            if action in ("reduced", "exited") and (previous_weight or 0) >= .02: tags.append("core_position_reduction")
            important.append({
                **item, "direction": "adding" if action in ("new", "increased") else "reducing",
                "unitsChangeK": (item.get("currentUnitsK") or 0)-(item.get("previousUnitsK") or 0),
                "weightChangeBps": weight_bps, "tags": tags,
                "continuity": "new_position" if action == "new" else "exit_after_hold" if action == "exited" else "single_quarter_change",
                "consecutiveDirectionQuarters": 1,
                "trajectory": [
                    {"reportDate": previous, "status": "reported" if item.get("previousUnitsK") is not None else "no_position", "unitsK": item.get("previousUnitsK"), "weight": previous_weight},
                    {"reportDate": current, "status": "reported" if item.get("currentUnitsK") is not None else "no_position", "unitsK": item.get("currentUnitsK"), "weight": current_weight},
                ],
            })
        security = security_map[ticker]
        changed = security["adds"]+security["trims"]
        breadth_close = abs(security["netFilers"]) <= max(3, changed*.1)
        breadth_direction = "balanced" if breadth_close else "positive" if security["netFilers"]>0 else "negative"
        units_direction = "increase" if (security["netUnitsChangeK"] or 0)>0 else "decrease" if (security["netUnitsChangeK"] or 0)<0 else "flat"
        previous_total = security.get("previousUnitsK")
        details[ticker]["analysis"] = {
            "methodVersion": "active-manager-behavior-v1",
            "headlineKey": f"{breadth_direction}_breadth_net_{units_direction}",
            "evidence": {
                "breadth": {"adds": security["adds"], "trims": security["trims"], "netFilers": security["netFilers"], "changedFilers": changed, "addsPct": None if not changed else security["adds"]/changed},
                "shares": {"netUnitsChangeK": security["netUnitsChangeK"], "netChangePctPrior": None if not previous_total else security["netUnitsChangeK"]/previous_total*100, "netChangePctOutstanding": security["netChangePctOutstanding"], "shareBasisDate": security["shareBasisDate"]},
                "weights": {"importantChangesEvaluated": len(important), "sharesUpWeightDown": sum(1 for item in important if item["action"]=="increased" and (item.get("weightChangeBps") or 0)<0)},
            },
            "importantChanges": important,
            "coverage": {"completeComparablePopulationEvaluated": True, "importantChangeSelection": "top_active_manager_absolute_reported_value_change_per_direction", "perDirection": IMPORTANT_PER_DIRECTION, "trajectoryQuarters": 2},
            "researchQuestionKeys": ["cash_conversion_with_institutional_change", "operating_evidence_divergence", "price_vs_model_since_disclosure"],
        }
    return details


def manager_analysis(con: duckdb.DuckDBPyConnection, cte: str, current: str):
    rows = con.execute(
        cte + f""", listing AS (
          SELECT ticker,coalesce(sector,'Unclassified') sector FROM tickers WHERE "table"='SF1'
          QUALIFY row_number() OVER(PARTITION BY ticker ORDER BY lastupdated DESC)=1
        ), weighted AS (
          SELECT j.*,coalesce(l.sector,'Unclassified') sector,
            current_value/nullif(current_book_value,0) current_weight,
            previous_value/nullif(previous_book_value,0) previous_weight
          FROM active_joined j LEFT JOIN listing l USING(ticker)
          WHERE reported_action<>'not_comparable'
        )
        SELECT investorid,coalesce(max(current_investor_name),max(previous_investor_name)),
          max(current_book_value),max(previous_book_value),
          count(*) FILTER(WHERE current_units>0),
          count(*) FILTER(WHERE reported_action='new'),count(*) FILTER(WHERE reported_action='increased'),
          count(*) FILTER(WHERE reported_action='reduced'),count(*) FILTER(WHERE reported_action='exited'),
          sum(abs(coalesce(current_weight,0)-coalesce(previous_weight,0)))/2 turnover_proxy
        FROM weighted GROUP BY investorid"""
    ).fetchall()
    managers = {
        row[0]: {"investorId": row[0], "name": row[1] or row[0], "currentValueM": row[2],
                 "previousValueM": row[3], "holdings": row[4], "newPositions": row[5],
                 "increases": row[6], "reductions": row[7], "exits": row[8],
                 "turnoverProxy": row[9], "top10Weight": 0.0, "sectorHhi": 0.0,
                 "sectorWeights": [], "topAdds": [], "topTrims": [], "topHoldings": []}
        for row in rows
    }
    holding_rows = con.execute(
        cte + """, listing AS (
          SELECT ticker,coalesce(sector,'Unclassified') sector FROM tickers WHERE "table"='SF1'
          QUALIFY row_number() OVER(PARTITION BY ticker ORDER BY lastupdated DESC)=1
        ), ranked AS (
          SELECT j.*,coalesce(l.sector,'Unclassified') sector,
            current_value/nullif(current_book_value,0) current_weight,
            previous_value/nullif(previous_book_value,0) previous_weight,
            row_number() OVER(PARTITION BY investorid ORDER BY coalesce(current_value,0) DESC,ticker) holding_rank,
            row_number() OVER(PARTITION BY investorid,
              CASE
                WHEN reported_action IN ('new','increased') THEN 'adding'
                WHEN reported_action IN ('reduced','exited') THEN 'reducing'
                ELSE 'other'
              END
              ORDER BY abs(coalesce(current_value,0)-coalesce(previous_value,0)) DESC,ticker) change_rank
          FROM active_joined j LEFT JOIN listing l USING(ticker)
          WHERE reported_action<>'not_comparable'
        )
        SELECT investorid,ticker,sector,reported_action,current_value,previous_value,
          current_weight,previous_weight,holding_rank,change_rank
        FROM ranked WHERE holding_rank<=10 OR (reported_action IN ('new','increased','reduced','exited') AND change_rank<=3)
        ORDER BY investorid,holding_rank"""
    ).fetchall()
    for row in holding_rows:
        manager = managers.get(row[0])
        if not manager: continue
        item = {"ticker": row[1], "sector": row[2], "action": row[3], "currentValueM": row[4],
                "previousValueM": row[5], "currentWeight": row[6], "previousWeight": row[7],
                "weightChangeBps": None if row[6] is None or row[7] is None else (row[6]-row[7])*10000}
        if row[8] <= 10 and row[6] is not None:
            manager["topHoldings"].append(item)
            manager["top10Weight"] += row[6]
        if row[3] in ("new", "increased") and row[9] <= 3: manager["topAdds"].append(item)
        if row[3] in ("reduced", "exited") and row[9] <= 3: manager["topTrims"].append(item)
    sector_rows = con.execute(
        cte + """, listing AS (
          SELECT ticker,coalesce(sector,'Unclassified') sector FROM tickers WHERE "table"='SF1'
          QUALIFY row_number() OVER(PARTITION BY ticker ORDER BY lastupdated DESC)=1
        )
        SELECT j.investorid,coalesce(l.sector,'Unclassified'),sum(current_value),sum(previous_value),
          sum(current_value)/nullif(max(current_book_value),0),
          sum(previous_value)/nullif(max(previous_book_value),0)
        FROM active_joined j LEFT JOIN listing l USING(ticker)
        WHERE reported_action<>'not_comparable' GROUP BY j.investorid,coalesce(l.sector,'Unclassified')"""
    ).fetchall()
    aggregate: dict[str, dict] = {}
    for row in sector_rows:
        manager = managers.get(row[0])
        if not manager: continue
        change_pp = None if row[4] is None or row[5] is None else (row[4]-row[5])*100
        item = {"sector": row[1], "currentValueM": row[2], "previousValueM": row[3],
                "currentWeight": row[4], "previousWeight": row[5], "weightChangePp": change_pp}
        manager["sectorWeights"].append(item)
        manager["sectorHhi"] += (row[4] or 0)**2
        group = aggregate.setdefault(row[1], {"sector": row[1], "currentValueM": 0.0, "previousValueM": 0.0})
        group["currentValueM"] += row[2] or 0
        group["previousValueM"] += row[3] or 0
    current_total = sum(item["currentValueM"] for item in aggregate.values())
    previous_total = sum(item["previousValueM"] for item in aggregate.values())
    sector_rotation = []
    for item in aggregate.values():
        current_weight = None if not current_total else item["currentValueM"]/current_total
        previous_weight = None if not previous_total else item["previousValueM"]/previous_total
        sector_rotation.append({**item, "currentWeight": current_weight, "previousWeight": previous_weight,
                                "weightChangePp": None if current_weight is None or previous_weight is None else (current_weight-previous_weight)*100})
    for manager in managers.values():
        manager["sectorWeights"].sort(key=lambda item: -(item["currentWeight"] or 0))
        manager["largestSectorShift"] = max(manager["sectorWeights"], key=lambda item: abs(item["weightChangePp"] or 0), default=None)
        manager["rotationScoreM"] = (manager["currentValueM"] or 0) * (manager["turnoverProxy"] or 0)
    manager_list = sorted(managers.values(), key=lambda item: -(item["currentValueM"] or 0))
    leader_list = sorted(manager_list, key=lambda item: -item["rotationScoreM"])[:40]
    rotations = []
    for manager in leader_list:
        if manager["topAdds"] and manager["topTrims"]:
            rotations.append({"investorId": manager["investorId"], "name": manager["name"],
                              "added": manager["topAdds"][0], "reduced": manager["topTrims"][0],
                              "turnoverProxy": manager["turnoverProxy"]})
    compact_leaders = [
        {key: value for key, value in manager.items() if key not in ("sectorWeights", "topHoldings")}
        for manager in leader_list
    ]
    valid_turnover = [item["turnoverProxy"] for item in manager_list if item["turnoverProxy"] is not None]
    valid_concentration = [item["top10Weight"] for item in manager_list if item["top10Weight"]]
    return {
        "summary": {
            "activeManagers": len(manager_list),
            "activeBookValueM": sum(item["currentValueM"] or 0 for item in manager_list),
            "medianTurnoverProxy": median(valid_turnover) if valid_turnover else None,
            "medianTop10Weight": median(valid_concentration) if valid_concentration else None,
        },
        "sectorRotation": sorted(sector_rotation, key=lambda item: -(item["currentWeight"] or 0)),
        "managerLeaders": compact_leaders,
        "rotationCandidates": rotations[:20],
    }


def snapshot(con, current: str, previous: str, share_basis_date: str, observed_at: str):
    classifications = manager_universe(con, current, previous)
    included = [row for row in classifications if row["bucket"] == "active"]
    con.execute("CREATE OR REPLACE TEMP TABLE active_manager_ids(investorid VARCHAR,confidence VARCHAR,reason VARCHAR)")
    con.executemany("INSERT INTO active_manager_ids VALUES(?,?,?)", [(row["investorId"],row["confidence"],row["reason"]) for row in included])
    cte = action_cte(current, previous)
    securities = stock_rows(con, cte, current, share_basis_date)
    details = detail_payloads(con, cte, securities, current, previous)
    manager_data = manager_analysis(con, cte, current)
    buckets: dict[str, int] = {}
    for row in classifications: buckets[row["bucket"]] = buckets.get(row["bucket"], 0)+1
    activity = {
        "newPositions": sum(row["newPositions"] for row in securities),
        "increases": sum(row["increases"] for row in securities),
        "reductions": sum(row["reductions"] for row in securities),
        "exits": sum(row["exits"] for row in securities),
    }
    return {
        "version": METHOD_VERSION, "reportDate": current, "previousReportDate": previous,
        "shareBasisDate": share_basis_date, "availableAt": available_at(current),
        "sourceObservedAt": observed_at,
        "coverage": {
            "currentFilers": sum(1 for row in included if row["currentValueM"] is not None),
            "previousFilers": sum(1 for row in included if row["previousValueM"] is not None),
            "securities": len(securities),
            "comparablePositions": sum(row["adds"]+row["trims"] for row in securities),
            "scope": "conservative_active_manager_proxy",
            "classificationBuckets": buckets,
            "classifiedFilers": len(classifications),
            "includedManagers": len(included),
        },
        "activity": activity, "rows": securities,
        "institutions": [{"investorId": row["investorId"], "name": row["name"],
                           "currentValueM": row["currentValueM"], "previousValueM": row["previousValueM"]} for row in included],
        "details": details,
        "sectorDetails": sector_analysis(con, cte),
        "activeAnalysis": {
            **manager_data,
            "classification": {
                "methodVersion": "conservative-active-manager-classification-v1",
                "includedConfidence": ["high", "medium"],
                "excludedByDefault": ["bank/custody/broker-dealer", "explicit passive/index complex", "asset owner", "mixed/unknown"],
                "warning": "Manager-level proxy, not a fund-level mandate classification; mixed complexes and uncertain filers are excluded rather than guessed active.",
            },
        },
        "methodology": {
            "universe": "Conservative active-manager subset of Sharadar SF3 common-stock filers",
            "classification": "Explicit identity exclusions plus active-manager identity/name and portfolio-structure evidence; unknown and mixed filers fail closed",
            "turnover": "One-half of the gross change in adjacent quarter-end reported common-stock portfolio weights; includes price and book-composition effects and is not verified trading turnover",
            "sectorRotation": "Change in reported common-stock sector weights using current security classifications; not actual sector flow",
            "availability": "Shared quarter-end plus 45-day proxy because SF3 lacks individual filing timestamps",
        },
    }


def build(args) -> int:
    fact_path = Path(args.fact_os).resolve()
    database_path = Path(args.database).resolve()
    if not database_path.exists():
        base_database_path = Path(args.base_database).resolve()
        if not base_database_path.is_file():
            raise RuntimeError("missing_base_13f_artifact")
        database_path.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(f"file:{base_database_path}?mode=ro", uri=True) as base:
            with sqlite3.connect(database_path) as target:
                base.backup(target)
        database_path.chmod(database_path.stat().st_mode | stat.S_IWUSR)
    catalog = json.loads((fact_path.parent/"manifests"/"catalog.json").read_text())
    source_keys = ("holdings","holdings_ticker","holdings_investor","actions","fundamentals","daily","tickers","sp500")
    source = {key: {"state":catalog["datasets"][key]["state"],"contentVersion":catalog["datasets"][key].get('contentVersion'),
                   "partitions":catalog["datasets"][key]['partitions']} for key in source_keys}
    observed_at = max(str(item['state'].get('watermark') or item['state'].get('max_date') or '') for item in source.values())
    source_generation = compact_hash({"method": METHOD_VERSION,
        "sectorMethodHash": hashlib.sha256(Path(__file__).with_name("active_sector_analysis.py").read_bytes()).hexdigest(), "rules": {
        "passiveIds": sorted(PASSIVE_IDS), "knownActiveIds": sorted(KNOWN_ACTIVE_IDS),
        "passivePhrases": PASSIVE_PHRASES, "custodyBankPhrases": CUSTODY_BANK_PHRASES,
        "assetOwnerPhrases": ASSET_OWNER_PHRASES, "activePhrases": ACTIVE_PHRASES,
    }, "source": source})
    repository = FactRepository(fact_path.parent)
    duck = repository.db
    duck.execute("SET memory_limit='2GB'")
    dates = [str(row[0]) for row in duck.execute("SELECT DISTINCT date FROM holdings WHERE securitytype='SHR' ORDER BY date DESC").fetchall()]
    selected = dates[:max(1,args.quarters)+1]
    if len(selected)<2: raise RuntimeError("insufficient_holdings_quarters")
    latest_split = duck.execute("SELECT max(date) FROM actions WHERE action='split' AND date<=?", [catalog['datasets']['daily']['state']['max_date']]).fetchone()[0]
    share_basis_date = str(latest_split or selected[0])
    sql = sqlite3.connect(database_path)
    sql.execute("PRAGMA busy_timeout=30000")
    sql.execute("""CREATE TABLE IF NOT EXISTS institutional_13f_active_snapshots_v1(
      report_date TEXT NOT NULL,source_generation TEXT NOT NULL,available_at TEXT NOT NULL,
      generated_at TEXT NOT NULL,payload_hash TEXT NOT NULL,payload_gzip BLOB NOT NULL,
      PRIMARY KEY(report_date,source_generation))""")
    sql.execute("CREATE INDEX IF NOT EXISTS institutional_13f_active_available_idx ON institutional_13f_active_snapshots_v1(available_at,report_date)")
    sql.execute("""CREATE TABLE IF NOT EXISTS institutional_13f_active_details_v1(
      report_date TEXT NOT NULL,source_generation TEXT NOT NULL,ticker TEXT NOT NULL,
      payload_hash TEXT NOT NULL,payload_gzip BLOB NOT NULL,
      PRIMARY KEY(report_date,source_generation,ticker))""")
    sql.execute("CREATE INDEX IF NOT EXISTS institutional_13f_active_details_lookup_idx ON institutional_13f_active_details_v1(report_date,ticker,source_generation)")
    sql.execute("""CREATE TABLE IF NOT EXISTS institutional_13f_active_sectors_v1(
      report_date TEXT NOT NULL,source_generation TEXT NOT NULL,sector TEXT NOT NULL,
      payload_hash TEXT NOT NULL,payload_gzip BLOB NOT NULL,
      PRIMARY KEY(report_date,source_generation,sector))""")
    before = sql.execute("SELECT count(*) FROM institutional_13f_active_snapshots_v1").fetchone()[0]
    before_oldest = sql.execute("SELECT min(report_date) FROM institutional_13f_active_snapshots_v1").fetchone()[0]
    inserted = []
    generated_at = dt.datetime.now(dt.timezone.utc).isoformat()
    for index in range(len(selected)-1):
        current, previous = selected[index], selected[index+1]
        if sql.execute("SELECT 1 FROM institutional_13f_active_snapshots_v1 WHERE report_date=? AND source_generation=?", (current,source_generation)).fetchone():
            continue
        payload = snapshot(duck,current,previous,share_basis_date,observed_at)
        details = payload.pop("details", {})
        sectors = payload.pop("sectorDetails", {})
        payload['activeAnalysis']['sectorDetailVersion'] = 'active-sector-v1'
        raw = json.dumps(payload,separators=(",",":"),ensure_ascii=False).encode()
        payload_hash = hashlib.sha256(raw).hexdigest()
        compressed = gzip.compress(raw,compresslevel=9,mtime=0)
        with sql:
            for sector, detail in sectors.items():
                sector_raw = json.dumps(detail,separators=(",",":"),ensure_ascii=False,allow_nan=False).encode()
                sql.execute("INSERT INTO institutional_13f_active_sectors_v1 VALUES(?,?,?,?,?)",
                            (current,source_generation,sector,hashlib.sha256(sector_raw).hexdigest(),
                             gzip.compress(sector_raw,compresslevel=9,mtime=0)))
            sql.execute("INSERT INTO institutional_13f_active_snapshots_v1 VALUES(?,?,?,?,?,?)",
                        (current,source_generation,payload["availableAt"],generated_at,payload_hash,compressed))
            for ticker, detail in details.items():
                detail_raw = json.dumps(detail,separators=(",",":"),ensure_ascii=False).encode()
                sql.execute("INSERT INTO institutional_13f_active_details_v1 VALUES(?,?,?,?,?)",
                            (current,source_generation,ticker,hashlib.sha256(detail_raw).hexdigest(),
                             gzip.compress(detail_raw,compresslevel=9,mtime=0)))
        inserted.append({"reportDate": current, "payloadHash": payload_hash, "bytes": len(raw),
                         "compressedBytes": len(compressed), "detailRows": len(details),
                         "includedManagers": payload["coverage"]["includedManagers"]})
        print(json.dumps({"builtQuarter": current, "sectors": len(sectors)}), flush=True)
    after = sql.execute("SELECT count(*) FROM institutional_13f_active_snapshots_v1").fetchone()[0]
    duplicates = sql.execute("""SELECT count(*) FROM (SELECT report_date,source_generation,count(*) n
      FROM institutional_13f_active_snapshots_v1 GROUP BY report_date,source_generation HAVING n>1)""").fetchone()[0]
    replay = sql.execute("SELECT count(*) FROM institutional_13f_active_snapshots_v1 WHERE source_generation=?", (source_generation,)).fetchone()[0]
    detail_rows = sql.execute("SELECT count(*) FROM institutional_13f_active_details_v1 WHERE source_generation=?", (source_generation,)).fetchone()[0]
    sector_rows = sql.execute("SELECT count(*) FROM institutional_13f_active_sectors_v1 WHERE source_generation=?", (source_generation,)).fetchone()[0]
    after_oldest = sql.execute("SELECT min(report_date) FROM institutional_13f_active_snapshots_v1").fetchone()[0]
    sql.execute("PRAGMA optimize")
    sql.close(); repository.close()
    receipt = {"methodVersion": METHOD_VERSION, "sourceGeneration": source_generation,
               "database": str(database_path), "beforeRows": before, "afterRows": after,
               "inserted": inserted, "sameInputRows": replay, "duplicateNaturalKeys": duplicates,
               "detailRows": detail_rows, "sectorRows": sector_rows,
               "beforeOldest": before_oldest, "afterOldest": after_oldest,
               "shareBasisDate": share_basis_date, "sourceObservedAt": observed_at}
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    output = fact_path.parent/"audit"/f"13f-active-insights-{stamp}-{source_generation[:12]}.json"
    output.parent.mkdir(parents=True,exist_ok=True)
    with output.open('x') as handle:
        handle.write(json.dumps(receipt,indent=2)+"\n")
    print(json.dumps({**receipt,"receipt":str(output)},indent=2))
    if duplicates: raise RuntimeError("duplicate_active_13f_natural_keys")
    return 0


def main() -> int:
    args = arguments()
    root = Path(args.fact_os).resolve().parent
    # Same writer protocol as Fact OS; derived publication cannot race ingestion.
    with (root / "sync/writer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            return build(args)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


if __name__ == "__main__":
    raise SystemExit(main())
