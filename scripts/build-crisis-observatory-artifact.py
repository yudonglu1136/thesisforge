#!/usr/bin/env python3
"""Build canonical zero-lookahead Crisis Observatory artifact for ThesisForge Discover.

Reproduces 100% bit-for-bit the audited QQQ 6 Druckenmiller Crisis Lights x US Liquid
Common-Stock A-D Line Top-Divergence x 1st-Tranche Naked Put + Subsequent Zero-Cost
Collar + VIX/VIX3M >= 1.10 Take-Profit + 5-Light Slow-Bear Shield engine
(2015-01-02 through latest official market close, $200,000 initial capital with DRIP).

Strict Hygiene:
  - Runs purely on Python stdlib + optional duckdb inside .venv-fact-os/bin/python
    (zero numpy/pandas/scipy/yfinance runtime dependency).
  - Strict EOD signal on day t -> executed at day t+1 Open (zero lookahead).
  - OPRA 53,347-print 90-DTE skew polynomial, 2.5% per-leg option slippage,
    3 bps stock rebalance fee, exact 4-factor pathwise convexity identity.
  - Zero ASCII tilde (chr(126)), zero internal DB names in user-facing text.
"""
from __future__ import annotations

import argparse
import bisect
import datetime
import gzip
import json
import math
import statistics
from pathlib import Path
from typing import Any

try:
    import duckdb
except ImportError:
    duckdb = None

ROOT_DIR = Path(__file__).resolve().parent.parent
SEED_GZ = ROOT_DIR / "server" / "config" / "crisis-observatory-seed-inputs.json.gz"
DEFAULT_OUT = ROOT_DIR / "server" / "config" / "crisis-observatory-dashboard.json"
DEFAULT_FACT_ROOT = ROOT_DIR / "data" / "fact_os"

ARTIFACT_VERSION = "crisis-observatory-v2"
START_DATE = "2015-01-02"
INITIAL_CAPITAL = 200_000.0
DEFAULT_SLIPPAGE = 0.025
STOCK_REBAL_FEE = 0.0003
DEFAULT_TP_MODE = "layered_itm"

TP_MODE_SPECS: list[dict[str, Any]] = [
    {
        "id": "layered_itm",
        "label_en": "Layered ITM (Rec.)",
        "label_zh": "分层实值（推荐）",
        "short_en": "Layered ITM",
        "short_zh": "分层实值",
        "summary_en": "Collar exits immediately at VIX/3M >= 1.10 to unlock Call cap; Naked Put ignores shallow inversions until strictly ITM (QQQ <= K_P); + 5x slow-bear lock (DTE <= 45).",
        "summary_zh": "次仓领口见 VIX/3M >= 1.10 立刻止盈解封卖 Call；首仓裸 Put 浅跌无视倒挂，必须跌破自身行权价 (QQQ <= K_P) 进入实值才平；叠加后半程 DTE <= 45 & Put >= 5x 慢熊锁利。",
    },
    {
        "id": "standard_dual",
        "label_en": "Standard 1.10",
        "label_zh": "标准双轨 1.10",
        "short_en": "Standard 1.10",
        "short_zh": "标准 1.10",
        "summary_en": "Both slots exit at next Open whenever VIX/3M >= 1.10 panic inversion triggers, or on second-half 5x slow-bear lock (DTE <= 45).",
        "summary_zh": "双槽统一：只要触发 VIX/3M >= 1.10 恐慌倒挂即次日开盘止盈抄底，或后半程 DTE <= 45 且 Put >= 5x 慢熊锁利。",
    },
    {
        "id": "both_4x",
        "label_en": "Deep 4x Both",
        "label_zh": "两槽深度 4x",
        "short_en": "Deep 4x",
        "short_zh": "两槽 4x",
        "summary_en": "Both slots require VIX/3M >= 1.10 AND Put Bid >= 4x entry cost (filters shallow spikes like 2018-10 and 2026-11), plus 5x slow-bear lock (DTE <= 45).",
        "summary_zh": "双槽统一：必须同时满足 VIX/3M >= 1.10 且 Put 涨超 4 倍成本才认恐慌止盈（过滤 2018-10 与 2026-11 浅跌假倒挂），叠加后半程 DTE <= 45 & Put >= 5x 慢熊锁利。",
    },
]


def _norm_cdf(x: float) -> float:
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def _polyval_desc(coeffs: list[float], x: float) -> float:
    acc = 0.0
    for c in coeffs:
        acc = acc * x + c
    return acc


def _clip(v: float, lo: float, hi: float) -> float:
    return lo if v < lo else (hi if v > hi else v)


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


def eval_skew_iv(
    S: float, K: float, T: float, r: float, q: float, vxn_pct: float, poly_coeffs: list[float]
) -> float:
    t_eff = max(T, 1.0 / 365.0)
    fwd = S * math.exp((r - q) * t_eff)
    log_m = _clip(math.log(K / fwd), -0.22, 0.20)
    ratio = _polyval_desc(poly_coeffs, log_m)
    ratio = max(0.72, min(1.55, ratio))
    return max(0.06, (vxn_pct / 100.0) * ratio)


def solve_zero_cost_call_strike(
    S: float,
    k_put: float,
    T: float,
    r: float,
    q: float,
    vxn_pct: float,
    poly_coeffs: list[float],
    slip: float = DEFAULT_SLIPPAGE,
) -> float:
    sigma_p = eval_skew_iv(S, k_put, T, r, q, vxn_pct, poly_coeffs)
    put_ask = bsm_price(S, k_put, T, r, q, sigma_p, "put") * (1.0 + slip)

    def obj(k_c: float) -> float:
        sigma_c = eval_skew_iv(S, k_c, T, r, q, vxn_pct, poly_coeffs)
        call_bid = bsm_price(S, k_c, T, r, q, sigma_c, "call") * (1.0 - slip)
        return call_bid - put_ask

    lo, hi = S * 1.0005, S * 1.55
    if obj(lo) <= 0.0:
        return lo
    if obj(hi) >= 0.0:
        return hi
    for _ in range(44):
        mid = 0.5 * (lo + hi)
        if obj(mid) > 0.0:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def decompose_tranche_convexity(
    tranche_type: str,
    s0: float,
    s1: float,
    kp: float,
    kc: float | None,
    t0: float,
    t1: float,
    r0: float,
    r1: float,
    q0: float,
    q1: float,
    vxn0: float,
    vxn1: float,
    coeffs: list[float],
    actual_net_pnl_sh: float,
) -> dict[str, float | None]:
    sp0 = eval_skew_iv(s0, kp, t0, r0, q0, vxn0, coeffs)
    p0_mid = bsm_price(s0, kp, t0, r0, q0, sp0, "put")
    dp0 = bsm_delta(s0, kp, t0, r0, q0, sp0, "put")

    if tranche_type == "collar" and kc is not None:
        sc0 = eval_skew_iv(s0, kc, t0, r0, q0, vxn0, coeffs)
        c0_mid = bsm_price(s0, kc, t0, r0, q0, sc0, "call")
        dc0 = bsm_delta(s0, kc, t0, r0, q0, sc0, "call")
    else:
        c0_mid = 0.0
        dc0 = 0.0

    v0_mid = p0_mid - c0_mid
    delta0 = dp0 - dc0
    dv_delta = delta0 * (s1 - s0)

    sp_s1 = eval_skew_iv(s1, kp, t0, r0, q0, vxn0, coeffs)
    p_s1 = bsm_price(s1, kp, t0, r0, q0, sp_s1, "put")
    if tranche_type == "collar" and kc is not None:
        sc_s1 = eval_skew_iv(s1, kc, t0, r0, q0, vxn0, coeffs)
        c_s1 = bsm_price(s1, kc, t0, r0, q0, sc_s1, "call")
    else:
        c_s1 = 0.0
    v_price = p_s1 - c_s1
    dv_gamma = (v_price - v0_mid) - dv_delta

    if t1 <= 1e-6:
        dv_vega = 0.0
    else:
        sp_t1_v0 = eval_skew_iv(s1, kp, t1, r1, q1, vxn0, coeffs)
        sp_t1_v1 = eval_skew_iv(s1, kp, t1, r1, q1, vxn1, coeffs)
        p_t1_v0 = bsm_price(s1, kp, t1, r1, q1, sp_t1_v0, "put")
        p_t1_v1 = bsm_price(s1, kp, t1, r1, q1, sp_t1_v1, "put")
        if tranche_type == "collar" and kc is not None:
            sc_t1_v0 = eval_skew_iv(s1, kc, t1, r1, q1, vxn0, coeffs)
            sc_t1_v1 = eval_skew_iv(s1, kc, t1, r1, q1, vxn1, coeffs)
            c_t1_v0 = bsm_price(s1, kc, t1, r1, q1, sc_t1_v0, "call")
            c_t1_v1 = bsm_price(s1, kc, t1, r1, q1, sc_t1_v1, "call")
        else:
            c_t1_v0 = 0.0
            c_t1_v1 = 0.0
        dv_vega = (p_t1_v1 - c_t1_v1) - (p_t1_v0 - c_t1_v0)

    dv_theta_slip = actual_net_pnl_sh - (dv_delta + dv_gamma + dv_vega)
    conv_mult = (actual_net_pnl_sh / dv_delta) if (dv_delta > 0.20 and actual_net_pnl_sh > 0) else None
    return {
        "delta0": delta0,
        "dV_delta_sh": dv_delta,
        "dV_gamma_sh": dv_gamma,
        "dV_vega_sh": dv_vega,
        "dV_theta_slip_sh": dv_theta_slip,
        "conv_mult": conv_mult,
    }


def _parse_iso(d: str) -> datetime.date:
    return datetime.date.fromisoformat(d)


def load_seed_and_extend(fact_root: Path | None = None) -> tuple[list[dict[str, Any]], list[float]]:
    if not SEED_GZ.exists():
        raise FileNotFoundError(f"Missing seed input archive: {SEED_GZ}")
    with gzip.open(SEED_GZ, "rb") as f:
        seed = json.loads(f.read().decode("utf-8"))
    rows: list[dict[str, Any]] = list(seed["rows"])
    coeffs: list[float] = [float(x) for x in seed["opra_90dte_poly3_coeffs_desc"]]

    # Optional incremental forward extension from local DuckDB warehouse if newer QQQ bars exist
    db_file = (fact_root or DEFAULT_FACT_ROOT) / "fact_os.duckdb"
    if duckdb is not None and db_file.exists() and rows:
        last_dt = rows[-1]["date"]
        try:
            con = duckdb.connect(str(db_file), read_only=True)
            q_rows = con.execute(
                """
                SELECT CAST(date AS VARCHAR) AS d, open, high, low, close, COALESCE(dividends, 0.0) AS div
                FROM funds
                WHERE ticker = 'QQQ' AND CAST(date AS VARCHAR) > ?
                ORDER BY date ASC
                """,
                [last_dt],
            ).fetchall()
            con.close()
        except Exception:
            q_rows = []

        for d_str, op, hi, lo, cl, div in q_rows:
            if op is None or cl is None or float(cl) <= 0:
                continue
            prev = rows[-1]
            cl_f = float(cl)
            run_ath = max(float(prev["running_ath"]), cl_f)
            dd_ath = cl_f / run_ath - 1.0
            tail_closes = [float(x["close"]) for x in rows[-199:]] + [cl_f]
            ma200 = sum(tail_closes) / len(tail_closes)
            sc = int(prev["score"])
            tail_scores = [int(x["score"]) for x in rows[-4:]] + [sc]
            sc5 = sum(tail_scores) / len(tail_scores)
            new_row = dict(prev)
            new_row.update(
                {
                    "date": str(d_str)[:10],
                    "open": round(float(op), 6),
                    "high": round(float(hi or cl_f), 6),
                    "low": round(float(lo or cl_f), 6),
                    "close": round(cl_f, 6),
                    "dividends": round(float(div or 0.0), 6),
                    "running_ath": round(run_ath, 6),
                    "dd_from_ath": round(dd_ath, 8),
                    "qqq_ma200": round(ma200, 6),
                    "score_5d": round(sc5, 4),
                    "gate_g4": False if dd_ath < -0.05 else bool(prev["gate_g4"]),
                }
            )
            rows.append(new_row)

    for r in rows:
        ath5 = float(r.get("dd_from_ath") or 0.0) >= -0.05
        vxn22 = float(r.get("vxn") or 99.0) <= 22.0
        ad_val = r.get("ad_line")
        ad50_val = r.get("ad_sma50")
        ad_below50 = (
            float(ad_val) < float(ad50_val)
            if (ad_val is not None and ad50_val is not None)
            else False
        )
        score = int(r.get("score") or 0)
        r["sw_u1"] = bool(ath5 and (ad_below50 or score >= 4) and vxn22)
        r["sw_b1c"] = bool(ath5 and ad_below50 and vxn22)
        r["sw_d2"] = bool(ath5 and score >= 4)
        r["sw_g4"] = bool(r.get("gate_g4") or False)

    return rows, coeffs


def compute_bh_drip_factors(rows: list[dict[str, Any]]) -> tuple[list[float], list[float]]:
    n = len(rows)
    pre_drip = [0.0] * n
    post_drip = [0.0] * n
    sh = INITIAL_CAPITAL / float(rows[0]["close"])
    for i, r in enumerate(rows):
        pre_drip[i] = sh
        div = float(r["dividends"])
        cl = float(r["close"])
        if i > 0 and div > 0.0:
            sh += (sh * div) / cl
        post_drip[i] = sh
    return pre_drip, post_drip


def _format_trigger_label(score: int, ad_below50: bool, gate_key: str | None) -> tuple[str, str]:
    if gate_key == "sw_g4":
        return ("ATH<=5% + YoY>=30% + VXN<=20", "ATH<=5% + 年涨>=30% + VXN<=20")
    if gate_key == "sw_d2":
        return (f"{score}/6 Lights + ATH<=5%", f"{score}/6 危机灯 + ATH<=5%")
    if ad_below50 and score >= 4:
        return (f"{score}/6 Lights + AD<50DMA", f"{score}灯 + AD<50DMA")
    if ad_below50:
        return (f"{score}L + AD<50DMA Div", f"{score}灯 + AD<50DMA 背离")
    return (f"{score}/6 Crisis Lights", f"{score}/6 危机灯触发")


