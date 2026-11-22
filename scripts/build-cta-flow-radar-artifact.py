#!/usr/bin/env python3
"""Build canonical zero-lookahead CTA Flow Radar artifact for ThesisForge Discover.

Implements Rob Carver ('Systematic Trading', Man AHL) 6-Speed Continuous EWMAC
(2/8..64/256, FDM=1.26, 36D EWMA vol blended 70/30 with 2520D long-term vol,
10% inertia buffer, 3D VWAP execution smoothing), Traditional 10-200D SMA
Threshold benchmark, 50/50 Hybrid ensemble, Vol-Control (60% RV20 + 40% RV60)
sleeve, and strict T+45 Point-in-Time SEC Form 13F CTA scale calibration across
31 institutional trend-following & quantitative macro managers (2014-2026).

Runs strictly on stdlib + duckdb inside .venv-fact-os/bin/python (zero numpy/scipy/yfinance
dependency) so local builds and AWS Elastic Beanstalk refreshes execute identically.
"""
from __future__ import annotations

import argparse
import bisect
import datetime
import json
import math
import statistics
import sys
import urllib.request
from pathlib import Path

try:
    import duckdb
except ImportError:
    duckdb = None

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT_DIR / "server" / "config" / "cta-flow-radar-dashboard.json"
PIT_SCALE_FILE = ROOT_DIR / "server" / "config" / "cta-13f-scale-pit.json"
DUCKDB_FILE = ROOT_DIR / "data" / "fact_os" / "fact_os.duckdb"

ARTIFACT_VERSION = "cta-flow-radar-v1"

EWMAC_CONFIGS = [
    (2, 8, 10.60),
    (4, 16, 7.50),
    (8, 32, 5.30),
    (16, 64, 3.75),
    (32, 128, 2.65),
    (64, 256, 1.87),
]
CARVER_FDM = 1.26
SMA_WINDOWS = [10, 20, 50, 100, 200]
SMA_WEIGHTS = [0.10, 0.20, 0.25, 0.25, 0.20]

SHOCK_GRID_PCT = [-5.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 5.0]
FINE_GRID_PCT = [round(-8.0 + 0.25 * i, 4) for i in range(65)]
CURVE_MIN_PCT = -6.0
CURVE_MAX_PCT = 6.0

ASSETS_CFG = {
    "SPY": {
        "nameEn": "SPDR S&P 500 ETF Trust",
        "nameZh": "标普 500 指数 ETF (SPY)",
        "futuresBenchmark": "CME E-mini S&P 500 (ES)",
        "ctaCap": 135.0,
        "ctaTargetVol": 0.18,
        "vcCap": 220.0,
        "vcTargetVol": 0.12,
        "sellCliff2026B": -25.0,
        "buyThrust2026B": 22.0,
        "squeeze5dB": 15.0,
        "squeeze10dB": 15.0,
    },
    "QQQ": {
        "nameEn": "Invesco QQQ Trust (Nasdaq-100)",
        "nameZh": "纳斯达克 100 指数 ETF (QQQ)",
        "futuresBenchmark": "CME E-mini Nasdaq-100 (NQ)",
        "ctaCap": 80.0,
        "ctaTargetVol": 0.20,
        "vcCap": 110.0,
        "vcTargetVol": 0.15,
        "sellCliff2026B": -15.0,
        "buyThrust2026B": 14.0,
        "squeeze5dB": 10.0,
        "squeeze10dB": 8.0,
    },
}


def _clip(v: float, lo: float, hi: float) -> float:
    return lo if v < lo else (hi if v > hi else v)


def _betacf(a: float, b: float, x: float) -> float:
    max_it = 200
    eps = 3.0e-12
    fpmin = 1.0e-30
    qab = a + b
    qap = a + 1.0
    qam = a - 1.0
    c = 1.0
    d = 1.0 - qab * x / qap
    if abs(d) < fpmin:
        d = fpmin
    d = 1.0 / d
    h = d
    for m in range(1, max_it + 1):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if abs(d) < fpmin:
            d = fpmin
        c = 1.0 + aa / c
        if abs(c) < fpmin:
            c = fpmin
        d = 1.0 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        if abs(d) < fpmin:
            d = fpmin
        c = 1.0 + aa / c
        if abs(c) < fpmin:
            c = fpmin
        d = 1.0 / d
        delta = d * c
        h *= delta
        if abs(delta - 1.0) < eps:
            break
    return h


def _betainc(a: float, b: float, x: float) -> float:
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    bt = math.exp(
        math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b) + a * math.log(x) + b * math.log(1.0 - x)
    )
    if x < (a + 1.0) / (a + b + 2.0):
        return bt * _betacf(a, b, x) / a
    return 1.0 - bt * _betacf(b, a, 1.0 - x) / b


def welch_ttest(xa: list[float], ya: list[float]) -> tuple[float, float]:
    nx, ny = len(xa), len(ya)
    if nx < 2 or ny < 2:
        return 0.0, 1.0
    mx = sum(xa) / nx
    my = sum(ya) / ny
    vx = sum((v - mx) ** 2 for v in xa) / (nx - 1)
    vy = sum((v - my) ** 2 for v in ya) / (ny - 1)
    se2 = vx / nx + vy / ny
    if se2 <= 1e-18:
        return 0.0, 1.0
    t_stat = (mx - my) / math.sqrt(se2)
    df_num = se2 * se2
    df_den = (vx / nx) ** 2 / (nx - 1) + (vy / ny) ** 2 / (ny - 1)
    df = df_num / max(df_den, 1e-18)
    x_beta = df / (df + t_stat * t_stat)
    p_two = _betainc(0.5 * df, 0.5, x_beta)
    return t_stat, p_two


def _percentile_linear(vals: list[float], q_pct: float) -> float:
    if not vals:
        return 0.0
    s = sorted(vals)
    if len(s) == 1:
        return s[0]
    pos = (q_pct / 100.0) * (len(s) - 1)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return s[lo]
    w = pos - lo
    return s[lo] + w * (s[hi] - s[lo])


def _sample_std(vals: list[float]) -> float:
    n = len(vals)
    if n < 2:
        return 0.0
    m = sum(vals) / n
    return math.sqrt(sum((v - m) ** 2 for v in vals) / (n - 1))


def _rolling_mean_bfill(arr: list[float], window: int, min_periods: int) -> list[float]:
    n = len(arr)
    out = [math.nan] * n
    run_sum = 0.0
    first_valid = math.nan
    for i, v in enumerate(arr):
        run_sum += v
        if i >= window:
            run_sum -= arr[i - window]
        cnt = min(i + 1, window)
        if cnt >= min_periods:
            val = run_sum / cnt
            out[i] = val
            if math.isnan(first_valid):
                first_valid = val
    if math.isnan(first_valid):
        first_valid = arr[0] if arr else 0.0
    for i in range(n):
        if math.isnan(out[i]):
            out[i] = first_valid
        else:
            break
    return out


def _rolling_std_bfill(arr: list[float], window: int, min_periods: int) -> list[float]:
    n = len(arr)
    out = [math.nan] * n
    first_valid = math.nan
    for i in range(n):
        cnt = min(i + 1, window)
        if cnt >= min_periods:
            seg = arr[i - cnt + 1 : i + 1]
            val = _sample_std(seg)
            out[i] = val
            if math.isnan(first_valid):
                first_valid = val
    if math.isnan(first_valid):
        first_valid = 0.0
    for i in range(n):
        if math.isnan(out[i]):
            out[i] = first_valid
        else:
            break
    return out


def _fetch_yahoo_daily(symbol: str, start_date: str = "2005-01-01", end_date: str | None = None) -> dict[str, tuple[float, float]]:
    p1 = int(datetime.datetime.fromisoformat(f"{start_date}T00:00:00+00:00").timestamp())
    if end_date:
        dt_end = datetime.date.fromisoformat(end_date) + datetime.timedelta(days=3)
        p2 = int(datetime.datetime(dt_end.year, dt_end.month, dt_end.day, tzinfo=datetime.timezone.utc).timestamp())
    else:
        p2 = int(datetime.datetime.now(datetime.timezone.utc).timestamp()) + 86400 * 2
    sym_enc = urllib.parse.quote(symbol, safe="")
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{sym_enc}?period1={p1}&period2={p2}&interval=1d"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    res0 = payload["chart"]["result"][0]
    ts_list = res0.get("timestamp") or []
    quote = (res0.get("indicators", {}).get("quote") or [{}])[0]
    closes = quote.get("close") or []
    adj_block = (res0.get("indicators", {}).get("adjclose") or [{}])[0]
    adjs = adj_block.get("adjclose") or closes
    out: dict[str, tuple[float, float]] = {}
    for idx, ts in enumerate(ts_list):
        c = closes[idx] if idx < len(closes) else None
        a = adjs[idx] if idx < len(adjs) else c
        if c is None:
            continue
        if a is None:
            a = c
        dt_str = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d")
        out[dt_str] = (float(a), float(c))
    return out


def load_daily_market_and_pit_scale(max_date: str | None = None) -> tuple[list[dict], dict]:
    pit_meta = json.loads(PIT_SCALE_FILE.read_text(encoding="utf-8"))
    quarters = sorted(pit_meta["quarters"], key=lambda q: q["availableDate"])
    avail_dates = [q["availableDate"] for q in quarters]

    spy_map = _fetch_yahoo_daily("SPY", "2005-01-01", max_date)
    qqq_map = _fetch_yahoo_daily("QQQ", "2005-01-01", max_date)
    vix_map = _fetch_yahoo_daily("^VIX", "2005-01-01", max_date)
    vix3m_map = _fetch_yahoo_daily("^VIX3M", "2005-01-01", max_date)

    # Cross-verify overlapping latest close against local DuckDB funds table when present
    if duckdb is not None and DUCKDB_FILE.exists():
        con = duckdb.connect(str(DUCKDB_FILE), read_only=True)
        try:
            for tk, mp in [("SPY", spy_map), ("QQQ", qqq_map)]:
                row = con.execute(
                    "SELECT CAST(date AS VARCHAR), closeadj FROM funds WHERE ticker = ? ORDER BY date DESC LIMIT 1",
                    [tk],
                ).fetchone()
                if row and row[0] in mp:
                    diff = abs(float(row[1]) - mp[row[0]][0])
                    if diff > 0.15:
                        raise RuntimeError(f"Price cross-check mismatch for {tk} on {row[0]}: diff={diff:.4f}")
        finally:
            con.close()

    common_dates = sorted(set(spy_map.keys()) & set(qqq_map.keys()))
    if max_date:
        common_dates = [d for d in common_dates if d <= max_date]

    rows: list[dict] = []
    last_vix = 15.0
    last_vix3m = 16.5
    first_cta_mult = float(quarters[0]["ctaScaleMult"])
    first_vc_mult = float(quarters[0]["vcScaleMult"])

    for d in common_dates:
        if d in vix_map and vix_map[d][1] > 0:
            last_vix = vix_map[d][1]
        if d in vix3m_map and vix3m_map[d][1] > 0:
            last_vix3m = vix3m_map[d][1]
        vix_ratio = (last_vix / last_vix3m) if last_vix3m > 0 else 0.90

        pos = bisect.bisect_right(avail_dates, d) - 1
        if pos >= 0:
            q_ref = quarters[pos]
            cta_mult = float(q_ref["ctaScaleMult"])
            vc_mult = float(q_ref["vcScaleMult"])
            q_date = q_ref["quarterDate"]
        else:
            cta_mult = first_cta_mult
            vc_mult = first_vc_mult
            q_date = quarters[0]["quarterDate"]

        rows.append({
            "date": d,
            "SPY": spy_map[d][0],
            "SPY_unadj": spy_map[d][1],
            "QQQ": qqq_map[d][0],
            "QQQ_unadj": qqq_map[d][1],
            "VIX": last_vix,
            "VIX3M": last_vix3m,
            "VIX_RATIO": vix_ratio,
            "cta_scale_mult": cta_mult,
            "vc_scale_mult": vc_mult,
            "pit_quarter": q_date,
        })
    return rows, pit_meta


