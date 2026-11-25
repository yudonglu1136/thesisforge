#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build the verified seed & golden audit archive for ThesisForge Crisis Observatory's
selectable 1.20x (+20% KMLM Leveraged Return-Stacking + Anti-Overfitting NegCorr Rotation)
Hypothesis Overlay ("版本假说 · 1.20x +20% KMLM 叠仓"), while keeping the locked 1.00x
B020_M125 production artifact (crisis-observatory-dashboard.json) 100.00% untouched.

Verifies $0.00 penny-exact parity against:
  /Users/yudonglu/Documents/gemini/qqq-options-backtest/output/pure_kmlm_dd12_negcorr_blueprint_20261125/data/pure_kmlm_dd12_blueprint_results.json
"""
from __future__ import annotations

import argparse
import datetime
import gzip
import importlib.util
import json
import math
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, Sequence

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

import m7_crisis_engine as m7e  # noqa: E402
import real_option_chain as roc  # noqa: E402

DEFAULT_DASHBOARD_JSON = PROJECT_ROOT / "server/config/crisis-observatory-dashboard.json"
DEFAULT_OUTPUT_GZ = PROJECT_ROOT / "server/config/crisis-observatory-kmlm20-seed.json.gz"
DEFAULT_GOLDEN_REF = Path(
    "/Users/yudonglu/Documents/gemini/qqq-options-backtest/output/"
    "pure_kmlm_dd12_negcorr_blueprint_20261125/data/pure_kmlm_dd12_blueprint_results.json"
)

INITIAL_CAPITAL = 200_000.0
REBAL_FEE = 0.0005  # 5 bps one-way ETF rebalance friction


def _load_bco_module():
    bco_path = SCRIPT_DIR / "build-crisis-observatory-artifact.py"
    spec = importlib.util.spec_from_file_location("bco_mod_kmlm", str(bco_path))
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _unpack_table(val: Any) -> list[dict[str, Any]]:
    if not val:
        return []
    if isinstance(val, list):
        return val
    if isinstance(val, dict) and "_cols" in val and "_rows" in val:
        cols = val["_cols"]
        return [{cols[j]: row[j] for j in range(len(cols))} for row in val["_rows"]]
    return []


def fetch_yahoo_adjclose(symbol: str, start_ts: int, end_ts: int) -> dict[str, float]:
    sym_url = symbol.replace("^", "%5E")
    url = (
        f"https://query1.finance.yahoo.com/v8/finance/chart/{sym_url}"
        f"?period1={start_ts}&period2={end_ts}&interval=1d&events=div,split"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    res = data["chart"]["result"][0]
    ts = res["timestamp"]
    ind = res["indicators"]
    vals = (
        ind["adjclose"][0]["adjclose"]
        if ("adjclose" in ind and ind["adjclose"])
        else ind["quote"][0]["close"]
    )
    out: dict[str, float] = {}
    for t, v in zip(ts, vals):
        if v is None or not math.isfinite(float(v)):
            continue
        d = datetime.datetime.fromtimestamp(t, tz=datetime.timezone.utc).strftime("%Y-%m-%d")
        out[d] = float(v)
    return dict(sorted(out.items()))


def fetch_nyfed_effr(start_date: str = "2015-01-01", end_date: str = "2026-12-31") -> dict[str, float]:
    url = (
        "https://markets.newyorkfed.org/api/rates/unsecured/effr/search.json"
        f"?startDate={start_date}&endDate={end_date}"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        obj = json.loads(resp.read().decode("utf-8"))
    rows = obj.get("refRates", [])
    out: dict[str, float] = {}
    for r in rows:
        if r.get("percentRate") is not None and r.get("effectiveDate"):
            out[str(r["effectiveDate"])] = float(r["percentRate"]) / 100.0
    return dict(sorted(out.items()))


def reindex_ffill(src: dict[str, float], target_dates: Sequence[str], bfill: bool = False) -> list[float | None]:
    sorted_items = sorted(src.items())
    out: list[float | None] = []
    idx = 0
    n_src = len(sorted_items)
    last_val: float | None = None
    for d in target_dates:
        while idx < n_src and sorted_items[idx][0] <= d:
            last_val = sorted_items[idx][1]
            idx += 1
        out.append(last_val)
    if bfill:
        first_valid = next((v for v in out if v is not None), None)
        if first_valid is not None:
            for j in range(len(out)):
                if out[j] is None:
                    out[j] = first_valid
                else:
                    break
    return out


def pct_change_zero_first(vals: Sequence[float | None]) -> list[float]:
    n = len(vals)
    out = [0.0] * n
    for i in range(1, n):
        prev = vals[i - 1]
        cur = vals[i]
        if prev is not None and cur is not None and prev > 0.0:
            out[i] = cur / prev - 1.0
    return out


def pearson_corr(xs: Sequence[float], ys: Sequence[float]) -> float:
    n = min(len(xs), len(ys))
    if n < 3:
        return 0.0
    mx = sum(xs[:n]) / n
    my = sum(ys[:n]) / n
    vx = sum((xs[k] - mx) ** 2 for k in range(n)) / n
    vy = sum((ys[k] - my) ** 2 for k in range(n)) / n
    sx = math.sqrt(vx)
    sy = math.sqrt(vy)
    if sx <= 1e-10 or sy <= 1e-10:
        return 0.0
    cov = sum((xs[k] - mx) * (ys[k] - my) for k in range(n)) / n
    return cov / (sx * sy)


def reg_t_crash_to_call(w: float, maint_margin: float) -> float:
    """Simultaneous portfolio drop (%) required to reach maintenance margin ratio m."""
    x = 1.0 - w / ((1.0 + w) * (1.0 - maint_margin))
    return round(-x * 100.0, 2)


def sim_pure_cta_blueprint(
    dates: Sequence[str],
    r_core: Sequence[float],
    r_qqq: Sequence[float],
    qqq_px: Sequence[float],
    sleeves: list[tuple[str, float, Sequence[float], Sequence[float]]],
    effr: Sequence[float],
    vix: Sequence[float],
    fin_spread: float,
    tp_day_info: dict[int, dict[str, Any]],
    lockout_active_by_day: Sequence[bool],
    mode: str = "rot_vix20",
    neg_rule: str = "strict_both",
    dd_thresh: float = -0.12,
    reload_vix: float = 20.0,
    reload_td: int = 60,
    fee_rate: float = REBAL_FEE,
) -> dict[str, Any]:
    """Strictly causal daily mark-to-market return-stacking + NegCorr rotation simulation."""
    n = len(dates)
    dt_objs = [datetime.date.fromisoformat(d) for d in dates]
    tot_w = sum(s[1] for s in sleeves)
    n_sl = len(sleeves)

    eq = [0.0] * n
    ltv = [0.0] * n
    core_val = INITIAL_CAPITAL
    sl_vals = [INITIAL_CAPITAL * s[1] for s in sleeves]
    sl_in_qqq = [False] * n_sl
    sl_saved_ath = [0.0] * n_sl
    sl_rot_idx = [-1] * n_sl
    sl_pending_to_qqq = [False] * n_sl
    sl_pending_to_hedge = [False] * n_sl
    sl_meta: list[dict[str, Any] | None] = [None] * n_sl
    pending_drift_rebal = False

    loan = INITIAL_CAPITAL * tot_w
    eq[0] = INITIAL_CAPITAL
    ltv[0] = loan / max(core_val + sum(sl_vals), 1e-6)
    tot_interest = 0.0
    tot_turnover = 0.0
    rebal_cnt = 0
    rot_log: list[dict[str, Any]] = []

    run_ath_px = float(qqq_px[0])
    run_ath_idx = 0
    is_static = mode in ("static_drift", "static_qtr")

    for i in range(1, n):
        cal_days = max(1, (dt_objs[i] - dt_objs[i - 1]).days)
        core_val *= 1.0 + float(r_core[i])
        for k in range(n_sl):
            sl_vals[k] *= 1.0 + float(r_qqq[i] if sl_in_qqq[k] else sleeves[k][2][i])
        int_today = loan * max(0.0, float(effr[i - 1]) + fin_spread) * (cal_days / 360.0)
        loan += int_today
        tot_interest += int_today
        cur_eq = max(1.0, core_val + sum(sl_vals) - loan)

        did_rebal_today = False
        for k in range(n_sl):
            if sl_pending_to_qqq[k] and not sl_in_qqq[k]:
                traded = 2.0 * sl_vals[k]
                tot_turnover += traded / max(cur_eq, 1.0)
                sl_vals[k] = max(0.0, sl_vals[k] * (1.0 - 2.0 * fee_rate))
                sl_in_qqq[k] = True
                sl_rot_idx[k] = i
                sl_pending_to_qqq[k] = False
                if sl_meta[k] is not None:
                    sl_meta[k]["exec_date"] = dates[i]
                    sl_meta[k]["qqq_in"] = float(qqq_px[i])
                    sl_meta[k]["asset_out"] = float(sleeves[k][3][i])
                    sl_meta[k]["usd_rot"] = round(float(sl_vals[k]), 2)
            elif sl_pending_to_hedge[k] and sl_in_qqq[k]:
                traded = 2.0 * sl_vals[k]
                tot_turnover += traded / max(cur_eq, 1.0)
                sl_vals[k] = max(0.0, sl_vals[k] * (1.0 - 2.0 * fee_rate))
                sl_in_qqq[k] = False
                sl_pending_to_hedge[k] = False
                if sl_meta[k] is not None:
                    m = sl_meta[k]
                    qr = (float(qqq_px[i]) / m["qqq_in"] - 1.0) * 100.0
                    ar = (float(sleeves[k][3][i]) / m["asset_out"] - 1.0) * 100.0
                    m["reload_date"] = dates[i]
                    m["hold_td"] = int(i - sl_rot_idx[k])
                    m["qqq_hold_ret_pct"] = round(float(qr), 2)
                    m["asset_hold_ret_pct"] = round(float(ar), 2)
                    m["spread_pp"] = round(float(qr - ar), 2)
                    m["est_alpha_usd"] = round(float(m["usd_rot"] * (qr - ar) / 100.0), 0)
                    sl_meta[k] = None
                cur_eq = max(1.0, core_val + sum(sl_vals) - loan)
                tgt_core = cur_eq
                tgt_sl = [cur_eq * s[1] for s in sleeves]
                d_tr = abs(tgt_core - core_val) + sum(abs(tgt_sl[j] - sl_vals[j]) for j in range(n_sl))
                tot_turnover += d_tr / max(cur_eq, 1.0)
                cur_eq_a = max(1.0, cur_eq - d_tr * fee_rate)
                core_val = cur_eq_a
                sl_vals = [cur_eq_a * s[1] for s in sleeves]
                loan = cur_eq_a * tot_w
                rebal_cnt += 1
                did_rebal_today = True

        if tot_w > 1e-8 and (not any(sl_in_qqq)) and (not did_rebal_today):
            do_rebal = False
            if mode == "static_drift":
                if pending_drift_rebal:
                    do_rebal = True
                    pending_drift_rebal = False
            else:
                q_cur = (int(dates[i][5:7]) - 1) // 3
                q_nxt = (int(dates[i + 1][5:7]) - 1) // 3 if i < n - 1 else q_cur
                if i < n - 1 and (q_cur != q_nxt or dates[i][:4] != dates[i + 1][:4]):
                    do_rebal = True
            if do_rebal:
                cur_eq = max(1.0, core_val + sum(sl_vals) - loan)
                tgt_core = cur_eq
                tgt_sl = [cur_eq * s[1] for s in sleeves]
                d_tr = abs(tgt_core - core_val) + sum(abs(tgt_sl[j] - sl_vals[j]) for j in range(n_sl))
                tot_turnover += d_tr / max(cur_eq, 1.0)
                cur_eq_a = max(1.0, cur_eq - d_tr * fee_rate)
                core_val = cur_eq_a
                sl_vals = [cur_eq_a * s[1] for s in sleeves]
                loan = cur_eq_a * tot_w
                rebal_cnt += 1

        cur_eq = max(1.0, core_val + sum(sl_vals) - loan)
        eq[i] = cur_eq
        ltv[i] = loan / max(core_val + sum(sl_vals), 1e-6)

        if float(qqq_px[i]) >= run_ath_px:
            run_ath_px = float(qqq_px[i])
            run_ath_idx = i

        if mode == "static_drift" and tot_w > 1e-8:
            cur_sl_w = sum(sl_vals) / max(cur_eq, 1e-6)
            if abs(cur_sl_w - tot_w) >= 0.025 or abs((core_val / cur_eq) - 1.0) >= 0.04:
                pending_drift_rebal = True

        if not is_static:
            for k in range(n_sl):
                if sl_in_qqq[k] and not sl_pending_to_hedge[k] and i > sl_rot_idx[k]:
                    trig_rel = False
                    if mode == "rot_ath":
                        trig_rel = bool(float(qqq_px[i]) >= sl_saved_ath[k])
                    elif mode == "rot_60td":
                        trig_rel = bool((i - sl_rot_idx[k]) >= reload_td)
                    elif mode == "rot_vix20":
                        trig_rel = bool((not lockout_active_by_day[i]) and float(vix[i]) <= reload_vix)
                    elif mode == "rot_vix20_or_60td":
                        trig_rel = bool(
                            ((i - sl_rot_idx[k]) >= reload_td)
                            or ((not lockout_active_by_day[i]) and float(vix[i]) <= reload_vix)
                        )
                    if trig_rel:
                        sl_pending_to_hedge[k] = True

            if i in tp_day_info:
                t_pk = run_ath_idx
                qqq_dd = float(qqq_px[i]) / max(float(qqq_px[t_pk]), 1e-6) - 1.0
                dd_ok = bool(qqq_dd <= dd_thresh)
                for k in range(n_sl):
                    if sl_in_qqq[k]:
                        continue
                    s_name, s_w, r_a, px_a = sleeves[k]
                    a_ret = float(px_a[i]) / max(float(px_a[t_pk]), 1e-6) - 1.0
                    lo_c = t_pk + 1 if (i - t_pk) >= 5 else max(1, i - 19)
                    rq_seg = r_qqq[lo_c : i + 1]
                    ra_seg = r_a[lo_c : i + 1]
                    corr_val = pearson_corr(rq_seg, ra_seg)
                    if neg_rule == "strict_both":
                        cond = bool(dd_ok and (a_ret > 0.0) and (corr_val < 0.0))
                    else:
                        cond = bool(dd_ok and (corr_val < 0.0))
                    reason_tag = "ROTATE"
                    if not cond:
                        if not dd_ok:
                            reason_tag = "HOLD_DD_SHALLOW"
                        elif corr_val >= 0.0:
                            reason_tag = "HOLD_POS_CORR"
                        else:
                            reason_tag = "HOLD_CTA_NEG_RET"
                    ev = {
                        "tp_date": dates[i],
                        "ath_date": dates[t_pk],
                        "sleeve": s_name,
                        "qqq_dd_pct": round(float(qqq_dd * 100.0), 2),
                        "asset_ret_pct": round(float(a_ret * 100.0), 2),
                        "corr": round(float(corr_val), 3),
                        "vix_eod": round(float(vix[i]), 2),
                        "dd_ok": dd_ok,
                        "decision": "ROTATE" if cond else "HOLD",
                        "reason": reason_tag,
                    }
                    rot_log.append(ev)
                    if cond:
                        sl_pending_to_qqq[k] = True
                        sl_saved_ath[k] = float(run_ath_px)
                        sl_meta[k] = ev

    yrs = (dt_objs[-1] - dt_objs[0]).days / 365.25
    mean_eq = sum(eq) / max(n, 1)
    return {
        "nav": eq,
        "peak_ltv_pct": round(max(ltv) * 100.0, 2),
        "avg_ltv_pct": round((sum(ltv) / max(n, 1)) * 100.0, 2),
        "min_eq_ratio_pct": round(min(1.0 - x for x in ltv) * 100.0, 2),
        "ann_interest_pct_nav": round(
            (tot_interest / max(mean_eq, 1.0)) / max(yrs, 0.1) * 100.0, 3
        ),
        "tot_interest_usd": round(float(tot_interest), 2),
        "ann_turnover_pct": round((tot_turnover / max(yrs, 0.1)) * 100.0, 1),
        "rebal_cnt": int(rebal_cnt),
        "rot_cnt": int(sum(1 for e in rot_log if e["decision"] == "ROTATE")),
        "rot_log": rot_log,
        "end_in_qqq": bool(any(sl_in_qqq)),
        "end_loan_usd": round(float(loan), 2),
        "end_ltv_pct": round(float(ltv[-1]) * 100.0, 2),
    }


def _sample_std(vals: Sequence[float]) -> float:
    m = len(vals)
    if m < 2:
        return 0.0
    mu = sum(vals) / m
    return math.sqrt(sum((x - mu) ** 2 for x in vals) / (m - 1))


def _max_dd(vals: Sequence[float]) -> float:
    if not vals:
        return 0.0
    pk = vals[0]
    mdd = 0.0
    for v in vals:
        if v > pk:
            pk = v
        dd = v / pk - 1.0
        if dd < mdd:
            mdd = dd
    return mdd


def calc_perf(
    dates: Sequence[str],
    nav: Sequence[float],
    bench_nav: Sequence[float],
    rf_arr: Sequence[float],
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    dt0 = datetime.date.fromisoformat(dates[0])
    dt1 = datetime.date.fromisoformat(dates[-1])
    yrs = (dt1 - dt0).days / 365.25
    tot = float(nav[-1] / nav[0] - 1.0)
    cagr = (nav[-1] / nav[0]) ** (1.0 / max(yrs, 0.1)) - 1.0
    bh_cagr = (bench_nav[-1] / bench_nav[0]) ** (1.0 / max(yrs, 0.1)) - 1.0
    mdd = _max_dd(nav)
    calmar = cagr / abs(mdd) if mdd < -1e-6 else 0.0

    rets = [nav[j] / nav[j - 1] - 1.0 for j in range(1, len(nav))]
    ex = [rets[j - 1] - rf_arr[j] / 252.0 for j in range(1, len(nav))]
    vol = _sample_std(rets) * math.sqrt(252.0)
    std_ex = _sample_std(ex)
    mean_ex = sum(ex) / max(len(ex), 1)
    sharpe = (mean_ex / std_ex * math.sqrt(252.0)) if std_ex > 1e-12 else 0.0
    dn = [x for x in ex if x < 0.0]
    std_dn = _sample_std(dn) if len(dn) > 2 else 0.0
    sortino = (mean_ex / std_dn * math.sqrt(252.0)) if std_dn > 1e-12 else 0.0

    yearly = {}
    for ys in sorted(set(d[:4] for d in dates)):
        idxs = [i for i, d in enumerate(dates) if d.startswith(ys)]
        if len(idxs) < 5:
            continue
        i0 = max(0, idxs[0] - 1)
        i1 = idxs[-1]
        sub = nav[i0 : i1 + 1]
        sub_b = bench_nav[i0 : i1 + 1]
        r_s = (sub[-1] / sub[0] - 1.0) * 100.0
        r_b = (sub_b[-1] / sub_b[0] - 1.0) * 100.0
        mdd_y = _max_dd(sub) * 100.0
        yearly[ys] = {
            "ret_pct": round(float(r_s), 2),
            "bench_ret_pct": round(float(r_b), 2),
            "alpha_pp": round(float(r_s - r_b), 2),
            "mdd_pct": round(float(mdd_y), 2),
        }

    crises = {}
    for cid, (s_d, e_d) in {
        "2022_BEAR": ("2021-11-19", "2022-12-30"),
        "2024_YEN": ("2024-07-10", "2024-09-10"),
        "2025_TAR": ("2025-02-19", "2025-05-15"),
        "2020_COVID": ("2020-02-12", "2020-04-30"),
    }.items():
        idxs = [i for i, d in enumerate(dates) if s_d <= d <= e_d]
        if len(idxs) < 5:
            continue
        sub = [nav[i] for i in idxs]
        sub_b = [bench_nav[i] for i in idxs]
        crises[cid] = {
            "ret_pct": round(float(sub[-1] / sub[0] - 1.0) * 100.0, 2),
            "mdd_pct": round(_max_dd(sub) * 100.0, 2),
            "bench_mdd_pct": round(_max_dd(sub_b) * 100.0, 2),
        }

    out: dict[str, Any] = {
        "start_date": dates[0],
        "end_date": dates[-1],
        "years": round(yrs, 2),
        "final_nav": round(float(nav[-1]), 2),
        "tot_ret_pct": round(tot * 100.0, 2),
        "cagr_pct": round(cagr * 100.0, 2),
        "excess_cagr_pp": round((cagr - bh_cagr) * 100.0, 2),
        "vol_pct": round(vol * 100.0, 2),
        "mdd_pct": round(mdd * 100.0, 2),
        "calmar": round(calmar, 3),
        "sharpe": round(sharpe, 3),
        "sortino": round(sortino, 3),
        "yearly": yearly,
        "crises": crises,
    }
    if extra:
        for k, v in extra.items():
            if k != "nav":
                out[k] = v
    return out


def build_tp_and_lockout(
    dates: Sequence[str],
    vix_arr: Sequence[float],
    vr_arr: Sequence[float],
    episodes: list[dict[str, Any]],
) -> tuple[dict[int, dict[str, Any]], list[bool]]:
    n = len(dates)
    d_idx = {d: i for i, d in enumerate(dates)}
    tp_day_info: dict[int, dict[str, Any]] = {}
    lockout_mask = [False] * n
    for ep in episodes:
        s_d = ep.get("start_signal_date")
        s_i = d_idx.get(s_d) if s_d else ep.get("start_idx")
        if s_i is None or s_i < 0 or s_i >= n:
            continue
        u_d = ep.get("unlock_eod_date")
        u_i = d_idx[u_d] if (u_d and u_d in d_idx) else None
        tp_day_info[int(s_i)] = {
            "start_date": dates[int(s_i)],
            "unlock_date": u_d,
            "unlock_idx": u_i,
            "vix": round(float(vix_arr[int(s_i)]), 2),
            "vr": round(float(vr_arr[int(s_i)]), 2),
        }
        for j in range(int(s_i), u_i if u_i is not None else n):
            lockout_mask[j] = True
    return tp_day_info, lockout_mask


def build_seed_and_verify(
    dashboard_path: Path = DEFAULT_DASHBOARD_JSON,
    output_gz_path: Path = DEFAULT_OUTPUT_GZ,
    golden_ref_path: Path = DEFAULT_GOLDEN_REF,
) -> dict[str, Any]:
    t0 = time.time()
    print(f"[kmlm20] Loading locked 1.00x Crisis Observatory artifact: {dashboard_path}")
    dash = json.loads(dashboard_path.read_text(encoding="utf-8"))
    eval_bars = _unpack_table(dash["m7_eval_bars"])
    sigs_m0on = _unpack_table(dash["m7_signals"]["m0on"])
    coeffs = [float(x) for x in dash["opra_90dte_poly3_coeffs_desc"]]

    bco_mod = _load_bco_module()
    store = roc.HybridRealOptionChainStore()

    print("[kmlm20] Simulating exact float64 Core NAVs (M7G_Graded & Core3_Adaptive, Limit & Ask/Bid)...")
    m7g_lim = m7e.simulate_m7_strategy(
        eval_bars, coeffs, bco_mod, "M7G_Graded", sigs_m0on,
        put_otm="otm15", m7_tp_mode="standard", roll_mode="adaptive_120_90",
        m0_enabled=True, cc_mode="cc_off", sp_mode="sp_off", wc_mode="wc_reclaim_30d_d35",
        real_store=store, fill_mode="ibkr_limit",
    )
    m7g_ab = m7e.simulate_m7_strategy(
        eval_bars, coeffs, bco_mod, "M7G_Graded", sigs_m0on,
        put_otm="otm15", m7_tp_mode="standard", roll_mode="adaptive_120_90",
        m0_enabled=True, cc_mode="cc_off", sp_mode="sp_off", wc_mode="wc_reclaim_30d_d35",
        real_store=store, fill_mode="ask_bid",
    )
    c3_lim = m7e.simulate_m7_strategy(
        eval_bars, coeffs, bco_mod, "Core3_Adaptive", sigs_m0on,
        put_otm="otm15", m7_tp_mode="standard", roll_mode="adaptive_120_90",
        m0_enabled=True, cc_mode="cc_off", sp_mode="sp_off", wc_mode="wc_reclaim_30d_d35",
        real_store=store, fill_mode="ibkr_limit",
    )
    c3_ab = m7e.simulate_m7_strategy(
        eval_bars, coeffs, bco_mod, "Core3_Adaptive", sigs_m0on,
        put_otm="otm15", m7_tp_mode="standard", roll_mode="adaptive_120_90",
        m0_enabled=True, cc_mode="cc_off", sp_mode="sp_off", wc_mode="wc_reclaim_30d_d35",
        real_store=store, fill_mode="ask_bid",
    )

    all_dates = [str(r["date"]) for r in eval_bars]
    idx_end_11 = all_dates.index("2025-12-15")
    n11 = idx_end_11 + 1
    d11 = all_dates[:n11]
    assert d11[0] == "2015-01-02" and d11[-1] == "2025-12-15" and n11 == 2755

    core_lim_11 = [float(x) for x in m7g_lim["nav"][:n11]]
    core_ab_11 = [float(x) for x in m7g_ab["nav"][:n11]]
    c3_lim_11 = [float(x) for x in c3_lim["nav"][:n11]]
    c3_ab_11 = [float(x) for x in c3_ab["nav"][:n11]]

    assert round(core_lim_11[-1], 2) == 1740267.20, f"Got {core_lim_11[-1]}"
    assert round(core_ab_11[-1], 2) == 1688420.02, f"Got {core_ab_11[-1]}"
    assert round(c3_lim_11[-1], 2) == 1514395.10, f"Got {c3_lim_11[-1]}"
    assert round(c3_ab_11[-1], 2) == 1478048.67, f"Got {c3_ab_11[-1]}"

    vix_11 = [float(eval_bars[i]["vix"]) for i in range(n11)]
    vr_11 = [float(eval_bars[i]["vix_ratio"]) for i in range(n11)]

    eps_m7g_11 = [
        ep for ep in m7g_lim["lockout_state_eod"]["episodes"]
        if str(ep.get("start_signal_date", "")) <= "2025-12-15"
    ]
    eps_c3_11 = [
        ep for ep in c3_lim["lockout_state_eod"]["episodes"]
        if str(ep.get("start_signal_date", "")) <= "2025-12-15"
    ]
    tp_m7g_11, lk_m7g_11 = build_tp_and_lockout(d11, vix_11, vr_11, eps_m7g_11)
    assert len(tp_m7g_11) == 6, f"Expected 6 historical TP episodes, got {len(tp_m7g_11)}"

    print("[kmlm20] Fetching Yahoo Finance Adjusted Close (QQQ, KMLM, DBMF, AQMIX, ^VIX) & NY Fed EFFR...")
    ts_start = int(datetime.datetime(2014, 1, 1, tzinfo=datetime.timezone.utc).timestamp())
    ts_end = int((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=2)).timestamp())
    yf = {sym: fetch_yahoo_adjclose(sym, ts_start, ts_end) for sym in ("QQQ", "KMLM", "DBMF", "AQMIX", "^VIX")}
    effr_raw = fetch_nyfed_effr("2015-01-01", "2026-12-31")

    px_qqq_11 = [float(x) for x in reindex_ffill(yf["QQQ"], d11, bfill=True)]  # type: ignore[arg-type]
    px_km_raw_11 = reindex_ffill(yf["KMLM"], d11, bfill=False)
    px_aq_11 = [float(x) for x in reindex_ffill(yf["AQMIX"], d11, bfill=True)]  # type: ignore[arg-type]
    effr_11 = [float(x) for x in reindex_ffill(effr_raw, d11, bfill=True)]  # type: ignore[arg-type]

    splice_km = d11.index("2020-12-03")
    r_aq_11 = pct_change_zero_first(px_aq_11)
    r_km_raw = pct_change_zero_first(px_km_raw_11)
    r_km_11 = [r_aq_11[i] if i < splice_km else r_km_raw[i] for i in range(n11)]
    px_km_11: list[float] = []
    acc_km = 100.0
    for r in r_km_11:
        acc_km *= 1.0 + r
        px_km_11.append(acc_km)

    r_qqq_11 = pct_change_zero_first(px_qqq_11)
    r_lim_11 = pct_change_zero_first(core_lim_11)
    r_ab_11 = pct_change_zero_first(core_ab_11)
    bh_11 = [INITIAL_CAPITAL * (x / px_qqq_11[0]) for x in px_qqq_11]

    # 5-Year Pure Live KMLM Window (2020-12-02 -> 2025-12-15, ZERO proxy, $200,000 start)
    i5 = d11.index("2020-12-02")
    d5 = d11[i5:]
    r_lim_5 = list(r_lim_11[i5:]); r_lim_5[0] = 0.0
    r_ab_5 = list(r_ab_11[i5:]); r_ab_5[0] = 0.0
    r_qqq_5 = list(r_qqq_11[i5:]); r_qqq_5[0] = 0.0
    px_qqq_5 = list(px_qqq_11[i5:])
    r_km_5 = list(r_km_raw[i5:]); r_km_5[0] = 0.0
    px_km_5 = [float(x) for x in px_km_raw_11[i5:]]  # type: ignore[arg-type]
    effr_5 = list(effr_11[i5:])
    vix_5 = list(vix_11[i5:])
    bh_5 = [INITIAL_CAPITAL * (x / px_qqq_5[0]) for x in px_qqq_5]
    tp5 = {k - i5: v for k, v in tp_m7g_11.items() if k >= i5}
    lk5 = lk_m7g_11[i5:]

    sl11_20 = [("KMLM", 0.20, r_km_11, px_km_11)]
    sl5_20 = [("KMLM", 0.20, r_km_5, px_km_5)]

    modes = [
        ("static_drift", "Static_Drift250bp"),
        ("static_qtr", "Static_Qtr"),
        ("rot_vix20", "Reload_VIX20_5D"),
        ("rot_60td", "Reload_60TD"),
        ("rot_vix20_or_60td", "Reload_VIX20_or_60TD"),
        ("rot_ath", "Reload_ATH"),
    ]

    kmlm20_res: dict[str, Any] = {}
    for ftag, spr in (("Box_35bp", 0.0035), ("IBKR_150bp", 0.0150)):
        kmlm20_res[ftag] = {}
        for mcode, mlbl in modes:
            s11 = sim_pure_cta_blueprint(
                d11, r_lim_11, r_qqq_11, px_qqq_11, sl11_20, effr_11, vix_11, spr,
                tp_m7g_11, lk_m7g_11, mode=mcode, neg_rule="strict_both", dd_thresh=-0.12
            )
            s11_ab = sim_pure_cta_blueprint(
                d11, r_ab_11, r_qqq_11, px_qqq_11, sl11_20, effr_11, vix_11, spr,
                tp_m7g_11, lk_m7g_11, mode=mcode, neg_rule="strict_both", dd_thresh=-0.12
            )
            p11 = calc_perf(
                d11, s11["nav"], bh_11, effr_11,
                extra={**{k: v for k, v in s11.items() if k != "nav"}, "ab_final_nav": round(float(s11_ab["nav"][-1]), 2)},
            )
            s5 = sim_pure_cta_blueprint(
                d5, r_lim_5, r_qqq_5, px_qqq_5, sl5_20, effr_5, vix_5, spr,
                tp5, lk5, mode=mcode, neg_rule="strict_both", dd_thresh=-0.12
            )
            s5_ab = sim_pure_cta_blueprint(
                d5, r_ab_5, r_qqq_5, px_qqq_5, sl5_20, effr_5, vix_5, spr,
                tp5, lk5, mode=mcode, neg_rule="strict_both", dd_thresh=-0.12
            )
            p5 = calc_perf(
                d5, s5["nav"], bh_5, effr_5,
                extra={**{k: v for k, v in s5.items() if k != "nav"}, "ab_final_nav": round(float(s5_ab["nav"][-1]), 2)},
            )
            kmlm20_res[ftag][mlbl] = {"11yr": p11, "5yr": p5}

    # Live 2026 YTD (2025-12-31 -> latest)
    d26 = [d for d in yf["QQQ"].keys() if d >= "2025-12-31"]
    px_qqq_26 = [float(x) for x in reindex_ffill(yf["QQQ"], d26, bfill=True)]  # type: ignore[arg-type]
    px_km_26 = [float(x) for x in reindex_ffill(yf["KMLM"], d26, bfill=True)]  # type: ignore[arg-type]
    px_db_26 = [float(x) for x in reindex_ffill(yf["DBMF"], d26, bfill=True)]  # type: ignore[arg-type]
    vix26 = [float(x) for x in reindex_ffill(yf["^VIX"], d26, bfill=True)]  # type: ignore[arg-type]
    ef26 = [float(x) for x in reindex_ffill(effr_raw, d26, bfill=True)]  # type: ignore[arg-type]

    rq26 = pct_change_zero_first(px_qqq_26)
    rk26 = pct_change_zero_first(px_km_26)
    idx_o6 = d26.index("2026-10-06")
    idx_n20 = d26.index("2026-11-20")

    qqq26_ytd = (px_qqq_26[-1] / px_qqq_26[0] - 1.0) * 100.0
    kmlm26_ytd = (px_km_26[-1] / px_km_26[0] - 1.0) * 100.0
    qqq26_q4 = (px_qqq_26[idx_n20] / px_qqq_26[idx_o6] - 1.0) * 100.0
    kmlm26_q4 = (px_km_26[idx_n20] / px_km_26[idx_o6] - 1.0) * 100.0
    corr26_km_q4 = pearson_corr(rq26[idx_o6 + 1 : idx_n20 + 1], rk26[idx_o6 + 1 : idx_n20 + 1])

    live26_k20: dict[str, Any] = {}
    for ftag, spr in (("Box_35bp", 0.0035), ("IBKR_150bp", 0.0150)):
        s26 = sim_pure_cta_blueprint(
            d26, rq26, rq26, px_qqq_26, [("KMLM", 0.20, rk26, px_km_26)],
            ef26, vix26, spr, {}, [False] * len(d26), mode="static_qtr"
        )
        n26 = s26["nav"]
        ytd = (float(n26[-1]) / float(n26[0]) - 1.0) * 100.0
        mdd26 = _max_dd(n26) * 100.0
        q4 = (float(n26[idx_n20]) / float(n26[idx_o6]) - 1.0) * 100.0
        live26_k20[ftag] = {
            "ytd_pct": round(ytd, 2),
            "alpha_pp": round(ytd - qqq26_ytd, 2),
            "q4_crash_pct": round(q4, 2),
            "mdd_pct": round(mdd26, 2),
            "peak_ltv_pct": s26["peak_ltv_pct"],
            "ann_interest_pct_nav": s26["ann_interest_pct_nav"],
        }

    # Strict $0.00 Parity Verification against Golden Reference JSON!
    if golden_ref_path.exists():
        ref = json.loads(golden_ref_path.read_text(encoding="utf-8"))
        ref_bx = ref["matrix"]["KMLM_20"]["Box_35bp"]["Reload_VIX20_5D"]
        ref_ib = ref["matrix"]["KMLM_20"]["IBKR_150bp"]["Reload_VIX20_5D"]
        got_bx = kmlm20_res["Box_35bp"]["Reload_VIX20_5D"]
        got_ib = kmlm20_res["IBKR_150bp"]["Reload_VIX20_5D"]

        checks = [
            ("11Y Box Limit Final NAV", got_bx["11yr"]["final_nav"], ref_bx["11yr"]["final_nav"], 1785222.38),
            ("11Y Box Ask/Bid Final NAV", got_bx["11yr"]["ab_final_nav"], ref_bx["11yr"]["ab_final_nav"], 1732487.07),
            ("11Y IBKR Limit Final NAV", got_ib["11yr"]["final_nav"], ref_ib["11yr"]["final_nav"], 1741934.61),
            ("11Y IBKR Ask/Bid Final NAV", got_ib["11yr"]["ab_final_nav"], ref_ib["11yr"]["ab_final_nav"], 1690449.50),
            ("5Y Box Limit Final NAV", got_bx["5yr"]["final_nav"], ref_bx["5yr"]["final_nav"], 570416.64),
            ("5Y Box Ask/Bid Final NAV", got_bx["5yr"]["ab_final_nav"], ref_bx["5yr"]["ab_final_nav"], 566429.07),
            ("5Y IBKR Limit Final NAV", got_ib["5yr"]["final_nav"], ref_ib["5yr"]["final_nav"], 564011.73),
            ("5Y IBKR Ask/Bid Final NAV", got_ib["5yr"]["ab_final_nav"], ref_ib["5yr"]["ab_final_nav"], 560066.76),
            ("11Y Box Total Interest", got_bx["11yr"]["tot_interest_usd"], ref_bx["11yr"]["tot_interest_usd"], 44489.89),
            ("11Y IBKR Total Interest", got_ib["11yr"]["tot_interest_usd"], ref_ib["11yr"]["tot_interest_usd"], 59455.66),
            ("5Y Box Total Interest", got_bx["5yr"]["tot_interest_usd"], ref_bx["5yr"]["tot_interest_usd"], 12501.87),
            ("5Y IBKR Total Interest", got_ib["5yr"]["tot_interest_usd"], ref_ib["5yr"]["tot_interest_usd"], 16114.89),
        ]
        for label, got_v, ref_v, hard_v in checks:
            diff_v = round(got_v - hard_v, 2)
            assert abs(diff_v) <= 1.00, f"PARITY MISMATCH on {label}: got={got_v}, ref={ref_v}, expected={hard_v}"
            print(f"  [PASS diff=${diff_v:+.2f}] {label:28s}: ${got_v:>12,.2f} (ref ${hard_v:>12,.2f})")

        assert abs(round(corr26_km_q4, 3) - 0.092) <= 0.002, f"Expected 2026 Q4 Corr +0.092, got {corr26_km_q4}"
        print(
            f"  [PASS LIVE ] 2026 YTD ({d26[0]} -> {d26[-1]}): QQQ={qqq26_ytd:+.2f}%, KMLM={kmlm26_ytd:+.2f}%, "
            f"Box20={live26_k20['Box_35bp']['ytd_pct']:+.2f}% ({live26_k20['Box_35bp']['alpha_pp']:+.2f}pp), "
            f"Q4 Corr={corr26_km_q4:+.3f} -> HOLD_POS_CORR"
        )

    # Full series aligned with all_dates (2015-01-02 -> 2026-11-20)
    full_qqq = [float(x) for x in reindex_ffill(yf["QQQ"], all_dates, bfill=True)]  # type: ignore[arg-type]
    full_km = [float(x) for x in reindex_ffill(yf["KMLM"], all_dates, bfill=True)]  # type: ignore[arg-type]
    full_ef = [float(x) for x in reindex_ffill(effr_raw, all_dates, bfill=True)]  # type: ignore[arg-type]

    # Build 7-episode audit table
    log_vix20 = kmlm20_res["Box_35bp"]["Reload_VIX20_5D"]["11yr"]["rot_log"]
    log_60td = kmlm20_res["Box_35bp"]["Reload_60TD"]["11yr"]["rot_log"]
    log_ath = kmlm20_res["Box_35bp"]["Reload_ATH"]["11yr"]["rot_log"]
    episodes_7 = []
    for ev_v, ev_60, ev_a in zip(log_vix20, log_60td, log_ath):
        episodes_7.append(
            {
                **ev_v,
                "reload_vix20_date": ev_v.get("reload_date", "-"),
                "reload_vix20_td": ev_v.get("hold_td", 0),
                "reload_vix20_spread_pp": ev_v.get("spread_pp", 0.0),
                "reload_vix20_alpha_usd": ev_v.get("est_alpha_usd", 0.0),
                "reload_60td_date": ev_60.get("reload_date", "-"),
                "reload_60td_spread_pp": ev_60.get("spread_pp", 0.0),
                "reload_60td_alpha_usd": ev_60.get("est_alpha_usd", 0.0),
                "reload_ath_date": ev_a.get("reload_date", "-"),
                "reload_ath_spread_pp": ev_a.get("spread_pp", 0.0),
                "reload_ath_alpha_usd": ev_a.get("est_alpha_usd", 0.0),
            }
        )
    episodes_7.append(
        {
            "tp_date": "2026-11-20",
            "ath_date": "2026-10-06",
            "sleeve": "KMLM (Live)",
            "qqq_dd_pct": round(float(qqq26_q4), 2),
            "asset_ret_pct": round(float(kmlm26_q4), 2),
            "corr": round(corr26_km_q4, 3),
            "vix_eod": round(float(vix26[idx_n20]), 2),
            "dd_ok": True,
            "decision": "HOLD",
            "reason": "HOLD_POS_CORR",
            "is_live_episode": True,
            "reload_vix20_date": "-",
            "reload_vix20_td": 0,
            "reload_vix20_spread_pp": 0.0,
            "reload_vix20_alpha_usd": 0.0,
            "reload_60td_date": "-",
            "reload_60td_spread_pp": 0.0,
            "reload_60td_alpha_usd": 0.0,
            "reload_ath_date": "-",
            "reload_ath_spread_pp": 0.0,
            "reload_ath_alpha_usd": 0.0,
        }
    )

    effr_dates_sorted = list(effr_raw.keys())
    effr_latest_date = effr_dates_sorted[-1]
    effr_latest_rate_pct = round(float(effr_raw[effr_latest_date]) * 100.0, 2)

    seed_doc = {
        "version": "crisis-observatory-kmlm20-v1",
        "status": "HYPOTHESIS",
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "initial_capital_usd": INITIAL_CAPITAL,
        "rebal_fee": REBAL_FEE,
        "kmlm_weight": 0.20,
        "gross_leverage": 1.20,
        "fin_spreads": {"box_35bp": 0.0035, "ibkr_150bp": 0.0150},
        "windows": {
            "window_11yr": "2015-01-02 -> 2025-12-15",
            "window_5yr_live": "2020-12-02 -> 2025-12-15",
            "splice_kmlm_date": "2020-12-03",
            "splice_note_en": "Pre-2020-12-03 stitched with AQR Managed Futures (AQMIX) daily total return; 2020-12-03 onward 100% live KMLM ETF.",
            "splice_note_zh": "2020-12-03 KMLM 上市前采用 AQR 管理期货基金（AQMIX）真实日总回报拼接；2020-12-03 起为 100% KMLM 实盘净值（无任何代换）。",
        },
        "effr_seed_latest": {
            "effective_date": effr_latest_date,
            "effr_pct": effr_latest_rate_pct,
            "box_rate_pct": round(effr_latest_rate_pct + 0.35, 2),
            "ibkr_rate_pct": round(effr_latest_rate_pct + 1.50, 2),
        },
        "d11": {
            "dates": d11,
            "m7g_lim_nav": core_lim_11,
            "m7g_ab_nav": core_ab_11,
            "c3_lim_nav": c3_lim_11,
            "c3_ab_nav": c3_ab_11,
            "qqq_adj": px_qqq_11,
            "kmlm_adj": px_km_raw_11,
            "aqmix_adj": px_aq_11,
            "effr": effr_11,
            "vix": vix_11,
            "vr": vr_11,
            "m7g_lockout_episodes": eps_m7g_11,
            "c3_lockout_episodes": eps_c3_11,
        },
        "post_d11_eval": {
            "dates": all_dates[n11:],
            "m7g_lim_nav": [float(x) for x in m7g_lim["nav"][n11:]],
            "m7g_ab_nav": [float(x) for x in m7g_ab["nav"][n11:]],
            "c3_lim_nav": [float(x) for x in c3_lim["nav"][n11:]],
            "c3_ab_nav": [float(x) for x in c3_ab["nav"][n11:]],
            "qqq_adj": full_qqq[n11:],
            "kmlm_adj": full_km[n11:],
            "effr": full_ef[n11:],
            "vix": [float(eval_bars[i]["vix"]) for i in range(n11, len(eval_bars))],
            "vr": [float(eval_bars[i]["vix_ratio"]) for i in range(n11, len(eval_bars))],
            "m7g_all_lockout_episodes": m7g_lim["lockout_state_eod"]["episodes"],
            "c3_all_lockout_episodes": c3_lim["lockout_state_eod"]["episodes"],
        },
        "tail_2026_seed": {
            "dates": d26,
            "qqq_adj": px_qqq_26,
            "kmlm_adj": px_km_26,
            "dbmf_adj": px_db_26,
            "vix": vix26,
            "effr": ef26,
        },
        "episodes_7_historical_and_q4": episodes_7,
    }

    output_gz_path.parent.mkdir(parents=True, exist_ok=True)
    raw_bytes = json.dumps(seed_doc, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    with gzip.open(output_gz_path, "wb", compresslevel=9) as gz:
        gz.write(raw_bytes)
    gz_kb = output_gz_path.stat().st_size / 1024.0
    print(
        f"[kmlm20] Wrote {output_gz_path} ({gz_kb:.1f} KB gzipped, {len(raw_bytes)/1024.0:.1f} KB raw) in {time.time() - t0:.1f}s"
    )
    return seed_doc


def main() -> None:
    parser = argparse.ArgumentParser(description="Build Crisis Observatory 1.20x +20% KMLM Hypothesis seed.")
    parser.add_argument("--dashboard", type=Path, default=DEFAULT_DASHBOARD_JSON)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT_GZ)
    parser.add_argument("--golden-ref", type=Path, default=DEFAULT_GOLDEN_REF)
    args = parser.parse_args()
    build_seed_and_verify(args.dashboard, args.output, args.golden_ref)


if __name__ == "__main__":
    main()