def simulate_strategy(
    rows_all: list[dict[str, Any]],
    coeffs: list[float],
    strategy_id: str,
    arch: str = "hybrid_campaign_first",
    max_slots: int = 2,
    slot_coverage: float = 0.50,
    put_moneyness: float = 0.90,
    gate_key: str | None = "sw_u1",
    target_dte: int = 90,
    step_cal_days: int = 30,
    vix_ratio_tp: float | None = 1.10,
    put_mult_tp: float | None = 5.0,
    put_mult_max_dte: int = 45,
    tp_mode: str = DEFAULT_TP_MODE,
    slow_bear_overlay: bool = False,
    slip: float = DEFAULT_SLIPPAGE,
) -> dict[str, Any]:
    rows = [r for r in rows_all if r["date"] >= START_DATE]
    dates = [r["date"] for r in rows]
    dt_objs = [_parse_iso(d) for d in dates]
    pre_drip_bh, post_drip_bh = compute_bh_drip_factors(rows)
    final_bh_sh = post_drip_bh[-1]
    final_cl = float(rows[-1]["close"])
    bh_end_nav = final_bh_sh * final_cl

    core_shares = INITIAL_CAPITAL / float(rows[0]["close"])
    tbill_cash = 0.0
    in_slow_bear_def = False
    pending_bear_change: str | None = None

    active_tranches: list[dict[str, Any]] = []
    pending_sig: dict[str, Any] | None = None
    ledger: list[dict[str, Any]] = []
    shield_events: list[dict[str, Any]] = []
    tid = 0

    nav_list: list[float] = []
    equiv_sh_list: list[float] = []
    any_active_list: list[int] = []
    active_slots_list: list[int] = []
    slot1_naked_list: list[bool] = []
    shield_active_list: list[bool] = []

    for i, d in enumerate(dates):
        row = rows[i]
        op = float(row["open"])
        cl = float(row["close"])
        div = float(row["dividends"])
        vxn_cl = float(row["vxn"])
        vix_r = float(row["vix_ratio"])
        r_cur = float(row["r"])
        q_cur = float(row["div_yield"])

        mult_morning = (final_bh_sh / pre_drip_bh[i]) * final_cl
        mult_eod = (final_bh_sh / post_drip_bh[i]) * final_cl

        if i > 0 and tbill_cash > 0.0:
            dt_yr = max(1, (dt_objs[i] - dt_objs[i - 1]).days) / 365.0
            tbill_cash *= 1.0 + float(rows[i - 1]["r"]) * dt_yr

        if i > 0 and slow_bear_overlay and pending_bear_change is not None:
            prev_r = rows[i - 1]
            if pending_bear_change == "enter_def" and not in_slow_bear_def:
                sell_sh = 0.50 * core_shares
                core_shares -= sell_sh
                cash_added = sell_sh * op * (1.0 - STOCK_REBAL_FEE)
                tbill_cash += cash_added
                in_slow_bear_def = True
                shield_events.append(
                    {
                        "event_id": f"{strategy_id}_shield_enter_{d}",
                        "event_type": "shield_enter",
                        "date": d,
                        "signal_date": prev_r["date"],
                        "spot": round(op, 2),
                        "qqq_ma200": round(float(prev_r["qqq_ma200"]), 2),
                        "smooth_lights": round(float(prev_r["score_5d"]), 2),
                        "raw_lights": int(prev_r["score"]),
                        "vix": round(float(prev_r["vix"]), 2),
                        "vix_ratio": round(float(prev_r["vix_ratio"]), 3),
                        "shares_delta": round(-sell_sh, 2),
                        "tbill_cash_usd": round(tbill_cash, 2),
                        "trigger_en": f"5D Smooth Lights {float(prev_r['score_5d']):.1f}>=4.8 & QQQ<200DMA (${float(prev_r['qqq_ma200']):.2f})",
                        "trigger_zh": f"5日均灯 {float(prev_r['score_5d']):.1f}>=4.8 且 QQQ跌破200DMA (${float(prev_r['qqq_ma200']):.2f})",
                    }
                )
            elif pending_bear_change == "exit_def" and in_slow_bear_def:
                buy_sh = tbill_cash / (op * (1.0 + STOCK_REBAL_FEE))
                core_shares += buy_sh
                prev_vix = float(prev_r["vix"])
                prev_vr = float(prev_r["vix_ratio"])
                prev_sc5 = float(prev_r["score_5d"])
                prev_cl_chk = float(prev_r["close"])
                prev_ma = float(prev_r["qqq_ma200"])
                if prev_vr >= 1.10 or prev_vix >= 34.0:
                    ex_en = f"Panic Capitulation Reload (VIX {prev_vix:.1f} / Ratio {prev_vr:.3f})"
                    ex_zh = f"恐慌极值抄底回补 (VIX {prev_vix:.1f} / 倒挂 {prev_vr:.3f})"
                elif prev_cl_chk > prev_ma * 1.01:
                    ex_en = f"Reclaimed 200DMA +1% (${prev_cl_chk:.2f} > ${prev_ma:.2f})"
                    ex_zh = f"重上200日年线 +1% (${prev_cl_chk:.2f} > ${prev_ma:.2f})"
                else:
                    ex_en = f"Macro Lights Cooled ({prev_sc5:.1f} <= 3.0)"
                    ex_zh = f"危机灯降温解除 ({prev_sc5:.1f} <= 3.0)"
                shield_events.append(
                    {
                        "event_id": f"{strategy_id}_shield_exit_{d}",
                        "event_type": "shield_exit",
                        "date": d,
                        "signal_date": prev_r["date"],
                        "spot": round(op, 2),
                        "qqq_ma200": round(prev_ma, 2),
                        "smooth_lights": round(prev_sc5, 2),
                        "raw_lights": int(prev_r["score"]),
                        "vix": round(prev_vix, 2),
                        "vix_ratio": round(prev_vr, 3),
                        "shares_delta": round(buy_sh, 2),
                        "tbill_cash_usd": 0.0,
                        "trigger_en": ex_en,
                        "trigger_zh": ex_zh,
                    }
                )
                tbill_cash = 0.0
                in_slow_bear_def = False
            pending_bear_change = None

        # A. Execute pending early Take-Profit exits at t+1 Open
        if i > 0 and any(t.get("pending_tp") for t in active_tranches):
            prev_vxn = float(rows[i - 1]["vxn"])
            prev_cl = float(rows[i - 1]["close"])
            gap_pct = (op / prev_cl - 1.0) * 100.0
            vxn_op = max(10.0, prev_vxn - 0.45 * gap_pct)

            still_open: list[dict[str, Any]] = []
            for tr in active_tranches:
                if not tr.get("pending_tp"):
                    still_open.append(tr)
                    continue
                rem_days = max(0, (tr["exp_dt"] - dt_objs[i]).days)
                t_rem = rem_days / 365.0
                sig_p_ex = eval_skew_iv(op, tr["kp"], t_rem, r_cur, q_cur, vxn_op, coeffs)
                put_bid = bsm_price(op, tr["kp"], t_rem, r_cur, q_cur, sig_p_ex, "put") * (1.0 - slip)

                if tr["tranche_type"] == "collar":
                    sig_c_ex = eval_skew_iv(op, tr["kc"], t_rem, r_cur, q_cur, vxn_op, coeffs)
                    call_ask = bsm_price(op, tr["kc"], t_rem, r_cur, q_cur, sig_c_ex, "call") * (1.0 + slip)
                    actual_net_sh = put_bid - call_ask
                else:
                    call_ask = 0.0
                    actual_net_sh = put_bid - tr["entry_put_ask"]

                net_sh_px = put_bid - call_ask
                exit_cash_usd = tr["hedged_shares"] * net_sh_px
                denom = op * (1.0 + (STOCK_REBAL_FEE if exit_cash_usd >= 0 else -STOCK_REBAL_FEE))
                d_sh = exit_cash_usd / denom if abs(exit_cash_usd) > 1e-10 else 0.0
                core_shares += d_sh

                d_sh_put = (tr["hedged_shares"] * put_bid) / denom
                d_sh_call = -(tr["hedged_shares"] * call_ask) / denom

                conv = decompose_tranche_convexity(
                    tr["tranche_type"],
                    tr["entry_spot"],
                    op,
                    tr["kp"],
                    tr["kc"],
                    tr["T_entry"],
                    t_rem,
                    tr["entry_r"],
                    r_cur,
                    tr["entry_q"],
                    q_cur,
                    tr["entry_vxn"],
                    vxn_op,
                    coeffs,
                    actual_net_sh,
                )
                hs = tr["hedged_shares"]
                trig_en, trig_zh = _format_trigger_label(tr["sig_score"], tr["sig_ad_below50"], gate_key)
                ledger.append(
                    {
                        "tranche_id": tr["tranche_id"],
                        "strategy_id": strategy_id,
                        "slot_num": tr["slot_num"],
                        "tranche_type": tr["tranche_type"],
                        "signal_date": tr["signal_date"],
                        "entry_date": tr["entry_date"],
                        "planned_exp_date": tr["exp_date"],
                        "exit_date": d,
                        "actual_days_held": (dt_objs[i] - tr["entry_dt"]).days,
                        "rem_dte_at_exit": rem_days,
                        "exit_reason": tr["tp_reason"],
                        "sig_score": tr["sig_score"],
                        "sig_ad_below50": tr["sig_ad_below50"],
                        "trigger_en": trig_en,
                        "trigger_zh": trig_zh,
                        "entry_spot": round(tr["entry_spot"], 2),
                        "entry_vxn": round(tr["entry_vxn"], 2),
                        "entry_vix_ratio": round(tr["entry_vix_ratio"], 3),
                        "kp": round(tr["kp"], 2),
                        "kc": round(tr["kc"], 2) if tr["kc"] is not None else None,
                        "call_cap_pct": round((tr["kc"] / tr["entry_spot"] - 1.0) * 100.0, 2)
                        if tr["kc"] is not None
                        else None,
                        "hedged_shares": round(hs, 2),
                        "slot_coverage": round(tr["slot_coverage"], 4),
                        "entry_put_ask_sh": round(tr["entry_put_ask"], 4),
                        "entry_cost_usd": round(tr["entry_cost_usd"], 2),
                        "entry_shares_sold": round(tr["entry_shares_sold"], 4),
                        "exit_spot": round(op, 2),
                        "exit_vxn": round(vxn_op, 2),
                        "exit_vix_ratio": round(tr["tp_trigger_ratio"], 3),
                        "underlying_ret_pct": round((op / tr["entry_spot"] - 1.0) * 100.0, 2),
                        "put_exit_val_sh": round(put_bid, 4),
                        "call_exit_cost_sh": round(call_ask, 4),
                        "exit_net_cash_usd": round(exit_cash_usd, 2),
                        "net_pnl_usd": round(exit_cash_usd - tr["entry_cost_usd"], 2),
                        "exit_shares_delta": round(d_sh, 2),
                        "shares_added": round(tr["entry_shares_sold"] + d_sh, 2),
                        "delta0": round(float(conv["delta0"]), 4),
                        "delta_usd": round(float(conv["dV_delta_sh"]) * hs, 2),
                        "gamma_usd": round(float(conv["dV_gamma_sh"]) * hs, 2),
                        "vega_usd": round(float(conv["dV_vega_sh"]) * hs, 2),
                        "theta_slip_usd": round(float(conv["dV_theta_slip_sh"]) * hs, 2),
                        "convexity_mult": round(float(conv["conv_mult"]), 2)
                        if conv["conv_mult"] is not None
                        else None,
                        "comp_entry_cost_usd": round(tr["comp_entry_cost_usd"], 2),
                        "comp_put_gain_usd": round(d_sh_put * mult_morning, 2),
                        "comp_call_drag_usd": round(d_sh_call * mult_morning, 2),
                    }
                )
            active_tranches = still_open

        # B. Execute pending new Tranche entry at t+1 Open
        if i > 0 and pending_sig is not None and arch != "pure_qqq" and len(active_tranches) < max_slots:
            prev_vxn = pending_sig["vxn"]
            prev_cl = pending_sig["close"]
            gap_pct = (op / prev_cl - 1.0) * 100.0
            vxn_en = max(10.0, prev_vxn - 0.45 * gap_pct)
            r_en, q_en = pending_sig["r"], pending_sig["q"]

            target_cal = dt_objs[i] + datetime.timedelta(days=target_dte)
            pos = bisect.bisect_left(dt_objs, target_cal)
            if pos < len(dates):
                exp_date = dates[pos]
                exp_dt = dt_objs[pos]
            else:
                exp_date = target_cal.isoformat()
                exp_dt = target_cal
            act_dte = max(1, (exp_dt - dt_objs[i]).days)
            t_en = act_dte / 365.0

            if arch == "all_collar":
                t_type = "collar"
            elif arch == "all_naked":
                t_type = "naked_put"
            elif arch == "hybrid_campaign_first":
                t_type = "naked_put" if len(active_tranches) == 0 else "collar"
            else:
                raise ValueError(f"Unknown arch: {arch}")

            kp = op * put_moneyness
            sig_p_en = eval_skew_iv(op, kp, t_en, r_en, q_en, vxn_en, coeffs)
            put_ask_en = bsm_price(op, kp, t_en, r_en, q_en, sig_p_en, "put") * (1.0 + slip)

            already_hedged = sum(t["hedged_shares"] for t in active_tranches)
            if max_slots == 1:
                hedged_sh = core_shares * slot_coverage
            else:
                avail_sh = max(0.0, core_shares - already_hedged)
                if t_type == "naked_put":
                    cost_sh_frac = put_ask_en / (op * (1.0 - STOCK_REBAL_FEE))
                    max_feasible = avail_sh / (1.0 + cost_sh_frac)
                    hedged_sh = min(core_shares * slot_coverage, max_feasible)
                else:
                    hedged_sh = min(core_shares * slot_coverage, avail_sh)

            if hedged_sh > 1e-6:
                if t_type == "collar":
                    kc = solve_zero_cost_call_strike(op, kp, t_en, r_en, q_en, vxn_en, coeffs, slip)
                    entry_cost_usd = 0.0
                    d_sh_entry = 0.0
                else:
                    kc = None
                    entry_cost_usd = hedged_sh * put_ask_en
                    d_sh_entry = -entry_cost_usd / (op * (1.0 - STOCK_REBAL_FEE))
                    core_shares += d_sh_entry

                tid += 1
                used_slots = {t["slot_num"] for t in active_tranches}
                slot_num = min(s for s in range(1, max_slots + 1) if s not in used_slots)
                active_tranches.append(
                    {
                        "tranche_id": tid,
                        "slot_num": slot_num,
                        "tranche_type": t_type,
                        "signal_date": pending_sig["signal_date"],
                        "sig_score": pending_sig["sig_score"],
                        "sig_ad_below50": pending_sig["sig_ad_below50"],
                        "entry_date": d,
                        "entry_dt": dt_objs[i],
                        "exp_date": exp_date,
                        "exp_dt": exp_dt,
                        "T_entry": t_en,
                        "entry_spot": op,
                        "entry_vxn": vxn_en,
                        "entry_vix_ratio": pending_sig["vix_ratio"],
                        "entry_r": r_en,
                        "entry_q": q_en,
                        "hedged_shares": hedged_sh,
                        "slot_coverage": slot_coverage,
                        "kp": kp,
                        "kc": kc,
                        "entry_put_ask": put_ask_en,
                        "entry_cost_usd": entry_cost_usd,
                        "entry_shares_sold": d_sh_entry,
                        "comp_entry_cost_usd": d_sh_entry * mult_morning,
                        "pending_tp": False,
                        "tp_trigger_ratio": 0.0,
                        "tp_reason": "",
                    }
                )
            pending_sig = None

        # C. Dividends DRIP at EOD Close
        if i > 0 and div > 0.0:
            core_shares += (core_shares * div) / cl

        # D. Expiry Settlement or EOD MTM + Take-Profit Check
        put_mtm_tot = 0.0
        call_mtm_tot = 0.0
        was_active_today = len(active_tranches) > 0
        active_slots_today = len(active_tranches)
        slot1_naked_today = any(t["tranche_type"] == "naked_put" for t in active_tranches)

        rem_after_exp: list[dict[str, Any]] = []
        for tr in active_tranches:
            if d == tr["exp_date"]:
                is_true_exp = (i < len(dates) - 1) or ((tr["exp_dt"] - dt_objs[i]).days == 0)
                if is_true_exp:
                    put_ex = max(0.0, tr["kp"] - cl)
                    call_ex = max(0.0, cl - tr["kc"]) if tr["kc"] is not None else 0.0
                    reason = f"expiry_{target_dte}dte"
                    rem_d = 0
                    t_rem_ex = 0.0
                else:
                    rem_d = (tr["exp_dt"] - dt_objs[i]).days
                    t_rem_ex = max(1.0 / 365.0, rem_d / 365.0)
                    sp = eval_skew_iv(cl, tr["kp"], t_rem_ex, r_cur, q_cur, vxn_cl, coeffs)
                    put_ex = bsm_price(cl, tr["kp"], t_rem_ex, r_cur, q_cur, sp, "put")
                    if tr["kc"] is not None:
                        sc = eval_skew_iv(cl, tr["kc"], t_rem_ex, r_cur, q_cur, vxn_cl, coeffs)
                        call_ex = bsm_price(cl, tr["kc"], t_rem_ex, r_cur, q_cur, sc, "call")
                    else:
                        call_ex = 0.0
                    reason = "sample_end_mtm"

                actual_net_sh = (put_ex - call_ex) if tr["tranche_type"] == "collar" else (put_ex - tr["entry_put_ask"])
                net_sh_px = put_ex - call_ex
                exit_cash_usd = tr["hedged_shares"] * net_sh_px
                denom = cl * (1.0 + (STOCK_REBAL_FEE if exit_cash_usd >= 0 else -STOCK_REBAL_FEE))
                d_sh = exit_cash_usd / denom if abs(exit_cash_usd) > 1e-8 else 0.0
                core_shares += d_sh

                d_sh_put = (tr["hedged_shares"] * put_ex) / denom if abs(put_ex) > 1e-10 else 0.0
                d_sh_call = -(tr["hedged_shares"] * call_ex) / denom if abs(call_ex) > 1e-10 else 0.0

                conv = decompose_tranche_convexity(
                    tr["tranche_type"],
                    tr["entry_spot"],
                    cl,
                    tr["kp"],
                    tr["kc"],
                    tr["T_entry"],
                    t_rem_ex if not is_true_exp else 0.0,
                    tr["entry_r"],
                    r_cur,
                    tr["entry_q"],
                    q_cur,
                    tr["entry_vxn"],
                    vxn_cl,
                    coeffs,
                    actual_net_sh,
                )
                hs = tr["hedged_shares"]
                trig_en, trig_zh = _format_trigger_label(tr["sig_score"], tr["sig_ad_below50"], gate_key)
                ledger.append(
                    {
                        "tranche_id": tr["tranche_id"],
                        "strategy_id": strategy_id,
                        "slot_num": tr["slot_num"],
                        "tranche_type": tr["tranche_type"],
                        "signal_date": tr["signal_date"],
                        "entry_date": tr["entry_date"],
                        "planned_exp_date": tr["exp_date"],
                        "exit_date": d,
                        "actual_days_held": (dt_objs[i] - tr["entry_dt"]).days,
                        "rem_dte_at_exit": rem_d,
                        "exit_reason": reason,
                        "sig_score": tr["sig_score"],
                        "sig_ad_below50": tr["sig_ad_below50"],
                        "trigger_en": trig_en,
                        "trigger_zh": trig_zh,
                        "entry_spot": round(tr["entry_spot"], 2),
                        "entry_vxn": round(tr["entry_vxn"], 2),
                        "entry_vix_ratio": round(tr["entry_vix_ratio"], 3),
                        "kp": round(tr["kp"], 2),
                        "kc": round(tr["kc"], 2) if tr["kc"] is not None else None,
                        "call_cap_pct": round((tr["kc"] / tr["entry_spot"] - 1.0) * 100.0, 2)
                        if tr["kc"] is not None
                        else None,
                        "hedged_shares": round(hs, 2),
                        "slot_coverage": round(tr["slot_coverage"], 4),
                        "entry_put_ask_sh": round(tr["entry_put_ask"], 4),
                        "entry_cost_usd": round(tr["entry_cost_usd"], 2),
                        "entry_shares_sold": round(tr["entry_shares_sold"], 4),
                        "exit_spot": round(cl, 2),
                        "exit_vxn": round(vxn_cl, 2),
                        "exit_vix_ratio": round(vix_r, 3),
                        "underlying_ret_pct": round((cl / tr["entry_spot"] - 1.0) * 100.0, 2),
                        "put_exit_val_sh": round(put_ex, 4),
                        "call_exit_cost_sh": round(call_ex, 4),
                        "exit_net_cash_usd": round(exit_cash_usd, 2),
                        "net_pnl_usd": round(exit_cash_usd - tr["entry_cost_usd"], 2),
                        "exit_shares_delta": round(d_sh, 2),
                        "shares_added": round(tr["entry_shares_sold"] + d_sh, 2),
                        "delta0": round(float(conv["delta0"]), 4),
                        "delta_usd": round(float(conv["dV_delta_sh"]) * hs, 2),
                        "gamma_usd": round(float(conv["dV_gamma_sh"]) * hs, 2),
                        "vega_usd": round(float(conv["dV_vega_sh"]) * hs, 2),
                        "theta_slip_usd": round(float(conv["dV_theta_slip_sh"]) * hs, 2),
                        "convexity_mult": round(float(conv["conv_mult"]), 2)
                        if conv["conv_mult"] is not None
                        else None,
                        "comp_entry_cost_usd": round(tr["comp_entry_cost_usd"], 2),
                        "comp_put_gain_usd": round(d_sh_put * mult_eod, 2),
                        "comp_call_drag_usd": round(d_sh_call * mult_eod, 2),
                    }
                )
            else:
                rem_days = max(1, (tr["exp_dt"] - dt_objs[i]).days)
                t_rem = rem_days / 365.0
                sp = eval_skew_iv(cl, tr["kp"], t_rem, r_cur, q_cur, vxn_cl, coeffs)
                pm = bsm_price(cl, tr["kp"], t_rem, r_cur, q_cur, sp, "put")
                if tr["kc"] is not None:
                    sc = eval_skew_iv(cl, tr["kc"], t_rem, r_cur, q_cur, vxn_cl, coeffs)
                    cm = bsm_price(cl, tr["kc"], t_rem, r_cur, q_cur, sc, "call")
                else:
                    cm = 0.0

                put_mtm_tot += tr["hedged_shares"] * pm
                call_mtm_tot -= tr["hedged_shares"] * cm

                if rem_days >= 3:
                    est_put_bid = pm * (1.0 - slip)
                    est_call_ask = cm * (1.0 + slip) if tr["kc"] is not None else 0.0
                    put_mult = est_put_bid / max(tr["entry_put_ask"], 1e-6)
                    tp_reason: str | None = None
                    # Track 1: Acute panic backwardation (VIX/VIX3M >= 1.10), gated by tp_mode
                    if vix_ratio_tp is not None and vix_r >= vix_ratio_tp:
                        if tp_mode == "standard_dual":
                            tp_reason = f"vix_inv_{vix_ratio_tp:.2f}_tp"
                        elif tp_mode == "layered_itm":
                            # Collar exits immediately on 1.10 to unlock Call cap; Naked Put ignores shallow inversions until strictly ITM (cl <= K_P)
                            if tr["tranche_type"] == "collar":
                                tp_reason = f"vix_inv_{vix_ratio_tp:.2f}_tp"
                            elif cl <= tr["kp"]:
                                tp_reason = f"vix_inv_{vix_ratio_tp:.2f}_itm_tp"
                        elif tp_mode == "both_4x":
                            if put_mult >= 4.0:
                                tp_reason = f"vix_inv_{vix_ratio_tp:.2f}_4x_tp"
                        else:
                            raise ValueError(f"Unknown tp_mode: {tp_mode}")
                    # Track 2: Second-half slow-bear 5x Put deep-ITM profit lock (DTE <= 45 & Put Bid >= 5x entry cost)
                    if (
                        tp_reason is None
                        and put_mult_tp is not None
                        and rem_days <= put_mult_max_dte
                        and est_put_bid >= put_mult_tp * tr["entry_put_ask"]
                    ):
                        tp_reason = f"put_{int(put_mult_tp)}x_dte{put_mult_max_dte}_tp"

                    if tp_reason is not None:
                        if tr["tranche_type"] == "collar":
                            if est_put_bid - est_call_ask > 0.0:
                                tr["pending_tp"] = True
                                tr["tp_trigger_ratio"] = vix_r
                                tr["tp_reason"] = tp_reason
                        else:
                            if est_put_bid > 0.02:
                                tr["pending_tp"] = True
                                tr["tp_trigger_ratio"] = vix_r
                                tr["tp_reason"] = tp_reason

                rem_after_exp.append(tr)

        active_tranches = rem_after_exp
        tot_mtm = put_mtm_tot + call_mtm_tot
        nav = core_shares * cl + tbill_cash + tot_mtm

        nav_list.append(nav)
        equiv_sh_list.append(nav / cl)
        any_active_list.append(1 if was_active_today else 0)
        active_slots_list.append(active_slots_today)
        slot1_naked_list.append(slot1_naked_today)
        shield_active_list.append(in_slow_bear_def)

        # E. EOD Entry Gate Check for t+1 Open (evaluate on all days including latest day for LIVE signal status!)
        if (
            arch != "pure_qqq"
            and gate_key is not None
            and len(active_tranches) < max_slots
            and not any(t.get("pending_tp") for t in active_tranches)
        ):
            can_open = False
            if len(active_tranches) == 0:
                if bool(row[gate_key]):
                    can_open = True
            else:
                if bool(row[gate_key]):
                    last_tr = max(active_tranches, key=lambda x: x["entry_dt"])
                    days_since_last = (dt_objs[i] - last_tr["entry_dt"]).days
                    if days_since_last >= step_cal_days:
                        can_open = True
            if can_open:
                pending_sig = {
                    "signal_date": d,
                    "close": cl,
                    "vxn": vxn_cl,
                    "vix_ratio": vix_r,
                    "r": r_cur,
                    "q": q_cur,
                    "sig_score": int(row["score"]),
                    "sig_ad_below50": bool(float(row["ad_line"]) < float(row["ad_sma50"])),
                }

        # F. Slow-Bear 6-Lights Regime Defense (also evaluate on latest day to surface next-open reload/enter status!)
        if slow_bear_overlay:
            sc_now = float(row["score_5d"])
            ma200_now = float(row["qqq_ma200"])
            vix_now = float(row["vix"])
            if not in_slow_bear_def:
                if sc_now >= 4.8 and cl < ma200_now:
                    pending_bear_change = "enter_def"
            else:
                if sc_now <= 3.0 or cl > ma200_now * 1.01 or vix_now >= 34.0 or vix_r >= 1.10:
                    pending_bear_change = "exit_def"

    # Serialize any tranches still open at final EOD (e.g. live 2026-11-20 ITM Naked Put awaiting next Open TP)
    last_r = rows[-1]
    last_d = dates[-1]
    last_dt = dt_objs[-1]
    last_cl = float(last_r["close"])
    last_vxn = float(last_r["vxn"])
    last_vr = float(last_r["vix_ratio"])
    last_rf = float(last_r["r"])
    last_q = float(last_r["div_yield"])
    mult_last = (final_bh_sh / post_drip_bh[-1]) * final_cl

    active_tranches_serialized: list[dict[str, Any]] = []
    for tr in active_tranches:
        rem_d = max(1, (tr["exp_dt"] - last_dt).days)
        t_rem = rem_d / 365.0
        sp = eval_skew_iv(last_cl, tr["kp"], t_rem, last_rf, last_q, last_vxn, coeffs)
        pm = bsm_price(last_cl, tr["kp"], t_rem, last_rf, last_q, sp, "put")
        if tr["kc"] is not None:
            sc = eval_skew_iv(last_cl, tr["kc"], t_rem, last_rf, last_q, last_vxn, coeffs)
            cm = bsm_price(last_cl, tr["kc"], t_rem, last_rf, last_q, sc, "call")
        else:
            cm = 0.0
        hs = tr["hedged_shares"]
        net_sh_px = pm - cm
        mtm_cash_usd = hs * net_sh_px
        mtm_net_pnl = mtm_cash_usd - tr["entry_cost_usd"]
        actual_net_sh = net_sh_px if tr["tranche_type"] == "collar" else (pm - tr["entry_put_ask"])
        est_d_sh = mtm_cash_usd / (last_cl * (1.0 + STOCK_REBAL_FEE)) if abs(mtm_cash_usd) > 1e-8 else 0.0
        est_sh_added = tr["entry_shares_sold"] + est_d_sh
        conv = decompose_tranche_convexity(
            tr["tranche_type"],
            tr["entry_spot"],
            last_cl,
            tr["kp"],
            tr["kc"],
            tr["T_entry"],
            t_rem,
            tr["entry_r"],
            last_rf,
            tr["entry_q"],
            last_q,
            tr["entry_vxn"],
            last_vxn,
            coeffs,
            actual_net_sh,
        )
        is_armed = bool(tr.get("pending_tp"))
        live_reason = "live_tp_armed_next_open" if is_armed else "open_live_mtm"
        trig_en, trig_zh = _format_trigger_label(tr["sig_score"], tr["sig_ad_below50"], gate_key)
        ledger.append(
            {
                "tranche_id": tr["tranche_id"],
                "strategy_id": strategy_id,
                "slot_num": tr["slot_num"],
                "tranche_type": tr["tranche_type"],
                "signal_date": tr["signal_date"],
                "entry_date": tr["entry_date"],
                "planned_exp_date": tr["exp_date"],
                "exit_date": None,
                "mtm_date": last_d,
                "is_open_live": True,
                "pending_tp": is_armed,
                "pending_tp_reason": tr.get("tp_reason") or "",
                "actual_days_held": (last_dt - tr["entry_dt"]).days,
                "rem_dte_at_exit": rem_d,
                "exit_reason": live_reason,
                "sig_score": tr["sig_score"],
                "sig_ad_below50": tr["sig_ad_below50"],
                "trigger_en": trig_en,
                "trigger_zh": trig_zh,
                "entry_spot": round(tr["entry_spot"], 2),
                "entry_vxn": round(tr["entry_vxn"], 2),
                "entry_vix_ratio": round(tr["entry_vix_ratio"], 3),
                "kp": round(tr["kp"], 2),
                "kc": round(tr["kc"], 2) if tr["kc"] is not None else None,
                "call_cap_pct": round((tr["kc"] / tr["entry_spot"] - 1.0) * 100.0, 2)
                if tr["kc"] is not None
                else None,
                "hedged_shares": round(hs, 2),
                "slot_coverage": round(tr["slot_coverage"], 4),
                "entry_put_ask_sh": round(tr["entry_put_ask"], 4),
                "entry_cost_usd": round(tr["entry_cost_usd"], 2),
                "entry_shares_sold": round(tr["entry_shares_sold"], 4),
                "exit_spot": round(last_cl, 2),
                "exit_vxn": round(last_vxn, 2),
                "exit_vix_ratio": round(last_vr, 3),
                "underlying_ret_pct": round((last_cl / tr["entry_spot"] - 1.0) * 100.0, 2),
                "put_exit_val_sh": round(pm, 4),
                "call_exit_cost_sh": round(cm, 4),
                "exit_net_cash_usd": round(mtm_cash_usd, 2),
                "net_pnl_usd": round(mtm_net_pnl, 2),
                "exit_shares_delta": round(est_d_sh, 2),
                "shares_added": round(est_sh_added, 2),
                "delta0": round(float(conv["delta0"]), 4),
                "delta_usd": round(float(conv["dV_delta_sh"]) * hs, 2),
                "gamma_usd": round(float(conv["dV_gamma_sh"]) * hs, 2),
                "vega_usd": round(float(conv["dV_vega_sh"]) * hs, 2),
                "theta_slip_usd": round(float(conv["dV_theta_slip_sh"]) * hs, 2),
                "convexity_mult": round(float(conv["conv_mult"]), 2)
                if conv["conv_mult"] is not None
                else None,
                "comp_entry_cost_usd": round(tr["comp_entry_cost_usd"], 2),
                "comp_put_gain_usd": round((hs * pm / last_cl) * mult_last, 2),
                "comp_call_drag_usd": round(-(hs * cm / last_cl) * mult_last, 2),
            }
        )
        active_tranches_serialized.append(
            {
                "tranche_id": tr["tranche_id"],
                "slot_num": tr["slot_num"],
                "tranche_type": tr["tranche_type"],
                "entry_date": tr["entry_date"],
                "exp_date": tr["exp_date"],
                "rem_dte": rem_d,
                "entry_spot": round(tr["entry_spot"], 2),
                "kp": round(tr["kp"], 2),
                "kc": round(tr["kc"], 2) if tr["kc"] is not None else None,
                "hedged_shares": round(hs, 2),
                "entry_cost_usd": round(tr["entry_cost_usd"], 2),
                "mtm_put_val_sh": round(pm, 4),
                "mtm_call_val_sh": round(cm, 4),
                "mtm_pnl_usd": round(mtm_net_pnl, 2),
                "est_shares_added": round(est_sh_added, 2),
                "pending_tp": is_armed,
                "tp_reason": tr.get("tp_reason") or "",
                "tp_trigger_ratio": round(float(tr.get("tp_trigger_ratio") or last_vr), 3),
            }
        )

    n = len(nav_list)
    rets = [nav_list[j] / nav_list[j - 1] - 1.0 for j in range(1, n)]
    rf_d = [float(rows[j]["r"]) / 252.0 for j in range(1, n)]
    yrs = (dt_objs[-1] - dt_objs[0]).days / 365.25
    cagr = (nav_list[-1] / nav_list[0]) ** (1.0 / yrs) - 1.0
    std_r = statistics.stdev(rets)
    vol = std_r * math.sqrt(252.0)
    ex = [rets[j] - rf_d[j] for j in range(len(rets))]
    mean_ex = sum(ex) / len(ex)
    sharpe = (mean_ex / std_r) * math.sqrt(252.0) if std_r > 0 else 0.0
    dn_sq = [min(0.0, x) ** 2 for x in ex]
    down_dev = math.sqrt(sum(dn_sq) / len(dn_sq)) * math.sqrt(252.0)
    sortino = (mean_ex * 252.0) / down_dev if down_dev > 0 else 0.0

    peak_nav = nav_list[0]
    mdd = 0.0
    for v in nav_list:
        if v > peak_nav:
            peak_nav = v
        dd = v / peak_nav - 1.0
        if dd < mdd:
            mdd = dd
    calmar = cagr / abs(mdd) if mdd < 0 else 0.0

    n_nak = sum(1 for x in ledger if x["tranche_type"] == "naked_put")
    n_col = sum(1 for x in ledger if x["tranche_type"] == "collar")
    n_tp = sum(1 for x in ledger if "tp" in x["exit_reason"] and not x.get("is_open_live"))
    naked_spent = sum(x["entry_cost_usd"] for x in ledger if x["tranche_type"] == "naked_put")
    gross_put = sum(x["hedged_shares"] * x["put_exit_val_sh"] for x in ledger)
    gross_call = sum(x["hedged_shares"] * x["call_exit_cost_sh"] for x in ledger)
    net_alpha = nav_list[-1] - bh_end_nav
    pct_active = (sum(any_active_list) / n) * 100.0
    active_days = max(1, sum(any_active_list))

    summary = {
        "id": strategy_id,
        "arch": arch,
        "max_slots": max_slots,
        "slot_coverage": round(slot_coverage, 4),
        "end_nav": round(nav_list[-1], 2),
        "net_alpha_usd": round(net_alpha, 2),
        "cagr_pct": round(cagr * 100.0, 2),
        "vol_pct": round(vol * 100.0, 2),
        "max_dd_pct": round(mdd * 100.0, 2),
        "sharpe": round(sharpe, 3),
        "sortino": round(sortino, 3),
        "calmar": round(calmar, 3),
        "final_shares": round(equiv_sh_list[-1], 2),
        "extra_shares_vs_bh": round(equiv_sh_list[-1] - final_bh_sh, 2),
        "pct_days_hedged": round(pct_active, 1),
        "alpha_per_active_day_usd": round(net_alpha / active_days, 2) if arch != "pure_qqq" else 0.0,
        "tranches_total": len(ledger),
        "naked_count": n_nak,
        "collar_count": n_col,
        "tp_count": n_tp,
        "naked_prem_spent_usd": round(naked_spent, 2),
        "gross_put_monetized_usd": round(gross_put, 2),
        "gross_call_drag_usd": round(gross_call, 2),
        "sum_delta_usd": round(sum(x["delta_usd"] for x in ledger), 2),
        "sum_gamma_usd": round(sum(x["gamma_usd"] for x in ledger), 2),
        "sum_vega_usd": round(sum(x["vega_usd"] for x in ledger), 2),
        "sum_theta_slip_usd": round(sum(x["theta_slip_usd"] for x in ledger), 2),
    }

    return {
        "summary": summary,
        "nav": nav_list,
        "equiv_shares": equiv_sh_list,
        "any_active": any_active_list,
        "active_slots": active_slots_list,
        "slot1_naked": slot1_naked_list,
        "shield_active": shield_active_list,
        "ledger": ledger,
        "shield_events": shield_events,
        "active_tranches_eod": active_tranches_serialized,
        "pending_sig_eod": pending_sig,
        "in_slow_bear_eod": in_slow_bear_def,
        "pending_bear_change_eod": pending_bear_change,
    }