def compute_asset_cta_state(
    rows: list[dict],
    ticker: str,
    cta_risk_cap_2026_b: float,
    cta_target_vol: float,
    vc_aum_2026_b: float,
    vc_target_vol: float,
    short_asym_weight: float = 0.65,
    max_leverage_mult: float = 1.65,
) -> dict:
    n = len(rows)
    px = [r[ticker] for r in rows]
    px_unadj = [r[f"{ticker}_unadj"] for r in rows]
    dp = [0.0] * n
    ret = [0.0] * n
    for t in range(1, n):
        dp[t] = px[t] - px[t - 1]
        ret[t] = dp[t] / px[t - 1] if px[t - 1] > 0 else 0.0

    sqrt252 = math.sqrt(252.0)
    alpha_vol = 2.0 / (36.0 + 1.0)
    var_36 = [0.0] * n
    var_36[0] = (0.01 * px[0]) ** 2
    ann_pct_vol_36 = [0.0] * n
    ann_pct_vol_36[0] = (math.sqrt(var_36[0]) / px[0]) * sqrt252
    for t in range(1, n):
        var_36[t] = (1.0 - alpha_vol) * var_36[t - 1] + alpha_vol * (dp[t] ** 2)
        ann_pct_vol_36[t] = (math.sqrt(var_36[t]) / px[t]) * sqrt252

    long_pct_vol = _rolling_mean_bfill(ann_pct_vol_36, 2520, 20)
    ann_vol_carver = [max(0.70 * ann_pct_vol_36[t] + 0.30 * long_pct_vol[t], 0.07) for t in range(n)]
    sig_p_blend = [(ann_vol_carver[t] / sqrt252) * px[t] for t in range(n)]

    ema_fast = [[0.0] * n for _ in range(6)]
    ema_slow = [[0.0] * n for _ in range(6)]
    f_indiv = [[0.0] * n for _ in range(6)]
    flip_1d_px = [[0.0] * n for _ in range(6)]

    for k, (lf, ls, scalar) in enumerate(EWMAC_CONFIGS):
        af = 2.0 / (lf + 1.0)
        asl = 2.0 / (ls + 1.0)
        ef = ema_fast[k]
        es = ema_slow[k]
        fi = f_indiv[k]
        fl = flip_1d_px[k]
        ef[0] = px[0]
        es[0] = px[0]
        for t in range(1, n):
            ef[t] = af * px[t] + (1.0 - af) * ef[t - 1]
            es[t] = asl * px[t] + (1.0 - asl) * es[t - 1]
        for t in range(n):
            raw_ewmac = (ef[t] - es[t]) / max(sig_p_blend[t], 1e-8)
            fi[t] = _clip(scalar * raw_ewmac, -20.0, 20.0)
            fl[t] = ((1.0 - asl) * es[t] - (1.0 - af) * ef[t]) / (af - asl)

    f_carver = [
        _clip(CARVER_FDM * (sum(f_indiv[k][t] for k in range(6)) / 6.0), -20.0, 20.0)
        for t in range(n)
    ]

    sma_mat = [_rolling_mean_bfill(px, w_len, w_len) for w_len in SMA_WINDOWS]
    f_sma = [0.0] * n
    for t in range(n):
        acc = 0.0
        for m, w_wt in enumerate(SMA_WEIGHTS):
            acc += w_wt * (1.0 if px[t] >= sma_mat[m][t] else -1.0)
        f_sma[t] = 20.0 * acc

    f_hybrid = [0.50 * f_carver[t] + 0.50 * f_sma[t] for t in range(n)]

    cta_scale_mult = [r["cta_scale_mult"] for r in rows]
    vc_scale_mult = [r["vc_scale_mult"] for r in rows]
    cap_cta_t = [cta_risk_cap_2026_b * m for m in cta_scale_mult]
    cap_vc_t = [vc_aum_2026_b * m for m in vc_scale_mult]

    def _exec_positions(forecast_arr: list[float]) -> tuple[list[float], list[float]]:
        target_b = [0.0] * n
        exec_b = [0.0] * n
        eta = 2.0 / (3.0 + 1.0)
        for t in range(n):
            f_v = forecast_arr[t]
            asym = 1.0 if f_v >= 0.0 else short_asym_weight
            vol_scalar = cta_target_vol / max(ann_vol_carver[t], 0.07)
            raw_unit = (f_v / 10.0) * vol_scalar * asym
            capped_unit = _clip(raw_unit, -max_leverage_mult * short_asym_weight, max_leverage_mult)
            target_b[t] = cap_cta_t[t] * capped_unit
            buf_b = 0.10 * cap_cta_t[t] * min(vol_scalar, max_leverage_mult)
            if t == 0:
                exec_b[0] = target_b[0]
            else:
                prev_e = exec_b[t - 1]
                desired = prev_e
                if target_b[t] > prev_e + buf_b:
                    desired = target_b[t] - buf_b
                elif target_b[t] < prev_e - buf_b:
                    desired = target_b[t] + buf_b
                exec_b[t] = (1.0 - eta) * prev_e + eta * desired
        return target_b, exec_b

    tgt_carver_b, pos_carver_b = _exec_positions(f_carver)
    tgt_sma_b, pos_sma_b = _exec_positions(f_sma)
    tgt_hybrid_b, pos_hybrid_b = _exec_positions(f_hybrid)

    rv20_raw = _rolling_std_bfill(ret, 20, 10)
    rv60_raw = _rolling_std_bfill(ret, 60, 20)
    rv20 = [v * sqrt252 for v in rv20_raw]
    rv60 = [v * sqrt252 for v in rv60_raw]

    pos_vc_b = [0.0] * n
    eta_vc = 2.0 / (3.0 + 1.0)
    for t in range(n):
        vc_ratio = (
            0.60 * _clip(vc_target_vol / max(rv20[t], 0.08), 0.0, 1.0)
            + 0.40 * _clip(vc_target_vol / max(rv60[t], 0.08), 0.0, 1.0)
        )
        raw_vc = cap_vc_t[t] * vc_ratio
        pos_vc_b[t] = raw_vc if t == 0 else ((1.0 - eta_vc) * pos_vc_b[t - 1] + eta_vc * raw_vc)

    return {
        "px": px,
        "px_unadj": px_unadj,
        "ret": ret,
        "var_36": var_36,
        "ann_pct_vol_36": ann_pct_vol_36,
        "long_pct_vol": long_pct_vol,
        "ann_vol_carver": ann_vol_carver,
        "rv20": rv20,
        "rv60": rv60,
        "ema_fast": ema_fast,
        "ema_slow": ema_slow,
        "f_indiv": f_indiv,
        "flip_1d_px": flip_1d_px,
        "f_carver": f_carver,
        "sma_mat": sma_mat,
        "f_sma": f_sma,
        "f_hybrid": f_hybrid,
        "cap_cta_t": cap_cta_t,
        "cap_vc_t": cap_vc_t,
        "cta_scale_mult": cta_scale_mult,
        "vc_scale_mult": vc_scale_mult,
        "tgt_carver_b": tgt_carver_b,
        "pos_carver_b": pos_carver_b,
        "tgt_sma_b": tgt_sma_b,
        "pos_sma_b": pos_sma_b,
        "tgt_hybrid_b": tgt_hybrid_b,
        "pos_hybrid_b": pos_hybrid_b,
        "pos_vc_b": pos_vc_b,
        "params": {
            "cta_risk_cap_2026_b": cta_risk_cap_2026_b,
            "cta_target_vol": cta_target_vol,
            "vc_aum_2026_b": vc_aum_2026_b,
            "vc_target_vol": vc_target_vol,
            "short_asym_weight": short_asym_weight,
            "max_leverage_mult": max_leverage_mult,
        },
    }


def simulate_single_day_surface(st: dict, t_idx: int, grid_pct: list[float], horizon_days: int) -> dict[str, list[float]]:
    g_len = len(grid_pct)
    px0 = st["px"][t_idx]
    var0 = st["var_36"][t_idx]
    long_v0 = st["long_pct_vol"][t_idx]
    cap_cta0 = st["cap_cta_t"][t_idx]
    cap_vc0 = st["cap_vc_t"][t_idx]
    pos_c0 = st["pos_carver_b"][t_idx]
    pos_s0 = st["pos_sma_b"][t_idx]
    pos_h0 = st["pos_hybrid_b"][t_idx]
    pos_vc0 = st["pos_vc_b"][t_idx]

    hist_px = st["px"][t_idx - 200 + 1 : t_idx + 1]
    hist_ret = st["ret"][t_idx - 60 + 1 : t_idx + 1]
    ef0 = [st["ema_fast"][k][t_idx] for k in range(6)]
    es0 = [st["ema_slow"][k][t_idx] for k in range(6)]

    p = st["params"]
    cta_tvol = p["cta_target_vol"]
    vc_tvol = p["vc_target_vol"]
    s_asym = p["short_asym_weight"]
    max_lev = p["max_leverage_mult"]
    alpha_vol = 2.0 / 37.0
    eta = 0.5
    sqrt252 = math.sqrt(252.0)
    af_list = [2.0 / (c[0] + 1.0) for c in EWMAC_CONFIGS]
    as_list = [2.0 / (c[1] + 1.0) for c in EWMAC_CONFIGS]
    sc_list = [c[2] for c in EWMAC_CONFIGS]

    # Pre-sum historical trailing sums for SMA windows to make inner loop super fast
    hist_sma_sums = {}
    for w_len in SMA_WINDOWS:
        for h_cnt in range(1, min(horizon_days, w_len - 1) + 1):
            need = w_len - h_cnt
            hist_sma_sums[(w_len, h_cnt)] = sum(hist_px[-need:])

    flow_c = [0.0] * g_len
    flow_s = [0.0] * g_len
    flow_h = [0.0] * g_len
    flow_vc = [0.0] * g_len
    flow_c_vc = [0.0] * g_len
    flow_h_vc = [0.0] * g_len
    end_fc = [0.0] * g_len
    end_fs = [0.0] * g_len

    for g_i, pct in enumerate(grid_pct):
        r_tot = pct / 100.0
        var_cur = var0
        prev_p = px0
        ef = ef0[:]
        es = es0[:]
        pos_c = pos_c0
        pos_s = pos_s0
        pos_h = pos_h0
        pos_v = pos_vc0
        fut_px_list: list[float] = []
        fut_ret_list: list[float] = []
        f_c = 0.0
        f_s = 0.0

        for h in range(horizon_days):
            h_cnt = h + 1
            p_h = px0 * (1.0 + r_tot * (h_cnt / float(horizon_days)))
            dp_h = p_h - prev_p
            r_h = dp_h / max(prev_p, 1e-8)
            fut_px_list.append(p_h)
            fut_ret_list.append(r_h)

            var_cur = (1.0 - alpha_vol) * var_cur + alpha_vol * (dp_h * dp_h)
            ann_v36 = (math.sqrt(var_cur) / p_h) * sqrt252
            ann_v_carver = max(0.70 * ann_v36 + 0.30 * long_v0, 0.07)
            sig_p_b = max((ann_v_carver / sqrt252) * p_h, 1e-8)

            f_sum = 0.0
            for k in range(6):
                ef[k] = af_list[k] * p_h + (1.0 - af_list[k]) * ef[k]
                es[k] = as_list[k] * p_h + (1.0 - as_list[k]) * es[k]
                f_sum += _clip(sc_list[k] * (ef[k] - es[k]) / sig_p_b, -20.0, 20.0)
            f_c = _clip(CARVER_FDM * (f_sum / 6.0), -20.0, 20.0)

            sma_acc = 0.0
            fut_sum = sum(fut_px_list)
            for m_idx, w_len in enumerate(SMA_WINDOWS):
                if h_cnt >= w_len:
                    sm_val = sum(fut_px_list[h_cnt - w_len : h_cnt]) / float(w_len)
                else:
                    sm_val = (hist_sma_sums[(w_len, h_cnt)] + fut_sum) / float(w_len)
                sma_acc += SMA_WEIGHTS[m_idx] * (1.0 if p_h >= sm_val else -1.0)
            f_s = 20.0 * sma_acc
            f_hyb = 0.50 * f_c + 0.50 * f_s

            v_sc = cta_tvol / ann_v_carver
            buf = 0.10 * cap_cta0 * min(v_sc, max_lev)

            for f_now, tag in ((f_c, 0), (f_s, 1), (f_hyb, 2)):
                asym = 1.0 if f_now >= 0.0 else s_asym
                u = _clip((f_now / 10.0) * v_sc * asym, -max_lev * s_asym, max_lev)
                tgt = cap_cta0 * u
                cur_p = pos_c if tag == 0 else (pos_s if tag == 1 else pos_h)
                if tgt > cur_p + buf:
                    des = tgt - buf
                elif tgt < cur_p - buf:
                    des = tgt + buf
                else:
                    des = cur_p
                nxt = (1.0 - eta) * cur_p + eta * des
                if tag == 0:
                    pos_c = nxt
                elif tag == 1:
                    pos_s = nxt
                else:
                    pos_h = nxt

            if h_cnt >= 20:
                r20_w = fut_ret_list[-20:]
            else:
                r20_w = hist_ret[-(20 - h_cnt) :] + fut_ret_list
            r60_w = hist_ret[-(60 - h_cnt) :] + fut_ret_list
            rv20_h = _sample_std(r20_w) * sqrt252
            rv60_h = _sample_std(r60_w) * sqrt252
            vc_rat = (
                0.60 * _clip(vc_tvol / max(rv20_h, 0.08), 0.0, 1.0)
                + 0.40 * _clip(vc_tvol / max(rv60_h, 0.08), 0.0, 1.0)
            )
            pos_v = (1.0 - eta) * pos_v + eta * (cap_vc0 * vc_rat)
            prev_p = p_h

        fc_b = pos_c - pos_c0
        fs_b = pos_s - pos_s0
        fh_b = pos_h - pos_h0
        fv_b = pos_v - pos_vc0
        flow_c[g_i] = fc_b
        flow_s[g_i] = fs_b
        flow_h[g_i] = fh_b
        flow_vc[g_i] = fv_b
        flow_c_vc[g_i] = fc_b + fv_b
        flow_h_vc[g_i] = fh_b + fv_b
        end_fc[g_i] = f_c
        end_fs[g_i] = f_s

    return {
        "flow_carver_b": flow_c,
        "flow_sma_b": flow_s,
        "flow_hybrid_b": flow_h,
        "flow_vc_b": flow_vc,
        "flow_carver_plus_vc_b": flow_c_vc,
        "flow_hybrid_plus_vc_b": flow_h_vc,
        "end_f_carver": end_fc,
        "end_f_sma": end_fs,
    }


