"""Independent stdlib-only audit; reads bounded inputs, never writes source facts.

Usage: python3 scripts/audit-rule-portfolio-snapshot.py SNAPSHOT PRICE_CSV
Replays share units and fees without importing the JavaScript engine.
"""
import csv
import datetime as dt
import hashlib
import json
import math
import statistics
import sys


def equal(actual, expected, label):
    if not math.isclose(actual, expected, rel_tol=1e-10, abs_tol=1e-10):
        raise ValueError(f"{label}: {actual} != {expected}")


def audit(snapshot_path, prices_path):
    with open(snapshot_path, encoding="utf8") as source:
        snapshot = json.load(source)
    with open(prices_path, "rb") as source:
        digest = hashlib.sha256(source.read()).hexdigest()
    assert digest == snapshot["lineage"]["priceSha256"]
    with open(prices_path, newline="", encoding="utf8") as source:
        rows = list(csv.reader(source))
    prices = {(t, d): float(p) for t, d, p in rows[1:]}
    assert len(prices) == len(rows) - 1
    assert all(math.isfinite(p) and p > 0 for p in prices.values())
    curve = snapshot["backtest"]["curve"]
    reports = []
    for style in snapshot["styles"]:
        key = style["id"]
        executed = {trade["date"] for trade in style["trades"]}
        schedule = {q["executionDate"]: q for q in style["quarters"] if q["executionDate"] in executed}
        for q in style["quarters"]:
            total = sum(math.sqrt(11 - p["rank"]) for p in q["positions"]) if key == "quality_rank" else 1
            for p in q["positions"]:
                expected = min(.15, math.sqrt(11 - p["rank"]) / total) if key == "quality_rank" else .05
                equal(p["weight"], expected, "target weight")
                equal(p["score"], sum(i["percentile"] * i["weight"] for i in p["inputs"]), "score")
            equal(sum(p["weight"] for p in q["positions"]) + q["cashWeight"], 1, "cash bridge")
        cash, fee_factor, positions, replay, turnovers = 1.0, 1.0, [], [], []
        for row in curve:
            day, values = row["date"], {}
            marked_cash = cash
            for ticker, units, action in positions:
                if action and day >= action["effectiveDate"]:
                    if action["considerationType"] == "cash":
                        marked_cash += units * action["terminalCashEntitlementPerShare"]
                        continue
                    assert action["considerationType"] == "stock", "unaudited action kind"
                    ticker, units = action["successorTicker"], units * action["successorSharesPerShare"]
                values[ticker] = values.get(ticker, 0) + units * prices[ticker, day]
            gross = marked_cash + sum(values.values())
            if day in schedule:
                q = schedule[day]
                old = {t: v / gross for t, v in values.items()}
                target = {p["ticker"]: p["weight"] for p in q["positions"]}
                turnover = sum(abs(target.get(t, 0) - old.get(t, 0)) for t in old.keys() | target.keys())
                fee_factor *= 1 - turnover * .0025
                turnovers.append(turnover)
                cash = gross * q["cashWeight"]
                actions = {a["ticker"]: a for a in style["corporateActions"] if a["executionDate"] == day}
                positions = [(t, gross * w / prices[t, day], actions.get(t)) for t, w in target.items()]
            replay.append(gross * fee_factor)
            equal(replay[-1], row[key], f"{key} daily NAV {day}")
        for trade, expected in zip(style["trades"], turnovers, strict=True):
            equal(trade["turnover"], expected, "turnover")
        returns = [b / a - 1 for a, b in zip(replay, replay[1:])]
        elapsed = (dt.date.fromisoformat(curve[-1]["date"]) - dt.date.fromisoformat(curve[0]["date"])).days
        peak, worst = 1.0, 0.0
        for value in replay:
            peak = max(peak, value)
            worst = min(worst, value / peak - 1)
        stdev = statistics.stdev(returns)
        computed = {"totalReturn": replay[-1] - 1, "cagr": replay[-1] ** (365.25 / elapsed) - 1,
                    "maxDrawdown": worst, "volatility": stdev * math.sqrt(252),
                    "sharpeZeroRf": statistics.mean(returns) / stdev * math.sqrt(252)}
        for metric, value in computed.items():
            equal(value, style["metrics"][metric], metric)
        reports.append({"strategy": key, "independentDailyChecks": len(replay), "quarters": len(turnovers), "status": "pass"})
    print(json.dumps({"status": "pass", "sourceWrites": False, "checks": reports}))


if __name__ == "__main__":
    audit(*sys.argv[1:])