def build_six_crisis_lights(row: dict[str, Any]) -> list[dict[str, Any]]:
    dgs2 = float(row["dgs2"] or 0.0)
    dgs2_lo = float(row["dgs2_low252"] or dgs2)
    dgs2_ma = float(row["dgs2_ma63"] or dgs2)
    dff = float(row["dff"] or 0.0)
    dff_lo = float(row["dff_low252"] or dff)
    dgs2_bps = round((dgs2 - dgs2_lo) * 100.0)
    dff_bps = round((dff - dff_lo) * 100.0)

    baa = float(row["baa10y"] or 0.0)
    baa_lo = float(row["baa_low252"] or baa)
    baa_ma = float(row["baa_ma63"] or baa)
    baa_bps = round((baa - baa_lo) * 100.0)
    baa_rel = ((baa / baa_lo - 1.0) * 100.0) if baa_lo > 0 else 0.0

    ad = float(row["ad_line"] or 0.0)
    ad_ma63 = float(row["ad_sma63"] or ad)
    pct200 = float(row["pct_200d"] or 0.0) * 100.0
    pct200_hi = float(row["pct200_hi252"] or 0.0) * 100.0
    pct200_drop = pct200_hi - pct200

    cop = float(row["copper"] or 0.0)
    cop_hi = float(row["cop_hi252"] or cop)
    cop_ma = float(row["cop_ma63"] or cop)
    cop_dd = ((cop / cop_hi - 1.0) * 100.0) if cop_hi > 0 else 0.0

    dc = float(row["def_cyc"] or 0.0)
    dc_lo = float(row["dc_low252"] or dc)
    dc_ma = float(row["dc_ma63"] or dc)
    dc_gain = ((dc / dc_lo - 1.0) * 100.0) if dc_lo > 0 else 0.0

    yc = float(row["t10y2y"] or 0.0)
    yc_hi = float(row["yc_hi252"] or yc)
    yc_flat_bps = round((yc_hi - yc) * 100.0)
    nfci = float(row["nfci"] or 0.0)
    nfci_lo = float(row["nfci_low252"] or nfci)
    nfci_chg = nfci - nfci_lo

    return [
        {
            "key": "sig1_fed",
            "index": 1,
            "lit": bool(row["sig1_fed"]),
            "name_en": "Fed Policy & Front-End Rates Tightening",
            "name_zh": "联储政策与前端利率紧缩",
            "short_en": "Fed / 2Y Yield",
            "short_zh": "前端利率紧缩",
            "reading_value": f"2Y {dgs2:.2f}% ({dgs2_bps:+d} bps)",
            "secondary_value": f"DFF {dff:.2f}% ({dff_bps:+d} bps)",
            "threshold_en": "2Y >= +50 bps off 12M low & > 63DMA, OR Fed Funds >= +20 bps",
            "threshold_zh": "2Y 美债较12月低点回升 >= 50bp 且高于63日均线，或联邦基金利率抬升 >= 20bp",
            "diagnostic_en": f"2Y UST at {dgs2:.2f}% vs 12M low {dgs2_lo:.2f}% (63DMA {dgs2_ma:.2f}%); Fed Funds {dff:.2f}%.",
            "diagnostic_zh": f"2Y 美债 {dgs2:.2f}%（较12月低点 {dgs2_lo:.2f}% 抬升 {dgs2_bps:+d}bp，63DMA {dgs2_ma:.2f}%）；DFF {dff:.2f}%。",
        },
        {
            "key": "sig2_credit",
            "index": 2,
            "lit": bool(row["sig2_credit"]),
            "name_en": "Corporate Credit Spread Widening",
            "name_zh": "企业信用利差走阔",
            "short_en": "Baa-10Y Credit",
            "short_zh": "信用利差走阔",
            "reading_value": f"{baa:.2f}% ({baa_rel:+.1f}%)",
            "secondary_value": f"{baa_bps:+d} bps vs 12M low",
            "threshold_en": "Moody's Baa-10Y widens >= +20 bps or >= +12% off 12M low & > 63DMA",
            "threshold_zh": "穆迪 Baa-10Y 利差较12月低点走阔 >= 20bp 或相对走阔 >= 12%，且高于63日均线",
            "diagnostic_en": f"Baa-10Y spread at {baa:.2f}% vs 12M tightest {baa_lo:.2f}% ({baa_rel:+.1f}%, 63DMA {baa_ma:.2f}%).",
            "diagnostic_zh": f"Baa-10Y 信用利差 {baa:.2f}%（较12月最低 {baa_lo:.2f}% 相对走阔 {baa_rel:+.1f}%，高于 63DMA {baa_ma:.2f}%）。",
        },
        {
            "key": "sig3_breadth",
            "index": 3,
            "lit": bool(row["sig3_breadth"]),
            "name_en": "Market Breadth & >200DMA Breakdown",
            "name_zh": "全美市场宽度与年线占比塌缩",
            "short_en": "Breadth / >200D",
            "short_zh": "市场宽度塌缩",
            "reading_value": f"{pct200:.1f}% >200D (-{pct200_drop:.1f}pp)",
            "secondary_value": f"AD {ad:,.0f} vs 63D {ad_ma63:,.0f}",
            "threshold_en": "US Liquid AD Line < 63DMA & < 12M high AND Stocks >200DMA down >= 8pp",
            "threshold_zh": "全美高流动性普通股 AD Line 跌破63日均线，且站上200日均线个股占比回落 >= 8个百分点",
            "diagnostic_en": f"Only {pct200:.1f}% of liquid stocks above 200DMA (down {pct200_drop:.1f}pp from {pct200_hi:.1f}% 12M peak); AD < 63DMA.",
            "diagnostic_zh": f"仅 {pct200:.1f}% 股票站上200DMA（较12月峰值 {pct200_hi:.1f}% 骤降 {pct200_drop:.1f}pp），AD 跌破 63DMA。",
        },
        {
            "key": "sig4_copper",
            "index": 4,
            "lit": bool(row["sig4_copper"]),
            "name_en": "Dr. Copper Industrial Demand Breakdown",
            "name_zh": "铜博士实体工业需求破位",
            "short_en": "Dr. Copper",
            "short_zh": "铜博士破位",
            "reading_value": f"${cop:.2f}/lb ({cop_dd:+.1f}%)",
            "secondary_value": f"63DMA ${cop_ma:.2f}/lb",
            "threshold_en": "HG Copper falls <= -10% off 12M high AND trades below 63DMA",
            "threshold_zh": "COMEX 铜价较过去12个月高点回撤 >= 10% 且跌破 63 日均线",
            "diagnostic_en": f"Copper at ${cop:.3f}/lb, {cop_dd:.1f}% below 12M high ${cop_hi:.3f} and below 63DMA ${cop_ma:.3f}.",
            "diagnostic_zh": f"铜价报 ${cop:.2f}/磅，较12月高点 ${cop_hi:.2f} 下跌 {abs(cop_dd):.1f}% 且位于 63DMA (${cop_ma:.2f}) 下方。",
        },
        {
            "key": "sig5_defensive",
            "index": 5,
            "lit": bool(row["sig5_defensive"]),
            "name_en": "Defensives Outperforming Cyclicals",
            "name_zh": "防御板块显著跑赢周期板块",
            "short_en": "DEF / CYC Ratio",
            "short_zh": "防御跑赢周期",
            "reading_value": f"{dc:.3f} ({dc_gain:+.1f}%)",
            "secondary_value": f"63DMA {dc_ma:.3f}",
            "threshold_en": "(XLU+XLP+XLV)/(XLY+XLI+XLB+XLF) rises >= +5% off 12M low & > 63DMA",
            "threshold_zh": "公用事业/必选/医疗相对可选/工业/材料/金融比值较12月低点反弹 >= 5% 且站上63日均线",
            "diagnostic_en": f"Defensive/Cyclical ratio at {dc:.3f}, +{dc_gain:.1f}% off 12M trough {dc_lo:.3f} (63DMA {dc_ma:.3f}).",
            "diagnostic_zh": f"防御/周期相对强弱比升至 {dc:.3f}，较12月低点 {dc_lo:.3f} 走强 +{dc_gain:.1f}%（高于 63DMA {dc_ma:.3f}）。",
        },
        {
            "key": "sig6_macro",
            "index": 6,
            "lit": bool(row["sig6_macro"]),
            "name_en": "Yield Curve & Financial Conditions Squeeze",
            "name_zh": "收益率曲线熊平与金融条件收紧",
            "short_en": "10Y-2Y / NFCI",
            "short_zh": "曲线与金融条件",
            "reading_value": f"10Y-2Y {yc:+.2f}% (-{yc_flat_bps}bp)",
            "secondary_value": f"NFCI {nfci:+.3f} ({nfci_chg:+.3f})",
            "threshold_en": "10Y-2Y flattens >= 40 bps (<0.75%) OR < 0%, OR Chicago Fed NFCI +0.12",
            "threshold_zh": "10Y-2Y 利差较12月峰值走平 >= 40bp（且<0.75%）或倒挂 < 0%，或芝加哥联储 NFCI 收紧 >= 0.12",
            "diagnostic_en": f"10Y-2Y at {yc:+.2f}% (flattened {yc_flat_bps} bps from 12M high {yc_hi:+.2f}%); NFCI {nfci:+.3f}.",
            "diagnostic_zh": f"10Y-2Y 报 {yc:+.2f}%（较12月高点 {yc_hi:+.2f}% 熊平压窄 {yc_flat_bps}bp）；NFCI 报 {nfci:+.3f}。",
        },
    ]