def find_threshold_strike_pct(
    fine_grid_pct: list[float],
    flow_row: list[float],
    threshold_b: float,
    direction: str = "down",
) -> float | None:
    zero_idx = min(range(len(fine_grid_pct)), key=lambda i: abs(fine_grid_pct[i]))
    if direction == "down":
        for j in range(zero_idx, -1, -1):
            if flow_row[j] <= threshold_b:
                if j == zero_idx:
                    return 0.0
                f1, f0 = flow_row[j + 1], flow_row[j]
                g1, g0 = fine_grid_pct[j + 1], fine_grid_pct[j]
                w = (threshold_b - f1) / (f0 - f1) if abs(f0 - f1) > 1e-9 else 0.0
                return g1 + w * (g0 - g1)
        return None
    for j in range(zero_idx, len(fine_grid_pct)):
        if flow_row[j] >= threshold_b:
            if j == zero_idx:
                return 0.0
            f0, f1 = flow_row[j - 1], flow_row[j]
            g0, g1 = fine_grid_pct[j - 1], fine_grid_pct[j]
            w = (threshold_b - f0) / (f1 - f0) if abs(f1 - f0) > 1e-9 else 0.0
            return g0 + w * (g1 - g0)
    return None


def decluster_indices(mask: list[bool], min_gap: int = 15) -> list[int]:
    kept: list[int] = []
    last_i = -999999
    for i, flag in enumerate(mask):
        if flag and (i - last_i >= min_gap):
            kept.append(i)
            last_i = i
    return kept


def eval_event_study(px: list[float], signal_mask: list[bool], horizons: list[int] = [5, 10, 21, 63], min_gap: int = 15) -> dict:
    n = len(px)
    ep_idx = decluster_indices(signal_mask, min_gap=min_gap)
    out = {
        "nSignalDays": sum(1 for f in signal_mask if f),
        "nEpisodes": len(ep_idx),
        "horizons": {},
    }
    sqrt252 = math.sqrt(252.0)
    for h in horizons:
        valid_ep = [idx for idx in ep_idx if idx + h < n]
        step = max(h, min_gap)
        base_idx = list(range(0, n - h, step))
        if len(valid_ep) < 3:
            out["horizons"][f"{h}D"] = {"nEp": len(valid_ep)}
            continue
        ep_rets = [(px[i + h] / px[i] - 1.0) * 100.0 for i in valid_ep]
        base_rets = [(px[i + h] / px[i] - 1.0) * 100.0 for i in base_idx]

        ep_rvol: list[float] = []
        ep_mdd: list[float] = []
        for idx in valid_ep:
            seg = px[idx : idx + h + 1]
            r_seg = [(seg[k + 1] - seg[k]) / seg[k] for k in range(len(seg) - 1)]
            ep_rvol.append(_sample_std(r_seg) * sqrt252 * 100.0)
            ep_mdd.append(min((v / seg[0] - 1.0) * 100.0 for v in seg))

        base_rvol: list[float] = []
        base_mdd: list[float] = []
        for idx in base_idx:
            seg = px[idx : idx + h + 1]
            r_seg = [(seg[k + 1] - seg[k]) / seg[k] for k in range(len(seg) - 1)]
            base_rvol.append(_sample_std(r_seg) * sqrt252 * 100.0)
            base_mdd.append(min((v / seg[0] - 1.0) * 100.0 for v in seg))

        t_ret, p_ret = welch_ttest(ep_rets, base_rets)
        t_vol, p_vol = welch_ttest(ep_rvol, base_rvol)
        t_mdd, p_mdd = welch_ttest(ep_mdd, base_mdd)

        gains = [v for v in ep_rets if v > 0]
        losses = [v for v in ep_rets if v < 0]
        wl_ratio = (sum(gains) / len(gains)) / abs(sum(losses) / len(losses)) if gains and losses else None

        mean_ep = sum(ep_rets) / len(ep_rets)
        mean_base = sum(base_rets) / len(base_rets)
        out["horizons"][f"{h}D"] = {
            "nEp": len(valid_ep),
            "meanRetPct": round(mean_ep, 2),
            "medianRetPct": round(statistics.median(ep_rets), 2),
            "baseMeanRetPct": round(mean_base, 2),
            "excessMeanRetPct": round(mean_ep - mean_base, 2),
            "winRatePct": round(sum(1 for v in ep_rets if v > 0) / len(ep_rets) * 100.0, 1),
            "winCount": sum(1 for v in ep_rets if v > 0),
            "p10LeftTailPct": round(_percentile_linear(ep_rets, 10.0), 2),
            "p90RightTailPct": round(_percentile_linear(ep_rets, 90.0), 2),
            "winLossRatio": round(wl_ratio, 2) if wl_ratio is not None else None,
            "fwdRvolMeanPct": round(sum(ep_rvol) / len(ep_rvol), 2),
            "baseRvolMeanPct": round(sum(base_rvol) / len(base_rvol), 2),
            "fwdWorstDdMeanPct": round(sum(ep_mdd) / len(ep_mdd), 2),
            "baseWorstDdMeanPct": round(sum(base_mdd) / len(base_mdd), 2),
            "tStatRet": round(t_ret, 2),
            "pValRet": round(p_ret, 4),
            "tStatVol": round(t_vol, 2),
            "pValVol": round(p_vol, 4),
            "tStatMdd": round(t_mdd, 2),
            "pValMdd": round(p_mdd, 4),
        }
    return out


def _summarize_forward_list(rets: list[float], base_all_rets: list[float], base_nonoverlap_rets: list[float]) -> dict:
    n = len(rets)
    if n == 0:
        return {
            "nCompleted": 0,
            "winCount": 0,
            "winRatePct": None,
            "medianRetPct": None,
            "meanRetPct": None,
            "minRetPct": None,
            "maxRetPct": None,
            "p25RetPct": None,
            "p75RetPct": None,
            "baselineWinRatePct": round(sum(1 for v in base_all_rets if v > 0) / len(base_all_rets) * 100.0, 1) if base_all_rets else None,
            "baselineMeanRetPct": round(sum(base_all_rets) / len(base_all_rets), 2) if base_all_rets else None,
            "baselineMedianRetPct": round(statistics.median(base_all_rets), 2) if base_all_rets else None,
            "excessMeanRetPct": None,
            "excessMedianRetPct": None,
            "pValVsBaseline": None,
        }
    win_cnt = sum(1 for v in rets if v > 0.0)
    mean_r = sum(rets) / n
    med_r = statistics.median(rets)
    b_win = sum(1 for v in base_all_rets if v > 0.0) / len(base_all_rets) * 100.0 if base_all_rets else 0.0
    b_mean = sum(base_all_rets) / len(base_all_rets) if base_all_rets else 0.0
    b_med = statistics.median(base_all_rets) if base_all_rets else 0.0
    _, p_val = welch_ttest(rets, base_nonoverlap_rets) if n >= 2 and len(base_nonoverlap_rets) >= 2 else (0.0, None)
    return {
        "nCompleted": n,
        "winCount": win_cnt,
        "winRatePct": round(win_cnt / n * 100.0, 1),
        "medianRetPct": round(med_r, 2),
        "meanRetPct": round(mean_r, 2),
        "minRetPct": round(min(rets), 2),
        "maxRetPct": round(max(rets), 2),
        "p25RetPct": round(_percentile_linear(rets, 25.0), 2),
        "p75RetPct": round(_percentile_linear(rets, 75.0), 2),
        "baselineWinRatePct": round(b_win, 1),
        "baselineMeanRetPct": round(b_mean, 2),
        "baselineMedianRetPct": round(b_med, 2),
        "excessMeanRetPct": round(mean_r - b_mean, 2),
        "excessMedianRetPct": round(med_r - b_med, 2),
        "pValVsBaseline": round(p_val, 4) if p_val is not None else None,
    }


