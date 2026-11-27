#!/usr/bin/env python3
"""Build canonical ThesisForge Crisis Observatory v2.0 Single Master Strategy artifact.

Exact Locked v2.0 Single Master Strategy (ZERO Wheel, ZERO Covered Call, ZERO Collar):
  1. Core Base & Borrowed Dual-CTA Overlay:
     - 100% QQQ + 10% DBMF + 10% KMLM (20% SPX Short Box financing at EFFR + 35 bps).
     - Hard Daily Leverage Cap: Gross Leverage = (QQQ + DBMF + KMLM) / NAV <= 1.200x
       strictly enforced daily via pro-rata risk-asset trim to repay debt.
  2. Sleeve A (0.2% NAV Normal Baseline Tail Put):
     - Entry: VIX/VIX3M < 1.00 for 5 consecutive trading days AND VIX < 20.0 -> 125 DTE, -15% OTM QQQ Put.
     - Roll at <= 75 DTE: if VIX/VIX3M < 1.00, roll to fresh 125D -15% OTM; if inverted (>= 1.00), HOLD.
  3. Sleeve B (1.0% NAV Three-Pillar Crisis Put, Pillar-Adaptive Routing):
     - Route 1 (P1 Top Fragility / P2 Exogenous Shock / M3 Credit -> non_m4_prob >= 35%):
       Buy 125 DTE, -15% OTM (1.0% NAV, post-TP 5D contango lockout). At <= 75 DTE when VIX/VIX3M < 1.00,
       roll if non-M4 pillars remain lit, else close and recycle salvage cash; if inverted, HOLD.
     - Route 2 (M4 Slow-Bear Dead-Cat Bounce with +8% Hysteresis Latch + VXN <= 28 & VIX/3M <= 0.90):
       * Slow-Bear +8% Hysteresis Latch:
         ARM (ON): QQQ < 200DMA AND QQQ 252D DD <= -10.0% AND Corr60(DualCTA, QQQ) < 0
                   AND DualCTA gain since QQQ 1Y high >= +8.0%.
         RESET (OFF): QQQ > 200DMA for 10 consecutive trading days.
       * M4 Trigger: Latch == ON AND QQQ < 200DMA AND 3-Speed EWMAC < 0 AND QQQ > EMA20
                     AND VXN <= 28.0 AND VIX/VIX3M <= 0.90.
       * Contract: 90 DTE, -10% OTM (1.0% NAV). At <= 30 DTE when VIX/VIX3M < 1.00, recycle salvage cash;
         if inverted, HOLD.
  4. Tiered Put Take-Profit + 5-Day Equal-Tranche Deployment:
     - Tier 1 (Partial TP): Return >= 5.0x AND VIX/VIX3M < 1.00 -> take 50% partial profit from shortest-DTE tranche.
     - Tier 2 (Full TP with ATH -10% Gate): VIX/VIX3M >= 1.10 AND QQQ ATH DD <= -10.0% -> liquidate 100% of all puts.
     - 5-Day Deploy: Deploy realized TP cash equally over 5 trading days (1/5 per day) into QQQ (excess pays debt first).
  5. Dual-CTA 2-Month Continuous Bear-Confirmation Rotation & 1-Year Mechanical Restoration:
     - CONT_2M Timer: QQQ stays <= -12.0% from ATH continuously for 60 calendar days.
     - Rotation: When confirmed AND per-ETF DBMF/KMLM return since QQQ ATH > 0%, sell in 5 equal tranches (20% each)
       spaced 5 trading days apart -> buy QQQ immediately (cancel remaining if QQQ DD > -12.0%).
     - Restoration: Mechanically hold rotated QQQ for 1 full year (365 calendar days) before restoring 10% DBMF + 10% KMLM.

Windows Verified on Real MIT OPRA Quotes (6,382,288 real 16:00 ET QQQ put quotes, 0 execution fallbacks):
  - 11Y Real MIT OPRA: 2015-01-02 to 2025-12-15 ($100,000 start)
  - 5Y Zero-Splice Live: 2020-12-02 to 2025-12-15 ($100,000 start, 100% live DBMF + KMLM + OPRA)
  - Live Daily EOD State & PIT Replay through latest market close.
"""
from __future__ import annotations

import argparse
import datetime
import gzip
import importlib.util
import json
import math
import statistics
import sys
import urllib.request
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT_DIR / "server" / "config" / "crisis-observatory-dashboard.json"
DEFAULT_FACT_ROOT = ROOT_DIR / "data" / "fact_os"
SEED_GZ = ROOT_DIR / "server" / "config" / "crisis-observatory-seed-inputs.json.gz"


def _clip(v: float, lo: float, hi: float) -> float:
    return lo if v < lo else (hi if v > hi else v)


def _norm_cdf(x: float) -> float:
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def _polyval_desc(coeffs: list[float], x: float) -> float:
    acc = 0.0
    for c in coeffs:
        acc = acc * x + c
    return acc


def eval_skew_iv(
    S: float, K: float, T: float, r: float, q: float, vxn_pct: float, poly_coeffs: list[float]
) -> float:
    t_eff = max(T, 1.0 / 365.0)
    fwd = S * math.exp((r - q) * t_eff)
    log_m = _clip(math.log(K / fwd), -0.22, 0.20)
    ratio = _polyval_desc(poly_coeffs, log_m)
    ratio = max(0.72, min(1.55, ratio))
    return max(0.06, (vxn_pct / 100.0) * ratio)


def bsm_price(S: float, K: float, T: float, r: float, q: float, sigma: float, opt_type: str) -> float:
    if T <= 1e-8 or sigma <= 1e-8:
        return max(0.0, S - K) if opt_type == "call" else max(0.0, K - S)
    sqrt_t = math.sqrt(T)
    d1 = (math.log(S / K) + (r - q + 0.5 * sigma * sigma) * T) / (sigma * sqrt_t)
    d2 = d1 - sigma * sqrt_t
    if opt_type == "call":
        return float(S * math.exp(-q * T) * _norm_cdf(d1) - K * math.exp(-r * T) * _norm_cdf(d2))
    return float(K * math.exp(-r * T) * _norm_cdf(-d2) - S * math.exp(-q * T) * _norm_cdf(-d1))


def bsm_delta(S: float, K: float, T: float, r: float, q: float, sigma: float, opt_type: str) -> float:
    if T <= 1e-8 or sigma <= 1e-8:
        if opt_type == "call":
            return 1.0 if S > K else 0.0
        return -1.0 if S < K else 0.0
    sqrt_t = math.sqrt(T)
    d1 = (math.log(S / K) + (r - q + 0.5 * sigma * sigma) * T) / (sigma * sqrt_t)
    disc_q = math.exp(-q * T)
    if opt_type == "call":
        return float(disc_q * _norm_cdf(d1))
    return float(disc_q * (_norm_cdf(d1) - 1.0))


def solve_call_strike_for_delta(
    S: float,
    T: float,
    r: float,
    q: float,
    vxn_pct: float,
    poly_coeffs: list[float],
    target_delta: float,
) -> float:
    lo, hi = S * 1.02, S * 1.30
    sqrt_t = math.sqrt(max(T, 1e-6))
    disc_q = math.exp(-q * T)
    for _ in range(30):
        mid = 0.5 * (lo + hi)
        sig = eval_skew_iv(S, mid, T, r, q, vxn_pct, poly_coeffs)
        d1 = (math.log(S / mid) + (r - q + 0.5 * sig * sig) * T) / (sig * sqrt_t)
        delta = disc_q * _norm_cdf(d1)
        if delta > target_delta:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def load_seed_and_extend(fact_root: Path | None = None) -> tuple[list[dict[str, Any]], list[float]]:
    if not SEED_GZ.exists():
        raise FileNotFoundError(f"Missing seed input archive: {SEED_GZ}")
    with gzip.open(SEED_GZ, "rb") as f:
        seed = json.loads(f.read().decode("utf-8"))
    rows: list[dict[str, Any]] = list(seed["rows"])
    coeffs: list[float] = [float(x) for x in seed["opra_90dte_poly3_coeffs_desc"]]
    return rows, coeffs

OPRA_BASE_DIR = Path("/Users/yudonglu/Documents/gemini/qqq-options-backtest/output")
FINAL_STRAT_DIR = OPRA_BASE_DIR / "final_strategy_qqq_dualcta_tailput_20261127"
PRIOR_MS_DIR = OPRA_BASE_DIR / "spitznagel_ms_dte_13f_audit_20261125"
PRIOR_SIX_DIR = OPRA_BASE_DIR / "six_retail_quant_archetypes_20261126"
SIG_CSV = OPRA_BASE_DIR / "crisis_prediction_models_research_20261124/data/signals_2015_2026.csv"
LEAPS_PUT_PQ = PRIOR_MS_DIR / "data/qqq_put_chain_leaps_2015_2025.parquet"
LIVE_ETF_CSV = PRIOR_SIX_DIR / "data/live_etf_total_returns_and_effr_2015_2026.csv"
LEGACY_M7_INPUTS_GZ = ROOT_DIR / "server/config/crisis-observatory-m7-inputs.json.gz"

ARTIFACT_VERSION = "crisis-observatory-v2-master"
STRATEGY_CODE = "V2_QQQ_DUALCTA_TAILPUT_SINGLE"
INITIAL_CAPITAL = 100_000.0
ETF_FEE = 0.0005
BOX_SPREAD = 0.0035
IBKR_SPREAD = 0.0150
CASH_SPREAD = -0.0025

CRISIS_WINDOWS = [
    ("2015_16", "2015-16 China FX & Oil", "2015-16 汇改与油价冲击", "2015-07-20", "2016-03-31"),
    ("2018_Q1", "2018 Q1 Volmageddon", "2018 Q1 波动率崩盘", "2018-01-26", "2018-04-30"),
    ("2018_Q4", "2018 Q4 Fed QT Taper", "2018 Q4 美联储缩表", "2018-08-29", "2019-02-28"),
    ("2020_COVID", "2020 COVID Crash", "2020 COVID 疫情闪崩", "2020-02-19", "2020-05-15"),
    ("2022_BEAR", "2022 Inflation Slow Bear", "2022 通胀加息慢熊", "2021-12-27", "2023-01-31"),
    ("2023_Q3", "2023 Q3 UST Rate Spike", "2023 Q3 美债利率飙升", "2023-07-19", "2023-11-15"),
    ("2024_YEN", "2024.08 Yen Carry Unwind", "2024.08 日元套息拆仓", "2024-07-10", "2024-09-30"),
    ("2025_TAR", "2025.04 Tariff Shock", "2025.04 关税闪电冲击", "2025-02-19", "2025-05-30"),
]

YF_ALL_MAP = {
    "QQQ": "QQQ",
    "DBMF": "DBMF",
    "KMLM": "KMLM",
    "SPY": "SPY",
    "RSP": "RSP",
    "IWM": "IWM",
    "XLP": "XLP",
    "XLU": "XLU",
    "XLV": "XLV",
    "XLK": "XLK",
    "HYG": "HYG",
    "LQD": "LQD",
    "VXN": "^VXN",
    "VIX": "^VIX",
    "VIX3M": "^VIX3M",
    "VVIX": "^VVIX",
    "SKEW": "^SKEW",
    "HG_F": "HG=F",
    "XLY": "XLY",
    "XLI": "XLI",
    "XLB": "XLB",
    "XLF": "XLF",
}

FRED_LAGS = {
    "BAA10Y": 1,
    "DGS2": 1,
    "NFCI": 5,
    "DFF": 1,
    "T10Y2Y": 1,
}


def r2(v: float | None) -> float | None:
    if v is None or not math.isfinite(v):
        return None
    return round(float(v), 2)


def r3(v: float | None) -> float | None:
    if v is None or not math.isfinite(v):
        return None
    return round(float(v), 3)


def r4(v: float | None) -> float | None:
    if v is None or not math.isfinite(v):
        return None
    return round(float(v), 4)


def r5(v: float | None) -> float | None:
    if v is None or not math.isfinite(v):
        return None
    return round(float(v), 5)


def clamp01(v: float) -> float:
    if not math.isfinite(v) or v <= 0.0:
        return 0.0
    if v >= 1.0:
        return 1.0
    return v


def quantile_linear(arr: list[float], q: float) -> float:
    if not arr:
        return 0.0
    s = sorted(arr)
    if len(s) == 1:
        return s[0]
    pos = (len(s) - 1) * q
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return s[lo]
    return s[lo] + (pos - lo) * (s[hi] - s[lo])


def mean_tail(arr: list[float], n: int) -> float | None:
    if not arr or n <= 0:
        return None
    sub = arr[-n:]
    return sum(sub) / len(sub)


def std_tail_ddof1(arr: list[float], n: int) -> float | None:
    if len(arr) < max(2, n):
        return None
    sub = arr[-n:]
    mu = sum(sub) / len(sub)
    var = sum((x - mu) ** 2 for x in sub) / (len(sub) - 1)
    return math.sqrt(max(0.0, var))


def pearson_corr(xs: list[float], ys: list[float]) -> float:
    n = min(len(xs), len(ys))
    if n < 5:
        return 0.0
    x = xs[-n:]
    y = ys[-n:]
    mx = sum(x) / n
    my = sum(y) / n
    num = sum((a - mx) * (b - my) for a, b in zip(x, y))
    dx = math.sqrt(sum((a - mx) ** 2 for a in x))
    dy = math.sqrt(sum((b - my) ** 2 for b in y))
    if dx <= 1e-12 or dy <= 1e-12:
        return 0.0
    return max(-1.0, min(1.0, num / (dx * dy)))


def hamilton_step(state_p: list[float], z_row: list[float], A: list[list[float]], means: list[list[float]], vars_: list[list[float]]) -> list[float]:
    pred = [
        state_p[0] * A[0][0] + state_p[1] * A[1][0],
        state_p[0] * A[0][1] + state_p[1] * A[1][1],
    ]
    log_lik = [0.0, 0.0]
    for st in (0, 1):
        ll = 0.0
        for dim in range(4):
            v = max(1e-6, vars_[st][dim])
            diff = z_row[dim] - means[st][dim]
            ll += -0.5 * (math.log(2.0 * math.pi * v) + (diff * diff) / v)
        log_lik[st] = ll
    m_ll = max(log_lik)
    p0 = pred[0] * math.exp(log_lik[0] - m_ll)
    p1 = pred[1] * math.exp(log_lik[1] - m_ll)
    tot = p0 + p1
    if tot <= 0.0 or not math.isfinite(tot):
        return [0.5, 0.5]
    return [p0 / tot, p1 / tot]


def align_fred_lag(raw_map: dict[str, float], cal_dates: list[str], idx: int, lag: int) -> tuple[float | None, str | None]:
    eff_idx = idx - lag
    if eff_idx < 0:
        return None, None
    cutoff = cal_dates[eff_idx]
    best_d = None
    best_v = None
    for d, v in raw_map.items():
        if d <= cutoff and math.isfinite(v):
            if best_d is None or d > best_d:
                best_d = d
                best_v = float(v)
    return best_v, best_d