def build_ad_line_signal(rows: list[dict[str, Any]], idx: int) -> dict[str, Any]:
    r = rows[idx]
    ad = float(r["ad_line"])
    sma50 = float(r["ad_sma50"])
    sma63 = float(r["ad_sma63"])
    hi252 = float(r["ad_hi252"])
    spread = ad - sma50
    spread_pct = (spread / sma50) * 100.0 if sma50 else 0.0
    below = ad < sma50

    streak = 0
    for j in range(idx, -1, -1):
        if float(rows[j]["ad_line"]) < float(rows[j]["ad_sma50"]):
            streak += 1
        else:
            break

    ath5 = float(r["dd_from_ath"]) >= -0.05
    top_div = bool(ath5 and below)
    last_top_div_date = None
    for j in range(idx, -1, -1):
        if float(rows[j]["dd_from_ath"]) >= -0.05 and float(rows[j]["ad_line"]) < float(rows[j]["ad_sma50"]):
            last_top_div_date = rows[j]["date"]
            break

    pct200 = float(r["pct_200d"]) * 100.0
    pct200_hi = float(r["pct200_hi252"]) * 100.0
    return {
        "ad_line": round(ad, 0),
        "ad_sma50": round(sma50, 0),
        "ad_sma63": round(sma63, 0),
        "ad_hi252": round(hi252, 0),
        "spread_vs_50ma": round(spread, 0),
        "spread_vs_50ma_pct": round(spread_pct, 2),
        "below_50ma": below,
        "days_below_50ma": streak,
        "pct_above_200d": round(pct200, 1),
        "pct200_hi252": round(pct200_hi, 1),
        "pct200_drop_pp": round(pct200_hi - pct200, 1),
        "top_divergence_active": top_div,
        "last_top_divergence_date": last_top_div_date,
        "status_en": (
            "TOP DIVERGENCE ARMED (Near ATH & AD < 50DMA)"
            if top_div
            else ("BREADTH BREAKDOWN (AD < 50DMA)" if below else "HEALTHY BREADTH (AD >= 50DMA)")
        ),
        "status_zh": (
            "高位顶背离亮灯（距ATH<=5% 且 AD跌破50DMA）"
            if top_div
            else ("市场宽度破位（AD 位于 50DMA 下方）" if below else "市场宽度健康（AD 站稳 50DMA 上方）")
        ),
        "note_en": (
            f"US Liquid Common-Stock AD Line {ad:,.0f} vs 50DMA {sma50:,.0f} ({spread:+,.0f}, {streak}D below); "
            f"last pre-crash ATH<=5% top divergence fired on {last_top_div_date or '—'}."
        ),
        "note_zh": (
            f"全美高流动性普通股腾落线 AD Line 报 {ad:,.0f} vs 50DMA {sma50:,.0f}（差值 {spread:+,.0f}，连续 {streak} 日破位）；"
            f"本轮崩盘前最近一次 ATH<=5% 高位顶背离触发于 {last_top_div_date or '—'}。"
        ),
    }