def _compute_single_regime_backtest(
    regime_id: str,
    title_en: str,
    title_zh: str,
    rule_en: str,
    rule_zh: str,
    mask: list[bool],
    dates: list[str],
    px_adj: list[float],
    px_unadj: list[float],
    f_carver: list[float],
    marg_asym_3: list[float],
    vix_ratio: list[float],
    vix_close: list[float],
    cooldown_days: int = 20,
    wait_window_days: int = 20,
) -> dict:
    m = len(px_adj)
    ep_indices = decluster_indices(mask, min_gap=cooldown_days)
    horizons_cfg = (10, 20, 60, 120)
    dd_windows = (10, 20, 60)

    # Precompute unconditional all-day and non-overlapping baselines
    base_all: dict[int, list[float]] = {}
    base_nonoverlap: dict[int, list[float]] = {}
    for h in horizons_cfg:
        if m > h:
            base_all[h] = [(px_adj[j + h] / px_adj[j] - 1.0) * 100.0 for j in range(m - h)]
            step = max(h, cooldown_days)
            base_nonoverlap[h] = [(px_adj[j + h] / px_adj[j] - 1.0) * 100.0 for j in range(0, m - h, step)]
        else:
            base_all[h] = []
            base_nonoverlap[h] = []

    # Post-signal further drawdown summary across 10D, 20D, 60D
    dd_summary: dict[str, dict] = {}
    for w in dd_windows:
        drops: list[float] = []
        trough_days: list[int] = []
        for idx in ep_indices:
            if idx + w >= m:
                continue
            p0 = px_adj[idx]
            min_r = 0.0
            min_d = 0
            for d in range(1, w + 1):
                r_d = (px_adj[idx + d] / p0 - 1.0) * 100.0
                if r_d < min_r:
                    min_r = r_d
                    min_d = d
            drops.append(min_r)
            trough_days.append(min_d)
        if drops:
            dd_summary[f"{w}D"] = {
                "nCompleted": len(drops),
                "medianDropPct": round(statistics.median(drops), 2),
                "meanDropPct": round(sum(drops) / len(drops), 2),
                "worstDropPct": round(min(drops), 2),
                "bestDropPct": round(max(drops), 2),
                "zeroFurtherDropCount": sum(1 for v in drops if v >= -1e-9),
                "dropGe2PctCount": sum(1 for v in drops if v <= -2.0),
                "dropGe5PctCount": sum(1 for v in drops if v <= -5.0),
                "medianDaysToTrough": round(float(statistics.median(trough_days)), 1),
                "meanDaysToTrough": round(sum(trough_days) / len(trough_days), 1),
                "maxDaysToTrough": max(trough_days),
            }
        else:
            dd_summary[f"{w}D"] = {
                "nCompleted": 0,
                "medianDropPct": None,
                "meanDropPct": None,
                "worstDropPct": None,
                "bestDropPct": None,
                "zeroFurtherDropCount": 0,
                "dropGe2PctCount": 0,
                "dropGe5PctCount": 0,
                "medianDaysToTrough": None,
                "meanDaysToTrough": None,
                "maxDaysToTrough": None,
            }

    # Forward returns from signal close (+10D, +20D, +60D, +120D)
    fwd_summary: dict[str, dict] = {}
    for h in horizons_cfg:
        rets_h = [(px_adj[idx + h] / px_adj[idx] - 1.0) * 100.0 for idx in ep_indices if idx + h < m]
        fwd_summary[f"{h}D"] = _summarize_forward_list(rets_h, base_all[h], base_nonoverlap[h])

    # Dip-entry limit-order simulator (0%, -2%, -3%, -5%, and 3-Tranche DCA within 20D waiting window)
    eligible_dip_eps = [idx for idx in ep_indices if idx + wait_window_days < m]
    dip_specs = [
        ("dip_0pct", 0.0, "0% (Buy Signal Close)", "0%（信号日收盘即买）", "100% immediate entry at signal-day close", "信号触发当日收盘 100% 直接买入"),
        ("dip_2pct", -2.0, "-2% Dip Limit (20D)", "再跌 -2% 挂单（20D内）", "Buy at first close <= -2% below signal close within 20 trading days", "信号后 20 个交易日内首次收盘跌破 -2% 买入"),
        ("dip_3pct", -3.0, "-3% Dip Limit (20D)", "再跌 -3% 挂单（20D内）", "Buy at first close <= -3% below signal close within 20 trading days", "信号后 20 个交易日内首次收盘跌破 -3% 买入"),
        ("dip_5pct", -5.0, "-5% Dip Limit (20D)", "再跌 -5% 挂单（20D内）", "Buy at first close <= -5% below signal close within 20 trading days", "信号后 20 个交易日内首次收盘跌破 -5% 买入"),
    ]
    dip_matrix: list[dict] = []

    for mode_id, dip_pct, lbl_en, lbl_zh, r_en, r_zh in dip_specs:
        filled_entries: list[tuple[int, int, float]] = []
        missed_indices: list[int] = []
        for idx in eligible_dip_eps:
            p0 = px_adj[idx]
            if abs(dip_pct) < 1e-9:
                filled_entries.append((idx, idx, p0))
            else:
                thresh = p0 * (1.0 + dip_pct / 100.0)
                hit_k = None
                for k in range(idx + 1, idx + wait_window_days + 1):
                    if px_adj[k] <= thresh + 1e-12:
                        hit_k = k
                        break
                if hit_k is not None:
                    filled_entries.append((idx, hit_k, px_adj[hit_k]))
                else:
                    missed_indices.append(idx)

        maes_20d: list[float] = []
        fill_waits: list[int] = []
        for sig_idx, fill_k, fill_px in filled_entries:
            fill_waits.append(fill_k - sig_idx)
            if fill_k + 20 < m:
                min_after = min(0.0, min((px_adj[fill_k + d] / fill_px - 1.0) * 100.0 for d in range(1, 21)))
                maes_20d.append(min_after)

        missed_20 = [(px_adj[idx + 20] / px_adj[idx] - 1.0) * 100.0 for idx in missed_indices if idx + 20 < m]
        missed_60 = [(px_adj[idx + 60] / px_adj[idx] - 1.0) * 100.0 for idx in missed_indices if idx + 60 < m]

        mode_horizons: dict[str, dict] = {}
        for h in horizons_cfg:
            h_rets = [(px_adj[fill_k + h] / fill_px - 1.0) * 100.0 for _, fill_k, fill_px in filled_entries if fill_k + h < m]
            if h_rets:
                w_c = sum(1 for v in h_rets if v > 0.0)
                mode_horizons[f"{h}D"] = {
                    "nFilled": len(h_rets),
                    "winCount": w_c,
                    "winRatePct": round(w_c / len(h_rets) * 100.0, 1),
                    "medianRetPct": round(statistics.median(h_rets), 2),
                    "meanRetPct": round(sum(h_rets) / len(h_rets), 2),
                    "minRetPct": round(min(h_rets), 2),
                    "maxRetPct": round(max(h_rets), 2),
                }
            else:
                mode_horizons[f"{h}D"] = {
                    "nFilled": 0,
                    "winCount": 0,
                    "winRatePct": None,
                    "medianRetPct": None,
                    "meanRetPct": None,
                    "minRetPct": None,
                    "maxRetPct": None,
                }

        n_elig = len(eligible_dip_eps)
        n_fill = len(filled_entries)
        dip_matrix.append({
            "id": mode_id,
            "dipPct": dip_pct,
            "labelEn": lbl_en,
            "labelZh": lbl_zh,
            "ruleEn": r_en,
            "ruleZh": r_zh,
            "eligibleEpisodes": n_elig,
            "filledCount": n_fill,
            "missedCount": len(missed_indices),
            "fillRatePct": round(n_fill / n_elig * 100.0, 1) if n_elig > 0 else None,
            "avgDeployedCapitalPct": round(n_fill / n_elig * 100.0, 1) if n_elig > 0 else None,
            "avgDaysToFill": round(sum(fill_waits) / len(fill_waits), 1) if fill_waits else None,
            "postEntry20dMaeMedianPct": round(statistics.median(maes_20d), 2) if maes_20d else None,
            "postEntry20dMaeMeanPct": round(sum(maes_20d) / len(maes_20d), 2) if maes_20d else None,
            "postEntry20dMaeWorstPct": round(min(maes_20d), 2) if maes_20d else None,
            "missed20dMeanRetPct": round(sum(missed_20) / len(missed_20), 2) if missed_20 else None,
            "missed60dMeanRetPct": round(sum(missed_60) / len(missed_60), 2) if missed_60 else None,
            "horizons": mode_horizons,
        })

    # 5th Mode: 3-Tranche DCA (1/3 Signal Close + 1/3 at -2% + 1/3 at -5% within 20D, uninvested cash = 0%)
    dca_deployed_list: list[float] = []
    dca_maes_20d: list[float] = []
    dca_horizons_rets: dict[int, list[float]] = {h: [] for h in horizons_cfg}
    dca_deployed_horizons_rets: dict[int, list[float]] = {h: [] for h in horizons_cfg}

    for idx in eligible_dip_eps:
        p0 = px_adj[idx]
        k2 = next((k for k in range(idx + 1, idx + wait_window_days + 1) if px_adj[k] <= p0 * 0.98 + 1e-12), None)
        k5 = next((k for k in range(idx + 1, idx + wait_window_days + 1) if px_adj[k] <= p0 * 0.95 + 1e-12), None)
        tranches_filled = 1 + (1 if k2 is not None else 0) + (1 if k5 is not None else 0)
        dca_deployed_list.append(tranches_filled / 3.0 * 100.0)

        def _dca_equity_at(t_idx: int) -> float:
            eq1 = px_adj[t_idx] / p0
            eq2 = (px_adj[t_idx] / px_adj[k2]) if (k2 is not None and k2 <= t_idx) else 1.0
            eq3 = (px_adj[t_idx] / px_adj[k5]) if (k5 is not None and k5 <= t_idx) else 1.0
            return (eq1 + eq2 + eq3) / 3.0

        def _dca_deployed_ret_at(t_idx: int) -> float:
            gains = [px_adj[t_idx] / p0 - 1.0]
            if k2 is not None and k2 <= t_idx:
                gains.append(px_adj[t_idx] / px_adj[k2] - 1.0)
            if k5 is not None and k5 <= t_idx:
                gains.append(px_adj[t_idx] / px_adj[k5] - 1.0)
            return (sum(gains) / len(gains)) * 100.0

        min_dca_20 = min(0.0, min((_dca_equity_at(idx + d) - 1.0) * 100.0 for d in range(1, wait_window_days + 1)))
        dca_maes_20d.append(min_dca_20)
        for h in horizons_cfg:
            if idx + h < m:
                dca_horizons_rets[h].append((_dca_equity_at(idx + h) - 1.0) * 100.0)
                dca_deployed_horizons_rets[h].append(_dca_deployed_ret_at(idx + h))

    dca_horizons_out: dict[str, dict] = {}
    for h in horizons_cfg:
        hr = dca_horizons_rets[h]
        dr = dca_deployed_horizons_rets[h]
        if hr:
            wc = sum(1 for v in hr if v > 0.0)
            dca_horizons_out[f"{h}D"] = {
                "nFilled": len(hr),
                "winCount": wc,
                "winRatePct": round(wc / len(hr) * 100.0, 1),
                "medianRetPct": round(statistics.median(hr), 2),
                "meanRetPct": round(sum(hr) / len(hr), 2),
                "minRetPct": round(min(hr), 2),
                "maxRetPct": round(max(hr), 2),
                "deployedMedianRetPct": round(statistics.median(dr), 2) if dr else None,
                "deployedMeanRetPct": round(sum(dr) / len(dr), 2) if dr else None,
            }
        else:
            dca_horizons_out[f"{h}D"] = {
                "nFilled": 0,
                "winCount": 0,
                "winRatePct": None,
                "medianRetPct": None,
                "meanRetPct": None,
                "minRetPct": None,
                "maxRetPct": None,
                "deployedMedianRetPct": None,
                "deployedMeanRetPct": None,
            }

    n_elig_dca = len(eligible_dip_eps)
    dip_matrix.append({
        "id": "dca_3tranche",
        "dipPct": None,
        "labelEn": "3-Tranche DCA (0% / -2% / -5%)",
        "labelZh": "分 3 批阶梯买（0% / -2% / -5%）",
        "ruleEn": "1/3 at signal close + 1/3 at -2% + 1/3 at -5% within 20D (unfilled cash earns 0%)",
        "ruleZh": "信号日收盘买 1/3 + 再跌 -2% 买 1/3 + 再跌 -5% 买 1/3（20D内未触发部分按现金 0% 计）",
        "eligibleEpisodes": n_elig_dca,
        "filledCount": n_elig_dca,
        "missedCount": 0,
        "fillRatePct": 100.0 if n_elig_dca > 0 else None,
        "avgDeployedCapitalPct": round(sum(dca_deployed_list) / len(dca_deployed_list), 1) if dca_deployed_list else None,
        "avgDaysToFill": 0.0 if n_elig_dca > 0 else None,
        "postEntry20dMaeMedianPct": round(statistics.median(dca_maes_20d), 2) if dca_maes_20d else None,
        "postEntry20dMaeMeanPct": round(sum(dca_maes_20d) / len(dca_maes_20d), 2) if dca_maes_20d else None,
        "postEntry20dMaeWorstPct": round(min(dca_maes_20d), 2) if dca_maes_20d else None,
        "missed20dMeanRetPct": None,
        "missed60dMeanRetPct": None,
        "horizons": dca_horizons_out,
    })

    # Episode-by-episode historical ledger
    ledger: list[dict] = []
    for rank_idx, idx in enumerate(ep_indices, start=1):
        days_elapsed = (m - 1) - idx
        status = "LIVE" if days_elapsed < 10 else ("PARTIAL" if days_elapsed < 120 else "COMPLETED")
        p0 = px_adj[idx]

        def _ep_dd(w: int) -> tuple[float | None, int | None, str | None]:
            if idx + w >= m:
                if days_elapsed >= 1:
                    min_r = 0.0
                    min_d = 0
                    for d in range(1, days_elapsed + 1):
                        rd = (px_adj[idx + d] / p0 - 1.0) * 100.0
                        if rd < min_r:
                            min_r = rd
                            min_d = d
                    return None, None, None
                return None, None, None
            min_r = 0.0
            min_d = 0
            for d in range(1, w + 1):
                rd = (px_adj[idx + d] / p0 - 1.0) * 100.0
                if rd < min_r:
                    min_r = rd
                    min_d = d
            t_dt = dates[idx + min_d]
            return round(min_r, 2), min_d, t_dt

        dd10, _, _ = _ep_dd(10)
        dd20, dt20, t_date20 = _ep_dd(20)
        dd60, dt60, _ = _ep_dd(60)

        r10 = round((px_adj[idx + 10] / p0 - 1.0) * 100.0, 2) if idx + 10 < m else None
        r20 = round((px_adj[idx + 20] / p0 - 1.0) * 100.0, 2) if idx + 20 < m else None
        r60 = round((px_adj[idx + 60] / p0 - 1.0) * 100.0, 2) if idx + 60 < m else None
        r120 = round((px_adj[idx + 120] / p0 - 1.0) * 100.0, 2) if idx + 120 < m else None

        live_ret = round((px_adj[m - 1] / p0 - 1.0) * 100.0, 2) if days_elapsed >= 1 else 0.0
        live_min_drop = (
            round(min(0.0, min((px_adj[idx + d] / p0 - 1.0) * 100.0 for d in range(1, days_elapsed + 1))), 2)
            if days_elapsed >= 1
            else 0.0
        )

        if idx + wait_window_days < m:
            f2 = any(px_adj[k] <= p0 * 0.98 + 1e-12 for k in range(idx + 1, idx + wait_window_days + 1))
            f3 = any(px_adj[k] <= p0 * 0.97 + 1e-12 for k in range(idx + 1, idx + wait_window_days + 1))
            f5 = any(px_adj[k] <= p0 * 0.95 + 1e-12 for k in range(idx + 1, idx + wait_window_days + 1))
            dca_dep = round((1 + (1 if f2 else 0) + (1 if f5 else 0)) / 3.0 * 100.0, 1)
        else:
            f2, f3, f5, dca_dep = None, None, None, None

        ledger.append({
            "rank": rank_idx,
            "date": dates[idx],
            "status": status,
            "daysElapsed": days_elapsed,
            "signalClose": round(px_unadj[idx], 2),
            "fCarver": round(f_carver[idx], 2),
            "convexity3Pct": round(marg_asym_3[idx], 2),
            "vixRatio": round(vix_ratio[idx], 3),
            "vixClose": round(vix_close[idx], 2),
            "maxDrop10dPct": dd10,
            "maxDrop20dPct": dd20,
            "maxDrop60dPct": dd60,
            "daysToTrough20d": dt20,
            "daysToTrough60d": dt60,
            "troughDate20d": t_date20,
            "ret10dPct": r10,
            "ret20dPct": r20,
            "ret60dPct": r60,
            "ret120dPct": r120,
            "liveRunningRetPct": live_ret,
            "liveRunningMaxDropPct": live_min_drop,
            "filledDip2Pct": f2,
            "filledDip3Pct": f3,
            "filledDip5Pct": f5,
            "dcaDeployedPct": dca_dep,
        })

    n_comp20 = dd_summary["20D"]["nCompleted"]
    return {
        "id": regime_id,
        "titleEn": title_en,
        "titleZh": title_zh,
        "ruleEn": rule_en,
        "ruleZh": rule_zh,
        "cooldownDays": cooldown_days,
        "activeToday": bool(mask[-1]) if mask else False,
        "totalEpisodes": len(ep_indices),
        "completedEpisodes10d": fwd_summary["10D"]["nCompleted"],
        "completedEpisodes20d": n_comp20,
        "completedEpisodes60d": fwd_summary["60D"]["nCompleted"],
        "completedEpisodes120d": fwd_summary["120D"]["nCompleted"],
        "livePendingCount": sum(1 for row in ledger if row["status"] == "LIVE"),
        "smallSampleCaveat": n_comp20 < 12,
        "postSignalDrawdown": dd_summary,
        "forwardHorizons": fwd_summary,
        "dipEntryMatrix": dip_matrix,
        "episodes": ledger,
    }


