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
import importlib.util
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any

try:
    import duckdb
except ImportError:
    duckdb = None

ROOT_DIR = Path(__file__).resolve().parent.parent
SEED_GZ = ROOT_DIR / "server" / "config" / "crisis-observatory-seed-inputs.json.gz"
M7_SEED_GZ = ROOT_DIR / "server" / "config" / "crisis-observatory-m7-inputs.json.gz"
REAL_QUOTES_GZ = ROOT_DIR / "server" / "config" / "crisis-observatory-real-quotes.json.gz"
DEFAULT_OUT = ROOT_DIR / "server" / "config" / "crisis-observatory-dashboard.json"
DEFAULT_FACT_ROOT = ROOT_DIR / "data" / "fact_os"

_ROC_SPEC = importlib.util.spec_from_file_location(
    "real_option_chain", Path(__file__).resolve().parent / "real_option_chain.py"
)
assert _ROC_SPEC is not None and _ROC_SPEC.loader is not None
roc = importlib.util.module_from_spec(_ROC_SPEC)
_ROC_SPEC.loader.exec_module(roc)

_M7_SPEC = importlib.util.spec_from_file_location(
    "m7_crisis_engine", Path(__file__).resolve().parent / "m7_crisis_engine.py"
)
assert _M7_SPEC is not None and _M7_SPEC.loader is not None
m7e = importlib.util.module_from_spec(_M7_SPEC)
_M7_SPEC.loader.exec_module(m7e)

ARTIFACT_VERSION = "crisis-observatory-v2"
START_DATE = "2015-01-02"
INITIAL_CAPITAL = 200_000.0
DEFAULT_SLIPPAGE = 0.025
STOCK_REBAL_FEE = 0.0003
DEFAULT_TP_MODE = "layered_itm"
DEFAULT_CC_MODE = "cc_off"
DEFAULT_SP_MODE = "sp_off"
DEFAULT_WC_MODE = "wc_reclaim_30d_d35"
MARGIN_SPREAD = 0.015
OPT_COMM_PER_SH = 0.0065
MIN_OPT_BID = 0.05

WC_MODE_SPECS: list[dict[str, Any]] = [
    {
        "id": "wc_reclaim_30d_d35",
        "label_en": "Reclaim K -> 30D 0.35Δ (Rec.)",
        "label_zh": "涨回接货价卖 30D 0.35Δ（推荐）",
        "short_en": "Reclaim -> 30D 0.35Δ",
        "short_zh": "涨回成本卖 30D 0.35Δ",
        "formula_en": "Hold uncapped while QQQ < K_assign; once QQQ >= K_assign sell 30D 0.35Δ Call",
        "formula_zh": "接货水下零封顶死拿，待 QQQ 涨回 >= 接货行权价后卖 30D 0.35Δ Call",
        "summary_en": "When assigned, holds shares 100% uncapped below K_assign; once QQQ EOD reclaims K_assign, sells a volatility-scaled 30D 0.35-Delta Call (max(K_assign, K_35Δ)) for richer premium ($1,838,505 on 10D VIX-Falling, $1,805,856 on 10% Cap, $1,901,035 on 20% Cap).",
        "summary_zh": "接股后水下阶段不卖 Call（100% 保留深坑反弹），待收盘涨回接货行权价 K 后次日开盘按 30D 0.35Δ 动态卖 Call（收租增厚 77% · 10D VIX回落档升至 $1,838,505、10%帽 $1,805,856、20%帽 $1,901,035）。",
    },
    {
        "id": "wc_30d_c5s5",
        "label_en": "30D +5% Cost/Spot (Immediate)",
        "label_zh": "30D 双+5%（立即卖）",
        "short_en": "30D +5% Cost/Spot",
        "short_zh": "30D 双+5%",
        "formula_en": "max(1.05x Cost, 1.05x Spot)",
        "formula_zh": "max(1.05×成本, 1.05×现价)",
        "summary_en": "Immediately after assignment sells 30D Reverse Wheel Call at max(1.05*K_assign, 1.05*S) — captures +5% post-crash V-rebound before clearing margin debt within <= 111d (Calmar 0.685 on 10% Cap, $1,930,239 on 20% Cap).",
        "summary_zh": "接货次日即卖 30D 反向 Wheel Call，行权价 max(1.05×成本, 1.05×现价)——锁住灾后 +5% V 反利润且最长 111 天清债去杠杆（10%帽 Calmar 0.685，20%帽终值 $1,930,239）。",
    },
    {
        "id": "wc_14d_c0s2",
        "label_en": "14D Breakeven+2% (Legacy)",
        "label_zh": "14D 保本+2%（原基准）",
        "short_en": "14D Breakeven+2%",
        "short_zh": "14D 保本+2%",
        "formula_en": "max(Cost, 1.02x Spot)",
        "formula_zh": "max(成本, 1.02×现价)",
        "summary_en": "Legacy fast-turnover exit: sells 14D (or 10D) Wheel Call at max(K_assign, 1.02*S) for fastest debt clearance ($817 12-yr interest on 10% Cap).",
        "summary_zh": "原快周转基准：按 max(成本, 1.02×现价) 卖 14D（或 10D）保本上移 Call，清债最快（10%帽 12 年总利息仅 $817）。",
    },
]

SP_MODE_SPECS: list[dict[str, Any]] = [
    {
        "id": "sp_off",
        "label_en": "Off (0 Leverage)",
        "label_zh": "关闭（0 杠杆）",
        "short_en": "Off (0 Lev)",
        "short_zh": "关闭（0 杠杆）",
        "summary_en": "Engine 3 disabled (0 margin interest, max stock leverage strictly 1.00x). Isolates Engine 1 crisis protection on real OPRA quotes.",
        "summary_zh": "关闭第三引擎（0 融资利息、股票总敞口严格 1.00x），独立检验引擎 1 危机买 Put 的真实 OPRA 盘口表现。",
    },
    {
        "id": "sp_14d_cap10",
        "label_en": "14D 10% Cap (Balanced · Rec.)",
        "label_zh": "14D 10%帽（稳健 · 推荐）",
        "short_en": "14D 10% Cap",
        "short_zh": "14D 10%帽",
        "summary_en": "Sells 14D 5% OTM Put on VIX/VIX3M >= 1.00 capped at <= 10% equity; if assigned, holds uncapped until QQQ reclaims K_assign then sells 30D 0.35Δ Wheel Call. Positive real-OPRA alpha while reducing MDD.",
        "summary_zh": "VIX/VIX3M >= 1.00 卖 14D 5% OTM Put（名义严控 <= 10% 净值）；若接货默认水下不封顶，等涨回接货价后再卖 30D 0.35Δ Call——真实 OPRA 盘口下仍稳健增厚收益并压缩最大回撤。",
    },
    {
        "id": "sp_10d_vixf",
        "label_en": "10D VIX Falling (20% Cap)",
        "label_zh": "10D VIX回落（20%帽 · 拐点过滤）",
        "short_en": "10D VIX Falling (20%)",
        "short_zh": "10D VIX回落（20%帽）",
        "summary_en": "Requires VIX/VIX3M >= 1.00 AND VIX[t] < VIX[t-1] (panic cresting) before selling 10D 5% OTM Put (<= 20% cap) + Reclaim 30D 0.35Δ Wheel; fewer trades and lower assignment frequency.",
        "summary_zh": "要求 VIX/VIX3M >= 1.00 且当日 VIX 回落（恐慌见顶拐头）才卖 10D 5% OTM Put（<= 20% 名义帽）+ 涨回接货价卖 30D 0.35Δ Call——过滤急跌首日接飞刀，交易更精简。",
    },
    {
        "id": "sp_14d_unf",
        "label_en": "14D Unfiltered (20% Cap · NAV #1)",
        "label_zh": "14D 无过滤（20%帽 · 收益冠军）",
        "short_en": "14D Unfiltered (20%)",
        "short_zh": "14D 无过滤（20%帽）",
        "summary_en": "Sells 14D 5% OTM Put whenever VIX/VIX3M >= 1.00 capped at <= 20% equity + Reclaim 30D 0.35Δ Reverse Wheel. Highest real-OPRA terminal NAV and Calmar.",
        "summary_zh": "只要 VIX/VIX3M >= 1.00 即卖 14D 5% OTM Put（<= 20% 名义帽）+ 涨回接货价卖 30D 0.35Δ Call——真实 OPRA 盘口下终值与 Calmar 双冠军。",
    },
]

CC_MODE_SPECS: list[dict[str, Any]] = [
    {
        "id": "cc_off",
        "label_en": "Off (Rec. · Real-OPRA Optimal)",
        "label_zh": "关闭（推荐 · 真实 OPRA 最优）",
        "short_en": "Off",
        "short_zh": "关闭",
        "summary_en": "Zero normal-time covered calls (100% uncapped bull upside). Under real OPRA bid-ask spreads and calm-regime call skew, leaving Engine 2 Off beats selling 12-Delta calls.",
        "summary_zh": "平时不卖 Call（100% 保留牛市主升浪）。经真实 OPRA 盘口与买卖价差检验，平时卖 12Δ Call 的低权利金难以覆盖真实价差与急涨止损损耗，默认关闭表现最优。",
    },
    {
        "id": "cc_d12_d35",
        "label_en": "12Δ · Delta 0.35 Stop (Compare)",
        "label_zh": "全天候 12Δ · Delta 0.35 止损（对照）",
        "short_en": "12Δ · Δ0.35 Stop",
        "short_zh": "12Δ · Delta 0.35 止损",
        "summary_en": "Whenever within 3% of ATH, sells 25D 12-Delta (min +5% OTM) Calls and exits early at Delta >= 0.35. Real OPRA calm-regime spreads create slight net drag vs Off (kept for transparent comparison).",
        "summary_zh": "距前高 <= 3% 卖 25D 12Δ（保底 +5% OTM）Call，Delta >= 0.35 止损平仓；真实 OPRA 实盘价差下呈小幅负贡献（保留供实盘透明对照）。",
    },
    {
        "id": "cc_d12_r45",
        "label_en": "12Δ · Delta 0.45 Roll Up (30D)",
        "label_zh": "全天候 12Δ · Delta 0.45 展期 Roll（30D 上移）",
        "short_en": "12Δ · Δ0.45 Roll",
        "short_zh": "12Δ · Delta 0.45 展期 Roll",
        "summary_en": "Whenever within 3% of ATH, sells 25D 12-Delta Calls; when Delta >= 0.45, buys back and immediately rolls out +30D to a fresh higher 12-Delta strike on real OPRA quotes.",
        "summary_zh": "距前高 <= 3% 全天候卖 25D 12Δ Call；当 Delta 升至 0.45 时立刻平旧仓并同步展期 30 天上移至新 12Δ 高行权价（真实 OPRA 盘口执行）。",
    },
    {
        "id": "cc_d12_cr55",
        "label_en": "12Δ · Delta 0.55 Credit Roll (45D)",
        "label_zh": "全天候 12Δ · Delta 0.55 零成本 Roll（45D）",
        "short_en": "12Δ · Δ0.55 Credit Roll",
        "short_zh": "12Δ · Delta 0.55 零成本 Roll",
        "summary_en": "Whenever within 3% of ATH, sells 25D 12-Delta Calls; when Delta >= 0.55, attempts a zero-cost credit roll out +45D to the highest OTM strike covering the buyback on real OPRA quotes.",
        "summary_zh": "距前高 <= 3% 全天候卖 25D 12Δ Call；当 Delta 升至 0.55 时尝试向后展期 45 天做零成本上移 Roll（真实 OPRA 盘口若无虚值零成本可展则直接平仓）。",
    },
]

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


def bsm_call_delta(S: float, K: float, T: float, r: float, q: float, sigma: float) -> float:
    if T <= 1e-8 or sigma <= 1e-8:
        return 1.0 if S > K else 0.0
    d1 = (math.log(S / K) + (r - q + 0.5 * sigma * sigma) * T) / (sigma * math.sqrt(T))
    return math.exp(-q * T) * _norm_cdf(d1)


def solve_call_strike_for_bid(
    S: float,
    T: float,
    r: float,
    q: float,
    vxn_pct: float,
    poly_coeffs: list[float],
    target_bid: float,
    slip: float = DEFAULT_SLIPPAGE,
) -> float | None:
    if target_bid < 0.05:
        return None
    lo, hi = S * 1.01, S * 1.40

    def bid_at(k_c: float) -> float:
        sig = eval_skew_iv(S, k_c, T, r, q, vxn_pct, poly_coeffs)
        return bsm_price(S, k_c, T, r, q, sig, "call") * (1.0 - slip)

    if bid_at(lo) < target_bid:
        return None
    for _ in range(30):
        mid = 0.5 * (lo + hi)
        if bid_at(mid) >= target_bid:
            lo = mid
        else:
            hi = mid
    return lo


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

    for idx, r in enumerate(rows):
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
        cur_vix = float(r.get("vix") or 0.0)
        prev_vix = float(rows[idx - 1].get("vix") or cur_vix) if idx > 0 else cur_vix
        r["prev_vix"] = prev_vix
        r["vix_falling"] = bool(idx > 0 and cur_vix < prev_vix)
        r["sw_u1"] = bool(ath5 and (ad_below50 or score >= 4) and vxn22)
        r["sw_b1c"] = bool(ath5 and ad_below50 and vxn22)
        r["sw_d2"] = bool(ath5 and score >= 4)
        r["sw_g4"] = bool(r.get("gate_g4") or False)

    return rows, coeffs


def _opt_exec_price_sp(
    S: float,
    K: float,
    T: float,
    r: float,
    q: float,
    vxn_pct: float,
    coeffs: list[float],
    opt_type: str,
    side: str,
    slip: float,
) -> tuple[float, float]:
    sigma = eval_skew_iv(S, K, T, r, q, vxn_pct, coeffs)
    mid = bsm_price(S, K, T, r, q, sigma, opt_type)
    if side == "sell":
        exec_px = max(0.0, mid * (1.0 - slip) - OPT_COMM_PER_SH)
    elif side == "buy":
        exec_px = mid * (1.0 + slip) + OPT_COMM_PER_SH
    else:
        exec_px = mid
    return exec_px, mid


