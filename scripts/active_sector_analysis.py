"""Full comparable active-manager sector evidence, USD millions / shares thousands.

Quantity-change valuation proxies are not observed trades or cash flows. The
upstream join normalizes splits and distinguishes absent positions/filings.
Both quarters use current sector taxonomy (not historical classifications).
"""
from collections import defaultdict
from math import fsum, isfinite
from statistics import median

VERSION = "active-sector-v1"
PRICE_RELATIVE_TOLERANCE = .05
VALUE_ROUNDING_ALLOWANCE_M = .1


def numeric(value):
    return float(value) if value is not None and isfinite(value) else None


def total(rows, key):
    values = [r[key] for r in rows if r.get(key) is not None]
    return fsum(values) if values else None


def ratio(a, b):
    return a / b if a is not None and b is not None and b > 0 else None


def reference_price(rows, units_key, value_key):
    observations = [(numeric(r[units_key]), numeric(r[value_key])) for r in rows]
    valid = [(u, v) for u, v in observations if u is not None and u > 0 and v is not None and v > 0]
    # Larger positions reduce the influence of provider amount rounding. The
    # median prevents an isolated corrupt share count from poisoning all filers.
    large = [(u, v) for u, v in valid if v >= 1]
    sample = large if len(large) >= 3 else valid
    return median(v / u for u, v in sample) if sample else None


def inconsistent(units, value, reference):
    if units is None or value is None:
        return False
    if units < 0 or value < 0 or (units == 0 and value > VALUE_ROUNDING_ALLOWANCE_M):
        return True
    if reference is None:
        return False
    expected = units * reference
    return abs(value - expected) > max(VALUE_ROUNDING_ALLOWANCE_M, abs(expected) * PRICE_RELATIVE_TOLERANCE)


def summarize(rows):
    current, previous = total(rows, "currentValueM"), total(rows, "previousValueM")
    added, trimmed = total(rows, "addProxyM"), total(rows, "trimProxyM")
    net = None if added is None or trimmed is None else added - trimmed
    complete = all(r["currentValueM"] is not None and r["previousValueM"] is not None for r in rows)
    change = current - previous if complete else None
    unpriced = sum(r["addProxyM"] is None for r in rows)
    return dict(currentValueM=current, previousValueM=previous, addProxyM=added,
                trimProxyM=trimmed, netProxyM=net, reportedValueChangeM=change,
                valuationResidualM=change-net if change is not None and net is not None and not unpriced else None,
                positions=len(rows), pricedPositions=len(rows)-unpriced, unpricedPositions=unpriced,
                inconsistentPositions=sum(r["quality"] == "inconsistent_source" for r in rows),
                missingInputPositions=sum(r["quality"] == "missing_input" for r in rows),
                priorPricePositions=sum(r["priceBasis"] == "previous_adjusted" for r in rows),
                addingPositions=sum(r["action"] in ("new", "increased") for r in rows),
                reducingPositions=sum(r["action"] in ("reduced", "exited") for r in rows),
                newPositions=sum(r["action"] == "new" for r in rows),
                exitedPositions=sum(r["action"] == "exited" for r in rows), valueCoverageComplete=complete)