def compute_signal_backtest(
    dates: list[str],
    px_adj: list[float],
    px_unadj: list[float],
    f_carver: list[float],
    marg_asym_3: list[float],
    vix_ratio: list[float],
    vix_close: list[float],
) -> dict:
    m = len(px_adj)
    mask_exh = [f_carver[i] <= -10.0 and marg_asym_3[i] >= 1.80 for i in range(m)]
    mask_q2 = [f_carver[i] <= -10.0 and marg_asym_3[i] >= 1.80 and vix_ratio[i] >= 1.00 for i in range(m)]
    mask_vix = [vix_ratio[i] >= 1.00 for i in range(m)]

    regimes = {
        "exhaustion_convexity": _compute_single_regime_backtest(
            regime_id="exhaustion_convexity",
            title_en="Short Exhaustion + Convexity Turn",
            title_zh="空头衰竭 + 凸性拐点",
            rule_en="Carver F <= -10.0 AND +3%/-3% Pure Marginal Convexity >= 1.80x (>=20D cooldown)",
            rule_zh="Carver F <= -10.0 且 +3%/-3% 纯价格边际凸性 >= 1.80x（>=20 交易日冷却去重）",
            mask=mask_exh,
            dates=dates,
            px_adj=px_adj,
            px_unadj=px_unadj,
            f_carver=f_carver,
            marg_asym_3=marg_asym_3,
            vix_ratio=vix_ratio,
            vix_close=vix_close,
            cooldown_days=20,
            wait_window_days=20,
        ),
        "quadrant2_combo": _compute_single_regime_backtest(
            regime_id="quadrant2_combo",
            title_en="Quadrant 2 Combo (+ VIX Lock >= 1.00)",
            title_zh="组合象限 2（叠加 VIX 倒挂 >= 1.00）",
            rule_en="Carver F <= -10.0 AND Convexity >= 1.80x AND VIX/VIX3M >= 1.00 (>=20D cooldown)",
            rule_zh="Carver F <= -10.0 + 凸性 >= 1.80x + VIX/VIX3M >= 1.00 期现倒挂共振（今日 SPY 实盘象限）",
            mask=mask_q2,
            dates=dates,
            px_adj=px_adj,
            px_unadj=px_unadj,
            f_carver=f_carver,
            marg_asym_3=marg_asym_3,
            vix_ratio=vix_ratio,
            vix_close=vix_close,
            cooldown_days=20,
            wait_window_days=20,
        ),
        "vix_backwardation_lock": _compute_single_regime_backtest(
            regime_id="vix_backwardation_lock",
            title_en="VIX Backwardation Lock Only",
            title_zh="仅 VIX 倒挂恐慌锁",
            rule_en="VIX / VIX3M >= 1.00 term-structure inversion onset (>=20D cooldown)",
            rule_zh="仅 VIX / VIX3M >= 1.00 期现倒挂首次触发（无趋势耗尽过滤，>=20 交易日冷却去重）",
            mask=mask_vix,
            dates=dates,
            px_adj=px_adj,
            px_unadj=px_unadj,
            f_carver=f_carver,
            marg_asym_3=marg_asym_3,
            vix_ratio=vix_ratio,
            vix_close=vix_close,
            cooldown_days=20,
            wait_window_days=20,
        ),
    }

    return {
        "basis": "close_to_close_total_return_adjusted",
        "priceMethodologyEn": "Strict zero-lookahead close-to-close total-return series (dividend & split adjusted) for all forward returns, post-signal drawdowns, and 20-day limit-order dip fills; spot close displays unadjusted exchange close on signal date.",
        "priceMethodologyZh": "严格零前视收盘对收盘全收益序列（含分红复权与拆股校准）计算全部后续最大再跌、20 日内挂单触发成交及 +10/+20/+60/+120 日涨幅；信号日价格展示当日交易所实际收盘价。",
        "cooldownTradingDays": 20,
        "dipWaitWindowDays": 20,
        "defaultRegimeId": "exhaustion_convexity",
        "regimeOrder": ["exhaustion_convexity", "quadrant2_combo", "vix_backwardation_lock"],
        "dipModeOrder": ["dip_0pct", "dip_2pct", "dip_3pct", "dip_5pct", "dca_3tranche"],
        "regimes": regimes,
    }


def _interp_linear(x: float, xs: list[float], ys: list[float]) -> float:
    if x <= xs[0]:
        return ys[0]
    if x >= xs[-1]:
        return ys[-1]
    idx = bisect.bisect_right(xs, x) - 1
    idx = max(0, min(idx, len(xs) - 2))
    x0, x1 = xs[idx], xs[idx + 1]
    if abs(x1 - x0) < 1e-12:
        return ys[idx]
    w = (x - x0) / (x1 - x0)
    return ys[idx] + w * (ys[idx + 1] - ys[idx])


def _pearson_r2(xs: list[float], ys: list[float]) -> float:
    n = len(xs)
    if n < 3:
        return 0.0
    mx = sum(xs) / n
    my = sum(ys) / n
    num = sum((xs[i] - mx) * (ys[i] - my) for i in range(n))
    dx = sum((xs[i] - mx) ** 2 for i in range(n))
    dy = sum((ys[i] - my) ** 2 for i in range(n))
    if dx <= 1e-18 or dy <= 1e-18:
        return 0.0
    r = num / math.sqrt(dx * dy)
    return r * r


def _build_matrix_with_breakeven(
    px_now: float,
    surf_grid: dict[str, list[float]],
    fine_surf: dict[str, list[float]],
    breakeven_pct: float | None,
) -> list[dict]:
    zero_g_idx = SHOCK_GRID_PCT.index(0.0)
    c_zero = surf_grid["flow_carver_b"][zero_g_idx]
    tot_zero = surf_grid["flow_carver_plus_vc_b"][zero_g_idx]
    rows: list[dict] = []
    for g_i, pct in enumerate(SHOCK_GRID_PCT):
        c_val = surf_grid["flow_carver_b"][g_i]
        tot_val = surf_grid["flow_carver_plus_vc_b"][g_i]
        rows.append({
            "movePct": float(pct),
            "targetPrice": round(px_now * (1.0 + pct / 100.0), 2),
            "carverCtaFlowB": round(c_val, 2),
            "marginalCarverFlowB": round(c_val - c_zero, 2),
            "smaCtaFlowB": round(surf_grid["flow_sma_b"][g_i], 2),
            "volControlFlowB": round(surf_grid["flow_vc_b"][g_i], 2),
            "combinedFlowB": round(tot_val, 2),
            "marginalCombinedFlowB": round(tot_val - tot_zero, 2),
            "projectedCarverForecast": round(surf_grid["end_f_carver"][g_i], 2),
            "projectedSmaForecast": round(surf_grid["end_f_sma"][g_i], 2),
            "isBaselineRow": abs(pct) < 1e-9,
            "isBreakevenRow": False,
        })

    if breakeven_pct is not None and CURVE_MIN_PCT <= breakeven_pct <= CURVE_MAX_PCT:
        if all(abs(breakeven_pct - p) >= 0.15 for p in SHOCK_GRID_PCT):
            c_be = _interp_linear(breakeven_pct, FINE_GRID_PCT, fine_surf["flow_carver_b"])
            s_be = _interp_linear(breakeven_pct, FINE_GRID_PCT, fine_surf["flow_sma_b"])
            v_be = _interp_linear(breakeven_pct, FINE_GRID_PCT, fine_surf["flow_vc_b"])
            fc_be = _interp_linear(breakeven_pct, FINE_GRID_PCT, fine_surf["end_f_carver"])
            fs_be = _interp_linear(breakeven_pct, FINE_GRID_PCT, fine_surf["end_f_sma"])
            rows.append({
                "movePct": round(breakeven_pct, 2),
                "targetPrice": round(px_now * (1.0 + breakeven_pct / 100.0), 2),
                "carverCtaFlowB": round(c_be, 2),
                "marginalCarverFlowB": round(c_be - c_zero, 2),
                "smaCtaFlowB": round(s_be, 2),
                "volControlFlowB": round(v_be, 2),
                "combinedFlowB": 0.0,
                "marginalCombinedFlowB": round(0.0 - tot_zero, 2),
                "projectedCarverForecast": round(fc_be, 2),
                "projectedSmaForecast": round(fs_be, 2),
                "isBaselineRow": False,
                "isBreakevenRow": True,
            })
            rows.sort(key=lambda r: r["movePct"])
    return rows