def build_live_signal_state(
    row: dict[str, Any],
    u1_sim: dict[str, Any],
    tp_mode: str = DEFAULT_TP_MODE,
) -> dict[str, Any]:
    cl = float(row["close"])
    dd_pct = float(row["dd_from_ath"]) * 100.0
    ma200 = float(row["qqq_ma200"])
    vxn = float(row["vxn"])
    vr = float(row["vix_ratio"])
    sc = int(row["score"])
    sc5 = float(row["score_5d"])
    ad_below = float(row["ad_line"]) < float(row["ad_sma50"])

    ath_ok = dd_pct >= -5.0
    vxn_ok = vxn <= 22.0
    lights_ok = sc >= 4
    tp_ok = vr >= 1.10

    active_tr = u1_sim["active_tranches_eod"]
    pend_sig = u1_sim["pending_sig_eod"]

    s1_open = next((t for t in active_tr if t["slot_num"] == 1), None)
    s2_open = next((t for t in active_tr if t["slot_num"] == 2), None)

    u1_led = u1_sim["ledger"]
    last_s1_u1 = next((x for x in reversed(u1_led) if x["slot_num"] == 1 and not x.get("is_open_live")), None)
    last_s2_u1 = next((x for x in reversed(u1_led) if x["slot_num"] == 2 and not x.get("is_open_live")), None)

    cur_dt = _parse_iso(row["date"])
    recent_tp_tranches = [
        t
        for t in (last_s1_u1, last_s2_u1)
        if t is not None
        and t.get("exit_date")
        and "tp" in str(t.get("exit_reason") or "")
        and (cur_dt - _parse_iso(t["exit_date"])).days <= 30
    ]

    if any(t.get("pending_tp") for t in active_tr):
        regime_code = "VIX110_TP_TRIGGERED"
        title_en = "DEEP ITM PANIC TAKE-PROFIT ARMED (MONETIZE & ADD QQQ AT NEXT OPEN)"
        title_zh = "深跌实值恐慌止盈触发（次日开盘全额变现低位加仓 QQQ）"
    elif s1_open and s2_open:
        regime_code = "DUAL_SLOT_FULL_SHIELD"
        title_en = "SLOT 1 NAKED PUT + SLOT 2 ZERO-COST COLLAR FULL HEDGE ACTIVE (100% QQQ)"
        title_zh = "首仓裸 Put + 次仓零成本 Collar 双槽满盾保护中（100% 满仓 QQQ）"
    elif s1_open:
        regime_code = "SLOT1_NAKED_PUT_ACTIVE"
        title_en = "SLOT 1 (50% NAKED -10% PUT) ACTIVE · 100% QQQ UNLIMITED UPSIDE RETAINED"
        title_zh = "首仓 50% 裸 -10% Put 持盾中 · 100% QQQ 保留完整向上冲顶收益"
    elif pend_sig is not None:
        regime_code = "SLOT1_NAKED_PUT_ARMED"
        title_en = "TOP-DIVERGENCE / 4-LIGHT GATE FIRED · OPEN SLOT 1 50% NAKED PUT AT NEXT OPEN"
        title_zh = "高位顶背离 / 四灯门控触发 · 次日开盘买入首仓 50% 裸 -10% Put"
    elif not ath_ok:
        regime_code = "LOW_SPOT_FREEZE_NO_NEW_COLLAR"
        if recent_tp_tranches:
            tp_usd = sum(float(t["net_pnl_usd"]) for t in recent_tp_tranches)
            tp_sh = sum(float(t["shares_added"]) for t in recent_tp_tranches)
            tp_date = max(t["exit_date"] for t in recent_tp_tranches)
            title_en = (
                f"100% QQQ HELD · NEW COLLARS HARD FROZEN BELOW ATH -5% "
                f"(HARVESTED +${tp_usd:,.0f} / +{tp_sh:.2f} SH ON {tp_date})"
            )
            title_zh = (
                f"100% 满仓 QQQ 持筹待弹 · 跌离前高超 5% 严禁低位新开 Collar"
                f"（已于 {tp_date} 恐慌止盈落袋 +${tp_usd:,.0f} / +{tp_sh:.2f} 股）"
            )
        else:
            title_en = "DRAWDOWN > 5% OFF ATH · HARD FREEZE ON NEW COLLARS (100% QQQ REBOUND CAPTURE)"
            title_zh = "距历史前高回撤超 5% · 严禁低位新开或续作 Collar（100% QQQ 保留完整反弹斜率）"
    else:
        regime_code = "CRUISE_UNHEDGED"
        title_en = "BULL CRUISE UNHEDGED (100% QQQ · ZERO CALL DRAG)"
        title_zh = "顺风巡航零期权拖累（100% 满仓 QQQ 复利）"

    def _fmt_last_action(tr_u1: dict[str, Any] | None) -> dict[str, Any]:
        if tr_u1 is None:
            return {"summary_en": "No prior trade", "summary_zh": "暂无历史交易"}
        is_nk = tr_u1["tranche_type"] == "naked_put"
        strike_str = (
            f"K=${tr_u1['kp']:.2f}"
            if is_nk
            else f"K_P=${tr_u1['kp']:.2f} / K_C=${tr_u1['kc']:.2f}"
        )
        ex_tag = "TP" if "tp" in tr_u1["exit_reason"] else "Exp"
        ex_tag_zh = "1.10止盈" if "tp" in tr_u1["exit_reason"] else "到期"
        return {
            "entry_date": tr_u1["entry_date"],
            "entry_spot": tr_u1["entry_spot"],
            "kp": tr_u1["kp"],
            "kc": tr_u1["kc"],
            "exit_date": tr_u1["exit_date"],
            "exit_spot": tr_u1["exit_spot"],
            "exit_reason": tr_u1["exit_reason"],
            "u1_net_pnl_usd": tr_u1["net_pnl_usd"],
            "u1_shares_added": tr_u1["shares_added"],
            "summary_en": (
                f"{tr_u1['entry_date']} Open @${tr_u1['entry_spot']:.2f} {strike_str} -> "
                f"{tr_u1['exit_date']} {ex_tag} @${tr_u1['exit_spot']:.2f} "
                f"{tr_u1['net_pnl_usd']:+,.0f} USD ({tr_u1['shares_added']:+.2f} sh)"
            ),
            "summary_zh": (
                f"{tr_u1['entry_date']} 开仓 @${tr_u1['entry_spot']:.2f} ({strike_str}) -> "
                f"{tr_u1['exit_date']} {ex_tag_zh} @${tr_u1['exit_spot']:.2f} "
                f"净赚 ${tr_u1['net_pnl_usd']:+,.0f}（增持 {tr_u1['shares_added']:+.2f} 股 QQQ）"
            ),
        }

    s1_status = (
        ("TP_TRIGGERED_NEXT_OPEN" if s1_open.get("pending_tp") else "ACTIVE_OPEN")
        if s1_open
        else ("ARMED_NEXT_OPEN" if pend_sig is not None else "MONETIZED_STANDBY")
    )
    s2_status = (
        ("TP_TRIGGERED_NEXT_OPEN" if s2_open.get("pending_tp") else "ACTIVE_OPEN")
        if s2_open
        else ("FROZEN_BELOW_ATH5" if not ath_ok else "STANDBY_WAIT_30D")
    )
    tp_meta = next((m for m in TP_MODE_SPECS if m["id"] == tp_mode), TP_MODE_SPECS[0])

    return {
        "tp_mode": tp_mode,
        "tp_mode_label_en": tp_meta["label_en"],
        "tp_mode_label_zh": tp_meta["label_zh"],
        "regime_code": regime_code,
        "regime_title_en": title_en,
        "regime_title_zh": title_zh,
        "regime_subtitle_en": (
            f"QQQ ${cl:.2f} ({dd_pct:.2f}% vs ATH, {(cl / ma200 - 1.0) * 100.0:.2f}% vs 200DMA) · "
            f"{sc}/6 Crisis Lights ON (5D avg {sc5:.1f}) · VIX/VIX3M {vr:.3f} · 100% QQQ Pure Options"
        ),
        "regime_subtitle_zh": (
            f"QQQ 现价 ${cl:.2f}（距前高 {dd_pct:.2f}%，偏离年线 {(cl / ma200 - 1.0) * 100.0:.2f}%）· "
            f"危机灯 {sc}/6 全亮（5日均值 {sc5:.1f}）· VIX/VIX3M {vr:.3f} · 100% 满仓 QQQ 纯期权"
        ),
        "target_equity_pct": 100.0,
        "target_tbill_pct": 0.0,
        "active_option_slots": len(active_tr),
        "slot1_naked_put": {
            "slot_id": "slot1_naked_put",
            "title_en": "Slot 1 · 50% First-Tranche Naked -10% Put",
            "title_zh": "首仓 Slot 1 · 50% 仓位 90-DTE 裸 -10% Put",
            "status": s1_status,
            "status_label_en": (
                "TP ARMED NEXT OPEN"
                if (s1_open and s1_open.get("pending_tp"))
                else ("ACTIVE" if s1_open else ("ARMED T+1" if pend_sig else "TP HARVESTED · STANDBY"))
            ),
            "status_label_zh": (
                "实值止盈已触发 · 次日开盘落袋"
                if (s1_open and s1_open.get("pending_tp"))
                else ("持仓保护中" if s1_open else ("次日开盘建仓" if pend_sig else "已止盈落袋 · 待命"))
            ),
            "rule_en": "ATH <= 5% & VXN <= 22 & (AD Line < 50DMA OR Crisis Lights >= 4) -> Buy 50% 90-DTE -10% Put (NO Call cap)",
            "rule_zh": "距ATH <= 5% 且 VXN <= 22 且（AD < 50DMA 顶背离 或 危机灯 >= 4）-> 买 50% 裸 -10% Put（不卖 Call 保留冲顶斜率）",
            "open_position": s1_open,
            "latest_action": _fmt_last_action(last_s1_u1),
        },
        "slot2_collar": {
            "slot_id": "slot2_collar",
            "title_en": "Slot 2 · 50% Second-Tranche Zero-Cost Collar",
            "title_zh": "次仓 Slot 2 · 50% 仓位零成本 Collar 领口盾",
            "status": s2_status,
            "status_label_en": (
                "TP ARMED NEXT OPEN"
                if (s2_open and s2_open.get("pending_tp"))
                else ("ACTIVE" if s2_open else ("HARD FROZEN (DD > 5%)" if not ath_ok else "STANDBY (>=30D STEP)"))
            ),
            "status_label_zh": (
                "止盈已触发 · 次日开盘落袋"
                if (s2_open and s2_open.get("pending_tp"))
                else ("持盾保护中" if s2_open else ("低位铁律冻结（禁卖Call）" if not ath_ok else "待命（距首仓满30日开启）"))
            ),
            "rule_en": ">= 30 cal days after Slot 1 & entry gates still ON -> Open 50% Zero-Cost Collar (-10% Put / +OTM Call); strictly forbidden below ATH -5%",
            "rule_zh": "首仓满 30 自然日且门控仍亮灯 -> 开启剩余 50% 零成本 Collar；跌离前高超 5% 严禁新开或续作 Collar",
            "open_position": s2_open,
            "latest_action": _fmt_last_action(last_s2_u1),
        },
        "gate_checklist": [
            {
                "key": "ath_within_5pct",
                "label_en": "ATH <= 5%",
                "label_zh": "距前高 <= 5%",
                "role": "ENTRY_PREREQ",
                "passed": ath_ok,
                "current_value": f"{dd_pct:.2f}%",
                "reading": f"{dd_pct:.2f}%",
                "threshold": ">= -5.00%",
                "note_en": "Prevents selling upside Calls in a hole" if not ath_ok else "Near highs: cheap hedging window open",
                "note_zh": "深跌区硬锁死，防止低位卖 Call 被逼空踏空" if not ath_ok else "处于前高 5% 内低成本上盾区",
            },
            {
                "key": "vxn_le_22",
                "label_en": "VXN <= 22",
                "label_zh": "VXN <= 22 低波门控",
                "role": "ENTRY_PREREQ",
                "passed": vxn_ok,
                "current_value": f"{vxn:.2f}",
                "reading": f"{vxn:.2f}",
                "threshold": "<= 22.00",
                "note_en": "Blocks overpaying bloated panic IV" if not vxn_ok else "Implied vol cheap enough for 90-DTE Put",
                "note_zh": "拒绝在恐慌高波时买天价期权当冤大头" if not vxn_ok else "隐含波动率低廉，适合建仓 90D Put",
            },
            {
                "key": "ad_below_50dma",
                "label_en": "AD Line < 50DMA",
                "label_zh": "AD Line < 50DMA",
                "role": "ENTRY_TRIGGER",
                "passed": ad_below,
                "current_value": f"{float(row['ad_line']) - float(row['ad_sma50']):+,.0f}",
                "reading": f"{float(row['ad_line']) - float(row['ad_sma50']):+,.0f}",
                "threshold": "< 0",
                "note_en": "Internal market breadth below 50DMA" if ad_below else "Broad participation intact",
                "note_zh": "全美腾落线跌破 50DMA（内部宽度恶化）" if ad_below else "市场内部腾落线位于 50DMA 上方",
            },
            {
                "key": "crisis_lights_ge_4",
                "label_en": "Crisis Lights >= 4",
                "label_zh": "危机灯 >= 4 盏",
                "role": "ENTRY_TRIGGER",
                "passed": lights_ok,
                "current_value": f"{sc} / 6",
                "reading": f"{sc} / 6",
                "threshold": ">= 4 / 6",
                "note_en": f"{sc}/6 Druckenmiller macro reversal lights ON" if lights_ok else f"Only {sc}/6 lights ON",
                "note_zh": f"德鲁肯米勒六大危机灯亮起 {sc}/6 盏" if lights_ok else f"仅亮 {sc}/6 盏，未达宏观警戒线",
            },
            {
                "key": "vix_ratio_ge_110_tp",
                "label_en": "VIX/VIX3M >= 1.10 TP",
                "label_zh": "VIX/VIX3M >= 1.10 止盈",
                "role": "EXIT_TRIGGER",
                "passed": tp_ok,
                "current_value": f"{vr:.3f}",
                "reading": f"{vr:.3f}",
                "threshold": ">= 1.100",
                "note_en": "Panic backwardation active: monetize puts & reload!" if tp_ok else "Term structure below 1.10 panic threshold",
                "note_zh": "恐慌期限倒挂极值触发：收割凸性暴利抄底正股！" if tp_ok else "未达 1.10 恐慌倒挂收割阈值",
            },
        ],
    }