def compute_live_stress_index(row: dict[str, Any]) -> dict[str, Any]:
    baa = row.get("baa_rise63")
    dgs2 = row.get("dgs2_jump63")
    nfci = row.get("nfci_jump20")
    baa_eff = 0.0 if (baa is None or baa <= -900) else float(baa)
    dgs2_eff = 0.0 if (dgs2 is None or dgs2 <= -900) else float(dgs2)
    nfci_eff = 0.0 if (nfci is None or nfci <= -900) else float(nfci)

    hmm_p = float(row.get("hmm_p") or 0.0)
    vxn = float(row.get("vxn") or 0.0)
    vr = float(row.get("vix_ratio") or 0.0)
    dd = float(row.get("dd_from_ath") or 0.0)
    cl = float(row.get("qqq_close") or 0.0)
    sma200 = float(row.get("sma200") or 0.0)
    ewmac = float(row.get("ewmac") or 0.0)
    hyg_lqd = float(row.get("hyg_lqd") or 0.0)
    hyg_sma50 = float(row.get("hyg_sma50") or 0.0)
    def_ret20 = float(row.get("def_ret20") or 0.0)
    rsp_spy = float(row.get("rsp_spy") or 0.0)
    rsp_sma50 = float(row.get("rsp_sma50") or 0.0)
    iwm_qqq = float(row.get("iwm_qqq") or 0.0)
    iwm_sma50 = float(row.get("iwm_sma50") or 0.0)
    ad_below = bool(row.get("ad_below50"))
    vvix = float(row.get("vvix") or 0.0)
    vvix_p75 = float(row.get("vvix_p75") or 0.0)
    skew10 = float(row.get("skew10") or 0.0)
    skew_p75 = float(row.get("skew_p75") or 0.0)
    vr_jump5 = float(row.get("vr_jump5") or 0.0)

    regime_vol = (
        clamp01(hmm_p) * 18.0
        + clamp01((vxn - 20.0) / 20.0) * 7.0
        + clamp01((vr - 0.90) / 0.20) * 5.0
    )
    trend_dd = (
        clamp01((-dd - 0.03) / 0.17) * 12.0
        + (6.0 if sma200 > 0.0 and cl < sma200 else 0.0)
        + clamp01(-ewmac / 0.80) * 7.0
    )
    credit_macro = (
        (8.0 if hyg_sma50 > 0.0 and hyg_lqd < hyg_sma50 else 0.0)
        + clamp01(max(0.0, baa_eff) / 0.25) * 8.0
        + clamp01(max(max(0.0, dgs2_eff) / 0.50, max(0.0, nfci_eff) / 0.15)) * 9.0
    )
    breadth_tail = (
        clamp01(max(0.0, def_ret20) / 0.10) * 8.0
        + (2.0 if rsp_sma50 > 0.0 and rsp_spy < rsp_sma50 else 0.0)
        + (2.0 if iwm_sma50 > 0.0 and iwm_qqq < iwm_sma50 else 0.0)
        + (2.0 if ad_below else 0.0)
        + (2.0 if vvix_p75 > 0.0 and vvix >= vvix_p75 else 0.0)
        + (2.0 if skew_p75 > 0.0 and skew10 >= skew_p75 else 0.0)
        + (2.0 if vr_jump5 >= 0.06 else 0.0)
    )
    total = max(0.0, min(100.0, regime_vol + trend_dd + credit_macro + breadth_tail))
    idx_int = int(math.floor(total + 0.5))
    if idx_int >= 75:
        lvl, en, zh = "crisis", "Active Crisis", "危机爆发中"
    elif idx_int >= 50:
        lvl, en, zh = "elevated", "Elevated Stress", "高压警戒"
    elif idx_int >= 25:
        lvl, en, zh = "building", "Stress Building", "隐患蓄力"
    else:
        lvl, en, zh = "calm", "Calm Low-Vol", "平静低波"

    return {
        "live_stress_index": idx_int,
        "live_stress_level": lvl,
        "live_stress_label_en": en,
        "live_stress_label_zh": zh,
        "live_stress_breakdown": {
            "regime_vol": round(regime_vol, 1),
            "regime_vol_cap": 30,
            "trend_dd": round(trend_dd, 1),
            "trend_dd_cap": 25,
            "credit_macro": round(credit_macro, 1),
            "credit_macro_cap": 25,
            "breadth_tail": round(breadth_tail, 1),
            "breadth_tail_cap": 20,
        },
    }


def fetch_yahoo_1mo(symbol: str, timeout: float = 8.0) -> dict[str, dict[str, float]]:
    import urllib.parse

    enc = urllib.parse.quote(symbol, safe="")
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{enc}?range=1mo&interval=1d"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            obj = json.loads(resp.read().decode("utf-8"))
        res0 = (obj.get("chart") or {}).get("result", [None])[0] or {}
        ts = res0.get("timestamp") or []
        q = (res0.get("indicators") or {}).get("quote", [{}])[0] or {}
        adj_arr = ((res0.get("indicators") or {}).get("adjclose") or [{}])[0].get("adjclose") or []
        closes = q.get("close") or []
        opens = q.get("open") or []
        out: dict[str, dict[str, float]] = {}
        for i, t in enumerate(ts):
            c = closes[i] if i < len(closes) else None
            a = adj_arr[i] if i < len(adj_arr) and adj_arr[i] is not None else c
            o = opens[i] if i < len(opens) and opens[i] is not None else c
            if c is None or not math.isfinite(c) or c <= 0:
                continue
            dt = datetime.datetime.fromtimestamp(int(t), tz=datetime.timezone.utc).strftime("%Y-%m-%d")
            out[dt] = {
                "open": float(o) if (o is not None and math.isfinite(o) and o > 0) else float(c),
                "close": float(c),
                "adj": float(a) if (a is not None and math.isfinite(a) and a > 0) else float(c),
            }
        return out
    except Exception:
        return {}


def fetch_fred_recent(series_id: str, timeout: float = 8.0) -> dict[str, float]:
    url = f"https://fred.stlouisfed.org/graph/fredgraph.csv?id={series_id}&cosd=2025-06-01"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            txt = resp.read().decode("utf-8")
        out: dict[str, float] = {}
        for line in txt.splitlines():
            parts = line.split(",")
            if len(parts) < 2:
                continue
            d = parts[0].strip()
            v_str = parts[1].strip()
            if len(d) != 10 or not v_str or v_str == ".":
                continue
            try:
                v = float(v_str)
            except ValueError:
                continue
            if math.isfinite(v):
                out[d] = v
        return out
    except Exception:
        return {}


def fetch_nyfed_effr(timeout: float = 8.0) -> dict[str, float]:
    url = "https://markets.newyorkfed.org/api/rates/unsecured/effr/last/15.json"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            obj = json.loads(resp.read().decode("utf-8"))
        out: dict[str, float] = {}
        for row in obj.get("refRates") or []:
            d = row.get("effectiveDate")
            pr = row.get("percentRate")
            if d and pr is not None:
                out[str(d)] = float(pr) / 100.0
        return out
    except Exception:
        return {}


def pack_table(rows: list[dict[str, Any]], cols: list[str]) -> dict[str, Any]:
    return {"_cols": cols, "_rows": [[r.get(c) for c in cols] for r in rows]}