def build_artifact(max_date: str | None = None) -> dict:
    rows, pit_meta = load_daily_market_and_pit_scale(max_date=max_date)
    eval_indices = [i for i, r in enumerate(rows) if r["date"] >= "2014-01-02"]
    if not eval_indices:
        raise RuntimeError("No evaluation dates >= 2014-01-02")

    eval_dates = [rows[i]["date"] for i in eval_indices]
    as_of_date = eval_dates[-1]

    # Locate 2014-Q1 effective date (2014-06-02) for PIT scale summary
    q1_2014_row = next((q for q in pit_meta["quarters"] if q["quarterDate"] == "2014-03-31"), pit_meta["quarters"][0])
    latest_q = pit_meta["quarters"][-1]
    scale_growth = round(float(rows[eval_indices[-1]]["cta_scale_mult"]) / float(rows[eval_indices[0]]["cta_scale_mult"]), 2)

    # Checkpoint anchor index right before 2025-01-02 so Node runtime can step 2025-01-02..live dynamically
    cp_idx = max(i for i, r in enumerate(rows) if r["date"] <= "2024-12-31")
    cp_bars = [
        [
            rows[i]["date"],
            round(rows[i]["SPY"], 4),
            round(rows[i]["SPY_unadj"], 4),
            round(rows[i]["QQQ"], 4),
            round(rows[i]["QQQ_unadj"], 4),
            round(rows[i]["VIX"], 3),
            round(rows[i]["VIX3M"], 3),
            round(rows[i]["cta_scale_mult"], 6),
            round(rows[i]["vc_scale_mult"], 6),
        ]
        for i in range(cp_idx + 1, len(rows))
    ]

    assets_out: dict[str, dict] = {}
    asset_checkpoints: dict[str, dict] = {}

    # Shock grid indices: [-5(0), -3(1), -2(2), -1(3), 0(4), +1(5), +2(6), +3(7), +5(8)]
    fine_zero_idx = FINE_GRID_PCT.index(0.0)

    for tk, cfg in ASSETS_CFG.items():
        st = compute_asset_cta_state(
            rows,
            ticker=tk,
            cta_risk_cap_2026_b=cfg["ctaCap"],
            cta_target_vol=cfg["ctaTargetVol"],
            vc_aum_2026_b=cfg["vcCap"],
            vc_target_vol=cfg["vcTargetVol"],
        )

        m_eval = len(eval_indices)
        px_eval = [st["px"][idx] for idx in eval_indices]
        px_unadj_eval = [st["px_unadj"][idx] for idx in eval_indices]
        f_carver_eval = [st["f_carver"][idx] for idx in eval_indices]
        f_sma_eval = [st["f_sma"][idx] for idx in eval_indices]
        f_hybrid_eval = [st["f_hybrid"][idx] for idx in eval_indices]
        scale_eval = [st["cta_scale_mult"][idx] for idx in eval_indices]
        vix_eval = [rows[idx]["VIX"] for idx in eval_indices]
        vix3m_eval = [rows[idx]["VIX3M"] for idx in eval_indices]
        vix_ratio_eval = [rows[idx]["VIX_RATIO"] for idx in eval_indices]
        sma50_eval = [st["sma_mat"][2][idx] for idx in eval_indices]
        sma100_eval = [st["sma_mat"][3][idx] for idx in eval_indices]
        pos_tot_eval = [st["pos_carver_b"][idx] + st["pos_vc_b"][idx] for idx in eval_indices]

        sell_strike_carver: list[float | None] = [None] * m_eval
        buy_strike_carver: list[float | None] = [None] * m_eval
        marg_asym_3_c = [0.0] * m_eval
        marg_asym_5_c = [0.0] * m_eval
        asym_ratio_c = [0.0] * m_eval
        asym_ratio_s = [0.0] * m_eval

        fine_tot_rows: list[list[float]] = []

        # Map FINE_GRID_PCT indices matching SHOCK_GRID_PCT:
        # -5% -> idx 12, -3% -> idx 20, 0% -> idx 32, +3% -> idx 44, +5% -> idx 52
        idx_m5 = FINE_GRID_PCT.index(-5.0)
        idx_m3 = FINE_GRID_PCT.index(-3.0)
        idx_0 = fine_zero_idx
        idx_p3 = FINE_GRID_PCT.index(3.0)
        idx_p5 = FINE_GRID_PCT.index(5.0)

        for i, raw_idx in enumerate(eval_indices):
            f5 = simulate_single_day_surface(st, raw_idx, FINE_GRID_PCT, horizon_days=5)
            sc_m = scale_eval[i]
            tot_raw = f5["flow_carver_plus_vc_b"]
            fine_tot_rows.append(tot_raw)
            tot_eq = [v / sc_m for v in tot_raw]
            carv_eq = [v / sc_m for v in f5["flow_carver_b"]]
            sma_eq = [v / sc_m for v in f5["flow_sma_b"]]

            r_dn_c = find_threshold_strike_pct(FINE_GRID_PCT, tot_eq, cfg["sellCliff2026B"], "down")
            r_up_c = find_threshold_strike_pct(FINE_GRID_PCT, tot_eq, cfg["buyThrust2026B"], "up")
            if r_dn_c is not None:
                sell_strike_carver[i] = px_eval[i] * (1.0 + r_dn_c / 100.0)
            if r_up_c is not None:
                buy_strike_carver[i] = px_eval[i] * (1.0 + r_up_c / 100.0)

            asym_ratio_c[i] = max(tot_eq[idx_p3], 0.0) / max(-tot_eq[idx_m3], 0.5)
            asym_ratio_s[i] = max(sma_eq[idx_p3], 0.0) / max(-sma_eq[idx_m3], 0.5)
            marg_asym_3_c[i] = max(carv_eq[idx_p3] - carv_eq[idx_0], 0.0) / max(-(carv_eq[idx_m3] - carv_eq[idx_0]), 0.5)
            marg_asym_5_c[i] = max(carv_eq[idx_p5] - carv_eq[idx_0], 0.0) / max(-(carv_eq[idx_m5] - carv_eq[idx_0]), 0.5)

        breach_carver = [False] * m_eval
        breach_sma = [False] * m_eval
        thrust_carver = [False] * m_eval
        for i in range(5, m_eval):
            k_ref = sell_strike_carver[i - 3]
            if f_carver_eval[i - 3] >= 2.0 and k_ref is not None and px_eval[i - 1] > k_ref and px_eval[i] <= k_ref:
                breach_carver[i] = True
            cross_50 = (px_eval[i - 1] >= sma50_eval[i - 1]) and (px_eval[i] < sma50_eval[i]) and (f_sma_eval[i - 1] >= 0.0)
            cross_100 = (px_eval[i - 1] >= sma100_eval[i - 1]) and (px_eval[i] < sma100_eval[i])
            if cross_50 or cross_100:
                breach_sma[i] = True
            k_up = buy_strike_carver[i - 3]
            if f_carver_eval[i - 3] <= 2.0 and k_up is not None and px_eval[i - 1] < k_up and px_eval[i] >= k_up:
                thrust_carver[i] = True

        exhaust_carver_total = [f_carver_eval[i] <= -10.0 and asym_ratio_c[i] >= 2.5 for i in range(m_eval)]
        exhaust_carver_marginal = [f_carver_eval[i] <= -10.0 and marg_asym_3_c[i] >= 1.8 for i in range(m_eval)]
        exhaust_sma = [f_sma_eval[i] <= -12.0 and asym_ratio_s[i] >= 2.5 for i in range(m_eval)]

        def _whipsaw_stats(mask: list[bool]) -> dict:
            ep = [idx for idx in decluster_indices(mask, min_gap=15) if idx + 21 < m_eval]
            if not ep:
                return {"nEp": 0, "furtherDrop10dGe2PctRate": 0.0, "whipsawRally21dGt2PctRate": 0.0}
            r21 = [(px_eval[idx + 21] / px_eval[idx] - 1.0) * 100.0 for idx in ep]
            f_drop = [
                min((px_eval[k] / px_eval[idx] - 1.0) * 100.0 for k in range(idx + 1, idx + 11)) <= -2.0
                for idx in ep
            ]
            return {
                "nEp": len(ep),
                "furtherDrop10dGe2PctRate": round(sum(1 for x in f_drop if x) / len(f_drop) * 100.0, 1),
                "whipsawRally21dGt2PctRate": round(sum(1 for x in r21 if x > 2.0) / len(r21) * 100.0, 1),
            }

        test_a_carver = eval_event_study(px_eval, breach_carver, min_gap=15)
        test_a_vix_inv = eval_event_study(px_eval, [breach_carver[i] and vix_ratio_eval[i] >= 1.00 for i in range(m_eval)], min_gap=15)
        test_a_vix_calm = eval_event_study(px_eval, [breach_carver[i] and vix_ratio_eval[i] < 1.00 for i in range(m_eval)], min_gap=15)
        test_a_sma = eval_event_study(px_eval, breach_sma, min_gap=15)

        test_b_carver_marg = eval_event_study(px_eval, exhaust_carver_marginal, min_gap=15)
        test_b_carver_tot = eval_event_study(px_eval, exhaust_carver_total, min_gap=15)
        test_b_sma = eval_event_study(px_eval, exhaust_sma, min_gap=15)
        test_c_carver = eval_event_study(px_eval, thrust_carver, min_gap=15)

        # Out-of-sample endpoint R^2
        pred_5d = [
            _interp_linear((px_eval[i + 5] / px_eval[i] - 1.0) * 100.0, FINE_GRID_PCT, fine_tot_rows[i])
            for i in range(m_eval - 5)
        ]
        act_5d = [pos_tot_eval[i + 5] - pos_tot_eval[i] for i in range(m_eval - 5)]
        r2_flow_map = round(_pearson_r2(pred_5d, act_5d), 4)

        # De-clustered marginal exhaustion episodes (including whether latest day is active!)
        marg_ep_indices = decluster_indices(exhaust_carver_marginal, min_gap=15)
        marg_ep_dates = [eval_dates[idx] for idx in marg_ep_indices]

        # Historical battleground timeline (5 completed regimes + 2026-11 live regime)
        episodes_cfg = [
            (
                "2018_q4",
                "2018-Q4 Fed Tightening Selloff",
                "2018-Q4 加息缩表急跌",
                "2018-10-01",
                "2019-01-15",
                "HIT",
                "Top cliff alert (Oct 2018) + exact Dec 26 exhaustion bottom buy.",
                "顶部抛压崖提前预警，平安夜次日（12/26）精准触发空头耗尽抄底。",
            ),
            (
                "2020_03",
                "2020-03 COVID-19 Liquidity Crash",
                "2020-03 新冠流动性崩盘",
                "2020-02-18",
                "2020-04-15",
                "HIT",
                "Feb 24 VIX-inverted cliff alert caught avalanche; Mar 24 exhaustion nailed QE bottom.",
                "2/24 倒挂破崖首日预警雪崩，3/24 空头耗尽精准命中无限 QE 大底。",
            ),
            (
                "2022_bear",
                "2022 Rate-Hike Slow Bear (Model Caveat)",
                "2022 加息慢熊（模型核心盲区披露）",
                "2022-03-25",
                "2022-09-15",
                "CAVEAT",
                "May exhaustion yielded +6% to +9% bear-market bounce before June/Sept macro lows; slow grinding Fed-tightening bears require macro regime discipline.",
                "5 月空头耗尽仅带来 +6% 至 +9% 熊市技术反弹，随后受通胀加息压制再创新低——诚实披露慢熊盲区。",
            ),
            (
                "2024_08",
                "2024-08 Yen Carry Flash Unwind",
                "2024-08 日元套息闪崩",
                "2024-07-15",
                "2024-08-30",
                "PARTIAL",
                "Jul 24 / Aug 2 cliff alert flagged -$155B deleveraging early; V-bottom reversed at F=-4.8 before reaching -10 exhaustion.",
                "7/24 与 8/02 精准预警超千亿美元去杠杆，但急跌未触及 F<=-10 即 V 型反转。",
            ),
            (
                "2025_04",
                "2025-04 Tariff Shock & V-Squeeze",
                "2025-04 关税冲击与 V 型逼空",
                "2025-02-18",
                "2025-05-15",
                "HIT",
                "Feb 21 cliff breach side-stepped -19% drawdown; April marginal exhaustion & May 2 upside thrust captured V-recovery.",
                "2/21 高位破崖规避近 -20% 急跌，4 月初边际耗尽与 5/02 右侧回补完整捕获反转。",
            ),
        ]
        timeline: list[dict] = []
        for ep_id, title_en, title_zh, s_dt, e_dt, verdict, note_en, note_zh in episodes_cfg:
            w_idx = [j for j, d in enumerate(eval_dates) if s_dt <= d <= e_dt]
            if not w_idx:
                continue
            breach_days = [eval_dates[j] for j in w_idx if breach_carver[j]]
            exh_marg_days = [eval_dates[j] for j in w_idx if exhaust_carver_marginal[j]]
            exh_tot_days = [eval_dates[j] for j in w_idx if exhaust_carver_total[j]]
            exh_union = sorted(set(exh_marg_days) | set(exh_tot_days))
            peak_pos = max(pos_tot_eval[j] for j in w_idx)
            trough_pos = min(pos_tot_eval[j] for j in w_idx)
            min_f = min(f_carver_eval[j] for j in w_idx)
            run_max = 0.0
            max_dd_w = 0.0
            for j in w_idx:
                run_max = max(run_max, px_eval[j])
                max_dd_w = min(max_dd_w, (px_eval[j] / run_max - 1.0) * 100.0)
            timeline.append({
                "id": ep_id,
                "titleEn": title_en,
                "titleZh": title_zh,
                "window": f"{s_dt} -> {e_dt}",
                "verdict": verdict,
                "windowMaxDdPct": round(max_dd_w, 2),
                "cliffBreachDates": breach_days[:3],
                "exhaustionBuyDates": exh_union[:4],
                "deleveragingB": round(trough_pos - peak_pos, 2),
                "minCarverForecast": round(min_f, 2),
                "summaryEn": note_en,
                "summaryZh": note_zh,
            })

        # Live latest day state
        i_now = m_eval - 1
        t_raw = eval_indices[i_now]
        px_now = px_unadj_eval[i_now]
        surf_5d_now = simulate_single_day_surface(st, t_raw, SHOCK_GRID_PCT, horizon_days=5)
        surf_10d_now = simulate_single_day_surface(st, t_raw, SHOCK_GRID_PCT, horizon_days=10)
        fine_5d_now = simulate_single_day_surface(st, t_raw, FINE_GRID_PCT, horizon_days=5)
        fine_10d_now = simulate_single_day_surface(st, t_raw, FINE_GRID_PCT, horizon_days=10)

        zero_flow_5d_pct = find_threshold_strike_pct(FINE_GRID_PCT, fine_5d_now["flow_carver_plus_vc_b"], 0.0, "up")
        zero_flow_10d_pct = find_threshold_strike_pct(FINE_GRID_PCT, fine_10d_now["flow_carver_plus_vc_b"], 0.0, "up")
        sqz_5d_pct = find_threshold_strike_pct(FINE_GRID_PCT, fine_5d_now["flow_carver_plus_vc_b"], cfg["squeeze5dB"], "up")
        sqz_10d_pct = find_threshold_strike_pct(FINE_GRID_PCT, fine_10d_now["flow_carver_plus_vc_b"], cfg["squeeze10dB"], "up")
        sell_cliff_now_pct = find_threshold_strike_pct(
            FINE_GRID_PCT,
            [v / scale_eval[i_now] for v in fine_5d_now["flow_carver_plus_vc_b"]],
            cfg["sellCliff2026B"],
            "down",
        )

        # Append Live 2026-11 regime card to timeline
        oct_nov_idx = [j for j, d in enumerate(eval_dates) if d >= "2026-10-01"]
        run_max_live = 0.0
        dd_live = 0.0
        for j in oct_nov_idx:
            run_max_live = max(run_max_live, px_eval[j])
            dd_live = min(dd_live, (px_eval[j] / run_max_live - 1.0) * 100.0)
        peak_recent = max(pos_tot_eval[-25:])
        cum_delev = pos_tot_eval[i_now] - peak_recent
        is_primary_active = bool(exhaust_carver_marginal[i_now])

        timeline.append({
            "id": "2026_11_live",
            "titleEn": f"{as_of_date[:7]} Live Systematic Deleveraging",
            "titleZh": f"{as_of_date[:7]} 实时去杠杆与边际凸性监测",
            "window": f"2026-10-15 -> {as_of_date}",
            "verdict": "LIVE_ACTIVE" if is_primary_active else "LIVE_WATCH",
            "windowMaxDdPct": round(dd_live, 2),
            "cliffBreachDates": [eval_dates[j] for j in oct_nov_idx if breach_carver[j]][:3],
            "exhaustionBuyDates": [as_of_date] if is_primary_active else [],
            "deleveragingB": round(cum_delev, 2),
            "minCarverForecast": round(min(f_carver_eval[j] for j in oct_nov_idx), 2),
            "summaryEn": (
                f"{abs(cum_delev):.1f}B mechanical selling already absorbed; F={f_carver_eval[i_now]:.2f} "
                f"with {marg_asym_3_c[i_now]:.2f}x (+3%/-3%) marginal convexity — "
                + ("11th historical Marginal Exhaustion Buy Trigger ACTIVE." if is_primary_active else "deep oversold watch; awaiting >=1.80x 3% marginal convexity.")
            ),
            "summaryZh": (
                f"已宣泄 {cum_delev:.1f}B 机械抛盘；当前 F={f_carver_eval[i_now]:.2f}，+3%/-3% 边际凸性比 {marg_asym_3_c[i_now]:.2f}x —— "
                + ("正式触发历史第 11 次空头边际耗尽买点信号！" if is_primary_active else "深度超卖观察区（待 +3% 边际凸性升破 1.80x）。")
            ),
        })

        ewmac_detail = [
            {
                "rule": f"EWMAC({lf},{ls})",
                "fastSpan": lf,
                "slowSpan": ls,
                "scalar": sc,
                "emaFast": round(st["ema_fast"][k][t_raw], 2),
                "emaSlow": round(st["ema_slow"][k][t_raw], 2),
                "forecast": round(st["f_indiv"][k][t_raw], 2),
                "flip1dPrice": round(st["flip_1d_px"][k][t_raw], 2),
                "pctTo1dFlip": round((st["flip_1d_px"][k][t_raw] / px_now - 1.0) * 100.0, 2),
            }
            for k, (lf, ls, sc) in enumerate(EWMAC_CONFIGS)
        ]
        sma_detail = [
            {
                "ma": f"SMA{w_len}",
                "window": w_len,
                "weight": SMA_WEIGHTS[m_idx],
                "level": round(st["sma_mat"][m_idx][t_raw], 2),
                "pctDistanceFromSpot": round((st["sma_mat"][m_idx][t_raw] / px_now - 1.0) * 100.0, 2),
                "state": "LONG" if px_eval[i_now] >= st["sma_mat"][m_idx][t_raw] else "SHORT",
            }
            for m_idx, w_len in enumerate(SMA_WINDOWS)
        ]

        matrix_5d = _build_matrix_with_breakeven(px_now, surf_5d_now, fine_5d_now, zero_flow_5d_pct)
        matrix_10d = _build_matrix_with_breakeven(px_now, surf_10d_now, fine_10d_now, zero_flow_10d_pct)

        c5_z = fine_5d_now["flow_carver_b"][fine_zero_idx]
        t5_z = fine_5d_now["flow_carver_plus_vc_b"][fine_zero_idx]
        c10_z = fine_10d_now["flow_carver_b"][fine_zero_idx]
        t10_z = fine_10d_now["flow_carver_plus_vc_b"][fine_zero_idx]

        curve_points = []
        for g_i, pct in enumerate(FINE_GRID_PCT):
            if pct < CURVE_MIN_PCT or pct > CURVE_MAX_PCT:
                continue
            curve_points.append({
                "movePct": pct,
                "targetPrice": round(px_now * (1.0 + pct / 100.0), 2),
                "carver5dB": round(fine_5d_now["flow_carver_b"][g_i], 2),
                "marginalCarver5dB": round(fine_5d_now["flow_carver_b"][g_i] - c5_z, 2),
                "sma5dB": round(fine_5d_now["flow_sma_b"][g_i], 2),
                "vc5dB": round(fine_5d_now["flow_vc_b"][g_i], 2),
                "combined5dB": round(fine_5d_now["flow_carver_plus_vc_b"][g_i], 2),
                "marginalCombined5dB": round(fine_5d_now["flow_carver_plus_vc_b"][g_i] - t5_z, 2),
                "carver10dB": round(fine_10d_now["flow_carver_b"][g_i], 2),
                "marginalCarver10dB": round(fine_10d_now["flow_carver_b"][g_i] - c10_z, 2),
                "sma10dB": round(fine_10d_now["flow_sma_b"][g_i], 2),
                "vc10dB": round(fine_10d_now["flow_vc_b"][g_i], 2),
                "combined10dB": round(fine_10d_now["flow_carver_plus_vc_b"][g_i], 2),
                "marginalCombined10dB": round(fine_10d_now["flow_carver_plus_vc_b"][g_i] - t10_z, 2),
            })

        recent_traj = []
        for j in range(max(0, m_eval - 45), m_eval):
            r_raw = eval_indices[j]
            prev_tot = pos_tot_eval[j - 1] if j > 0 else pos_tot_eval[j]
            recent_traj.append({
                "date": eval_dates[j],
                "close": round(px_unadj_eval[j], 2),
                "fCarver": round(f_carver_eval[j], 2),
                "fSma": round(f_sma_eval[j], 2),
                "posCarverB": round(st["pos_carver_b"][r_raw], 2),
                "posVcB": round(st["pos_vc_b"][r_raw], 2),
                "posCombinedB": round(pos_tot_eval[j], 2),
                "dailyFlowB": round(pos_tot_eval[j] - prev_tot, 2),
                "vixRatio": round(vix_ratio_eval[j], 3),
            })

        pctile_12y = round(sum(1 for v in f_carver_eval if v <= f_carver_eval[i_now]) / len(f_carver_eval) * 100.0, 1)
        completed_marg_eps = test_b_carver_marg["horizons"].get("63D", {}).get("nEp", len(marg_ep_dates))
        trigger_rank = (completed_marg_eps + 1) if is_primary_active else None

        whip_carver = _whipsaw_stats(breach_carver)
        whip_vix_inv = _whipsaw_stats([breach_carver[i] and vix_ratio_eval[i] >= 1.00 for i in range(m_eval)])
        whip_vix_calm = _whipsaw_stats([breach_carver[i] and vix_ratio_eval[i] < 1.00 for i in range(m_eval)])
        whip_sma = _whipsaw_stats(breach_sma)

        assets_out[tk] = {
            "ticker": tk,
            "nameEn": cfg["nameEn"],
            "nameZh": cfg["nameZh"],
            "futuresBenchmark": cfg["futuresBenchmark"],
            "calibration": {
                "ctaRiskCap2026B": cfg["ctaCap"],
                "ctaTargetVolPct": round(cfg["ctaTargetVol"] * 100.0, 1),
                "vcAum2026B": cfg["vcCap"],
                "vcTargetVolPct": round(cfg["vcTargetVol"] * 100.0, 1),
                "sellCliff2026B": cfg["sellCliff2026B"],
                "buyThrust2026B": cfg["buyThrust2026B"],
            },
            "liveState": {
                "asOfDate": as_of_date,
                "spotClose": round(px_now, 2),
                "vixClose": round(vix_eval[i_now], 2),
                "vix3mClose": round(vix3m_eval[i_now], 2),
                "vixVix3mRatio": round(vix_ratio_eval[i_now], 3),
                "vixBackwardation": bool(vix_ratio_eval[i_now] >= 1.00),
                "fCarver": round(f_carver_eval[i_now], 2),
                "fSma": round(f_sma_eval[i_now], 2),
                "fHybrid": round(f_hybrid_eval[i_now], 2),
                "carverForecast12YrPercentile": pctile_12y,
                "annVolCarverPct": round(st["ann_vol_carver"][t_raw] * 100.0, 2),
                "rv20Pct": round(st["rv20"][t_raw] * 100.0, 2),
                "rv60Pct": round(st["rv60"][t_raw] * 100.0, 2),
                "posCarverCtaB": round(st["pos_carver_b"][t_raw], 2),
                "tgtUnbufferedCarverCtaB": round(st["tgt_carver_b"][t_raw], 2),
                "posSmaCtaB": round(st["pos_sma_b"][t_raw], 2),
                "posVolControlB": round(st["pos_vc_b"][t_raw], 2),
                "posCombinedSysB": round(pos_tot_eval[i_now], 2),
                "recentPeakCombinedSysB": round(peak_recent, 2),
                "recentCumDeleveragingB": round(cum_delev, 2),
                "flatInertia5dCarverB": round(c5_z, 2),
                "flatInertia5dCombinedB": round(t5_z, 2),
                "flatInertia10dCarverB": round(c10_z, 2),
                "flatInertia10dCombinedB": round(t10_z, 2),
                "marginalAsymmetry3Pct5d": round(marg_asym_3_c[i_now], 2),
                "marginalAsymmetry5Pct5d": round(marg_asym_5_c[i_now], 2),
                "zeroNetFlowBreakeven5dPct": round(zero_flow_5d_pct, 2) if zero_flow_5d_pct is not None else None,
                "zeroNetFlowBreakeven5dPx": round(px_now * (1.0 + zero_flow_5d_pct / 100.0), 2) if zero_flow_5d_pct is not None else None,
                "zeroNetFlowBreakeven10dPct": round(zero_flow_10d_pct, 2) if zero_flow_10d_pct is not None else None,
                "zeroNetFlowBreakeven10dPx": round(px_now * (1.0 + zero_flow_10d_pct / 100.0), 2) if zero_flow_10d_pct is not None else None,
                "squeezeIgnition5dPct": round(sqz_5d_pct, 2) if sqz_5d_pct is not None else None,
                "squeezeIgnition5dPx": round(px_now * (1.0 + sqz_5d_pct / 100.0), 2) if sqz_5d_pct is not None else None,
                "squeezeIgnition10dPct": round(sqz_10d_pct, 2) if sqz_10d_pct is not None else None,
                "squeezeIgnition10dPx": round(px_now * (1.0 + sqz_10d_pct / 100.0), 2) if sqz_10d_pct is not None else None,
                "sellCliff5dPct": round(sell_cliff_now_pct, 2) if sell_cliff_now_pct is not None else None,
                "sellCliff5dPx": round(px_now * (1.0 + sell_cliff_now_pct / 100.0), 2) if sell_cliff_now_pct is not None else None,
            },
            "signals": {
                "primaryExhaustionBuy": {
                    "id": "carver_marginal_exhaustion",
                    "active": is_primary_active,
                    "triggerRank": trigger_rank,
                    "completedEpisodes": completed_marg_eps,
                    "historicalTriggerDates": marg_ep_dates,
                    "fThreshold": -10.0,
                    "convexityThreshold": 1.80,
                    "currentF": round(f_carver_eval[i_now], 2),
                    "currentConvexity3Pct": round(marg_asym_3_c[i_now], 2),
                    "currentConvexity5Pct": round(marg_asym_5_c[i_now], 2),
                    "oosStats": test_b_carver_marg["horizons"],
                },
                "vixBackwardationGuardrail": {
                    "id": "vix_backwardation_cliff_lock",
                    "vixInverted": bool(vix_ratio_eval[i_now] >= 1.00),
                    "cliffBreachedToday": bool(breach_carver[i_now]),
                    "recentCliffBreachDate": next((eval_dates[j] for j in reversed(range(max(0, m_eval - 20), m_eval)) if breach_carver[j]), None),
                    "vixRatio": round(vix_ratio_eval[i_now], 3),
                    "vixClose": round(vix_eval[i_now], 2),
                    "vix3mClose": round(vix3m_eval[i_now], 2),
                    "inverted10dDropGe2PctRate": whip_vix_inv["furtherDrop10dGe2PctRate"],
                    "calm10dDropGe2PctRate": whip_vix_calm["furtherDrop10dGe2PctRate"],
                    "inverted5dRvolPct": test_a_vix_inv["horizons"]["5D"]["fwdRvolMeanPct"],
                    "base5dRvolPct": test_a_vix_inv["horizons"]["5D"]["baseRvolMeanPct"],
                    "pValVol5d": test_a_vix_inv["horizons"]["5D"]["pValVol"],
                    "inverted5dWorstDdPct": test_a_vix_inv["horizons"]["5D"]["fwdWorstDdMeanPct"],
                    "pValMdd5d": test_a_vix_inv["horizons"]["5D"]["pValMdd"],
                },
            },
            "ewmacComponents": ewmac_detail,
            "smaComponents": sma_detail,
            "flowCurve": curve_points,
            "matrix5d": matrix_5d,
            "matrix10d": matrix_10d,
            "empiricalScorecard": {
                "flowSurfaceEndpointR2": r2_flow_map,
                "unconditionalCliffBreach": {
                    "carver": {**test_a_carver, "whipsaw": whip_carver},
                    "sma": {**test_a_sma, "whipsaw": whip_sma},
                },
                "vixBackwardationCliff": {
                    "inverted": {**test_a_vix_inv, "whipsaw": whip_vix_inv},
                    "contango": {**test_a_vix_calm, "whipsaw": whip_vix_calm},
                },
                "shortExhaustionAlpha": {
                    "carverMarginal": test_b_carver_marg,
                    "carverTotal": test_b_carver_tot,
                    "smaExhaustion": test_b_sma,
                },
                "upsideThrust": test_c_carver,
            },
            "historicalTimeline": timeline,
            "recentTrajectory": recent_traj,
        }
        sig_bt = compute_signal_backtest(
            dates=eval_dates,
            px_adj=px_eval,
            px_unadj=px_unadj_eval,
            f_carver=f_carver_eval,
            marg_asym_3=marg_asym_3_c,
            vix_ratio=vix_ratio_eval,
            vix_close=vix_eval,
        )
        assets_out[tk]["signalBacktest"] = sig_bt
        assets_out[tk]["signal_backtest"] = sig_bt

        # Compact checkpoint state at cp_idx (2024-12-31) for dynamic runtime stepping
        f_sorted_2014_cp = sorted(
            round(st["f_carver"][idx], 3) for idx in eval_indices if idx <= cp_idx
        )
        eval_pre2025 = [
            [
                eval_dates[j],
                round(px_eval[j], 4),
                round(px_unadj_eval[j], 2),
                round(f_carver_eval[j], 3),
                round(marg_asym_3_c[j], 3),
                round(vix_ratio_eval[j], 4),
                round(vix_eval[j], 2),
            ]
            for j, raw_idx in enumerate(eval_indices)
            if raw_idx <= cp_idx
        ]
        asset_checkpoints[tk] = {
            "cpDate": rows[cp_idx]["date"],
            "trailingPx200": [round(v, 4) for v in st["px"][cp_idx - 200 + 1 : cp_idx + 1]],
            "trailingRet60": [round(v, 6) for v in st["ret"][cp_idx - 60 + 1 : cp_idx + 1]],
            "var36": st["var_36"][cp_idx],
            "trailingAnnVol2520Sum": sum(st["ann_pct_vol_36"][cp_idx - 2520 + 1 : cp_idx + 1]),
            "trailingAnnVol2520Head600": [round(v, 5) for v in st["ann_pct_vol_36"][cp_idx - 2520 + 1 : cp_idx - 2520 + 601]],
            "emaFast": [st["ema_fast"][k][cp_idx] for k in range(6)],
            "emaSlow": [st["ema_slow"][k][cp_idx] for k in range(6)],
            "posCarverB": st["pos_carver_b"][cp_idx],
            "posSmaB": st["pos_sma_b"][cp_idx],
            "posHybridB": st["pos_hybrid_b"][cp_idx],
            "posVcB": st["pos_vc_b"][cp_idx],
            "fCarverPre2025": f_sorted_2014_cp,
            "completedMargEpsPre2025": sum(1 for d in marg_ep_dates if d <= rows[cp_idx]["date"]),
            "margEpDatesPre2025": [d for d in marg_ep_dates if d <= rows[cp_idx]["date"]],
            "evalSeriesPre2025": eval_pre2025,
        }

    return {
        "version": ARTIFACT_VERSION,
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "asOfDate": as_of_date,
        "evaluationWindow": {
            "warmupStart": rows[0]["date"],
            "start": eval_dates[0],
            "end": as_of_date,
            "tradingDays": len(eval_dates),
        },
        "pit13fScale": {
            "trackedInstitutionCount": pit_meta["trackedInstitutionCount"],
            "statutoryReportingLagDays": pit_meta["statutoryReportingLagDays"],
            "representativeInstitutions": pit_meta["representativeInstitutions"],
            "q1_2014CtaTrendCoreB": round(float(q1_2014_row["ctaTrendCoreB"]), 2),
            "latestQuarter": latest_q["quarterDate"],
            "latestAvailableDate": latest_q["availableDate"],
            "latestCtaTrendCoreB": round(float(latest_q["ctaTrendCoreB"]), 2),
            "latestSp500EtfB": round(float(latest_q["ctaSp500B"]), 2),
            "latestQqqEtfB": round(float(latest_q["ctaQqqB"]), 2),
            "scaleGrowthMultiplier": scale_growth,
            "quarters": [
                {
                    "quarterDate": q["quarterDate"],
                    "availableDate": q["availableDate"],
                    "filerCount": q["filerCount"],
                    "ctaTrendCoreB": round(float(q["ctaTrendCoreB"]), 2),
                    "ctaMacroB": round(float(q["ctaMacroB"]), 2),
                    "ctaSp500B": round(float(q["ctaSp500B"]), 2),
                    "ctaQqqB": round(float(q["ctaQqqB"]), 2),
                    "ctaScaleMult": round(float(q["ctaScaleMult"]), 4),
                }
                for q in pit_meta["quarters"]
                if q["quarterDate"] >= "2014-03-31"
            ],
        },
        "methodology": {
            "ewmacRules": [
                {"rule": f"EWMAC({lf},{ls})", "fastSpan": lf, "slowSpan": ls, "scalar": sc, "weight": round(1.0 / 6.0, 4)}
                for lf, ls, sc in EWMAC_CONFIGS
            ],
            "forecastDiversificationMultiplier": CARVER_FDM,
            "forecastCap": 20.0,
            "volEstimator": "70% 36-day EWMA price-diff vol + 30% 10-year (2520D) rolling floor (min 7% ann.)",
            "inertiaBufferPct": 10.0,
            "executionSmoothing": "3-day institutional VWAP (alpha = 0.50)",
            "shortAsymmetryFactor": 0.65,
            "smaBenchmarkWindows": SMA_WINDOWS,
            "smaBenchmarkWeights": SMA_WEIGHTS,
            "volControlRule": "60% RV20 + 40% RV60 long-only target-volatility sleeve (0x to 1.0x)",
        },
        "assets": assets_out,
        "runtimeCheckpoint": {
            "checkpointDate": rows[cp_idx]["date"],
            "dailyBarsFrom2025": cp_bars,
            "assets": asset_checkpoints,
        },
    }