def aggregate_sectors(source):
    source = sorted((r for r in source if r["reported_action"] != "not_comparable"),
                    key=lambda r: (r["ticker"], r["investorid"]))
    by_ticker = defaultdict(list)
    for row in source:
        by_ticker[row["ticker"]].append(row)
    prices = {}
    for ticker, rows in by_ticker.items():
        prices[ticker] = (reference_price(rows, "current_units", "current_value"),
                          reference_price(rows, "adjusted_previous_units", "previous_value"))
    sectors = defaultdict(list)
    for row in source:
        action = row["reported_action"]
        # Zero only when the complete comparable filing establishes absence.
        curr = 0.0 if action == "exited" else numeric(row["current_units"])
        prev = 0.0 if action == "new" else numeric(row["adjusted_previous_units"])
        value = 0.0 if action == "exited" else numeric(row["current_value"])
        old_value = 0.0 if action == "new" else numeric(row["previous_value"])
        delta = curr - prev if curr is not None and prev is not None else None
        current_price, previous_price = prices[row["ticker"]]
        price = current_price if current_price is not None else previous_price
        basis = "current" if current_price is not None else "previous_adjusted" if previous_price is not None else "unavailable"
        quality = "inconsistent_source" if (inconsistent(curr, value, current_price) or
                  inconsistent(prev, old_value, previous_price)) else "missing_input" if (
                  None in (curr, prev, value, old_value, price)) else "priced"
        proxy = delta * price if quality == "priced" else None
        sectors[row["sector"]].append(dict(
            ticker=row["ticker"], name=row["name"], investorId=row["investorid"],
            investorName=row["investor_name"], industry=row["industry"], action=action,
            currentValueM=value, previousValueM=old_value,
            currentBookValueM=numeric(row["current_book_value"]), previousBookValueM=numeric(row["previous_book_value"]),
            currentUnitsK=curr, previousUnitsK=prev, netUnitsK=delta if quality == "priced" else None,
            addProxyM=max(proxy, 0) if proxy is not None else None,
            trimProxyM=max(-proxy, 0) if proxy is not None else None, priceBasis=basis, quality=quality))
    result = {}
    for sector, rows in sorted(sectors.items()):
        summary = summarize(rows)
        groups = {}
        for kind, key in (("stocks", "ticker"), ("managers", "investorId"), ("industries", "industry")):
            grouped = defaultdict(list)
            for row in rows:
                grouped[row[key]].append(row)
            values = []
            for identity, members in sorted(grouped.items()):
                item = {key: identity, **summarize(members)}
                item["name"] = members[0]["investorName"] if kind == "managers" else members[0]["name"] if kind == "stocks" else identity
                # Stocks/industries: sector share; managers: sector share of their disclosed book.
                denominator = members[0]["currentBookValueM"] if kind == "managers" else summary["currentValueM"]
                previous_denominator = members[0]["previousBookValueM"] if kind == "managers" else summary["previousValueM"]
                item["currentWeight"] = ratio(item["currentValueM"], denominator)
                item["previousWeight"] = ratio(item["previousValueM"], previous_denominator)
                if kind == "stocks":
                    item.update(industry=members[0]["industry"], currentUnitsK=total(members, "currentUnitsK"),
                                previousUnitsK=total(members, "previousUnitsK"), netUnitsK=total(members, "netUnitsK"))
                values.append(item)
            values.sort(key=lambda r: (r["netProxyM"] is None, -abs(r["netProxyM"] or 0), r[key]))
            groups[kind] = [dict(item, rank=i+1) for i, item in enumerate(values)]
        summary.update(stocks=len(groups["stocks"]), managers=len(groups["managers"]))
        result[sector] = dict(version=VERSION, sector=sector, summary=summary, **groups)
    return result


def sector_analysis(con, cte):
    cursor = con.execute(cte + """, listing AS (
      SELECT ticker,name,coalesce(sector,'Unclassified') sector,coalesce(industry,'Unclassified') industry
      FROM tickers WHERE "table"='SF1'
      QUALIFY row_number() OVER(PARTITION BY ticker ORDER BY lastupdated DESC)=1
    ) SELECT j.*, coalesce(l.sector,'Unclassified') sector,coalesce(l.industry,'Unclassified') industry,
      coalesce(l.name,j.ticker) AS name,coalesce(current_investor_name,previous_investor_name,j.investorid) investor_name
      FROM active_joined j LEFT JOIN listing l USING(ticker) WHERE reported_action<>'not_comparable'""")
    columns = [column[0] for column in cursor.description]
    return aggregate_sectors([dict(zip(columns, row)) for row in cursor.fetchall()])