def build_crisis_windows(
    rows_eval: list[dict[str, Any]],
    sims: dict[str, dict[str, Any]],
    unified_events: list[dict[str, Any]],
    tp_mode: str = DEFAULT_TP_MODE,
) -> list[dict[str, Any]]:
    date_to_idx = {r["date"]: i for i, r in enumerate(rows_eval)}

    if tp_mode == "layered_itm":
        live_narr_en = (
            "1) 8/31 Slot 1 Naked Put @$715.17 (K_P=$643.65, NO Call cap -> captured 100% of the rally to $759.66 ATH!). "
            "2) 10/05 Slot 2 Zero-Cost Collar @$749.35 (K_P=$674.41). "
            "3) On 11/05 VIX/3M=1.103: Slot 2 Collar (already deep ITM) monetized on 11/06 Open @$658.35 for +$50,384 (+76.51 QQQ shares) and freed the Call cap, "
            "while Slot 1 Naked Put IGNORED the shallow inversion ($647.05 > $643.65 OTM) and rode the real crash down to $608.45 (-19.9%), arming deep-ITM panic TP (+$39,532 MTM / +67.32 sh) for next Open — cutting drawdown to -14.81% (+5.09% excess)!"
        )
        live_narr_zh = (
            "① 8/31 AD 背离开启首仓 50% 裸 Put @$715.17（行权 $643.65，无卖 Call 封顶吃满冲顶至 $759.66！）；"
            "② 10/05 见顶前一日 @$749.35 补齐次仓 50% 零成本 Collar（行权 $674.41）；"
            "③ 11/05 压线倒挂 1.103：次仓领口已深实值，11/06 开盘果断落袋 +$50,384（+76.51 股）并解除卖 Call 封顶；"
            "首仓裸 Put 因收盘 $647.05 尚未跌破行权价 $643.65 直接无视浅倒挂，稳稳拿住吃到 11/20 深跌至 $608.45（-19.9%），实值恐慌止盈正式触发（浮盈 +$39,532 / +67.32 股待次日开盘换股），将本轮回撤从 -19.90% 压至 -14.81%（超额 +5.09%）！"
        )
    elif tp_mode == "both_4x":
        live_narr_en = (
            "1) 8/31 Slot 1 Naked Put @$715.17 + 10/05 Slot 2 Zero-Cost Collar @$749.35. "
            "2) On 11/05 VIX/3M=1.103: Slot 2 Collar exceeded 4x cost and monetized on 11/06 Open for +$50,035 (+75.98 sh), "
            "while Slot 1 Naked Put (<4x on 11/05) ignored the shallow spike and rode down to $608.45 (-19.9%) on 11/20, triggering 4x deep panic TP (+$39,258 MTM / +66.85 sh) and cutting drawdown to -14.81% (+5.09% excess)!"
        )
        live_narr_zh = (
            "① 8/31 首仓裸 Put @$715.17 叠加 10/05 次仓领口 @$749.35；"
            "② 11/05 倒挂 1.103 时次仓领口已超 4 倍成本，11/06 开盘落袋 +$50,035（+75.98 股）；"
            "首仓裸 Put 未满 4 倍直接无视浅跌，拿住到 11/20 深跌至 $608.45（-19.9%）突破 4 倍成本，触发深度恐慌止盈（浮盈 +$39,258 / +66.85 股），将回撤压至 -14.81%（超额 +5.09%）！"
        )
    else:
        live_narr_en = (
            "1) 8/31 Slot 1 Naked Put @$715.17 (AD divergence, NO Call cap -> captured 100% of the rally to $759.66 ATH!). "
            "2) 10/05 Slot 2 Zero-Cost Collar @$749.35 (1 day before peak!). "
            "3) On 11/06 Open @$658.35 (VIX/3M 1.103), Standard 1.10 TP monetized both slots immediately for +$62,156 (+95.55 extra QQQ shares), "
            "cutting drawdown to -16.33% (+3.58% excess) while holding 100% QQQ uncapped below ATH -5%."
        )
        live_narr_zh = (
            "① 8/31 AD 背离开启首仓 50% 裸 Put @$715.17（无卖 Call 封顶吃满冲顶至 $759.66！）；"
            "② 10/05 见顶前一日 @$749.35 补齐次仓 50% 零成本 Collar；"
            "③ 11/06 倒挂 1.103 在 @$658.35 按标准双轨一次性双槽止盈落袋 +$62,156（低位增持 +95.55 股 QQQ）；"
            "④ 跌离前高超 5% 严禁低位新开 Collar，100% 满仓 QQQ 待弹（回撤 -16.33% vs QQQ -19.90%，超额 +3.58%）。"
        )

    specs = [
        {
            "id": "2015-08",
            "pill_en": "2015-08 Yuan Shock",
            "pill_zh": "2015-08 汇改闪崩",
            "title_en": "2015-08 Yuan Devaluation Flash Crash",
            "title_zh": "2015-08 人民币汇改与全球流动性闪崩",
            "start_date": "2015-05-26",
            "end_date": "2015-10-15",
            "crash_start_date": "2015-07-20",
            "crash_end_date": "2015-08-25",
            "is_live": False,
            "narrative_en": (
                "4/6 Crisis Lights + AD top-divergence armed two 90-DTE Collars ahead of the peak ($110.64 on 6/01 and "
                "$112.73 on 7/23). On 2015-08-24 when VIX/VIX3M spiked to 1.194, both tranches monetized at $94.23 Open "
                "for +$13,633 (+144.6 QQQ shares), cutting QQQ's -13.94% drawdown nearly in half."
            ),
            "narrative_zh": (
                "暴跌前 4–5 盏危机灯叠加 AD 背离提前在 $110.64（6/01）与 $112.73（7/23）挂满双槽保护；"
                "8/24 闪崩开盘 VIX/VIX3M 飙至 1.194 触发止盈，在 $94.23 铁底一次性落袋 +$13,633 并抄底 +144.6 股 QQQ！"
            ),
        },
        {
            "id": "2018-Q4",
            "pill_en": "2018-Q4 Fed QT",
            "pill_zh": "2018-Q4 联储缩表",
            "title_en": "2018-Q4 Fed Autopilot Tightening Bear (-22.7%)",
            "title_zh": "2018-Q4 美联储缩表加息急跌 (-22.7%)",
            "start_date": "2018-06-20",
            "end_date": "2019-02-08",
            "crash_start_date": "2018-10-01",
            "crash_end_date": "2018-12-24",
            "is_live": False,
            "narrative_en": (
                "4/6 Crisis Lights fired 47 trading days before the top (Slot 1 Naked Put 6/25, Slot 2 Collar 7/26, "
                "refreshed Collar 10/05 @$182.36). On 10/11 when VIX/VIX3M inverted to 1.109, the option sleeve monetized "
                "for +$5,847 (+34.18 QQQ shares), reducing QQQ's -22.69% drawdown to -21.28% (+1.41% excess) while holding 100% QQQ."
            ),
            "narrative_zh": (
                "四灯在见顶前 47 个交易日提前亮起，10/05 在 $182.36 高位补齐 Collar；"
                "10/11 首波恐慌倒挂 1.109 止盈落袋 +$5,847（增持 +34.18 股 QQQ），全程 100% 持仓 QQQ 将回撤从 -22.69% 压至 -21.28%（超额 +1.41%）。"
            ),
        },
        {
            "id": "2020-03",
            "pill_en": "2020-03 COVID",
            "pill_zh": "2020-03 新冠熔断",
            "title_en": "2020-03 Exogenous Pandemic Shock (-28.6%)",
            "title_zh": "2020-03 新冠外生黑天鹅熔断 (-28.6%)",
            "start_date": "2020-01-02",
            "end_date": "2020-04-17",
            "crash_start_date": "2020-02-19",
            "crash_end_date": "2020-03-23",
            "is_live": False,
            "narrative_en": (
                "Honest out-of-sample disclosure: because COVID-19 was an exogenous biological shock while pre-peak macro "
                "lights were 2/6 and AD Line hit new highs, U1 held 0 pre-peak puts (zero Call cap drag in 2019's +39% melt-up) "
                "and stayed strictly 100% QQQ with ATH<=5% freeze, capturing 100% of the April V-bottom rebound (0.00% excess)."
            ),
            "narrative_zh": (
                "零前视客观披露：2020年2月见顶前宏观基本面仅亮 2/6 灯且全美 AD 创历史新高，纯内生宽度/宏观开关未提前挂 Put（也因此零损耗吃满 2019 年 +39% 主升浪）；"
                "下跌超 5% 后触发低位铁律冻结，100% 满仓 QQQ 完整吃下 3/23 后的 V 型暴涨（区间超额 0.00%）。"
            ),
        },
        {
            "id": "2022",
            "pill_en": "2022 Slow Bear",
            "pill_zh": "2022 加息慢熊",
            "title_en": "2022 Inflation Hiking Grind (-35.1% QQQ vs -31.5% U1 · 5x Put Lock)",
            "title_zh": "2022 加息慢熊（QQQ -35.1% vs U1 -31.5% · 后半程 5x 止盈锁利）",
            "start_date": "2021-11-15",
            "end_date": "2022-12-30",
            "crash_start_date": "2021-11-19",
            "crash_end_date": "2022-12-28",
            "is_live": False,
            "narrative_en": (
                "In 2022's frog-boiling grind, VIX/VIX3M peaked at just 1.022 (<1.10), so panic-inversion TP never fired. "
                "Track-2 Dual-TP (DTE<=45 & Put>=5x) stepped in on 2022-02-24 Open @$318.84 (32 DTE left, 5x+ deep ITM), "
                "harvesting +$37,680 (+121.86 extra QQQ shares!) right before March's dead-cat bounce, slashing 2022 MDD from -35.12% to -31.52% (+3.60% excess)!"
            ),
            "narrative_zh": (
                "2022 温水煮青蛙慢熊中 VIX/VIX3M 全年最高仅 1.022（未达 1.10 恐慌倒挂）；第二轨「后半程 DTE<=45 且 Put>=5x」精准补位："
                "在 2022-02-24 早盘 @$318.84（距到期 32 天、深实值超 5 倍）果断兑现 +$37,680（低位抄底 +121.86 股 QQQ），完美避开 3 月底反弹归零，100% 满仓将 2022 回撤从 -35.12% 砍至 -31.52%（超额 +3.60%）！"
            ),
        },
        {
            "id": "2024-08",
            "pill_en": "2024-08 Yen Carry",
            "pill_zh": "2024-08 日元闪崩",
            "title_en": "2024-08 Yen Carry Unwind Flash Crash (-13.6%)",
            "title_zh": "2024-08 日元套息交易平仓闪崩 (-13.6%)",
            "start_date": "2024-05-20",
            "end_date": "2024-09-06",
            "crash_start_date": "2024-07-10",
            "crash_end_date": "2024-08-07",
            "is_live": False,
            "narrative_en": (
                "4/6 Crisis Lights + AD divergence opened two 50% option slots right into the summer peak ($455.50 on 5/30 and "
                "$497.62 on 7/16). When the Yen carry unwind pushed VIX/VIX3M to 1.144 on 2024-08-05, both slots "
                "monetized at $437.23 Open on 8/06 for +$35,158 (+80.39 QQQ shares), slashing DD from -13.56% to -8.05% (+5.51% excess)!"
            ),
            "narrative_zh": (
                "4/6 危机灯与 AD 顶背离在 $455.50（5/30）与见顶处 $497.62（7/16）精准挂满双槽保护；"
                "8/05 日元闪崩引爆 VIX/VIX3M 至 1.144，8/06 开盘 @$437.23 双槽止盈落袋 +$35,158（低位白捡 +80.39 股 QQQ），回撤从 -13.56% 大砍至 -8.05%（超额 +5.51%）！"
            ),
        },
        {
            "id": "2025-04",
            "pill_en": "2025-04 Tariff Crash",
            "pill_zh": "2025-04 关税暴跌",
            "title_en": "2025-04 Tariff Liquidity Waterfall (-22.8%)",
            "title_zh": "2025-04 关税冲击流动性暴跌 (-22.8%)",
            "start_date": "2024-12-18",
            "end_date": "2025-05-16",
            "crash_start_date": "2025-02-19",
            "crash_end_date": "2025-04-08",
            "is_live": False,
            "narrative_en": (
                "Even with macro lights at only 2/6, US Liquid AD Line < 50DMA top-divergence caught the $539.52 top "
                "and opened a 50% Collar on 2025-02-24 @$527.88 (K_P=$475.09). On 2025-04-07 Open @$408.66 (VIX/3M 1.234), "
                "that single tranche harvested +$76,729 (+187.70 QQQ shares at the exact bottom!), slashing DD to -16.36% (+6.41% excess)!"
            ),
            "narrative_zh": (
                "即便宏观灯仅亮 2 盏，全美 AD Line < 50DMA 顶背离依然死死咬住 $539.52 大顶，于 2/24 @$527.88 开启 50% 保护（K_P=$475.09）；"
                "4/07 关税恐慌极值（倒挂 1.234）在 $408.66 铁底单笔暴赚 +$76,729，一把抄底 +187.70 股 QQQ，回撤压至 -16.36%（超额高达 +6.41%）！"
            ),
        },
        {
            "id": "2026-08_11_LIVE",
            "pill_en": "2026-11 LIVE",
            "pill_zh": "2026-11 实盘 LIVE",
            "title_en": "2026-08 to 2026-11 LIVE Pure-Options Campaign (-19.9% QQQ vs -17.5% U1)",
            "title_zh": "2026-08 至 2026-11 实盘 LIVE 纯期权双槽战役（QQQ -19.9% vs U1 -17.5%）",
            "start_date": "2026-08-24",
            "end_date": rows_eval[-1]["date"],
            "crash_start_date": "2026-10-06",
            "crash_end_date": rows_eval[-1]["date"],
            "is_live": True,
            "narrative_en": live_narr_en,
            "narrative_zh": live_narr_zh,
        },
    ]

    strat_keys = [
        "U1_PureOptions",
        "B1c_PureAD",
        "D2_SixLights",
        "H2_G4_PriceGate",
        "BH_Pure_QQQ",
    ]

    out_windows: list[dict[str, Any]] = []
    for sp in specs:
        c0 = date_to_idx[sp["crash_start_date"]]
        c1 = date_to_idx[sp["crash_end_date"]]
        z0_date = sp["start_date"]
        z1_date = sp["end_date"]

        bh_sub = sims["BH_Pure_QQQ"]["nav"][c0 : c1 + 1]
        q_ret = (bh_sub[-1] / bh_sub[0] - 1.0) * 100.0
        pk = bh_sub[0]
        q_mdd = 0.0
        for v in bh_sub:
            if v > pk:
                pk = v
            dd = (v / pk - 1.0) * 100.0
            if dd < q_mdd:
                q_mdd = dd

        ep_stats: dict[str, Any] = {}
        for sk in strat_keys:
            m_sub = sims[sk]["nav"][c0 : c1 + 1]
            m_ret = (m_sub[-1] / m_sub[0] - 1.0) * 100.0
            mpk = m_sub[0]
            m_mdd = 0.0
            for v in m_sub:
                if v > mpk:
                    mpk = v
                dd = (v / mpk - 1.0) * 100.0
                if dd < m_mdd:
                    m_mdd = dd
            led_in_win = [
                t
                for t in sims[sk]["ledger"]
                if (z0_date <= t["entry_date"] <= z1_date)
                or (
                    (t.get("exit_date") or t.get("mtm_date") or "") != ""
                    and z0_date <= (t.get("exit_date") or t.get("mtm_date")) <= z1_date
                )
            ]
            tp_harvested = sum(
                t["net_pnl_usd"]
                for t in led_in_win
                if ("tp" in t["exit_reason"] or t.get("is_open_live")) and t["net_pnl_usd"] > 0
            )
            tp_shares = sum(
                t["shares_added"]
                for t in led_in_win
                if ("tp" in t["exit_reason"] or t.get("is_open_live")) and t["shares_added"] > 0
            )
            net_pnl_all = sum(t["net_pnl_usd"] for t in led_in_win)
            ep_stats[sk] = {
                "ret_pct": round(m_ret, 2),
                "mdd_pct": round(m_mdd, 2),
                "dd_cushion_pct": round(m_mdd - q_mdd, 2),
                "excess_ret_pct": round(m_ret - q_ret, 2),
                "harvested_tp_usd": round(tp_harvested, 2),
                "shares_added_tp": round(tp_shares, 2),
                "net_option_pnl_usd": round(net_pnl_all, 2),
                "tranche_ids": [t["tranche_id"] for t in led_in_win],
            }

        peak_vr = max(float(rows_eval[j]["vix_ratio"]) for j in range(c0, c1 + 1))
        peak_lights = max(int(rows_eval[j]["score"]) for j in range(c0, c1 + 1))

        linked_ids = [
            ev["event_id"]
            for ev in unified_events
            if z0_date <= ev["date"] <= z1_date
        ]

        out_windows.append(
            {
                **sp,
                "qqq_ret_pct": round(q_ret, 2),
                "qqq_mdd": round(q_mdd, 2),
                "u1_mdd": ep_stats["U1_PureOptions"]["mdd_pct"],
                "b1c_mdd": ep_stats["B1c_PureAD"]["mdd_pct"],
                "d2_mdd": ep_stats["D2_SixLights"]["mdd_pct"],
                "h2_mdd": ep_stats["H2_G4_PriceGate"]["mdd_pct"],
                "excess_ret_u1": ep_stats["U1_PureOptions"]["excess_ret_pct"],
                "dd_cushion_u1": ep_stats["U1_PureOptions"]["dd_cushion_pct"],
                "peak_vix_ratio": round(peak_vr, 3),
                "peak_lights": peak_lights,
                "harvested_usd": ep_stats["U1_PureOptions"]["harvested_tp_usd"],
                "harvested_usd_u1": ep_stats["U1_PureOptions"]["harvested_tp_usd"],
                "shares_added": ep_stats["U1_PureOptions"]["shares_added_tp"],
                "shares_added_u1": ep_stats["U1_PureOptions"]["shares_added_tp"],
                "strategy_stats": ep_stats,
                "linked_event_ids": linked_ids,
            }
        )

    return out_windows