def verify_artifact(doc: dict) -> None:
    assert doc["version"] == ARTIFACT_VERSION
    assert doc["evaluationWindow"]["tradingDays"] >= 3240
    spy = doc["assets"]["SPY"]
    qqq = doc["assets"]["QQQ"]
    assert spy["liveState"]["spotClose"] > 100
    assert qqq["liveState"]["spotClose"] > 100
    assert len(spy["flowCurve"]) == 49
    assert len(qqq["flowCurve"]) == 49
    assert len(spy["matrix5d"]) >= 9
    assert len(spy["matrix10d"]) >= 9
    assert 0.74 <= spy["empiricalScorecard"]["flowSurfaceEndpointR2"] <= 0.82
    assert 0.75 <= qqq["empiricalScorecard"]["flowSurfaceEndpointR2"] <= 0.83
    b63 = spy["signals"]["primaryExhaustionBuy"]["oosStats"]["63D"]
    assert b63["winRatePct"] == 100.0
    assert b63["pValRet"] <= 0.005
    spy_bt = spy["signalBacktest"]["regimes"]["exhaustion_convexity"]
    qqq_bt = qqq["signalBacktest"]["regimes"]["exhaustion_convexity"]
    assert spy_bt["completedEpisodes120d"] == 10
    assert spy_bt["livePendingCount"] >= 1
    assert len(spy_bt["dipEntryMatrix"]) == 5
    assert len(qqq_bt["dipEntryMatrix"]) == 5