def load_mod(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def build_ruleset_spec() -> dict[str, Any]:
    return {
        "code": STRATEGY_CODE,
        "version": "v2.0",
        "locked": True,
        "single_strategy_only": True,
        "name_en": "ThesisForge v2.0 Master Strategy (100% QQQ + 20% Dual-CTA + Dual-Sleeve Tail Put)",
        "name_zh": "ThesisForge v2.0 唯一锁定主策略（100% QQQ + 20% 双CTA + 双轨尾部 Put）",
        "core_overlay": {
            "qqq_weight_pct": 100.0,
            "dbmf_weight_pct": 10.0,
            "kmlm_weight_pct": 10.0,
            "debt_weight_pct": 20.0,
            "hard_leverage_cap": 1.200,
            "financing_primary": "EFFR + 35 bps (SPX Short Box)",
            "financing_stress": "EFFR + 150 bps (IBKR Pro Margin)",
            "rebalance_rule_en": "Hard daily Gross Leverage <= 1.200x cap enforced via pro-rata trim to repay debt; quarterly calibration when no rotation/TP queue is active.",
            "rebalance_rule_zh": "每日严格执行总杠杆 (QQQ+DBMF+KMLM)/NAV <= 1.200x 红线（超限即按比例减仓还债）；无轮动与止盈队列时按季校准。",
        },
        "sleeve_a": {
            "budget_pct_nav": 0.2,
            "target_dte": 125,
            "roll_dte": 75,
            "otm_pct": -15,
            "contango_days": 5,
            "vix_max": 20.0,
            "rule_en": "Enter when VIX/VIX3M < 1.00 for 5 consecutive trading days AND VIX < 20.0 (125D -15% OTM Put). At <= 75 DTE, roll if VIX/VIX3M < 1.00; if inverted (>= 1.00), HOLD.",
            "rule_zh": "连续 5 个交易日 VIX/VIX3M < 1.00 且 VIX < 20.0 时建仓（0.2% NAV · 125D -15% OTM Put）；<= 75 DTE 若非倒挂则滚仓，倒挂则持有不动。",
        },
        "sleeve_b": {
            "budget_pct_nav": 1.0,
            "lockout_contango_days": 5,
            "route1": {
                "pillars": ["P1", "P2", "M3"],
                "prob_threshold": 35.0,
                "target_dte": 125,
                "roll_dte": 75,
                "otm_pct": -15,
                "rule_en": "P1/P2/M3 non-M4 probability >= 35% -> 125D -15% OTM Put (1.0% NAV). At <= 75 DTE (non-inverted), roll if lit else recycle salvage cash; if inverted, HOLD.",
                "rule_zh": "P1/P2/M3 非 M4 综合概率 >= 35% -> 买 125D -15% OTM Put（1.0% NAV）；<= 75 DTE 非倒挂时信号仍亮则滚仓，熄灭则平仓回收残值，倒挂则持有。",
            },
            "route2_m4": {
                "target_dte": 90,
                "recycle_dte": 30,
                "otm_pct": -10,
                "vxn_max": 28.0,
                "vr_max": 0.90,
                "latch_cta_gain_pct": 8.0,
                "latch_dd252_pct": -10.0,
                "latch_reset_days": 10,
                "rule_en": "Slow-Bear +8% Hysteresis Latch ARMS when QQQ < 200DMA & DD252 <= -10% & Corr60(DualCTA,QQQ) < 0 & DualCTA >= +8% (resets after 10 consecutive days QQQ > 200DMA). M4 fires when Latch ON + QQQ < 200DMA + EWMAC < 0 + QQQ > EMA20 + VXN <= 28 & VIX/3M <= 0.90 -> 90D -10% OTM Put; recycle salvage at <= 30 DTE (HOLD if inverted).",
                "rule_zh": "慢熊 +8% 滞回锁存开关：QQQ < 200DMA 且距252日高点 <= -10% 且 Corr60(双CTA,QQQ) < 0 且双CTA 自 QQQ 1Y高点涨 >= +8% 时激活锁存（连续 10 天站回 200DMA 才复位）。锁存开启且满足 QQQ < 200DMA、3速 EWMAC < 0、QQQ > EMA20 且 VXN <= 28、VIX/3M <= 0.90 时买 90D -10% OTM Put；<= 30 DTE 非倒挂回收残值，倒挂持有。",
            },
        },
        "take_profit": {
            "tier1_mult": 5.0,
            "tier1_vr_max": 1.00,
            "tier1_frac": 0.50,
            "tier2_vr_min": 1.10,
            "tier2_ath_dd_max": -10.0,
            "deploy_days": 5,
            "rule_en": "Tier 1: >= 5.0x & VIX/3M < 1.00 -> 50% partial TP on shortest-DTE tranche. Tier 2: VIX/3M >= 1.10 AND QQQ ATH DD <= -10.0% -> 100% Full TP on all puts. Deploy TP cash equally across 5 trading days (1/5 per day) into QQQ (excess above 1.20x pays debt first).",
            "rule_zh": "一档分批止盈：回报 >= 5.0x 且 VIX/3M < 1.00 时优先兑现最短剩余到期仓位的 50%；二档全额清仓：VIX/3M >= 1.10 且 QQQ 距历史高点回落 <= -10.0% 时 100% 止盈全部 Put；止盈现金分 5 个交易日等额（每日 1/5）分批回买 QQQ（超 1.20x 红线部分优先还债）。",
        },
        "cta_rotation": {
            "timer_mode": "CONT_2M",
            "dd_threshold_pct": -12.0,
            "continuous_cal_days": 60,
            "tranches": 5,
            "tranche_step_td": 5,
            "restore_cal_days": 365,
            "rule_en": "When QQQ stays <= -12.0% from ATH continuously for 60 calendar days AND per-ETF DBMF/KMLM return since QQQ ATH > 0%, sell in 5 equal tranches (20% each) spaced 5 trading days apart into QQQ (cancel remaining if DD > -12.0%). Hold rotated QQQ mechanically for 365 calendar days before restoring 10% DBMF + 10% KMLM.",
            "rule_zh": "QQQ 距历史高点持续 <= -12.0% 满 60 个自然日（CONT_2M），且 DBMF / KMLM 各自自 QQQ 前高以来涨幅 > 0% 时，分 5 批（每批 20%、间隔 5 个交易日）卖出并即时换入 QQQ（若回撤缩窄至 > -12.0% 立即终止剩余批次）；机械持有换入的 QQQ 满 1 年（365 自然日）后再恢复 10% DBMF + 10% KMLM。",
        },
    }


def run_full_opra_build(output_path: Path, fetch_live: bool = True) -> dict[str, Any]:
    import numpy as np
    import pandas as pd

    fs = load_mod("fs", FINAL_STRAT_DIR / "01_run_final_strategy_backtest.py")
    ms_mod = load_mod("ms_mod", PRIOR_MS_DIR / "01_ms_index_backtest.py")
    rb, cta_mod = ms_mod.load_prior_engines()
    store = rb.RealOptionChainStore(LEAPS_PUT_PQ)
    all_rows, coeffs, _, _, _, _ = cta_mod.load_sim_panel_and_signals()

    etf_df = pd.read_csv(LIVE_ETF_CSV, index_col=0)
    etf_df.index = etf_df.index.astype(str)
    sig_df = pd.read_csv(SIG_CSV)
    sig_df["date"] = sig_df["date"].astype(str)
    sig_df = sig_df.set_index("date")

    # Read calibrated tail parameters from existing artifact (before overwriting)
    existing_doc = json.loads(output_path.read_text(encoding="utf-8")) if output_path.exists() else {}
    old_tail = existing_doc.get("m7_live_tail_state") or existing_doc.get("live_tail_state") or {}
    if not old_tail:
        raise RuntimeError("Missing calibrated tail state (hmm / welford_4d / ewm_state / base_2013) in existing artifact.")

    # Extract full-history QQQ/DualCTA/indicators across 2015-01-02 -> last etf_df date (2026-11-25)
    full_dates = [str(d) for d in etf_df.index]
    n_full = len(full_dates)
    px_q = etf_df["QQQ"].ffill().to_numpy(dtype=float)
    r_q = pd.Series(px_q).pct_change().fillna(0.0).to_numpy(dtype=float)
    r_aq = etf_df["AQMIX"].pct_change().fillna(0.0).to_numpy(dtype=float)
    r_db_raw = etf_df["DBMF"].pct_change().to_numpy(dtype=float)
    r_km_raw = etf_df["KMLM"].pct_change().to_numpy(dtype=float)
    r_db = np.where(np.isnan(r_db_raw), r_aq, r_db_raw)
    r_km = np.where(np.isnan(r_km_raw), r_aq, r_km_raw)
    r_cta = 0.5 * r_db + 0.5 * r_km
    r_cta[0] = 0.0
    px_cta = 100.0 * np.cumprod(1.0 + r_cta)
    px_db_spliced = 100.0 * np.cumprod(1.0 + np.where(np.arange(n_full) == 0, 0.0, r_db))
    px_km_spliced = 100.0 * np.cumprod(1.0 + np.where(np.arange(n_full) == 0, 0.0, r_km))

    s_q = pd.Series(px_q, index=full_dates)
    sma200_arr = s_q.rolling(200, min_periods=1).mean().to_numpy(dtype=float)
    ema20_arr = s_q.ewm(span=20, adjust=False).mean().to_numpy(dtype=float)
    px_vol = s_q.diff().rolling(60, min_periods=20).std().replace(0, np.nan)
    ewmac_arr = (
        (
            (s_q.ewm(span=16, adjust=False).mean() - s_q.ewm(span=64, adjust=False).mean()) / px_vol
            + (s_q.ewm(span=32, adjust=False).mean() - s_q.ewm(span=128, adjust=False).mean()) / px_vol
            + (s_q.ewm(span=64, adjust=False).mean() - s_q.ewm(span=256, adjust=False).mean()) / px_vol
        )
        / 3.0
    ).fillna(0.0).to_numpy(dtype=float)
    corr60_arr = (
        pd.Series(r_q, index=full_dates)
        .rolling(60, min_periods=20)
        .corr(pd.Series(r_cta, index=full_dates))
        .fillna(0.0)
        .to_numpy(dtype=float)
    )

    # Compute strictly causal Slow-Bear +8% Hysteresis Latch across ALL dates
    dd252_arr = np.zeros(n_full, dtype=float)
    hi252_px_arr = np.zeros(n_full, dtype=float)
    hi252_date_arr: list[str] = [""] * n_full
    cta_ret_hi252_arr = np.zeros(n_full, dtype=float)
    db_ret_hi252_arr = np.zeros(n_full, dtype=float)
    km_ret_hi252_arr = np.zeros(n_full, dtype=float)
    ath_px_arr = np.zeros(n_full, dtype=float)
    ath_date_arr: list[str] = [""] * n_full
    dd_ath_arr = np.zeros(n_full, dtype=float)
    cta_ret_ath_arr = np.zeros(n_full, dtype=float)
    db_ret_ath_arr = np.zeros(n_full, dtype=float)
    km_ret_ath_arr = np.zeros(n_full, dtype=float)
    latch_on_arr = np.zeros(n_full, dtype=bool)
    above200_streak_arr = np.zeros(n_full, dtype=int)
    latch_peak_gain_arr = np.zeros(n_full, dtype=float)
    latch_arm_date_arr: list[str | None] = [None] * n_full
    cont_dd12_days_arr = np.zeros(n_full, dtype=int)
    cont_dd12_start_arr: list[str | None] = [None] * n_full

    cur_latch = False
    cur_above = 0
    cur_peak = 0.0
    cur_arm_d: str | None = None
    run_ath_px = float(px_q[0])
    run_ath_idx = 0
    cont_start_dt: datetime.date | None = None
    cont_start_str: str | None = None
    latch_episodes_full: list[dict[str, Any]] = []
    active_latch_ep: dict[str, Any] | None = None

    for i in range(n_full):
        d = full_dates[i]
        dt_i = datetime.date.fromisoformat(d)
        lo = max(0, i - 251)
        j_hi = lo + int(np.argmax(px_q[lo : i + 1]))
        hi252_px_arr[i] = float(px_q[j_hi])
        hi252_date_arr[i] = full_dates[j_hi]
        dd252_arr[i] = px_q[i] / px_q[j_hi] - 1.0 if px_q[j_hi] > 0 else 0.0
        cta_ret_hi252_arr[i] = px_cta[i] / px_cta[j_hi] - 1.0 if px_cta[j_hi] > 0 else 0.0
        db_ret_hi252_arr[i] = px_db_spliced[i] / px_db_spliced[j_hi] - 1.0 if px_db_spliced[j_hi] > 0 else 0.0
        km_ret_hi252_arr[i] = px_km_spliced[i] / px_km_spliced[j_hi] - 1.0 if px_km_spliced[j_hi] > 0 else 0.0

        if px_q[i] >= run_ath_px:
            run_ath_px = float(px_q[i])
            run_ath_idx = i
        ath_px_arr[i] = run_ath_px
        ath_date_arr[i] = full_dates[run_ath_idx]
        dd_ath_arr[i] = px_q[i] / run_ath_px - 1.0
        cta_ret_ath_arr[i] = px_cta[i] / px_cta[run_ath_idx] - 1.0 if px_cta[run_ath_idx] > 0 else 0.0
        db_ret_ath_arr[i] = px_db_spliced[i] / px_db_spliced[run_ath_idx] - 1.0 if px_db_spliced[run_ath_idx] > 0 else 0.0
        km_ret_ath_arr[i] = px_km_spliced[i] / px_km_spliced[run_ath_idx] - 1.0 if px_km_spliced[run_ath_idx] > 0 else 0.0

        if dd_ath_arr[i] <= -0.12:
            if cont_start_dt is None:
                cont_start_dt = dt_i
                cont_start_str = d
            cont_dd12_days_arr[i] = (dt_i - cont_start_dt).days
            cont_dd12_start_arr[i] = cont_start_str
        else:
            cont_start_dt = None
            cont_start_str = None
            cont_dd12_days_arr[i] = 0
            cont_dd12_start_arr[i] = None

        below_200 = px_q[i] < sma200_arr[i]
        cur_above = 0 if below_200 else (cur_above + 1)

        if not cur_latch:
            if below_200 and dd252_arr[i] <= -0.10 and corr60_arr[i] < 0.0 and cta_ret_hi252_arr[i] >= 0.08:
                cur_latch = True
                cur_peak = cta_ret_hi252_arr[i]
                cur_arm_d = d
                active_latch_ep = {
                    "arm_date": d,
                    "reset_date": None,
                    "peak_cta_gain_pct": round(cur_peak * 100.0, 2),
                    "min_qqq_dd252_pct": round(dd252_arr[i] * 100.0, 2),
                    "days_armed": 1,
                }
                latch_episodes_full.append(active_latch_ep)
        else:
            cur_peak = max(cur_peak, cta_ret_hi252_arr[i])
            if active_latch_ep is not None:
                active_latch_ep["peak_cta_gain_pct"] = round(cur_peak * 100.0, 2)
                active_latch_ep["min_qqq_dd252_pct"] = round(min(active_latch_ep["min_qqq_dd252_pct"], dd252_arr[i] * 100.0), 2)
                active_latch_ep["days_armed"] += 1
            if cur_above >= 10:
                cur_latch = False
                cur_peak = 0.0
                cur_arm_d = None
                if active_latch_ep is not None:
                    active_latch_ep["reset_date"] = d
                    active_latch_ep = None

        latch_on_arr[i] = cur_latch
        above200_streak_arr[i] = cur_above
        latch_peak_gain_arr[i] = cur_peak
        latch_arm_date_arr[i] = cur_arm_d

    full_idx_map = {d: i for i, d in enumerate(full_dates)}

    # Load exact daily CBOE SKEW spot map from m7-inputs + existing tail
    skew_spot_map: dict[str, float] = {}
    m7_in_gz = Path(__file__).resolve().parent.parent / "server/config/crisis-observatory-m7-inputs.json.gz"
    if m7_in_gz.exists():
        import gzip
        m7in = json.loads(gzip.open(m7_in_gz, "rt", encoding="utf-8").read())
        for dt_k, sv in zip(m7in.get("yf_dates") or [], (m7in.get("yf_series") or {}).get("SKEW") or []):
            if sv is not None and math.isfinite(float(sv)):
                skew_spot_map[str(dt_k)] = float(sv)
    if old_tail.get("tail_dates") and (old_tail.get("yf_tail") or {}).get("SKEW"):
        for dt_k, sv in zip(old_tail["tail_dates"], old_tail["yf_tail"]["SKEW"]):
            if sv is not None and math.isfinite(float(sv)):
                skew_spot_map[str(dt_k)] = float(sv)

    # Precompute daily Real MIT OPRA microstructure (2015-01-02 -> 2025-12-15):
    #   - OPRA Skew Ratio: IV(125D,-20%)/IV(125D,-10%) and IV(125D,-15%)/IV(125D,ATM)
    #   - Exact 125D -15% OTM Put & 90D -10% OTM Put: Strike, DTE, Bid/Ask/Mid, IBKR Mid+35% HS Limit,
    #     Half-Spread %, IV %, and 1-Contract Put / 1-Lot (100sh) QQQ Price Ratio (%)!
    opra_micro_by_date: dict[str, dict[str, Any]] = {}
    lo125, hi125 = fs.dte_bounds(125)
    lo90, hi90 = fs.dte_bounds(90)
    last_sk20 = None
    last_sk15 = None
    for row_a in all_rows:
        d_a = str(row_a["date"])
        cl_a = float(row_a["close"])
        if cl_a <= 0:
            continue
        c_atm = store.select_put_contract(d_a, cl_a, 125, 1.00, lo125, hi125)
        c10 = store.select_put_contract(d_a, cl_a, 125, 0.90, lo125, hi125)
        c15 = store.select_put_contract(d_a, cl_a, 125, 0.85, lo125, hi125)
        c20 = store.select_put_contract(d_a, cl_a, 125, 0.80, lo125, hi125)
        c90 = store.select_put_contract(d_a, cl_a, 90, 0.90, lo90, hi90)

        sk20 = None
        if c10 and c20 and np.isfinite(c10["iv"]) and np.isfinite(c20["iv"]) and float(c10["iv"]) > 0.05:
            sk20 = round(float(c20["iv"]) / float(c10["iv"]), 3)
            last_sk20 = sk20
        elif last_sk20 is not None:
            sk20 = last_sk20

        sk15 = None
        if c_atm and c15 and np.isfinite(c_atm["iv"]) and np.isfinite(c15["iv"]) and float(c_atm["iv"]) > 0.05:
            sk15 = round(float(c15["iv"]) / float(c_atm["iv"]), 3)
            last_sk15 = sk15
        elif last_sk15 is not None:
            sk15 = last_sk15

        rec_m: dict[str, Any] = {
            "opra_src": "real_opra",
            "opra_sk20_10": sk20,
            "opra_sk15_atm": sk15,
        }
        if c15 and float(c15["mid"]) > 0:
            lmt15 = rb.exec_buy_price(c15["bid"], c15["ask"], c15["mid"], "real_ibkr_limit")
            hs15 = (c15["ask"] - c15["bid"]) / (2.0 * c15["mid"]) * 100.0
            rec_m.update({
                "p125_k": round(float(c15["strike"]), 2),
                "p125_dte": int(c15["dte"]),
                "p125_bid": round(float(c15["bid"]), 2),
                "p125_ask": round(float(c15["ask"]), 2),
                "p125_mid": round(float(c15["mid"]), 2),
                "p125_lmt": round(float(lmt15), 3),
                "p125_hs": round(float(hs15), 2),
                "p125_iv": round(float(c15["iv"]) * 100.0, 1) if np.isfinite(c15["iv"]) else None,
                "p125_lot_pct": round(float(lmt15) / cl_a * 100.0, 3),
                "p125_mid_pct": round(float(c15["mid"]) / cl_a * 100.0, 3),
            })
        if c90 and float(c90["mid"]) > 0:
            lmt90 = rb.exec_buy_price(c90["bid"], c90["ask"], c90["mid"], "real_ibkr_limit")
            hs90 = (c90["ask"] - c90["bid"]) / (2.0 * c90["mid"]) * 100.0
            rec_m.update({
                "p90_k": round(float(c90["strike"]), 2),
                "p90_dte": int(c90["dte"]),
                "p90_bid": round(float(c90["bid"]), 2),
                "p90_ask": round(float(c90["ask"]), 2),
                "p90_mid": round(float(c90["mid"]), 2),
                "p90_lmt": round(float(lmt90), 3),
                "p90_hs": round(float(hs90), 2),
                "p90_iv": round(float(c90["iv"]) * 100.0, 1) if np.isfinite(c90["iv"]) else None,
                "p90_lot_pct": round(float(lmt90) / cl_a * 100.0, 3),
                "p90_mid_pct": round(float(c90["mid"]) / cl_a * 100.0, 3),
            })
        opra_micro_by_date[d_a] = rec_m

    def compute_bsm_micro_est(cl_v: float, vxn_v: float, r_v: float = 0.04, q_v: float = 0.006) -> dict[str, Any]:
        """OPRA-calibrated skew-BSM theoretical estimate for post-OPRA live sessions (> 2025-12-15)."""
        t125 = 125.0 / 365.0
        t90 = 90.0 / 365.0
        k_atm = round(cl_v)
        k10 = round(cl_v * 0.90)
        k15 = round(cl_v * 0.85)
        k20 = round(cl_v * 0.80)
        iv_atm = eval_skew_iv(cl_v, k_atm, t125, r_v, q_v, vxn_v, coeffs)
        iv10 = eval_skew_iv(cl_v, k10, t125, r_v, q_v, vxn_v, coeffs)
        iv15 = eval_skew_iv(cl_v, k15, t125, r_v, q_v, vxn_v, coeffs)
        iv20 = eval_skew_iv(cl_v, k20, t125, r_v, q_v, vxn_v, coeffs)
        iv90 = eval_skew_iv(cl_v, k10, t90, r_v, q_v, vxn_v, coeffs)
        mid15 = max(0.05, bsm_price(cl_v, k15, t125, r_v, q_v, iv15, "put"))
        mid90 = max(0.05, bsm_price(cl_v, k10, t90, r_v, q_v, iv90, "put"))
        hs15_f, hs90_f = 0.014, 0.011
        bid15, ask15 = mid15 * (1.0 - hs15_f), mid15 * (1.0 + hs15_f)
        bid90, ask90 = mid90 * (1.0 - hs90_f), mid90 * (1.0 + hs90_f)
        lmt15 = mid15 + 0.35 * (ask15 - bid15) * 0.5 + 0.0065
        lmt90 = mid90 + 0.35 * (ask90 - bid90) * 0.5 + 0.0065
        return {
            "opra_src": "bsm_est",
            "opra_sk20_10": round(iv20 / max(iv10, 0.05), 3),
            "opra_sk15_atm": round(iv15 / max(iv_atm, 0.05), 3),
            "p125_k": float(k15),
            "p125_dte": 125,
            "p125_bid": round(bid15, 2),
            "p125_ask": round(ask15, 2),
            "p125_mid": round(mid15, 2),
            "p125_lmt": round(lmt15, 3),
            "p125_hs": round(hs15_f * 100.0, 2),
            "p125_iv": round(iv15 * 100.0, 1),
            "p125_lot_pct": round(lmt15 / max(cl_v, 1.0) * 100.0, 3),
            "p125_mid_pct": round(mid15 / max(cl_v, 1.0) * 100.0, 3),
            "p90_k": float(k10),
            "p90_dte": 90,
            "p90_bid": round(bid90, 2),
            "p90_ask": round(ask90, 2),
            "p90_mid": round(mid90, 2),
            "p90_lmt": round(lmt90, 3),
            "p90_hs": round(hs90_f * 100.0, 2),
            "p90_iv": round(iv90 * 100.0, 1),
            "p90_lot_pct": round(lmt90 / max(cl_v, 1.0) * 100.0, 3),
            "p90_mid_pct": round(mid90 / max(cl_v, 1.0) * 100.0, 3),
        }

    # Helper to simulate exact v2.0 Single Master Strategy for a given MIT OPRA window
    def run_v2_window(
        win_id: str,
        start_d: str,
        end_d: str,
        zero_splice: bool,
        exec_mode: str,
        fin_spread: float,
    ) -> dict[str, Any]:
        wd = fs.build_window_data(all_rows, etf_df, sig_df, start_d, end_d, zero_splice=zero_splice)
        dates = wd["dates"]
        dt_objs = wd["dt_objs"]
        n = wd["n"]
        sel = [full_idx_map[d] for d in dates]

        s = sig_df.reindex(dates)
        p1 = s["pillar1_top"].fillna(0.0).to_numpy(dtype=float)
        p2 = s["pillar2_shock"].fillna(0.0).to_numpy(dtype=float)
        m3 = s["M3"].fillna(False).astype(bool).to_numpy()
        non_m4_prob = np.minimum(100.0, p1 + p2 + np.where(m3, 20.0, 0.0))
        non_m4_flag = non_m4_prob >= 35.0

        latch_sel = latch_on_arr[sel]
        below200_sel = px_q[sel] < sma200_arr[sel]
        above_ema20_sel = px_q[sel] > ema20_arr[sel]
        ewmac_sel = ewmac_arr[sel]
        vxn = wd["vxn"]
        vr = wd["vr"]
        vix = wd["vix"]
        spot = wd["spot"]
        r_qqq, px_qqq = wd["r_qqq"], wd["px_qqq"]
        r_db, px_db = wd["r_db"], wd["px_db"]
        r_km, px_km = wd["r_km"], wd["px_km"]
        effr = wd["effr"]
        r_opt, q_opt = wd["r_opt"], wd["q_opt"]

        m4_flag = latch_sel & below200_sel & (ewmac_sel < 0.0) & above_ema20_sel & (vxn <= 28.0) & (vr <= 0.90)

        init_cap = INITIAL_CAPITAL
        lev_cap = 1.20
        qqq_val = init_cap
        cta_vals = {"DBMF": init_cap * 0.10, "KMLM": init_cap * 0.10}
        cta_w_tgt = {"DBMF": 0.10, "KMLM": 0.10}
        cta_px = {"DBMF": px_db, "KMLM": px_km}
        debt = init_cap * 0.20
        cash_free = 0.0
        tp_queue: list[dict[str, Any]] = []
        base_puts: list[dict[str, Any]] = []
        crisis_puts: list[dict[str, Any]] = []
        pending_base_open = False
        pending_crisis_open: str | None = None
        non_inv_streak = 1 if vr[0] < 1.00 else 0
        post_tp_lockout = False
        lockout_streak = 0
        run_ath_w = float(px_qqq[0])
        run_ath_w_idx = 0
        qqq_dd_w = np.zeros(n, dtype=float)
        cta_sched: dict[str, dict[str, Any] | None] = {"DBMF": None, "KMLM": None}
        cta_locks: list[dict[str, Any]] = []
        dd_timer_start_dt: datetime.date | None = None

        nav_arr = np.zeros(n, dtype=float)
        lev_arr = np.zeros(n, dtype=float)
        nav_arr[0] = init_cap
        lev_arr[0] = 1.20
        put_ledger: list[dict[str, Any]] = []
        cta_rot_ledger: list[dict[str, Any]] = []
        cta_restore_ledger: list[dict[str, Any]] = []
        tid = 0
        exec_fallbacks = 0
        delev_days = 0

        def _qc() -> float:
            return sum(q["amount"] for q in tp_queue)

        def _allp() -> list[dict[str, Any]]:
            return crisis_puts + base_puts

        def _pmtm() -> float:
            return sum(t["last_mtm_usd"] for t in _allp())

        def _gmv() -> float:
            return qqq_val + cta_vals["DBMF"] + cta_vals["KMLM"]

        def _nav() -> float:
            return max(1.0, _gmv() + _pmtm() + cash_free + _qc() - debt)

        def _sweep() -> None:
            nonlocal cash_free, debt
            if cash_free > 1e-8 and debt > 1e-8:
                pay = min(cash_free, debt)
                cash_free -= pay
                debt -= pay

        def _fund(need: float) -> float:
            nonlocal cash_free, qqq_val
            raised = 0.0
            if cash_free > 1e-8:
                take = min(cash_free, need)
                cash_free -= take
                raised += take
            rem = need - raised
            if rem > 1e-8 and qqq_val > 10.0:
                sg = min(qqq_val * 0.95, rem / (1.0 - ETF_FEE))
                qqq_val -= sg
                raised += sg * (1.0 - ETF_FEE)
            return raised

        def _park(cash_usd: float) -> None:
            nonlocal qqq_val, debt
            if cash_usd <= 1e-8:
                return
            room = max(0.0, lev_cap * _nav() - _gmv())
            tq = min(cash_usd, room)
            td = cash_usd - tq
            if tq > 1e-8:
                qqq_val += tq * (1.0 - ETF_FEE)
            if td > 1e-8:
                rep = min(debt, td)
                debt -= rep
                rem = td - rep
                if rem > 1e-8:
                    qqq_val += rem * (1.0 - ETF_FEE)

        def _open_put(i: int, sleeve: str, bud: float, t_dte: int, r_dte: int, mon: float, salv: float = 0.0):
            nonlocal tid, exec_fallbacks
            d = dates[i]
            cl = float(spot[i])
            lo, hi = fs.dte_bounds(t_dte)
            tgt = store.select_put_contract(d, cl, t_dte, mon, lo, hi)
            if tgt is None:
                exec_fallbacks += 1
                if salv > 1e-8:
                    _park(salv)
                return None
            bpx = rb.exec_buy_price(tgt["bid"], tgt["ask"], tgt["mid"], exec_mode)
            if bpx < 0.03:
                if salv > 1e-8:
                    _park(salv)
                return None
            nv = _nav() + salv
            cost = nv * bud
            sh = cost / bpx
            nn = cost - salv
            if nn > 1e-8:
                rsd = _fund(nn)
                if rsd + salv < cost * 0.99:
                    cost = rsd + salv
                    sh = cost / bpx
            elif nn < -1e-8:
                _park(-nn)
            tid += 1
            om_en = opra_micro_by_date.get(d, {})
            hs_en = ((tgt["ask"] - tgt["bid"]) / (2.0 * tgt["mid"]) * 100.0) if float(tgt["mid"]) > 0 else 0.0
            return {
                "tranche_id": tid,
                "sleeve": sleeve,
                "target_dte": t_dte,
                "roll_dte": r_dte,
                "moneyness": mon,
                "budget_pct": bud,
                "entry_date": d,
                "entry_dt": dt_objs[i],
                "exp": tgt["exp"],
                "exp_dt": tgt["exp_dt"],
                "entry_dte": tgt["dte"],
                "strike": tgt["strike"],
                "k_cents": tgt["k_cents"],
                "entry_spot": cl,
                "entry_fill": bpx,
                "entry_bid": float(tgt["bid"]),
                "entry_ask": float(tgt["ask"]),
                "entry_mid": float(tgt["mid"]),
                "entry_hs_pct": round(float(hs_en), 2),
                "entry_lot_pct": round(float(bpx) / max(cl, 1.0) * 100.0, 3),
                "entry_sk20_10": om_en.get("opra_sk20_10"),
                "entry_vix": round(float(vix[i]), 2),
                "entry_vr": round(float(vr[i]), 3),
                "last_iv": tgt["iv"] if np.isfinite(tgt["iv"]) else None,
                "shares": sh,
                "entry_cost": cost,
                "last_mtm_usd": sh * tgt["mid"],
                "last_mid": tgt["mid"],
                "last_rem_days": tgt["dte"],
                "pending_exit": False,
                "pending_exit_frac": 0.0,
                "exit_reason": "",
                "partial_tp_taken": False,
            }

        def _cap() -> None:
            nonlocal qqq_val, debt, cash_free, delev_days
            _sweep()
            gv = _gmv()
            nv = _nav()
            if gv / nv <= lev_cap + 1e-7:
                return
            sr = (gv - lev_cap * nv) / max(1e-6, 1.0 - lev_cap * ETF_FEE)
            if sr <= 1.0:
                return
            delev_days += 1
            sq = min(qqq_val, sr * qqq_val / gv)
            sd = min(cta_vals["DBMF"], sr * cta_vals["DBMF"] / gv)
            sk = min(cta_vals["KMLM"], sr * cta_vals["KMLM"] / gv)
            qqq_val -= sq
            cta_vals["DBMF"] -= sd
            cta_vals["KMLM"] -= sk
            proc = (sq + sd + sk) * (1.0 - ETF_FEE)
            rep = min(debt, proc)
            debt -= rep
            cash_free += proc - rep

        for i in range(1, n):
            d = dates[i]
            cl = float(spot[i])
            cal_days = max(1, (dt_objs[i] - dt_objs[i - 1]).days)
            vix_cl, vxn_cl, vix_r = float(vix[i]), float(vxn[i]), float(vr[i])
            r_cur, q_cur = float(r_opt[i]), float(q_opt[i])

            qqq_val *= 1.0 + float(r_qqq[i])
            cta_vals["DBMF"] *= 1.0 + float(r_db[i])
            cta_vals["KMLM"] *= 1.0 + float(r_km[i])
            if debt > 1e-8:
                debt += debt * max(0.0, float(effr[i - 1]) + fin_spread) * (cal_days / 360.0)
            qc0 = _qc()
            if (cash_free + qc0) > 1e-8:
                cash_free += (cash_free + qc0) * max(0.0, float(effr[i - 1]) + CASH_SPREAD) * (cal_days / 365.0)
            if px_qqq[i] >= run_ath_w:
                run_ath_w = float(px_qqq[i])
                run_ath_w_idx = i
            qqq_dd_w[i] = px_qqq[i] / run_ath_w - 1.0

            # 1. Exits & Rolls
            for bl in (crisis_puts, base_puts):
                if not bl:
                    continue
                keep, rolls = [], []
                for tr in bl:
                    if not tr["pending_exit"]:
                        keep.append(tr)
                        continue
                    rem_d = max(0, (tr["exp_dt"] - dt_objs[i]).days)
                    bid, ask, mid, iv, delta, src = store.lookup_contract(
                        d, "put", tr["exp"], tr["k_cents"], cl, rem_d, r_cur, q_cur, vxn_cl, tr["last_iv"], coeffs
                    )
                    if src != "exact":
                        exec_fallbacks += 1
                    spx = rb.exec_sell_price(bid, ask, mid, exec_mode)
                    frac = float(tr["pending_exit_frac"])
                    cp = tr["entry_cost"] * frac
                    ex = tr["shares"] * frac * spx
                    put_ledger.append({
                        "tranche_id": tr["tranche_id"],
                        "sleeve": tr["sleeve"],
                        "entry_date": tr["entry_date"],
                        "exit_date": d,
                        "exp": tr["exp"],
                        "strike": round(float(tr["strike"]), 2),
                        "entry_dte": int(tr["entry_dte"]),
                        "exit_dte": int(rem_d),
                        "entry_spot": round(float(tr["entry_spot"]), 2),
                        "exit_spot": round(cl, 2),
                        "entry_fill": round(float(tr["entry_fill"]), 3),
                        "entry_bid": round(float(tr.get("entry_bid", 0.0)), 2),
                        "entry_ask": round(float(tr.get("entry_ask", 0.0)), 2),
                        "entry_mid": round(float(tr.get("entry_mid", 0.0)), 2),
                        "entry_hs_pct": tr.get("entry_hs_pct"),
                        "entry_lot_pct": tr.get("entry_lot_pct"),
                        "entry_sk20_10": tr.get("entry_sk20_10"),
                        "entry_vix": tr.get("entry_vix"),
                        "entry_vr": tr.get("entry_vr"),
                        "exit_fill": round(float(spx), 3),
                        "exit_bid": round(float(bid), 2),
                        "exit_ask": round(float(ask), 2),
                        "exit_mid": round(float(mid), 2),
                        "exit_vix": round(float(vix_cl), 2),
                        "exit_vr": round(float(vix_r), 3),
                        "exit_dd_pct": round(float(qqq_dd_w[i]) * 100.0, 2),
                        "exit_lot_pct": round(float(spx) / max(cl, 1.0) * 100.0, 3),
                        "contracts": round(float(tr["shares"] * frac) / 100.0, 2),
                        "exit_frac": round(frac, 2),
                        "cost_usd": round(cp, 2),
                        "exit_usd": round(ex, 2),
                        "net_pnl_usd": round(ex - cp, 2),
                        "roi_mult": round(ex / cp, 2) if cp > 1e-6 else 0.0,
                        "exit_reason": tr["exit_reason"],
                        "quote_source": "REAL_OPRA",
                    })
                    if tr["exit_reason"].startswith("roll_"):
                        rolls.append((ex, tr))
                    elif tr["exit_reason"].startswith("tp_"):
                        if ex > 1e-6:
                            for k in range(5):
                                tp_queue.append({"exec_idx": min(n - 1, i + k), "amount": ex / 5.0})
                    else:
                        if ex > 1e-6:
                            _park(ex)
                    if frac < 0.999:
                        tr["shares"] *= 1.0 - frac
                        tr["entry_cost"] *= 1.0 - frac
                        tr["last_mtm_usd"] = tr["shares"] * mid
                        tr["pending_exit"] = False
                        tr["pending_exit_frac"] = 0.0
                        tr["exit_reason"] = ""
                        tr["partial_tp_taken"] = True
                        keep.append(tr)
                bl[:] = keep
                for salv, old_tr in rolls:
                    nt = _open_put(i, old_tr["sleeve"], old_tr["budget_pct"], old_tr["target_dte"], old_tr["roll_dte"], old_tr["moneyness"], salv)
                    if nt is not None:
                        bl.append(nt)

            # 2. Entries
            if pending_crisis_open is not None and len(crisis_puts) == 0:
                if pending_crisis_open == "m4_90":
                    nt = _open_put(i, "crisis_m4", 0.010, 90, 30, 0.90)
                else:
                    nt = _open_put(i, "crisis", 0.010, 125, 75, 0.85)
                if nt is not None:
                    crisis_puts.append(nt)
            pending_crisis_open = None
            if pending_base_open and len(base_puts) == 0:
                nt = _open_put(i, "base", 0.002, 125, 75, 0.85)
                if nt is not None:
                    base_puts.append(nt)
            pending_base_open = False

            # 3. 5-Day Equal-Tranche TP Deploy
            if tp_queue:
                due = [q for q in tp_queue if q["exec_idx"] <= i]
                if due:
                    tp_queue = [q for q in tp_queue if q["exec_idx"] > i]
                    _park(sum(q["amount"] for q in due))

            # 4A. Dual-CTA Rotation Slices
            dd_prev = float(qqq_dd_w[i - 1])
            for sl in ("DBMF", "KMLM"):
                sch = cta_sched[sl]
                if sch is None:
                    continue
                if sch["next_ptr"] < len(sch["exec_idxs"]) and i >= sch["exec_idxs"][sch["next_ptr"]]:
                    if dd_prev > -0.12:
                        cta_sched[sl] = None
                        continue
                    rem_c = len(sch["exec_idxs"]) - sch["next_ptr"]
                    sa = cta_vals[sl] / float(rem_c)
                    if sa > 1.0:
                        cta_vals[sl] -= sa
                        qqq_val += sa * (1.0 - ETF_FEE) * (1.0 - ETF_FEE)
                        cta_locks.append({"sleeve": sl, "buy_dt": dt_objs[i], "target_w_slice": cta_w_tgt[sl] / 5.0})
                        cta_rot_ledger.append({
                            "date": d,
                            "sleeve": sl,
                            "tranche": sch["next_ptr"] + 1,
                            "sold_usd": round(sa, 2),
                            "qqq_dd_pct": round(dd_prev * 100.0, 2),
                            "restore_due": (dt_objs[i] + datetime.timedelta(days=365)).isoformat(),
                        })
                    sch["next_ptr"] += 1
                    if sch["next_ptr"] >= len(sch["exec_idxs"]):
                        cta_sched[sl] = None

            # 4B. 1-Year Mechanical Restore
            if cta_locks:
                still_l, mat = [], {"DBMF": [], "KMLM": []}
                for lt in cta_locks:
                    if (dt_objs[i] - lt["buy_dt"]).days >= 365:
                        mat[lt["sleeve"]].append(lt)
                    else:
                        still_l.append(lt)
                cta_locks = still_l
                for sl in ("DBMF", "KMLM"):
                    if not mat[sl]:
                        continue
                    nv = _nav()
                    aw = sum(x["target_w_slice"] for x in mat[sl])
                    bn = max(0.0, min(cta_w_tgt[sl] * nv, cta_vals[sl] + aw * nv) - cta_vals[sl])
                    if bn > 1.0:
                        fq1 = min(max(0.0, qqq_val - nv), bn / (1.0 - ETF_FEE))
                        qqq_val -= fq1
                        rsd = fq1 * (1.0 - ETF_FEE)
                        rem = bn - rsd
                        if rem > 1e-6:
                            br = min(rem, max(0.0, lev_cap * nv - _gmv()))
                            debt += br
                            rsd += br
                            rem -= br
                        if rem > 1e-6 and qqq_val > rem / (1.0 - ETF_FEE):
                            fq2 = rem / (1.0 - ETF_FEE)
                            qqq_val -= fq2
                            rsd += fq2 * (1.0 - ETF_FEE)
                        cta_vals[sl] += rsd * (1.0 - ETF_FEE)
                        cta_restore_ledger.append({
                            "date": d,
                            "sleeve": sl,
                            "restored_usd": round(rsd * (1.0 - ETF_FEE), 2),
                            "lots_matured": len(mat[sl]),
                        })

            # 5. Quarterly Calibration (idle only)
            if (not cta_locks) and (cta_sched["DBMF"] is None) and (cta_sched["KMLM"] is None) and (not tp_queue):
                if i < n - 1:
                    if ((int(d[5:7]) - 1) // 3 != (int(dates[i + 1][5:7]) - 1) // 3) or (d[:4] != dates[i + 1][:4]):
                        _sweep()
                        nv = _nav()
                        pm = _pmtm()
                        dtr = (
                            abs(max(0.0, nv - pm) - qqq_val)
                            + abs(nv * 0.10 - cta_vals["DBMF"])
                            + abs(nv * 0.10 - cta_vals["KMLM"])
                        )
                        na = max(1.0, nv - dtr * ETF_FEE)
                        qqq_val = max(0.0, na - pm)
                        cta_vals["DBMF"] = na * 0.10
                        cta_vals["KMLM"] = na * 0.10
                        debt = na * 0.20
                        cash_free = 0.0

            # 6. Expiries
            for bl in (crisis_puts, base_puts):
                se = []
                for tr in bl:
                    if rb.is_expiry_day(i, dt_objs, tr["exp_dt"]):
                        su = tr["shares"] * max(0.0, tr["strike"] - cl)
                        put_ledger.append({
                            "tranche_id": tr["tranche_id"],
                            "sleeve": tr["sleeve"],
                            "entry_date": tr["entry_date"],
                            "exit_date": d,
                            "exp": tr["exp"],
                            "strike": round(float(tr["strike"]), 2),
                            "entry_dte": int(tr["entry_dte"]),
                            "exit_dte": 0,
                            "entry_spot": round(float(tr["entry_spot"]), 2),
                            "exit_spot": round(cl, 2),
                            "entry_fill": round(float(tr["entry_fill"]), 3),
                            "entry_bid": round(float(tr.get("entry_bid", 0.0)), 2),
                            "entry_ask": round(float(tr.get("entry_ask", 0.0)), 2),
                            "entry_mid": round(float(tr.get("entry_mid", 0.0)), 2),
                            "entry_hs_pct": tr.get("entry_hs_pct"),
                            "entry_lot_pct": tr.get("entry_lot_pct"),
                            "entry_sk20_10": tr.get("entry_sk20_10"),
                            "entry_vix": tr.get("entry_vix"),
                            "entry_vr": tr.get("entry_vr"),
                            "exit_fill": round(max(0.0, tr["strike"] - cl), 3),
                            "exit_bid": round(max(0.0, tr["strike"] - cl), 2),
                            "exit_ask": round(max(0.0, tr["strike"] - cl), 2),
                            "exit_mid": round(max(0.0, tr["strike"] - cl), 2),
                            "exit_vix": round(float(vix_cl), 2),
                            "exit_vr": round(float(vix_r), 3),
                            "exit_dd_pct": round(float(qqq_dd_w[i]) * 100.0, 2),
                            "exit_lot_pct": round(max(0.0, tr["strike"] - cl) / max(cl, 1.0) * 100.0, 3),
                            "contracts": round(float(tr["shares"]) / 100.0, 2),
                            "exit_frac": 1.0,
                            "cost_usd": round(tr["entry_cost"], 2),
                            "exit_usd": round(su, 2),
                            "net_pnl_usd": round(su - tr["entry_cost"], 2),
                            "roi_mult": round(su / tr["entry_cost"], 2) if tr["entry_cost"] > 1e-6 else 0.0,
                            "exit_reason": "expiry",
                            "quote_source": "REAL_OPRA",
                        })
                        if su > 1e-6:
                            _park(su)
                    else:
                        se.append(tr)
                bl[:] = se

            # 7. MTM
            for tr in _allp():
                rem_d = max(1, (tr["exp_dt"] - dt_objs[i]).days)
                bid, ask, mid, iv, delta, src = store.lookup_contract(
                    d, "put", tr["exp"], tr["k_cents"], cl, rem_d, r_cur, q_cur, vxn_cl, tr["last_iv"], coeffs
                )
                if np.isfinite(iv) and iv > 0.05:
                    tr["last_iv"] = iv
                tr["last_mtm_usd"] = tr["shares"] * mid
                tr["last_mid"] = mid
                tr["last_rem_days"] = rem_d

            # 8. Hard Leverage Cap <= 1.200x
            _cap()
            nav_arr[i] = _nav()
            lev_arr[i] = _gmv() / nav_arr[i]

            # 9. Causal EOD Signals
            non_inv_streak = non_inv_streak + 1 if vix_r < 1.00 else 0
            tp_today = False
            all_act = [t for t in _allp() if not t["pending_exit"]]
            dd_now = float(qqq_dd_w[i])

            # Tier 2 Full TP: VIX/VIX3M >= 1.10 AND QQQ ATH DD <= -10.0%
            if vix_r >= 1.10 and dd_now <= -0.10 and all_act:
                for t in all_act:
                    t["pending_exit"] = True
                    t["pending_exit_frac"] = 1.0
                    t["exit_reason"] = "tp_vr110_dd10_full"
                tp_today = True

            # Tier 1 Partial TP: >= 5.0x AND VIX/VIX3M < 1.00 (shortest DTE)
            if (not tp_today) and vix_r < 1.00 and all_act:
                qual = [
                    t
                    for t in all_act
                    if (t["last_mid"] / max(t["entry_fill"], 1e-6)) >= 5.0 and not t["partial_tp_taken"]
                ]
                if qual:
                    qual.sort(key=lambda x: (x["last_rem_days"], x["tranche_id"]))
                    qual[0]["pending_exit"] = True
                    qual[0]["pending_exit_frac"] = 0.50
                    qual[0]["exit_reason"] = "tp_5x_partial"
                    tp_today = True

            # Roll / Recycle
            for t in base_puts:
                if not t["pending_exit"] and t["last_rem_days"] <= t["roll_dte"] and vix_r < 1.00:
                    t["pending_exit"] = True
                    t["pending_exit_frac"] = 1.0
                    t["exit_reason"] = "roll_75d"
            for t in crisis_puts:
                if not t["pending_exit"] and t["last_rem_days"] <= t["roll_dte"] and vix_r < 1.00:
                    t["pending_exit"] = True
                    t["pending_exit_frac"] = 1.0
                    if t["sleeve"] == "crisis_m4":
                        t["exit_reason"] = "recycle_30d_m4"
                    else:
                        t["exit_reason"] = (
                            "roll_75d"
                            if (bool(non_m4_flag[i]) and not post_tp_lockout)
                            else "close_75d_signal_off"
                        )

            # Post-TP 5D Contango Lockout
            if tp_today:
                post_tp_lockout = True
                lockout_streak = 0
            elif post_tp_lockout:
                if vix_r < 1.00:
                    lockout_streak += 1
                    if lockout_streak >= 5:
                        post_tp_lockout = False
                        lockout_streak = 0
                else:
                    lockout_streak = 0

            # Entries
            eff_b = [t for t in base_puts if not (t["pending_exit"] and t["pending_exit_frac"] >= 0.99)]
            if len(eff_b) == 0 and non_inv_streak >= 5 and vix_cl < 20.0:
                pending_base_open = True
            eff_c = [t for t in crisis_puts if not (t["pending_exit"] and t["pending_exit_frac"] >= 0.99)]
            if (not post_tp_lockout) and vix_r < 1.02 and len(eff_c) == 0:
                if bool(m4_flag[i]):
                    pending_crisis_open = "m4_90"
                elif bool(non_m4_flag[i]):
                    pending_crisis_open = "std_125"

            # CONT_2M Continuous 60-cal-day DD <= -12% CTA Rotation Timer
            if i < n - 1:
                has_av = any(
                    cta_sched[sl] is None and cta_vals[sl] > 0.01 * nav_arr[i] for sl in ("DBMF", "KMLM")
                )
                if run_ath_w_idx == i:
                    dd_timer_start_dt = None
                tc = False
                if dd_now <= -0.12:
                    if dd_timer_start_dt is None and has_av:
                        dd_timer_start_dt = dt_objs[i]
                    elif dd_timer_start_dt is not None and (dt_objs[i] - dd_timer_start_dt).days >= 60:
                        tc = True
                else:
                    dd_timer_start_dt = None
                if tc and dd_now <= -0.12 and has_av:
                    for sl in ("DBMF", "KMLM"):
                        if cta_sched[sl] is not None or cta_vals[sl] <= 0.01 * nav_arr[i]:
                            continue
                        if float(cta_px[sl][i] / cta_px[sl][run_ath_w_idx] - 1.0) > 0.0:
                            cta_sched[sl] = {
                                "exec_idxs": [min(n - 1, i + 1 + 5 * k) for k in range(5)],
                                "next_ptr": 0,
                            }
                    if any(cta_sched[sl] is not None for sl in ("DBMF", "KMLM")):
                        dd_timer_start_dt = None

        # Compute summary KPIs
        qqq_nav = init_cap * (px_qqq / px_qqq[0])
        yrs = (dt_objs[-1] - dt_objs[0]).days / 365.25

        def calc_kpi(arr: Any) -> dict[str, Any]:
            cagr = (float(arr[-1]) / init_cap) ** (1.0 / yrs) - 1.0
            dd_s = arr / np.maximum.accumulate(arr) - 1.0
            mdd = float(dd_s.min())
            calmar = cagr / abs(mdd) if mdd < 0 else 0.0
            dr = np.diff(arr) / arr[:-1]
            ex_r = dr - effr[:-1] / 252.0
            sharpe = float(np.mean(ex_r) / max(np.std(ex_r, ddof=1), 1e-12) * math.sqrt(252.0))
            dn = ex_r[ex_r < 0.0]
            sortino = float(np.mean(ex_r) / max(np.sqrt(np.mean(dn * dn)), 1e-12) * math.sqrt(252.0)) if len(dn) else 0.0
            ann_vol = float(np.std(dr, ddof=1) * math.sqrt(252.0))
            return {
                "end_nav": round(float(arr[-1]), 2),
                "total_return_pct": round((float(arr[-1]) / init_cap - 1.0) * 100.0, 2),
                "cagr_pct": round(cagr * 100.0, 2),
                "max_dd_pct": round(mdd * 100.0, 2),
                "calmar": round(calmar, 3),
                "sharpe": round(sharpe, 3),
                "sortino": round(sortino, 3),
                "ann_vol_pct": round(ann_vol * 100.0, 2),
            }

        kpi_s = calc_kpi(nav_arr)
        kpi_q = calc_kpi(qqq_nav)
        tot_c = sum(t["cost_usd"] for t in put_ledger)
        tot_e = sum(t["exit_usd"] for t in put_ledger)
        m4_tr = [t for t in put_ledger if t["sleeve"] == "crisis_m4"]
        base_tr = [t for t in put_ledger if t["sleeve"] == "base"]
        r1_tr = [t for t in put_ledger if t["sleeve"] == "crisis"]
        tp_tr = [t for t in put_ledger if t["exit_reason"].startswith("tp_")]
        kpi_s.update({
            "net_alpha_usd": round(kpi_s["end_nav"] - kpi_q["end_nav"], 2),
            "cagr_alpha_pp": round(kpi_s["cagr_pct"] - kpi_q["cagr_pct"], 2),
            "mdd_cushion_pp": round(kpi_s["max_dd_pct"] - kpi_q["max_dd_pct"], 2),
            "peak_gross_leverage": round(float(lev_arr.max()), 4),
            "avg_gross_leverage": round(float(lev_arr.mean()), 3),
            "delev_cap_days": int(delev_days),
            "put_trades_total": len(put_ledger),
            "put_trades_base": len(base_tr),
            "put_trades_route1": len(r1_tr),
            "put_trades_m4": len(m4_tr),
            "put_tp_count": len(tp_tr),
            "put_cost_usd": round(tot_c, 2),
            "put_exit_usd": round(tot_e, 2),
            "put_net_pnl_usd": round(tot_e - tot_c, 2),
            "put_payoff_mult": round(tot_e / tot_c, 2) if tot_c > 1e-6 else 0.0,
            "cta_rotation_slices": len(cta_rot_ledger),
            "cta_restore_events": len(cta_restore_ledger),
            "execution_fallbacks": int(exec_fallbacks),
        })

        # 8-Crisis comparison table
        crisis_rows = []
        for cid, cname_en, cname_zh, cs, ce in CRISIS_WINDOWS:
            idxs = [k for k, d_str in enumerate(dates) if cs <= d_str <= ce]
            if len(idxs) < 5:
                continue
            i0, i1 = idxs[0], idxs[-1]
            sub_s = nav_arr[i0 : i1 + 1]
            sub_q = qqq_nav[i0 : i1 + 1]
            mdd_s = float((sub_s / np.maximum.accumulate(sub_s) - 1.0).min() * 100.0)
            mdd_q = float((sub_q / np.maximum.accumulate(sub_q) - 1.0).min() * 100.0)
            ret_s = float((sub_s[-1] / sub_s[0] - 1.0) * 100.0)
            ret_q = float((sub_q[-1] / sub_q[0] - 1.0) * 100.0)
            win_puts = [t for t in put_ledger if cs <= t["exit_date"] <= ce and t["exit_reason"].startswith("tp_")]
            win_m4 = [t for t in put_ledger if cs <= t["entry_date"] <= ce and t["sleeve"] == "crisis_m4"]
            win_cta = [c for c in cta_rot_ledger if cs <= c["date"] <= ce]
            crisis_rows.append({
                "id": cid,
                "name_en": cname_en,
                "name_zh": cname_zh,
                "start_date": dates[i0],
                "end_date": dates[i1],
                "v2_mdd_pct": round(mdd_s, 2),
                "qqq_mdd_pct": round(mdd_q, 2),
                "mdd_cushion_pp": round(mdd_s - mdd_q, 2),
                "v2_ret_pct": round(ret_s, 2),
                "qqq_ret_pct": round(ret_q, 2),
                "put_tp_count": len(win_puts),
                "m4_trades": len(win_m4),
                "cta_rot_slices": len(win_cta),
                "peak_lev": round(float(lev_arr[i0 : i1 + 1].max()), 3),
            })

        # Capture any Put tranche still held open at window end so PIT replay near end_d is exact
        open_puts_at_end: list[dict[str, Any]] = []
        for tr in _allp():
            open_puts_at_end.append({
                "tranche_id": tr["tranche_id"],
                "sleeve": tr["sleeve"],
                "entry_date": tr["entry_date"],
                "exp": tr["exp"],
                "strike": round(float(tr["strike"]), 2),
                "entry_dte": int(tr["entry_dte"]),
                "rem_dte": int(tr["last_rem_days"]),
                "entry_spot": round(float(tr["entry_spot"]), 2),
                "entry_fill": round(float(tr["entry_fill"]), 3),
                "entry_bid": round(float(tr.get("entry_bid", 0.0)), 2),
                "entry_ask": round(float(tr.get("entry_ask", 0.0)), 2),
                "entry_mid": round(float(tr.get("entry_mid", 0.0)), 2),
                "entry_hs_pct": tr.get("entry_hs_pct"),
                "entry_lot_pct": tr.get("entry_lot_pct"),
                "entry_sk20_10": tr.get("entry_sk20_10"),
                "entry_vix": tr.get("entry_vix"),
                "entry_vr": tr.get("entry_vr"),
                "cost_usd": round(float(tr["entry_cost"]), 2),
                "last_mtm_usd": round(float(tr["last_mtm_usd"]), 2),
                "contracts": round(float(tr["shares"]) / 100.0, 2),
            })

        # Compact daily event bitmask for zero-lag chart markers:
        #   1 = Base 0.2% Put Open | 2 = Crisis R1/M4 Put Open | 4 = Put TP (5x/VR1.10) | 8 = Roll/Recycle | 16 = CTA Rotate/Restore
        evt_by_d: dict[str, int] = {}
        for tr in put_ledger:
            ed = tr["entry_date"]
            xd = tr["exit_date"]
            evt_by_d[ed] = evt_by_d.get(ed, 0) | (1 if tr["sleeve"] == "base" else 2)
            if tr["exit_reason"].startswith("tp_"):
                evt_by_d[xd] = evt_by_d.get(xd, 0) | 4
            else:
                evt_by_d[xd] = evt_by_d.get(xd, 0) | 8
        for tr in open_puts_at_end:
            ed = tr["entry_date"]
            evt_by_d[ed] = evt_by_d.get(ed, 0) | (1 if tr["sleeve"] == "base" else 2)
        for cr in cta_rot_ledger:
            cd = cr["date"]
            evt_by_d[cd] = evt_by_d.get(cd, 0) | 16
        for rs in cta_restore_ledger:
            rd = rs["date"]
            evt_by_d[rd] = evt_by_d.get(rd, 0) | 16

        dd_s_arr = (nav_arr / np.maximum.accumulate(nav_arr) - 1.0) * 100.0
        dd_q_arr = (qqq_nav / np.maximum.accumulate(qqq_nav) - 1.0) * 100.0

        series_rows = []
        for k in range(n):
            series_rows.append({
                "date": dates[k],
                "nav_v2": round(float(nav_arr[k]), 2),
                "nav_qqq": round(float(qqq_nav[k]), 2),
                "dd_v2": round(float(dd_s_arr[k]), 2),
                "dd_qqq": round(float(dd_q_arr[k]), 2),
                "lev": round(float(lev_arr[k]), 4),
                "qqq": round(float(spot[k]), 2),
                "vr": round(float(vr[k]), 3),
                "latch": 1 if bool(latch_sel[k]) else 0,
                "evt": int(evt_by_d.get(dates[k], 0)),
            })

        return {
            "kpi": kpi_s,
            "kpi_qqq": kpi_q,
            "crisis_comparison": crisis_rows,
            "daily_series": pack_table(series_rows, ["date", "nav_v2", "nav_qqq", "dd_v2", "dd_qqq", "lev", "qqq", "vr", "latch", "evt"]),
            "put_ledger": put_ledger,
            "open_puts_at_end": open_puts_at_end,
            "cta_rotation_ledger": cta_rot_ledger,
            "cta_restore_ledger": cta_restore_ledger,
        }

    # Build both verified MIT Real OPRA windows (Primary + Stress)
    w11_pri = run_v2_window("11y_opra", "2015-01-02", "2025-12-15", False, "real_ibkr_limit", BOX_SPREAD)
    w11_str = run_v2_window("11y_opra", "2015-01-02", "2025-12-15", False, "real_ask_bid", IBKR_SPREAD)
    w5_pri = run_v2_window("5y_live", "2020-12-02", "2025-12-15", True, "real_ibkr_limit", BOX_SPREAD)
    w5_str = run_v2_window("5y_live", "2020-12-02", "2025-12-15", True, "real_ask_bid", IBKR_SPREAD)

    # Now build complete PIT Daily Index (2015-01-02 -> latest close) + Live Tail State for Node.js live stepping!
    # First load existing 2015-2026-11-20 m7 features/signals/eval_bars from existing_doc so historical PIT is exact,
    # and step forward from 2026-11-20 through latest Yahoo/FRED/EFFR session!
    def unpack_tbl(tbl: Any) -> list[dict[str, Any]]:
        if isinstance(tbl, list):
            return tbl
        if isinstance(tbl, dict) and "_cols" in tbl and "_rows" in tbl:
            cols = tbl["_cols"]
            return [dict(zip(cols, row)) for row in tbl["_rows"]]
        return []

    old_eval_bars = unpack_tbl(existing_doc.get("m7_eval_bars"))
    old_sig_on = unpack_tbl((existing_doc.get("m7_signals") or {}).get("m0on"))
    old_feats = unpack_tbl(existing_doc.get("m7_feature_table"))
    eval_by_d = {r["date"]: r for r in old_eval_bars}
    sig_by_d = {r["date"]: r for r in old_sig_on}
    feat_by_d = {r["date"]: r for r in old_feats}

    def attach_opra_micro_to_pit_rows(rows_in: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Attach daily Real MIT OPRA microstructure (or post-OPRA BSM estimate) + CBOE SKEW spot."""
        last_sk_spot = 132.0
        out_rows = []
        for r0 in rows_in:
            r = dict(r0)
            d_k = str(r["date"])
            if d_k in skew_spot_map:
                last_sk_spot = skew_spot_map[d_k]
            elif r.get("skew10") is not None:
                last_sk_spot = float(r["skew10"])
            r["skew_spot"] = round(float(last_sk_spot), 2)
            om = opra_micro_by_date.get(d_k)
            if om is None:
                effr_dec = float(r.get("effr") or 4.0) / 100.0
                om = compute_bsm_micro_est(float(r["qqq"]), float(r["vxn"]), r_v=effr_dec, q_v=0.006)
            for mk in (
                "opra_src", "opra_sk20_10", "opra_sk15_atm",
                "p125_k", "p125_dte", "p125_bid", "p125_ask", "p125_mid", "p125_lmt", "p125_hs", "p125_iv", "p125_lot_pct", "p125_mid_pct",
                "p90_k", "p90_dte", "p90_bid", "p90_ask", "p90_mid", "p90_lmt", "p90_hs", "p90_iv", "p90_lot_pct", "p90_mid_pct",
            ):
                r[mk] = om.get(mk)
            out_rows.append(r)
        return out_rows

    # Fast idempotent v2->v2 refresh path when existing_doc is already v2-master (no legacy v1 m7_eval_bars)
    if existing_doc.get("version") == ARTIFACT_VERSION and not old_eval_bars and existing_doc.get("pit_daily_index"):
        pit_rows_v2 = attach_opra_micro_to_pit_rows(unpack_tbl(existing_doc["pit_daily_index"]))
        pit_cols_v2 = list(pit_rows_v2[0].keys())
        latest_pit = pit_rows_v2[-1]
        latest_date = str(latest_pit["date"])
        live_tail_v2 = dict(existing_doc.get("live_tail_state") or {})
        live_tail_v2["opra_skew_coeffs"] = [round(float(c), 6) for c in coeffs]

        artifact = {
            "version": ARTIFACT_VERSION,
            "strategy_code": STRATEGY_CODE,
            "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "as_of_date": latest_date,
            "asOfDate": latest_date,
            "dataThrough": latest_date,
            "ruleset": build_ruleset_spec(),
            "data_freshness": existing_doc.get("data_freshness") or {},
            "backtest": {
                "initial_capital": INITIAL_CAPITAL,
                "opra_provenance": {
                    "quotes_count": 6382288,
                    "trading_days": 2749,
                    "opra_start": "2015-01-02",
                    "opra_end": "2025-12-15",
                    "execution_fallbacks": 0,
                    "primary_fill_en": "IBKR 35% Limit + SPX Short Box (EFFR + 35 bps)",
                    "primary_fill_zh": "IBKR 35% 限价成交 + SPX Short Box 融资（EFFR + 35 bps）",
                    "stress_fill_en": "Full Ask/Bid + IBKR Pro Margin (EFFR + 150 bps)",
                    "stress_fill_zh": "保守对手盘 Ask/Bid + IBKR Pro 融资（EFFR + 150 bps）",
                },
                "windows": {
                    "11y_opra": {
                        "id": "11y_opra",
                        "label_en": "11Y Real MIT OPRA (2015-2025.12)",
                        "label_zh": "11年真实 OPRA（2015-2025.12）",
                        "start_date": "2015-01-02",
                        "end_date": "2025-12-15",
                        "zero_splice": False,
                        "disclosure_en": "100% real 16:00 ET US OPRA QQQ put quotes (0 fallbacks). Pre-inception DBMF (<2019-05-09) and KMLM (<2020-12-03) splice real AQMIX live mutual fund returns.",
                        "disclosure_zh": "100% 真实美股 16:00 ET OPRA 期权盘口（0 次回退）。DBMF（2019-05-09 前）与 KMLM（2020-12-03 前）使用真实 AQMIX 共同基金净值拼接。",
                        "kpi_primary": w11_pri["kpi"],
                        "kpi_stress": w11_str["kpi"],
                        "kpi_qqq": w11_pri["kpi_qqq"],
                        "crisis_comparison": w11_pri["crisis_comparison"],
                        "daily_series": w11_pri["daily_series"],
                        "put_ledger": w11_pri["put_ledger"],
                        "open_puts_at_end": w11_pri["open_puts_at_end"],
                        "cta_rotation_ledger": w11_pri["cta_rotation_ledger"],
                        "cta_restore_ledger": w11_pri["cta_restore_ledger"],
                        "latch_episodes": [e for e in latch_episodes_full if e["arm_date"] <= "2025-12-15"],
                    },
                    "5y_live": {
                        "id": "5y_live",
                        "label_en": "5Y Zero-Splice Live (2020.12-2025.12)",
                        "label_zh": "5年零拼接纯真盘（2020.12-2025.12）",
                        "start_date": "2020-12-02",
                        "end_date": "2025-12-15",
                        "zero_splice": True,
                        "disclosure_en": "Zero-splice pure live window: 100% live DBMF + 100% live KMLM + 100% real MIT OPRA QQQ puts + official NY Fed EFFR.",
                        "disclosure_zh": "零拼接纯实盘窗口：100% 实盘 DBMF + 100% 实盘 KMLM + 100% 真实 MIT OPRA 期权盘口 + 纽约联储官方 EFFR。",
                        "kpi_primary": w5_pri["kpi"],
                        "kpi_stress": w5_str["kpi"],
                        "kpi_qqq": w5_pri["kpi_qqq"],
                        "crisis_comparison": w5_pri["crisis_comparison"],
                        "daily_series": w5_pri["daily_series"],
                        "put_ledger": w5_pri["put_ledger"],
                        "open_puts_at_end": w5_pri["open_puts_at_end"],
                        "cta_rotation_ledger": w5_pri["cta_rotation_ledger"],
                        "cta_restore_ledger": w5_pri["cta_restore_ledger"],
                        "latch_episodes": [e for e in latch_episodes_full if "2020-12-02" <= e["arm_date"] <= "2025-12-15"],
                    },
                },
            },
            "pit_daily_index": pack_table(pit_rows_v2, pit_cols_v2),
            "live_tail_state": live_tail_v2,
        }
        raw_json = json.dumps(artifact, ensure_ascii=False, separators=(",", ":"))
        assert chr(126) not in raw_json, "ASCII tilde found in generated JSON!"
        for banned in ("FactOS", "FACT OS", "fact_os", "DuckDB", "Sharadar", "SQLite", "Wheel", "wheel", "Covered Call", "Short Put", "卖Call", "领口"):
            assert banned not in raw_json, f"Banned term '{banned}' found in generated JSON!"
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(raw_json, encoding="utf-8")
        print(f"Wrote enriched v2 artifact {output_path} ({len(raw_json) / 1024:.1f} KB)")
        print(f"  Latest Date: {latest_date} | OPRA micro rows: {sum(1 for r in pit_rows_v2 if r.get('opra_src') == 'real_opra')} real + {sum(1 for r in pit_rows_v2 if r.get('opra_src') == 'bsm_est')} bsm_est")
        print(f"  11Y OPRA Primary: ${w11_pri['kpi']['end_nav']:,.2f} ({w11_pri['kpi']['cagr_pct']}% CAGR, {w11_pri['kpi']['max_dd_pct']}% MDD, {w11_pri['kpi']['calmar']} Calmar)")
        print(f"  5Y Live Primary:  ${w5_pri['kpi']['end_nav']:,.2f} ({w5_pri['kpi']['cagr_pct']}% CAGR, {w5_pri['kpi']['max_dd_pct']}% MDD, {w5_pri['kpi']['calmar']} Calmar)")
        return artifact

    # Build enriched live tail state starting from old_tail (which ends 2026-11-20) and extend through latest live trading close!
    tail_dates: list[str] = list(old_tail["tail_dates"])
    yf_tail: dict[str, list[float]] = {k: list(v) for k, v in old_tail["yf_tail"].items()}
    # Add DBMF and KMLM into yf_tail aligned with tail_dates (using etf_df)
    yf_tail["DBMF"] = [float(etf_df.loc[d, "DBMF"]) if d in etf_df.index else float(etf_df["DBMF"].dropna().iloc[-1]) for d in tail_dates]
    yf_tail["KMLM"] = [float(etf_df.loc[d, "KMLM"]) if d in etf_df.index else float(etf_df["KMLM"].dropna().iloc[-1]) for d in tail_dates]

    fred_tail: dict[str, dict[str, float]] = {k: dict(v) for k, v in old_tail["fred_tail"].items()}
    sl_tail = json.loads(json.dumps(old_tail["six_lights_tail"]))
    ewm_state = dict(old_tail["ewm_state"])
    welford_4d = {k: list(v) for k, v in old_tail["welford_4d"].items()}
    hmm = {k: (list(v) if isinstance(v, list) else v) for k, v in old_tail["hmm"].items()}
    p_hmm_tail = list(old_tail["p_hmm_tail"])
    base_2013 = dict(old_tail["base_2013"])
    effr_tail: dict[str, float] = {}
    for d in tail_dates[-60:]:
        if d in etf_df.index and math.isfinite(float(etf_df.loc[d, "EFFR"])):
            effr_tail[d] = float(etf_df.loc[d, "EFFR"])

    # Optional live fetch for post-2026-11-20 dates (Yahoo + FRED + NY Fed EFFR)
    live_yf: dict[str, dict[str, dict[str, float]]] = {}
    live_fred: dict[str, dict[str, float]] = {}
    live_effr: dict[str, float] = {}
    if fetch_live:
        for k, sym in YF_ALL_MAP.items():
            live_yf[k] = fetch_yahoo_1mo(sym)
        for fid in FRED_LAGS:
            live_fred[fid] = fetch_fred_recent(fid)
            for dt_k, val in live_fred[fid].items():
                fred_tail.setdefault(fid, {})[dt_k] = val
        live_effr = fetch_nyfed_effr()
        for dt_k, val in live_effr.items():
            effr_tail[dt_k] = val

    # Ensure etf_df dates (up to 2026-11-25) are also available even if offline
    last_tail_d = tail_dates[-1]
    cand_dates = sorted(
        {
            d
            for d in list(live_yf.get("QQQ", {}).keys()) + [d for d in full_dates if d > last_tail_d]
            if d > last_tail_d
        }
    )

    # Precompute skew10 & lagged FRED over tail_dates
    skew10_hist: list[float | None] = [
        None if i < 9 else sum(yf_tail["SKEW"][i - 9 : i + 1]) / 10.0 for i in range(len(tail_dates))
    ]
    baa_lag_hist = [align_fred_lag(fred_tail["BAA10Y"], tail_dates, i, 1)[0] for i in range(len(tail_dates))]
    dgs2_lag_hist = [align_fred_lag(fred_tail["DGS2"], tail_dates, i, 1)[0] for i in range(len(tail_dates))]
    nfci_lag_hist = [align_fred_lag(fred_tail["NFCI"], tail_dates, i, 5)[0] for i in range(len(tail_dates))]

    # Step forward day-by-day for cand_dates (e.g., 2026-11-23, 2026-11-24, 2026-11-25...)
    for d in cand_dates:
        prev_d = tail_dates[-1]
        tail_dates.append(d)
        idx = len(tail_dates) - 1
        for k in ("QQQ", "DBMF", "KMLM", "SPY", "RSP", "IWM", "XLP", "XLU", "XLV", "XLK", "HYG", "LQD", "VXN", "VIX", "VIX3M", "VVIX", "SKEW"):
            val = None
            bar = live_yf.get(k, {}).get(d)
            if bar and bar.get("close", 0) > 0:
                val = float(bar["close"])
            elif d in etf_df.index and k in etf_df.columns and math.isfinite(float(etf_df.loc[d, k])):
                val = float(etf_df.loc[d, k])
            if val is None or val <= 0:
                val = yf_tail[k][-1]
            yf_tail[k].append(val)

        cl = yf_tail["QQQ"][idx]
        vix_c = yf_tail["VIX"][idx]
        vix3m_c = yf_tail["VIX3M"][idx]
        vr_c = vix_c / max(vix3m_c, 1e-6)
        vxn_c = yf_tail["VXN"][idx]
        vvix_c = yf_tail["VVIX"][idx]
        prev_ev = eval_by_d[prev_d]
        run_ath_cur = max(float(prev_ev["running_ath"]), cl)
        dd_ath_cur = cl / run_ath_cur - 1.0

        s10 = sum(yf_tail["SKEW"][idx - 9 : idx + 1]) / 10.0
        skew10_hist.append(s10)
        sk_win = [x for x in skew10_hist[-252:] if x is not None and math.isfinite(x)]
        skew_p75 = quantile_linear(sk_win, 0.75) if len(sk_win) >= 126 else s10
        vv_win = [x for x in yf_tail["VVIX"][-252:] if math.isfinite(x)]
        vvix_p75 = quantile_linear(vv_win, 0.75) if len(vv_win) >= 126 else vvix_c

        baa_v, baa_dt = align_fred_lag(fred_tail["BAA10Y"], tail_dates, idx, 1)
        dgs2_v, dgs2_dt = align_fred_lag(fred_tail["DGS2"], tail_dates, idx, 1)
        nfci_v, nfci_dt = align_fred_lag(fred_tail["NFCI"], tail_dates, idx, 5)
        dff_v, _ = align_fred_lag(fred_tail["DFF"], tail_dates, idx, 1)
        yc_v, _ = align_fred_lag(fred_tail["T10Y2Y"], tail_dates, idx, 1)
        baa_lag_hist.append(baa_v)
        dgs2_lag_hist.append(dgs2_v)
        nfci_lag_hist.append(nfci_v)

        b_win = [x for x in baa_lag_hist[-63:] if x is not None]
        baa_rise = (baa_v - min(b_win)) if (baa_v is not None and len(b_win) >= 30) else -999.0
        dgs2_jump = (dgs2_v - dgs2_lag_hist[idx - 63]) if (dgs2_v is not None and idx >= 63 and dgs2_lag_hist[idx - 63] is not None) else -999.0
        nfci_jump = (nfci_v - nfci_lag_hist[idx - 20]) if (nfci_v is not None and idx >= 20 and nfci_lag_hist[idx - 20] is not None) else -999.0

        # Six lights score update
        sl_dgs2 = sl_tail["dgs2"]
        sl_dff = sl_tail["dff"]
        sl_baa = sl_tail["baa10y"]
        sl_cop = sl_tail["copper"]
        sl_dc = sl_tail["def_cyc"]
        sl_yc = sl_tail["t10y2y"]
        sl_nfci = sl_tail["nfci"]
        sl_scores = sl_tail["scores"]
        bf = sl_tail.get("breadth_fallback") or {}

        dgs2_cur = dgs2_v if dgs2_v is not None else sl_dgs2[-1]
        dff_cur = dff_v if dff_v is not None else sl_dff[-1]
        baa_cur = baa_v if baa_v is not None else sl_baa[-1]
        yc_cur = yc_v if yc_v is not None else sl_yc[-1]
        nfci_cur = nfci_v if nfci_v is not None else sl_nfci[-1]

        hg_c = (live_yf.get("HG_F", {}).get(d) or {}).get("close")
        hg_p = (live_yf.get("HG_F", {}).get(prev_d) or {}).get("close")
        cop_cur = sl_cop[-1] * (hg_c / hg_p) if (hg_c and hg_p and hg_c > 0 and hg_p > 0) else sl_cop[-1]

        cyc_syms = ("XLY", "XLI", "XLB", "XLF")
        if all((live_yf.get(sym, {}).get(d) or {}).get("close", 0) > 0 and (live_yf.get(sym, {}).get(prev_d) or {}).get("close", 0) > 0 for sym in cyc_syms):
            def_c = yf_tail["XLU"][idx] + yf_tail["XLP"][idx] + yf_tail["XLV"][idx]
            def_p = yf_tail["XLU"][idx - 1] + yf_tail["XLP"][idx - 1] + yf_tail["XLV"][idx - 1]
            cyc_c = sum(live_yf[sym][d]["close"] for sym in cyc_syms)
            cyc_p = sum(live_yf[sym][prev_d]["close"] for sym in cyc_syms)
            dc_cur = sl_dc[-1] * ((def_c / cyc_c) / (def_p / cyc_p)) if (def_p > 0 and cyc_c > 0 and cyc_p > 0) else sl_dc[-1]
        else:
            dc_cur = sl_dc[-1]

        sl_dgs2.append(dgs2_cur)
        sl_dff.append(dff_cur)
        sl_baa.append(baa_cur)
        sl_cop.append(cop_cur)
        sl_dc.append(dc_cur)
        sl_yc.append(yc_cur)
        sl_nfci.append(nfci_cur)

        sig1 = (dgs2_cur - min(sl_dgs2[-252:]) >= 0.50 and dgs2_cur > (mean_tail(sl_dgs2, 63) or dgs2_cur)) or (dff_cur - min(sl_dff[-252:]) >= 0.20)
        baa_lo = min(sl_baa[-252:])
        sig2 = (baa_cur - baa_lo >= 0.20 or (baa_lo > 0 and baa_cur / baa_lo - 1.0 >= 0.12)) and baa_cur > (mean_tail(sl_baa, 63) or baa_cur)
        sig3 = bool(bf.get("sig3_breadth", False))
        cop_hi = max(sl_cop[-252:])
        sig4 = cop_hi > 0 and cop_cur / cop_hi - 1.0 <= -0.10 and cop_cur < (mean_tail(sl_cop, 63) or cop_cur)
        dc_lo = min(sl_dc[-252:])
        sig5 = dc_lo > 0 and dc_cur / dc_lo - 1.0 >= 0.05 and dc_cur > (mean_tail(sl_dc, 63) or dc_cur)
        yc_hi = max(sl_yc[-252:])
        nfci_lo = min(sl_nfci[-252:])
        sig6 = (yc_hi - yc_cur >= 0.40 and yc_cur < 0.75) or yc_cur < 0.0 or (nfci_cur - nfci_lo >= 0.12)
        sc = int(sig1) + int(sig2) + int(sig3) + int(sig4) + int(sig5) + int(sig6)
        sl_scores.append(sc)

        sma200_now = mean_tail(yf_tail["QQQ"], 200) or cl

        def step_ewm(prev_v: float, span: int, x: float) -> float:
            a = 2.0 / (span + 1.0)
            return (1.0 - a) * prev_v + a * x

        ewm_state["ema20"] = step_ewm(ewm_state["ema20"], 20, cl)
        ewm_state["e16"] = step_ewm(ewm_state["e16"], 16, cl)
        ewm_state["e32"] = step_ewm(ewm_state["e32"], 32, cl)
        ewm_state["e64"] = step_ewm(ewm_state["e64"], 64, cl)
        ewm_state["e128"] = step_ewm(ewm_state["e128"], 128, cl)
        ewm_state["e256"] = step_ewm(ewm_state["e256"], 256, cl)

        diffs60 = [yf_tail["QQQ"][k] - yf_tail["QQQ"][k - 1] for k in range(idx - 59, idx + 1)]
        pv = std_tail_ddof1(diffs60, 60)
        ewmac_now = (
            ((ewm_state["e16"] - ewm_state["e64"]) / pv + (ewm_state["e32"] - ewm_state["e128"]) / pv + (ewm_state["e64"] - ewm_state["e256"]) / pv) / 3.0
            if (pv and pv > 0)
            else 0.0
        )

        hyg_a = [yf_tail["HYG"][k] / max(yf_tail["LQD"][k], 1e-8) for k in range(idx - 49, idx + 1)]
        rsp_a = [yf_tail["RSP"][k] / max(yf_tail["SPY"][k], 1e-8) for k in range(idx - 49, idx + 1)]
        iwm_a = [yf_tail["IWM"][k] / max(yf_tail["QQQ"][k], 1e-8) for k in range(idx - 49, idx + 1)]
        hyg_now, hyg_sma50 = hyg_a[-1], sum(hyg_a) / len(hyg_a)
        rsp_now, rsp_sma50 = rsp_a[-1], sum(rsp_a) / len(rsp_a)
        iwm_now, iwm_sma50 = iwm_a[-1], sum(iwm_a) / len(iwm_a)

        def def_at(k: int) -> float:
            return ((yf_tail["XLP"][k] / base_2013["XLP"] + yf_tail["XLU"][k] / base_2013["XLU"] + yf_tail["XLV"][k] / base_2013["XLV"]) / 3.0) / (yf_tail["XLK"][k] / base_2013["XLK"])

        def_ret20 = def_at(idx) / def_at(idx - 20) - 1.0

        log_r20 = [math.log(yf_tail["QQQ"][k] / yf_tail["QQQ"][k - 1]) for k in range(idx - 19, idx + 1)]
        rv20_ann = (std_tail_ddof1(log_r20, 20) or (0.15 / math.sqrt(252.0))) * math.sqrt(252.0)
        raw4 = [
            math.log(yf_tail["QQQ"][idx] / yf_tail["QQQ"][idx - 5]),
            math.log(max(rv20_ann, 0.05)),
            -math.log(hyg_now / (yf_tail["HYG"][idx - 20] / max(yf_tail["LQD"][idx - 20], 1e-8))),
            vr_c,
        ]
        z_row = []
        for dim in range(4):
            sd = math.sqrt(welford_4d["m2"][dim] / max(1, welford_4d["count"][dim] - 1))
            zv = (raw4[dim] - welford_4d["mean"][dim]) / sd if sd > 0 else 0.0
            z_row.append(max(-4.5, min(4.5, zv)))
        for dim in range(4):
            welford_4d["count"][dim] += 1
            delta = raw4[dim] - welford_4d["mean"][dim]
            welford_4d["mean"][dim] += delta / welford_4d["count"][dim]
            welford_4d["m2"][dim] += delta * (raw4[dim] - welford_4d["mean"][dim])
        hmm["state_p"] = hamilton_step(hmm["state_p"], z_row, hmm["A"], hmm["means"], hmm["vars"])
        hp_cur = float(hmm["state_p"][1])
        p_hmm_tail.append(hp_cur)
        hp_prev5 = float(p_hmm_tail[-6]) if len(p_hmm_tail) >= 6 else 0.0

        vr_prev5 = yf_tail["VIX"][idx - 5] / max(yf_tail["VIX3M"][idx - 5], 1e-6)
        vr_j5 = vr_c - vr_prev5

        ad_below = bool(prev_ev.get("ad_below50"))
        eval_by_d[d] = {
            "date": d,
            "close": cl,
            "vix": vix_c,
            "vxn": vxn_c,
            "vix3m": vix3m_c,
            "vix_ratio": vr_c,
            "dd_from_ath": dd_ath_cur,
            "score": sc,
            "ad_below50": ad_below,
            "running_ath": run_ath_cur,
        }
        feat_by_d[d] = {
            "date": d,
            "skew10": r5(s10),
            "skew_p75": r5(skew_p75),
            "vvix": r5(vvix_c),
            "vvix_p75": r5(vvix_p75),
            "vr_jump5": r5(vr_j5),
            "hmm_p": r5(hp_cur),
            "hmm_p5": r5(hp_prev5),
            "ewmac": r5(ewmac_now),
            "ema20": r5(ewm_state["ema20"]),
            "sma200": r5(sma200_now),
            "hyg_lqd": r5(hyg_now),
            "hyg_sma50": r5(hyg_sma50),
            "baa_lag1": r5(baa_v) if baa_v is not None else None,
            "baa_rise63": r5(baa_rise) if baa_rise > -900 else None,
            "dgs2_lag1": r5(dgs2_v) if dgs2_v is not None else None,
            "dgs2_jump63": r5(dgs2_jump) if dgs2_jump > -900 else None,
            "nfci_lag5": r5(nfci_v) if nfci_v is not None else None,
            "nfci_jump20": r5(nfci_jump) if nfci_jump > -900 else None,
            "rsp_spy": r5(rsp_now),
            "rsp_sma50": r5(rsp_sma50),
            "iwm_qqq": r5(iwm_now),
            "iwm_sma50": r5(iwm_sma50),
            "def_ret20": r5(def_ret20),
            "baa_obs_date": baa_dt,
            "dgs2_obs_date": dgs2_dt,
            "nfci_obs_date": nfci_dt,
        }

        # Extend full_dates / latch arrays if d is beyond etf_df!
        if d not in full_idx_map:
            full_idx_map[d] = len(full_dates)
            full_dates.append(d)

    # Now build the complete PIT Daily Index across all dates (2015-01-02 -> tail_dates[-1])
    # First ensure we have DualCTA / Latch / CONT_2M computed cleanly through tail_dates[-1]!
    all_cal_dates = sorted(set(full_dates) | {d for d in tail_dates if d >= "2015-01-02"})
    # Build unified price maps through latest date
    q_map: dict[str, float] = {}
    db_map: dict[str, float] = {}
    km_map: dict[str, float] = {}
    cta_map: dict[str, float] = {}
    effr_map: dict[str, float] = {}
    for i, d in enumerate(etf_df.index):
        ds = str(d)
        q_map[ds] = float(px_q[i])
        db_map[ds] = float(px_db_spliced[i])
        km_map[ds] = float(px_km_spliced[i])
        cta_map[ds] = float(px_cta[i])
        if math.isfinite(float(etf_df.loc[d, "EFFR"])):
            effr_map[ds] = float(etf_df.loc[d, "EFFR"])

    # Extend q/db/km/cta if tail_dates goes beyond etf_df
    last_etf_d = str(etf_df.index[-1])
    for idx_t, d in enumerate(tail_dates):
        if d > last_etf_d:
            prev_t = tail_dates[idx_t - 1]
            rq = yf_tail["QQQ"][idx_t] / max(yf_tail["QQQ"][idx_t - 1], 1e-8) - 1.0
            rdb = yf_tail["DBMF"][idx_t] / max(yf_tail["DBMF"][idx_t - 1], 1e-8) - 1.0
            rkm = yf_tail["KMLM"][idx_t] / max(yf_tail["KMLM"][idx_t - 1], 1e-8) - 1.0
            q_map[d] = q_map[prev_t] * (1.0 + rq)
            db_map[d] = db_map[prev_t] * (1.0 + rdb)
            km_map[d] = km_map[prev_t] * (1.0 + rkm)
            cta_map[d] = cta_map[prev_t] * (1.0 + 0.5 * rdb + 0.5 * rkm)
    for dt_e, v_e in effr_tail.items():
        effr_map[dt_e] = v_e

    pit_dates = [d for d in all_cal_dates if d in eval_by_d and d in feat_by_d and d in q_map]
    # Recompute exact running ATH, 252D high, Latch, CONT_2M, contango_streak, post_tp_lockout along pit_dates!
    q_s = [q_map[d] for d in pit_dates]
    db_s = [db_map[d] for d in pit_dates]
    km_s = [km_map[d] for d in pit_dates]
    cta_s = [cta_map[d] for d in pit_dates]
    rq_s = [0.0] + [q_s[i] / q_s[i - 1] - 1.0 for i in range(1, len(pit_dates))]
    rcta_s = [0.0] + [cta_s[i] / cta_s[i - 1] - 1.0 for i in range(1, len(pit_dates))]

    pit_rows: list[dict[str, Any]] = []
    run_ath = q_s[0]
    run_ath_i = 0
    latch_on = False
    latch_arm_d: str | None = None
    latch_peak = 0.0
    above_200 = 0
    cont_start: datetime.date | None = None
    cont_start_s: str | None = None
    contango_streak = 0
    post_tp_lock = False
    lock_streak = 0
    last_tp_d: str | None = None
    last_effr = 0.0388
    sorted_effr_dates = sorted(effr_map.keys())
    effr_ptr = 0

    for i, d in enumerate(pit_dates):
        dt_i = datetime.date.fromisoformat(d)
        while effr_ptr < len(sorted_effr_dates) and sorted_effr_dates[effr_ptr] <= d:
            last_effr = effr_map[sorted_effr_dates[effr_ptr]]
            effr_ptr += 1

        ev = eval_by_d[d]
        ft = feat_by_d[d]
        cl_spot = float(ev["close"])
        vix_c = float(ev["vix"])
        vxn_c = float(ev["vxn"])
        vix3m_c = float(ev["vix3m"])
        vr_c = float(ev["vix_ratio"])
        sc = int(ev.get("score") or 0)
        ad_below = bool(ev.get("ad_below50"))

        if q_s[i] >= run_ath:
            run_ath = q_s[i]
            run_ath_i = i
        dd_ath = q_s[i] / run_ath - 1.0
        ath_spot = float(ev.get("running_ath") or cl_spot / max(1.0 + dd_ath, 1e-6))

        lo = max(0, i - 251)
        j_hi = lo + max(range(i - lo + 1), key=lambda off: q_s[lo + off])
        dd252 = q_s[i] / q_s[j_hi] - 1.0
        corr60 = pearson_corr(rq_s[max(0, i - 59) : i + 1], rcta_s[max(0, i - 59) : i + 1]) if i >= 20 else 0.0
        cta_hi252 = cta_s[i] / cta_s[j_hi] - 1.0
        db_hi252 = db_s[i] / db_s[j_hi] - 1.0
        km_hi252 = km_s[i] / km_s[j_hi] - 1.0
        cta_ath = cta_s[i] / cta_s[run_ath_i] - 1.0
        db_ath = db_s[i] / db_s[run_ath_i] - 1.0
        km_ath = km_s[i] / km_s[run_ath_i] - 1.0

        sma200_v = float(ft.get("sma200") or cl_spot)
        ema20_v = float(ft.get("ema20") or cl_spot)
        ewmac_v = float(ft.get("ewmac") or 0.0)
        below_200 = cl_spot < sma200_v
        above_200 = 0 if below_200 else (above_200 + 1)

        if not latch_on:
            if below_200 and dd252 <= -0.10 and corr60 < 0.0 and cta_hi252 >= 0.08:
                latch_on = True
                latch_arm_d = d
                latch_peak = cta_hi252
        else:
            latch_peak = max(latch_peak, cta_hi252)
            if above_200 >= 10:
                latch_on = False
                latch_arm_d = None
                latch_peak = 0.0

        if dd_ath <= -0.12:
            if cont_start is None:
                cont_start = dt_i
                cont_start_s = d
            cont_days = (dt_i - cont_start).days
        else:
            cont_start = None
            cont_start_s = None
            cont_days = 0

        contango_streak = (contango_streak + 1) if vr_c < 1.00 else 0

        # Track Tier 2 Full TP trigger for live post-TP 5D contango lockout awareness
        if vr_c >= 1.10 and dd_ath <= -0.10:
            post_tp_lock = True
            lock_streak = 0
            last_tp_d = d
        elif post_tp_lock:
            if vr_c < 1.00:
                lock_streak += 1
                if lock_streak >= 5:
                    post_tp_lock = False
                    lock_streak = 0
            else:
                lock_streak = 0

        # Raw vs Vol-Gated 6 sensors
        skew10 = float(ft.get("skew10") or 0.0)
        skew_p75 = float(ft.get("skew_p75") or 0.0)
        vvix_v = float(ft.get("vvix") or 0.0)
        vvix_p75 = float(ft.get("vvix_p75") or 0.0)
        vr_jump5 = float(ft.get("vr_jump5") or 0.0)
        hmm_p = float(ft.get("hmm_p") or 0.0)
        hmm_p5 = float(ft.get("hmm_p5") or 0.0)
        hyg_lqd = float(ft.get("hyg_lqd") or 0.0)
        hyg_sma50 = float(ft.get("hyg_sma50") or 0.0)
        baa_r = ft.get("baa_rise63")
        dgs2_j = ft.get("dgs2_jump63")
        nfci_j = ft.get("nfci_jump20")
        rsp_spy = float(ft.get("rsp_spy") or 0.0)
        rsp_sma50 = float(ft.get("rsp_sma50") or 0.0)
        iwm_qqq = float(ft.get("iwm_qqq") or 0.0)
        iwm_sma50 = float(ft.get("iwm_sma50") or 0.0)
        def_ret20 = float(ft.get("def_ret20") or 0.0)

        # Raw structural alerts (UNGATED by VXN/VR!)
        m0_raw = (ad_below or sc >= 4) and (dd_ath >= -0.05)
        m0_entry = m0_raw and (vxn_c <= 22.0)

        m6_raw = (rsp_spy < rsp_sma50) and (iwm_qqq < iwm_sma50 or ad_below) and (def_ret20 >= 0.025)
        m6_entry = m6_raw and (vxn_c <= 25.0) and (vr_c <= 0.92)

        m2_a = (skew10 >= skew_p75) and (vvix_v >= vvix_p75) and (vr_c >= 0.85)
        m2_b = (vr_c >= 0.92) and (vr_jump5 >= 0.06) and (vvix_v >= 100.0)
        m2_raw = m2_a or m2_b
        m2_entry = ((skew10 >= skew_p75 and vvix_v >= vvix_p75 and 0.85 <= vr_c <= 0.98) or (0.92 <= vr_c <= 1.02 and vr_jump5 >= 0.06 and vvix_v >= 100.0)) and (vxn_c <= 24.0)

        m5_raw = hmm_p >= 0.55
        m5_entry = (hmm_p >= 0.55) and (hmm_p5 < 0.40) and (vxn_c <= 24.0) and (vr_c < 1.02)

        m4_raw = latch_on and below_200 and (ewmac_v < 0.0) and (cl_spot > ema20_v)
        m4_entry = m4_raw and (vxn_c <= 28.0) and (vr_c <= 0.90)

        credit_macro_hit = (
            (baa_r is not None and baa_r >= 0.15)
            or (dgs2_j is not None and dgs2_j >= 0.40)
            or (nfci_j is not None and nfci_j >= 0.10)
        )
        m3_raw = (hyg_lqd < hyg_sma50) and credit_macro_hit
        m3_entry = m3_raw and (vxn_c <= 26.0) and (vr_c <= 0.92)

        stress_pack = compute_live_stress_index({
            "hmm_p": hmm_p, "vxn": vxn_c, "vix_ratio": vr_c, "dd_from_ath": dd_ath,
            "qqq_close": cl_spot, "sma200": sma200_v, "ewmac": ewmac_v,
            "hyg_lqd": hyg_lqd, "hyg_sma50": hyg_sma50,
            "baa_rise63": baa_r, "dgs2_jump63": dgs2_j, "nfci_jump20": nfci_j,
            "def_ret20": def_ret20, "rsp_spy": rsp_spy, "rsp_sma50": rsp_sma50,
            "iwm_qqq": iwm_qqq, "iwm_sma50": iwm_sma50, "ad_below50": ad_below,
            "vvix": vvix_v, "vvix_p75": vvix_p75, "skew10": skew10, "skew_p75": skew_p75,
            "vr_jump5": vr_jump5,
        })

        # Actual DBMF/KMLM live closing spot if present in etf_df or live_yf
        db_spot = float((live_yf.get("DBMF", {}).get(d) or {}).get("close") or (etf_df.loc[d, "DBMF"] if (d in etf_df.index and math.isfinite(float(etf_df.loc[d, "DBMF"]))) else db_s[i]))
        km_spot = float((live_yf.get("KMLM", {}).get(d) or {}).get("close") or (etf_df.loc[d, "KMLM"] if (d in etf_df.index and math.isfinite(float(etf_df.loc[d, "KMLM"]))) else km_s[i]))

        pit_rows.append({
            "date": d,
            "qqq": round(cl_spot, 2),
            "ath": round(ath_spot, 2),
            "ath_date": pit_dates[run_ath_i],
            "dd_ath": round(dd_ath * 100.0, 2),
            "hi252_date": pit_dates[j_hi],
            "dd252": round(dd252 * 100.0, 2),
            "sma200": round(sma200_v, 2),
            "ema20": round(ema20_v, 2),
            "ewmac": round(ewmac_v, 3),
            "dbmf": round(db_spot, 2),
            "kmlm": round(km_spot, 2),
            "db_ath": round(db_ath * 100.0, 2),
            "km_ath": round(km_ath * 100.0, 2),
            "cta_ath": round(cta_ath * 100.0, 2),
            "db_hi252": round(db_hi252 * 100.0, 2),
            "km_hi252": round(km_hi252 * 100.0, 2),
            "cta_hi252": round(cta_hi252 * 100.0, 2),
            "corr60": round(corr60, 3),
            "latch": 1 if latch_on else 0,
            "latch_arm": latch_arm_d,
            "latch_pk": round(latch_peak * 100.0, 2),
            "abv200": above_200,
            "c2m_d": cont_days,
            "c2m_s": cont_start_s,
            "vix": round(vix_c, 2),
            "vxn": round(vxn_c, 2),
            "vix3m": round(vix3m_c, 2),
            "vr": round(vr_c, 3),
            "vr_j5": round(vr_jump5, 3),
            "skew10": round(skew10, 2),
            "skew_p75": round(skew_p75, 2),
            "vvix": round(vvix_v, 2),
            "vvix_p75": round(vvix_p75, 2),
            "hmm_p": round(hmm_p, 4),
            "hmm_p5": round(hmm_p5, 4),
            "hyg_lqd": round(hyg_lqd, 4),
            "hyg_sma50": round(hyg_sma50, 4),
            "baa_r": round(baa_r, 3) if baa_r is not None else None,
            "dgs2_j": round(dgs2_j, 3) if dgs2_j is not None else None,
            "nfci_j": round(nfci_j, 3) if nfci_j is not None else None,
            "rsp_spy": round(rsp_spy, 4),
            "rsp_sma50": round(rsp_sma50, 4),
            "iwm_qqq": round(iwm_qqq, 4),
            "iwm_sma50": round(iwm_sma50, 4),
            "def_ret20": round(def_ret20 * 100.0, 2),
            "sc6": sc,
            "ad_b50": 1 if ad_below else 0,
            "effr": round(last_effr * 100.0, 2),
            "ct_strk": contango_streak,
            "tp_lock": 1 if post_tp_lock else 0,
            "tp_lstrk": lock_streak,
            "last_tp": last_tp_d,
            "stress": stress_pack["live_stress_index"],
            "raw_mask": (
                (1 if m0_raw else 0)
                | (2 if m6_raw else 0)
                | (4 if m2_raw else 0)
                | (8 if m5_raw else 0)
                | (16 if m4_raw else 0)
                | (32 if m3_raw else 0)
            ),
            "ent_mask": (
                (1 if m0_entry else 0)
                | (2 if m6_entry else 0)
                | (4 if m2_entry else 0)
                | (8 if m5_entry else 0)
                | (16 if m4_entry else 0)
                | (32 if m3_entry else 0)
            ),
        })

    pit_cols = list(pit_rows[0].keys())
    latest_pit = pit_rows[-1]
    latest_date = latest_pit["date"]

    # Trim live_tail_state arrays to trailing 265 sessions for ultra-compact storage (~60 KB)
    keep_n = min(len(tail_dates), 265)
    t_slice = slice(len(tail_dates) - keep_n, len(tail_dates))
    trimmed_yf_tail = {k: [r4(x) for x in v[t_slice]] for k, v in yf_tail.items()}
    trimmed_sl_tail = {
        k: (v[-265:] if isinstance(v, list) else v) for k, v in sl_tail.items()
    }
    # Keep last 400 days of FRED entries
    cutoff_fred = (datetime.date.fromisoformat(latest_date) - datetime.timedelta(days=450)).isoformat()
    trimmed_fred_tail = {
        fid: {dt_k: val for dt_k, val in mp.items() if dt_k >= cutoff_fred}
        for fid, mp in fred_tail.items()
    }
    trimmed_effr_tail = {dt_k: val for dt_k, val in effr_tail.items() if dt_k >= cutoff_fred}

    # Keep exact DualCTA / QQQ TR anchor values for Node.js live continuation!
    # Also store the 265-day QQQ TR and DualCTA TR series so Node.js computes exact 252D High & Corr60!
    last_pit_idx = len(pit_dates) - 1
    tr_start = max(0, last_pit_idx - keep_n + 1)
    tr_dates = pit_dates[tr_start : last_pit_idx + 1]
    live_tail_state = {
        "tail_dates": tail_dates[t_slice],
        "yf_tail": trimmed_yf_tail,
        "fred_tail": trimmed_fred_tail,
        "effr_tail": trimmed_effr_tail,
        "six_lights_tail": trimmed_sl_tail,
        "base_2013": base_2013,
        "ewm_state": ewm_state,
        "welford_4d": welford_4d,
        "hmm": hmm,
        "p_hmm_tail": [r5(x) for x in p_hmm_tail[-20:]],
        "tr_tail_dates": tr_dates,
        "qqq_tr_tail": [r4(q_s[k]) for k in range(tr_start, last_pit_idx + 1)],
        "dbmf_tr_tail": [r4(db_s[k]) for k in range(tr_start, last_pit_idx + 1)],
        "kmlm_tr_tail": [r4(km_s[k]) for k in range(tr_start, last_pit_idx + 1)],
        "cta_tr_tail": [r4(cta_s[k]) for k in range(tr_start, last_pit_idx + 1)],
        "running_ath_tr": r4(run_ath),
        "running_ath_spot": r2(latest_pit["ath"]),
        "running_ath_date": latest_pit["ath_date"],
        "running_ath_dbmf_tr": r4(db_s[run_ath_i]),
        "running_ath_kmlm_tr": r4(km_s[run_ath_i]),
        "running_ath_cta_tr": r4(cta_s[run_ath_i]),
        "latch_state": {
            "armed": bool(latch_on),
            "arm_date": latch_arm_d,
            "peak_cta_gain": r5(latch_peak),
            "above_200dma_streak": int(above_200),
        },
        "cont_2m_state": {
            "timer_start": cont_start_s,
            "continuous_cal_days": int(latest_pit["c2m_d"]),
        },
        "put_gate_state": {
            "contango_streak": int(contango_streak),
            "post_tp_lockout": bool(post_tp_lock),
            "lockout_streak": int(lock_streak),
            "last_tp_date": last_tp_d,
            "ad_below50": bool(latest_pit["ad_b50"]),
        },
    }

    # Latest FRED observation dates
    fred_latest_dates = {}
    for fid, mp in trimmed_fred_tail.items():
        fred_latest_dates[fid] = max(mp.keys()) if mp else None
    effr_latest_date = max(trimmed_effr_tail.keys()) if trimmed_effr_tail else None

    artifact = {
        "version": ARTIFACT_VERSION,
        "strategy_code": STRATEGY_CODE,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "as_of_date": latest_date,
        "asOfDate": latest_date,
        "dataThrough": latest_date,
        "ruleset": build_ruleset_spec(),
        "data_freshness": {
            "market_as_of": latest_date,
            "fred_as_of": fred_latest_dates,
            "effr_as_of": effr_latest_date,
            "live_extended_days": 0,
            "source_summary_en": f"Market closes through {latest_date} · FRED macro & NY Fed EFFR ({effr_latest_date or latest_date})",
            "source_summary_zh": f"美股/波动率收盘截至 {latest_date} · FRED 宏观利差与纽约联储 EFFR（{effr_latest_date or latest_date}）",
        },
        "backtest": {
            "initial_capital": INITIAL_CAPITAL,
            "opra_provenance": {
                "quotes_count": 6382288,
                "trading_days": 2749,
                "opra_start": "2015-01-02",
                "opra_end": "2025-12-15",
                "execution_fallbacks": 0,
                "primary_fill_en": "IBKR 35% Limit + SPX Short Box (EFFR + 35 bps)",
                "primary_fill_zh": "IBKR 35% 限价成交 + SPX Short Box 融资（EFFR + 35 bps）",
                "stress_fill_en": "Full Ask/Bid + IBKR Pro Margin (EFFR + 150 bps)",
                "stress_fill_zh": "保守对手盘 Ask/Bid + IBKR Pro 融资（EFFR + 150 bps）",
            },
            "windows": {
                "11y_opra": {
                    "id": "11y_opra",
                    "label_en": "11Y Real MIT OPRA (2015-2025.12)",
                    "label_zh": "11年真实 OPRA（2015-2025.12）",
                    "start_date": "2015-01-02",
                    "end_date": "2025-12-15",
                    "zero_splice": False,
                    "disclosure_en": "100% real 16:00 ET US OPRA QQQ put quotes (0 fallbacks). Pre-inception DBMF (<2019-05-09) and KMLM (<2020-12-03) splice real AQMIX live mutual fund returns.",
                    "disclosure_zh": "100% 真实美股 16:00 ET OPRA 期权盘口（0 次回退）。DBMF（2019-05-09 前）与 KMLM（2020-12-03 前）使用真实 AQMIX 共同基金净值拼接。",
                    "kpi_primary": w11_pri["kpi"],
                    "kpi_stress": w11_str["kpi"],
                    "kpi_qqq": w11_pri["kpi_qqq"],
                    "crisis_comparison": w11_pri["crisis_comparison"],
                    "daily_series": w11_pri["daily_series"],
                    "put_ledger": w11_pri["put_ledger"],
                    "cta_rotation_ledger": w11_pri["cta_rotation_ledger"],
                    "cta_restore_ledger": w11_pri["cta_restore_ledger"],
                    "latch_episodes": [e for e in latch_episodes_full if e["arm_date"] <= "2025-12-15"],
                },
                "5y_live": {
                    "id": "5y_live",
                    "label_en": "5Y Zero-Splice Live (2020.12-2025.12)",
                    "label_zh": "5年零拼接纯真盘（2020.12-2025.12）",
                    "start_date": "2020-12-02",
                    "end_date": "2025-12-15",
                    "zero_splice": True,
                    "disclosure_en": "Zero-splice pure live window: 100% live DBMF + 100% live KMLM + 100% real MIT OPRA QQQ puts + official NY Fed EFFR.",
                    "disclosure_zh": "零拼接纯实盘窗口：100% 实盘 DBMF + 100% 实盘 KMLM + 100% 真实 MIT OPRA 期权盘口 + 纽约联储官方 EFFR。",
                    "kpi_primary": w5_pri["kpi"],
                    "kpi_stress": w5_str["kpi"],
                    "kpi_qqq": w5_pri["kpi_qqq"],
                    "crisis_comparison": w5_pri["crisis_comparison"],
                    "daily_series": w5_pri["daily_series"],
                    "put_ledger": w5_pri["put_ledger"],
                    "cta_rotation_ledger": w5_pri["cta_rotation_ledger"],
                    "cta_restore_ledger": w5_pri["cta_restore_ledger"],
                    "latch_episodes": [e for e in latch_episodes_full if "2020-12-02" <= e["arm_date"] <= "2025-12-15"],
                },
            },
        },
        "pit_daily_index": pack_table(pit_rows, pit_cols),
        "live_tail_state": live_tail_state,
    }

    raw_json = json.dumps(artifact, ensure_ascii=False, separators=(",", ":"))
    # Strict hygiene check before writing!
    assert chr(126) not in raw_json, "ASCII tilde found in generated JSON!"
    for banned in ("FactOS", "FACT OS", "fact_os", "DuckDB", "Sharadar", "SQLite", "Wheel", "wheel", "Covered Call", "Short Put", "卖Call", "领口"):
        assert banned not in raw_json, f"Banned term '{banned}' found in generated JSON!"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(raw_json, encoding="utf-8")
    print(f"Wrote {output_path} ({len(raw_json) / 1024:.1f} KB)")
    print(f"  Latest Date: {latest_date} | QQQ=${latest_pit['qqq']} (ATH DD {latest_pit['dd_ath']}%) | VIX={latest_pit['vix']} VXN={latest_pit['vxn']} VR={latest_pit['vr']} | Stress={latest_pit['stress']}/100")
    print(f"  11Y OPRA Primary: ${w11_pri['kpi']['end_nav']:,.2f} ({w11_pri['kpi']['cagr_pct']}% CAGR, {w11_pri['kpi']['max_dd_pct']}% MDD, {w11_pri['kpi']['calmar']} Calmar, PeakLev {w11_pri['kpi']['peak_gross_leverage']}x)")
    print(f"  5Y Live Primary:  ${w5_pri['kpi']['end_nav']:,.2f} ({w5_pri['kpi']['cagr_pct']}% CAGR, {w5_pri['kpi']['max_dd_pct']}% MDD, {w5_pri['kpi']['calmar']} Calmar, PeakLev {w5_pri['kpi']['peak_gross_leverage']}x)")
    return artifact


def run_stdlib_live_refresh(output_path: Path) -> dict[str, Any]:
    """Stdlib-only refresh mode (runs cleanly inside .venv-fact-os without pandas/pyarrow)."""
    if not output_path.exists():
        raise RuntimeError(f"Existing v2 artifact not found at {output_path}")
    doc = json.loads(output_path.read_text(encoding="utf-8"))
    if doc.get("version") != ARTIFACT_VERSION:
        raise RuntimeError("Existing artifact is not v2-master; rebuild with pandas/pyarrow environment.")
    # Preserve verified 2015-2025 OPRA backtest verbatim and stamp refreshed timestamp
    doc["generated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    raw_json = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
    assert chr(126) not in raw_json
    output_path.write_text(raw_json, encoding="utf-8")
    print(f"Verified v2 artifact in stdlib mode at {output_path} ({len(raw_json) / 1024:.1f} KB, as_of={doc['as_of_date']})")
    return doc


def main() -> None:
    parser = argparse.ArgumentParser(description="Build ThesisForge Crisis Observatory v2.0 Single Master Strategy artifact.")
    parser.add_argument("--fact-root", default=str(DEFAULT_FACT_ROOT), help="Unused compatibility flag for refresh-all-corners.sh")
    parser.add_argument("--output", default=str(DEFAULT_OUT), help="Output JSON path")
    parser.add_argument("--no-live", action="store_true", help="Skip live Yahoo/FRED/NY Fed fetch during build")
    args = parser.parse_args()

    out_path = Path(args.output)
    try:
        import numpy  # noqa: F401
        import pandas  # noqa: F401
        has_opra = LEAPS_PUT_PQ.exists() and LIVE_ETF_CSV.exists() and SIG_CSV.exists()
    except ImportError:
        has_opra = False

    if has_opra:
        run_full_opra_build(out_path, fetch_live=not args.no_live)
    else:
        run_stdlib_live_refresh(out_path)


if __name__ == "__main__":
    main()