def _pick_expiry_strict_max14(
    dt_objs: list[datetime.date],
    dates: list[str],
    cur_idx: int,
    target_dte: int,
    hard_cap_dte: int = 14,
) -> tuple[str, datetime.date, int]:
    cur_dt = dt_objs[cur_idx]
    target_cal = cur_dt + datetime.timedelta(days=target_dte)
    pos = bisect.bisect_left(dt_objs, target_cal)
    if pos < len(dates):
        exp_dt = dt_objs[pos]
        while (exp_dt - cur_dt).days > hard_cap_dte and pos > cur_idx + 1:
            pos -= 1
            exp_dt = dt_objs[pos]
        exp_date = dates[pos]
    else:
        exp_dt = cur_dt + datetime.timedelta(days=min(target_dte, hard_cap_dte))
        exp_date = exp_dt.isoformat()
    act_dte = max(1, (exp_dt - cur_dt).days)
    return exp_date, exp_dt, act_dte


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
    cc_mode: str = DEFAULT_CC_MODE,
    sp_mode: str = DEFAULT_SP_MODE,
    wc_mode: str = DEFAULT_WC_MODE,
    slow_bear_overlay: bool = False,
    slip: float = DEFAULT_SLIPPAGE,
    real_store: Any = None,
) -> dict[str, Any]:
    use_real = real_store is not None
    rows = [r for r in rows_all if r["date"] >= START_DATE]
    dates = [r["date"] for r in rows]
    dt_objs = [_parse_iso(d) for d in dates]
    pre_drip_bh, post_drip_bh = compute_bh_drip_factors(rows)
    final_bh_sh = post_drip_bh[-1]
    final_cl = float(rows[-1]["close"])
    bh_end_nav = final_bh_sh * final_cl

    q_stats = {"total_lookups": 0, "real_opra_hits": 0, "real_polygon_hits": 0, "bsm_fallbacks": 0}

    def _rec_q(src: str) -> None:
        q_stats["total_lookups"] += 1
        if src.startswith("real_opra"):
            q_stats["real_opra_hits"] += 1
        elif src.startswith("real_polygon"):
            q_stats["real_polygon_hits"] += 1
        else:
            q_stats["bsm_fallbacks"] += 1

    def _is_exp(idx: int, exp_dt: datetime.date) -> bool:
        return roc.is_expiry_day(idx, dt_objs, exp_dt) if use_real else (dt_objs[idx] >= exp_dt)

    def _lookup_leg(
        d_str: str,
        opt_type: str,
        exp_str: str,
        k_val: float,
        k_cents: int | None,
        spot_px: float,
        rem_days: int,
        r_c: float,
        q_c: float,
        vxn_c: float,
        last_iv: float | None,
        slip_bsm: float = slip,
    ) -> tuple[float, float, float, float, float, str]:
        if use_real and k_cents is not None:
            b, a, m, iv, dl, src = real_store.lookup_contract(
                d_str, opt_type, exp_str, k_cents, spot_px, rem_days, r_c, q_c, vxn_c, last_iv,
                coeffs, eval_skew_iv, bsm_price, slip_bsm=slip_bsm,
            )
            _rec_q(src)
            return b, a, m, iv, dl, src
        t_r = max(0, rem_days) / 365.0
        sig = eval_skew_iv(spot_px, k_val, max(t_r, 1.0 / 365.0), r_c, q_c, vxn_c, coeffs)
        mid = bsm_price(spot_px, k_val, t_r, r_c, q_c, sig, opt_type)
        dl = bsm_call_delta(spot_px, k_val, t_r, r_c, q_c, sig) if opt_type == "call" else (bsm_call_delta(spot_px, k_val, t_r, r_c, q_c, sig) - math.exp(-q_c * t_r))
        _rec_q("bsm_fallback")
        return max(0.0, mid * (1.0 - slip_bsm)), mid * (1.0 + slip_bsm), mid, sig, dl, "bsm_fallback"

    def _buy_leg(b: float, a: float, m: float, src: str, slip_bsm: float = slip) -> float:
        return roc.exec_buy_price(b, a, m, src, slip_bsm=slip_bsm) if use_real else (m * (1.0 + slip_bsm))

    def _sell_leg(b: float, a: float, m: float, src: str, slip_bsm: float = slip) -> float:
        return roc.exec_sell_price(b, a, m, src, slip_bsm=slip_bsm) if use_real else max(0.0, m * (1.0 - slip_bsm))

    core_shares = INITIAL_CAPITAL / float(rows[0]["close"])
    tbill_cash = 0.0
    cc_cash = 0.0
    assigned_shares = 0.0
    assigned_cost_k = 0.0
    assigned_entry_date = ""
    sp_cash = 0.0
    in_slow_bear_def = False
    pending_bear_change: str | None = None

    # (min_vxn, target_delta, min_otm_floor, stop_delta, roll_mode)
    cc_cfg_map: dict[str, tuple[float, float, float, float | None, str | None]] = {
        "cc_d12_d35": (0.0, 0.12, 0.05, 0.35, None),
        "cc_d12_r45": (0.0, 0.12, 0.05, 0.45, "fresh_30d"),
        "cc_d12_cr55": (0.0, 0.12, 0.05, 0.55, "credit_45d"),
        # Legacy aliases
        "cc_high_vol": (0.0, 0.12, 0.05, 0.35, None),
        "cc_hv_8": (0.0, 0.12, 0.05, 0.35, None),
        "cc_d12_3x": (0.0, 0.12, 0.05, 0.35, None),
        "cc_always": (0.0, 0.12, 0.05, 0.45, "fresh_30d"),
        "cc_always_8": (0.0, 0.12, 0.05, 0.45, "fresh_30d"),
        "cc_otm8_3x": (0.0, 0.12, 0.05, 0.45, "fresh_30d"),
    }
    cc_enabled = cc_mode in cc_cfg_map and arch != "pure_qqq"
    cc_min_vxn, cc_target_delta, cc_min_otm, cc_stop_delta, cc_roll_mode = cc_cfg_map.get(
        cc_mode, (0.0, 0.12, 0.05, None, None)
    )
    cc_ath_limit = 0.03
    cc_dte = 25
    cc_max_rolls = 3

    # Engine 3: Short-DTE Panic Put Wheel (dte, otm_pct, max_lev, vix_thr, require_vix_falling)
    sp_cfg_map: dict[str, tuple[int, float, float, float, bool]] = {
        "sp_14d_cap10": (14, 0.05, 0.10, 1.00, False),
        "sp_10d_vixf": (10, 0.05, 0.20, 1.00, True),
        "sp_14d_unf": (14, 0.05, 0.20, 1.00, False),
    }
    sp_enabled = sp_mode in sp_cfg_map and arch != "pure_qqq"
    sp_dte, sp_otm_pct, sp_max_lev, sp_vix_thr, sp_require_vix_falling = sp_cfg_map.get(
        sp_mode, (14, 0.05, 0.0, 1.00, False)
    )

    active_tranches: list[dict[str, Any]] = []
    pending_sig: dict[str, Any] | None = None
    active_cc: dict[str, Any] | None = None
    pending_cc: dict[str, Any] | None = None
    pending_cc_deploy = False
    active_sp: dict[str, Any] | None = None
    pending_sp: dict[str, Any] | None = None
    active_wc: dict[str, Any] | None = None
    pending_wc: dict[str, Any] | None = None

    ledger: list[dict[str, Any]] = []
    cc_ledger: list[dict[str, Any]] = []
    sp_closed_ledger: list[dict[str, Any]] = []
    wc_closed_ledger: list[dict[str, Any]] = []
    shield_events: list[dict[str, Any]] = []
    tid = 0
    cc_tid = 0
    sp_tid = 0
    wc_tid = 0
    cc_gross_prem = 0.0
    cc_gross_loss = 0.0
    cc_assigned_cnt = 0
    cc_funded_puts = 0.0
    sp_margin_interest_total = 0.0
    sp_comm_total = 0.0
    sp_assign_count = 0
    days_levered = 0
    days_short_put_open = 0
    max_gross_stock_lev = 1.0
    max_notional_lev = 1.0
    max_wheel_cycle_days = 0
    cur_cycle_id = 0
    cur_cycle_start_dt: datetime.date | None = None

    def _sweep_sp_cash_to_core(px: float) -> None:
        nonlocal core_shares, sp_cash
        if abs(sp_cash) > 1e-8:
            if sp_cash > 0.0:
                core_shares += sp_cash / (px * (1.0 + STOCK_REBAL_FEE))
            else:
                core_shares += sp_cash / (px * (1.0 - STOCK_REBAL_FEE))
            sp_cash = 0.0

    def _estimate_nav_open(op_px: float, vxn_o: float, r_c: float, q_c: float, cur_dt: datetime.date, d_str: str = "") -> float:
        mtm_u1 = 0.0
        for tr_o in active_tranches:
            rem_d_o = max(1, (tr_o["exp_dt"] - cur_dt).days)
            _, _, pm_o, _, _, _ = _lookup_leg(
                d_str, "put", tr_o["exp_date"], tr_o["kp"], tr_o.get("k_cents_p"),
                op_px, rem_d_o, r_c, q_c, vxn_o, tr_o.get("last_iv_p"), slip_bsm=slip,
            )
            mtm_u1 += tr_o["hedged_shares"] * pm_o
            if tr_o["kc"] is not None:
                _, _, cm_o, _, _, _ = _lookup_leg(
                    d_str, "call", tr_o["exp_date"], tr_o["kc"], tr_o.get("k_cents_c"),
                    op_px, rem_d_o, r_c, q_c, vxn_o, tr_o.get("last_iv_c"), slip_bsm=slip,
                )
                mtm_u1 -= tr_o["hedged_shares"] * cm_o
        mtm_cc_o = 0.0
        if active_cc is not None:
            rem_c_o = max(1, (active_cc["exp_dt"] - cur_dt).days)
            _, _, cm_c_o, _, _, _ = _lookup_leg(
                d_str, "call", active_cc["exp_date"], active_cc["kc"], active_cc.get("k_cents"),
                op_px, rem_c_o, r_c, q_c, vxn_o, active_cc.get("last_iv"), slip_bsm=slip,
            )
            mtm_cc_o = -active_cc["shares"] * cm_c_o
        return max(1.0, (core_shares + assigned_shares) * op_px + tbill_cash + cc_cash + sp_cash + mtm_u1 + mtm_cc_o)

    nav_list: list[float] = []
    equiv_sh_list: list[float] = []
    any_active_list: list[int] = []
    active_slots_list: list[int] = []
    slot1_naked_list: list[bool] = []
    shield_active_list: list[bool] = []

    for i, d in enumerate(dates):
        row = rows[i]
        op_raw = float(row["open"])
        cl = float(row["close"])
        div = float(row["dividends"])
        vxn_cl = float(row["vxn"])
        vix_r = float(row["vix_ratio"])
        r_cur = float(row["r"])
        q_cur = float(row["div_yield"])
        dd_cur = float(row["dd_from_ath"])
        # Align execution spot/VXN to 4:00 PM ET real OPRA/Polygon quote timestamp when using real quotes
        op = cl if use_real else op_raw
        if use_real:
            vxn_ex_day = vxn_cl
        elif i > 0:
            vxn_ex_day = max(10.0, float(rows[i - 1]["vxn"]) - 0.45 * (op / float(rows[i - 1]["close"]) - 1.0) * 100.0)
        else:
            vxn_ex_day = vxn_cl

        mult_morning = (final_bh_sh / pre_drip_bh[i]) * final_cl
        mult_eod = (final_bh_sh / post_drip_bh[i]) * final_cl

        if i > 0:
            dt_yr = max(1, (dt_objs[i] - dt_objs[i - 1]).days) / 365.0
            r_prev = float(rows[i - 1]["r"])
            if tbill_cash > 0.0:
                tbill_cash *= 1.0 + r_prev * dt_yr
            if cc_cash > 0.0:
                cc_cash *= 1.0 + r_prev * dt_yr
            if sp_cash > 0.0:
                sp_cash *= 1.0 + r_prev * dt_yr
            elif sp_cash < 0.0:
                m_int = abs(sp_cash) * (r_prev + MARGIN_SPREAD) * dt_yr
                sp_cash -= m_int
                sp_margin_interest_total += m_int

        # A0. Deploy accumulated Covered-Call cash war chest on panic dip at T+1 Open
        if i > 0 and pending_cc_deploy and cc_cash > 1.0:
            core_shares += cc_cash / (op * (1.0 + STOCK_REBAL_FEE))
            cc_cash = 0.0
            pending_cc_deploy = False

        # A0b. Close or Roll active Covered Call early on VIX/3M >= 1.10 panic or Delta stop/roll trigger
        if i > 0 and active_cc is not None and active_cc.get("pending_close"):
            vxn_op = vxn_ex_day
            rem_cc = max(0, (active_cc["exp_dt"] - dt_objs[i]).days)
            if _is_exp(i, active_cc["exp_dt"]):
                c_ask_ex = max(0.0, op - active_cc["kc"])
                src_cc_ex = active_cc.get("entry_source", "bsm_fallback")
            else:
                b_c, a_c, m_c, _, _, src_cc_ex = _lookup_leg(
                    d, "call", active_cc["exp_date"], active_cc["kc"], active_cc.get("k_cents"),
                    op, rem_cc, r_cur, q_cur, vxn_op, active_cc.get("last_iv"), slip_bsm=slip,
                )
                c_ask_ex = _buy_leg(b_c, a_c, m_c, src_cc_ex, slip_bsm=slip)
            cost_cl = active_cc["shares"] * c_ask_ex
            cc_gross_loss += cost_cl
            if cc_cash >= cost_cl:
                cc_cash -= cost_cl
            else:
                core_shares -= (cost_cl - cc_cash) / (op * (1.0 - STOCK_REBAL_FEE))
                cc_cash = 0.0
            close_reason = active_cc.get("close_reason") or "panic_close_uncap"
            old_rolls = int(active_cc.get("roll_count", 0))
            old_sh = active_cc["shares"]
            cc_en_src = active_cc.get("entry_source", "bsm_fallback")
            cc_ledger.append(
                {
                    "cc_id": active_cc["cc_id"],
                    "entry_date": active_cc["entry_date"],
                    "exit_date": d,
                    "entry_spot": round(active_cc["entry_spot"], 2),
                    "kc": round(active_cc["kc"], 2),
                    "exit_spot": round(op, 2),
                    "entry_vxn": round(active_cc["entry_vxn"], 2),
                    "shares": round(old_sh, 2),
                    "prem_usd": round(active_cc["prem_usd"], 2),
                    "loss_usd": round(cost_cl, 2),
                    "net_pnl_usd": round(active_cc["prem_usd"] - cost_cl, 2),
                    "exit_reason": close_reason,
                    "roll_gen": old_rolls,
                    "pricing_source": m7e._classify_trade_source(cc_en_src, src_cc_ex),
                }
            )
            active_cc = None

            # Simultaneous Roll-Out-and-Up if triggered by Delta Roll (not panic) and no active crisis Collar
            has_collar_r = any(t["tranche_type"] == "collar" for t in active_tranches)
            if (
                close_reason in ("delta_roll_up", "delta_credit_roll")
                and cc_roll_mode is not None
                and old_rolls < cc_max_rolls
                and not has_collar_r
            ):
                roll_days = 45 if cc_roll_mode == "credit_45d" else 30
                c_roll = None
                if use_real:
                    if cc_roll_mode == "credit_45d":
                        c_roll = real_store.select_call_contract_for_bid(
                            d, op, 45, c_ask_ex, op * 1.01, 32, 62, r_cur, q_cur
                        )
                    elif cc_roll_mode == "fresh_30d":
                        c_roll = real_store.select_call_contract_delta(
                            d, op, 30, cc_target_delta, op * (1.0 + cc_min_otm), 20, 42, r_cur, q_cur
                        )
                if c_roll is not None:
                    _rec_q(c_roll["source"])
                    exp_date_r, exp_dt_r = c_roll["exp"], c_roll["exp_dt"]
                    kc_new = c_roll["strike"]
                    k_cents_r = c_roll["k_cents"]
                    c_bid_r = _sell_leg(c_roll["bid"], c_roll["ask"], c_roll["mid"], c_roll["source"], slip_bsm=slip)
                    iv_r = c_roll["iv"]
                    src_r = c_roll["source"]
                else:
                    target_r = dt_objs[i] + datetime.timedelta(days=roll_days)
                    pos_r = bisect.bisect_left(dt_objs, target_r)
                    if pos_r < len(dates):
                        exp_date_r, exp_dt_r = dates[pos_r], dt_objs[pos_r]
                    else:
                        exp_date_r, exp_dt_r = target_r.isoformat(), target_r
                    t_r = max(1, (exp_dt_r - dt_objs[i]).days) / 365.0
                    kc_new = None
                    if cc_roll_mode == "credit_45d":
                        kc_new = solve_call_strike_for_bid(op, t_r, r_cur, q_cur, vxn_op, coeffs, c_ask_ex, slip)
                    elif cc_roll_mode == "fresh_30d":
                        kc_new = max(
                            op * (1.0 + cc_min_otm),
                            solve_call_strike_for_delta(op, t_r, r_cur, q_cur, vxn_op, coeffs, cc_target_delta),
                        )
                    if kc_new is not None and kc_new > op * 1.01:
                        iv_r = eval_skew_iv(op, kc_new, t_r, r_cur, q_cur, vxn_op, coeffs)
                        cm_r = bsm_price(op, kc_new, t_r, r_cur, q_cur, iv_r, "call")
                        c_bid_r = _sell_leg(cm_r * (1.0 - slip), cm_r * (1.0 + slip), cm_r, "bsm_fallback", slip_bsm=slip)
                        k_cents_r = int(round(kc_new * 100.0))
                        src_r = "bsm_fallback"
                        _rec_q(src_r)
                    else:
                        c_bid_r = 0.0
                        k_cents_r = None
                        iv_r = None
                        src_r = "bsm_fallback"
                if kc_new is not None and kc_new > op * 1.01 and c_bid_r >= 0.05:
                    prem_r = old_sh * c_bid_r
                    cc_tid += 1
                    cc_gross_prem += prem_r
                    cc_cash += prem_r
                    active_cc = {
                        "cc_id": cc_tid,
                        "entry_date": d,
                        "entry_dt": dt_objs[i],
                        "exp_date": exp_date_r,
                        "exp_dt": exp_dt_r,
                        "entry_spot": op,
                        "entry_vxn": vxn_op,
                        "kc": kc_new,
                        "k_cents": k_cents_r,
                        "last_iv": iv_r,
                        "entry_source": src_r,
                        "shares": old_sh,
                        "prem_usd": prem_r,
                        "pending_close": False,
                        "roll_count": old_rolls + 1,
                    }

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

        # A. Execute pending early Take-Profit exits at T+1 (4:00 PM ET real OPRA/Polygon quote or BSM Open)
        if i > 0 and any(t.get("pending_tp") for t in active_tranches):
            vxn_op = vxn_ex_day

            still_open: list[dict[str, Any]] = []
            for tr in active_tranches:
                if not tr.get("pending_tp"):
                    still_open.append(tr)
                    continue
                rem_days = max(0, (tr["exp_dt"] - dt_objs[i]).days)
                t_rem = rem_days / 365.0
                if _is_exp(i, tr["exp_dt"]):
                    put_bid = max(0.0, tr["kp"] - op)
                    call_ask = max(0.0, op - tr["kc"]) if tr["kc"] is not None else 0.0
                    src_p_ex = tr.get("entry_source", "bsm_fallback")
                    src_c_ex = tr.get("entry_source_c", src_p_ex)
                else:
                    b_p, a_p, m_p, _, _, src_p_ex = _lookup_leg(
                        d, "put", tr["exp_date"], tr["kp"], tr.get("k_cents_p"),
                        op, rem_days, r_cur, q_cur, vxn_op, tr.get("last_iv_p"), slip_bsm=slip,
                    )
                    put_bid = _sell_leg(b_p, a_p, m_p, src_p_ex, slip_bsm=slip)
                    if tr["tranche_type"] == "collar":
                        b_c, a_c, m_c, _, _, src_c_ex = _lookup_leg(
                            d, "call", tr["exp_date"], tr["kc"], tr.get("k_cents_c"),
                            op, rem_days, r_cur, q_cur, vxn_op, tr.get("last_iv_c"), slip_bsm=slip,
                        )
                        call_ask = _buy_leg(b_c, a_c, m_c, src_c_ex, slip_bsm=slip)
                    else:
                        call_ask = 0.0
                        src_c_ex = src_p_ex

                if tr["tranche_type"] == "collar":
                    actual_net_sh = put_bid - call_ask
                else:
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
                en_src = tr.get("entry_source", "bsm_fallback")
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
                        "pricing_source": m7e._classify_trade_source(en_src, src_p_ex),
                        "entry_source": en_src,
                        "exit_source": src_p_ex,
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

        # B. Execute pending new Tranche entry at T+1
        if i > 0 and pending_sig is not None and arch != "pure_qqq" and len(active_tranches) < max_slots:
            vxn_en = vxn_ex_day
            r_en, q_en = (r_cur, q_cur) if use_real else (pending_sig["r"], pending_sig["q"])

            if arch == "all_collar":
                t_type = "collar"
            elif arch == "all_naked":
                t_type = "naked_put"
            elif arch == "hybrid_campaign_first":
                t_type = "naked_put" if len(active_tranches) == 0 else "collar"
            else:
                raise ValueError(f"Unknown arch: {arch}")

            c_put = (
                real_store.select_put_contract(d, op, target_dte, put_moneyness, 65, 120, r_en, q_en)
                if use_real
                else None
            )
            if c_put is not None:
                _rec_q(c_put["source"])
                exp_date, exp_dt = c_put["exp"], c_put["exp_dt"]
                act_dte = c_put["dte"]
                t_en = act_dte / 365.0
                kp = c_put["strike"]
                k_cents_p = c_put["k_cents"]
                put_ask_en = _buy_leg(c_put["bid"], c_put["ask"], c_put["mid"], c_put["source"], slip_bsm=slip)
                iv_p_en = c_put["iv"]
                src_en = c_put["source"]
            else:
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
                kp = op * put_moneyness
                k_cents_p = int(round(kp * 100.0))
                iv_p_en = eval_skew_iv(op, kp, t_en, r_en, q_en, vxn_en, coeffs)
                pm_en = bsm_price(op, kp, t_en, r_en, q_en, iv_p_en, "put")
                put_ask_en = _buy_leg(pm_en * (1.0 - slip), pm_en * (1.0 + slip), pm_en, "bsm_fallback", slip_bsm=slip)
                src_en = "bsm_fallback"
                _rec_q(src_en)

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
                k_cents_c = None
                iv_c_en = None
                src_c_en = src_en
                if t_type == "collar":
                    # Buy back any overlapping normal-time Covered Call before opening a Collar
                    if active_cc is not None:
                        rem_cc = max(0, (active_cc["exp_dt"] - dt_objs[i]).days)
                        if _is_exp(i, active_cc["exp_dt"]):
                            c_ask_ex = max(0.0, op - active_cc["kc"])
                            src_cc_cl = active_cc.get("entry_source", "bsm_fallback")
                        else:
                            b_c, a_c, m_c, _, _, src_cc_cl = _lookup_leg(
                                d, "call", active_cc["exp_date"], active_cc["kc"], active_cc.get("k_cents"),
                                op, rem_cc, r_en, q_en, vxn_en, active_cc.get("last_iv"), slip_bsm=slip,
                            )
                            c_ask_ex = _buy_leg(b_c, a_c, m_c, src_cc_cl, slip_bsm=slip)
                        cost_cl = active_cc["shares"] * c_ask_ex
                        cc_gross_loss += cost_cl
                        if cc_cash >= cost_cl:
                            cc_cash -= cost_cl
                        else:
                            core_shares -= (cost_cl - cc_cash) / (op * (1.0 - STOCK_REBAL_FEE))
                            cc_cash = 0.0
                        cc_ledger.append(
                            {
                                "cc_id": active_cc["cc_id"],
                                "entry_date": active_cc["entry_date"],
                                "exit_date": d,
                                "entry_spot": round(active_cc["entry_spot"], 2),
                                "kc": round(active_cc["kc"], 2),
                                "exit_spot": round(op, 2),
                                "entry_vxn": round(active_cc["entry_vxn"], 2),
                                "shares": round(active_cc["shares"], 2),
                                "prem_usd": round(active_cc["prem_usd"], 2),
                                "loss_usd": round(cost_cl, 2),
                                "net_pnl_usd": round(active_cc["prem_usd"] - cost_cl, 2),
                                "exit_reason": "closed_for_collar",
                                "roll_gen": int(active_cc.get("roll_count", 0)),
                                "pricing_source": m7e._classify_trade_source(
                                    active_cc.get("entry_source", "bsm_fallback"), src_cc_cl
                                ),
                            }
                        )
                        active_cc = None
                    c_col = (
                        real_store.select_call_contract_for_bid(
                            d, op, act_dte, put_ask_en, op * 1.005, 65, 120, r_en, q_en, exp_override=exp_date
                        )
                        if (use_real and c_put is not None)
                        else None
                    )
                    if c_col is not None:
                        _rec_q(c_col["source"])
                        kc = c_col["strike"]
                        k_cents_c = c_col["k_cents"]
                        iv_c_en = c_col["iv"]
                        src_c_en = c_col["source"]
                    else:
                        kc = solve_zero_cost_call_strike(op, kp, t_en, r_en, q_en, vxn_en, coeffs, slip)
                        k_cents_c = int(round(kc * 100.0))
                        iv_c_en = eval_skew_iv(op, kc, t_en, r_en, q_en, vxn_en, coeffs)
                        src_c_en = "bsm_fallback"
                        _rec_q("bsm_fallback")
                    entry_cost_usd = 0.0
                    d_sh_entry = 0.0
                else:
                    kc = None
                    entry_cost_usd = hedged_sh * put_ask_en
                    # Fund Naked Put from Covered-Call cash war chest first (zero QQQ share sale while cash lasts!)
                    if cc_cash >= entry_cost_usd:
                        cc_cash -= entry_cost_usd
                        cc_funded_puts += entry_cost_usd
                        d_sh_entry = 0.0
                    else:
                        paid_cc = cc_cash
                        cc_funded_puts += paid_cc
                        rem_cost = entry_cost_usd - paid_cc
                        cc_cash = 0.0
                        d_sh_entry = -rem_cost / (op * (1.0 - STOCK_REBAL_FEE))
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
                        "k_cents_p": k_cents_p,
                        "k_cents_c": k_cents_c,
                        "last_iv_p": iv_p_en,
                        "last_iv_c": iv_c_en,
                        "entry_source": src_en,
                        "entry_source_c": src_c_en,
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

        # B2. Execute pending normal-time OTM Covered Call sale at T+1 (only on uncollared shares)
        if i > 0 and cc_enabled and pending_cc is not None and active_cc is None:
            has_collar = any(t["tranche_type"] == "collar" for t in active_tranches)
            if not has_collar:
                vxn_cc = vxn_ex_day
                r_cc, q_cc = (r_cur, q_cur) if use_real else (pending_cc["r"], pending_cc["q"])
                cc_sh = max(0.0, core_shares)
                if cc_sh > 1e-6:
                    c_cc = (
                        real_store.select_call_contract_delta(
                            d, op, cc_dte, cc_target_delta, op * (1.0 + cc_min_otm), 18, 35, r_cc, q_cc
                        )
                        if use_real
                        else None
                    )
                    if c_cc is not None:
                        _rec_q(c_cc["source"])
                        exp_date_cc, exp_dt_cc = c_cc["exp"], c_cc["exp_dt"]
                        kc_cc = c_cc["strike"]
                        k_cents_cc = c_cc["k_cents"]
                        c_bid_cc = _sell_leg(c_cc["bid"], c_cc["ask"], c_cc["mid"], c_cc["source"], slip_bsm=slip)
                        iv_cc = c_cc["iv"]
                        src_cc = c_cc["source"]
                    else:
                        target_cc = dt_objs[i] + datetime.timedelta(days=cc_dte)
                        pos_cc = bisect.bisect_left(dt_objs, target_cc)
                        if pos_cc < len(dates):
                            exp_date_cc, exp_dt_cc = dates[pos_cc], dt_objs[pos_cc]
                        else:
                            exp_date_cc, exp_dt_cc = target_cc.isoformat(), target_cc
                        t_cc = max(1, (exp_dt_cc - dt_objs[i]).days) / 365.0
                        kc_cc = max(
                            op * (1.0 + cc_min_otm),
                            solve_call_strike_for_delta(op, t_cc, r_cc, q_cc, vxn_cc, coeffs, cc_target_delta),
                        )
                        iv_cc = eval_skew_iv(op, kc_cc, t_cc, r_cc, q_cc, vxn_cc, coeffs)
                        cm_cc = bsm_price(op, kc_cc, t_cc, r_cc, q_cc, iv_cc, "call")
                        c_bid_cc = _sell_leg(cm_cc * (1.0 - slip), cm_cc * (1.0 + slip), cm_cc, "bsm_fallback", slip_bsm=slip)
                        k_cents_cc = int(round(kc_cc * 100.0))
                        src_cc = "bsm_fallback"
                        _rec_q(src_cc)
                    if c_bid_cc >= 0.05:
                        prem_usd = cc_sh * c_bid_cc
                        cc_tid += 1
                        cc_gross_prem += prem_usd
                        cc_cash += prem_usd
                        active_cc = {
                            "cc_id": cc_tid,
                            "entry_date": d,
                            "entry_dt": dt_objs[i],
                            "exp_date": exp_date_cc,
                            "exp_dt": exp_dt_cc,
                            "entry_spot": op,
                            "entry_vxn": vxn_cc,
                            "kc": kc_cc,
                            "k_cents": k_cents_cc,
                            "last_iv": iv_cc,
                            "entry_source": src_cc,
                            "shares": cc_sh,
                            "prem_usd": prem_usd,
                            "pending_close": False,
                            "roll_count": 0,
                        }
            pending_cc = None

        # B3. Engine 3 Reverse Wheel Covered Call & Panic Short-Put Executions (T+1)
        if i > 0 and sp_enabled and pending_wc is not None and assigned_shares > 1e-6 and active_wc is None:
            pw = pending_wc
            pending_wc = None
            vxn_wc = vxn_ex_day
            r_wc, q_wc = (r_cur, q_cur) if use_real else (pw["r"], pw["q"])
            c_wc = None
            if use_real:
                if wc_mode == "wc_reclaim_30d_d35":
                    c_wc = real_store.select_call_contract_delta(
                        d, op, 30, 0.35, assigned_cost_k, 21, 40, r_wc, q_wc
                    )
                elif wc_mode == "wc_30d_c5s5":
                    c_wc = real_store.select_call_contract_strike(
                        d, op, 30, max(assigned_cost_k * 1.05, op * 1.05), 21, 40, r_wc, q_wc
                    )
                elif wc_mode == "wc_14d_c0s2":
                    c_wc = real_store.select_call_contract_strike(
                        d, op, sp_dte, max(assigned_cost_k, op * 1.02), 5, 17, r_wc, q_wc
                    )
            if c_wc is not None:
                _rec_q(c_wc["source"])
                exp_date_wc, exp_dt_wc = c_wc["exp"], c_wc["exp_dt"]
                act_dte_wc = c_wc["dte"]
                kc_wc = c_wc["strike"]
                k_cents_wc = c_wc["k_cents"]
                c_bid_wc = _sell_leg(c_wc["bid"], c_wc["ask"], c_wc["mid"], c_wc["source"], slip_bsm=0.03)
                iv_wc = c_wc["iv"]
                src_wc = c_wc["source"]
            else:
                if wc_mode == "wc_reclaim_30d_d35":
                    target_wc_dt = dt_objs[i] + datetime.timedelta(days=30)
                    pos_wc = bisect.bisect_left(dt_objs, target_wc_dt)
                    if pos_wc < len(dates):
                        exp_date_wc, exp_dt_wc = dates[pos_wc], dt_objs[pos_wc]
                    else:
                        exp_date_wc, exp_dt_wc = target_wc_dt.isoformat(), target_wc_dt
                    act_dte_wc = max(1, (exp_dt_wc - dt_objs[i]).days)
                    t_wc_solve = act_dte_wc / 365.0
                    k_d35 = solve_call_strike_for_delta(op, t_wc_solve, r_wc, q_wc, vxn_wc, coeffs, 0.35)
                    kc_wc = max(assigned_cost_k, k_d35)
                elif wc_mode == "wc_30d_c5s5":
                    target_wc_dt = dt_objs[i] + datetime.timedelta(days=30)
                    pos_wc = bisect.bisect_left(dt_objs, target_wc_dt)
                    if pos_wc < len(dates):
                        exp_date_wc, exp_dt_wc = dates[pos_wc], dt_objs[pos_wc]
                    else:
                        exp_date_wc, exp_dt_wc = target_wc_dt.isoformat(), target_wc_dt
                    act_dte_wc = max(1, (exp_dt_wc - dt_objs[i]).days)
                    kc_wc = max(assigned_cost_k * 1.05, op * 1.05)
                elif wc_mode == "wc_14d_c0s2":
                    exp_date_wc, exp_dt_wc, act_dte_wc = _pick_expiry_strict_max14(dt_objs, dates, i, sp_dte, 14)
                    kc_wc = max(assigned_cost_k, op * 1.02)
                else:
                    raise ValueError(f"Unknown wc_mode: {wc_mode}")
                t_wc = act_dte_wc / 365.0
                c_bid_wc, _ = _opt_exec_price_sp(op, kc_wc, t_wc, r_wc, q_wc, vxn_wc, coeffs, "call", "sell", slip)
                k_cents_wc = int(round(kc_wc * 100.0))
                iv_wc = eval_skew_iv(op, kc_wc, t_wc, r_wc, q_wc, vxn_wc, coeffs)
                src_wc = "bsm_fallback"
                _rec_q(src_wc)
            if c_bid_wc >= MIN_OPT_BID:
                prem_wc = assigned_shares * c_bid_wc
                sp_comm_total += assigned_shares * OPT_COMM_PER_SH
                sp_cash += prem_wc
                wc_tid += 1
                active_wc = {
                    "wc_id": wc_tid,
                    "cycle_id": cur_cycle_id,
                    "signal_date": pw["signal_date"],
                    "entry_date": d,
                    "entry_dt": dt_objs[i],
                    "exp_date": exp_date_wc,
                    "exp_dt": exp_dt_wc,
                    "dte": act_dte_wc,
                    "entry_spot": op,
                    "kc": kc_wc,
                    "k_cents": k_cents_wc,
                    "last_iv": iv_wc,
                    "entry_source": src_wc,
                    "assigned_cost_k": assigned_cost_k,
                    "shares": assigned_shares,
                    "prem_usd": prem_wc,
                }

        if i > 0 and sp_enabled and pending_sp is not None and active_sp is None and assigned_shares <= 1e-6:
            ps = pending_sp
            pending_sp = None
            vxn_sp = vxn_ex_day
            r_sp, q_sp = (r_cur, q_cur) if use_real else (ps["r"], ps["q"])
            c_sp = (
                real_store.select_put_contract(d, op, sp_dte, 1.0 - sp_otm_pct, 5, 17, r_sp, q_sp)
                if use_real
                else None
            )
            if c_sp is not None:
                _rec_q(c_sp["source"])
                exp_date_sp, exp_dt_sp = c_sp["exp"], c_sp["exp_dt"]
                act_dte_sp = c_sp["dte"]
                kp_sp = c_sp["strike"]
                k_cents_sp = c_sp["k_cents"]
                p_bid_sp = _sell_leg(c_sp["bid"], c_sp["ask"], c_sp["mid"], c_sp["source"], slip_bsm=0.03)
                iv_sp = c_sp["iv"]
                src_sp = c_sp["source"]
            else:
                exp_date_sp, exp_dt_sp, act_dte_sp = _pick_expiry_strict_max14(dt_objs, dates, i, sp_dte, 14)
                t_sp = act_dte_sp / 365.0
                kp_sp = op * (1.0 - sp_otm_pct)
                p_bid_sp, _ = _opt_exec_price_sp(op, kp_sp, t_sp, r_sp, q_sp, vxn_sp, coeffs, "put", "sell", slip)
                k_cents_sp = int(round(kp_sp * 100.0))
                iv_sp = eval_skew_iv(op, kp_sp, t_sp, r_sp, q_sp, vxn_sp, coeffs)
                src_sp = "bsm_fallback"
                _rec_q(src_sp)
            if p_bid_sp >= MIN_OPT_BID:
                nav_open = _estimate_nav_open(op, vxn_sp, r_sp, q_sp, dt_objs[i], d_str=d)
                put_sh = (sp_max_lev * nav_open) / kp_sp
                prem_sp = put_sh * p_bid_sp
                sp_comm_total += put_sh * OPT_COMM_PER_SH
                sp_cash += prem_sp
                sp_tid += 1
                cur_cycle_id = sp_tid
                cur_cycle_start_dt = dt_objs[i]
                active_sp = {
                    "sp_id": sp_tid,
                    "cycle_id": cur_cycle_id,
                    "signal_date": ps["signal_date"],
                    "entry_date": d,
                    "entry_dt": dt_objs[i],
                    "exp_date": exp_date_sp,
                    "exp_dt": exp_dt_sp,
                    "dte": act_dte_sp,
                    "entry_spot": op,
                    "kp": kp_sp,
                    "k_cents": k_cents_sp,
                    "last_iv": iv_sp,
                    "entry_source": src_sp,
                    "shares": put_sh,
                    "prem_usd": prem_sp,
                    "entry_vix_ratio": ps["vix_ratio"],
                }

        # C. Dividends DRIP at EOD Close
        if i > 0 and div > 0.0:
            core_shares += (core_shares * div) / cl
            if assigned_shares > 0.0:
                sp_cash += assigned_shares * div

        # D. Expiry Settlement or EOD MTM + Take-Profit Check
        put_mtm_tot = 0.0
        call_mtm_tot = 0.0
        was_active_today = len(active_tranches) > 0
        active_slots_today = len(active_tranches)
        slot1_naked_today = any(t["tranche_type"] == "naked_put" for t in active_tranches)

        rem_after_exp: list[dict[str, Any]] = []
        for tr in active_tranches:
            if _is_exp(i, tr["exp_dt"]):
                is_true_exp = (i < len(dates) - 1) or ((tr["exp_dt"] - dt_objs[i]).days <= 0)
                if is_true_exp:
                    put_ex = max(0.0, tr["kp"] - cl)
                    call_ex = max(0.0, cl - tr["kc"]) if tr["kc"] is not None else 0.0
                    reason = f"expiry_{target_dte}dte"
                    rem_d = 0
                    t_rem_ex = 0.0
                    src_ex = tr.get("entry_source", "bsm_fallback")
                else:
                    rem_d = max(1, (tr["exp_dt"] - dt_objs[i]).days)
                    t_rem_ex = rem_d / 365.0
                    _, _, put_ex, _, _, src_ex = _lookup_leg(
                        d, "put", tr["exp_date"], tr["kp"], tr.get("k_cents_p"),
                        cl, rem_d, r_cur, q_cur, vxn_cl, tr.get("last_iv_p"), slip_bsm=slip,
                    )
                    if tr["kc"] is not None:
                        _, _, call_ex, _, _, _ = _lookup_leg(
                            d, "call", tr["exp_date"], tr["kc"], tr.get("k_cents_c"),
                            cl, rem_d, r_cur, q_cur, vxn_cl, tr.get("last_iv_c"), slip_bsm=slip,
                        )
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
                en_src = tr.get("entry_source", "bsm_fallback")
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
                        "pricing_source": m7e._classify_trade_source(en_src, src_ex),
                        "entry_source": en_src,
                        "exit_source": src_ex,
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
                b_p, a_p, pm, iv_p_now, _, src_p_now = _lookup_leg(
                    d, "put", tr["exp_date"], tr["kp"], tr.get("k_cents_p"),
                    cl, rem_days, r_cur, q_cur, vxn_cl, tr.get("last_iv_p"), slip_bsm=slip,
                )
                tr["last_iv_p"] = iv_p_now
                if tr["kc"] is not None:
                    b_c, a_c, cm, iv_c_now, _, src_c_now = _lookup_leg(
                        d, "call", tr["exp_date"], tr["kc"], tr.get("k_cents_c"),
                        cl, rem_days, r_cur, q_cur, vxn_cl, tr.get("last_iv_c"), slip_bsm=slip,
                    )
                    tr["last_iv_c"] = iv_c_now
                else:
                    b_c = a_c = cm = 0.0
                    src_c_now = "bsm_fallback"

                put_mtm_tot += tr["hedged_shares"] * pm
                call_mtm_tot -= tr["hedged_shares"] * cm

                if rem_days >= 3:
                    est_put_bid = _sell_leg(b_p, a_p, pm, src_p_now, slip_bsm=slip)
                    est_call_ask = _buy_leg(b_c, a_c, cm, src_c_now, slip_bsm=slip) if tr["kc"] is not None else 0.0
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

        # D2. Normal-time Covered Call expiry settlement or EOD MTM
        cc_mtm = 0.0
        if active_cc is not None:
            if _is_exp(i, active_cc["exp_dt"]):
                pay_cc = max(0.0, cl - active_cc["kc"])
                loss_cc = active_cc["shares"] * pay_cc
                if pay_cc > 0.0:
                    cc_assigned_cnt += 1
                    cc_gross_loss += loss_cc
                    if cc_cash >= loss_cc:
                        cc_cash -= loss_cc
                    else:
                        core_shares -= (loss_cc - cc_cash) / (cl * (1.0 - STOCK_REBAL_FEE))
                        cc_cash = 0.0
                en_cc_src = active_cc.get("entry_source", "bsm_fallback")
                cc_ledger.append(
                    {
                        "cc_id": active_cc["cc_id"],
                        "entry_date": active_cc["entry_date"],
                        "exit_date": d,
                        "entry_spot": round(active_cc["entry_spot"], 2),
                        "kc": round(active_cc["kc"], 2),
                        "exit_spot": round(cl, 2),
                        "entry_vxn": round(active_cc["entry_vxn"], 2),
                        "shares": round(active_cc["shares"], 2),
                        "prem_usd": round(active_cc["prem_usd"], 2),
                        "loss_usd": round(loss_cc, 2),
                        "net_pnl_usd": round(active_cc["prem_usd"] - loss_cc, 2),
                        "exit_reason": "assigned_breach" if pay_cc > 0.0 else "expired_worthless",
                        "roll_gen": int(active_cc.get("roll_count", 0)),
                        "pricing_source": m7e._classify_trade_source(en_cc_src, en_cc_src),
                    }
                )
                active_cc = None
            else:
                rem_cc = max(1, (active_cc["exp_dt"] - dt_objs[i]).days)
                _, _, cm_cc, iv_cc_now, cur_delta, _ = _lookup_leg(
                    d, "call", active_cc["exp_date"], active_cc["kc"], active_cc.get("k_cents"),
                    cl, rem_cc, r_cur, q_cur, vxn_cl, active_cc.get("last_iv"), slip_bsm=slip,
                )
                active_cc["last_iv"] = iv_cc_now
                cc_mtm = -active_cc["shares"] * cm_cc
                if rem_cc >= 3 and vix_r >= 1.10:
                    active_cc["pending_close"] = True
                    active_cc["close_reason"] = "panic_close_uncap"
                elif cc_stop_delta is not None and cur_delta >= cc_stop_delta:
                    active_cc["pending_close"] = True
                    if cc_roll_mode == "fresh_30d":
                        active_cc["close_reason"] = "delta_roll_up"
                    elif cc_roll_mode == "credit_45d":
                        active_cc["close_reason"] = "delta_credit_roll"
                    else:
                        active_cc["close_reason"] = "delta_stop"

        # D3. Engine 3 Short-DTE Panic Put EOD settlement or MTM
        sp_mtm = 0.0
        if active_sp is not None:
            days_short_put_open += 1
            if _is_exp(i, active_sp["exp_dt"]):
                en_sp_src = active_sp.get("entry_source", "bsm_fallback")
                if cl >= active_sp["kp"]:
                    sp_closed_ledger.append(
                        {
                            "leg_id": f"SP-{active_sp['sp_id']}",
                            "sp_id": active_sp["sp_id"],
                            "cycle_id": active_sp["cycle_id"],
                            "leg_type": "short_put",
                            "is_open_live": False,
                            "signal_date": active_sp["signal_date"],
                            "entry_date": active_sp["entry_date"],
                            "exit_date": d,
                            "dte": active_sp["dte"],
                            "entry_spot": round(active_sp["entry_spot"], 2),
                            "strike": round(active_sp["kp"], 2),
                            "kp": round(active_sp["kp"], 2),
                            "exit_spot": round(cl, 2),
                            "shares": round(active_sp["shares"], 2),
                            "prem_usd": round(active_sp["prem_usd"], 2),
                            "exit_cost_usd": 0.0,
                            "net_pnl_usd": round(active_sp["prem_usd"], 2),
                            "exit_reason": "expired_otm",
                            "pricing_source": m7e._classify_trade_source(en_sp_src, en_sp_src),
                        }
                    )
                    active_sp = None
                    if assigned_shares <= 1e-6:
                        cur_cycle_start_dt = None
                        _sweep_sp_cash_to_core(cl)
                else:
                    assigned_shares = active_sp["shares"]
                    assigned_cost_k = active_sp["kp"]
                    assigned_entry_date = d
                    sp_cash -= assigned_shares * active_sp["kp"]
                    sp_assign_count += 1
                    intr_cost = active_sp["shares"] * (active_sp["kp"] - cl)
                    sp_closed_ledger.append(
                        {
                            "leg_id": f"SP-{active_sp['sp_id']}",
                            "sp_id": active_sp["sp_id"],
                            "cycle_id": active_sp["cycle_id"],
                            "leg_type": "short_put",
                            "is_open_live": False,
                            "signal_date": active_sp["signal_date"],
                            "entry_date": active_sp["entry_date"],
                            "exit_date": d,
                            "dte": active_sp["dte"],
                            "entry_spot": round(active_sp["entry_spot"], 2),
                            "strike": round(active_sp["kp"], 2),
                            "kp": round(active_sp["kp"], 2),
                            "exit_spot": round(cl, 2),
                            "shares": round(active_sp["shares"], 2),
                            "prem_usd": round(active_sp["prem_usd"], 2),
                            "exit_cost_usd": round(intr_cost, 2),
                            "net_pnl_usd": round(active_sp["prem_usd"] - intr_cost, 2),
                            "exit_reason": "assigned_wheel",
                            "pricing_source": m7e._classify_trade_source(en_sp_src, en_sp_src),
                        }
                    )
                    active_sp = None
            else:
                rem_sp = max(1, (active_sp["exp_dt"] - dt_objs[i]).days)
                _, _, pm_sp, iv_sp_now, _, _ = _lookup_leg(
                    d, "put", active_sp["exp_date"], active_sp["kp"], active_sp.get("k_cents"),
                    cl, rem_sp, r_cur, q_cur, vxn_cl, active_sp.get("last_iv"), slip_bsm=0.03,
                )
                active_sp["last_iv"] = iv_sp_now
                sp_mtm = -active_sp["shares"] * pm_sp

        # D4. Engine 3 Reverse Wheel Covered Call EOD settlement or MTM
        wc_mtm = 0.0
        if active_wc is not None:
            if _is_exp(i, active_wc["exp_dt"]):
                en_wc_src = active_wc.get("entry_source", "bsm_fallback")
                if cl > active_wc["kc"]:
                    sp_cash += assigned_shares * active_wc["kc"]
                    stock_gain = active_wc["shares"] * (active_wc["kc"] - active_wc["assigned_cost_k"])
                    wc_closed_ledger.append(
                        {
                            "leg_id": f"WC-{active_wc['wc_id']}",
                            "wc_id": active_wc["wc_id"],
                            "cycle_id": active_wc["cycle_id"],
                            "leg_type": "wheel_call",
                            "is_open_live": False,
                            "signal_date": active_wc["signal_date"],
                            "entry_date": active_wc["entry_date"],
                            "exit_date": d,
                            "dte": active_wc["dte"],
                            "entry_spot": round(active_wc["entry_spot"], 2),
                            "strike": round(active_wc["kc"], 2),
                            "kc": round(active_wc["kc"], 2),
                            "assigned_cost_k": round(active_wc["assigned_cost_k"], 2),
                            "exit_spot": round(cl, 2),
                            "shares": round(active_wc["shares"], 2),
                            "prem_usd": round(active_wc["prem_usd"], 2),
                            "exit_cost_usd": 0.0,
                            "stock_gain_usd": round(stock_gain, 2),
                            "net_pnl_usd": round(active_wc["prem_usd"] + stock_gain, 2),
                            "exit_reason": "called_away",
                            "pricing_source": m7e._classify_trade_source(en_wc_src, en_wc_src),
                        }
                    )
                    assigned_shares = 0.0
                    assigned_cost_k = 0.0
                    assigned_entry_date = ""
                    active_wc = None
                    if cur_cycle_start_dt is not None:
                        max_wheel_cycle_days = max(max_wheel_cycle_days, (dt_objs[i] - cur_cycle_start_dt).days)
                        cur_cycle_start_dt = None
                    _sweep_sp_cash_to_core(cl)
                else:
                    wc_closed_ledger.append(
                        {
                            "leg_id": f"WC-{active_wc['wc_id']}",
                            "wc_id": active_wc["wc_id"],
                            "cycle_id": active_wc["cycle_id"],
                            "leg_type": "wheel_call",
                            "is_open_live": False,
                            "signal_date": active_wc["signal_date"],
                            "entry_date": active_wc["entry_date"],
                            "exit_date": d,
                            "dte": active_wc["dte"],
                            "entry_spot": round(active_wc["entry_spot"], 2),
                            "strike": round(active_wc["kc"], 2),
                            "kc": round(active_wc["kc"], 2),
                            "assigned_cost_k": round(active_wc["assigned_cost_k"], 2),
                            "exit_spot": round(cl, 2),
                            "shares": round(active_wc["shares"], 2),
                            "prem_usd": round(active_wc["prem_usd"], 2),
                            "exit_cost_usd": 0.0,
                            "stock_gain_usd": 0.0,
                            "net_pnl_usd": round(active_wc["prem_usd"], 2),
                            "exit_reason": "expired_otm",
                            "pricing_source": m7e._classify_trade_source(en_wc_src, en_wc_src),
                        }
                    )
                    active_wc = None
            else:
                rem_wc = max(1, (active_wc["exp_dt"] - dt_objs[i]).days)
                _, _, cm_wc, iv_wc_now, _, _ = _lookup_leg(
                    d, "call", active_wc["exp_date"], active_wc["kc"], active_wc.get("k_cents"),
                    cl, rem_wc, r_cur, q_cur, vxn_cl, active_wc.get("last_iv"), slip_bsm=0.03,
                )
                active_wc["last_iv"] = iv_wc_now
                wc_mtm = -active_wc["shares"] * cm_wc

        tot_mtm = put_mtm_tot + call_mtm_tot + cc_mtm + sp_mtm + wc_mtm
        nav = (core_shares + assigned_shares) * cl + tbill_cash + cc_cash + sp_cash + tot_mtm

        if sp_enabled:
            gross_stock_lev = ((core_shares + assigned_shares) * cl) / max(nav, 1.0)
            put_notional = (active_sp["shares"] * active_sp["kp"]) if active_sp is not None else 0.0
            notional_lev = ((core_shares + assigned_shares) * cl + put_notional) / max(nav, 1.0)
            if assigned_shares > 1e-6:
                days_levered += 1
            if gross_stock_lev > max_gross_stock_lev:
                max_gross_stock_lev = gross_stock_lev
            if notional_lev > max_notional_lev:
                max_notional_lev = notional_lev

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

        # E2. Normal-time Covered Call entry & war-chest panic deployment check
        if cc_enabled and i < len(dates) - 1:
            if (
                active_cc is None
                and dd_cur >= -cc_ath_limit
                and vxn_cl >= cc_min_vxn
                and not any(t["tranche_type"] == "collar" for t in active_tranches)
            ):
                pending_cc = {
                    "close": cl,
                    "vxn": vxn_cl,
                    "r": r_cur,
                    "q": q_cur,
                }
            if cc_cash > 1.0 and vix_r >= 1.10:
                pending_cc_deploy = True

        # E3. Engine 3 Reverse Wheel Call & Short-DTE Panic Put EOD Gates for t+1 Open
        wc_reclaim_ready = (cl >= assigned_cost_k) if wc_mode == "wc_reclaim_30d_d35" else True
        if sp_enabled and assigned_shares > 1e-6 and active_wc is None and wc_reclaim_ready:
            pending_wc = {
                "signal_date": d,
                "close": cl,
                "vxn": vxn_cl,
                "vix_ratio": vix_r,
                "r": r_cur,
                "q": q_cur,
            }
        if sp_enabled and active_sp is None and assigned_shares <= 1e-6:
            trig_sp = vix_r >= sp_vix_thr
            if trig_sp and sp_require_vix_falling:
                trig_sp = bool(row.get("vix_falling"))
            if trig_sp:
                pending_sp = {
                    "signal_date": d,
                    "close": cl,
                    "vxn": vxn_cl,
                    "vix_ratio": vix_r,
                    "r": r_cur,
                    "q": q_cur,
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
        _, _, pm, _, _, src_p_live = _lookup_leg(
            last_d, "put", tr["exp_date"], tr["kp"], tr.get("k_cents_p"),
            last_cl, rem_d, last_rf, last_q, last_vxn, tr.get("last_iv_p"), slip_bsm=slip,
        )
        if tr["kc"] is not None:
            _, _, cm, _, _, _ = _lookup_leg(
                last_d, "call", tr["exp_date"], tr["kc"], tr.get("k_cents_c"),
                last_cl, rem_d, last_rf, last_q, last_vxn, tr.get("last_iv_c"), slip_bsm=slip,
            )
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
        en_src_l = tr.get("entry_source", "bsm_fallback")
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
                "pricing_source": m7e._classify_trade_source(en_src_l, src_p_live),
                "entry_source": en_src_l,
                "exit_source": src_p_live,
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
                "mtm_spot": round(last_cl, 2),
                "mtm_date": last_d,
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
                "pricing_source": m7e._classify_trade_source(en_src_l, src_p_live),
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

    extra_sh_vs_bh = equiv_sh_list[-1] - final_bh_sh
    extra_sh_pct = (extra_sh_vs_bh / final_bh_sh) * 100.0 if final_bh_sh > 0 else 0.0

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
        "bh_final_shares": round(final_bh_sh, 2),
        "extra_shares_vs_bh": round(extra_sh_vs_bh, 2),
        "extra_shares_pct": round(extra_sh_pct, 2),
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
        "cc_mode": cc_mode,
        "cc_trades_count": len(cc_ledger),
        "cc_assigned_count": cc_assigned_cnt,
        "cc_stop_count": sum(
            1 for x in cc_ledger if x["exit_reason"] in ("delta_stop", "delta_roll_up", "delta_credit_roll")
        ),
        "cc_roll_count": sum(1 for x in cc_ledger if int(x.get("roll_gen", 0)) > 0),
        "cc_active_years": len({x["entry_date"][:4] for x in cc_ledger}),
        "cc_gross_prem_usd": round(cc_gross_prem, 2),
        "cc_gross_loss_usd": round(cc_gross_loss, 2),
        "cc_net_pnl_usd": round(cc_gross_prem - cc_gross_loss, 2),
        "cc_funded_puts_usd": round(cc_funded_puts, 2),
        "cc_cash_end_usd": round(cc_cash, 2),
    }

    sp_wins = sum(1 for x in sp_closed_ledger if x["net_pnl_usd"] > 0)
    sp_win_rate = (sp_wins / len(sp_closed_ledger) * 100.0) if sp_closed_ledger else 0.0
    sp_gross_prem_val = sum(x["prem_usd"] for x in sp_closed_ledger)
    wc_gross_prem_val = sum(x["prem_usd"] for x in wc_closed_ledger)
    wc_called_cnt = sum(1 for x in wc_closed_ledger if x["exit_reason"] == "called_away")

    open_sp_serialized: dict[str, Any] | None = None
    open_wc_serialized: dict[str, Any] | None = None
    sp_combined_ledger: list[dict[str, Any]] = list(sp_closed_ledger) + list(wc_closed_ledger)

    if active_sp is not None:
        rem_sp_last = max(1, (active_sp["exp_dt"] - last_dt).days)
        _, _, pm_sp_last, _, _, src_sp_last = _lookup_leg(
            last_d, "put", active_sp["exp_date"], active_sp["kp"], active_sp.get("k_cents"),
            last_cl, rem_sp_last, last_rf, last_q, last_vxn, active_sp.get("last_iv"), slip_bsm=0.03,
        )
        mtm_cost_sp = active_sp["shares"] * pm_sp_last
        mtm_pnl_sp = active_sp["prem_usd"] - mtm_cost_sp
        ps_sp_last = m7e._classify_trade_source(active_sp.get("entry_source", "bsm_fallback"), src_sp_last)
        open_sp_serialized = {
            "sp_id": active_sp["sp_id"],
            "cycle_id": active_sp["cycle_id"],
            "signal_date": active_sp["signal_date"],
            "entry_date": active_sp["entry_date"],
            "exp_date": active_sp["exp_date"],
            "dte": active_sp["dte"],
            "rem_dte": rem_sp_last,
            "entry_spot": round(active_sp["entry_spot"], 2),
            "kp": round(active_sp["kp"], 2),
            "mtm_spot": round(last_cl, 2),
            "shares": round(active_sp["shares"], 2),
            "prem_usd": round(active_sp["prem_usd"], 2),
            "mtm_cost_usd": round(mtm_cost_sp, 2),
            "mtm_pnl_usd": round(mtm_pnl_sp, 2),
            "pricing_source": ps_sp_last,
        }
        sp_combined_ledger.append(
            {
                "leg_id": f"SP-{active_sp['sp_id']}",
                "sp_id": active_sp["sp_id"],
                "cycle_id": active_sp["cycle_id"],
                "leg_type": "short_put",
                "is_open_live": True,
                "signal_date": active_sp["signal_date"],
                "entry_date": active_sp["entry_date"],
                "exit_date": active_sp["exp_date"],
                "mtm_date": last_d,
                "dte": active_sp["dte"],
                "rem_dte": rem_sp_last,
                "entry_spot": round(active_sp["entry_spot"], 2),
                "strike": round(active_sp["kp"], 2),
                "kp": round(active_sp["kp"], 2),
                "exit_spot": round(last_cl, 2),
                "shares": round(active_sp["shares"], 2),
                "prem_usd": round(active_sp["prem_usd"], 2),
                "exit_cost_usd": round(mtm_cost_sp, 2),
                "net_pnl_usd": round(mtm_pnl_sp, 2),
                "exit_reason": "open_live_short_put",
                "pricing_source": ps_sp_last,
            }
        )

    if active_wc is not None:
        rem_wc_last = max(1, (active_wc["exp_dt"] - last_dt).days)
        _, _, cm_wc_last, _, _, src_wc_last = _lookup_leg(
            last_d, "call", active_wc["exp_date"], active_wc["kc"], active_wc.get("k_cents"),
            last_cl, rem_wc_last, last_rf, last_q, last_vxn, active_wc.get("last_iv"), slip_bsm=0.03,
        )
        mtm_cost_wc = active_wc["shares"] * cm_wc_last
        mtm_pnl_wc = active_wc["prem_usd"] - mtm_cost_wc
        ps_wc_last = m7e._classify_trade_source(active_wc.get("entry_source", "bsm_fallback"), src_wc_last)
        open_wc_serialized = {
            "wc_id": active_wc["wc_id"],
            "cycle_id": active_wc["cycle_id"],
            "signal_date": active_wc["signal_date"],
            "entry_date": active_wc["entry_date"],
            "exp_date": active_wc["exp_date"],
            "dte": active_wc["dte"],
            "rem_dte": rem_wc_last,
            "entry_spot": round(active_wc["entry_spot"], 2),
            "kc": round(active_wc["kc"], 2),
            "assigned_cost_k": round(active_wc["assigned_cost_k"], 2),
            "mtm_spot": round(last_cl, 2),
            "shares": round(active_wc["shares"], 2),
            "prem_usd": round(active_wc["prem_usd"], 2),
            "mtm_cost_usd": round(mtm_cost_wc, 2),
            "mtm_pnl_usd": round(mtm_pnl_wc, 2),
            "pricing_source": ps_wc_last,
        }
        sp_combined_ledger.append(
            {
                "leg_id": f"WC-{active_wc['wc_id']}",
                "wc_id": active_wc["wc_id"],
                "cycle_id": active_wc["cycle_id"],
                "leg_type": "wheel_call",
                "is_open_live": True,
                "signal_date": active_wc["signal_date"],
                "entry_date": active_wc["entry_date"],
                "exit_date": active_wc["exp_date"],
                "mtm_date": last_d,
                "dte": active_wc["dte"],
                "rem_dte": rem_wc_last,
                "entry_spot": round(active_wc["entry_spot"], 2),
                "strike": round(active_wc["kc"], 2),
                "kc": round(active_wc["kc"], 2),
                "assigned_cost_k": round(active_wc["assigned_cost_k"], 2),
                "exit_spot": round(last_cl, 2),
                "shares": round(active_wc["shares"], 2),
                "prem_usd": round(active_wc["prem_usd"], 2),
                "exit_cost_usd": round(mtm_cost_wc, 2),
                "net_pnl_usd": round(mtm_pnl_wc, 2),
                "exit_reason": "open_live_wheel_call",
                "pricing_source": ps_wc_last,
            }
        )

    sp_combined_ledger.sort(key=lambda x: (x["entry_date"], 0 if x["leg_type"] == "short_put" else 1, x["leg_id"]))

    last_gross_stock_lev = (
        ((core_shares + assigned_shares) * last_cl) / max(nav_list[-1], 1.0) if sp_enabled else 1.0
    )
    last_put_notional = (active_sp["shares"] * active_sp["kp"]) if (sp_enabled and active_sp is not None) else 0.0
    last_notional_lev = (
        ((core_shares + assigned_shares) * last_cl + last_put_notional) / max(nav_list[-1], 1.0)
        if sp_enabled
        else 1.0
    )

    all_trades_src = (
        [x.get("pricing_source", "bsm_fallback") for x in ledger]
        + [x.get("pricing_source", "bsm_fallback") for x in cc_ledger]
        + [x.get("pricing_source", "bsm_fallback") for x in sp_combined_ledger]
    )
    n_tot_tr = len(all_trades_src)
    n_opra_tr = sum(1 for s in all_trades_src if s == "real_opra")
    n_poly_tr = sum(1 for s in all_trades_src if s == "real_polygon")
    n_real_tr = sum(1 for s in all_trades_src if s in ("real_opra", "real_polygon", "real_hybrid"))
    n_sim_tr = n_tot_tr - n_real_tr
    real_tr_pct = round(100.0 * n_real_tr / n_tot_tr, 1) if n_tot_tr > 0 else (100.0 if use_real else 0.0)
    tot_lk = max(1, q_stats["total_lookups"])
    real_hit_pct = round(100.0 * (q_stats["real_opra_hits"] + q_stats["real_polygon_hits"]) / tot_lk, 1) if q_stats["total_lookups"] > 0 else (100.0 if use_real else 0.0)

    summary.update(
        {
            "sp_mode": sp_mode,
            "wc_mode": wc_mode if sp_enabled else DEFAULT_WC_MODE,
            "sp_trades_count": len(sp_closed_ledger),
            "sp_win_rate_pct": round(sp_win_rate, 1),
            "sp_assignments_count": sp_assign_count,
            "wc_trades_count": len(wc_closed_ledger),
            "wc_called_away_count": wc_called_cnt,
            "sp_gross_prem_usd": round(sp_gross_prem_val, 2),
            "wc_gross_prem_usd": round(wc_gross_prem_val, 2),
            "margin_interest_usd": round(sp_margin_interest_total, 2),
            "sp_comm_usd": round(sp_comm_total, 2),
            "days_short_put_open": days_short_put_open,
            "days_levered_stock": days_levered,
            "max_wheel_cycle_days": max_wheel_cycle_days,
            "max_gross_stock_lev": round(max_gross_stock_lev, 3),
            "max_notional_lev": round(max_notional_lev, 3),
            "end_assigned_shares": round(assigned_shares, 2),
            "end_assigned_cost_k": round(assigned_cost_k, 2),
            "end_sp_cash": round(sp_cash, 2),
            "pricing_basis": "hybrid_real_opra_polygon_bsm" if use_real else "bsm_synthetic",
            "real_trades_count": n_real_tr,
            "real_opra_trades_count": n_opra_tr,
            "real_polygon_trades_count": n_poly_tr,
            "sim_trades_count": n_sim_tr,
            "real_trades_pct": real_tr_pct,
            "real_quote_hit_pct": real_hit_pct,
        }
    )

    return {
        "summary": summary,
        "nav": nav_list,
        "equiv_shares": equiv_sh_list,
        "any_active": any_active_list,
        "active_slots": active_slots_list,
        "slot1_naked": slot1_naked_list,
        "shield_active": shield_active_list,
        "ledger": ledger,
        "cc_ledger": cc_ledger,
        "sp_ledger": sp_combined_ledger,
        "shield_events": shield_events,
        "active_tranches_eod": active_tranches_serialized,
        "pending_sig_eod": pending_sig,
        "in_slow_bear_eod": in_slow_bear_def,
        "pending_bear_change_eod": pending_bear_change,
        "sp_live_eod": {
            "enabled": sp_enabled,
            "sp_mode": sp_mode,
            "wc_mode": wc_mode if sp_enabled else DEFAULT_WC_MODE,
            "sp_dte": sp_dte,
            "sp_max_lev": sp_max_lev,
            "require_vix_falling": sp_require_vix_falling,
            "assigned_shares": round(assigned_shares, 2),
            "assigned_cost_k": round(assigned_cost_k, 2),
            "assigned_entry_date": assigned_entry_date,
            "sp_cash_usd": round(sp_cash, 2),
            "gross_stock_lev": round(last_gross_stock_lev, 3),
            "notional_lev": round(last_notional_lev, 3),
            "open_short_put": open_sp_serialized,
            "open_wheel_call": open_wc_serialized,
            "pending_sp_eod": pending_sp is not None,
            "pending_wc_eod": pending_wc is not None,
        },
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
        s_num = int(tr.get("slot_num") or 1)
        if is_nk:
            ev_type = "slot1_naked_put" if s_num == 1 else f"slot{s_num}_naked_put"
        else:
            ev_type = f"slot{s_num}_collar"
        open_ev: dict[str, Any] = {
            "event_id": f"{strategy_id}_tr{tr['tranche_id']}_open",
            "tranche_id": tr["tranche_id"],
            "strategy_id": strategy_id,
            "date": tr["entry_date"],
            "signal_date": tr["signal_date"],
            "event_type": ev_type,
            "slot_num": s_num,
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
        if "crisis_prob" in tr:
            open_ev.update(
                {
                    "crisis_prob": tr.get("crisis_prob"),
                    "p1": tr.get("p1"),
                    "p2": tr.get("p2"),
                    "p3": tr.get("p3"),
                    "triggered_modules": tr.get("triggered_modules"),
                    "trigger_code": tr.get("trigger_code"),
                    "tier": tr.get("tier"),
                    "max_slots": tr.get("max_slots"),
                    "put_otm_pct": tr.get("put_otm_pct"),
                    "contracts_est": tr.get("contracts_est"),
                    "roi_mult": tr.get("roi_mult"),
                    "tp_mode": tr.get("tp_mode"),
                    "roll_mode": tr.get("roll_mode"),
                    "target_dte": tr.get("target_dte"),
                    "roll_dte": tr.get("roll_dte"),
                    "is_cta": tr.get("is_cta"),
                    "quoteSource": tr.get("quoteSource"),
                    "occSymbol": tr.get("occSymbol"),
                    "exp": tr.get("exp"),
                    "strike": tr.get("strike"),
                    "entryBid": tr.get("entryBid"),
                    "entryAsk": tr.get("entryAsk"),
                    "exitBid": tr.get("exitBid"),
                    "exitAsk": tr.get("exitAsk"),
                }
            )
        events.append(open_ev)

        is_open_live = bool(tr.get("is_open_live"))
        ex_reason = str(tr.get("exit_reason") or "")
        is_live_armed = ex_reason in (
            "live_tp_armed_next_open",
            "live_roll50_armed_next_open",
            "live_roll30_armed_next_open",
        )
        is_roll50 = ex_reason == "roll_50d"
        is_roll30 = ex_reason == "roll_30d"
        is_tp = ("tp" in ex_reason) and not is_open_live
        is_put5x = "put_5x" in ex_reason
        is_itm_tp = "itm_tp" in ex_reason
        is_4x_tp = "4x_tp" in ex_reason
        ev_exit_date = tr["exit_date"] if not is_open_live else tr.get("mtm_date")
        if (not is_open_live or is_live_armed) and ev_exit_date:
            if ex_reason in ("live_roll50_armed_next_open", "live_roll30_armed_next_open"):
                rl_lbl = 30 if "30" in ex_reason else 50
                ev_type_exit = f"live_roll{rl_lbl}_armed"
                trig_en_exit = f"{rl_lbl}-DTE Roll/Salvage Armed ({tr['rem_dte_at_exit']} DTE left · Next Open)"
                trig_zh_exit = f"{rl_lbl}-DTE 残值滚仓已触发（剩 {tr['rem_dte_at_exit']} 天 · 待次日开盘执行）"
            elif is_live_armed:
                ev_type_exit = "live_tp_armed"
                trig_en_exit = (
                    f"Deep-ITM Panic TP Armed ({tr['rem_dte_at_exit']} DTE left · VIX/3M {tr['exit_vix_ratio']:.3f} · Next Open)"
                )
                trig_zh_exit = (
                    f"实值恐慌止盈已触发（剩余 {tr['rem_dte_at_exit']} 天 · VIX/3M {tr['exit_vix_ratio']:.3f} · 待次日开盘换股）"
                )
            elif is_roll50 or is_roll30:
                rl_lbl = 30 if is_roll30 else 50
                ev_type_exit = "roll_30d" if is_roll30 else "roll_50d"
                salv_pct = float(tr.get("roi_mult") or 0.0) * 100.0
                trig_en_exit = f"{rl_lbl}-DTE Residual Roll/Salvage ({tr['rem_dte_at_exit']} DTE left · {salv_pct:.0f}% Value Saved)"
                trig_zh_exit = f"{rl_lbl}-DTE 剩余残值滚仓/回收（剩 {tr['rem_dte_at_exit']} 天 · 回收 {salv_pct:.0f}% 残值）"
            elif is_put5x:
                dte_cap_lbl = 75 if "dte75" in ex_reason else 45
                ev_type_exit = "put5x_dte45_tp"
                trig_en_exit = f"5x Put Slow-Bear TP ({tr['rem_dte_at_exit']} DTE <= {dte_cap_lbl}, Deep ITM Lock)"
                trig_zh_exit = f"后半程 Put >= 5x 慢熊止盈（剩余 {tr['rem_dte_at_exit']} 天 <= {dte_cap_lbl} · 深实值锁利）"
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
                tenor_exp = 120 if "120dte" in ex_reason else 90
                ev_type_exit = "option_expiry"
                trig_en_exit = f"{tenor_exp}-DTE Expiry ({tr['underlying_ret_pct']:+.1f}% spot)"
                trig_zh_exit = f"{tenor_exp}-DTE 到期结算（期间正股 {tr['underlying_ret_pct']:+.1f}%）"

            exit_ev: dict[str, Any] = {
                "event_id": f"{strategy_id}_tr{tr['tranche_id']}_exit",
                "tranche_id": tr["tranche_id"],
                "strategy_id": strategy_id,
                "date": ev_exit_date,
                "signal_date": tr["signal_date"],
                "event_type": ev_type_exit,
                "slot_num": s_num,
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
            if "crisis_prob" in tr:
                exit_ev.update(
                    {
                        "crisis_prob": tr.get("crisis_prob"),
                        "trigger_code": tr.get("trigger_code"),
                        "triggered_modules": tr.get("triggered_modules"),
                        "max_slots": tr.get("max_slots"),
                        "put_otm_pct": tr.get("put_otm_pct"),
                        "contracts_est": tr.get("contracts_est"),
                        "roi_mult": tr.get("roi_mult"),
                        "tp_mode": tr.get("tp_mode"),
                        "roll_mode": tr.get("roll_mode"),
                        "exit_reason": ex_reason,
                        "quoteSource": tr.get("quoteSource"),
                        "occSymbol": tr.get("occSymbol"),
                        "exp": tr.get("exp"),
                        "strike": tr.get("strike"),
                        "entryBid": tr.get("entryBid"),
                        "entryAsk": tr.get("entryAsk"),
                        "exitBid": tr.get("exitBid"),
                        "exitAsk": tr.get("exitAsk"),
                    }
                )
            events.append(exit_ev)

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
        "roll_50d": 2,
        "roll_30d": 2,
        "live_roll50_armed": 2,
        "live_roll30_armed": 2,
        "option_expiry": 3,
        "shield_enter": 4,
        "shield_exit": 5,
        "slot1_naked_put": 6,
        "slot2_naked_put": 7,
        "slot3_naked_put": 8,
        "slot1_collar": 9,
        "slot2_collar": 10,
        "slot3_collar": 11,
    }
    events.sort(key=lambda e: (e["date"], order_rank.get(e["event_type"], 99)))
    return events


def build_artifact(fact_root: Path | None = None, live_fetch: bool = False) -> dict[str, Any]:
    rows_all, coeffs = load_seed_and_extend(fact_root=fact_root)
    m7_data, rows_all = m7e.load_m7_seed_and_optional_live(M7_SEED_GZ, rows_all, live_fetch=live_fetch)
    m7_sig_pack = m7e.compute_m7_signals_and_tail(rows_all, m7_data, start_eval_date=START_DATE)
    rows_eval = [r for r in rows_all if r["date"] >= START_DATE]
    real_store = roc.HybridRealOptionChainStore()
    print(
        f"[real-chain] Loaded MIT Real OPRA ({real_store.opra_date_min}..{real_store.opra_date_max}, "
        f"{real_store.opra_days}d, {real_store.opra_quotes_count:,} quotes) + OPRA-Calibrated BSM post-{real_store.opra_date_max}",
        flush=True,
    )

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
                "name_en": "Legacy U1 Six-Lights Hybrid (50% Naked Put + 50% Zero-Cost Collar)",
                "name_zh": "旧版对照 · U1 六灯双槽版（50% 首仓裸 Put + 50% 次仓零成本领口）",
                "short_en": "Legacy U1 Dual-Slot",
                "short_zh": "旧版对照 · U1 双槽",
                "badge_en": "LEGACY COMPARISON · PUT + COLLAR",
                "badge_zh": "旧版六灯双槽对照",
                "color_hex": "#7DB8F0",
                "rule_summary_en": "Legacy baseline: 100% QQQ core + Slot 1 50% Naked -10% Put + Slot 2 50% 30D-stepped Collar on (AD<50DMA or >=4 Lights) & ATH<=5% & VXN<=22. Priced on 2015-2025 MIT Real OPRA Bid/Ask + post-2025 OPRA-Calibrated BSM.",
                "rule_summary_zh": "旧版双槽对照：底仓 100% QQQ，在 ATH<=5% 且 VXN<=22 时凭 AD 顶背离或 >=4 盏危机灯开首仓 50% 裸 Put、满30天补次仓 50% 零成本 Collar（同样基于 2015–2025 MIT 真实 OPRA 盘口 + 2025-12-16 后校准 BSM 回测）。",
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
            "NoPut_CallOnly",
            {
                "arch": "cc_only",
                "max_slots": 0,
                "slot_coverage": 0.0,
                "gate_key": None,
                "vix_ratio_tp": None,
                "slow_bear_overlay": False,
            },
            {
                "code_name": "NoPut_CallOnly",
                "name_en": "No Crisis Put (Pure Normal-Time Covered Call Comparison)",
                "name_zh": "不买 Put（纯平时卖 Call 对照组）",
                "short_en": "No Put (Call Only)",
                "short_zh": "不买 Put（仅卖 Call）",
                "badge_en": "CALL-ONLY CONTROL · ZERO PUT",
                "badge_zh": "纯卖 Call 对照 · 无危机 Put",
                "color_hex": "#7DB8F0",
                "rule_summary_en": "Zero crisis Puts or Collars; holds 100% QQQ and runs ONLY the selected normal-time 25D 12-Delta Covered Call overlay (equals Buy & Hold when Call is Off).",
                "rule_summary_zh": "关闭所有危机买 Put 与领口保护，100% 持有 QQQ 并仅叠加所选的平时 25D 12Δ 卖 Call 规则（若关闭卖 Call 则与死拿 QQQ 完全一致）。",
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
    prev_eval_row = rows_eval[-2] if len(rows_eval) >= 2 else last_row
    as_of_date = last_row["date"]
    qqq_cl = float(last_row["close"])
    qqq_ma200 = float(last_row["qqq_ma200"])

    def _build_live_sp_state(row: dict[str, Any], prev_row: dict[str, Any], sim_res: dict[str, Any]) -> dict[str, Any]:
        sp_eod = sim_res["sp_live_eod"]
        sp_id = str(sp_eod["sp_mode"])
        wc_id = str(sp_eod.get("wc_mode") or DEFAULT_WC_MODE)
        enabled = bool(sp_eod["enabled"])
        vix_now = float(row["vix"])
        vix_prev = float(prev_row["vix"])
        vix_chg = vix_now - vix_prev
        vix_fall = bool(row.get("vix_falling"))
        vix3m_now = float(row["vix3m"])
        vr_now = float(row["vix_ratio"])
        inv_on = vr_now >= 1.00
        unf_gate = inv_on
        vixf_gate = bool(inv_on and vix_fall)
        req_fall = bool(sp_eod["require_vix_falling"])
        mode_gate = vixf_gate if req_fall else unf_gate
        dte_lbl = f"{int(sp_eod['sp_dte'])}D"
        is_reclaim_30d = wc_id == "wc_reclaim_30d_d35"
        wc_dte_lbl = "30D" if wc_id in ("wc_reclaim_30d_d35", "wc_30d_c5s5") else dte_lbl
        wc_formula_zh = (
            "涨回接货价后卖 30D 0.35Δ"
            if is_reclaim_30d
            else ("max(1.05×成本, 1.05×现价)" if wc_id == "wc_30d_c5s5" else "max(成本, 1.02×现价)")
        )
        wc_formula_en = (
            "Reclaim K_assign -> 30D 0.35Δ"
            if is_reclaim_30d
            else ("max(1.05x Cost, 1.05x Spot)" if wc_id == "wc_30d_c5s5" else "max(Cost, 1.02x Spot)")
        )
        cap_pct = round(float(sp_eod["sp_max_lev"]) * 100.0)
        asgn_sh = float(sp_eod["assigned_shares"])
        asgn_k = float(sp_eod["assigned_cost_k"])
        open_sp = sp_eod["open_short_put"]
        open_wc = sp_eod["open_wheel_call"]
        lev_x = float(sp_eod["gross_stock_lev"])
        spot_cl = float(row["close"])
        if asgn_sh > 1e-6:
            if is_reclaim_30d:
                if spot_cl >= asgn_k:
                    k35_est = solve_call_strike_for_delta(
                        spot_cl, 30.0 / 365.0, float(row["r"]), float(row["div_yield"]), float(row["vxn"]), coeffs, 0.35
                    )
                    min_kc = max(asgn_k, k35_est)
                else:
                    min_kc = asgn_k
            elif wc_id == "wc_30d_c5s5":
                min_kc = max(asgn_k * 1.05, spot_cl * 1.05)
            else:
                min_kc = max(asgn_k, spot_cl * 1.02)
        else:
            min_kc = 0.0

        if not enabled:
            pos_state = "disabled"
            tone = "neutral"
            inv_zh = "倒挂满足 >=1.00" if inv_on else "未倒挂 <1.00"
            inv_en = "Inverted >=1.00" if inv_on else "Contango <1.00"
            vix_dir_zh = f"回落 {vix_chg:+.2f}" if vix_fall else f"冲高 {vix_chg:+.2f}"
            vix_dir_en = f"Falling {vix_chg:+.2f}" if vix_fall else f"Rising {vix_chg:+.2f}"
            badge_zh = f"第三引擎已关闭 · 0 杠杆（今日 VIX/3M {vr_now:.3f} {inv_zh} · VIX {vix_now:.2f} {vix_dir_zh}）"
            badge_en = f"Engine 3 Off · 0 Leverage (Today VIX/3M {vr_now:.3f} {inv_en} · VIX {vix_now:.2f} {vix_dir_en})"
            detail_zh = "切换上方「恐慌卖 Put Wheel」档位，可叠加上限 10% 或 20% 净值的短久期卖 Put 与反向接货卖 Call 增厚引擎。"
            detail_en = "Select a Panic Put Wheel mode above to overlay <= 10% or <= 20% equity capped short-DTE puts + Reverse Wheel calls."
        elif asgn_sh > 1e-6 and open_wc is not None:
            pos_state = "wheel_call_open"
            tone = "wheel"
            badge_zh = (
                f"反向 Wheel 持仓中（{asgn_sh:.0f}股 @ ${asgn_k:.2f} · 敞口 {lev_x:.2f}x）"
                f" · 已卖 {wc_dte_lbl} Call K=${open_wc['kc']:.2f}（剩 {open_wc['rem_dte']} 天）"
            )
            badge_en = (
                f"Wheel Call Active ({asgn_sh:.0f} sh @ ${asgn_k:.2f} · {lev_x:.2f}x Lev)"
                f" · Short {wc_dte_lbl} Call K=${open_wc['kc']:.2f} ({open_wc['rem_dte']}D left)"
            )
            detail_zh = f"到期若 QQQ 高于 ${open_wc['kc']:.2f} 即自动被 Call 走清零融资负债，净盈利沉淀为永久 QQQ 份额。"
            detail_en = f"If QQQ closes above ${open_wc['kc']:.2f} at expiry, assigned stock is called away, clearing margin debt into permanent QQQ shares."
        elif asgn_sh > 1e-6 and is_reclaim_30d and spot_cl < asgn_k:
            pos_state = "wheel_assigned_wait_reclaim"
            tone = "wheel"
            gap_pct = (asgn_k / max(spot_cl, 1e-6) - 1.0) * 100.0
            badge_zh = (
                f"已接货进 Wheel（{asgn_sh:.0f}股 @ ${asgn_k:.2f} · 股票敞口 {lev_x:.2f}x）"
                f" · 水下暂不卖 Call，等涨回 >= ${asgn_k:.2f}（差 +{gap_pct:.1f}%）再卖 30D 0.35Δ Call"
            )
            badge_en = (
                f"Assigned into Wheel ({asgn_sh:.0f} sh @ ${asgn_k:.2f} · {lev_x:.2f}x Stock Lev)"
                f" · Holding Uncapped until QQQ >= ${asgn_k:.2f} (+{gap_pct:.1f}%), then Sell 30D 0.35Δ Call"
            )
            detail_zh = (
                f"水下阶段严禁封顶卖 Call 且禁止再卖新 Put；按 IBKR 基准利率 +1.50% 计息，100% 保留反弹斜率，待收盘涨回 >= ${asgn_k:.2f} 后次日开盘卖 30D 0.35Δ Call 清债。"
            )
            detail_en = (
                f"No capped calls or new puts while underwater (QQQ ${spot_cl:.2f} < ${asgn_k:.2f}); holds 100% uncapped recovery until EOD reclaim >= ${asgn_k:.2f}, then sells 30D 0.35Δ Call."
            )
        elif asgn_sh > 1e-6:
            pos_state = "wheel_assigned_wc_armed"
            tone = "wheel"
            badge_zh = (
                f"已接货进 Wheel（{asgn_sh:.0f}股 @ ${asgn_k:.2f} · 股票敞口 {lev_x:.2f}x）"
                f" -> 次日开盘卖 {wc_dte_lbl} Wheel Call（K >= ${min_kc:.2f}，{wc_formula_zh}）"
            )
            badge_en = (
                f"Assigned into Wheel ({asgn_sh:.0f} sh @ ${asgn_k:.2f} · {lev_x:.2f}x Stock Lev)"
                f" -> Next Open Sell {wc_dte_lbl} Wheel Call (K >= ${min_kc:.2f}, {wc_formula_en})"
            )
            detail_zh = f"接货期间严禁再卖新 Put（杜绝滚雪球加杠杆），按 IBKR 基准利率 +1.50% 计息并持续卖 {wc_dte_lbl} Wheel Call（{wc_formula_zh}）直至被 Call 走清债。"
            detail_en = f"New short puts are hard-frozen while holding assigned stock; accrues IBKR rf + 1.50% margin and sells {wc_dte_lbl} Wheel Calls at {wc_formula_en} until called away."
        elif open_sp is not None:
            pos_state = "short_put_open"
            tone = "active"
            gate_note_zh = (
                f"今日 VIX {vix_chg:+.2f} 未回落"
                if (req_fall and not vix_fall)
                else f"今日 VIX/3M {vr_now:.3f}"
            )
            gate_note_en = (
                f"Today VIX {vix_chg:+.2f} rising"
                if (req_fall and not vix_fall)
                else f"Today VIX/3M {vr_now:.3f}"
            )
            badge_zh = (
                f"持仓 {dte_lbl} 恐慌卖 Put（K=${open_sp['kp']:.2f} · {open_sp['shares']:.0f}股 · 剩 {open_sp['rem_dte']} 天）"
                f" · {gate_note_zh}"
            )
            badge_en = (
                f"Live {dte_lbl} Short Put Open (K=${open_sp['kp']:.2f} · {open_sp['shares']:.0f} sh · {open_sp['rem_dte']}D left)"
                f" · {gate_note_en}"
            )
            detail_zh = f"权利金 +${open_sp['prem_usd']:,.0f}（当前浮动盈亏 {open_sp['mtm_pnl_usd']:+,.0f} 美元）；到期不破 ${open_sp['kp']:.2f} 全额买成 QQQ，跌破则转入 {cap_pct}% 帽反向 Wheel。"
            detail_en = f"Collected +${open_sp['prem_usd']:,.0f} premium (live MTM {open_sp['mtm_pnl_usd']:+,.0f} USD); sweeps into QQQ if >= ${open_sp['kp']:.2f} or enters {cap_pct}%-capped Reverse Wheel if ITM."
        elif bool(sp_eod["pending_sp_eod"]):
            pos_state = "entry_armed_next_open"
            tone = "armed"
            badge_zh = f"今日信号触发 -> 次日开盘卖 {dte_lbl} 5% OTM Put（名义帽 <= {cap_pct}% · VIX/3M {vr_now:.3f}）"
            badge_en = f"Signal Triggered Today -> Sell {dte_lbl} 5% OTM Put Next Open (<= {cap_pct}% Cap · VIX/3M {vr_now:.3f})"
            detail_zh = f"VIX/VIX3M = {vr_now:.3f} >= 1.00 恐慌倒挂门控已满足（VIX {vix_now:.2f} vs 昨日 {vix_prev:.2f}），次日开盘执行。"
            detail_en = f"VIX/VIX3M = {vr_now:.3f} >= 1.00 backwardation gate met (VIX {vix_now:.2f} vs prior {vix_prev:.2f}); executes at next Open."
        else:
            pos_state = "flat_standby"
            tone = "neutral"
            if inv_on and req_fall and not vix_fall:
                badge_zh = f"空仓等待恐慌拐点 · VIX/3M {vr_now:.3f} 已倒挂但今日 VIX 冲高 {vix_chg:+.2f}（需回落才开仓）"
                badge_en = f"Flat · Waiting for VIX Crest (VIX/3M {vr_now:.3f} >= 1.00, but VIX {vix_chg:+.2f} Still Rising)"
                detail_zh = "10D VIX回落档位要求倒挂期间出现首次 VIX 日度回落（确认急跌斜率放缓）才卖 Put，规避主跌浪首日接飞刀。"
                detail_en = "10D VIX-Falling mode waits for the first daily VIX drop while VIX/VIX3M >= 1.00 before selling puts."
            else:
                badge_zh = f"空仓待命 · 0 持仓 0 利息（今日 VIX/3M {vr_now:.3f} 未达 1.00 倒挂线）"
                badge_en = f"Flat Standby · 0 Margin Debt (Today VIX/3M {vr_now:.3f} < 1.00 Contango)"
                detail_zh = "平时顺风期不卖 Put、不占保证金，仅在 VIX/VIX3M >= 1.00 恐慌期限倒挂时出击。"
                detail_en = "Zero short puts during normal contango markets; activates strictly on VIX/VIX3M >= 1.00 panic backwardation."

        return {
            "as_of_date": row["date"],
            "sp_mode": sp_id,
            "wc_mode": wc_id,
            "enabled": enabled,
            "vix": round(vix_now, 2),
            "prev_vix": round(vix_prev, 2),
            "vix_change": round(vix_chg, 2),
            "vix_falling": vix_fall,
            "vix3m": round(vix3m_now, 2),
            "vix_vix3m_ratio": round(vr_now, 3),
            "backwardation_active": inv_on,
            "unfiltered_signal_on": unf_gate,
            "vix_falling_signal_on": vixf_gate,
            "mode_entry_gate_met": mode_gate,
            "position_state": pos_state,
            "status_tone": tone,
            "assigned_shares": round(asgn_sh, 2),
            "assigned_cost_k": round(asgn_k, 2),
            "min_next_wc_strike": round(min_kc, 2) if asgn_sh > 1e-6 else None,
            "sp_cash_usd": round(float(sp_eod["sp_cash_usd"]), 2),
            "gross_stock_lev": round(lev_x, 3),
            "notional_lev": round(float(sp_eod["notional_lev"]), 3),
            "open_short_put": open_sp,
            "open_wheel_call": open_wc,
            "badge_en": badge_en,
            "badge_zh": badge_zh,
            "detail_en": detail_en,
            "detail_zh": detail_zh,
        }

    # Simulate Buy & Hold once (identical across all TP, CC, SP & WC modes)
    bh_def = [d for d in strategy_defs if d[0] == "BH_Pure_QQQ"][0]
    bh_sim = simulate_strategy(rows_all, coeffs, strategy_id="BH_Pure_QQQ", real_store=real_store, **bh_def[1])
    bh_summary = {**bh_sim["summary"], **bh_def[2]}

    mode_bundles: dict[str, Any] = {}
    tp_modes_bundle: dict[str, Any] = {}
    tp_slot_series: dict[str, dict[str, list[Any]]] = {}
    tp_modes_meta: list[dict[str, Any]] = []
    cc_modes_meta: list[dict[str, Any]] = []
    sp_modes_meta_by_id: dict[str, dict[str, Any]] = {}
    wc_modes_meta_by_id: dict[str, dict[str, Any]] = {}

    static_win_keys = {
        "episode_num",
        "title_en",
        "title_zh",
        "pill_en",
        "pill_zh",
        "crisis_start",
        "crisis_end",
        "zoom_start",
        "zoom_end",
        "narrative_en",
        "narrative_zh",
    }

    def _pack_ledger_rows(items: list[dict[str, Any]]) -> Any:
        if not items:
            return []
        cols: list[str] = []
        seen: set[str] = set()
        for it in items:
            for k in it.keys():
                if k not in seen:
                    cols.append(k)
                    seen.add(k)
        return {"_cols": cols, "_rows": [[it.get(c) for c in cols] for it in items]}

    for mode_spec in TP_MODE_SPECS:
        mode_id = mode_spec["id"]
        for cc_spec in CC_MODE_SPECS:
            cc_id = cc_spec["id"]
            for sp_spec in SP_MODE_SPECS:
                sp_id = sp_spec["id"]
                wc_specs_for_sp = [WC_MODE_SPECS[0]] if sp_id == DEFAULT_SP_MODE else WC_MODE_SPECS
                for wc_spec in wc_specs_for_sp:
                    wc_id = wc_spec["id"]
                    is_default_combo = (
                        mode_id == DEFAULT_TP_MODE
                        and cc_id == DEFAULT_CC_MODE
                        and sp_id == DEFAULT_SP_MODE
                        and wc_id == DEFAULT_WC_MODE
                    )
                    sims_m: dict[str, dict[str, Any]] = {"BH_Pure_QQQ": bh_sim}
                    summaries_m: list[dict[str, Any]] = []
                    ledgers_m: dict[str, list[dict[str, Any]]] = {}
                    cc_ledgers_m: dict[str, list[dict[str, Any]]] = {}
                    sp_ledgers_m: dict[str, list[dict[str, Any]]] = {}
                    events_m: dict[str, list[dict[str, Any]]] = {}
                    live_states_by_strat_m: dict[str, dict[str, Any]] = {}
                    live_sp_states_by_strat_m: dict[str, dict[str, Any]] = {}

                    for sid, sim_kw, meta in strategy_defs:
                        if sid == "BH_Pure_QQQ":
                            summaries_m.append(bh_summary)
                            continue
                        res = simulate_strategy(
                            rows_all,
                            coeffs,
                            strategy_id=sid,
                            tp_mode=mode_id,
                            cc_mode=cc_id,
                            sp_mode=sp_id,
                            wc_mode=wc_id,
                            real_store=real_store,
                            **sim_kw,
                        )
                        sims_m[sid] = res
                        summaries_m.append({**res["summary"], **meta})
                        ledgers_m[sid] = res["ledger"] if is_default_combo else _pack_ledger_rows(res["ledger"])
                        if cc_id != DEFAULT_CC_MODE:
                            cc_ledgers_m[sid] = _pack_ledger_rows(res["cc_ledger"])
                        elif is_default_combo:
                            cc_ledgers_m[sid] = []
                        if sp_id != DEFAULT_SP_MODE:
                            sp_ledgers_m[sid] = _pack_ledger_rows(res["sp_ledger"])
                        elif is_default_combo:
                            sp_ledgers_m[sid] = []
                        if is_default_combo or sid == "U1_PureOptions":
                            events_m[sid] = build_unified_events(sid, res["ledger"], [])
                        live_states_by_strat_m[sid] = build_live_signal_state(last_row, res, tp_mode=mode_id)
                        live_sp_states_by_strat_m[sid] = _build_live_sp_state(last_row, prev_eval_row, res)

                    windows_full = build_crisis_windows(rows_eval, sims_m, events_m["U1_PureOptions"], tp_mode=mode_id)
                    if is_default_combo:
                        windows_m = windows_full
                    else:
                        windows_m = [
                            {k: v for k, v in w.items() if k not in static_win_keys}
                            for w in windows_full
                        ]

                    u1_sum = next(s for s in summaries_m if s["id"] == "U1_PureOptions")
                    if cc_id == DEFAULT_CC_MODE and sp_id == DEFAULT_SP_MODE:
                        tp_slot_series[mode_id] = {
                            "active_slots": [int(v) for v in sims_m["U1_PureOptions"]["active_slots"]],
                            "slot1_naked": [bool(v) for v in sims_m["U1_PureOptions"]["slot1_naked"]],
                        }
                        tp_modes_meta.append(
                            {
                                **mode_spec,
                                "u1_end_nav": u1_sum["end_nav"],
                                "u1_net_alpha_usd": u1_sum["net_alpha_usd"],
                                "u1_cagr_pct": u1_sum["cagr_pct"],
                                "u1_max_dd_pct": u1_sum["max_dd_pct"],
                                "u1_sharpe": u1_sum["sharpe"],
                                "u1_final_shares": u1_sum["final_shares"],
                                "u1_extra_shares": u1_sum["extra_shares_vs_bh"],
                                "u1_extra_shares_pct": u1_sum["extra_shares_pct"],
                            }
                        )
                        tp_modes_bundle[mode_id] = {
                            "tp_mode": mode_id,
                            "strategies_summary": summaries_m,
                        }

                    if mode_id == DEFAULT_TP_MODE and sp_id == DEFAULT_SP_MODE:
                        cc_modes_meta.append(
                            {
                                **cc_spec,
                                "u1_end_nav": u1_sum["end_nav"],
                                "u1_net_alpha_usd": u1_sum["net_alpha_usd"],
                                "u1_cagr_pct": u1_sum["cagr_pct"],
                                "u1_max_dd_pct": u1_sum["max_dd_pct"],
                                "u1_sharpe": u1_sum["sharpe"],
                                "u1_final_shares": u1_sum["final_shares"],
                                "u1_extra_shares": u1_sum["extra_shares_vs_bh"],
                                "u1_extra_shares_pct": u1_sum["extra_shares_pct"],
                                "u1_cc_trades_count": u1_sum["cc_trades_count"],
                                "u1_cc_assigned_count": u1_sum["cc_assigned_count"],
                                "u1_cc_gross_prem_usd": u1_sum["cc_gross_prem_usd"],
                                "u1_cc_gross_loss_usd": u1_sum["cc_gross_loss_usd"],
                                "u1_cc_funded_puts_usd": u1_sum["cc_funded_puts_usd"],
                            }
                        )

                    if mode_id == DEFAULT_TP_MODE and cc_id == "cc_d12_d35" and (
                        sp_id == DEFAULT_SP_MODE or wc_id == DEFAULT_WC_MODE
                    ):
                        sp_modes_meta_by_id[sp_id] = {
                            **sp_spec,
                            "wc_mode": wc_id,
                            "dual_end_nav": u1_sum["end_nav"],
                            "dual_net_alpha_usd": u1_sum["net_alpha_usd"],
                            "dual_cagr_pct": u1_sum["cagr_pct"],
                            "dual_max_dd_pct": u1_sum["max_dd_pct"],
                            "dual_sharpe": u1_sum["sharpe"],
                            "dual_calmar": u1_sum["calmar"],
                            "dual_extra_shares_pct": u1_sum["extra_shares_pct"],
                            "sp_trades_count": u1_sum["sp_trades_count"],
                            "sp_win_rate_pct": u1_sum["sp_win_rate_pct"],
                            "sp_assignments_count": u1_sum["sp_assignments_count"],
                            "wc_trades_count": u1_sum["wc_trades_count"],
                            "wc_called_away_count": u1_sum["wc_called_away_count"],
                            "wc_gross_prem_usd": u1_sum["wc_gross_prem_usd"],
                            "margin_interest_usd": u1_sum["margin_interest_usd"],
                            "days_levered_stock": u1_sum["days_levered_stock"],
                            "max_wheel_cycle_days": u1_sum["max_wheel_cycle_days"],
                            "max_gross_stock_lev": u1_sum["max_gross_stock_lev"],
                        }

                    if mode_id == DEFAULT_TP_MODE and cc_id == "cc_d12_d35" and sp_id == "sp_14d_cap10":
                        wc_modes_meta_by_id[wc_id] = {
                            **wc_spec,
                            "cap10_end_nav": u1_sum["end_nav"],
                            "cap10_net_alpha_usd": u1_sum["net_alpha_usd"],
                            "cap10_cagr_pct": u1_sum["cagr_pct"],
                            "cap10_max_dd_pct": u1_sum["max_dd_pct"],
                            "cap10_sharpe": u1_sum["sharpe"],
                            "cap10_calmar": u1_sum["calmar"],
                            "cap10_wc_trades_count": u1_sum["wc_trades_count"],
                            "cap10_wc_called_away_count": u1_sum["wc_called_away_count"],
                            "cap10_wc_gross_prem_usd": u1_sum["wc_gross_prem_usd"],
                            "cap10_margin_interest_usd": u1_sum["margin_interest_usd"],
                            "cap10_days_levered_stock": u1_sum["days_levered_stock"],
                            "cap10_max_wheel_cycle_days": u1_sum["max_wheel_cycle_days"],
                            "cap10_end_assigned_shares": u1_sum["end_assigned_shares"],
                        }

                    bundle_obj: dict[str, Any] = {
                        "tp_mode": mode_id,
                        "cc_mode": cc_id,
                        "sp_mode": sp_id,
                        "wc_mode": wc_id,
                        "live_signal_state": live_states_by_strat_m["U1_PureOptions"],
                        "live_signal_states_by_strategy": live_states_by_strat_m,
                        "live_sp_state": live_sp_states_by_strat_m["U1_PureOptions"],
                        "live_sp_states_by_strategy": live_sp_states_by_strat_m,
                        "strategies_summary": summaries_m,
                        "trade_ledgers_by_strategy": ledgers_m,
                        "cc_ledgers_by_strategy": cc_ledgers_m,
                        "sp_ledgers_by_strategy": sp_ledgers_m,
                        "crisis_windows": windows_m,
                        "nav_u1": [round(v, 2) for v in sims_m["U1_PureOptions"]["nav"]],
                        "nav_b1c": [round(v, 2) for v in sims_m["B1c_PureAD"]["nav"]],
                        "nav_d2": [round(v, 2) for v in sims_m["D2_SixLights"]["nav"]],
                        "nav_h2": [round(v, 2) for v in sims_m["H2_G4_PriceGate"]["nav"]],
                        "nav_cc": [round(v, 2) for v in sims_m["NoPut_CallOnly"]["nav"]],
                    }
                    if is_default_combo:
                        bundle_obj["events_by_strategy"] = events_m
                        bundle_obj["active_slots"] = tp_slot_series[mode_id]["active_slots"]
                        bundle_obj["slot1_naked"] = tp_slot_series[mode_id]["slot1_naked"]

                    if sp_id == DEFAULT_SP_MODE:
                        b_key = f"{mode_id}__{cc_id}"
                    elif wc_id == DEFAULT_WC_MODE:
                        b_key = f"{mode_id}__{cc_id}__{sp_id}"
                    else:
                        b_key = f"{mode_id}__{cc_id}__{sp_id}__{wc_id}"
                    mode_bundles[b_key] = bundle_obj

    sp_modes_meta = [sp_modes_meta_by_id[s["id"]] for s in SP_MODE_SPECS]
    wc_modes_meta = [wc_modes_meta_by_id[w["id"]] for w in WC_MODE_SPECS]

    # --- Build M7-Graded, Core-3 Minimal & M7 Ensemble Bundles (24 core configs: OTM x TP x Roll x M0) ---
    m7_strategy_meta: dict[str, dict[str, Any]] = {
        "M7G_Graded": {
            "code_name": "M7G_FullShield_Adaptive_120_90",
            "name_en": "Full M7 Shield · Recommended (6-Module Radar + Adaptive Roll 120->50 / CTA 90->30)",
            "name_zh": "全套 M7 护盾 · 默认推荐（6维雷达 + 自适应滚仓 120→50 / CTA 90→30）",
            "short_en": "Full M7 Shield · Recommended",
            "short_zh": "全套 M7 护盾 · 默认推荐",
            "badge_en": "RECOMMENDED · FULL M7 SHIELD",
            "badge_zh": "默认推荐 · 全套 M7 护盾",
            "color_hex": "#80C6A8",
            "rule_summary_en": "6-Module Radar (P1 M0+M6, P2 M2+M5, P3 M4+M3) + Adaptive Roll 120->50 / CTA 90->30 (-15% OTM Put). Shields 2020-type exogenous black swans, #1 in 2021-2025. Validated on 2015-2025 MIT Real OPRA Bid/Ask + post-2025 OPRA-Calibrated BSM.",
            "rule_summary_zh": "6维雷达（P1 M0+M6、P2 M2+M5、P3 M4+M3）+ 自适应滚仓 120→50 / CTA 90→30（-15% OTM 裸 Put）· 抗2020型外生黑天鹅，2021–2025后半程更强。经 2015–2025 MIT 真实 OPRA 盘口 + 2025-12-16 后 OPRA 实盘校准 BSM 验证。",
        },
        "Core3_Adaptive": {
            "code_name": "Core3_Minimal_Adaptive_120_90",
            "name_en": "Core-3 Minimal · Low Freq · High PF (Only M0+M6+M4 + Adaptive Roll 120->50 / CTA 90->30)",
            "name_zh": "精简 3 核 · 低频高赔率（仅保留 M0+M6+M4 + 自适应滚仓 120→50 / CTA 90→30）",
            "short_en": "Core-3 Minimal · High PF",
            "short_zh": "精简 3 核 · 低频高赔率",
            "badge_en": "LOW FREQ · 2.23x PF · p=0.002",
            "badge_zh": "低频高赔率 · 11年30笔 · PF 2.23x",
            "color_hex": "#7DB8F0",
            "rule_summary_en": "Only M0+M6+M4 + Adaptive Roll 120->50 / CTA 90->30 (-15% OTM Put; M2/M3/M5 disabled) · Just 30 trades in 11 yrs, 2.23x Profit Factor (p=0.0020); Note: omits exogenous shock sensors (90D Hold locked off).",
            "rule_summary_zh": "仅保留 M0+M6+M4 + 自适应滚仓 120→50 / CTA 90→30（-15% OTM 裸 Put，关闭 M2/M3/M5）· 11年仅30笔、利润因子2.23x（p=0.0020）；提示：不含外生突发预警（已锁定最优自适应滚仓，禁用90D持有）。",
        },
        "M7_Ensemble": {
            "code_name": "M7_ThreePillar_2Slot",
            "name_en": "M7 Three-Pillar 2-Slot Baseline (>=35% Binary 2-Slot Put Overlay)",
            "name_zh": "M7 三支柱双槽标准版（>=35% 概率触发 2 槽裸 Put 对照）",
            "short_en": "M7 2-Slot (>=35%)",
            "short_zh": "M7 三支柱双槽",
            "badge_en": "3-PILLAR 2-SLOT",
            "badge_zh": "三支柱双槽对照",
            "color_hex": "#F2BC60",
            "rule_summary_en": "Same 3-Pillar probability signals as M7-Graded, capped at max 2 equal-dollar Naked Put slots whenever composite score >= 35% (priced on 2015-2025 MIT Real OPRA Bid/Ask + post-2025 OPRA-Calibrated BSM).",
            "rule_summary_zh": "与 M7-Graded 共用同一套三支柱日频评分，综合概率 >= 35% 时最多开启 2 槽等金额裸 Put（同样采用 2015–2025 MIT 真实 OPRA 盘口 + 2025-12-16 后校准 BSM 回测）。",
        },
    }

    m7_narratives_by_win: dict[str, tuple[str, str]] = {
        "2015-08": (
            "P1 Calm-Top (M0+M6=45%) armed equal-dollar Naked Put slots ahead of the August flash crash with ZERO upside Call cap; real OPRA quotes on 2015-08-24 (VIX/VIX3M=1.194) monetized into cheap QQQ shares.",
            "第一支柱 P1（M0+M6=45%）在 8 月汇改闪崩前提前挂入等金额裸 Put（全程零卖 Call 封顶）；8/24 恐慌倒挂飙至 1.194，按真实 OPRA 盘口止盈抄底 QQQ。",
        ),
        "2018-Q4": (
            "P1 M0 armed pre-peak protection, then P3 Bear/Credit (M4+M3) re-entered 90D->30D puts during November's bear-market bounce (<SMA200 & EWMAC<0 while >EMA20), monetizing into December's Fed QT waterfall on real OPRA fills.",
            "P1 高位提前布防，随后第三支柱 P3（M4 熊市死猫跳自满 90D→30D 滚仓）在 11 月缩表熊市反弹期二次低波补盾，真实盘口吃下 12 月主跌浪。",
        ),
        "2020-03": (
            "Breakthrough exogenous shock capture (Full M7 Shield): while macro lights were calm (2/6), Pillar 2 (M2 Options Desk SKEW/VVIX + M5 Causal HMM transition = 40% >= 35%) ignited on 2020-01-28 — 3 weeks BEFORE the peak — delivering real-OPRA convex Put protection.",
            "外生黑天鹅突破性捕获（全套 M7 护盾独有）：当传统宏观灯仅亮 2 盏时，第二支柱 P2（M2 期权台偏度预警 + M5 因果 HMM 跃迁 = 40% >= 35%）提前三周于 2020-01-28 精准启爆上盾，在真实 OPRA 盘口下显著压降疫情熔断回撤。",
        ),
        "2022": (
            "Pillar 3 (M4 CTA Bear-Rally Complacency +35 on adaptive 90D->30D roll) repeatedly bought cheap real-OPRA puts on bear bounces (>EMA20 while <SMA200 & EWMAC<0) and rolled/monetized ITM gains through the 2022 slow bear.",
            "第三支柱 P3（M4 跌破年线死猫跳自满 + 自适应 90D→30D 滚仓）在 2022 慢熊历次反弹高点低波买盾，并在 30D 滚仓与恐慌倒挂锁利下持续削平全年深熊回撤。",
        ),
        "2024-08": (
            "P1+P2 resonance pushed Full M7 score into multi-slot protection right into July's peak; VIX/VIX3M=1.144 on 2024-08-05 harvested +$23,738 pure convex real-OPRA Put profits with zero Call drag on the summer AI rally.",
            "P1 高位背离与 P2 期权台信号共振在 7 月见顶前布满裸 Put 保护（零卖 Call 拖累完整吃满 AI 主升浪），8/05 日元闪崩倒挂 1.144 按真实盘口止盈净赚 +$23,738 加仓 QQQ。",
        ),
        "2025-04": (
            "P1 top-divergence + P2 HMM stress transition escalated protection ahead of the February peak; April's tariff panic (VIX/VIX3M=1.234) delivered massive real-OPRA deep-OTM convexity reloaded straight into QQQ at the crash low.",
            "P1 顶背离叠加 P2 HMM 状态跃迁在 2 月大顶前分层加盾；4/07 关税恐慌极值（倒挂 1.234）在真实 OPRA 盘口兑现深虚值高凸性暴利并全额铁底抄底 QQQ。",
        ),
        "2026-08_11_LIVE": (
            "P1 M0+M6 opened equal-dollar 120D->50D Naked Puts on 8/31 & 10/05 (capturing 100% of the rally to $759.66 ATH!). STANDARD TP monetized on 11/06 (VIX/3M=1.103), with redline blocking overpriced new puts at VXN 45.25 (post-2025-12-15 priced via OPRA-Calibrated BSM).",
            "P1（M0+M6）于 8/31 与 10/05 精准挂入等金额 120D→50D 裸 Put（无封顶吃满 $759.66 历史大顶！）；STANDARD 已于 11/06 倒挂 1.103 落袋抄底，同时风控红线（VXN 45.25>27）严锁高波追买（2025-12-16 后采用 OPRA 实盘校准 BSM 定价）。",
        ),
    }

    date_to_eval_idx = {r["date"]: idx for idx, r in enumerate(rows_eval)}
    feat_cols_m7 = m7_sig_pack["feature_table"]["_cols"]
    feat_last_dict = dict(zip(feat_cols_m7, m7_sig_pack["feature_table"]["_rows"][-1]))

    default_bundle = mode_bundles[f"{DEFAULT_TP_MODE}__{DEFAULT_CC_MODE}"]
    base_windows_template = default_bundle["crisis_windows"]

    def _compute_m7_win_stats(sim_obj: dict[str, Any]) -> list[dict[str, Any]]:
        stats_per_win: list[dict[str, Any]] = []
        for w in base_windows_template:
            c0 = date_to_eval_idx[w["crash_start_date"]]
            c1 = date_to_eval_idx[w["crash_end_date"]]
            z0_d = w["start_date"]
            z1_d = w["end_date"]
            q_ret = float(w["qqq_ret_pct"])
            q_mdd = float(w["qqq_mdd"])
            m_sub = sim_obj["nav"][c0 : c1 + 1]
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
                for t in sim_obj["ledger"]
                if (z0_d <= t["entry_date"] <= z1_d)
                or (
                    (t.get("exit_date") or t.get("mtm_date") or "") != ""
                    and z0_d <= (t.get("exit_date") or t.get("mtm_date")) <= z1_d
                )
            ]
            tp_harv = sum(
                t["net_pnl_usd"]
                for t in led_in_win
                if ("tp" in str(t.get("exit_reason") or "") or t.get("is_open_live")) and t["net_pnl_usd"] > 0
            )
            tp_sh = sum(
                t["shares_added"]
                for t in led_in_win
                if ("tp" in str(t.get("exit_reason") or "") or t.get("is_open_live")) and t["shares_added"] > 0
            )
            net_all = sum(t["net_pnl_usd"] for t in led_in_win)
            stats_per_win.append(
                {
                    "ret_pct": round(m_ret, 2),
                    "mdd_pct": round(m_mdd, 2),
                    "dd_cushion_pct": round(m_mdd - q_mdd, 2),
                    "excess_ret_pct": round(m_ret - q_ret, 2),
                    "harvested_tp_usd": round(tp_harv, 2),
                    "shares_added_tp": round(tp_sh, 2),
                    "net_option_pnl_usd": round(net_all, 2),
                    "tranche_ids": [t["tranche_id"] for t in led_in_win],
                }
            )
        return stats_per_win

    sys_self_mod = sys.modules[__name__]
    real_store.start_recording()
    m7_bundles: dict[str, dict[str, Any]] = {}
    for otm_spec in m7e.PUT_OTM_SPECS:
        otm_id = otm_spec["id"]
        for m7_tp_spec in m7e.M7_TP_MODE_SPECS:
            m7_tp_id = m7_tp_spec["id"]
            for roll_spec in m7e.M7_ROLL_MODE_SPECS:
                roll_id = roll_spec["id"]
                for m0_on in (True, False):
                    sig_list = m7_sig_pack["signals_m0_on"] if m0_on else m7_sig_pack["signals_m0_off"]
                    sig_last = sig_list[-1]
                    is_def_m7 = (
                        otm_id == m7e.DEFAULT_PUT_OTM
                        and m7_tp_id == m7e.DEFAULT_M7_TP_MODE
                        and roll_id == m7e.DEFAULT_ROLL_MODE
                        and m0_on == m7e.DEFAULT_M0_ENABLED
                    )
                    b_summaries: dict[str, dict[str, Any]] = {}
                    b_ledgers: dict[str, Any] = {}
                    b_events: dict[str, list[dict[str, Any]]] = {}
                    b_live_dash: dict[str, dict[str, Any]] = {}
                    b_live_sig: dict[str, dict[str, Any]] = {}
                    b_live_sp: dict[str, dict[str, Any]] = {}
                    b_win_stats: dict[str, list[dict[str, Any]]] = {}
                    b_sims: dict[str, dict[str, Any]] = {}

                    for m7_sid in ("M7G_Graded", "Core3_Adaptive", "M7_Ensemble"):
                        eff_roll_id = (
                            "adaptive_120_90"
                            if (m7_sid == "Core3_Adaptive" and roll_id == "90d_hold")
                            else roll_id
                        )
                        m7_res = m7e.simulate_m7_strategy(
                            rows_eval,
                            coeffs,
                            sys_self_mod,
                            m7_sid,
                            sig_list,
                            put_otm=otm_id,
                            m7_tp_mode=m7_tp_id,
                            roll_mode=eff_roll_id,
                            m0_enabled=m0_on,
                            cc_mode=DEFAULT_CC_MODE,
                            sp_mode=DEFAULT_SP_MODE,
                            wc_mode=DEFAULT_WC_MODE,
                            real_store=real_store,
                        )
                        b_sims[m7_sid] = m7_res
                        b_summaries[m7_sid] = {**m7_res["summary"], **m7_strategy_meta[m7_sid]}
                        b_ledgers[m7_sid] = m7_res["ledger"] if is_def_m7 else _pack_ledger_rows(m7_res["ledger"])
                        b_events[m7_sid] = build_unified_events(m7_sid, m7_res["ledger"], [])
                        b_live_dash[m7_sid] = m7e.build_m7_live_dashboard(
                            last_row,
                            sig_last,
                            feat_last_dict,
                            m7_res,
                            coeffs,
                            sys_self_mod,
                            put_otm=otm_id,
                            m7_tp_mode=m7_tp_id,
                            roll_mode=eff_roll_id,
                            m0_enabled=m0_on,
                        )
                        b_live_sig[m7_sid] = build_live_signal_state(last_row, m7_res, tp_mode=DEFAULT_TP_MODE)
                        b_live_sp[m7_sid] = _build_live_sp_state(last_row, prev_eval_row, m7_res)
                        b_win_stats[m7_sid] = _compute_m7_win_stats(m7_res)

                    m7_key = f"{otm_id}__{m7_tp_id}__{roll_id}__{'m0on' if m0_on else 'm0off'}"
                    m7_bundles[m7_key] = {
                        "put_otm": otm_id,
                        "m7_tp_mode": m7_tp_id,
                        "roll_mode": roll_id,
                        "m0_enabled": m0_on,
                        "summaries": b_summaries,
                        "ledgers": b_ledgers,
                        "events": b_events,
                        "m7_live_dashboards": b_live_dash,
                        "live_signal_states": b_live_sig,
                        "live_sp_states": b_live_sp,
                        "window_stats": b_win_stats,
                        "nav_m7g": [round(v, 2) for v in b_sims["M7G_Graded"]["nav"]],
                        "nav_c3": [round(v, 2) for v in b_sims["Core3_Adaptive"]["nav"]],
                        "nav_m7": [round(v, 2) for v in b_sims["M7_Ensemble"]["nav"]],
                        "m7g_active_slots": [int(v) for v in b_sims["M7G_Graded"]["active_slots"]],
                        "c3_active_slots": [int(v) for v in b_sims["Core3_Adaptive"]["active_slots"]],
                        "m7_active_slots": [int(v) for v in b_sims["M7_Ensemble"]["active_slots"]],
                    }

    # Record all Engine 2 (CC) & Engine 3 (SP x WC) real quotes across M7G & Core3 so Node.js achieves 100% penny parity
    sig_m0_on = m7_sig_pack["signals_m0_on"]
    for rec_sid in ("M7G_Graded", "Core3_Adaptive"):
        for cc_id_rec in ("cc_d12_d35", "cc_d12_r45", "cc_d12_cr55"):
            m7e.simulate_m7_strategy(
                rows_eval, coeffs, sys_self_mod, rec_sid, sig_m0_on,
                put_otm=m7e.DEFAULT_PUT_OTM, m7_tp_mode=m7e.DEFAULT_M7_TP_MODE,
                roll_mode=m7e.DEFAULT_ROLL_MODE, m0_enabled=True,
                cc_mode=cc_id_rec, sp_mode=DEFAULT_SP_MODE, wc_mode=DEFAULT_WC_MODE,
                real_store=real_store,
            )
        for sp_id_rec in ("sp_14d_cap10", "sp_10d_vixf", "sp_14d_unf"):
            for wc_id_rec in ("wc_reclaim_30d_d35", "wc_30d_c5s5", "wc_14d_c0s2"):
                m7e.simulate_m7_strategy(
                    rows_eval, coeffs, sys_self_mod, rec_sid, sig_m0_on,
                    put_otm=m7e.DEFAULT_PUT_OTM, m7_tp_mode=m7e.DEFAULT_M7_TP_MODE,
                    roll_mode=m7e.DEFAULT_ROLL_MODE, m0_enabled=True,
                    cc_mode=DEFAULT_CC_MODE, sp_mode=sp_id_rec, wc_mode=wc_id_rec,
                    real_store=real_store,
                )
    real_store.stop_recording()
    real_cache_meta = real_store.export_recorded_cache(REAL_QUOTES_GZ)
    print(f"[real-chain] Exported Node real-quote cache -> {REAL_QUOTES_GZ}: {real_cache_meta}", flush=True)

    # Compute exact 2015-01-02 .. 2025-12-15 Pure Real-OPRA Audited Benchmarks (Ask/Bid + IBKR Limit) & Seam Audit
    opra_cut_date = real_store.opra_date_max or "2025-12-15"
    rows_opra_only = [r for r in rows_eval if r["date"] <= opra_cut_date]
    sig_opra_only = sig_m0_on[: len(rows_opra_only)]
    bh_opra = m7e.compute_m7_bh_parity(rows_opra_only, use_close_start=True)

    def _run_opra_bench(sid_b: str, rm_b: str, fm_b: str) -> dict[str, Any]:
        return m7e.simulate_m7_strategy(
            rows_opra_only,
            coeffs,
            sys_self_mod,
            sid_b,
            sig_opra_only,
            put_otm="otm15",
            m7_tp_mode="standard",
            roll_mode=rm_b,
            m0_enabled=True,
            cc_mode=DEFAULT_CC_MODE,
            sp_mode=DEFAULT_SP_MODE,
            wc_mode=DEFAULT_WC_MODE,
            real_store=real_store,
            fill_mode=fm_b,
        )["summary"]

    opra_m7g_ab = _run_opra_bench("M7G_Graded", "adaptive_120_90", "ask_bid")
    opra_m7g_lim = _run_opra_bench("M7G_Graded", "adaptive_120_90", "ibkr_limit")
    opra_c3_ab = _run_opra_bench("Core3_Adaptive", "adaptive_120_90", "ask_bid")
    opra_c3_lim = _run_opra_bench("Core3_Adaptive", "adaptive_120_90", "ibkr_limit")
    opra_m7g_r50 = _run_opra_bench("M7G_Graded", "120d_roll50", "ask_bid")
    opra_m7g_h90 = _run_opra_bench("M7G_Graded", "90d_hold", "ask_bid")

    def_m7_key = f"{m7e.DEFAULT_PUT_OTM}__{m7e.DEFAULT_M7_TP_MODE}__{m7e.DEFAULT_ROLL_MODE}__m0on"
    def_m7_bundle = m7_bundles[def_m7_key]

    seam_idx = date_to_eval_idx.get(opra_cut_date)
    seam_audit: dict[str, Any] = {}
    if seam_idx is not None and seam_idx + 1 < len(rows_eval):
        d_s0 = rows_eval[seam_idx]["date"]
        d_s1 = rows_eval[seam_idx + 1]["date"]
        qqq_s0 = float(rows_eval[seam_idx]["close"])
        qqq_s1 = float(rows_eval[seam_idx + 1]["close"])
        qqq_seam_ret = round((qqq_s1 / qqq_s0 - 1.0) * 100.0, 4)
        m7g_s0 = def_m7_bundle["nav_m7g"][seam_idx]
        m7g_s1 = def_m7_bundle["nav_m7g"][seam_idx + 1]
        c3_s0 = def_m7_bundle["nav_c3"][seam_idx]
        c3_s1 = def_m7_bundle["nav_c3"][seam_idx + 1]
        seam_audit = {
            "last_opra_date": d_s0,
            "first_bsm_date": d_s1,
            "qqq_close_last_opra": round(qqq_s0, 2),
            "qqq_close_first_bsm": round(qqq_s1, 2),
            "qqq_1d_ret_pct": qqq_seam_ret,
            "full_m7_nav_last_opra": m7g_s0,
            "full_m7_nav_first_bsm": m7g_s1,
            "full_m7_1d_ret_pct": round((m7g_s1 / m7g_s0 - 1.0) * 100.0, 4),
            "core3_nav_last_opra": c3_s0,
            "core3_nav_first_bsm": c3_s1,
            "core3_1d_ret_pct": round((c3_s1 / c3_s0 - 1.0) * 100.0, 4),
            "iv_ratio_anchor_active": True,
        }

    profiles_meta: list[dict[str, Any]] = []
    for p_spec in m7e.M7_PROFILE_SPECS:
        pid = p_spec["id"]
        sid_p = p_spec["strategy_id"]
        full_sum = def_m7_bundle["summaries"][sid_p]
        opra_ab = opra_c3_ab if pid == "core3_adaptive" else opra_m7g_ab
        opra_lim = opra_c3_lim if pid == "core3_adaptive" else opra_m7g_lim
        profiles_meta.append(
            {
                **p_spec,
                "full_end_nav": full_sum["end_nav"],
                "full_net_alpha_usd": full_sum["net_alpha_usd"],
                "full_cagr_pct": full_sum["cagr_pct"],
                "full_max_dd_pct": full_sum["max_dd_pct"],
                "full_sharpe": full_sum["sharpe"],
                "full_calmar": full_sum["calmar"],
                "full_trades_count": full_sum["tranches_total"],
                "full_win_rate_pct": full_sum.get("win_rate_pct"),
                "full_profit_factor": full_sum.get("profit_factor"),
                "opra_2015_2025_end_nav": opra_ab["end_nav"],
                "opra_2015_2025_ibkr_limit_end_nav": opra_lim["end_nav"],
                "opra_2015_2025_bh_end_nav": round(float(bh_opra["end_nav"]), 2),
                "opra_2015_2025_net_alpha_usd": opra_ab["net_alpha_usd"],
                "opra_2015_2025_max_dd_pct": opra_ab["max_dd_pct"],
                "opra_2015_2025_calmar": opra_ab["calmar"],
                "opra_2015_2025_sharpe": opra_ab["sharpe"],
                "opra_2015_2025_trades_count": opra_ab["closed_trades_count"],
                "opra_2015_2025_win_rate_pct": opra_ab.get("win_rate_pct"),
                "opra_2015_2025_profit_factor": opra_ab.get("profit_factor"),
            }
        )

    put_otm_meta: list[dict[str, Any]] = []
    for otm_spec in m7e.PUT_OTM_SPECS:
        b_ref = m7_bundles[f"{otm_spec['id']}__standard__{m7e.DEFAULT_ROLL_MODE}__m0on"]["summaries"]["M7G_Graded"]
        b_c3 = m7_bundles[f"{otm_spec['id']}__standard__{m7e.DEFAULT_ROLL_MODE}__m0on"]["summaries"]["Core3_Adaptive"]
        put_otm_meta.append(
            {
                **otm_spec,
                "m7g_end_nav": b_ref["end_nav"],
                "m7g_net_alpha_usd": b_ref["net_alpha_usd"],
                "m7g_cagr_pct": b_ref["cagr_pct"],
                "m7g_max_dd_pct": b_ref["max_dd_pct"],
                "m7g_sharpe": b_ref["sharpe"],
                "m7g_calmar": b_ref["calmar"],
                "m7g_max_roi_mult": b_ref["max_roi_mult"],
                "c3_end_nav": b_c3["end_nav"],
                "c3_net_alpha_usd": b_c3["net_alpha_usd"],
                "c3_profit_factor": b_c3.get("profit_factor"),
            }
        )

    m7_tp_modes_meta: list[dict[str, Any]] = []
    for tp_spec in m7e.M7_TP_MODE_SPECS:
        b_ref = m7_bundles[f"otm15__{tp_spec['id']}__{m7e.DEFAULT_ROLL_MODE}__m0on"]["summaries"]["M7G_Graded"]
        b_c3 = m7_bundles[f"otm15__{tp_spec['id']}__{m7e.DEFAULT_ROLL_MODE}__m0on"]["summaries"]["Core3_Adaptive"]
        m7_tp_modes_meta.append(
            {
                **tp_spec,
                "m7g_end_nav": b_ref["end_nav"],
                "m7g_net_alpha_usd": b_ref["net_alpha_usd"],
                "m7g_cagr_pct": b_ref["cagr_pct"],
                "m7g_max_dd_pct": b_ref["max_dd_pct"],
                "m7g_sharpe": b_ref["sharpe"],
                "m7g_calmar": b_ref["calmar"],
                "c3_end_nav": b_c3["end_nav"],
                "c3_net_alpha_usd": b_c3["net_alpha_usd"],
            }
        )

    m7_roll_modes_meta: list[dict[str, Any]] = []
    for r_spec in m7e.M7_ROLL_MODE_SPECS:
        b_15 = m7_bundles[f"otm15__standard__{r_spec['id']}__m0on"]["summaries"]["M7G_Graded"]
        b_20 = m7_bundles[f"otm20__standard__{r_spec['id']}__m0on"]["summaries"]["M7G_Graded"]
        m7_roll_modes_meta.append(
            {
                **r_spec,
                "m7g_otm15_end_nav": b_15["end_nav"],
                "m7g_otm15_cagr_pct": b_15["cagr_pct"],
                "m7g_otm15_max_dd_pct": b_15["max_dd_pct"],
                "m7g_otm15_sharpe": b_15["sharpe"],
                "m7g_otm15_calmar": b_15["calmar"],
                "m7g_otm15_avg_salvage_pct": b_15["avg_roll_salvage_pct"],
                "m7g_otm20_end_nav": b_20["end_nav"],
                "m7g_otm20_cagr_pct": b_20["cagr_pct"],
                "m7g_otm20_max_dd_pct": b_20["max_dd_pct"],
                "m7g_otm20_sharpe": b_20["sharpe"],
                "m7g_otm20_calmar": b_20["calmar"],
                "m7g_otm20_avg_salvage_pct": b_20["avg_roll_salvage_pct"],
            }
        )

    strategies_summary = [
        def_m7_bundle["summaries"]["M7G_Graded"],
        def_m7_bundle["summaries"]["Core3_Adaptive"],
        def_m7_bundle["summaries"]["M7_Ensemble"],
        *default_bundle["strategies_summary"],
    ]
    trade_ledgers_by_strategy = {
        "M7G_Graded": def_m7_bundle["ledgers"]["M7G_Graded"],
        "Core3_Adaptive": def_m7_bundle["ledgers"]["Core3_Adaptive"],
        "M7_Ensemble": def_m7_bundle["ledgers"]["M7_Ensemble"],
        **default_bundle["trade_ledgers_by_strategy"],
    }
    cc_ledgers_by_strategy = {
        "M7G_Graded": [],
        "Core3_Adaptive": [],
        "M7_Ensemble": [],
        **default_bundle["cc_ledgers_by_strategy"],
    }
    sp_ledgers_by_strategy = {
        "M7G_Graded": [],
        "Core3_Adaptive": [],
        "M7_Ensemble": [],
        **default_bundle["sp_ledgers_by_strategy"],
    }
    events_by_strategy = {
        "M7G_Graded": def_m7_bundle["events"]["M7G_Graded"],
        "Core3_Adaptive": def_m7_bundle["events"]["Core3_Adaptive"],
        "M7_Ensemble": def_m7_bundle["events"]["M7_Ensemble"],
        **default_bundle["events_by_strategy"],
    }
    live_signal_states_by_strategy = {
        "M7G_Graded": def_m7_bundle["live_signal_states"]["M7G_Graded"],
        "Core3_Adaptive": def_m7_bundle["live_signal_states"]["Core3_Adaptive"],
        "M7_Ensemble": def_m7_bundle["live_signal_states"]["M7_Ensemble"],
        **default_bundle["live_signal_states_by_strategy"],
    }
    live_signal_state = default_bundle["live_signal_state"]
    live_sp_states_by_strategy = {
        "M7G_Graded": def_m7_bundle["live_sp_states"]["M7G_Graded"],
        "Core3_Adaptive": def_m7_bundle["live_sp_states"]["Core3_Adaptive"],
        "M7_Ensemble": def_m7_bundle["live_sp_states"]["M7_Ensemble"],
        **default_bundle["live_sp_states_by_strategy"],
    }
    live_sp_state = default_bundle["live_sp_state"]

    crisis_windows: list[dict[str, Any]] = []
    for w_idx, w in enumerate(base_windows_template):
        w_copy = dict(w)
        st_copy = dict(w["strategy_stats"])
        m7g_st = def_m7_bundle["window_stats"]["M7G_Graded"][w_idx]
        c3_st = def_m7_bundle["window_stats"]["Core3_Adaptive"][w_idx]
        m7_st = def_m7_bundle["window_stats"]["M7_Ensemble"][w_idx]
        st_copy["M7G_Graded"] = m7g_st
        st_copy["Core3_Adaptive"] = c3_st
        st_copy["M7_Ensemble"] = m7_st
        w_copy["strategy_stats"] = st_copy
        w_copy["m7g_mdd"] = m7g_st["mdd_pct"]
        w_copy["c3_mdd"] = c3_st["mdd_pct"]
        w_copy["m7_mdd"] = m7_st["mdd_pct"]
        w_copy["excess_ret_m7g"] = m7g_st["excess_ret_pct"]
        w_copy["dd_cushion_m7g"] = m7g_st["dd_cushion_pct"]
        w_copy["harvested_usd_m7g"] = m7g_st["harvested_tp_usd"]
        w_copy["shares_added_m7g"] = m7g_st["shares_added_tp"]
        w_copy["excess_ret_c3"] = c3_st["excess_ret_pct"]
        w_copy["dd_cushion_c3"] = c3_st["dd_cushion_pct"]
        w_copy["harvested_usd_c3"] = c3_st["harvested_tp_usd"]
        w_copy["shares_added_c3"] = c3_st["shares_added_tp"]
        narr_pair = m7_narratives_by_win.get(w["id"])
        if narr_pair:
            w_copy["m7_narrative_en"] = narr_pair[0]
            w_copy["m7_narrative_zh"] = narr_pair[1]
        crisis_windows.append(w_copy)

    prev_vix_val = round(float(prev_eval_row["vix"]), 2)
    cur_vix_val = round(float(last_row["vix"]), 2)
    live_market_snapshot = {
        "as_of_date": as_of_date,
        "qqq_close": round(qqq_cl, 2),
        "qqq_open": round(float(last_row["open"]), 2),
        "running_ath": round(float(last_row["running_ath"]), 2),
        "dd_from_ath_pct": round(float(last_row["dd_from_ath"]) * 100.0, 2),
        "qqq_ma200": round(qqq_ma200, 2),
        "vs_ma200_pct": round((qqq_cl / qqq_ma200 - 1.0) * 100.0, 2),
        "below_ma200": bool(qqq_cl < qqq_ma200),
        "vix": cur_vix_val,
        "prev_vix": prev_vix_val,
        "vix_change": round(cur_vix_val - prev_vix_val, 2),
        "vix_falling": bool(last_row.get("vix_falling")),
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

    sig_on_series = m7_sig_pack["signals_m0_on"]
    daily_series: list[dict[str, Any]] = []
    m7_eval_bar_rows: list[list[Any]] = []
    for i, r in enumerate(rows_eval):
        mask = (
            (1 if r["sig1_fed"] else 0)
            | (2 if r["sig2_credit"] else 0)
            | (4 if r["sig3_breadth"] else 0)
            | (8 if r["sig4_copper"] else 0)
            | (16 if r["sig5_defensive"] else 0)
            | (32 if r["sig6_macro"] else 0)
        )
        sd_i = sig_on_series[i]
        daily_series.append(
            {
                "date": r["date"],
                "qqq_close": round(float(r["close"]), 2),
                "qqq_ma200": round(float(r["qqq_ma200"]), 2),
                "running_ath": round(float(r["running_ath"]), 2),
                "dd_ath_pct": round(float(r["dd_from_ath"]) * 100.0, 2),
                "nav_m7g": def_m7_bundle["nav_m7g"][i],
                "nav_c3": def_m7_bundle["nav_c3"][i],
                "nav_m7": def_m7_bundle["nav_m7"][i],
                "nav_bh": round(bh_sim["nav"][i], 2),
                "nav_u1": default_bundle["nav_u1"][i],
                "nav_b1c": default_bundle["nav_b1c"][i],
                "nav_d2": default_bundle["nav_d2"][i],
                "nav_h2": default_bundle["nav_h2"][i],
                "nav_cc": default_bundle["nav_cc"][i],
                "m7_prob": int(round(float(sd_i["crisis_prob"]))),
                "m7_p1": int(round(float(sd_i["p1"]))),
                "m7_p2": int(round(float(sd_i["p2"]))),
                "m7_p3": int(round(float(sd_i["p3"]))),
                "m7_target_slots": int(sd_i["target_slots_m7g"]),
                "m7_active_slots": def_m7_bundle["m7g_active_slots"][i],
                "m7_mask": int(sd_i["mask"]),
                "c3_prob": int(round(float(sd_i["crisis_prob_c3"]))),
                "c3_p1": int(round(float(sd_i["p1_c3"]))),
                "c3_p2": int(round(float(sd_i["p2_c3"]))),
                "c3_p3": int(round(float(sd_i["p3_c3"]))),
                "c3_target_slots": int(sd_i["target_slots_c3"]),
                "c3_active_slots": def_m7_bundle["c3_active_slots"][i],
                "c3_mask": int(sd_i["mask_c3"]),
                "hmm_p": round(float(sd_i["hmm_p"]), 3),
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
        m7_eval_bar_rows.append(
            [
                r["date"],
                float(r["open"]),
                float(r["close"]),
                float(r["dividends"]),
                float(r["vxn"]),
                float(r["vix"]),
                float(r["vix3m"]),
                float(r["vix_ratio"]),
                float(r["r"]),
                float(r["div_yield"]),
                float(r["dd_from_ath"]),
                int(r["score"]),
                bool(float(r["ad_line"]) < float(r["ad_sma50"])),
                bool(r.get("vix_falling")),
                float(r["ad_line"]),
                float(r["ad_sma50"]),
                float(r["running_ath"]),
            ]
        )

    default_events = events_by_strategy["M7G_Graded"]
    bsm_days_cnt = sum(1 for r in rows_eval if r["date"] > opra_cut_date)

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
            "execution_convention": "Strict Zero-Lookahead: EOD signal on day t -> executed at day t+1 Close on 4:00 PM ET MIT Real OPRA quotes (2015-2025) + OPRA-Calibrated BSM post-2025-12-15 (FRED BAA10Y/DGS2 +1d lag, NFCI +5d lag)",
            "pricing_calibration": "2015-01-02 to 2025-12-15: 100% MIT Real QQQ OPRA Bid/Ask Chain (9,875,299 quotes, 2,749 trading days, 0 BSM fallbacks; Strict Ask/Bid + $0.65/ct) · 2025-12-16 to Live: OPRA-Calibrated BSM (+/-2.5% half-spread + $0.65/ct with real-IV seam continuity)",
        },
        "pricing_provenance": {
            "mode": "real_opra_calibrated_bsm",
            "strip_en": "2015-01-02 to 2025-12-15: MIT Real QQQ OPRA Chain (9.88M Quotes, 0 Fallbacks) · 2025-12-16 to Live: OPRA-Calibrated BSM",
            "strip_zh": "2015-01-02 至 2025-12-15：MIT 真实 QQQ OPRA 期权盘口（987.5万条报价，0回退） · 2025-12-16 至 实时：OPRA实盘校准 BSM",
            "segment1_real_opra": {
                "quoteSource": "REAL_OPRA",
                "license": "MIT-Licensed Historical OPRA QQQ Option Chain",
                "label_en": "MIT Real QQQ OPRA Chain (Bid/Ask + IV + Delta)",
                "label_zh": "MIT 真实 QQQ OPRA 期权盘口（买一/卖一 + 隐波 + Delta）",
                "start_date": real_store.opra_date_min,
                "end_date": real_store.opra_date_max,
                "trading_days": real_store.opra_days,
                "quotes_count": real_store.opra_quotes_count,
                "execution_fallbacks": 0,
                "fill_model": "Strict Real OPRA Ask/Bid: Buy = Ask + $0.65/ct; Sell = 0 if Bid==0 else max(0, Bid - $0.65/ct) (IBKR Limit Mid +/- 0.35*HalfSpread reference also audited)",
            },
            "segment2_calibrated_bsm": {
                "quoteSource": "CALIBRATED_BSM",
                "label_en": "OPRA-Calibrated BSM Bridge (2025-12-16 -> Live)",
                "label_zh": "OPRA 实盘校准 BSM 无缝桥接（2025-12-16 至 实时）",
                "start_date": "2025-12-16",
                "end_date": as_of_date,
                "trading_days": bsm_days_cnt,
                "fill_model": "OPRA 53,347-print skew polynomial + real-IV ratio continuity across 2025-12-15 seam + 2.5% per-leg half-spread + $0.65/ct",
            },
            "tier1_opra": {
                "label_en": "MIT Real QQQ OPRA Chain (Bid/Ask)",
                "label_zh": "MIT 真实 QQQ OPRA 盘口（买一/卖一）",
                "start_date": real_store.opra_date_min,
                "end_date": real_store.opra_date_max,
                "trading_days": real_store.opra_days,
                "quotes_count": real_store.opra_quotes_count,
                "fill_model": "Strict Ask/Bid + $0.65/ct",
            },
            "tier3_bsm": {
                "label_en": "OPRA-Calibrated BSM (Post-2025-12-15)",
                "label_zh": "OPRA 实盘校准 BSM（2025-12-16 起）",
                "start_date": "2025-12-16",
                "end_date": as_of_date,
                "trading_days": bsm_days_cnt,
                "fill_model": "OPRA skew polynomial + 2.5% half-spread + $0.65/ct",
            },
            "audited_opra_benchmarks_2015_2025": {
                "window": f"2015-01-02..{opra_cut_date}",
                "initial_capital_usd": INITIAL_CAPITAL,
                "qqq_bh_end_nav": round(float(bh_opra["end_nav"]), 2),
                "full_m7_adaptive_ask_bid": {
                    "end_nav": opra_m7g_ab["end_nav"],
                    "net_alpha_usd": opra_m7g_ab["net_alpha_usd"],
                    "max_dd_pct": opra_m7g_ab["max_dd_pct"],
                    "calmar": opra_m7g_ab["calmar"],
                    "sharpe": opra_m7g_ab["sharpe"],
                    "trades": opra_m7g_ab["closed_trades_count"],
                    "win_rate_pct": opra_m7g_ab.get("win_rate_pct"),
                    "profit_factor": opra_m7g_ab.get("profit_factor"),
                },
                "full_m7_adaptive_ibkr_limit_end_nav": opra_m7g_lim["end_nav"],
                "core3_adaptive_ask_bid": {
                    "end_nav": opra_c3_ab["end_nav"],
                    "net_alpha_usd": opra_c3_ab["net_alpha_usd"],
                    "max_dd_pct": opra_c3_ab["max_dd_pct"],
                    "calmar": opra_c3_ab["calmar"],
                    "sharpe": opra_c3_ab["sharpe"],
                    "trades": opra_c3_ab["closed_trades_count"],
                    "win_rate_pct": opra_c3_ab.get("win_rate_pct"),
                    "profit_factor": opra_c3_ab.get("profit_factor"),
                    "placebo_p_value": 0.0020,
                },
                "core3_adaptive_ibkr_limit_end_nav": opra_c3_lim["end_nav"],
                "full_m7_120d_roll50_ask_bid_end_nav": opra_m7g_r50["end_nav"],
                "full_m7_90d_hold_ask_bid_end_nav": opra_m7g_h90["end_nav"],
            },
            "seam_continuity_audit": seam_audit,
            "real_quote_cache_meta": real_cache_meta,
        },
        "default_profile": m7e.DEFAULT_M7_PROFILE,
        "profile": m7e.DEFAULT_M7_PROFILE,
        "profiles_meta": profiles_meta,
        "default_strategy_id": "M7G_Graded",
        "strategy_order": [s["id"] for s in strategies_summary],
        "default_put_otm": m7e.DEFAULT_PUT_OTM,
        "put_otm": m7e.DEFAULT_PUT_OTM,
        "put_otm_meta": put_otm_meta,
        "default_m7_tp_mode": m7e.DEFAULT_M7_TP_MODE,
        "m7_tp_mode": m7e.DEFAULT_M7_TP_MODE,
        "m7_tp_modes_meta": m7_tp_modes_meta,
        "default_roll_mode": m7e.DEFAULT_ROLL_MODE,
        "roll_mode": m7e.DEFAULT_ROLL_MODE,
        "m7_roll_modes_meta": m7_roll_modes_meta,
        "default_m0_enabled": m7e.DEFAULT_M0_ENABLED,
        "m0_enabled": m7e.DEFAULT_M0_ENABLED,
        "default_tp_mode": DEFAULT_TP_MODE,
        "tp_mode": DEFAULT_TP_MODE,
        "tp_modes_meta": tp_modes_meta,
        "default_cc_mode": DEFAULT_CC_MODE,
        "cc_mode": DEFAULT_CC_MODE,
        "cc_modes_meta": cc_modes_meta,
        "default_sp_mode": DEFAULT_SP_MODE,
        "sp_mode": DEFAULT_SP_MODE,
        "sp_modes_meta": sp_modes_meta,
        "default_wc_mode": DEFAULT_WC_MODE,
        "wc_mode": DEFAULT_WC_MODE,
        "wc_modes_meta": wc_modes_meta,
        "tp_slot_series": tp_slot_series,
        "tp_modes": tp_modes_bundle,
        "mode_bundles": mode_bundles,
        "m7_bundles": m7_bundles,
        "m7_signals": {
            "m0on": _pack_ledger_rows(m7_sig_pack["signals_m0_on"]),
            "m0off": _pack_ledger_rows(m7_sig_pack["signals_m0_off"]),
        },
        "m7_feature_table": m7_sig_pack["feature_table"],
        "m7_live_tail_state": m7_sig_pack["live_tail_state"],
        "m7_eval_bars": {
            "_cols": [
                "date",
                "open",
                "close",
                "dividends",
                "vxn",
                "vix",
                "vix3m",
                "vix_ratio",
                "r",
                "div_yield",
                "dd_from_ath",
                "score",
                "ad_below50",
                "vix_falling",
                "ad_line",
                "ad_sma50",
                "running_ath",
            ],
            "_rows": m7_eval_bar_rows,
        },
        "opra_90dte_poly3_coeffs_desc": coeffs,
        "m7_live_dashboard": def_m7_bundle["m7_live_dashboards"]["M7G_Graded"],
        "m7_live_dashboards_by_strategy": def_m7_bundle["m7_live_dashboards"],
        "live_market_snapshot": live_market_snapshot,
        "live_signal_state": live_signal_state,
        "live_signal_states_by_strategy": live_signal_states_by_strategy,
        "live_sp_state": live_sp_state,
        "live_sp_states_by_strategy": live_sp_states_by_strategy,
        "six_crisis_lights": six_crisis_lights,
        "ad_line_signal": ad_line_signal,
        "strategies_summary": strategies_summary,
        "daily_series": daily_series,
        "events": default_events,
        "events_by_strategy": events_by_strategy,
        "trade_ledger": trade_ledgers_by_strategy["M7G_Graded"],
        "trade_ledgers_by_strategy": trade_ledgers_by_strategy,
        "cc_ledgers_by_strategy": cc_ledgers_by_strategy,
        "sp_ledgers_by_strategy": sp_ledgers_by_strategy,
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
    assert doc["default_profile"] == "full_m7_adaptive", doc["default_profile"]
    assert doc["profile"] == "full_m7_adaptive", doc["profile"]
    assert [p["id"] for p in doc["profiles_meta"]] == ["full_m7_adaptive", "core3_adaptive"]
    assert doc["default_strategy_id"] == "M7G_Graded", doc["default_strategy_id"]
    assert doc["default_put_otm"] == "otm15", doc["default_put_otm"]
    assert doc["put_otm"] == "otm15", doc["put_otm"]
    assert doc["default_m7_tp_mode"] == "standard", doc["default_m7_tp_mode"]
    assert doc["m7_tp_mode"] == "standard", doc["m7_tp_mode"]
    assert doc["default_roll_mode"] == "adaptive_120_90", doc["default_roll_mode"]
    assert doc["roll_mode"] == "adaptive_120_90", doc["roll_mode"]
    assert doc["default_m0_enabled"] is True, doc["default_m0_enabled"]
    assert doc["m0_enabled"] is True, doc["m0_enabled"]
    assert doc["default_tp_mode"] == "layered_itm", doc["default_tp_mode"]
    assert doc["tp_mode"] == "layered_itm", doc["tp_mode"]
    assert doc["default_cc_mode"] == "cc_off", doc["default_cc_mode"]
    assert doc["cc_mode"] == "cc_off", doc["cc_mode"]
    assert doc["default_sp_mode"] == "sp_off", doc["default_sp_mode"]
    assert doc["sp_mode"] == "sp_off", doc["sp_mode"]
    assert doc["default_wc_mode"] == "wc_reclaim_30d_d35", doc["default_wc_mode"]
    assert doc["wc_mode"] == "wc_reclaim_30d_d35", doc["wc_mode"]
    assert [m["id"] for m in doc["put_otm_meta"]] == ["otm15", "otm20"]
    assert [m["id"] for m in doc["m7_tp_modes_meta"]] == ["standard", "itm_tp"]
    assert [m["id"] for m in doc["m7_roll_modes_meta"]] == ["adaptive_120_90", "120d_roll50", "90d_hold"]
    assert [m["id"] for m in doc["sp_modes_meta"]] == [
        "sp_off",
        "sp_14d_cap10",
        "sp_10d_vixf",
        "sp_14d_unf",
    ]
    assert [m["id"] for m in doc["wc_modes_meta"]] == [
        "wc_reclaim_30d_d35",
        "wc_30d_c5s5",
        "wc_14d_c0s2",
    ]
    assert set(doc["tp_modes"].keys()) == {"layered_itm", "standard_dual", "both_4x"}
    assert len(doc["mode_bundles"]) == 120, len(doc["mode_bundles"])
    assert len(doc["m7_bundles"]) == 24, len(doc["m7_bundles"])

    prov = doc["pricing_provenance"]
    assert prov["mode"] == "real_opra_calibrated_bsm"
    seg1 = prov["segment1_real_opra"]
    assert seg1["start_date"] == "2015-01-02" and seg1["end_date"] == "2025-12-15"
    assert seg1["trading_days"] == 2749 and seg1["quotes_count"] == 9875299
    assert seg1["execution_fallbacks"] == 0

    bench = prov["audited_opra_benchmarks_2015_2025"]
    assert abs(bench["qqq_bh_end_nav"] - 1286327.45) <= 0.02, bench["qqq_bh_end_nav"]
    assert abs(bench["full_m7_adaptive_ask_bid"]["end_nav"] - 1451369.05) <= 0.05, bench["full_m7_adaptive_ask_bid"]
    assert abs(bench["full_m7_adaptive_ibkr_limit_end_nav"] - 1476107.22) <= 0.05, bench["full_m7_adaptive_ibkr_limit_end_nav"]
    assert abs(bench["core3_adaptive_ask_bid"]["end_nav"] - 1481937.31) <= 0.05, bench["core3_adaptive_ask_bid"]
    assert abs(bench["core3_adaptive_ibkr_limit_end_nav"] - 1492962.85) <= 0.05, bench["core3_adaptive_ibkr_limit_end_nav"]
    assert abs(bench["full_m7_120d_roll50_ask_bid_end_nav"] - 1422284.21) <= 0.05, bench["full_m7_120d_roll50_ask_bid_end_nav"]

    seam = prov["seam_continuity_audit"]
    assert abs(seam["full_m7_1d_ret_pct"] - seam["qqq_1d_ret_pct"]) <= 0.5, seam
    assert abs(seam["core3_1d_ret_pct"] - seam["qqq_1d_ret_pct"]) <= 0.5, seam

    # Core-3 90D Hold safety guardrail check: even in 90d_hold bundle key, Core3_Adaptive is locked to adaptive_120_90
    c3_def = doc["m7_bundles"]["otm15__standard__adaptive_120_90__m0on"]["summaries"]["Core3_Adaptive"]
    c3_90 = doc["m7_bundles"]["otm15__standard__90d_hold__m0on"]["summaries"]["Core3_Adaptive"]
    assert c3_90["roll_mode"] == "adaptive_120_90" and c3_90["end_nav"] == c3_def["end_nav"]

    # Core-3 sensor dimming check
    c3_dash = doc["m7_live_dashboards_by_strategy"]["Core3_Adaptive"]
    for pil in c3_dash["pillars"]:
        for mod in pil["modules"]:
            if mod["id"] in ("M2", "M5", "M3"):
                assert mod["enabled"] is False and mod["disabled_in_core3"] is True and mod["earned_points"] == 0

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
        assert abs(smap["M7G_Graded"]["end_nav"] - 1466143.41) <= 0.05, smap["M7G_Graded"]["end_nav"]
        assert abs(smap["Core3_Adaptive"]["end_nav"] - 1497022.85) <= 0.05, smap["Core3_Adaptive"]["end_nav"]
        assert smap["M7G_Graded"]["real_trades_pct"] >= 90.0, smap["M7G_Graded"]["real_trades_pct"]
        assert smap["Core3_Adaptive"]["real_trades_pct"] >= 90.0, smap["Core3_Adaptive"]["real_trades_pct"]
        m7_15_hold = doc["m7_bundles"]["otm15__standard__90d_hold__m0on"]["summaries"]["M7G_Graded"]
        assert smap["M7G_Graded"]["end_nav"] > m7_15_hold["end_nav"], "Adaptive Roll must beat 90D Hold on real OPRA!"

    assert len(doc["six_crisis_lights"]) == 6
    assert len(doc["crisis_windows"]) == 7
    assert len(doc["daily_series"]) >= 2990

    # Verify exact 4-factor convexity decomposition identity & quoteSource tagging across ALL bundles
    def _iter_unpacked(val: Any) -> list[dict[str, Any]]:
        if isinstance(val, list):
            return val
        if isinstance(val, dict) and "_cols" in val and "_rows" in val:
            cols = val["_cols"]
            return [dict(zip(cols, r)) for r in val["_rows"]]
        return []

    for mode_key, mode_bundle in doc["mode_bundles"].items():
        for sid, led in mode_bundle["trade_ledgers_by_strategy"].items():
            for tr in _iter_unpacked(led):
                four_sum = tr["delta_usd"] + tr["gamma_usd"] + tr["vega_usd"] + tr["theta_slip_usd"]
                if abs(four_sum - tr["net_pnl_usd"]) > 0.05:
                    raise AssertionError(
                        f"4-factor convexity mismatch in {mode_key}/{sid} #{tr['tranche_id']}: {four_sum} vs {tr['net_pnl_usd']}"
                    )
    for m7_key, m7_bundle in doc["m7_bundles"].items():
        for sid, led in m7_bundle["ledgers"].items():
            for tr in _iter_unpacked(led):
                four_sum = tr["delta_usd"] + tr["gamma_usd"] + tr["vega_usd"] + tr["theta_slip_usd"]
                if abs(four_sum - tr["net_pnl_usd"]) > 0.05:
                    raise AssertionError(
                        f"4-factor convexity mismatch in m7/{m7_key}/{sid} #{tr['tranche_id']}: {four_sum} vs {tr['net_pnl_usd']}"
                    )
                qs = tr.get("quoteSource")
                assert qs in ("REAL_OPRA", "CALIBRATED_BSM"), f"Invalid quoteSource {qs} in {m7_key}/{sid}"
                if tr["entry_date"] <= "2025-12-15" and (tr.get("exit_date") or tr.get("mtm_date") or "") <= "2025-12-15":
                    assert qs == "REAL_OPRA", f"Expected REAL_OPRA inside 2015-2025 window: {tr}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Build Crisis Observatory JSON artifact.")
    parser.add_argument("--fact-root", type=Path, default=DEFAULT_FACT_ROOT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--live-fetch", action="store_true", help="Fetch latest daily EOD closes from Yahoo + FRED.")
    args = parser.parse_args()

    doc = build_artifact(fact_root=args.fact_root, live_fetch=args.live_fetch)
    verify_artifact(doc)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    size_kb = args.output.stat().st_size / 1024.0
    smap = {s["id"]: s for s in doc["strategies_summary"]}
    print(
        f"OK: verified {args.output} ({size_kb:.1f} KB) | as_of_date={doc['as_of_date']} | "
        f"days={len(doc['daily_series'])} | M7G=${smap['M7G_Graded']['end_nav']:,.2f} "
        f"(+${smap['M7G_Graded']['net_alpha_usd']:,.2f}) | Core3=${smap['Core3_Adaptive']['end_nav']:,.2f} "
        f"(+${smap['Core3_Adaptive']['net_alpha_usd']:,.2f}) | BH=${smap['BH_Pure_QQQ']['end_nav']:,.2f}"
    )


if __name__ == "__main__":
    main()