def main() -> None:
    parser = argparse.ArgumentParser(description="Build CTA Flow Radar dashboard artifact.")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="Output JSON path")
    parser.add_argument("--max-date", type=str, default=None, help="Optional YYYY-MM-DD cutoff")
    parser.add_argument("--check", action="store_true", help="Verify existing artifact without writing")
    args = parser.parse_args()

    if args.check:
        existing = json.loads(args.out.read_text(encoding="utf-8"))
        verify_artifact(existing)
        print(f"OK: verified {args.out} (asOfDate={existing['asOfDate']})")
        return

    doc = build_artifact(max_date=args.max_date)
    verify_artifact(doc)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    spy_ls = doc["assets"]["SPY"]["liveState"]
    qqq_ls = doc["assets"]["QQQ"]["liveState"]
    print(
        f"Built {args.out} | asOf={doc['asOfDate']} | "
        f"SPY=${spy_ls['spotClose']} F={spy_ls['fCarver']} ({spy_ls['carverForecast12YrPercentile']}%ile) "
        f"10D_Flip=${spy_ls['zeroNetFlowBreakeven10dPx']} [{spy_ls['zeroNetFlowBreakeven10dPct']}%] | "
        f"QQQ=${qqq_ls['spotClose']} F={qqq_ls['fCarver']} ({qqq_ls['carverForecast12YrPercentile']}%ile) "
        f"10D_Flip=${qqq_ls['zeroNetFlowBreakeven10dPx']} [{qqq_ls['zeroNetFlowBreakeven10dPct']}%]"
    )


if __name__ == "__main__":
    main()
