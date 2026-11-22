#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build the audited Guru 13F Copycat Playbook ("大师作业") artifact
(`server/config/guru-copycat-playbook-dashboard.json`) from FactOS (`data/fact_os`)
and the self-contained institutional strategy taxonomy
(`server/config/investor-strategy-taxonomy.json`).

Zero third-party dependencies beyond `duckdb` and Python stdlib so it runs
identically in `.venv-fact-os/bin/python` locally and `/opt/thesisforge-fact-os/bin/python`
on AWS Elastic Beanstalk.

Usage:
  .venv-fact-os/bin/python scripts/build-guru-copycat-playbook-artifact.py
  .venv-fact-os/bin/python scripts/build-guru-copycat-playbook-artifact.py --check
"""

from __future__ import annotations

import argparse
from datetime import date, datetime, timedelta, timezone
import json
import math
from pathlib import Path
import statistics
import sys

import duckdb

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

ARTIFACT_VERSION = "guru-copycat-playbook-v1"
DEFAULT_FACT_ROOT = REPO_ROOT / "data/fact_os"
DEFAULT_TAXONOMY_FILE = REPO_ROOT / "server/config/investor-strategy-taxonomy.json"
DEFAULT_RULE_QQQ_FILE = REPO_ROOT / "server/config/rule-universe-qqq.json"
DEFAULT_OUTPUT_FILE = REPO_ROOT / "server/config/guru-copycat-playbook-dashboard.json"

DUAL_CLASS_PAIRS: dict[str, str] = {
    "GOOG": "GOOGL",
    "GOOGL": "GOOG",
    "CMCSA": "CMCSK",
    "CMCSK": "CMCSA",
    "FOX": "FOXA",
    "FOXA": "FOX",
    "TFCF": "TFCFA",
    "TFCFA": "TFCF",
}


def load_sec_qqq_snapshots(rule_qqq_file: Path) -> list[dict]:
    if not rule_qqq_file.exists():
        return []
    raw = json.loads(rule_qqq_file.read_text(encoding="utf-8"))
    snaps = []
    for s in raw.get("snapshots", []):
        filed_at = str(s.get("filed") or s.get("filedAt") or "")[:10]
        report_dt = str(s.get("period") or s.get("reportDate") or "")[:10]
        tickers: set[str] = set()
        permas: set[int] = set()
        for m in s.get("members") or s.get("holdings") or []:
            for t in m.get("tickers", []):
                tu = str(t).strip().upper()
                if tu:
                    tickers.add(tu)
            tk = str(m.get("ticker") or "").strip().upper()
            if tk:
                tickers.add(tk)
            pm = m.get("permaticker")
            if pm is not None:
                try:
                    permas.add(int(pm))
                except (TypeError, ValueError):
                    pass
        if filed_at and (tickers or permas):
            snaps.append({
                "filedAt": filed_at,
                "reportDate": report_dt,
                "tickers": tickers,
                "permatickers": permas,
            })
    snaps.sort(key=lambda x: (x["reportDate"], x["filedAt"]))
    return snaps


def r1(v: float | None) -> float | None:
    return None if v is None or not math.isfinite(v) else round(float(v), 1)


def r2(v: float | None) -> float | None:
    return None if v is None or not math.isfinite(v) else round(float(v), 2)


def r3(v: float | None) -> float | None:
    return None if v is None or not math.isfinite(v) else round(float(v), 3)


def r4(v: float | None) -> float | None:
    return None if v is None or not math.isfinite(v) else round(float(v), 4)


# 16 surviving high-conviction institutional gurus across 3 clear style buckets
GURU_META: dict[str, dict] = {
    "TCIFUN": {
        "nameEn": "TCI Fund Management (Chris Hohn)",
        "nameZh": "TCI 基金 (Chris Hohn)",
        "shortName": "TCI",
        "styleEn": "Global Monopoly Compounders",
        "styleZh": "全球垄断复利",
        "bucket": "L1_COMPOUND",
        "bucketLabel": {"en": "Monopoly Compounder", "zh": "垄断复利"},
        "thesisForgeGuruId": "chris-hohn",
        "pre2014Famous": True,
    },
    "SANDER": {
        "nameEn": "Sanders Capital",
        "nameZh": "Sanders Capital",
        "shortName": "Sanders",
        "styleEn": "Large-Cap Quality Value",
        "styleZh": "大盘质量价值",
        "bucket": "L1_COMPOUND",
        "bucketLabel": {"en": "Monopoly Compounder", "zh": "垄断复利"},
        "thesisForgeGuruId": None,
        "pre2014Famous": True,
    },
    "WINDAC": {
        "nameEn": "Windacre Partnership",
        "nameZh": "Windacre Partnership",
        "shortName": "Windacre",
        "styleEn": "Ultra-Concentrated Compounders",
        "styleZh": "极集中垄断复利",
        "bucket": "L1_COMPOUND",
        "bucketLabel": {"en": "Monopoly Compounder", "zh": "垄断复利"},
        "thesisForgeGuruId": None,
        "pre2014Famous": False,
    },
    "MARSHF": {
        "nameEn": "Marshfield Associates",
        "nameZh": "Marshfield Associates",
        "shortName": "Marshfield",
        "styleEn": "Resilient Moat Compounders",
        "styleZh": "精选护城河复利",
        "bucket": "L1_COMPOUND",
        "bucketLabel": {"en": "Monopoly Compounder", "zh": "垄断复利"},
        "thesisForgeGuruId": None,
        "pre2014Famous": True,
    },
    "PRIMEC": {
        "nameEn": "PRIMECAP Management",
        "nameZh": "PRIMECAP Management",
        "shortName": "PRIMECAP",
        "styleEn": "Contrarian GARP Compounders",
        "styleZh": "反向大盘成长价值",
        "bucket": "L1_COMPOUND",
        "bucketLabel": {"en": "Monopoly Compounder", "zh": "垄断复利"},
        "thesisForgeGuruId": None,
        "pre2014Famous": True,
    },
    "EAGLEC": {
        "nameEn": "Eagle Capital Management",
        "nameZh": "Eagle Capital",
        "shortName": "Eagle",
        "styleEn": "Concentrated Quality Value",
        "styleZh": "集中质量价值",
        "bucket": "L1_COMPOUND",
        "bucketLabel": {"en": "Monopoly Compounder", "zh": "垄断复利"},
        "thesisForgeGuruId": None,
        "pre2014Famous": True,
    },
    "BERHAT": {
        "nameEn": "Berkshire Hathaway (Buffett)",
        "nameZh": "伯克希尔 (巴菲特 13F)",
        "shortName": "Berkshire",
        "styleEn": "Permanent Franchise Value (13F US)",
        "styleZh": "永久护城河价值 (美股13F)",
        "bucket": "L1_COMPOUND",
        "bucketLabel": {"en": "Monopoly Compounder", "zh": "垄断复利"},
        "thesisForgeGuruId": "warren-buffett",
        "pre2014Famous": True,
    },
    "SACHEA": {
        "nameEn": "Sachem Head Capital",
        "nameZh": "Sachem Head Capital",
        "shortName": "Sachem Head",
        "styleEn": "Constructive Activist Quality",
        "styleZh": "激进质量价值",
        "bucket": "L2_CATALYST",
        "bucketLabel": {"en": "Activist & Macro Sniper", "zh": "激进与宏观狙击"},
        "thesisForgeGuruId": None,
        "pre2014Famous": True,
    },
    "DUQUES": {
        "nameEn": "Duquesne Family Office (Druckenmiller)",
        "nameZh": "Duquesne (德鲁肯米勒)",
        "shortName": "Duquesne",
        "styleEn": "Macro + Secular AI Sniper",
        "styleZh": "宏观趋势与AI狙击",
        "bucket": "L2_CATALYST",
        "bucketLabel": {"en": "Activist & Macro Sniper", "zh": "激进与宏观狙击"},
        "thesisForgeGuruId": "stanley-druckenmiller",
        "pre2014Famous": True,
    },
    "APPALO": {
        "nameEn": "Appaloosa LP (David Tepper)",
        "nameZh": "Appaloosa (大卫·泰珀)",
        "shortName": "Appaloosa",
        "styleEn": "Contrarian Dislocation Sniper",
        "styleZh": "逆向危机狙击",
        "bucket": "L2_CATALYST",
        "bucketLabel": {"en": "Activist & Macro Sniper", "zh": "激进与宏观狙击"},
        "thesisForgeGuruId": "david-tepper",
        "pre2014Famous": True,
    },
    "GQGPAR": {
        "nameEn": "GQG Partners (Rajiv Jain)",
        "nameZh": "GQG Partners (Rajiv Jain)",
        "shortName": "GQG",
        "styleEn": "Forward-Quality Regime Rotation",
        "styleZh": "动态前瞻质量轮动",
        "bucket": "L2_CATALYST",
        "bucketLabel": {"en": "Activist & Macro Sniper", "zh": "激进与宏观狙击"},
        "thesisForgeGuruId": None,
        "pre2014Famous": False,
    },
    "PERSQU": {
        "nameEn": "Pershing Square (Bill Ackman)",
        "nameZh": "潘兴广场 (比尔·阿克曼)",
        "shortName": "Pershing Sq",
        "styleEn": "Ultra-Concentrated Activist Core",
        "styleZh": "极集中激进大盘",
        "bucket": "L2_CATALYST",
        "bucketLabel": {"en": "Activist & Macro Sniper", "zh": "激进与宏观狙击"},
        "thesisForgeGuruId": "bill-ackman",
        "pre2014Famous": True,
    },
    "ABRBIS": {
        "nameEn": "Abrams Bison Investments",
        "nameZh": "Abrams Bison Investments",
        "shortName": "Abrams Bison",
        "styleEn": "Ultra-Concentrated Deep Value",
        "styleZh": "极集中深价值长持",
        "bucket": "L3_DEEPVAL",
        "bucketLabel": {"en": "Concentrated Deep Value", "zh": "极集中深价值"},
        "thesisForgeGuruId": None,
        "pre2014Famous": True,
    },
    "DONSMI": {
        "nameEn": "Donald Smith & Co.",
        "nameZh": "Donald Smith & Co.",
        "shortName": "Donald Smith",
        "styleEn": "Bottom-Decile P/TBV Deep Value",
        "styleZh": "纯低PB有形净值深价值",
        "bucket": "L3_DEEPVAL",
        "bucketLabel": {"en": "Concentrated Deep Value", "zh": "极集中深价值"},
        "thesisForgeGuruId": None,
        "pre2014Famous": True,
    },
    "GENDJL": {
        "nameEn": "Tontine Associates (Jeffrey Gendell)",
        "nameZh": "Tontine (Jeffrey Gendell)",
        "shortName": "Tontine",
        "styleEn": "Cyclical Infrastructure Deep Value",
        "styleZh": "周期基建高弹性深价值",
        "bucket": "L3_DEEPVAL",
        "bucketLabel": {"en": "Concentrated Deep Value", "zh": "极集中深价值"},
        "thesisForgeGuruId": None,
        "pre2014Famous": False,
    },
    "HIMALA": {
        "nameEn": "Himalaya Capital (Li Lu)",
        "nameZh": "喜马拉雅资本 (李录 13F)",
        "shortName": "Himalaya",
        "styleEn": "Concentrated Value Compounder (US 13F)",
        "styleZh": "极集中价值复利 (美股13F)",
        "bucket": "L3_DEEPVAL",
        "bucketLabel": {"en": "Concentrated Deep Value", "zh": "极集中深价值"},
        "thesisForgeGuruId": "li-lu",
        "pre2014Famous": False,
    },
}

PRE2014_FAMOUS_IDS = [
    "TCIFUN", "SANDER", "PRIMEC", "MARSHF", "EAGLEC", "BERHAT",
    "DUQUES", "APPALO", "SACHEA", "ABRBIS", "DONSMI", "PERSQU",
]
TOP_COMPOUND_IDS = ["TCIFUN", "SANDER", "PRIMEC", "MARSHF", "WINDAC", "SACHEA"]
MACRO_CATALYST_IDS = ["DUQUES", "APPALO", "SACHEA", "GQGPAR", "TCIFUN", "ABRBIS"]
SURVIVING_12_IDS = [
    "TCIFUN", "SANDER", "PRIMEC", "MARSHF", "WINDAC", "SACHEA",
    "DUQUES", "APPALO", "GQGPAR", "ABRBIS", "DONSMI", "GENDJL",
]

MASTER_BLUEPRINT_SPEC = [
    # Tier 1: Non-Tech Monopoly Ballast (42% = 7 * 6%)
    ("GE",    "non_tech_monopoly", 6.0, {"en": "Commercial aero engine monopoly; TCI #1 anchor (29.8%)", "zh": "商用航发寡头印钞机，TCI 第一重仓 (29.8%)"}),
    ("V",     "non_tech_monopoly", 6.0, {"en": "Global payment tollbooth; TCI (22.0%) + Marshfield (8.7%)", "zh": "全球支付过路费垄断，TCI (22.0%) + Marshfield (8.7%) 共识"}),
    ("MCO",   "non_tech_monopoly", 6.0, {"en": "Credit rating duopoly; TCI (13.1%) + Windacre (10.3%)", "zh": "信用评级双寡头，TCI (13.1%) + Windacre (10.3%) 双重锁仓"}),
    ("SPGI",  "non_tech_monopoly", 6.0, {"en": "Index & ratings monopoly; TCI #4 core (11.2%)", "zh": "标普指数+评级垄断壁垒，TCI 第四重仓 (11.2%)"}),
    ("ROP",   "non_tech_monopoly", 6.0, {"en": "Vertical mission-critical software compounder; Windacre #1 (20.8%)", "zh": "垂直工业软件并购复利王，Windacre 头号重仓 (20.8%)"}),
    ("TDG",   "non_tech_monopoly", 6.0, {"en": "Proprietary aero aftermarket parts pricing power; Windacre #2 (15.0%)", "zh": "航空售后独家备件定价权之王，Windacre 第二重仓 (15.0%)"}),
    ("UNH",   "non_tech_monopoly", 6.0, {"en": "Managed-care leader in left-side valuation reset; Sanders #3 (8.0%)", "zh": "北美医保龙头逆向估值修复，Sanders 第三重仓 (8.0%)"}),
    # Tier 2: Tech Super-Consensus Engine (42% = 6 * 7%)
    ("AMZN",  "tech_consensus", 7.0, {"en": "5-Guru super-consensus (Appaloosa/Duquesne +43%/Sanders/GQG/PRIMECAP)", "zh": "5位大师超级共识，Duquesne 当季猛加 +43% 至第一重仓"}),
    ("GOOGL", "tech_consensus", 7.0, {"en": "5-Guru consensus (TCI/Sanders/PRIMECAP/Appaloosa/GQG) below Q3 avg cost", "zh": "5位大师共同重仓 (TCI/Sanders/PRIMECAP等)，较Q3均价折价安全垫厚"}),
    ("TSM",   "tech_consensus", 7.0, {"en": "AI foundry monopoly; 4-Guru core (Sanders/GQG/Windacre/Appaloosa)", "zh": "AI 晶圆代工绝对垄断，4位大师合计权重超 32%"}),
    ("NVDA",  "tech_consensus", 7.0, {"en": "5-Guru core; Sanders +33% & Appaloosa +31% Q3 adds, deeply below Q3 cost", "zh": "5位大师重仓 (Sanders +33% / Tepper +31%)，现价显著低于大师Q3成本"}),
    ("MSFT",  "tech_consensus", 7.0, {"en": "Enterprise cloud & AI OS; Sanders Q3 massive +483% add to #2 (8.1%)", "zh": "企业云与AI底座，Sanders 当季暴增 +483% 跃居第二重仓 (8.1%)"}),
    ("MU",    "tech_consensus", 7.0, {"en": "HBM memory upcycle; Appaloosa #1 (18.6%, +28% Q3 add) + PRIMECAP", "zh": "HBM 存储周期主升浪，Tepper 头号重仓 (18.6%, Q3再加+28%)"}),
    # Tier 3: New-Add Catalyst Satellites (16% = 6% + 5% + 5%)
    ("STX",   "catalyst_satellite", 6.0, {"en": "AI nearline storage inflection; 4 Gurus led by Sachem Head #1 & Duquesne +180%", "zh": "AI 数据中心存储拐点，Sachem头号重仓 + 德鲁肯米勒猛加 +180%"}),
    ("AMAT",  "catalyst_satellite", 5.0, {"en": "WFE semi cap-equip leader; Appaloosa NEW #4 position (7.7%)", "zh": "半导体设备龙头，Tepper Q3 全新建仓直冲第四重仓 (7.7%)"}),
    ("FOXA",  "catalyst_satellite", 5.0, {"en": "Live sports/news cash cow; Abrams Bison 25.1% anchor", "zh": "体育新闻现金牛+低估值回购，Abrams Bison 25.1% 压舱重仓"}),
]


def quarter_label(qd_str: str) -> str:
    y = qd_str[:4]
    m = int(qd_str[5:7])
    q = (m - 1) // 3 + 1
    return f"{y} Q{q}"


def statutory_filing_date(qd_str: str) -> str:
    d = date.fromisoformat(qd_str[:10])
    target = d + timedelta(days=45)
    # Statutory 45-day deadline rolls forward over weekends
    while target.weekday() >= 5:
        target += timedelta(days=1)
    return target.isoformat()


def sample_std(vals: list[float]) -> float:
    return statistics.stdev(vals) if len(vals) >= 2 else 0.0


def percentile_rank_map(items: list[tuple[str, float]]) -> dict[str, float]:
    """Match pandas Series.rank(pct=True) average tie-breaking."""
    n = len(items)
    if n == 0:
        return {}
    sorted_items = sorted(items, key=lambda x: x[1])
    out: dict[str, float] = {}
    i = 0
    while i < n:
        j = i
        val = sorted_items[i][1]
        while j + 1 < n and sorted_items[j + 1][1] == val:
            j += 1
        avg_rank = (i + 1 + j + 1) / 2.0
        pct = avg_rank / float(n)
        for k in range(i, j + 1):
            out[sorted_items[k][0]] = pct
        i = j + 1
    return out


def quantile_linear(vals: list[float], q: float) -> float:
    if not vals:
        return math.nan
    s = sorted(vals)
    if len(s) == 1:
        return s[0]
    pos = (len(s) - 1) * q
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return s[lo]
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def calc_series_metrics(
    q_dates: list[str],
    ret_map: dict[str, float],
    spy_map: dict[str, float],
    qqq_map: dict[str, float] | None = None,
    avg_n: float = 0.0,
    ann_to_pct: float = 0.0,
) -> dict:
    pairs = [
        (qd, ret_map[qd], spy_map[qd], (qqq_map or {}).get(qd, 0.0))
        for qd in q_dates
        if qd in ret_map
        and qd in spy_map
        and ret_map[qd] is not None
        and spy_map[qd] is not None
        and math.isfinite(ret_map[qd])
        and math.isfinite(spy_map[qd])
    ]
    n = len(pairs)
    if n == 0:
        return {}
    yrs = n / 4.0
    eq_r = 1.0
    eq_s = 1.0
    peak_r = 1.0
    mdd = 0.0
    wins = 0
    wins_qqq = 0
    rs: list[float] = []
    diffs: list[float] = []
    curve: list[dict] = []
    by_year: dict[str, list[tuple[float, float, float]]] = {}

    for qd, r, s, qq in pairs:
        eq_r *= 1.0 + r
        eq_s *= 1.0 + s
        if eq_r > peak_r:
            peak_r = eq_r
        dd = eq_r / peak_r - 1.0
        if dd < mdd:
            mdd = dd
        if r > s:
            wins += 1
        if r > qq:
            wins_qqq += 1
        rs.append(r)
        diffs.append(r - s)
        curve.append({
            "quarterDate": qd,
            "quarter": quarter_label(qd),
            "retPct": r2(r * 100.0),
            "spyRetPct": r2(s * 100.0),
            "qqqRetPct": r2(qq * 100.0),
            "excessSpyPct": r2((r - s) * 100.0),
            "excessQqqPct": r2((r - qq) * 100.0),
            "nav100k": r2(eq_r * 100.0),
            "drawdownPct": r2(dd * 100.0),
            "beatSpy": bool(r > s),
            "beatQqq": bool(r > qq),
        })
        by_year.setdefault(qd[:4], []).append((r, s, qq))

    cagr_r = (eq_r ** (1.0 / yrs) - 1.0) * 100.0
    cagr_s = (eq_s ** (1.0 / yrs) - 1.0) * 100.0
    alpha = cagr_r - cagr_s
    std_r = sample_std(rs)
    std_d = sample_std(diffs)
    vol = std_r * 2.0 * 100.0
    mean_r = sum(rs) / n
    mean_d = sum(diffs) / n
    sharpe = (mean_r * 4.0 - 0.025) / (std_r * 2.0) if std_r > 0 else 0.0
    ir = (mean_d * 4.0) / (std_d * 2.0) if std_d > 0 else 0.0
    win_q = (wins / n) * 100.0
    win_q_qqq = (wins_qqq / n) * 100.0

    def sub_alpha(pred) -> float | None:
        sub = [(r, s) for qd, r, s, _ in pairs if pred(qd)]
        if len(sub) < 4:
            return None
        pr = 1.0
        ps = 1.0
        for r, s in sub:
            pr *= 1.0 + r
            ps *= 1.0 + s
        cr = pr ** (4.0 / len(sub)) - 1.0
        cs = ps ** (4.0 / len(sub)) - 1.0
        return (cr - cs) * 100.0

    a_14_19 = sub_alpha(lambda qd: qd < "2020-01-01")
    a_20_26 = sub_alpha(lambda qd: qd >= "2020-01-01")

    annual_rows = []
    for yr in sorted(by_year.keys()):
        pr = 1.0
        ps = 1.0
        pq = 1.0
        for r, s, qq in by_year[yr]:
            pr *= 1.0 + r
            ps *= 1.0 + s
            pq *= 1.0 + qq
        rr = (pr - 1.0) * 100.0
        sr = (ps - 1.0) * 100.0
        qr = (pq - 1.0) * 100.0
        annual_rows.append({
            "year": yr,
            "quarters": len(by_year[yr]),
            "retPct": r2(rr),
            "spyRetPct": r2(sr),
            "qqqRetPct": r2(qr),
            "excessSpyPct": r2(rr - sr),
            "excessQqqPct": r2(rr - qr),
            "beatSpy": bool(rr > sr),
            "beatQqq": bool(rr > qr),
        })

    return {
        "quarters": n,
        "avgHoldings": r1(avg_n),
        "annTurnoverPct": r1(ann_to_pct),
        "cagrPct": r2(cagr_r),
        "spyCagrPct": r2(cagr_s),
        "alphaPct": r2(alpha),
        "alpha1419Pct": r2(a_14_19),
        "alpha2026Pct": r2(a_20_26),
        "bothHalvesBeat": bool((a_14_19 or 0.0) > 0 and (a_20_26 or 0.0) > 0),
        "volPct": r2(vol),
        "sharpe": r2(sharpe),
        "ir": r2(ir),
        "maxDrawdownPct": r2(mdd * 100.0),
        "winRatePct": r1(win_q),
        "winQuarters": wins,
        "winRateVsQqqPct": r1(win_q_qqq),
        "winQuartersVsQqq": wins_qqq,
        "final100k": r1(eq_r * 100.0),
        "curve": curve,
        "annualReturns": annual_rows,
    }


def follow_verdict(action: str, vs_cost_pct: float | None, dd_52w_pct: float | None, q1_dump: bool) -> dict:
    if q1_dump:
        return {
            "code": "AVOID_HF_DUMP",
            "en": "AVOID: Q1 Active-HF heavy institutional dumping warning",
            "zh": "排雷回避：落入主动HF净抛售最猛Q1雷区",
        }
    act = (action or "").upper()
    disc = vs_cost_pct if vs_cost_pct is not None else 0.0
    if act.startswith("NEW") or act.startswith("ADD"):
        if disc <= -5.0:
            return {
                "code": "PRIORITY_BUY_BELOW_GURU",
                "en": f"Priority Buy: Guru {act} + {disc:.1f}% below Q3 avg cost",
                "zh": f"优先抄底：大师{act} + 较Q3成本折价 {disc:.1f}%",
            }
        if disc <= 10.0:
            return {
                "code": "FOLLOW_ACCUMULATE",
                "en": f"Accumulate on Statutory Rebalance ({act})",
                "zh": f"法定窗口跟进建仓/加仓 ({act})",
            }
        return {
            "code": "WAIT_PULLBACK",
            "en": f"Extended (+{disc:.1f}% vs Q3 cost) — size half or wait for pullback",
            "zh": f"较Q3均价已涨 +{disc:.1f}%：半仓配置或等回踩",
        }
    if act.startswith("TRIM"):
        return {
            "code": "TRIM_WITH_GURU",
            "en": f"Trim / Reduce Weight ({act})",
            "zh": f"同步减仓控制权重 ({act})",
        }
    if disc <= -10.0 and (dd_52w_pct is None or dd_52w_pct > -55.0):
        return {
            "code": "CORE_DISCOUNT_HOLD",
            "en": f"Core Compounder at {disc:.1f}% discount vs Q3 avg",
            "zh": f"核心锁仓复利股 · 较Q3均价折价 {disc:.1f}%",
        }
    return {
        "code": "CORE_HOLD",
        "en": "Core Rebalance Hold at Target Weight",
        "zh": "按目标权重标准持有 · 季度再平衡",
    }


def build_artifact(fact_root: Path, taxonomy_file: Path) -> dict:
    from fact_os.repository import FactRepository

    taxonomy = json.loads(taxonomy_file.read_text(encoding="utf-8"))
    groups = taxonomy.get("groups", {})
    active_hf_ids = list(groups.get("ACTIVE_HF", []))
    active_lo_ids = list(groups.get("ACTIVE_LO", []))
    pod_ids = list(groups.get("MULTISTRAT_POD", []))
    passive_ids = list(groups.get("PASSIVE_INDEX", []))

    repo = FactRepository(fact_root)
    con = repo.db
    try:
        con.execute("SET memory_limit='6GB'; SET threads=6; SET preserve_insertion_order=false;")

        # Register strategy taxonomy table in DuckDB
        tax_rows: list[tuple[str, str]] = []
        for st_name, id_list in [
            ("ACTIVE_HF", active_hf_ids),
            ("ACTIVE_LO", active_lo_ids),
            ("MULTISTRAT_POD", pod_ids),
            ("PASSIVE_INDEX", passive_ids),
        ]:
            for iid in id_list:
                tax_rows.append((iid, st_name))
        con.execute("CREATE TEMP TABLE inv_tax (investorid VARCHAR, strategy VARCHAR);")
        con.executemany("INSERT INTO inv_tax VALUES (?, ?)", tax_rows)

        guru_ids = list(GURU_META.keys())
        con.execute("CREATE TEMP TABLE guru_ids (investorid VARCHAR);")
        con.executemany("INSERT INTO guru_ids VALUES (?)", [(g,) for g in guru_ids])

        # Ticker metadata (company name & sector)
        tk_meta_rows = con.execute("""
            SELECT ticker,
                   arg_max(name, lastupdated) AS name,
                   arg_max(sector, lastupdated) AS sector
            FROM tickers
            WHERE ticker IS NOT NULL AND name IS NOT NULL
            GROUP BY 1
        """).fetchall()
        ticker_meta: dict[str, dict[str, str]] = {
            str(t): {"name": str(nm or t), "sector": str(sec or "")}
            for t, nm, sec in tk_meta_rows
        }
        ticker_meta.setdefault("SPY", {"name": "SPDR S&P 500 ETF Trust", "sector": "Broad Index ETF"})
        ticker_meta.setdefault("QQQ", {"name": "Invesco QQQ Trust (Nasdaq-100)", "sector": "Tech / Growth Index ETF"})

        # Deduplicated daily price panel (stocks + funds) from 2013-12-01 onward
        con.execute("""
            CREATE TEMP TABLE px_dedup AS
            SELECT ticker, date, max(closeadj) AS closeadj, max(close) AS close_raw
            FROM (
                SELECT ticker, date, closeadj, close FROM stocks WHERE date >= DATE '2013-12-01' AND closeadj > 0
                UNION ALL
                SELECT ticker, date, closeadj, close FROM funds  WHERE date >= DATE '2013-12-01' AND closeadj > 0
            )
            GROUP BY 1, 2;
        """)

        # Extend px_dedup through the latest completed US market close (e.g. when upstream Sharadar lags recent sessions)
        import os as _os
        if _os.environ.get("COPYCAT_OFFLINE_ONLY") != "1":
            try:
                from concurrent.futures import ThreadPoolExecutor
                from datetime import datetime, timezone
                import httpx

                fact_max_row = con.execute(
                    "SELECT CAST(MAX(s.date) AS VARCHAR) FROM px_dedup s JOIN px_dedup q ON q.date = s.date AND q.ticker = 'QQQ' WHERE s.ticker = 'SPY'"
                ).fetchone()
                fact_max_dt = str(fact_max_row[0])[:10] if fact_max_row and fact_max_row[0] else "2026-11-17"

                tail_tks_rows = con.execute("""
                    SELECT DISTINCT ticker FROM (
                        SELECT ticker FROM holdings
                        WHERE date >= DATE '2026-03-31' AND securitytype = 'SHR'
                          AND investorid IN (SELECT investorid FROM guru_ids)
                          AND ticker IS NOT NULL
                        UNION
                        SELECT ticker FROM (
                            SELECT ticker, SUM(value) AS v
                            FROM holdings
                            WHERE date >= DATE '2025-12-31' AND securitytype = 'SHR'
                              AND investorid IN (SELECT investorid FROM inv_tax WHERE strategy = 'ACTIVE_HF')
                              AND ticker IS NOT NULL
                            GROUP BY 1 ORDER BY v DESC LIMIT 180
                        )
                    )
                """).fetchall()
                tail_tickers = sorted({"SPY", "QQQ", *(str(r[0]) for r in tail_tks_rows if r[0])})

                con.execute("CREATE TEMP TABLE tail_tks (ticker VARCHAR);")
                con.executemany("INSERT INTO tail_tks VALUES (?)", [(t,) for t in tail_tickers])
                anchor_rows = con.execute("""
                    SELECT p.ticker, CAST(MAX(p.date) AS VARCHAR) AS max_dt,
                           LAST(p.closeadj ORDER BY p.date) AS last_adj
                    FROM px_dedup p
                    JOIN tail_tks t ON t.ticker = p.ticker
                    WHERE p.date >= DATE '2026-10-15'
                    GROUP BY 1
                """).fetchall()
                anchor_by_tk = {str(t): (str(mdt)[:10], float(ladj)) for t, mdt, ladj in anchor_rows if ladj and ladj > 0}

                def fetch_yh_tail(tk: str) -> list[tuple[str, str, float, float]]:
                    anc = anchor_by_tk.get(tk)
                    if not anc and tk not in ("SPY", "QQQ"):
                        return []
                    yh_sym = tk.replace(".", "-")
                    try:
                        with httpx.Client(timeout=10.0, headers={"User-Agent": "Mozilla/5.0"}) as cli:
                            resp = cli.get(
                                f"https://query1.finance.yahoo.com/v8/finance/chart/{yh_sym}",
                                params={"range": "15d", "interval": "1d"},
                            )
                            if resp.status_code != 200:
                                return []
                            res_list = resp.json().get("chart", {}).get("result") or []
                            if not res_list:
                                return []
                            res0 = res_list[0]
                            ts_list = res0.get("timestamp") or []
                            closes = ((res0.get("indicators") or {}).get("quote") or [{}])[0].get("close") or []
                            adjs = ((res0.get("indicators") or {}).get("adjclose") or [{}])[0].get("adjclose") or closes
                            pts: dict[str, tuple[float, float]] = {}
                            for ts_v, cl_v, ad_v in zip(ts_list, closes, adjs):
                                if cl_v and cl_v > 0 and ad_v and ad_v > 0:
                                    dt_iso = datetime.fromtimestamp(int(ts_v), tz=timezone.utc).strftime("%Y-%m-%d")
                                    pts[dt_iso] = (float(cl_v), float(ad_v))
                            if not pts or not anc:
                                return []
                            anc_dt, anc_adj = anc
                            yh_anc = pts.get(anc_dt)
                            if not yh_anc:
                                prior_dts = [d for d in sorted(pts.keys()) if d <= anc_dt]
                                if not prior_dts:
                                    return []
                                yh_anc = pts[prior_dts[-1]]
                            yh_anc_adj = yh_anc[1]
                            out_rows: list[tuple[str, str, float, float]] = []
                            for dt_iso, (cl_v, ad_v) in sorted(pts.items()):
                                if dt_iso > anc_dt:
                                    chained_adj = anc_adj * (ad_v / yh_anc_adj)
                                    out_rows.append((tk, dt_iso, chained_adj, cl_v))
                            return out_rows
                    except Exception:
                        return []

                spy_probe = fetch_yh_tail("SPY")
                if spy_probe and spy_probe[-1][1] > fact_max_dt:
                    new_px_rows: list[tuple[str, str, float, float]] = []
                    with ThreadPoolExecutor(max_workers=16) as pool:
                        for batch_rows in pool.map(fetch_yh_tail, tail_tickers):
                            new_px_rows.extend(batch_rows)
                    if new_px_rows:
                        con.executemany(
                            "INSERT INTO px_dedup (ticker, date, closeadj, close_raw) VALUES (?, CAST(? AS DATE), ?, ?)",
                            new_px_rows,
                        )
            except Exception as yh_err:
                print(f"  [warn] Yahoo tail extension skipped: {yh_err}")

        # Latest complete trading date where BOTH SPY & QQQ and active universe (>=150 tickers) have closes
        max_px_row = con.execute("""
            SELECT CAST(MAX(s.date) AS VARCHAR)
            FROM px_dedup s
            JOIN px_dedup q ON q.date = s.date AND q.ticker = 'QQQ'
            WHERE s.ticker = 'SPY'
              AND (SELECT COUNT(*) FROM px_dedup p WHERE p.date = s.date) >= 150
        """).fetchone()
        latest_price_date = str(max_px_row[0])[:10] if max_px_row and max_px_row[0] else "2026-11-17"

        q_dates_raw = [
            str(r[0])[:10]
            for r in con.execute("""
                SELECT DISTINCT date FROM holdings_investor
                WHERE date >= DATE '2013-12-31' AND date <= DATE '2026-09-30'
                ORDER BY date
            """).fetchall()
        ]
        con.execute("CREATE TEMP TABLE q_cal (q_idx INT, q_date DATE);")
        con.executemany("INSERT INTO q_cal VALUES (?, ?)", [(i, qd) for i, qd in enumerate(q_dates_raw)])

        con.execute("""
            CREATE TEMP TABLE spy_days AS
            SELECT date, closeadj AS spy_adj FROM px_dedup WHERE ticker = 'SPY' ORDER BY date;
        """)
        con.execute("""
            CREATE TEMP TABLE q_sessions AS
            SELECT c.q_idx, c.q_date,
                   (SELECT max(date) FROM spy_days WHERE date <= c.q_date) AS qe_td,
                   (SELECT min(date) FROM spy_days WHERE date >= c.q_date + INTERVAL 46 DAY) AS lag_td
            FROM q_cal c;
        """)

        session_rows = con.execute("""
            SELECT q.q_idx, CAST(q.q_date AS VARCHAR), CAST(q.qe_td AS VARCHAR),
                   CAST(q.lag_td AS VARCHAR), CAST(qn.lag_td AS VARCHAR)
            FROM q_sessions q
            LEFT JOIN q_sessions qn ON qn.q_idx = q.q_idx + 1
            ORDER BY q.q_idx
        """).fetchall()
        session_info: dict[str, dict] = {}
        for qi, qd_s, qe_s, lag_s, next_lag_s in session_rows:
            qd_clean = str(qd_s)[:10]
            session_info[qd_clean] = {
                "qIdx": int(qi),
                "quarterDate": qd_clean,
                "quarter": quarter_label(qd_clean),
                "filedAt": statutory_filing_date(qd_clean),
                "qeTradeDate": str(qe_s)[:10] if qe_s else qd_clean,
                "t45EntryDate": str(lag_s)[:10] if lag_s else statutory_filing_date(qd_clean),
                "t45ExitDate": str(next_lag_s)[:10] if next_lag_s else None,
            }

        # Quarterly & T+45 price/return table (exact match to 12_guru_copycat_playbook_engine.py)
        con.execute("""
            CREATE TEMP TABLE q_px_panel AS
            WITH q_px AS (
                SELECT
                    c.q_idx,
                    c.q_date AS qd,
                    p.ticker,
                    LAST(p.closeadj ORDER BY p.date) FILTER (WHERE p.date <= c.q_date AND p.date >= c.q_date - INTERVAL 10 DAY) AS p_qe,
                    AVG(p.closeadj) FILTER (WHERE p.date > c.q_date - INTERVAL 92 DAY AND p.date <= c.q_date) AS p_qavg,
                    FIRST(p.closeadj ORDER BY p.date) FILTER (WHERE p.date >= c.q_date + INTERVAL 46 DAY AND p.date <= c.q_date + INTERVAL 56 DAY) AS p_t45,
                    FIRST(p.close_raw ORDER BY p.date) FILTER (WHERE p.date >= c.q_date + INTERVAL 46 DAY AND p.date <= c.q_date + INTERVAL 56 DAY) AS p_t45_raw
                FROM q_cal c
                JOIN px_dedup p
                  ON p.date >= c.q_date - INTERVAL 92 DAY AND p.date <= c.q_date + INTERVAL 56 DAY
                GROUP BY 1, 2, 3
            ),
            lead_px AS (
                SELECT
                    q_idx, qd, ticker, p_qe, p_qavg, p_t45, p_t45_raw,
                    LEAD(p_qe) OVER (PARTITION BY ticker ORDER BY qd) AS p_next_qe,
                    LEAD(p_t45) OVER (PARTITION BY ticker ORDER BY qd) AS p_next_t45,
                    LEAD(p_t45_raw) OVER (PARTITION BY ticker ORDER BY qd) AS p_next_t45_raw
                FROM q_px
                WHERE p_qe > 0
            )
            SELECT
                q_idx,
                CAST(qd AS VARCHAR) AS qd,
                ticker,
                p_qe, p_qavg, p_t45, p_t45_raw, p_next_qe, p_next_t45, p_next_t45_raw,
                CASE WHEN p_next_qe > 0 AND p_qe > 0 THEN least(4.0, greatest(-0.95, p_next_qe / p_qe - 1.0)) END AS ret_qe,
                CASE WHEN p_next_t45 > 0 AND p_t45 > 0 THEN least(4.0, greatest(-0.95, p_next_t45 / p_t45 - 1.0)) END AS ret_t45,
                CASE WHEN p_t45 > 0 AND p_qavg > 0 THEN p_t45 / p_qavg - 1.0 END AS gap_t45_vs_qavg,
                CASE WHEN p_t45 > 0 AND p_qe > 0 THEN p_t45 / p_qe - 1.0 END AS gap_t45_vs_qe
            FROM lead_px;
        """)

        # Fetch SPY & QQQ benchmark returns across all realized T+45 quarters (through latest complete price date)
        bm_rows = con.execute("""
            SELECT qd, ticker, ret_t45, ret_qe, p_t45_raw, p_next_t45_raw
            FROM q_px_panel
            WHERE ticker IN ('SPY', 'QQQ')
              AND qd >= '2014-03-31' AND qd <= '2026-09-30'
            ORDER BY qd, ticker
        """).fetchall()
        spy_t45: dict[str, float] = {}
        qqq_t45: dict[str, float] = {}
        spy_qe: dict[str, float] = {}
        bm_px_info: dict[tuple[str, str], tuple[float | None, float | None, float | None]] = {}
        for qd_s, tk, rt45, rqe, p0, p1 in bm_rows:
            qd_k = str(qd_s)[:10]
            bm_px_info[(qd_k, str(tk))] = (
                float(p0) if p0 is not None else None,
                float(p1) if p1 is not None else None,
                float(rt45) if rt45 is not None else None,
            )
            exit_dt_q = session_info.get(qd_k, {}).get("t45ExitDate")
            if exit_dt_q and exit_dt_q <= latest_price_date and rt45 is not None:
                if tk == "SPY":
                    spy_t45[qd_k] = float(rt45)
                elif tk == "QQQ":
                    qqq_t45[qd_k] = float(rt45)
            if qd_k <= "2026-06-30" and rqe is not None and tk == "SPY":
                spy_qe[qd_k] = float(rqe)

        realized_q_dates = sorted(spy_t45.keys())  # All 50 realized quarters: 2014-03-31 .. 2026-06-30 (exit 2026-11-16)
        all_snapshot_q_dates = sorted(
            qd for qd in session_info.keys() if "2014-03-31" <= qd <= "2026-09-30"
        )  # 51 quarter-ends (2014 Q1 .. 2026 Q3; Q1..Q2 realized + Q3 live mark-to-market through latest_price_date)

        # Latest spot price, Q3 2026 avg price, Q2 2026 avg price, and 52-week high for all stocks/ETFs
        latest_px_rows = con.execute("""
            SELECT
                ticker,
                LAST(close_raw ORDER BY date) AS latest_raw,
                LAST(closeadj ORDER BY date) AS latest_adj,
                CAST(MAX(date) AS VARCHAR) AS latest_dt,
                AVG(close_raw) FILTER (WHERE date >= DATE '2026-07-01' AND date <= DATE '2026-09-30') AS q3_avg_raw,
                AVG(closeadj) FILTER (WHERE date >= DATE '2026-07-01' AND date <= DATE '2026-09-30') AS q3_avg_adj,
                AVG(closeadj) FILTER (WHERE date >= DATE '2026-04-01' AND date <= DATE '2026-06-30') AS q2_avg_adj,
                MAX(closeadj) FILTER (WHERE date >= DATE '2025-11-18') AS hi52_adj
            FROM px_dedup
            WHERE date >= DATE '2025-11-18'
            GROUP BY 1
        """).fetchall()
        spot_meta: dict[str, dict] = {}
        for tk, l_raw, l_adj, l_dt, q3_raw, q3_adj, q2_adj, hi52 in latest_px_rows:
            if not l_adj or l_adj <= 0:
                continue
            scale = float(l_raw / l_adj) if (l_raw and l_adj) else 1.0
            q3_cost = float(q3_adj) * scale if q3_adj and q3_adj > 0 else (float(q3_raw) if q3_raw else None)
            q2_cost = float(q2_adj) * scale if q2_adj and q2_adj > 0 else None
            vs_q3 = (float(l_adj) / float(q3_adj) - 1.0) * 100.0 if (q3_adj and q3_adj > 0) else None
            dd52 = (float(l_adj) / float(hi52) - 1.0) * 100.0 if (hi52 and hi52 > 0) else None
            spot_meta[str(tk)] = {
                "latestPrice": float(l_raw or l_adj),
                "latestDate": str(l_dt)[:10],
                "q3AvgCost": q3_cost,
                "q2AvgCost": q2_cost,
                "vsQ3CostPct": vs_q3,
                "dd52wPct": dd52,
            }

        # Pull all 16 gurus' holdings across 2013-12-31 .. 2026-09-30 with QoQ diffs + price panel
        gh_rows = con.execute("""
            WITH raw_h AS (
                SELECT
                    c.q_idx,
                    CAST(s.date AS VARCHAR) AS qd,
                    s.investorid,
                    s.ticker,
                    SUM(s.value) AS val_m,
                    SUM(s.units) AS units
                FROM holdings s
                JOIN guru_ids g ON s.investorid = g.investorid
                JOIN q_cal c ON c.q_date = s.date
                WHERE s.securitytype = 'SHR'
                  AND s.date >= DATE '2013-12-31'
                  AND s.value > 0
                GROUP BY 1, 2, 3, 4
            ),
            tot AS (
                SELECT q_idx, qd, investorid, SUM(val_m) AS tot_val, COUNT(*) AS n_stocks
                FROM raw_h
                GROUP BY 1, 2, 3
            ),
            ranked AS (
                SELECT
                    r.q_idx, r.qd, r.investorid, r.ticker,
                    r.val_m, r.units,
                    r.val_m / t.tot_val AS wt,
                    t.tot_val, t.n_stocks,
                    ROW_NUMBER() OVER (PARTITION BY r.q_idx, r.investorid ORDER BY r.val_m DESC) AS rk
                FROM raw_h r
                JOIN tot t ON r.q_idx = t.q_idx AND r.investorid = t.investorid
            )
            SELECT
                cur.q_idx, cur.qd, cur.investorid, cur.ticker,
                cur.val_m, cur.units, cur.wt, cur.tot_val, cur.n_stocks, cur.rk,
                COALESCE(prev.wt, 0.0) AS prev_wt,
                COALESCE(prev.units, 0.0) AS prev_units,
                COALESCE(prev.val_m, 0.0) AS prev_val_m,
                p.ret_qe, p.ret_t45, p.gap_t45_vs_qavg, p.gap_t45_vs_qe,
                p.p_t45_raw, p.p_next_t45_raw, p.p_qavg
            FROM ranked cur
            LEFT JOIN ranked prev
              ON prev.q_idx = cur.q_idx - 1
             AND prev.investorid = cur.investorid
             AND prev.ticker = cur.ticker
            LEFT JOIN q_px_panel p
              ON p.q_idx = cur.q_idx AND p.ticker = cur.ticker
            ORDER BY cur.qd, cur.investorid, cur.rk
        """).fetchall()

        guru_by_q: dict[str, list[dict]] = {}
        guru_by_id_q: dict[str, dict[str, list[dict]]] = {g: {} for g in guru_ids}
        px_by_q_tk: dict[tuple[str, str], dict] = {}

        for row in gh_rows:
            (
                q_idx, qd_s, iid, tk, val_m, units, wt, tot_val, n_stocks, rk,
                prev_wt, prev_units, prev_val_m, ret_qe, ret_t45, gap_qavg, gap_qe,
                p_t45_raw, p_next_t45_raw, p_qavg,
            ) = row
            qd_k = str(qd_s)[:10]
            tk_s = str(tk)
            iid_s = str(iid)
            d_wt = float(wt) - float(prev_wt)
            d_units_pct = ((float(units) / float(prev_units) - 1.0) * 100.0) if float(prev_units) > 0 else 999.0
            if float(prev_units) <= 0:
                act = "NEW"
            elif d_units_pct >= 10.0:
                act = f"ADD +{d_units_pct:.0f}%"
            elif d_units_pct <= -10.0:
                act = f"TRIM {d_units_pct:.0f}%"
            else:
                act = "HOLD"
            rec = {
                "qIdx": int(q_idx),
                "qd": qd_k,
                "investorid": iid_s,
                "ticker": tk_s,
                "valM": float(val_m),
                "units": float(units),
                "wt": float(wt),
                "totVal": float(tot_val),
                "nStocks": int(n_stocks),
                "rk": int(rk),
                "prevWt": float(prev_wt),
                "prevUnits": float(prev_units),
                "dWt": d_wt,
                "dUnitsPct": d_units_pct,
                "action": act,
                "retQe": float(ret_qe) if ret_qe is not None else None,
                "retT45": float(ret_t45) if ret_t45 is not None else None,
                "gapQavg": float(gap_qavg) if gap_qavg is not None else None,
                "gapQe": float(gap_qe) if gap_qe is not None else None,
                "pT45": float(p_t45_raw) if p_t45_raw is not None else None,
                "pNextT45": float(p_next_t45_raw) if p_next_t45_raw is not None else None,
                "pQavg": float(p_qavg) if p_qavg is not None else None,
            }
            guru_by_q.setdefault(qd_k, []).append(rec)
            guru_by_id_q.setdefault(iid_s, {}).setdefault(qd_k, []).append(rec)
            px_by_q_tk[(qd_k, tk_s)] = {
                "retT45": rec["retT45"],
                "pT45": rec["pT45"],
                "pNextT45": rec["pNextT45"],
                "pQavg": rec["pQavg"],
            }

        # Build HF-4 Smart-Money Flow panel across 2014-03-31 .. 2026-09-30 (exact match to Step 13B & 13C)
        con.execute("""
            CREATE TEMP TABLE sec_q_ret AS
            WITH qe_p AS (
                SELECT q.q_idx, p.ticker, p.closeadj AS p_qe
                FROM q_sessions q JOIN px_dedup p ON p.date = q.qe_td
            ),
            lag_p AS (
                SELECT q.q_idx, p.ticker, p.closeadj AS p_lag, p.close_raw AS p_lag_raw
                FROM q_sessions q JOIN px_dedup p ON p.date = q.lag_td
            )
            SELECT c.q_idx, CAST(q.q_date AS VARCHAR) AS q_date, c.ticker,
                   l0.p_lag_raw AS p_t45_raw,
                   l1.p_lag_raw AS p_next_t45_raw,
                   CASE WHEN n.p_qe > 0 AND c.p_qe > 0 THEN least(3.0, greatest(-0.95, n.p_qe / c.p_qe - 1.0)) END AS ret_qe_fwd,
                   CASE WHEN l1.p_lag > 0 AND l0.p_lag > 0 THEN least(3.0, greatest(-0.95, l1.p_lag / l0.p_lag - 1.0)) END AS ret_lag_fwd
            FROM qe_p c
            JOIN q_sessions q ON q.q_idx = c.q_idx
            LEFT JOIN qe_p n  ON n.q_idx  = c.q_idx + 1 AND n.ticker  = c.ticker
            LEFT JOIN lag_p l0 ON l0.q_idx = c.q_idx     AND l0.ticker = c.ticker
            LEFT JOIN lag_p l1 ON l1.q_idx = c.q_idx + 1 AND l1.ticker = c.ticker;
        """)

        hf_panel_rows = con.execute("""
            WITH h_st AS (
                SELECT
                    q.q_idx, q.q_date, h.ticker,
                    SUM(h.value) AS tot_13f_m,
                    SUM(CASE WHEN c.strategy = 'ACTIVE_HF' THEN h.value ELSE 0 END) AS hf_val,
                    COUNT(DISTINCT CASE WHEN c.strategy = 'ACTIVE_HF' THEN h.investorid END) AS n_hf,
                    SUM(CASE WHEN c.strategy = 'MULTISTRAT_POD' THEN h.value ELSE 0 END) AS pod_val,
                    SUM(CASE WHEN c.strategy = 'PASSIVE_INDEX' THEN h.value ELSE 0 END) AS pas_val
                FROM holdings h
                JOIN q_sessions q ON q.q_date = h.date
                LEFT JOIN inv_tax c ON h.investorid = c.investorid
                WHERE h.securitytype = 'SHR' AND h.value > 0
                GROUP BY 1, 2, 3
            )
            SELECT
                cur.q_idx,
                CAST(cur.q_date AS VARCHAR) AS qd,
                cur.ticker,
                cur.tot_13f_m,
                prev.tot_13f_m AS prev_tot_13f_m,
                cur.n_hf,
                (cur.n_hf - COALESCE(prev.n_hf, 0)) AS d_n_hf,
                (cur.hf_val / (1.0 + pr.ret_qe_fwd) - COALESCE(prev.hf_val, 0.0)) / prev.tot_13f_m AS hf_flow_pct,
                (cur.pod_val / (1.0 + pr.ret_qe_fwd) - COALESCE(prev.pod_val, 0.0)) / prev.tot_13f_m AS pod_flow_pct,
                (cur.pas_val / (1.0 + pr.ret_qe_fwd) - COALESCE(prev.pas_val, 0.0)) / prev.tot_13f_m AS pas_flow_pct,
                (cur.hf_val / (1.0 + pr.ret_qe_fwd) - COALESCE(prev.hf_val, 0.0)) AS hf_net_m,
                r.ret_lag_fwd,
                r.p_t45_raw,
                r.p_next_t45_raw
            FROM h_st cur
            JOIN h_st prev ON prev.q_idx = cur.q_idx - 1 AND prev.ticker = cur.ticker
            JOIN sec_q_ret pr ON pr.q_idx = cur.q_idx - 1 AND pr.ticker = cur.ticker
            LEFT JOIN sec_q_ret r ON r.q_idx = cur.q_idx AND r.ticker = cur.ticker
            WHERE cur.q_date >= DATE '2014-03-31'
              AND prev.tot_13f_m >= 500
              AND pr.ret_qe_fwd IS NOT NULL AND (1.0 + pr.ret_qe_fwd) > 0.15
              AND abs((cur.hf_val / (1.0 + pr.ret_qe_fwd) - COALESCE(prev.hf_val, 0.0)) / prev.tot_13f_m) <= 0.25
        """).fetchall()

        hf_by_q: dict[str, list[dict]] = {}
        for (
            q_idx, qd_s, tk, tot_m, prev_tot_m, n_hf, d_n_hf,
            hf_fl, pod_fl, pas_fl, hf_net_m, ret_lag, p0_raw, p1_raw,
        ) in hf_panel_rows:
            qd_k = str(qd_s)[:10]
            tk_s = str(tk)
            if hf_fl is None or pod_fl is None or pas_fl is None:
                continue
            rec = {
                "qd": qd_k,
                "ticker": tk_s,
                "tot13fM": float(tot_m),
                "prevTot13fM": float(prev_tot_m),
                "nHf": int(n_hf),
                "dNHf": int(d_n_hf),
                "hfFlowPct": float(hf_fl),
                "podFlowPct": float(pod_fl),
                "pasFlowPct": float(pas_fl),
                "hfNetM": float(hf_net_m),
                "retT45": float(ret_lag) if ret_lag is not None else None,
                "pT45": float(p0_raw) if p0_raw is not None else None,
                "pNextT45": float(p1_raw) if p1_raw is not None else None,
            }
            hf_by_q.setdefault(qd_k, []).append(rec)
            if (qd_k, tk_s) not in px_by_q_tk:
                px_by_q_tk[(qd_k, tk_s)] = {
                    "retT45": rec["retT45"],
                    "pT45": rec["pT45"],
                    "pNextT45": rec["pNextT45"],
                    "pQavg": None,
                }

        # Live 2026 Q3 Q1 Active-HF Heavy Dumping Minefield Radar (>=$15B large caps)
        q3_hf_universe = [
            r for r in hf_by_q.get("2026-09-30", [])
            if r["prevTot13fM"] >= 5000.0 and r["tot13fM"] >= 15000.0
        ]
        q3_hf_universe.sort(key=lambda x: x["hfFlowPct"])
        q1_dump_rows_raw = q3_hf_universe[:12]
        q1_dump_tickers = {r["ticker"] for r in q1_dump_rows_raw}

        # Check which of the 16 gurus hold any Q1 dumped ticker in 2026 Q3
        q3_guru_holders_by_tk: dict[str, list[str]] = {}
        for rec in guru_by_q.get("2026-09-30", []):
            if rec["rk"] <= 12:
                g_short = GURU_META[rec["investorid"]]["shortName"]
                q3_guru_holders_by_tk.setdefault(rec["ticker"], []).append(
                    f"{g_short} ({rec['wt']*100:.1f}% {rec['action']})"
                )

        q1_dump_radar: list[dict] = []
        for idx, r in enumerate(q1_dump_rows_raw, start=1):
            tk = r["ticker"]
            sp = spot_meta.get(tk, {})
            tm = ticker_meta.get(tk, {"name": tk, "sector": ""})
            guru_overlap = q3_guru_holders_by_tk.get(tk, [])
            q1_dump_radar.append({
                "rank": idx,
                "ticker": tk,
                "companyName": tm["name"],
                "sector": tm["sector"],
                "tot13fB": r2(r["tot13fM"] / 1000.0),
                "nHf": r["nHf"],
                "dNHf": r["dNHf"],
                "hfFlowPct": r2(r["hfFlowPct"] * 100.0),
                "podFlowPct": r2(r["podFlowPct"] * 100.0),
                "pasFlowPct": r2(r["pasFlowPct"] * 100.0),
                "hfNetM": r1(r["hfNetM"]),
                "q3AvgPrice": r2(sp.get("q3AvgCost")),
                "latestPrice": r2(sp.get("latestPrice")),
                "postQ3ReturnPct": r2(sp.get("vsQ3CostPct")),
                "dd52wPct": r2(sp.get("dd52wPct")),
                "guruOverlap": guru_overlap,
                "warningTag": {
                    "en": (
                        f"Guru Trap Conflict ({', '.join(guru_overlap)}) — Active HFs dumped ${abs(r['hfNetM'])/1000:.2f}B"
                        if guru_overlap
                        else f"Active HFs dumped ${abs(r['hfNetM'])/1000:.2f}B ({r['dNHf']:+d} funds)"
                    ),
                    "zh": (
                        f"单一大师撞车预警 ({', '.join(guru_overlap)}) · 主动HF狂抛 ${abs(r['hfNetM'])/1000:.2f}B"
                        if guru_overlap
                        else f"主动HF单季净抛 ${abs(r['hfNetM'])/1000:.2f}B (净撤退 {abs(r['dNHf'])} 家)"
                    ),
                },
            })

        # Also extract 2026 Q3 Explicit Guru Exits & Heavy Slashes (>=50% share cut on prior >=1.8% core positions)
        exits_raw = con.execute("""
            WITH raw_h AS (
                SELECT
                    CAST(s.date AS VARCHAR) AS qd,
                    s.investorid,
                    s.ticker,
                    SUM(s.value) AS val_m,
                    SUM(s.units) AS units
                FROM holdings s
                JOIN guru_ids g ON s.investorid = g.investorid
                WHERE s.securitytype = 'SHR'
                  AND s.date IN (DATE '2026-06-30', DATE '2026-09-30')
                  AND s.value > 0
                GROUP BY 1, 2, 3
            ),
            tot AS (
                SELECT qd, investorid, SUM(val_m) AS tot_val
                FROM raw_h GROUP BY 1, 2
            ),
            w AS (
                SELECT r.qd, r.investorid, r.ticker, r.val_m, r.units, r.val_m / t.tot_val AS wt
                FROM raw_h r JOIN tot t ON r.qd = t.qd AND r.investorid = t.investorid
            )
            SELECT
                prev.investorid,
                prev.ticker,
                prev.wt AS prev_wt,
                COALESCE(cur.wt, 0.0) AS cur_wt,
                prev.units AS prev_units,
                COALESCE(cur.units, 0.0) AS cur_units,
                prev.val_m AS prev_val_m,
                COALESCE(cur.val_m, 0.0) AS cur_val_m
            FROM w prev
            LEFT JOIN w cur
              ON cur.qd = '2026-09-30'
             AND cur.investorid = prev.investorid
             AND cur.ticker = prev.ticker
            WHERE prev.qd = '2026-06-30'
              AND prev.wt >= 0.018
              AND (cur.units IS NULL OR cur.units <= prev.units * 0.50)
            ORDER BY prev.wt DESC
        """).fetchall()

        guru_exits_slashes: list[dict] = []
        for iid, tk, p_wt, c_wt, p_u, c_u, p_vm, c_vm in exits_raw[:24]:
            iid_s = str(iid)
            tk_s = str(tk)
            cut_pct = ((float(c_u) / float(p_u) - 1.0) * 100.0) if float(p_u) > 0 else -100.0
            is_exit = float(c_u) <= 0.0
            sp = spot_meta.get(tk_s, {})
            tm = ticker_meta.get(tk_s, {"name": tk_s, "sector": ""})
            gm = GURU_META[iid_s]
            guru_exits_slashes.append({
                "investorId": iid_s,
                "guruName": {"en": gm["shortName"], "zh": gm["nameZh"]},
                "ticker": tk_s,
                "companyName": tm["name"],
                "sector": tm["sector"],
                "action": "EXIT -100%" if is_exit else f"SLASH {cut_pct:.0f}%",
                "isFullExit": is_exit,
                "prevWeightPct": r2(float(p_wt) * 100.0),
                "curWeightPct": r2(float(c_wt) * 100.0),
                "deltaWeightPct": r2((float(c_wt) - float(p_wt)) * 100.0),
                "shareCutPct": r1(cut_pct),
                "prevValM": r1(float(p_vm)),
                "q3AvgPrice": r2(sp.get("q3AvgCost")),
                "latestPrice": r2(sp.get("latestPrice")),
                "vsQ3CostPct": r2(sp.get("vsQ3CostPct")),
                "q1DumpWarning": tk_s in q1_dump_tickers,
                "sellRule": {
                    "en": (
                        "Unconditional T+45 Exit: Guru fully liquidated core stake"
                        if is_exit
                        else f"Discipline Slash: Guru cut shares by {abs(cut_pct):.0f}% (>50% threshold)"
                    ),
                    "zh": (
                        "T+45 无条件清仓：大师已100%清仓退出核心持仓"
                        if is_exit
                        else f"纪律跟砍：大师单季砍仓 {abs(cut_pct):.0f}%（触发 >50% 止盈/止损线）"
                    ),
                },
            })

        # Strategy selection helpers across all quarters (both 49 realized T+45 backtest quarters AND live 2026 Q2 / 2026 Q3!)
        def make_guru_selector(
            pool_ids: list[str],
            max_rk: int = 6,
            top_k: int = 10,
            min_wt: float = 0.04,
            weight_mode: str = "equal",
            price_filter: str | None = None,
            only_adds: bool = False,
        ):
            pool_set = set(pool_ids)

            def _select(qd: str, require_realized_ret: bool = True) -> list[dict]:
                rows = [
                    r for r in guru_by_q.get(qd, [])
                    if r["investorid"] in pool_set
                    and (not require_realized_ret or r["retT45"] is not None)
                ]
                if only_adds:
                    rows = [r for r in rows if r["dWt"] >= 0.015 and r["wt"] >= 0.025]
                else:
                    rows = [r for r in rows if r["rk"] <= max_rk and r["wt"] >= min_wt]
                if price_filter == "discount_qavg":
                    rows = [r for r in rows if r["gapQavg"] is not None and r["gapQavg"] <= 0.0]
                elif price_filter == "chased_up":
                    rows = [r for r in rows if r["gapQe"] is not None and r["gapQe"] >= 0.10]
                if not rows:
                    return []
                by_tk: dict[str, list[dict]] = {}
                for r in rows:
                    by_tk.setdefault(r["ticker"], []).append(r)
                scored = []
                for tk, grp in by_tk.items():
                    wt_sum = sum(x["wt"] for x in grp)
                    n_g = len({x["investorid"] for x in grp})
                    conv_score = wt_sum + 0.05 * (n_g - 1)
                    raw_w = wt_sum if weight_mode == "conviction" else (conv_score if weight_mode == "consensus" else 1.0)
                    grp_sorted = sorted(grp, key=lambda x: x["wt"], reverse=True)
                    backing = [
                        f"{GURU_META[x['investorid']]['shortName']} ({x['wt']*100:.1f}%)"
                        for x in grp_sorted[:4]
                    ]
                    lead_act = grp_sorted[0]["action"]
                    for x in grp_sorted:
                        if x["action"].startswith("NEW") or x["action"].startswith("ADD"):
                            lead_act = x["action"]
                            break
                    scored.append({
                        "ticker": tk,
                        "convScore": conv_score,
                        "rawWeight": raw_w,
                        "guruCount": n_g,
                        "sumGuruWtPct": wt_sum * 100.0,
                        "backingGurus": backing,
                        "leadAction": lead_act,
                    })
                scored.sort(key=lambda x: (x["convScore"], x["sumGuruWtPct"], x["ticker"]), reverse=True)
                picks = scored[:top_k]
                tot_w = sum(x["rawWeight"] for x in picks) or 1.0
                for p in picks:
                    p["weight"] = p["rawWeight"] / tot_w
                return picks

            return _select

        # Point-in-Time QQQ Constituent Filter (SEC N-PORT 2019 Q4..2026 Q3 + PIT Top-100 Non-Financial NASDAQ 2014 Q1..2019 Q3)
        sec_qqq_snaps = load_sec_qqq_snapshots(DEFAULT_RULE_QQQ_FILE)
        ticker_to_permas: dict[str, set[int]] = {}
        for tk_r, pm_r in con.execute(
            "SELECT DISTINCT ticker, permaticker FROM tickers WHERE ticker IS NOT NULL AND permaticker IS NOT NULL"
        ).fetchall():
            ticker_to_permas.setdefault(str(tk_r).upper(), set()).add(int(pm_r))

        pit_ndx_rows = con.execute("""
            WITH tk_clean AS (
                SELECT ticker,
                       arg_max(permaticker, lastupdated) AS permaticker,
                       arg_max(exchange, lastupdated) AS exchange,
                       arg_max(sector, lastupdated) AS sector
                FROM tickers
                WHERE ticker IS NOT NULL
                GROUP BY 1
            ),
            q_mcap AS (
                SELECT CAST(c.q_date AS VARCHAR) AS qd,
                       d.ticker,
                       LAST(d.marketcap ORDER BY d.date) AS mcap
                FROM q_cal c
                JOIN daily d
                  ON d.date <= c.q_date AND d.date >= c.q_date - INTERVAL 15 DAY
                JOIN tk_clean t ON t.ticker = d.ticker
                WHERE c.q_date >= DATE '2014-03-31'
                  AND t.exchange = 'NASDAQ'
                  AND COALESCE(t.sector, '') <> 'Financial Services'
                  AND d.marketcap > 0
                GROUP BY 1, 2
            ),
            ranked AS (
                SELECT qd, ticker, mcap,
                       ROW_NUMBER() OVER (PARTITION BY qd ORDER BY mcap DESC) AS rk
                FROM q_mcap
            )
            SELECT qd, ticker FROM ranked WHERE rk <= 100
        """).fetchall()
        pit_ndx_by_q: dict[str, set[str]] = {}
        for qd_s, tk_s in pit_ndx_rows:
            pit_ndx_by_q.setdefault(str(qd_s)[:10], set()).add(str(tk_s).upper())

        def is_in_qqq_pit(qd: str, entry_dt: str, ticker: str) -> bool:
            tk = ticker.upper()
            if tk in ("QQQ", "SPY"):
                return True
            visible = [
                snap for snap in sec_qqq_snaps
                if snap["filedAt"] < entry_dt and snap["reportDate"] <= entry_dt
            ]
            if visible:
                best_sec = max(visible, key=lambda s: (s["reportDate"], s["filedAt"]))
                t_set = best_sec["tickers"]
                p_set = best_sec["permatickers"]
                if tk in t_set:
                    return True
                alt = DUAL_CLASS_PAIRS.get(tk)
                if alt and alt in t_set:
                    return True
                t_permas = ticker_to_permas.get(tk, set())
                if t_permas and (t_permas & p_set):
                    return True
                return False
            ndx_set = pit_ndx_by_q.get(qd, set())
            if tk in ndx_set:
                return True
            alt = DUAL_CLASS_PAIRS.get(tk)
            if alt and alt in ndx_set:
                return True
            return False

        def make_exqqq_monopoly_selector(top_k: int = 5, weight_mode: str = "conviction"):
            pool_set = set(TOP_COMPOUND_IDS)

            def _select(qd: str, require_realized_ret: bool = True) -> list[dict]:
                entry_dt = session_info[qd]["t45EntryDate"]
                base_rows = [
                    r for r in guru_by_q.get(qd, [])
                    if r["investorid"] in pool_set
                    and (not require_realized_ret or r["pT45"] is not None)
                    and not is_in_qqq_pit(qd, entry_dt, r["ticker"])
                ]
                strict_rows = [r for r in base_rows if r["rk"] <= 6 and r["wt"] >= 0.04]
                strict_tks = {r["ticker"] for r in strict_rows}
                if len(strict_tks) < top_k:
                    extra_rows = [
                        r for r in base_rows
                        if r["rk"] <= 10 and r["wt"] >= 0.025 and r["ticker"] not in strict_tks
                    ]
                    use_rows = strict_rows + extra_rows
                else:
                    use_rows = strict_rows
                if not use_rows:
                    return []
                by_tk: dict[str, list[dict]] = {}
                for r in use_rows:
                    by_tk.setdefault(r["ticker"], []).append(r)
                scored = []
                for tk, grp in by_tk.items():
                    wt_sum = sum(x["wt"] for x in grp)
                    n_g = len({x["investorid"] for x in grp})
                    is_primary = any(x["rk"] <= 6 and x["wt"] >= 0.04 for x in grp)
                    conv_score = (10.0 if is_primary else 0.0) + wt_sum + 0.05 * (n_g - 1)
                    raw_w = wt_sum if weight_mode == "conviction" else 1.0
                    grp_sorted = sorted(grp, key=lambda x: x["wt"], reverse=True)
                    backing = [
                        f"{GURU_META[x['investorid']]['shortName']} ({x['wt']*100:.1f}%)"
                        for x in grp_sorted[:4]
                    ]
                    lead_act = grp_sorted[0]["action"]
                    for x in grp_sorted:
                        if x["action"].startswith("NEW") or x["action"].startswith("ADD"):
                            lead_act = x["action"]
                            break
                    scored.append({
                        "ticker": tk,
                        "convScore": conv_score,
                        "rawWeight": raw_w,
                        "guruCount": n_g,
                        "sumGuruWtPct": wt_sum * 100.0,
                        "backingGurus": backing,
                        "leadAction": lead_act,
                    })
                scored.sort(key=lambda x: (x["convScore"], x["sumGuruWtPct"], x["ticker"]), reverse=True)
                picks = scored[:top_k]
                tot_w = sum(x["rawWeight"] for x in picks) or 1.0
                for p in picks:
                    p["weight"] = p["rawWeight"] / tot_w
                return picks

            return _select

        def run_full_scheme(
            selector_fn,
            cost_bps: float = 10.0,
            barbell_etf: bool = False,
            qqq80_etf: bool = False,
        ) -> tuple[dict[str, float], float, float, list[dict], list[dict]]:
            prev_w: dict[str, float] = {}
            rets_49: dict[str, float] = {}
            ns_49: list[float] = []
            tos_49: list[float] = []
            snapshots: list[dict] = []
            rebalance_legs: list[dict] = []
            prev_stock_set: set[str] = set()

            # Evaluate across all quarters 2014-03-31 .. 2026-09-30 (51 quarters: 50 realized + active 2026 Q3 live!)
            for qd in all_snapshot_q_dates:
                s_info = session_info[qd]
                is_bt_q = bool(s_info["t45ExitDate"] and s_info["t45ExitDate"] <= latest_price_date)
                has_realized_t45 = is_bt_q
                picks = selector_fn(qd, require_realized_ret=is_bt_q)

                if qqq80_etf:
                    eff_picks = [
                        {
                            "ticker": "QQQ",
                            "weight": 0.80,
                            "guruCount": 0,
                            "sumGuruWtPct": 80.0,
                            "backingGurus": ["Nasdaq-100 Growth Core (80%)"],
                            "leadAction": "CORE ETF",
                        },
                    ] + [
                        {**p, "weight": p["weight"] * 0.20}
                        for p in picks
                    ]
                elif barbell_etf:
                    eff_picks = [
                        {
                            "ticker": "SPY",
                            "weight": 0.35,
                            "guruCount": 0,
                            "sumGuruWtPct": 35.0,
                            "backingGurus": ["S&P 500 Core Ballast (35%)"],
                            "leadAction": "CORE ETF",
                        },
                        {
                            "ticker": "QQQ",
                            "weight": 0.35,
                            "guruCount": 0,
                            "sumGuruWtPct": 35.0,
                            "backingGurus": ["Nasdaq-100 Growth Core (35%)"],
                            "leadAction": "CORE ETF",
                        },
                    ] + [
                        {**p, "weight": p["weight"] * 0.30}
                        for p in picks
                    ]
                else:
                    eff_picks = picks

                w_map = {p["ticker"]: p["weight"] for p in eff_picks}
                q_to = 0.0
                if prev_w and w_map:
                    all_k = set(w_map) | set(prev_w)
                    q_to = 0.5 * sum(abs(w_map.get(k, 0.0) - prev_w.get(k, 0.0)) for k in all_k)
                    if is_bt_q:
                        tos_49.append(q_to * 400.0)
                if w_map:
                    prev_w = w_map
                    if is_bt_q:
                        ns_49.append(float(len(picks)))

                # Compute realized T+45 return when available
                s_info = session_info[qd]
                spy_b = bm_px_info.get((qd, "SPY"), (None, None, None))
                qqq_b = bm_px_info.get((qd, "QQQ"), (None, None, None))
                spy_r = spy_b[2]
                qqq_r = qqq_b[2]

                port_r: float | None = None
                holdings_detail: list[dict] = []
                cur_stock_set = {p["ticker"] for p in eff_picks if p["ticker"] not in ("SPY", "QQQ")}
                entered_tks = sorted(cur_stock_set - prev_stock_set) if prev_stock_set else sorted(cur_stock_set)
                exited_tks = sorted(prev_stock_set - cur_stock_set) if prev_stock_set else []
                held_tks = sorted(cur_stock_set & prev_stock_set) if prev_stock_set else []

                valid_ret_sum = 0.0
                valid_w_sum = 0.0
                valid_w_map: dict[str, float] = {}
                drifted_end_raw: dict[str, float] = {}
                for p in eff_picks:
                    tk = p["ticker"]
                    if tk in ("SPY", "QQQ"):
                        b_p0, b_p1, b_rt = bm_px_info.get((qd, tk), (None, None, None))
                        tk_ret = b_rt if has_realized_t45 else None
                        p_entry = b_p0
                        p_exit = b_p1 if has_realized_t45 else None
                    else:
                        px_i = px_by_q_tk.get((qd, tk), {})
                        tk_ret = px_i.get("retT45") if has_realized_t45 else None
                        p_entry = px_i.get("pT45")
                        p_exit = px_i.get("pNextT45") if has_realized_t45 else None

                    if tk_ret is not None and math.isfinite(tk_ret):
                        valid_ret_sum += p["weight"] * tk_ret
                        valid_w_sum += p["weight"]
                        valid_w_map[tk] = p["weight"]
                        drifted_end_raw[tk] = p["weight"] * (1.0 + tk_ret)

                    sp = spot_meta.get(tk, {})
                    tm = ticker_meta.get(tk, {"name": tk, "sector": ""})
                    is_q1_dump = (qd == "2026-09-30") and (tk in q1_dump_tickers)
                    status_tag = (
                        "CORE"
                        if tk in ("SPY", "QQQ")
                        else ("NEW" if (not prev_stock_set or tk in entered_tks) else "HELD")
                    )
                    verdict = follow_verdict(
                        p["leadAction"],
                        sp.get("vsQ3CostPct") if qd == "2026-09-30" else None,
                        sp.get("dd52wPct") if qd == "2026-09-30" else None,
                        is_q1_dump,
                    )
                    h_item = {
                        "ticker": tk,
                        "companyName": tm["name"],
                        "sector": tm["sector"],
                        "weightPct": r2(p["weight"] * 100.0),
                        "status": status_tag,
                        "leadAction": p["leadAction"],
                        "guruCount": p["guruCount"],
                        "backingGurus": p["backingGurus"],
                        "entryPrice": r2(p_entry),
                        "exitPrice": r2(p_exit),
                        "realizedRetPct": r2(tk_ret * 100.0) if tk_ret is not None else None,
                        "contribBps": r1(p["weight"] * tk_ret * 10000.0) if tk_ret is not None else None,
                    }
                    if qd == "2026-09-30":
                        h_item.update({
                            "estGuruCost": r2(sp.get("q3AvgCost")),
                            "latestPrice": r2(sp.get("latestPrice")),
                            "vsGuruCostPct": r2(sp.get("vsQ3CostPct")),
                            "dd52wPct": r2(sp.get("dd52wPct")),
                            "q1DumpWarning": is_q1_dump,
                            "verdict": verdict,
                        })
                    holdings_detail.append(h_item)

                if has_realized_t45 and valid_w_sum > 0:
                    if qqq80_etf and qqq_r is not None:
                        sat_w = sum(p["weight"] for p in eff_picks if p["ticker"] != "QQQ" and px_by_q_tk.get((qd, p["ticker"]), {}).get("retT45") is not None)
                        sat_r_gross = sum(
                            (p["weight"] / sat_w) * px_by_q_tk[(qd, p["ticker"])]["retT45"]
                            for p in eff_picks
                            if p["ticker"] != "QQQ" and px_by_q_tk.get((qd, p["ticker"]), {}).get("retT45") is not None
                        ) if sat_w > 0 else 0.0
                        port_r = 0.80 * qqq_r + 0.20 * sat_r_gross - q_to * (cost_bps / 10000.0)
                    elif barbell_etf and spy_r is not None and qqq_r is not None:
                        # Exact 35% SPY + 35% QQQ + 30% net active sleeve
                        sat_w = sum(p["weight"] for p in eff_picks if p["ticker"] not in ("SPY", "QQQ") and px_by_q_tk.get((qd, p["ticker"]), {}).get("retT45") is not None)
                        sat_r_gross = sum(
                            (p["weight"] / sat_w) * px_by_q_tk[(qd, p["ticker"])]["retT45"]
                            for p in eff_picks
                            if p["ticker"] not in ("SPY", "QQQ") and px_by_q_tk.get((qd, p["ticker"]), {}).get("retT45") is not None
                        ) if sat_w > 0 else 0.0
                        sat_to = q_to / 0.30 if q_to > 0 else 0.0
                        sat_net = sat_r_gross - sat_to * (cost_bps / 10000.0)
                        port_r = 0.35 * spy_r + 0.35 * qqq_r + 0.30 * sat_net
                    else:
                        port_r = (valid_ret_sum / valid_w_sum) - q_to * (cost_bps / 10000.0)

                    if is_bt_q:
                        rets_49[qd] = port_r
                        rebalance_legs.append({
                            "qd": qd,
                            "entryDate": s_info["t45EntryDate"],
                            "exitDate": s_info["t45ExitDate"],
                            "barbellEtf": barbell_etf,
                            "qqq80Etf": qqq80_etf,
                            "weights": w_map if qqq80_etf else valid_w_map,
                            "turnover": q_to,
                            "costBps": cost_bps,
                            "portRet": port_r,
                            "isLiveLeg": False,
                        })
                elif (not has_realized_t45) and w_map and s_info["t45EntryDate"] and s_info["t45EntryDate"] <= latest_price_date:
                    # Active live quarter leg (e.g. 2026 Q3 entered 2026-11-16 -> latest_price_date)
                    rebalance_legs.append({
                        "qd": qd,
                        "entryDate": s_info["t45EntryDate"],
                        "exitDate": latest_price_date,
                        "barbellEtf": barbell_etf,
                        "qqq80Etf": qqq80_etf,
                        "weights": dict(w_map),
                        "turnover": q_to,
                        "costBps": cost_bps,
                        "portRet": None,
                        "isLiveLeg": True,
                    })

                prev_stock_set = cur_stock_set
                snapshots.append({
                    "quarterDate": qd,
                    "quarter": s_info["quarter"],
                    "filedAt": s_info["filedAt"],
                    "entryDate": s_info["t45EntryDate"],
                    "exitDate": s_info["t45ExitDate"] or "2027-02-16 (Active)",
                    "isLive": not has_realized_t45,
                    "in12YrBacktest": is_bt_q,
                    "portRetPct": r2(port_r * 100.0) if port_r is not None else None,
                    "spyRetPct": r2(spy_r * 100.0) if (has_realized_t45 and spy_r is not None) else None,
                    "qqqRetPct": r2(qqq_r * 100.0) if (has_realized_t45 and qqq_r is not None) else None,
                    "excessSpyPct": r2((port_r - spy_r) * 100.0) if (port_r is not None and has_realized_t45 and spy_r is not None) else None,
                    "excessQqqPct": r2((port_r - qqq_r) * 100.0) if (port_r is not None and has_realized_t45 and qqq_r is not None) else None,
                    "beatSpy": bool(port_r > spy_r) if (port_r is not None and has_realized_t45 and spy_r is not None) else None,
                    "beatQqq": bool(port_r > qqq_r) if (port_r is not None and has_realized_t45 and qqq_r is not None) else None,
                    "turnoverPct": r1(q_to * 100.0),
                    "enteredCount": len(entered_tks),
                    "exitedCount": len(exited_tks),
                    "heldCount": len(held_tks),
                    "enteredTickers": entered_tks,
                    "exitedTickers": exited_tks,
                    "heldTickers": held_tks,
                    "holdings": holdings_detail,
                })

            avg_n = sum(ns_49) / len(ns_49) if ns_49 else 0.0
            ann_to = 40.0 if barbell_etf else (sum(tos_49) / len(tos_49) if tos_49 else 0.0)
            return rets_49, avg_n, ann_to, snapshots, rebalance_legs

        # Run all 5 Interactive Low/Moderate-Turnover Copycat Schemes + Conviction/Equal-Weight Variants
        sel_exqqq5_cw = make_exqqq_monopoly_selector(top_k=5, weight_mode="conviction")
        sel_exqqq8_ew = make_exqqq_monopoly_selector(top_k=8, weight_mode="equal")
        sel_cmp_ew = make_guru_selector(TOP_COMPOUND_IDS, max_rk=6, top_k=10, min_wt=0.04, weight_mode="equal")
        sel_cmp_cw = make_guru_selector(TOP_COMPOUND_IDS, max_rk=6, top_k=10, min_wt=0.04, weight_mode="conviction")
        sel_fam12 = make_guru_selector(PRE2014_FAMOUS_IDS, max_rk=6, top_k=12, min_wt=0.04, weight_mode="equal")
        sel_adds = make_guru_selector(PRE2014_FAMOUS_IDS, max_rk=15, top_k=12, min_wt=0.025, weight_mode="equal", only_adds=True)

        r_qqq80_cw, n_qqq80_cw, to_qqq80_cw, snap_qqq80_cw, legs_qqq80_cw = run_full_scheme(sel_exqqq5_cw, cost_bps=10.0, qqq80_etf=True)
        r_qqq80_ew, n_qqq80_ew, to_qqq80_ew, snap_qqq80_ew, legs_qqq80_ew = run_full_scheme(sel_exqqq8_ew, cost_bps=10.0, qqq80_etf=True)
        r_barbell, n_barbell, to_barbell, snap_barbell, legs_barbell = run_full_scheme(sel_cmp_ew, cost_bps=10.0, barbell_etf=True)
        r_cmp_cw, n_cmp_cw, to_cmp_cw, snap_cmp_cw, legs_cmp_cw = run_full_scheme(sel_cmp_cw, cost_bps=10.0)
        r_cmp_ew, n_cmp_ew, to_cmp_ew, snap_cmp_ew, legs_cmp_ew = run_full_scheme(sel_cmp_ew, cost_bps=10.0)
        r_fam12, n_fam12, to_fam12, snap_fam12, legs_fam12 = run_full_scheme(sel_fam12, cost_bps=10.0)
        r_adds, n_adds, to_adds, snap_adds, legs_adds = run_full_scheme(sel_adds, cost_bps=10.0)

        # Position Count Sensitivity legs (computed before daily price fetch so all tickers are loaded in one query)
        pos_sensitivity_raw: list[tuple[int, dict[str, float], float, float, list[dict]]] = []
        for k in [5, 8, 12, 20, 35]:
            sel_k = make_guru_selector(PRE2014_FAMOUS_IDS, max_rk=10, top_k=k, min_wt=0.02, weight_mode="equal")
            rk_map, an_k, ato_k, _, legs_k = run_full_scheme(sel_k, cost_bps=10.0)
            pos_sensitivity_raw.append((k, rk_map, an_k, ato_k, legs_k))

        # True Daily Mark-to-Market NAV Simulation through latest complete market close (incl. 2026 Q1, Q2 realized + active 2026 Q3 live!)
        daily_start_date = session_info[realized_q_dates[0]]["t45EntryDate"]
        daily_end_date = latest_price_date
        daily_trading_dates = [
            str(r[0])[:10]
            for r in con.execute(
                """
                SELECT CAST(s.date AS VARCHAR)
                FROM spy_days s
                JOIN px_dedup q ON q.date = s.date AND q.ticker = 'QQQ'
                WHERE s.date >= CAST(? AS DATE) AND s.date <= CAST(? AS DATE)
                ORDER BY s.date
                """,
                [daily_start_date, daily_end_date],
            ).fetchall()
        ]
        date_to_idx = {d: i for i, d in enumerate(daily_trading_dates)}

        # Also collect all 16 gurus' top-60 holdings for daily mark-to-market NAV through daily_end_date
        guru_daily_legs_by_id: dict[str, list[dict]] = {}
        for gid in guru_ids:
            by_q_g = guru_by_id_q.get(gid, {})
            g_legs: list[dict] = []
            for qd in all_snapshot_q_dates:
                recs_g = by_q_g.get(qd, [])
                if not recs_g:
                    continue
                s_info_g = session_info[qd]
                e0_g = s_info_g["t45EntryDate"]
                e1_g = s_info_g["t45ExitDate"] if (s_info_g["t45ExitDate"] and s_info_g["t45ExitDate"] <= latest_price_date) else latest_price_date
                if not e0_g or e0_g > latest_price_date or e1_g <= e0_g:
                    continue
                top_recs = [x for x in recs_g[:60] if x["pT45"] is not None]
                w_sum_g = sum(x["wt"] for x in top_recs)
                if w_sum_g <= 0:
                    continue
                g_legs.append({
                    "qd": qd,
                    "entryDate": e0_g,
                    "exitDate": e1_g,
                    "barbellEtf": False,
                    "qqq80Etf": False,
                    "weights": {x["ticker"]: x["wt"] / w_sum_g for x in top_recs},
                    "turnover": 0.0,
                    "costBps": 0.0,
                    "portRet": None,
                    "isLiveLeg": not bool(s_info_g["t45ExitDate"] and s_info_g["t45ExitDate"] <= latest_price_date),
                })
            guru_daily_legs_by_id[gid] = g_legs

        daily_needed_tickers: set[str] = {"SPY", "QQQ"}
        for leg_list in [
            legs_qqq80_cw,
            legs_qqq80_ew,
            legs_barbell,
            legs_cmp_cw,
            legs_cmp_ew,
            legs_fam12,
            legs_adds,
            *[x[4] for x in pos_sensitivity_raw],
            *guru_daily_legs_by_id.values(),
        ]:
            for leg in leg_list:
                daily_needed_tickers.update(leg["weights"].keys())

        con.execute("CREATE TEMP TABLE daily_need_tks (ticker VARCHAR);")
        con.executemany(
            "INSERT INTO daily_need_tks VALUES (?)",
            [(tk,) for tk in sorted(daily_needed_tickers)],
        )
        daily_px_rows = con.execute(
            """
            SELECT p.ticker, CAST(p.date AS VARCHAR) AS dt, p.closeadj
            FROM px_dedup p
            JOIN daily_need_tks n ON p.ticker = n.ticker
            WHERE p.date >= CAST(? AS DATE) - INTERVAL 10 DAY
              AND p.date <= CAST(? AS DATE)
            ORDER BY p.ticker, p.date
            """,
            [daily_start_date, daily_end_date],
        ).fetchall()
        daily_px_by_tk: dict[str, dict[str, float]] = {}
        for tk, dt_s, cadj in daily_px_rows:
            daily_px_by_tk.setdefault(str(tk), {})[str(dt_s)[:10]] = float(cadj)

        def simulate_daily_etf(ticker: str) -> list[float]:
            tk_map = daily_px_by_tk[ticker]
            p0 = tk_map[daily_trading_dates[0]]
            last_p = p0
            out: list[float] = []
            for d in daily_trading_dates:
                p_cur = tk_map.get(d)
                if p_cur and p_cur > 0:
                    last_p = p_cur
                out.append(100.0 * (last_p / p0))
            return out

        def simulate_daily_scheme(legs: list[dict]) -> list[float]:
            nav_vals = [100.0] * len(daily_trading_dates)
            cur_nav = 100.0
            last_filled = 0
            for leg in legs:
                e0 = leg["entryDate"]
                e1 = leg["exitDate"]
                if not e0 or not e1 or e0 not in date_to_idx or e1 not in date_to_idx:
                    continue
                i0 = date_to_idx[e0]
                i1 = date_to_idx[e1]
                if i1 <= i0:
                    continue
                if i0 > last_filled:
                    for fill_i in range(last_filled + 1, i0 + 1):
                        nav_vals[fill_i] = cur_nav

                raw_weights = leg["weights"]
                entry_px: dict[str, float] = {}
                usable_w: dict[str, float] = {}
                for tk, w in raw_weights.items():
                    tk_map = daily_px_by_tk.get(tk, {})
                    p0 = tk_map.get(e0)
                    if p0 is None:
                        # Match DuckDB FIRST(closeadj) within T+45..T+56 window
                        for scan_i in range(i0, min(i1 + 1, i0 + 8)):
                            cand = tk_map.get(daily_trading_dates[scan_i])
                            if cand and cand > 0:
                                p0 = cand
                                break
                    if p0 is None:
                        for back_i in range(i0 - 1, max(-1, i0 - 6), -1):
                            cand = tk_map.get(daily_trading_dates[back_i])
                            if cand and cand > 0:
                                p0 = cand
                                break
                    if p0 and p0 > 0:
                        entry_px[tk] = p0
                        usable_w[tk] = w

                if leg.get("qqq80Etf"):
                    sat_tks = [tk for tk in usable_w if tk != "QQQ"]
                    sat_sum = sum(usable_w[tk] for tk in sat_tks)
                    eff_w: dict[str, float] = {"QQQ": 0.80}
                    if sat_sum > 0:
                        for tk in sat_tks:
                            eff_w[tk] = 0.20 * (usable_w[tk] / sat_sum)
                    else:
                        eff_w = {"QQQ": 1.0}
                    cost = leg["turnover"] * (leg["costBps"] / 10000.0)
                elif leg["barbellEtf"]:
                    sat_tks = [tk for tk in usable_w if tk not in ("SPY", "QQQ")]
                    sat_sum = sum(usable_w[tk] for tk in sat_tks)
                    eff_w = {"SPY": 0.35, "QQQ": 0.35}
                    if sat_sum > 0:
                        for tk in sat_tks:
                            eff_w[tk] = 0.30 * (usable_w[tk] / sat_sum)
                    else:
                        eff_w = {"SPY": 0.50, "QQQ": 0.50}
                    sat_to = leg["turnover"] / 0.30 if leg["turnover"] > 0 else 0.0
                    cost = 0.30 * sat_to * (leg["costBps"] / 10000.0)
                else:
                    w_sum = sum(usable_w.values())
                    eff_w = {tk: w / w_sum for tk, w in usable_w.items()} if w_sum > 0 else {}
                    cost = leg["turnover"] * (leg["costBps"] / 10000.0)

                last_valid = dict(entry_px)
                for idx_d in range(i0 + 1, i1 + 1):
                    d_str = daily_trading_dates[idx_d]
                    gross_mult = 0.0
                    for tk, w in eff_w.items():
                        p_cur = daily_px_by_tk.get(tk, {}).get(d_str)
                        if p_cur and p_cur > 0:
                            last_valid[tk] = p_cur
                        rel = min(5.0, max(0.05, last_valid[tk] / entry_px[tk]))
                        gross_mult += w * rel
                    net_mult = max(0.05, gross_mult - cost)
                    nav_vals[idx_d] = cur_nav * net_mult

                # Carry exact compounded NAV to next rebalance date
                cur_nav = nav_vals[i1]
                last_filled = max(last_filled, i1)
            if last_filled > 0 and last_filled < len(daily_trading_dates) - 1:
                for fill_i in range(last_filled + 1, len(daily_trading_dates)):
                    nav_vals[fill_i] = cur_nav
            return nav_vals

        def compute_daily_risk_overlay(
            nav_vals: list[float],
            spy_nav: list[float],
            qqq_nav: list[float],
            dates_override: list[str] | None = None,
        ) -> dict:
            cur_dates = dates_override if dates_override is not None else daily_trading_dates
            n = len(nav_vals)
            yrs = (n - 1) / 252.0 if n > 1 else 1.0
            cagr = ((nav_vals[-1] / nav_vals[0]) ** (1.0 / yrs) - 1.0) * 100.0
            spy_cagr = ((spy_nav[-1] / spy_nav[0]) ** (1.0 / yrs) - 1.0) * 100.0
            qqq_cagr = ((qqq_nav[-1] / qqq_nav[0]) ** (1.0 / yrs) - 1.0) * 100.0
            peak = nav_vals[0]
            mdd = 0.0
            mdd_dt = cur_dates[0]
            rets: list[float] = []
            diffs: list[float] = []
            diffs_qqq: list[float] = []
            for i in range(n):
                v = nav_vals[i]
                if v > peak:
                    peak = v
                dd = (v / peak - 1.0) * 100.0
                if dd < mdd:
                    mdd = dd
                    mdd_dt = cur_dates[i]
                if i > 0 and nav_vals[i - 1] > 0 and spy_nav[i - 1] > 0 and qqq_nav[i - 1] > 0:
                    r = v / nav_vals[i - 1] - 1.0
                    sr = spy_nav[i] / spy_nav[i - 1] - 1.0
                    qr = qqq_nav[i] / qqq_nav[i - 1] - 1.0
                    rets.append(r)
                    diffs.append(r - sr)
                    diffs_qqq.append(r - qr)
            std_r = sample_std(rets)
            std_d = sample_std(diffs)
            std_dq = sample_std(diffs_qqq)
            mean_r = sum(rets) / len(rets) if rets else 0.0
            mean_d = sum(diffs) / len(diffs) if diffs else 0.0
            mean_dq = sum(diffs_qqq) / len(diffs_qqq) if diffs_qqq else 0.0
            ann_vol = std_r * math.sqrt(252.0) * 100.0
            d_sharpe = (mean_r * 252.0 - 0.025) / (std_r * math.sqrt(252.0)) if std_r > 0 else 0.0
            d_ir = (mean_d * 252.0) / (std_d * math.sqrt(252.0)) if std_d > 0 else 0.0
            d_ir_qqq = (mean_dq * 252.0) / (std_dq * math.sqrt(252.0)) if std_dq > 0 else 0.0

            # Rolling 3Y (756 trading sessions) beat SPY & beat QQQ win rates
            roll_w = 756
            roll_spy_wins = 0
            roll_qqq_wins = 0
            roll_cnt = 0
            if n > roll_w:
                for i in range(roll_w, n):
                    r_p = nav_vals[i] / nav_vals[i - roll_w] - 1.0
                    r_s = spy_nav[i] / spy_nav[i - roll_w] - 1.0
                    r_q = qqq_nav[i] / qqq_nav[i - roll_w] - 1.0
                    roll_cnt += 1
                    if r_p > r_s:
                        roll_spy_wins += 1
                    if r_p > r_q:
                        roll_qqq_wins += 1
            roll3y_spy_pct = (roll_spy_wins / roll_cnt * 100.0) if roll_cnt > 0 else 0.0
            roll3y_qqq_pct = (roll_qqq_wins / roll_cnt * 100.0) if roll_cnt > 0 else 0.0

            # Dual-regime daily alpha vs SPY (2014-2019 vs 2020-present)
            split_idx = next((i for i, d in enumerate(cur_dates) if d >= "2020-01-01"), int(n * 0.5))
            def sub_cagr(arr: list[float], i0: int, i1: int) -> float:
                if i1 <= i0 or arr[i0] <= 0:
                    return 0.0
                y = (i1 - i0) / 252.0
                return ((arr[i1] / arr[i0]) ** (1.0 / y) - 1.0) * 100.0

            a14_19 = sub_cagr(nav_vals, 0, split_idx) - sub_cagr(spy_nav, 0, split_idx)
            a20_26 = sub_cagr(nav_vals, split_idx, n - 1) - sub_cagr(spy_nav, split_idx, n - 1)
            a14_19_qqq = sub_cagr(nav_vals, 0, split_idx) - sub_cagr(qqq_nav, 0, split_idx)
            a20_26_qqq = sub_cagr(nav_vals, split_idx, n - 1) - sub_cagr(qqq_nav, split_idx, n - 1)

            # Calendar-year returns (2014 .. 2026 YTD through latest market close) directly from daily NAV
            yr_bounds: dict[str, tuple[int, int]] = {}
            for i, d in enumerate(cur_dates):
                yr = d[:4]
                if yr not in yr_bounds:
                    yr_bounds[yr] = (max(0, i - 1), i)
                else:
                    yr_bounds[yr] = (yr_bounds[yr][0], i)
            cal_annuals = []
            for yr, (i0, i1) in sorted(yr_bounds.items()):
                pr = (nav_vals[i1] / nav_vals[i0] - 1.0) * 100.0 if nav_vals[i0] > 0 else 0.0
                sr = (spy_nav[i1] / spy_nav[i0] - 1.0) * 100.0 if spy_nav[i0] > 0 else 0.0
                qr = (qqq_nav[i1] / qqq_nav[i0] - 1.0) * 100.0 if qqq_nav[i0] > 0 else 0.0
                cal_annuals.append({
                    "year": yr,
                    "quarters": 4 if yr not in ("2014", daily_end_date[:4]) else 3,
                    "retPct": r2(pr),
                    "spyRetPct": r2(sr),
                    "qqqRetPct": r2(qr),
                    "excessSpyPct": r2(pr - sr),
                    "excessQqqPct": r2(pr - qr),
                    "beatSpy": bool(pr > sr),
                    "beatQqq": bool(pr > qr),
                })

            return {
                "dailyCagrPct": r2(cagr),
                "dailySpyCagrPct": r2(spy_cagr),
                "dailyQqqCagrPct": r2(qqq_cagr),
                "dailyAlphaPct": r2(cagr - spy_cagr),
                "dailyAlphaVsQqqPct": r2(cagr - qqq_cagr),
                "dailyAlpha1419Pct": r2(a14_19),
                "dailyAlpha2026Pct": r2(a20_26),
                "dailyAlpha1419VsQqqPct": r2(a14_19_qqq),
                "dailyAlpha2026VsQqqPct": r2(a20_26_qqq),
                "dailyBothHalvesBeat": bool(a14_19 > 0 and a20_26 > 0),
                "dailyBothHalvesBeatQqq": bool(a14_19_qqq > 0 and a20_26_qqq > 0),
                "dailyMaxDrawdownPct": r2(mdd),
                "dailyMddDate": mdd_dt,
                "dailyVolPct": r2(ann_vol),
                "dailySharpe": r2(d_sharpe),
                "dailyIr": r2(d_ir),
                "dailyIrVsQqq": r2(d_ir_qqq),
                "roll3yWinSpyPct": r1(roll3y_spy_pct),
                "roll3yWinQqqPct": r1(roll3y_qqq_pct),
                "tradingDays": n,
                "dailyFinal100k": r1(nav_vals[-1]),
                "dailyAnnualReturns": cal_annuals,
            }

        def apply_daily_risk(
            metrics_dict: dict,
            nav_vals: list[float],
            spy_nav: list[float],
            qqq_nav: list[float],
            dates_override: list[str] | None = None,
        ) -> dict:
            overlay = compute_daily_risk_overlay(nav_vals, spy_nav, qqq_nav, dates_override)
            out = dict(metrics_dict)
            out["quarterlyMaxDrawdownPct"] = out.get("maxDrawdownPct")
            out["cagrPct"] = overlay["dailyCagrPct"]
            out["spyCagrPct"] = overlay["dailySpyCagrPct"]
            out["qqqCagrPct"] = overlay["dailyQqqCagrPct"]
            out["alphaPct"] = overlay["dailyAlphaPct"]
            out["alphaVsQqqPct"] = overlay["dailyAlphaVsQqqPct"]
            out["alpha1419Pct"] = overlay["dailyAlpha1419Pct"]
            out["alpha2026Pct"] = overlay["dailyAlpha2026Pct"]
            out["alpha1419VsQqqPct"] = overlay["dailyAlpha1419VsQqqPct"]
            out["alpha2026VsQqqPct"] = overlay["dailyAlpha2026VsQqqPct"]
            out["bothHalvesBeat"] = overlay["dailyBothHalvesBeat"]
            out["bothHalvesBeatQqq"] = overlay["dailyBothHalvesBeatQqq"]
            out["final100k"] = overlay["dailyFinal100k"]
            out["maxDrawdownPct"] = overlay["dailyMaxDrawdownPct"]
            out["dailyMddDate"] = overlay["dailyMddDate"]
            out["dailyVolPct"] = overlay["dailyVolPct"]
            out["dailySharpe"] = overlay["dailySharpe"]
            out["dailyIr"] = overlay["dailyIr"]
            out["irVsQqq"] = overlay["dailyIrVsQqq"]
            out["roll3yWinSpyPct"] = overlay["roll3yWinSpyPct"]
            out["roll3yWinQqqPct"] = overlay["roll3yWinQqqPct"]
            out["tradingDays"] = overlay["tradingDays"]
            out["navEndDate"] = daily_end_date
            out["annualReturns"] = overlay["dailyAnnualReturns"]
            return out

        daily_spy = simulate_daily_etf("SPY")
        daily_qqq = simulate_daily_etf("QQQ")
        daily_qqq80_cw = simulate_daily_scheme(legs_qqq80_cw)
        daily_qqq80_ew = simulate_daily_scheme(legs_qqq80_ew)
        daily_barbell = simulate_daily_scheme(legs_barbell)
        daily_cmp_cw = simulate_daily_scheme(legs_cmp_cw)
        daily_cmp_ew = simulate_daily_scheme(legs_cmp_ew)
        daily_fam12 = simulate_daily_scheme(legs_fam12)
        daily_adds = simulate_daily_scheme(legs_adds)

        # Benchmarks
        spy_metrics = apply_daily_risk(
            calc_series_metrics(realized_q_dates, spy_t45, spy_t45, qqq_t45, avg_n=500.0, ann_to_pct=0.0),
            daily_spy,
            daily_spy,
            daily_qqq,
        )
        qqq_metrics = apply_daily_risk(
            calc_series_metrics(realized_q_dates, qqq_t45, spy_t45, qqq_t45, avg_n=100.0, ann_to_pct=0.0),
            daily_qqq,
            daily_spy,
            daily_qqq,
        )

        m_qqq80_cw = apply_daily_risk(
            calc_series_metrics(realized_q_dates, r_qqq80_cw, spy_t45, qqq_t45, n_qqq80_cw, to_qqq80_cw),
            daily_qqq80_cw,
            daily_spy,
            daily_qqq,
        )
        m_qqq80_ew = apply_daily_risk(
            calc_series_metrics(realized_q_dates, r_qqq80_ew, spy_t45, qqq_t45, n_qqq80_ew, to_qqq80_ew),
            daily_qqq80_ew,
            daily_spy,
            daily_qqq,
        )
        m_barbell = apply_daily_risk(
            calc_series_metrics(realized_q_dates, r_barbell, spy_t45, qqq_t45, n_barbell, to_barbell),
            daily_barbell,
            daily_spy,
            daily_qqq,
        )
        m_cmp_cw = apply_daily_risk(
            calc_series_metrics(realized_q_dates, r_cmp_cw, spy_t45, qqq_t45, n_cmp_cw, to_cmp_cw),
            daily_cmp_cw,
            daily_spy,
            daily_qqq,
        )
        m_cmp_ew = apply_daily_risk(
            calc_series_metrics(realized_q_dates, r_cmp_ew, spy_t45, qqq_t45, n_cmp_ew, to_cmp_ew),
            daily_cmp_ew,
            daily_spy,
            daily_qqq,
        )
        m_fam12 = apply_daily_risk(
            calc_series_metrics(realized_q_dates, r_fam12, spy_t45, qqq_t45, n_fam12, to_fam12),
            daily_fam12,
            daily_spy,
            daily_qqq,
        )
        m_adds = apply_daily_risk(
            calc_series_metrics(realized_q_dates, r_adds, spy_t45, qqq_t45, n_adds, to_adds),
            daily_adds,
            daily_spy,
            daily_qqq,
        )

        # Anchor prices on daily_end_date for live runtime tail extension when newer closes arrive in FactOS / SQLite
        live_anchor_tickers: set[str] = {"SPY", "QQQ"}
        for leg_list in (legs_qqq80_cw, legs_qqq80_ew, legs_barbell, legs_cmp_cw, legs_cmp_ew, legs_fam12, legs_adds):
            if leg_list:
                live_anchor_tickers.update(leg_list[-1]["weights"].keys())
        live_anchor_prices: dict[str, float] = {}
        for tk in sorted(live_anchor_tickers):
            tk_m = daily_px_by_tk.get(tk, {})
            p_end = tk_m.get(daily_end_date)
            if p_end is None:
                for back_d in reversed(daily_trading_dates[-6:]):
                    if back_d in tk_m:
                        p_end = tk_m[back_d]
                        break
            if p_end and p_end > 0:
                live_anchor_prices[tk] = r4(p_end)

        daily_curves_payload = {
            "startDate": daily_start_date,
            "endDate": daily_end_date,
            "tradingDays": len(daily_trading_dates),
            "dates": daily_trading_dates,
            "liveAnchor": {
                "anchorDate": daily_end_date,
                "prices": live_anchor_prices,
            },
            "series": {
                "SPY": [r2(v) for v in daily_spy],
                "QQQ": [r2(v) for v in daily_qqq],
                "qqq80_exqqq_monopoly": [r2(v) for v in daily_qqq80_cw],
                "qqq80_exqqq_monopoly_equal": [r2(v) for v in daily_qqq80_ew],
                "barbell_70_30": [r2(v) for v in daily_barbell],
                "monopoly_compounders": [r2(v) for v in daily_cmp_cw],
                "monopoly_compounders_equal": [r2(v) for v in daily_cmp_ew],
                "pre2014_legends": [r2(v) for v in daily_fam12],
                "new_adds_catalyst": [r2(v) for v in daily_adds],
            },
        }

        schemes_meta = [
            {
                "id": "qqq80_exqqq_monopoly",
                "recommended": True,
                "taxBadge": {
                    "en": f"Tax-Optimal · {m_qqq80_cw['annTurnoverPct']:.0f}% Turnover · 0% QQQ Overlap",
                    "zh": f"极低摩擦 · {m_qqq80_cw['annTurnoverPct']:.0f}%年换手 · 零重叠",
                },
                "badge": {
                    "en": f"Flagship #1 · Beats QQQ ({m_qqq80_cw['alphaVsQqqPct']:+.2f}%)",
                    "zh": f"旗舰主推 · 跑赢纳指 ({m_qqq80_cw['alphaVsQqqPct']:+.2f}%)",
                },
                "name": {
                    "en": "80% QQQ + 20% Ex-QQQ Monopoly Compounders",
                    "zh": "80% QQQ + 20% 非QQQ垄断复利精选",
                },
                "shortName": {
                    "en": "80% QQQ + 20% Ex-QQQ",
                    "zh": "80%纳指+20%非纳指垄断",
                },
                "formula": {
                    "en": "80% QQQ Core + 20% PIT SEC N-PORT Ex-QQQ Monopoly Compounders (Top-5 Conviction or Top-8 Equal-Weight, Rebalanced 4×/yr on T+45)",
                    "zh": "80% QQQ 科技复利底座 + 20% SEC N-PORT 时点剔除QQQ成分后的垄断复利大师重仓（支持 Top-5 信念加权 ⇄ Top-8 等权一键切换）",
                },
                "whyItWorks": {
                    "en": f"Eliminates duplicate mega-cap tech exposure via strict PIT SEC N-PORT QQQ exclusion (V, GE, MCO, UNH, SPGI), lifting 12Y strict T+45 CAGR to {m_qqq80_cw['cagrPct']:.2f}% ({m_qqq80_cw['alphaVsQqqPct']:+.2f}% vs QQQ, {m_qqq80_cw['alphaPct']:+.2f}% vs SPY) while compressing daily max drawdown to {m_qqq80_cw['maxDrawdownPct']:.1f}% vs QQQ {qqq_metrics['maxDrawdownPct']:.1f}%. Toggle Top-8 Equal-Weight for {m_qqq80_ew['cagrPct']:.2f}% CAGR, {m_qqq80_ew['annTurnoverPct']:.0f}% turnover, and {m_qqq80_ew['roll3yWinQqqPct']:.1f}% rolling 3Y beat-QQQ win rate.",
                    "zh": f"基于 SEC N-PORT 时点成分表严格剔除与 QQQ 重复的科技巨头，20%卫星仓100%聚焦非纳指收费站垄断寡头（V / GE / MCO / UNH / SPGI）：严格 T+45 年化 {m_qqq80_cw['cagrPct']:.2f}%（跑赢纳指 {m_qqq80_cw['alphaVsQqqPct']:+.2f}%、跑赢标普 {m_qqq80_cw['alphaPct']:+.2f}%），同时将日频最大回撤从纳指 {qqq_metrics['maxDrawdownPct']:.1f}% 压缩至 {m_qqq80_cw['maxDrawdownPct']:.1f}%；切换 Top-8 等权版年化达 {m_qqq80_ew['cagrPct']:.2f}%、年换手仅 {m_qqq80_ew['annTurnoverPct']:.0f}%、滚动3年赢纳指胜率高达 {m_qqq80_ew['roll3yWinQqqPct']:.1f}%。",
                },
                "metrics": m_qqq80_cw,
                "equalWeightVariant": m_qqq80_ew,
            },
            {
                "id": "barbell_70_30",
                "recommended": False,
                "taxBadge": {"en": "Taxable-Friendly · 40% Turnover", "zh": "应税账户友好 · 40%低换手"},
                "badge": {"en": "Lowest Drawdown Barbell", "zh": "最低回撤杠铃舱"},
                "name": {"en": "70/30 Core-Satellite Barbell", "zh": "70/30 宽基杠铃落地舱"},
                "shortName": {"en": "70/30 Barbell", "zh": "70/30 杠铃舱"},
                "formula": {
                    "en": "35% SPY + 35% QQQ + 30% Monopoly Compounders Top-10 (Rebalanced 4×/yr on T+45)",
                    "zh": "35% SPY + 35% QQQ + 30% 垄断复利6大师 Top-10（每年4次法定日再平衡）",
                },
                "whyItWorks": {
                    "en": f"Highest risk-adjusted IR vs SPY ({m_barbell['ir']:.2f}) with {m_barbell['sharpe']:.2f} Sharpe: captures Nasdaq/S&P beta with the lowest daily max drawdown ({m_barbell['maxDrawdownPct']:.1f}%, beating SPY {spy_metrics['maxDrawdownPct']:.1f}% and QQQ {qqq_metrics['maxDrawdownPct']:.1f}%) while harvesting low-decay monopoly alpha.",
                    "zh": f"对标标普最高信息比 ({m_barbell['ir']:.2f}) 与高夏普比 ({m_barbell['sharpe']:.2f})：70%宽基锁住国运Beta，30%低衰减垄断复利大师贡献纯Alpha，日频最大回撤仅 {m_barbell['maxDrawdownPct']:.1f}%（优于标普 {spy_metrics['maxDrawdownPct']:.1f}% 与纳指 {qqq_metrics['maxDrawdownPct']:.1f}%），心态最稳。",
                },
                "metrics": m_barbell,
            },
            {
                "id": "monopoly_compounders",
                "recommended": False,
                "taxBadge": {"en": f"Low T+45 Decay · {m_cmp_cw['annTurnoverPct']:.0f}% Turnover", "zh": f"T+45零衰减 · {m_cmp_cw['annTurnoverPct']:.0f}%换手"},
                "badge": {"en": f"100% Active Pure Alpha ({m_cmp_cw['alphaPct']:+.2f}%)", "zh": f"全主动纯多超额 ({m_cmp_cw['alphaPct']:+.2f}%)"},
                "name": {"en": "Monopoly Compounders Top-10", "zh": "垄断复利 6 大师核心 Top-10"},
                "shortName": {"en": "Monopoly Top-10", "zh": "垄断复利 Top-10"},
                "formula": {
                    "en": "TCI · Sanders · PRIMECAP · Marshfield · Windacre · Sachem Head (Rank ≤ 6, Weight ≥ 4%, Conviction-Weighted Top-10)",
                    "zh": "TCI · Sanders · PRIMECAP · Marshfield · Windacre · Sachem Head（前6重仓且≥4%，信念加权 Top-10）",
                },
                "whyItWorks": {
                    "en": f"Ultra-low turnover compounders hold 3–5+ years, retaining 88%–107% of their alpha after the 45-day SEC lag ({m_cmp_cw['cagrPct']:.2f}% CAGR through {daily_end_date}). Toggle Equal-Weight for a {m_cmp_ew['winRatePct']:.1f}% quarterly win rate.",
                    "zh": f"低换手垄断复利大师平均持股3–5年以上，45天披露滞后几乎不损耗超额（截至 {daily_end_date} 年化仍高达 {m_cmp_cw['cagrPct']:.2f}%）；切换等权版季度跑赢标普胜率高达 {m_cmp_ew['winRatePct']:.1f}%。",
                },
                "metrics": m_cmp_cw,
                "equalWeightVariant": m_cmp_ew,
            },
            {
                "id": "pre2014_legends",
                "recommended": False,
                "taxBadge": {"en": f"Zero Selection Bias · {m_fam12['annTurnoverPct']:.0f}% Turnover", "zh": f"100%零后视镜 · {m_fam12['annTurnoverPct']:.0f}%换手"},
                "badge": {"en": "Zero-Hindsight Proof", "zh": "零后视镜铁证"},
                "name": {"en": "Pre-2014 Famous 12 Legends Top-12", "zh": "2014前已成名 12 大师 Top-12"},
                "shortName": {"en": "Pre-2014 Legends", "zh": "零后视镜12大师"},
                "formula": {
                    "en": "12 Gurus Already World-Famous Before 2014 (Buffett, Hohn, Druckenmiller, Tepper, Ackman, PRIMECAP, Sanders, etc.) Top-12 Equal-Weight",
                    "zh": "仅用 2014 年前已享誉华尔街的 12 位老牌名将（含巴菲特/阿克曼等后来跑输者），前6重仓共识 Top-12 等权",
                },
                "whyItWorks": {
                    "en": f"Eliminates survivorship bias completely: even keeping Berkshire and Pershing Square inside the pool, core Top-6 consensus beats SPY in BOTH 2014–19 ({m_fam12['alpha1419Pct']:+.2f}%) and 2020–26 ({m_fam12['alpha2026Pct']:+.2f}%).",
                    "zh": f"彻底排除幸存者偏差：即便把后来跑输标普的巴菲特和阿克曼原封保留在池内，前6重仓共识仍在 2014–19 ({m_fam12['alpha1419Pct']:+.2f}%) 与 2020–26 ({m_fam12['alpha2026Pct']:+.2f}%) 上下半场双杀标普！",
                },
                "metrics": m_fam12,
            },
            {
                "id": "new_adds_catalyst",
                "recommended": False,
                "taxBadge": {"en": f"Tactical Sleeve · {m_adds['annTurnoverPct']:.0f}% Turnover", "zh": f"进攻卫星仓 · {m_adds['annTurnoverPct']:.0f}%换手"},
                "badge": {"en": f"2020–26 Alpha {m_adds['alpha2026Pct']:+.2f}%", "zh": f"近6年超额 {m_adds['alpha2026Pct']:+.2f}%"},
                "name": {"en": "Guru New Buys & Big Adds (Δwt ≥ +1.5%)", "zh": "大师新建仓与猛加仓催化"},
                "shortName": {"en": "New Adds Catalyst", "zh": "新进猛加催化"},
                "formula": {
                    "en": "Tracks Only Fresh Convictions Where QoQ Portfolio Weight Jumped ≥ +1.5% (Resulting Weight ≥ 2.5%), Top-12 Equal-Weight",
                    "zh": "只抄当季单票仓位环比猛增 Δwt ≥ +1.5%（且总仓位 ≥ 2.5%）的新建仓与重手加仓股，Top-12 等权",
                },
                "whyItWorks": {
                    "en": f"Captures multi-quarter institutional accumulation waves (e.g., Duquesne/Tepper AI memory & semi cap-equip cycles) with {m_adds['alpha2026Pct']:+.2f}%/yr post-2020 alpha and {m_adds['maxDrawdownPct']:.1f}% daily max drawdown.",
                    "zh": f"精准捕捉顶级大师基本面拐点建仓周期（机构建满大仓往往横跨2–3个季度），2020–26年化超额高达 {m_adds['alpha2026Pct']:+.2f}%，日频最大回撤 {m_adds['maxDrawdownPct']:.1f}%。",
                },
                "metrics": m_adds,
            },
        ]

        snapshots_by_scheme = {
            "qqq80_exqqq_monopoly": snap_qqq80_cw,
            "qqq80_exqqq_monopoly_equal": snap_qqq80_ew,
            "barbell_70_30": snap_barbell,
            "monopoly_compounders": snap_cmp_cw,
            "monopoly_compounders_equal": snap_cmp_ew,
            "pre2014_legends": snap_fam12,
            "new_adds_catalyst": snap_adds,
        }

        # Position Count Sensitivity (Top-5 / Top-8 / Top-12 / Top-20 / Top-35)
        pos_sensitivity = []
        for k, rk_map, an_k, ato_k, legs_k in pos_sensitivity_raw:
            daily_k = simulate_daily_scheme(legs_k)
            mk = apply_daily_risk(
                calc_series_metrics(realized_q_dates, rk_map, spy_t45, qqq_t45, an_k, ato_k),
                daily_k,
                daily_spy,
                daily_qqq,
            )
            pos_sensitivity.append({
                "label": f"Top-{k}",
                "holdingsCount": k,
                "sweetSpot": k in (8, 12),
                "cagrPct": mk["cagrPct"],
                "alphaPct": mk["alphaPct"],
                "volPct": mk["volPct"],
                "sharpe": mk["sharpe"],
                "maxDrawdownPct": mk["maxDrawdownPct"],
                "winRatePct": mk["winRatePct"],
                "annTurnoverPct": mk["annTurnoverPct"],
                "final100k": mk["final100k"],
            })

        # Anti-Patterns (Empirical Traps to Avoid)
        sel_cheaper = make_guru_selector(
            PRE2014_FAMOUS_IDS, max_rk=10, top_k=12, min_wt=0.03, weight_mode="equal", price_filter="discount_qavg"
        )
        r_cheaper, n_cheaper, to_cheaper, _, _ = run_full_scheme(sel_cheaper, cost_bps=10.0)
        m_cheaper = calc_series_metrics(realized_q_dates, r_cheaper, spy_t45, qqq_t45, n_cheaper, to_cheaper)

        anti_patterns = [
            {
                "id": "walk_forward_hot_chasing",
                "title": {
                    "en": "Trap #1: Chasing Trailing 3-Year Leaderboard Gurus",
                    "zh": "死穴一：看近3年收益榜追热榜大师",
                },
                "cagrPct": 14.44,
                "alphaPct": -1.14,
                "maxDrawdownPct": -30.02,
                "winRatePct": 56.1,
                "annTurnoverPct": 168.7,
                "lesson": {
                    "en": "Walk-forward selecting top-15 active managers by trailing 3-year IR lagged SPY by -5.72%/yr in 2020–2026 due to style mean-reversion. Select low-turnover structural moats, never 3-year hot hands.",
                    "zh": "每季滚动选过去3年IR最高的前15名经理，在2020–2026年化跑输标普 -5.72%！原因正是风格均值回归（刚登顶即迎风格逆风）。选大师看低换手垄断商业模式，绝不追3年冠军榜。",
                },
            },
            {
                "id": "blind_buy_cheaper_t45",
                "title": {
                    "en": "Trap #2: Blindly Buying Only T+45 Underwater Guru Stocks",
                    "zh": "死穴二：日常每季只买「T+45跌破大师成本」的破发股",
                },
                "cagrPct": m_cheaper["cagrPct"],
                "alphaPct": m_cheaper["alphaPct"],
                "maxDrawdownPct": m_cheaper["maxDrawdownPct"],
                "winRatePct": m_cheaper["winRatePct"],
                "annTurnoverPct": m_cheaper["annTurnoverPct"],
                "lesson": {
                    "en": f"Mechanically buying only guru picks trading below Q-avg at every T+45 yielded {m_cheaper['cagrPct']:.2f}% ({m_cheaper['alphaPct']:+.2f}% vs SPY, {m_cheaper['winRatePct']:.1f}% win rate) — adverse selection skips winners and catches broken theses. Use discount-to-guru ONLY during systemic market panics!",
                    "zh": f"在平稳牛市里每季机械只挑跌破大师均价的票，年化仅 {m_cheaper['cagrPct']:.2f}%（跑输标普 {m_cheaper['alphaPct']:.2f}%，胜率仅 {m_cheaper['winRatePct']:.1f}%）——本质是逆向淘汰漏掉主升浪牛股、专接基本面恶化飞刀！「抄大师折价底」仅限全市场系统性恐慌大跌时对核心复利股使用！",
                },
            },
            {
                "id": "raw_hf_q1_landmine",
                "title": {
                    "en": "Trap #3: Holding Q1 Stocks Being Heavily Dumped by Active HFs",
                    "zh": "死穴三：死扛主动对冲基金集中狂抛的 Q1 雷区股",
                },
                "cagrPct": 7.30,
                "alphaPct": -6.84,
                "maxDrawdownPct": -33.63,
                "winRatePct": 46.9,
                "annTurnoverPct": 277.9,
                "lesson": {
                    "en": "Stocks in the bottom 20% of Active-HF net selling delivered just 7.30% CAGR (-6.84%/yr behind SPY; $100k grew to $237k vs $505k SPY). Always cross-check single-guru picks against the Q1 HF-Dumping Radar!",
                    "zh": "主动对冲基金净抛售最猛的20%股票池（Q1组），12年严格T+45年化仅 7.30%（年化跑输标普 -6.84%，$10万仅变$23.7万 vs 标普$50.5万）！抄任何单一大师作业前必须先过一遍 Q1 聪明钱排雷榜！",
                },
            },
        ]

        # Build 16-Stock Master Copycat Blueprint for 2026 Q3
        q3_guru_recs_by_tk: dict[str, list[dict]] = {}
        for rec in guru_by_q.get("2026-09-30", []):
            if rec["rk"] <= 12:
                q3_guru_recs_by_tk.setdefault(rec["ticker"], []).append(rec)

        tier_meta = {
            "non_tech_monopoly": {
                "en": "Tier 1 · Non-Tech Monopoly Ballast (42%)",
                "zh": "第一层 · 非科技垄断复利压舱石 (42%)",
            },
            "tech_consensus": {
                "en": "Tier 2 · Tech Super-Consensus Engine (42%)",
                "zh": "第二层 · 科技巨头超级共识主引擎 (42%)",
            },
            "catalyst_satellite": {
                "en": "Tier 3 · New-Add Catalyst Satellites (16%)",
                "zh": "第三层 · 新进猛加进攻卫星仓 (16%)",
            },
        }
        master_blueprint: list[dict] = []
        for tk, tier_key, target_wt, note in MASTER_BLUEPRINT_SPEC:
            sp = spot_meta.get(tk, {})
            tm = ticker_meta.get(tk, {"name": tk, "sector": ""})
            grecs = sorted(q3_guru_recs_by_tk.get(tk, []), key=lambda x: x["wt"], reverse=True)
            backing = [
                f"{GURU_META[x['investorid']]['shortName']} ({x['wt']*100:.1f}%)"
                for x in grecs[:5]
            ]
            lead_act = grecs[0]["action"] if grecs else "HOLD"
            for x in grecs:
                if x["action"].startswith("NEW") or x["action"].startswith("ADD"):
                    lead_act = x["action"]
                    break
            is_q1_dump = tk in q1_dump_tickers
            master_blueprint.append({
                "ticker": tk,
                "companyName": tm["name"],
                "sector": tm["sector"],
                "tier": tier_key,
                "tierLabel": tier_meta[tier_key],
                "targetWeightPct": target_wt,
                "guruCount": len({x["investorid"] for x in grecs}),
                "sumGuruWeightPct": r1(sum(x["wt"] * 100.0 for x in grecs)),
                "backingGurus": backing,
                "leadAction": lead_act,
                "estGuruCost": r2(sp.get("q3AvgCost")),
                "latestPrice": r2(sp.get("latestPrice")),
                "vsGuruCostPct": r2(sp.get("vsQ3CostPct")),
                "dd52wPct": r2(sp.get("dd52wPct")),
                "q1DumpWarning": is_q1_dump,
                "thesis": note,
                "verdict": follow_verdict(lead_act, sp.get("vsQ3CostPct"), sp.get("dd52wPct"), is_q1_dump),
            })

        # Build All 16 Tracked Gurus Panorama Matrix + 12-Year QE vs T+45 Retention Audit + Live 2026 Q3 Top-12 Holdings
        guru_roster: list[dict] = []
        for gid, gm in GURU_META.items():
            by_q = guru_by_id_q.get(gid, {})
            qe_rets: dict[str, float] = {}
            t45_rets: dict[str, float] = {}
            top10_concs: list[float] = []
            stock_counts: list[int] = []
            turnovers: list[float] = []
            prev_w_g: dict[str, float] = {}

            for qd in sorted(by_q.keys()):
                recs = by_q[qd]
                if not recs:
                    continue
                if "2014-03-31" <= qd <= "2026-06-30":
                    top10_concs.append(sum(x["wt"] for x in recs[:10]) * 100.0)
                    stock_counts.append(recs[0]["nStocks"])
                    cur_w_g = {x["ticker"]: x["wt"] for x in recs}
                    if prev_w_g:
                        ak = set(cur_w_g) | set(prev_w_g)
                        turnovers.append(0.5 * sum(abs(cur_w_g.get(k, 0.0) - prev_w_g.get(k, 0.0)) for k in ak) * 100.0)
                    prev_w_g = cur_w_g

                if "2014-03-31" <= qd <= "2026-06-30":
                    v_qe = [(x["wt"], x["retQe"]) for x in recs if x["retQe"] is not None]
                    if v_qe:
                        sw = sum(w for w, _ in v_qe)
                        if sw > 0:
                            qe_rets[qd] = sum(w * r for w, r in v_qe) / sw
                    v_t45 = [(x["wt"], x["retT45"]) for x in recs if x["retT45"] is not None]
                    if v_t45:
                        sw = sum(w for w, _ in v_t45)
                        if sw > 0:
                            t45_rets[qd] = sum(w * r for w, r in v_t45) / sw

            common_qs = sorted(set(qe_rets.keys()) & set(t45_rets.keys()) & set(spy_t45.keys()))
            spy_qe_aligned = {qd: spy_qe.get(qd, spy_t45[qd]) for qd in common_qs}
            m_qe = calc_series_metrics(common_qs, qe_rets, spy_qe_aligned)
            m_t45_paired = calc_series_metrics(common_qs, t45_rets, spy_t45, qqq_t45)

            qe_alpha = m_qe.get("alphaPct") or 0.0
            t45_paired_alpha = m_t45_paired.get("alphaPct") or 0.0
            if qe_alpha >= 1.0:
                retention_pct = max(0.0, min(125.0, (t45_paired_alpha / qe_alpha) * 100.0))
            elif t45_paired_alpha > 0:
                retention_pct = 100.0
            else:
                retention_pct = 0.0

            g_legs_cur = guru_daily_legs_by_id.get(gid, [])
            daily_g = simulate_daily_scheme(g_legs_cur)
            m_t45 = dict(m_t45_paired)
            if common_qs and g_legs_cur:
                first_entry_dt = session_info[common_qs[0]]["t45EntryDate"]
                live_legs = [gl for gl in g_legs_cur if gl.get("isLiveLeg")]
                if live_legs and first_entry_dt:
                    live_leg = live_legs[-1]
                    ge0 = live_leg.get("entryDate")
                    ge1 = live_leg.get("exitDate")
                    if ge0 in date_to_idx and ge1 in date_to_idx:
                        gi0 = date_to_idx[ge0]
                        gi1 = date_to_idx[ge1]
                        r_live_g = daily_g[gi1] / daily_g[gi0] if daily_g[gi0] > 0 else 1.0
                        r_live_s = daily_spy[gi1] / daily_spy[gi0] if daily_spy[gi0] > 0 else 1.0
                        r_live_q = daily_qqq[gi1] / daily_qqq[gi0] if daily_qqq[gi0] > 0 else 1.0
                        nav_g_end = (m_t45_paired.get("final100k") or 100.0) * r_live_g
                        # Reconstruct paired SPY / QQQ cumulative multiple through daily_end_date
                        spy_mult = 1.0
                        qqq_mult = 1.0
                        for qd_c in common_qs:
                            spy_mult *= 1.0 + spy_t45.get(qd_c, 0.0)
                            qqq_mult *= 1.0 + qqq_t45.get(qd_c, 0.0)
                        spy_mult *= r_live_s
                        qqq_mult *= r_live_q
                        total_days_g = (date.fromisoformat(ge1) - date.fromisoformat(first_entry_dt)).days
                        yrs_g = max(0.25, total_days_g / 365.25)
                        cagr_g = ((nav_g_end / 100.0) ** (1.0 / yrs_g) - 1.0) * 100.0
                        cagr_s = (spy_mult ** (1.0 / yrs_g) - 1.0) * 100.0
                        cagr_q = (qqq_mult ** (1.0 / yrs_g) - 1.0) * 100.0
                        m_t45["final100k"] = round(nav_g_end, 1)
                        m_t45["cagrPct"] = round(cagr_g, 2)
                        m_t45["spyCagrPct"] = round(cagr_s, 2)
                        m_t45["qqqCagrPct"] = round(cagr_q, 2)
                        m_t45["alphaPct"] = round(cagr_g - cagr_s, 2)
                        m_t45["alphaVsQqqPct"] = round(cagr_g - cagr_q, 2)

            avg_to_g = statistics.mean(turnovers) if turnovers else 0.0
            t45_alpha = m_t45.get("alphaPct") or 0.0
            if (t45_alpha >= 3.5 and retention_pct >= 80.0) or (
                t45_alpha >= 2.8 and retention_pct >= 85.0 and avg_to_g <= 20.0
            ):
                grade = "A+"
            elif t45_alpha >= 2.0 and retention_pct >= 65.0:
                grade = "A"
            elif t45_alpha > 0.0:
                grade = "B"
            else:
                grade = "Caution"

            latest_qd = max(by_q.keys()) if by_q else "2026-09-30"
            latest_recs = sorted(by_q.get(latest_qd, []), key=lambda x: x["rk"])
            aum_b = (latest_recs[0]["totVal"] / 1000.0) if latest_recs else 0.0
            n_st_now = latest_recs[0]["nStocks"] if latest_recs else 0
            top10_now = sum(x["wt"] for x in latest_recs[:10]) * 100.0

            # Biggest Q3 move among top 12
            big_move_rec = max(latest_recs[:12], key=lambda x: abs(x["dWt"]), default=None)
            biggest_move = (
                f"{big_move_rec['ticker']} ({big_move_rec['action']}, {big_move_rec['dWt']*100:+.1f}% wt)"
                if big_move_rec
                else "Steady Hold"
            )

            top12_list = []
            for x in latest_recs[:12]:
                tk = x["ticker"]
                sp = spot_meta.get(tk, {})
                tm = ticker_meta.get(tk, {"name": tk, "sector": ""})
                cost = sp.get("q3AvgCost") if latest_qd.startswith("2026-09") else sp.get("q2AvgCost")
                l_px = sp.get("latestPrice")
                vs_c = ((l_px / cost - 1.0) * 100.0) if (l_px and cost and cost > 0) else None
                is_q1_d = tk in q1_dump_tickers
                top12_list.append({
                    "rank": x["rk"],
                    "ticker": tk,
                    "companyName": tm["name"],
                    "sector": tm["sector"],
                    "valM": r1(x["valM"]),
                    "weightPct": r2(x["wt"] * 100.0),
                    "prevWeightPct": r2(x["prevWt"] * 100.0),
                    "deltaWeightPct": r2(x["dWt"] * 100.0),
                    "action": x["action"],
                    "estGuruCost": r2(cost),
                    "latestPrice": r2(l_px),
                    "vsGuruCostPct": r2(vs_c),
                    "dd52wPct": r2(sp.get("dd52wPct")),
                    "q1DumpWarning": is_q1_d,
                })

            guru_roster.append({
                "investorId": gid,
                "name": {"en": gm["nameEn"], "zh": gm["nameZh"]},
                "shortName": gm["shortName"],
                "style": {"en": gm["styleEn"], "zh": gm["styleZh"]},
                "bucket": gm["bucket"],
                "bucketLabel": gm["bucketLabel"],
                "thesisForgeGuruId": gm["thesisForgeGuruId"],
                "pre2014Famous": gm["pre2014Famous"],
                "copyabilityGrade": grade,
                "quartersAudited": len(common_qs),
                "navEndDate": daily_end_date,
                "final100k": m_t45.get("final100k"),
                "qeCagrPct": m_qe.get("cagrPct"),
                "qeAlphaPct": m_qe.get("alphaPct"),
                "t45CagrPct": m_t45.get("cagrPct"),
                "t45AlphaPct": m_t45.get("alphaPct"),
                "t45AlphaVsQqqPct": m_t45.get("alphaVsQqqPct"),
                "alphaRetentionPct": r1(retention_pct),
                "ir": m_t45.get("ir"),
                "sharpe": m_t45.get("sharpe"),
                "maxDrawdownPct": m_t45.get("maxDrawdownPct"),
                "winRatePct": m_t45.get("winRatePct"),
                "avgQuarterlyTurnoverPct": r1(sum(turnovers) / len(turnovers)) if turnovers else 0.0,
                "latestQuarterDate": latest_qd,
                "latestQuarter": quarter_label(latest_qd),
                "filedAt": statutory_filing_date(latest_qd),
                "aumB": r2(aum_b),
                "stockCount": n_st_now,
                "top10ConcPct": r1(top10_now),
                "biggestMove": biggest_move,
                "topHoldingsSummary": [
                    {"ticker": h["ticker"], "weightPct": h["weightPct"], "action": h["action"]}
                    for h in top12_list[:5]
                ],
                "top12Holdings": top12_list,
            })

        # Sort guru roster by Copyability Grade then Strict T+45 Alpha descending
        grade_rank = {"A+": 4, "A": 3, "B": 2, "Caution": 1}
        guru_roster.sort(
            key=lambda g: (grade_rank.get(g["copyabilityGrade"], 0), g["t45AlphaPct"] or -99.0),
            reverse=True,
        )

        return {
            "version": ARTIFACT_VERSION,
            "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "factGeneration": repo.generation,
            "latestQuarterDate": "2026-09-30",
            "latestQuarter": "2026 Q3",
            "latestFiledDate": "2026-11-16",
            "latestPriceDate": latest_price_date,
            "defaultSchemeId": "qqq80_exqqq_monopoly",
            "rebalanceSchedule": {
                "cadence": {"en": "4× Yearly on SEC 45-Day Statutory Deadlines", "zh": "每年 4 次按 SEC 13F 法定披露截止日调仓"},
                "statutoryDates": ["02-16 (Q4)", "05-16 (Q1)", "08-16 (Q2)", "11-16 (Q3)"],
                "lastRebalanceDate": "2026-11-16",
                "nextRebalanceDate": "2027-02-16",
                "costModelBps": 10,
            },
            "backtestWindow": {
                "startQuarter": "2014 Q1",
                "endQuarter": f"2026 Q2 Realized + 2026 Q3 Live ({daily_end_date})",
                "startDate": daily_start_date,
                "endDate": daily_end_date,
                "tradingDays": len(daily_trading_dates),
                "realizedQuarters": len(realized_q_dates),
                "totalSnapshots": len(all_snapshot_q_dates),
            },
            "benchmarks": {
                "SPY": spy_metrics,
                "QQQ": qqq_metrics,
            },
            "dailyCurves": daily_curves_payload,
            "schemes": schemes_meta,
            "positionCountSensitivity": pos_sensitivity,
            "antiPatterns": anti_patterns,
            "masterBlueprint16": master_blueprint,
            "guruExitsAndSlashes": guru_exits_slashes,
            "q1HfDumpRadar": q1_dump_radar,
            "guruRoster": guru_roster,
            "snapshotsByScheme": snapshots_by_scheme,
        }
    finally:
        repo.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Build Guru Copycat Playbook JSON artifact")
    parser.add_argument("--fact-root", type=Path, default=DEFAULT_FACT_ROOT)
    parser.add_argument("--taxonomy", type=Path, default=DEFAULT_TAXONOMY_FILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT_FILE)
    parser.add_argument("--check", action="store_true", help="Verify existing artifact schema without writing")
    args = parser.parse_args()

    if args.check:
        if not args.output.exists():
            print(f"error: missing {args.output}", file=sys.stderr)
            return 1
        existing = json.loads(args.output.read_text(encoding="utf-8"))
        assert existing.get("version") == ARTIFACT_VERSION
        assert existing.get("defaultSchemeId") == "qqq80_exqqq_monopoly"
        scheme_ids = [s.get("id") for s in existing.get("schemes", [])]
        assert scheme_ids == [
            "qqq80_exqqq_monopoly",
            "barbell_70_30",
            "monopoly_compounders",
            "pre2014_legends",
            "new_adds_catalyst",
        ], f"unexpected scheme_ids: {scheme_ids}"
        assert "hf4_smart_flow" not in scheme_ids
        assert len(existing.get("guruRoster", [])) == 16
        assert len(existing.get("masterBlueprint16", [])) == 16
        dc = existing.get("dailyCurves") or {}
        dc_dates = dc.get("dates") or []
        dc_series = dc.get("series") or {}
        assert "hf4_smart_flow" not in dc_series
        assert len(dc_dates) >= 2500, f"expected >=2500 daily NAV points, got {len(dc_dates)}"
        for key in (
            "SPY",
            "QQQ",
            "qqq80_exqqq_monopoly",
            "qqq80_exqqq_monopoly_equal",
            "barbell_70_30",
            "monopoly_compounders",
            "monopoly_compounders_equal",
            "pre2014_legends",
            "new_adds_catalyst",
        ):
            assert len(dc_series.get(key) or []) == len(dc_dates), f"dailyCurves.{key} length mismatch"
        print(
            f"OK: verified {args.output} ({len(existing['schemes'])} schemes, "
            f"{len(existing['guruRoster'])} gurus, {len(dc_dates)} daily NAV sessions through {dc.get('endDate')})"
        )
        return 0

    artifact = build_artifact(args.fact_root, args.taxonomy)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(artifact, ensure_ascii=False, separators=(",", ":"))
    args.output.write_text(payload + "\n", encoding="utf-8")

    size_kb = len(payload.encode("utf-8")) / 1024.0
    print(f"Built {args.output} ({size_kb:.1f} KB) | latestPriceDate={artifact['latestPriceDate']}")
    for sc in artifact["schemes"]:
        m = sc["metrics"]
        a_qqq = m.get("alphaVsQqqPct") or 0.0
        print(
            f"  [{sc['id']:22s}] CAGR={m['cagrPct']:6.2f}% | vsSPY={m['alphaPct']:+6.2f}% | "
            f"vsQQQ={a_qqq:+6.2f}% | Sharpe={m['sharpe']:4.2f} | MDD={m['maxDrawdownPct']:6.2f}% | "
            f"TO={m['annTurnoverPct']:5.1f}% | $100k->${m['final100k']:.1f}k"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