def build_unified_events(
    strategy_id: str,
    ledger: list[dict[str, Any]],
    shield_events: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for tr in ledger:
        is_nk = tr["tranche_type"] == "naked_put"
        ev_type = "slot1_naked_put" if is_nk else f"slot{tr['slot_num']}_collar"
        events.append(
            {
                "event_id": f"{strategy_id}_tr{tr['tranche_id']}_open",
                "tranche_id": tr["tranche_id"],
                "strategy_id": strategy_id,
                "date": tr["entry_date"],
                "signal_date": tr["signal_date"],
                "event_type": ev_type,
                "slot_num": tr["slot_num"],
                "tranche_type": tr["tranche_type"],
                "spot": tr["entry_spot"],
                "vxn": tr["entry_vxn"],
                "vix_ratio": tr["entry_vix_ratio"],
                "kp": tr["kp"],
                "kc": tr["kc"],
                "call_cap_pct": tr["call_cap_pct"],
                "entry_cost_usd": tr["entry_cost_usd"],
                "hedged_shares": tr["hedged_shares"],
                "sig_score": tr["sig_score"],
                "sig_ad_below50": tr["sig_ad_below50"],
                "trigger_en": tr["trigger_en"],
                "trigger_zh": tr["trigger_zh"],
                "linked_exit_date": tr["exit_date"],
                "linked_exit_spot": tr["exit_spot"],
                "linked_exit_reason": tr["exit_reason"],
                "net_pnl_usd": tr["net_pnl_usd"],
                "shares_added": tr["shares_added"],
                "delta_usd": tr["delta_usd"],
                "gamma_usd": tr["gamma_usd"],
                "vega_usd": tr["vega_usd"],
                "theta_slip_usd": tr["theta_slip_usd"],
            }
        )
        is_open_live = bool(tr.get("is_open_live"))
        is_live_armed = tr["exit_reason"] == "live_tp_armed_next_open"
        is_tp = ("tp" in tr["exit_reason"]) and not is_open_live
        is_put5x = "put_5x" in tr["exit_reason"]
        is_itm_tp = "itm_tp" in tr["exit_reason"]
        is_4x_tp = "4x_tp" in tr["exit_reason"]
        ev_exit_date = tr["exit_date"] if not is_open_live else tr.get("mtm_date")
        if (not is_open_live or is_live_armed) and ev_exit_date:
            if is_live_armed:
                ev_type_exit = "live_tp_armed"
                trig_en_exit = (
                    f"Deep-ITM Panic TP Armed ({tr['rem_dte_at_exit']} DTE left · VIX/3M {tr['exit_vix_ratio']:.3f} · Next Open)"
                )
                trig_zh_exit = (
                    f"实值恐慌止盈已触发（剩余 {tr['rem_dte_at_exit']} 天 · VIX/3M {tr['exit_vix_ratio']:.3f} · 待次日开盘换股）"
                )
            elif is_put5x:
                ev_type_exit = "put5x_dte45_tp"
                trig_en_exit = f"5x Put Slow-Bear TP ({tr['rem_dte_at_exit']} DTE <= 45, Deep ITM Lock)"
                trig_zh_exit = f"后半程 Put >= 5x 慢熊止盈（剩余 {tr['rem_dte_at_exit']} 天 <= 45 · 深实值锁利）"
            elif is_itm_tp:
                ev_type_exit = "vix110_itm_tp"
                trig_en_exit = f"Deep-ITM Panic TP (QQQ <= K_P & VIX/3M {tr['exit_vix_ratio']:.3f} >= 1.10)"
                trig_zh_exit = f"实值恐慌止盈（跌破行权价且 VIX/3M {tr['exit_vix_ratio']:.3f} >= 1.10）"
            elif is_4x_tp:
                ev_type_exit = "vix110_4x_tp"
                trig_en_exit = f"4x Deep Panic TP (Put >= 4x & VIX/3M {tr['exit_vix_ratio']:.3f} >= 1.10)"
                trig_zh_exit = f"4x 深度恐慌止盈（Put >= 4x 且 VIX/3M {tr['exit_vix_ratio']:.3f} >= 1.10）"
            elif is_tp:
                ev_type_exit = "vix110_tp"
                trig_en_exit = f"VIX/VIX3M {tr['exit_vix_ratio']:.3f} >= 1.10 Panic TP"
                trig_zh_exit = f"VIX/VIX3M {tr['exit_vix_ratio']:.3f} >= 1.10 恐慌止盈抄底"
            else:
                ev_type_exit = "option_expiry"
                trig_en_exit = f"90-DTE Expiry ({tr['underlying_ret_pct']:+.1f}% spot)"
                trig_zh_exit = f"90-DTE 到期结算（期间正股 {tr['underlying_ret_pct']:+.1f}%）"

            events.append(
                {
                    "event_id": f"{strategy_id}_tr{tr['tranche_id']}_exit",
                    "tranche_id": tr["tranche_id"],
                    "strategy_id": strategy_id,
                    "date": ev_exit_date,
                    "signal_date": tr["signal_date"],
                    "event_type": ev_type_exit,
                    "slot_num": tr["slot_num"],
                    "tranche_type": tr["tranche_type"],
                    "spot": tr["exit_spot"],
                    "vxn": tr["exit_vxn"],
                    "vix_ratio": tr["exit_vix_ratio"],
                    "kp": tr["kp"],
                    "kc": tr["kc"],
                    "call_cap_pct": tr["call_cap_pct"],
                    "entry_spot": tr["entry_spot"],
                    "entry_date": tr["entry_date"],
                    "entry_cost_usd": tr["entry_cost_usd"],
                    "hedged_shares": tr["hedged_shares"],
                    "sig_score": tr["sig_score"],
                    "sig_ad_below50": tr["sig_ad_below50"],
                    "trigger_en": trig_en_exit,
                    "trigger_zh": trig_zh_exit,
                    "net_pnl_usd": tr["net_pnl_usd"],
                    "shares_added": tr["shares_added"],
                    "delta_usd": tr["delta_usd"],
                    "gamma_usd": tr["gamma_usd"],
                    "vega_usd": tr["vega_usd"],
                    "theta_slip_usd": tr["theta_slip_usd"],
                    "convexity_mult": tr["convexity_mult"],
                }
            )

    for sev in shield_events:
        events.append(
            {
                "event_id": sev["event_id"],
                "tranche_id": None,
                "strategy_id": strategy_id,
                "date": sev["date"],
                "signal_date": sev["signal_date"],
                "event_type": sev["event_type"],
                "slot_num": 0,
                "tranche_type": "slow_bear_shield",
                "spot": sev["spot"],
                "vxn": None,
                "vix_ratio": sev["vix_ratio"],
                "kp": None,
                "kc": None,
                "call_cap_pct": None,
                "entry_cost_usd": 0.0,
                "hedged_shares": abs(sev["shares_delta"]),
                "sig_score": sev["raw_lights"],
                "sig_ad_below50": True,
                "trigger_en": sev["trigger_en"],
                "trigger_zh": sev["trigger_zh"],
                "net_pnl_usd": None,
                "shares_added": sev["shares_delta"],
                "delta_usd": None,
                "gamma_usd": None,
                "vega_usd": None,
                "theta_slip_usd": None,
            }
        )

    order_rank = {
        "vix110_tp": 1,
        "vix110_itm_tp": 1,
        "vix110_4x_tp": 1,
        "put5x_dte45_tp": 1,
        "live_tp_armed": 1,
        "option_expiry": 2,
        "shield_enter": 3,
        "shield_exit": 4,
        "slot1_naked_put": 5,
        "slot1_collar": 6,
        "slot2_collar": 7,
        "slot3_collar": 8,
    }
    events.sort(key=lambda e: (e["date"], order_rank.get(e["event_type"], 99)))
    return events


def build_artifact(fact_root: Path | None = None) -> dict[str, Any]:
    rows_all, coeffs = load_seed_and_extend(fact_root=fact_root)
    rows_eval = [r for r in rows_all if r["date"] >= START_DATE]

    strategy_defs = [
        (
            "U1_PureOptions",
            {
                "arch": "hybrid_campaign_first",
                "max_slots": 2,
                "slot_coverage": 0.50,
                "gate_key": "sw_u1",
                "vix_ratio_tp": 1.10,
                "slow_bear_overlay": False,
            },
            {
                "code_name": "U1_AD_or_Score4_VXN22_H2_2x50",
                "name_en": "U1 Pure Options Champion (100% QQQ + AD/4-Light First-Naked 2x50%)",
                "name_zh": "U1 纯期权总冠军（100% 满仓 QQQ + AD背离/四灯 首裸次领口）",
                "short_en": "U1 Pure Options",
                "short_zh": "U1 纯期权冠军",
                "badge_en": "FLAGSHIP #1 · 100% QQQ PURE OPTIONS",
                "badge_zh": "纯期权总冠军 · 永不卖股",
                "color_hex": "#80C6A8",
                "rule_summary_en": "100% QQQ core forever; opens Slot 1 50% Naked -10% Put + Slot 2 50% 30D-stepped Collar on (AD<50DMA or >=4 Lights) & ATH<=5% & VXN<=22; Dual-Track TP monetizes into QQQ shares on VIX/VIX3M >= 1.10 OR (DTE <= 45 & Put Bid >= 5x entry cost).",
                "rule_summary_zh": "底仓 100% QQQ 永不卖股择时；在 ATH<=5% 且 VXN<=22 时凭 AD 顶背离或 >=4 盏危机灯开首仓 50% 裸 Put、满30天补次仓 50% 零成本 Collar；双轨止盈（VIX/VIX3M >= 1.10 恐慌倒挂，或后半程 DTE <= 45 且 Put 涨超 5 倍）变现抄底复投 QQQ。",
            },
        ),
        (
            "B1c_PureAD",
            {
                "arch": "hybrid_campaign_first",
                "max_slots": 2,
                "slot_coverage": 0.50,
                "gate_key": "sw_b1c",
                "vix_ratio_tp": 1.10,
                "slow_bear_overlay": False,
            },
            {
                "code_name": "B1c_AD_Below50MA_VXN22_H2_2x50",
                "name_en": "B1c Pure AD-Line Top-Divergence Switch (First-Naked 2x50%)",
                "name_zh": "B1c 纯 AD 腾落线顶背离开关（首仓裸 Put · 仅 31% 天数持盾）",
                "short_en": "B1c Pure AD Line",
                "short_zh": "B1c 纯 AD 背离",
                "badge_en": "HIGHEST EFFICIENCY · 31% HEDGED",
                "badge_zh": "极简高效率 · 仅31%持盾",
                "color_hex": "#7DB8F0",
                "rule_summary_en": "Fires strictly when QQQ is within 5% of ATH, VXN<=22, and US Liquid Common-Stock AD Line < 50DMA (only 23 tranches in 11.9 years, +$178 alpha per hedged day).",
                "rule_summary_zh": "仅在 QQQ 距前高<=5%、VXN<=22 且全美 AD Line 跌破 50DMA 形成顶背离时上盾；11.9 年仅出手 23 笔，单持盾日创造 +$178 净超额。",
            },
        ),
        (
            "D2_SixLights",
            {
                "arch": "all_collar",
                "max_slots": 3,
                "slot_coverage": 1.0 / 3.0,
                "gate_key": "sw_d2",
                "vix_ratio_tp": 1.10,
                "slow_bear_overlay": False,
            },
            {
                "code_name": "D2_Score4_ATH5_Collar3x33",
                "name_en": "D2 Druckenmiller >=4 Crisis Lights Confirmation (3x33% Zero-Cost Collar)",
                "name_zh": "D2 德鲁肯米勒 >=4 盏危机灯确认（3x33% 零保费领口梯队）",
                "short_en": "D2 >=4 Lights Collar",
                "short_zh": "D2 四灯零保费领口",
                "badge_en": "$0 PREMIUM SPENT · 29% HEDGED",
                "badge_zh": "零保费支出 · 宏观确认",
                "color_hex": "#B8A1EA",
                "rule_summary_en": "Zero out-of-pocket premium: opens 3x33.3% 90-DTE Zero-Cost Collars only when >=4/6 Druckenmiller Crisis Lights are ON while QQQ is within 5% of ATH.",
                "rule_summary_zh": "零现金保费支出：仅当德鲁肯米勒六大危机灯亮起 >=4 盏且 QQQ 处于 ATH<=5% 高位时分三档挂零成本 Collar（若去掉 ATH<=5% 门控则倒亏 -$409K）。",
            },
        ),
        (
            "H2_G4_PriceGate",
            {
                "arch": "hybrid_campaign_first",
                "max_slots": 2,
                "slot_coverage": 0.50,
                "gate_key": "sw_g4",
                "vix_ratio_tp": 1.10,
                "slow_bear_overlay": False,
            },
            {
                "code_name": "H2_2x50_G4_TP110",
                "name_en": "H2 Price/Momentum Gate Baseline (ATH<=5% & YoY>=30% & VXN<=20)",
                "name_zh": "H2 传统价格动量门控基准（ATH<=5% 且 年涨>=30% 且 VXN<=20）",
                "short_en": "H2 Price Gate",
                "short_zh": "H2 价格门控基准",
                "badge_en": "LEGACY PRICE GATE",
                "badge_zh": "传统价格门控对照",
                "color_hex": "#64748B",
                "rule_summary_en": "Pure price/volatility gate without internal AD breadth or macro lights (missed 2015-08 & 2026-11 tops when YoY < 30%).",
                "rule_summary_zh": "不含市场宽度与宏观灯的纯价格涨幅门控对照（在年涨幅未满 30% 的 2015-08 与 2026-11 顶部漏开保护，超额仅 +$92.4K）。",
            },
        ),
        (
            "BH_Pure_QQQ",
            {
                "arch": "pure_qqq",
                "max_slots": 1,
                "slot_coverage": 0.0,
                "gate_key": None,
                "vix_ratio_tp": None,
                "slow_bear_overlay": False,
            },
            {
                "code_name": "BH_Pure_QQQ",
                "name_en": "Pure QQQ Buy & Hold ($200K Unhedged DRIP Benchmark)",
                "name_zh": "Pure QQQ 拿着不动基准（$200K 股息全复投无保护）",
                "short_en": "Pure QQQ Hold",
                "short_zh": "QQQ 拿着不动",
                "badge_en": "BENCHMARK",
                "badge_zh": "被动持有基准",
                "color_hex": "#EC8C98",
                "rule_summary_en": "100% unhedged QQQ Buy & Hold with full dividend reinvestment ($200,000 initial capital on 2015-01-02).",
                "rule_summary_zh": "2015-01-02 起 $200,000 买入 QQQ 拿着不动并股息复投，承受全部 -35.12% 深熊回撤。",
            },
        ),
    ]

    last_row = rows_eval[-1]
    as_of_date = last_row["date"]
    qqq_cl = float(last_row["close"])
    qqq_ma200 = float(last_row["qqq_ma200"])

    # Simulate Buy & Hold once (identical across all TP modes)
    bh_def = [d for d in strategy_defs if d[0] == "BH_Pure_QQQ"][0]
    bh_sim = simulate_strategy(rows_all, coeffs, strategy_id="BH_Pure_QQQ", **bh_def[1])
    bh_summary = {**bh_sim["summary"], **bh_def[2]}

    tp_modes_bundle: dict[str, Any] = {}
    tp_modes_meta: list[dict[str, Any]] = []

    for mode_spec in TP_MODE_SPECS:
        mode_id = mode_spec["id"]
        sims_m: dict[str, dict[str, Any]] = {"BH_Pure_QQQ": bh_sim}
        summaries_m: list[dict[str, Any]] = []
        ledgers_m: dict[str, list[dict[str, Any]]] = {}
        events_m: dict[str, list[dict[str, Any]]] = {}
        live_states_by_strat_m: dict[str, dict[str, Any]] = {}

        for sid, sim_kw, meta in strategy_defs:
            if sid == "BH_Pure_QQQ":
                summaries_m.append(bh_summary)
                continue
            res = simulate_strategy(rows_all, coeffs, strategy_id=sid, tp_mode=mode_id, **sim_kw)
            sims_m[sid] = res
            summaries_m.append({**res["summary"], **meta})
            ledgers_m[sid] = res["ledger"]
            events_m[sid] = build_unified_events(sid, res["ledger"], [])
            live_states_by_strat_m[sid] = build_live_signal_state(last_row, res, tp_mode=mode_id)

        windows_m = build_crisis_windows(rows_eval, sims_m, events_m["U1_PureOptions"], tp_mode=mode_id)
        u1_sum = next(s for s in summaries_m if s["id"] == "U1_PureOptions")
        tp_modes_meta.append(
            {
                **mode_spec,
                "u1_end_nav": u1_sum["end_nav"],
                "u1_net_alpha_usd": u1_sum["net_alpha_usd"],
                "u1_cagr_pct": u1_sum["cagr_pct"],
                "u1_max_dd_pct": u1_sum["max_dd_pct"],
                "u1_sharpe": u1_sum["sharpe"],
                "u1_extra_shares": u1_sum["extra_shares_vs_bh"],
            }
        )
        tp_modes_bundle[mode_id] = {
            "live_signal_state": live_states_by_strat_m["U1_PureOptions"],
            "live_signal_states_by_strategy": live_states_by_strat_m,
            "strategies_summary": summaries_m,
            "events_by_strategy": events_m,
            "trade_ledgers_by_strategy": ledgers_m,
            "crisis_windows": windows_m,
            "nav_u1": [round(v, 2) for v in sims_m["U1_PureOptions"]["nav"]],
            "nav_b1c": [round(v, 2) for v in sims_m["B1c_PureAD"]["nav"]],
            "nav_d2": [round(v, 2) for v in sims_m["D2_SixLights"]["nav"]],
            "nav_h2": [round(v, 2) for v in sims_m["H2_G4_PriceGate"]["nav"]],
            "active_slots": [int(v) for v in sims_m["U1_PureOptions"]["active_slots"]],
            "slot1_naked": [bool(v) for v in sims_m["U1_PureOptions"]["slot1_naked"]],
        }

    default_bundle = tp_modes_bundle[DEFAULT_TP_MODE]
    strategies_summary = default_bundle["strategies_summary"]
    trade_ledgers_by_strategy = default_bundle["trade_ledgers_by_strategy"]
    events_by_strategy = default_bundle["events_by_strategy"]
    live_signal_state = default_bundle["live_signal_state"]
    live_signal_states_by_strategy = default_bundle["live_signal_states_by_strategy"]
    crisis_windows = default_bundle["crisis_windows"]

    live_market_snapshot = {
        "as_of_date": as_of_date,
        "qqq_close": round(qqq_cl, 2),
        "qqq_open": round(float(last_row["open"]), 2),
        "running_ath": round(float(last_row["running_ath"]), 2),
        "dd_from_ath_pct": round(float(last_row["dd_from_ath"]) * 100.0, 2),
        "qqq_ma200": round(qqq_ma200, 2),
        "vs_ma200_pct": round((qqq_cl / qqq_ma200 - 1.0) * 100.0, 2),
        "below_ma200": bool(qqq_cl < qqq_ma200),
        "vix": round(float(last_row["vix"]), 2),
        "vix3m": round(float(last_row["vix3m"]), 2),
        "vix_vix3m_ratio": round(float(last_row["vix_ratio"]), 3),
        "vix_backwardation": bool(float(last_row["vix_ratio"]) >= 1.0),
        "vix_tp_triggered": bool(float(last_row["vix_ratio"]) >= 1.10),
        "vxn": round(float(last_row["vxn"]), 2),
        "rf_3m_pct": round(float(last_row["r"]) * 100.0, 2),
        "ad_line": round(float(last_row["ad_line"]), 0),
        "ad_sma50": round(float(last_row["ad_sma50"]), 0),
        "ad_vs_50ma": round(float(last_row["ad_line"]) - float(last_row["ad_sma50"]), 0),
        "ad_vs_50ma_pct": round(
            (float(last_row["ad_line"]) / float(last_row["ad_sma50"]) - 1.0) * 100.0, 2
        ),
        "pct_above_200d": round(float(last_row["pct_200d"]) * 100.0, 1),
        "smooth_crisis_score_5d": round(float(last_row["score_5d"]), 2),
        "smooth_5d_score": round(float(last_row["score_5d"]), 2),
        "raw_crisis_score": int(last_row["score"]),
        "total_crisis_lights": 6,
    }

    six_crisis_lights = build_six_crisis_lights(last_row)
    ad_line_signal = build_ad_line_signal(rows_all, len(rows_all) - 1)

    daily_series: list[dict[str, Any]] = []
    for i, r in enumerate(rows_eval):
        mask = (
            (1 if r["sig1_fed"] else 0)
            | (2 if r["sig2_credit"] else 0)
            | (4 if r["sig3_breadth"] else 0)
            | (8 if r["sig4_copper"] else 0)
            | (16 if r["sig5_defensive"] else 0)
            | (32 if r["sig6_macro"] else 0)
        )
        daily_series.append(
            {
                "date": r["date"],
                "qqq_close": round(float(r["close"]), 2),
                "qqq_ma200": round(float(r["qqq_ma200"]), 2),
                "running_ath": round(float(r["running_ath"]), 2),
                "dd_ath_pct": round(float(r["dd_from_ath"]) * 100.0, 2),
                "nav_bh": round(bh_sim["nav"][i], 2),
                "nav_u1": default_bundle["nav_u1"][i],
                "nav_b1c": default_bundle["nav_b1c"][i],
                "nav_d2": default_bundle["nav_d2"][i],
                "nav_h2": default_bundle["nav_h2"][i],
                "crisis_lights": int(r["score"]),
                "smooth_lights": round(float(r["score_5d"]), 2),
                "lights_mask": mask,
                "ad_line": round(float(r["ad_line"]), 0),
                "ad_sma50": round(float(r["ad_sma50"]), 0),
                "ad_vs_50ma": round(float(r["ad_line"]) - float(r["ad_sma50"]), 0),
                "pct_200d": round(float(r["pct_200d"]) * 100.0, 1),
                "vix": round(float(r["vix"]), 2),
                "vix3m": round(float(r["vix3m"]), 2),
                "vix_ratio": round(float(r["vix_ratio"]), 3),
                "vxn": round(float(r["vxn"]), 2),
                "active_slots": default_bundle["active_slots"][i],
                "slot1_naked": default_bundle["slot1_naked"][i],
            }
        )

    default_events = events_by_strategy["U1_PureOptions"]

    return {
        "version": ARTIFACT_VERSION,
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "as_of_date": as_of_date,
        "asOfDate": as_of_date,
        "dataThrough": as_of_date,
        "evaluation_window": {
            "start_date": rows_eval[0]["date"],
            "end_date": as_of_date,
            "trading_days": len(rows_eval),
            "initial_capital_usd": INITIAL_CAPITAL,
            "execution_convention": "Strict Zero-Lookahead: EOD signal on day t -> executed at day t+1 Open",
            "pricing_calibration": "OPRA 53,347-print 90-DTE skew polynomial + 2.5% per-leg option slippage + 3 bps stock rebalance fee",
        },
        "default_strategy_id": "U1_PureOptions",
        "strategy_order": [s["id"] for s in strategies_summary],
        "default_tp_mode": DEFAULT_TP_MODE,
        "tp_mode": DEFAULT_TP_MODE,
        "tp_modes_meta": tp_modes_meta,
        "tp_modes": tp_modes_bundle,
        "live_market_snapshot": live_market_snapshot,
        "live_signal_state": live_signal_state,
        "live_signal_states_by_strategy": live_signal_states_by_strategy,
        "six_crisis_lights": six_crisis_lights,
        "ad_line_signal": ad_line_signal,
        "strategies_summary": strategies_summary,
        "daily_series": daily_series,
        "events": default_events,
        "events_by_strategy": events_by_strategy,
        "trade_ledger": trade_ledgers_by_strategy["U1_PureOptions"],
        "trade_ledgers_by_strategy": trade_ledgers_by_strategy,
        "shield_events": [],
        "crisis_windows": crisis_windows,
    }


def verify_artifact(doc: dict[str, Any]) -> None:
    raw_txt = json.dumps(doc, ensure_ascii=False)
    if chr(126) in raw_txt:
        raise AssertionError("Artifact contains forbidden ASCII tilde character!")
    for banned in (
        "FactOS",
        "FACT OS",
        "fact_os",
        "DuckDB",
        "Sharadar",
        "SQLite",
        "U4_DualEngine",
        "T-Bill",
        "slow_bear_shield",
        "美债慢熊盾",
        "慢熊盾",
        "短债",
    ):
        if banned in raw_txt:
            raise AssertionError(f"Artifact contains forbidden identifier: {banned}")

    snap = doc["live_market_snapshot"]
    assert doc["default_strategy_id"] == "U1_PureOptions", doc["default_strategy_id"]
    assert doc["default_tp_mode"] == "layered_itm", doc["default_tp_mode"]
    assert doc["tp_mode"] == "layered_itm", doc["tp_mode"]
    assert set(doc["tp_modes"].keys()) == {"layered_itm", "standard_dual", "both_4x"}
    assert doc["as_of_date"] >= "2026-11-20"
    if doc["as_of_date"] == "2026-11-20":
        assert snap["qqq_close"] == 608.45, snap["qqq_close"]
        assert snap["running_ath"] == 759.66, snap["running_ath"]
        assert snap["dd_from_ath_pct"] == -19.90, snap["dd_from_ath_pct"]
        assert snap["vix"] == 35.89, snap["vix"]
        assert snap["vix3m"] == 30.94, snap["vix3m"]
        assert snap["vix_vix3m_ratio"] == 1.160, snap["vix_vix3m_ratio"]
        assert snap["vxn"] == 45.25, snap["vxn"]
        assert snap["raw_crisis_score"] == 6, snap["raw_crisis_score"]
        assert all(l["lit"] for l in doc["six_crisis_lights"]), "All 6 lights must be ON on 2026-11-20"

        smap = {s["id"]: s for s in doc["strategies_summary"]}
        assert "U4_DualEngine" not in smap
        assert abs(smap["BH_Pure_QQQ"]["end_nav"] - 1288304.78) <= 0.02, smap["BH_Pure_QQQ"]["end_nav"]
        # Default mode: layered_itm (Collar@1.10 | NakedPut ITM Spot<=K_P | Track-2 DTE<=45 & Put>=5x)
        assert abs(smap["U1_PureOptions"]["end_nav"] - 1654577.25) <= 1.0, smap["U1_PureOptions"]["end_nav"]
        assert abs(smap["U1_PureOptions"]["net_alpha_usd"] - 366272.47) <= 1.0, smap["U1_PureOptions"]["net_alpha_usd"]
        assert smap["U1_PureOptions"]["cagr_pct"] == 19.46, smap["U1_PureOptions"]["cagr_pct"]
        assert smap["U1_PureOptions"]["max_dd_pct"] == -31.52, smap["U1_PureOptions"]["max_dd_pct"]
        assert abs(smap["B1c_PureAD"]["end_nav"] - 1587800.99) <= 1.0, smap["B1c_PureAD"]["end_nav"]
        assert abs(smap["D2_SixLights"]["end_nav"] - 1497620.82) <= 1.0, smap["D2_SixLights"]["end_nav"]
        assert abs(smap["H2_G4_PriceGate"]["end_nav"] - 1402250.68) <= 1.0, smap["H2_G4_PriceGate"]["end_nav"]

        std_map = {s["id"]: s for s in doc["tp_modes"]["standard_dual"]["strategies_summary"]}
        assert abs(std_map["U1_PureOptions"]["end_nav"] - 1625377.79) <= 1.0, std_map["U1_PureOptions"]["end_nav"]
        d4x_map = {s["id"]: s for s in doc["tp_modes"]["both_4x"]["strategies_summary"]}
        assert abs(d4x_map["U1_PureOptions"]["end_nav"] - 1643122.56) <= 1.0, d4x_map["U1_PureOptions"]["end_nav"]

    assert len(doc["six_crisis_lights"]) == 6
    assert len(doc["crisis_windows"]) == 7
    assert len(doc["daily_series"]) >= 2990

    # Verify exact 4-factor convexity decomposition identity on every option tranche across ALL TP modes
    for mode_id, mode_bundle in doc["tp_modes"].items():
        for sid, led in mode_bundle["trade_ledgers_by_strategy"].items():
            for tr in led:
                four_sum = tr["delta_usd"] + tr["gamma_usd"] + tr["vega_usd"] + tr["theta_slip_usd"]
                if abs(four_sum - tr["net_pnl_usd"]) > 0.05:
                    raise AssertionError(
                        f"4-factor convexity mismatch in {mode_id}/{sid} #{tr['tranche_id']}: {four_sum} vs {tr['net_pnl_usd']}"
                    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Build Crisis Observatory JSON artifact.")
    parser.add_argument("--fact-root", type=Path, default=DEFAULT_FACT_ROOT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    doc = build_artifact(fact_root=args.fact_root)
    verify_artifact(doc)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    size_kb = args.output.stat().st_size / 1024.0
    smap = {s["id"]: s for s in doc["strategies_summary"]}
    print(
        f"OK: verified {args.output} ({size_kb:.1f} KB) | as_of_date={doc['as_of_date']} | "
        f"days={len(doc['daily_series'])} | U1=${smap['U1_PureOptions']['end_nav']:,.2f} "
        f"(+${smap['U1_PureOptions']['net_alpha_usd']:,.2f}) | BH=${smap['BH_Pure_QQQ']['end_nav']:,.2f}"
    )


if __name__ == "__main__":
    main()
