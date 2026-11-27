#!/usr/bin/env python3
"""Build canonical ThesisForge Crisis Observatory v3.0 Double-Champion (Plan D) artifact.

Exact Locked Plan D Strategy ("Double-Champion · Full-Blooded Taleb Core + User Improved Dual-CTA CONT_2M + +8% Slow-Bear Latch M4 -15% OTM"):
  1. Core Base & Borrowed Dual-CTA Overlay (NO Daily 1.20x Forced Deleveraging Cap):
     - 100% QQQ Core (with B020_M125 Put Engine) + 10% DBMF + 10% KMLM (20% SPX Short Box financing at NY Fed EFFR + 35 bps;
       stress comparison: IBKR Pro Margin at EFFR + 150 bps + Full Ask/Bid).
     - NO daily 1.20x forced drawdown deleveraging cap: natural gross leverage drifts up to approx 1.26x
       during crashes so QQQ is NEVER liquidated at crash bottoms. Quarterly calm calibration restores 1.200x.
  2. Put Engine (`B020_M125` + User's `+8%` Slow-Bear Hysteresis Latch `M4_latch_v2` — UNIFORM -15% OTM):
     - Baseline Floor (Book B, 0.20% NAV): Entry when VIX <= 20.0 AND VIX/VIX3M < 1.02 AND not in 5D Lockout.
       Contract: 125 DTE (95-160D), -15% OTM (K = 0.85 * S). Hard 75D roll/salvage.
     - Crisis Graded Ladder (Book M, `M7G_tier_45_65`, 1-3 Slots x 1.25% NAV = up to 3.75% NAV):
       * Score = min(100, pillar1_top + pillar2_shock + (10 if M3 else 0) + (35 if M4_latch_v2 else 0)).
       * Tier mapping: Crisis Score >= 35 -> 1 slot (1.25%), >= 45 -> 2 slots (2.50%), >= 65 -> 3 slots (3.75%).
       * Entry Vol Gate: VXN <= 27.0 AND VIX/VIX3M < 1.02 AND not in 5D Lockout.
       * Cooldown: >= 30 cal days (slots 1->2), >= 21 cal days (slot 3).
       * Contract Routing (UNIFORM -15% OTM):
         - Standard Pillars (P1/P2/M3) -> 125D -> Hard 75D roll, -15% OTM (K = 0.85 * S).
         - User's +8% Slow-Bear Hysteresis Latch (`M4_latch_v2`):
           ARM (ON) when QQQ < 200DMA & DD_252 <= -10.0% & Corr60(DualCTA, QQQ) < 0 & DualCTA_since_252hi >= +8.0%.
           RESET (OFF) when QQQ > 200DMA for 10 consecutive trading days.
           M4 Trigger: Latch ON & QQQ < 200DMA & 3-Speed EWMAC < 0 & QQQ > EMA20 & VXN <= 28.0 & VIX/VIX3M <= 0.90
           -> 90D -> Hard 30D roll, UNIFORM -15% OTM (K = 0.85 * S) at 1.25% NAV per slot!
     - Hard 75D / 30D Roll recovers approx 67% weighted salvage on non-TP rolls, keeping TRUE Net Roll Bleed
       at only approx 2.1% NAV/yr (vs approx 6.7% NAV/yr gross premium turnover).
  3. Right-Tail Take-Profit (`tp_near_itm_late5x`) + 5D Post-TP Contango Lockout:
     - Full TP: (VIX/VIX3M >= 1.10 AND QQQ <= 1.05 * Strike [Near-ITM]) OR VIX >= 45.0 -> 100% liquidate.
     - Late 5x TP: Remaining DTE <= 60D (Base) / <= 45D (Crisis) AND option ROI >= 5.0x -> 100% liquidate.
     - Proceeds: T+1 lump-sum 100% reinvestment into QQQ.
     - 5D Contango Lockout: Lock BOTH books post-TP until VIX/VIX3M < 1.00 for 5 consecutive trading days.
  4. User's Improved Dual-CTA Slow-Bear Rotation (`CONT_2M` + 5-Tranche + 1-Year Mechanical LTCG Lock):
     - Trigger: QQQ stays DD_ATH <= -12.0% continuously for 60 calendar days AND per-ETF (DBMF / KMLM)
       return since QQQ ATH > 0% -> rotate into pure QQQ in 5 equal tranches spaced 5 trading days apart
       (cancel remaining tranches if DD > -12.0%).
     - Restore: Mechanically hold rotated QQQ for 365 calendar days (LTCG lock) -> restore 10% DBMF + 10% KMLM (1.20x).

Windows Verified on Real MIT OPRA Quotes (6,382,288 real 16:00 ET QQQ put quotes across 2,749 OPRA days)
+ OPRA-Residual-Calibrated Z-Surface BSM Extension through 2026-11-25:
  - 11Y Real MIT OPRA (2015-01-02 -> 2025-12-15): 22.54% CAGR / -24.31% MDD / 0.927 Calmar
  - 5Y Zero-Splice Live (2020-12-03 -> 2025-12-15): 24.05% CAGR / -23.67% MDD / 1.016 Calmar
  - Extended continuously through 2026-11-25 via OPRA-residual-calibrated Z-surface BSM + half-spread model.
"""
from __future__ import annotations

import argparse
import datetime
import gzip
import importlib.util
import json
import math
import sys
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT_DIR / "server" / "config" / "crisis-observatory-dashboard.json"
DEFAULT_FACT_ROOT = ROOT_DIR / "data" / "fact_os"
SEED_GZ = ROOT_DIR / "server" / "config" / "crisis-observatory-seed-inputs.json.gz"

OPRA_BASE_DIR = Path("/Users/yudonglu/Documents/gemini/qqq-options-backtest/output")
PRIOR_MS_DIR = OPRA_BASE_DIR / "spitznagel_ms_dte_13f_audit_20261125"
PRIOR_SIX_DIR = OPRA_BASE_DIR / "six_retail_quant_archetypes_20261126"
SIG_CSV = OPRA_BASE_DIR / "crisis_prediction_models_research_20261124/data/signals_2015_2026.csv"
LEAPS_PUT_PQ = PRIOR_MS_DIR / "data/qqq_put_chain_leaps_2015_2025.parquet"
LIVE_ETF_CSV = PRIOR_SIX_DIR / "data/live_etf_total_returns_and_effr_2015_2026.csv"

ARTIFACT_VERSION = "crisis-observatory-v3-plan-d"
STRATEGY_CODE = "PlanD_TalebB020M125_DualCTA_CONT2M"
PUT_ENGINE_CODE = "B020_M125"
INITIAL_CAPITAL = 100_000.0
STOCK_REBAL_FEE = 0.0003   # Exact rb.STOCK_REBAL_FEE (3 bps) inside B020_M125 TailCore
CTA_REBAL_FEE = 0.0005     # Exact pure_mod.REBAL_FEE (5 bps) on Dual-CTA Box & rotation legs
BOX_SPREAD = 0.0035        # NY Fed EFFR + 35 bps (SPX Short Box Spread)
IBKR_SPREAD = 0.0150       # NY Fed EFFR + 150 bps (IBKR Pro Margin Stress)
OPRA_CUTOFF_DATE = "2025-12-15"

CRISIS_WINDOWS = [
    ("2015_16", "2015-16 China FX & Oil", "2015-16 汇改与油价冲击", "2015-07-20", "2016-03-31"),
    ("2018_Q1", "2018 Q1 Volmageddon", "2018 Q1 波动率崩盘", "2018-01-26", "2018-04-30"),
    ("2018_Q4", "2018 Q4 Fed QT Taper", "2018 Q4 美联储缩表", "2018-08-29", "2019-02-28"),
    ("2020_COVID", "2020 COVID Crash", "2020 COVID 疫情闪崩", "2020-02-19", "2020-05-15"),
    ("2022_BEAR", "2022 Inflation Slow Bear", "2022 通胀加息慢熊", "2021-12-27", "2023-01-31"),
    ("2023_Q3", "2023 Q3 UST Rate Spike", "2023 Q3 美债利率飙升", "2023-07-19", "2023-11-15"),
    ("2024_YEN", "2024.08 Yen Carry Unwind", "2024.08 日元套息拆仓", "2024-07-10", "2024-09-30"),
    ("2025_TAR", "2025.04 Tariff Shock", "2025.04 关税闪电冲击", "2025-02-19", "2025-05-30"),
    ("2026_NOV", "2026.11 Tech Selloff (BSM Ext)", "2026.11 科技抛售（BSM 延展）", "2026-10-15", "2026-11-25"),
]

# Empirical OPRA-Residual-Calibrated Option Surface (fitted on 1,500,755 real 2015-2025 MIT OPRA QQQ puts,
# self-consistent with r=EFFR & q=0.006, using physical standardized moneyness z = ln(K/F)/(sigma_VXN*sqrt(T))
# plus asymmetric contango/backwardation term-structure slope and CBOE SKEW):
OPRA_CAL_Z13: list[float] = [
    -0.083434, -0.186627, 0.015502, -0.028041, -0.407210, 0.039988,
    -0.587775, 0.034410, -0.011351, -0.130406, -0.045917, -0.008629, -0.116750,
]
# Empirical Modern Liquid Half-Spread Model (fitted on 2020-2025 real MIT OPRA QQQ puts):
OPRA_CAL_HS5: list[float] = [
    -5.243303, 0.021480, -0.342642, 0.024492, -3.358657,
]

OPRA_BSM_CALIBRATION_REPORT: dict[str, Any] = {
    "method": "opra_residual_z_surface_v1",
    "fit_quotes_count": 1500755,
    "fit_window": "2015-01-02..2025-12-15",
    "hs_fit_window": "2020-01-01..2025-12-15",
    "entry_104_med_sim_real": 0.999,
    "d125_medape_before_pct": 15.21,
    "d125_medape_after_pct": 7.00,
    "d90_medape_before_pct": 10.92,
    "d90_medape_after_pct": 5.81,
    "crash_tp_medape_before_pct": 13.77,
    "crash_tp_medape_after_pct": 6.39,
    "crash_tp_bias_before_pct": 22.22,
    "crash_tp_bias_after_pct": -0.90,
    "oos_2026_real_n": 9937,
    "oos_2026_medape_before_pct": 9.84,
    "oos_2026_medape_after_pct": 6.65,
    "oos_2026_bias_before_pct": 5.60,
    "oos_2026_bias_after_pct": 1.40,
    "hs_125d_medae_before_pp": 0.64,
    "hs_125d_medae_after_pp": 0.28,
}


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


def eval_calibrated_opra_iv(
    S: float,
    K: float,
    rem_d: int,
    r: float,
    q: float,
    vxn_pct: float,
    vix_ratio: float,
    skew_spot: float = 135.0,
    beta: list[float] = OPRA_CAL_Z13,
) -> float:
    t_eff = max(float(rem_d), 1.0) / 365.0
    fwd = max(1e-6, S * math.exp((r - q) * t_eff))
    log_m = math.log(max(K, 1e-6) / fwd)
    sig0 = _clip(vxn_pct / 100.0, 0.08, 1.0)
    dte_c = _clip(float(rem_d), 15.0, 220.0)
    sqt = math.sqrt(dte_c / 365.0)
    z = _clip(log_m / max(sig0 * sqt, 1e-4), -2.8, 1.5)
    tau = math.log(dte_c / 90.0)
    nu = math.log(_clip(vix_ratio, 0.70, 1.50))
    nu_pos = max(0.0, nu)
    sc = (_clip(skew_spot, 105.0, 175.0) - 135.0) / 100.0
    lv = math.log(_clip(vxn_pct, 10.0, 90.0) / 22.0)
    feats = (
        1.0, z, z * z, tau, nu, nu_pos,
        tau * nu, tau * nu_pos, z * tau, z * nu,
        sc, z * sc, lv,
    )
    log_rat = sum(b * f for b, f in zip(beta, feats))
    return _clip((vxn_pct / 100.0) * math.exp(log_rat), 0.06, 2.0)


def eval_calibrated_opra_hs(
    mid: float,
    rem_d: int,
    vix_pct: float,
    log_m: float,
    gamma: list[float] = OPRA_CAL_HS5,
) -> float:
    feats = (
        1.0,
        math.log(_clip(mid, 0.20, 200.0)),
        math.log(_clip(float(rem_d), 15.0, 220.0) / 90.0),
        math.log(_clip(vix_pct, 10.0, 90.0) / 20.0),
        _clip(log_m, -0.28, 0.12),
    )
    return _clip(math.exp(sum(g * f for g, f in zip(gamma, feats))), 0.002, 0.10)


def dte_bounds(dte_tgt: int) -> tuple[int, int]:
    if dte_tgt == 90:
        return 65, 120
    if dte_tgt == 125:
        return 95, 160
    return int(dte_tgt * 0.78), int(dte_tgt * 1.25)


def third_friday(year: int, month: int) -> datetime.date:
    first = datetime.date(year, month, 1)
    offset = (4 - first.weekday()) % 7
    return first + datetime.timedelta(days=offset + 14)


def nearest_monthly_exp(cur_dt: datetime.date, target_dte: int) -> tuple[datetime.date, int]:
    tgt_dt = cur_dt + datetime.timedelta(days=target_dte)
    cands: list[tuple[int, datetime.date, int]] = []
    for dm in (-1, 0, 1, 2):
        m0 = (tgt_dt.year * 12 + (tgt_dt.month - 1)) + dm
        yr, mo = divmod(m0, 12)
        mo += 1
        exp_dt = third_friday(yr, mo)
        dte = (exp_dt - cur_dt).days
        if dte >= max(45, int(target_dte * 0.65)):
            cands.append((abs(dte - target_dte), exp_dt, dte))
    cands.sort(key=lambda x: x[0])
    _, best_exp, best_dte = cands[0]
    return best_exp, best_dte


def pack_table(rows: list[dict[str, Any]], cols: list[str]) -> dict[str, Any]:
    return {"_cols": cols, "_rows": [[r.get(c) for c in cols] for r in rows]}


def unpack_table(tbl: Any) -> list[dict[str, Any]]:
    if isinstance(tbl, list):
        return tbl
    if isinstance(tbl, dict) and "_cols" in tbl and "_rows" in tbl:
        cols = tbl["_cols"]
        return [dict(zip(cols, row)) for row in tbl["_rows"]]
    return []


def load_mod(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def pearson_corr(xs: list[float], ys: list[float]) -> float:
    n = min(len(xs), len(ys))
    if n < 3:
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


def build_ruleset_spec(roll_econ: dict[str, Any] | None = None) -> dict[str, Any]:
    re = roll_econ or {
        "gross_turnover_pct_nav_yr": 6.67,
        "roll_salvage_pct": 67.3,
        "true_net_bleed_pct_nav_yr": 2.13,
    }
    gt = re["gross_turnover_pct_nav_yr"]
    sv = re["roll_salvage_pct"]
    nb = re["true_net_bleed_pct_nav_yr"]
    return {
        "code": STRATEGY_CODE,
        "put_engine_code": PUT_ENGINE_CODE,
        "tier_ladder": "M7G_tier_45_65",
        "m4_mode": "M4_latch_v2_90d_m15",
        "tp_mode": "tp_near_itm_late5x",
        "cta_rotation_mode": "CONT_2M_5tranche_365d_LTCG",
        "version": "v3.0",
        "locked": True,
        "single_strategy_only": True,
        "name_en": "Double-Champion v3.0 (Plan D) · Taleb B020_M125 + +8% Slow-Bear Latch + Dual-CTA CONT_2M",
        "name_zh": "双冠终极版 v3.0（Plan D）· 原汁正统 Taleb 满血核 + 改进 CTA 慢熊轮动 + +8% 磁滞锁存",
        "core_overlay": {
            "qqq_weight_pct": 100.0,
            "dbmf_weight_pct": 10.0,
            "kmlm_weight_pct": 10.0,
            "debt_weight_pct": 20.0,
            "target_gross_leverage": 1.200,
            "daily_forced_delev_cap": False,
            "natural_drift_peak_approx": 1.26,
            "financing_primary": "EFFR + 35 bps (SPX Short Box)",
            "financing_stress": "EFFR + 150 bps (IBKR Pro Margin)",
            "rebalance_rule_en": "NO daily 1.20x forced drawdown deleveraging cap (natural gross leverage drifts up to approx 1.26x during drawdowns so QQQ is NEVER liquidated at crash bottoms). Quarterly calm calibration restores 1.200x target.",
            "rebalance_rule_zh": "取消每日 1.20x 强制去杠杆砍仓线（回撤期允许总杠杆自然漂移至约 1.26x，绝不在底部割肉 QQQ）；平稳无锁仓期按季校准回 1.200x。",
        },
        "sleeve_a": {
            "code": "B020",
            "budget_pct_nav": 0.20,
            "target_dte": 125,
            "roll_dte": 75,
            "otm_pct": -15,
            "vix_max": 20.0,
            "vr_max": 1.02,
            "hard_roll": True,
            "rule_en": "Baseline Floor (0.20% NAV): Enter 125D -15% OTM Put when VIX <= 20.0 AND VIX/VIX3M < 1.02 AND not in 5D Lockout. Hard 75D roll/salvage preserves convexity and recovers salvage value.",
            "rule_zh": "常态底仓盾（0.20% NAV）：VIX <= 20.0 且 VIX/VIX3M < 1.02 且非 5 日锁仓期时买入 125D -15% OTM Put；75D 强制早滚仓/回收残值，绝不扛到深度时间衰减区。",
        },
        "sleeve_b": {
            "code": "M125",
            "tier_ladder": "M7G_tier_45_65",
            "budget_per_slot_pct_nav": 1.25,
            "max_slots": 3,
            "max_budget_pct_nav": 3.75,
            "tier_thresholds": {"slot1": 35, "slot2": 45, "slot3": 65},
            "vxn_max": 27.0,
            "vr_max": 1.02,
            "cooldown_days_1_to_2": 30,
            "cooldown_days_slot_3": 21,
            "lockout_contango_days": 5,
            "uniform_otm_pct": -15,
            "route1": {
                "pillars": ["P1", "P2", "M3"],
                "target_dte": 125,
                "roll_dte": 75,
                "otm_pct": -15,
                "rule_en": "Standard Pillars (P1/P2/M3): Score = min(100, P1 + P2 + 10*M3 + 35*M4_latch). >= 35 -> 1 slot (1.25%), >= 45 -> 2 slots (2.50%), >= 65 -> 3 slots (3.75% NAV) in 125D -> Hard 75D roll, -15% OTM Put when VXN <= 27.0 & VIX/VIX3M < 1.02.",
                "rule_zh": "标准危机三支柱（P1/P2/M3）：得分 = min(100, P1 + P2 + 10*M3 + 35*M4锁存)；>= 35 开 1 槽（1.25%）、>= 45 开 2 槽（2.50%）、>= 65 开满 3 槽（3.75% NAV）；门控 VXN <= 27.0 且 VIX/3M < 1.02，统一买 125D -15% OTM、75D 强滚。",
            },
            "route2_m4": {
                "mode": "M4_latch_v2_90d_m15",
                "target_dte": 90,
                "roll_dte": 30,
                "otm_pct": -15,
                "vxn_max": 28.0,
                "vr_max": 0.90,
                "latch_cta_gain_pct": 8.0,
                "latch_dd252_pct": -10.0,
                "latch_reset_above200_days": 10,
                "rule_en": "User +8% Slow-Bear Hysteresis Latch (M4_latch_v2): ARM when QQQ < 200DMA & DD_252 <= -10.0% & Corr60(DualCTA, QQQ) < 0 & DualCTA gain >= +8.0%; RESET after 10 consecutive days QQQ > 200DMA. When ON & QQQ < 200DMA & EWMAC < 0 & QQQ > EMA20 & VXN <= 28.0 & VR <= 0.90 -> 90D -> Hard 30D roll, UNIFORM -15% OTM (1.25% NAV per slot).",
                "rule_zh": "用户 +8% 慢熊磁滞锁存（M4_latch_v2）：QQQ < 200DMA 且 252日回撤 <= -10.0% 且 60日相关 < 0 且双CTA自高点涨 >= +8.0% 时锁存开启，连续 10 交易日站回 200DMA 解锁；开启且慢熊反弹（EWMAC < 0 & QQQ > EMA20 & VXN <= 28.0 & VR <= 0.90）时买 90D -> 30D 强滚，统一 -15% OTM（每槽 1.25% NAV）。",
            },
        },
        "roll_economics": {
            "hard_roll_dte_std": 75,
            "hard_roll_dte_m4": 30,
            "opra_11y_gross_turnover_pct_nav_yr": gt,
            "opra_11y_roll_salvage_pct": sv,
            "opra_11y_true_net_bleed_pct_nav_yr": nb,
            "note_en": f"Hard 75D/30D roll recovers {sv}% weighted salvage on non-TP rolls, cutting {gt}% NAV/yr gross turnover down to only {nb}% NAV/yr true net roll bleed.",
            "note_zh": f"75D/30D 强制早滚仓在非止盈滚仓中平均回收 {sv}% 残值，将名义流水 {gt}% NAV/yr 压缩至仅 {nb}% NAV/yr 的真实净损耗。",
        },
        "take_profit": {
            "mode": "tp_near_itm_late5x",
            "full_vr_min": 1.10,
            "near_itm_strike_mult": 1.05,
            "vix_panic_min": 45.0,
            "late_5x_mult": 5.0,
            "late_5x_dte_base": 60,
            "late_5x_dte_crisis": 45,
            "reinvest_mode": "t1_lump_sum_100pct_qqq",
            "lockout_contango_days": 5,
            "lockout_scope": "both_books",
            "rule_en": "Full TP: (VIX/VIX3M >= 1.10 AND QQQ <= 1.05 x Strike [Near-ITM]) OR VIX >= 45.0 -> 100% liquidate. Late 5x TP: Remaining DTE <= 60D (Base) / <= 45D (Crisis) AND ROI >= 5.0x -> 100% liquidate. T+1 lump-sum 100% reinvestment into QQQ + 5D Post-TP Contango Lockout (VIX/VIX3M < 1.00 for 5 consecutive days) on BOTH books.",
            "rule_zh": "右尾全额止盈：（VIX/VIX3M >= 1.10 且 QQQ <= 1.05 倍行权价 [近实值]）或 VIX >= 45.0 -> 100% 清仓；晚段 5x 止盈：剩余到期 <= 60D（常态）/ <= 45D（危机）且回报 >= 5.0x -> 100% 清仓；T+1 一次性 100% 全额回买 QQQ，并对双账本启动止盈后 5 日正向期限结构锁仓（连续 5 日 VIX/3M < 1.00 解锁）。",
        },
        "cta_rotation": {
            "mode": "CONT_2M_5tranche_365d_LTCG",
            "dd_threshold_pct": -12.0,
            "continuous_calendar_days": 60,
            "tranches": 5,
            "tranche_spacing_trading_days": 5,
            "ltcg_hold_calendar_days": 365,
            "rule_en": "User Improved Dual-CTA Rotation (CONT_2M): When QQQ stays DD_ATH <= -12.0% continuously for 60 calendar days AND per-ETF (DBMF / KMLM) return since QQQ ATH > 0%, rotate qualifying CTA sleeve into pure QQQ in 5 equal tranches spaced 5 trading days apart (cancel remaining if DD > -12.0%).",
            "rule_zh": "用户改进版双CTA慢熊轮动（CONT_2M）：QQQ 距前高连续 60 自然日 <= -12.0% 且单只 CTA（DBMF/KMLM）自前高涨幅 > 0% 时，分 5 批（每批间隔 5 交易日）切入 QQQ；若期间回撤收窄至 > -12.0% 则中止未执行批次。",
            "reload_rule_en": "Mechanical 1-Year LTCG Restore: Each rotated QQQ tranche is mechanically held for 365 calendar days (US Long-Term Capital Gains compliance), then restored back to 10% DBMF + 10% KMLM (1.200x).",
            "reload_rule_zh": "365 天机械长期税率锁定恢复：每批切入的 QQQ 机械持有满 365 自然日（满足美股长期资本利得 LTCG），随后自动恢复为 10% DBMF + 10% KMLM（1.200x）。",
        },
    }


def check_tp_near_itm_late5x(
    vix: float, vix_r: float, cl: float, tr: dict[str, Any], rem_days: int, mid: float, is_base: bool
) -> tuple[bool, str]:
    mult = mid / max(float(tr["entry_fill"]), 1e-6)
    near_itm = cl <= float(tr["strike"]) * 1.05
    dte_lim = 60 if is_base else 45
    if (vix_r >= 1.10 and near_itm) or vix >= 45.0:
        return True, "base_tp_near_itm" if is_base else "tp_near_itm"
    if rem_days <= dte_lim and mult >= 5.0:
        return True, "base_tp_5x_late" if is_base else "tp_5x_late"
    return False, ""


def run_full_opra_build(output_path: Path, fetch_live: bool = False) -> dict[str, Any]:
    import numpy as np
    import pandas as pd

    ms_mod = load_mod("ms_mod", PRIOR_MS_DIR / "01_ms_index_backtest.py")
    rb, cta_mod = ms_mod.load_prior_engines()
    store = rb.RealOptionChainStore(LEAPS_PUT_PQ)
    all_rows, coeffs, m4_opra_flags, m7g_opra_slots, _, _ = cta_mod.load_sim_panel_and_signals()

    etf_df = pd.read_csv(LIVE_ETF_CSV, index_col=0)
    etf_df.index = etf_df.index.astype(str)
    sig_df = pd.read_csv(SIG_CSV)
    sig_df["date"] = sig_df["date"].astype(str)
    sig_df = sig_df.set_index("date")

    existing_doc = json.loads(output_path.read_text(encoding="utf-8")) if output_path.exists() else {}
    existing_pit_rows = unpack_table(existing_doc.get("pit_daily_index"))
    if not existing_pit_rows:
        raise RuntimeError(f"Existing artifact at {output_path} missing pit_daily_index.")
    existing_pit_by_d = {str(r["date"]): r for r in existing_pit_rows}
    old_tail = dict(existing_doc.get("live_tail_state") or {})

    # Build daily CBOE SKEW spot map from existing pit rows + tail
    skew_spot_map: dict[str, float] = {}
    for r in existing_pit_rows:
        sv = r.get("skew_spot") if r.get("skew_spot") is not None else r.get("skew10")
        if sv is not None and math.isfinite(float(sv)):
            skew_spot_map[str(r["date"])] = float(sv)

    # Precompute daily Real MIT OPRA microstructure (2015-01-02 -> 2025-12-15) with UNIFORM -15% OTM for BOTH 125D & 90D!
    opra_micro_by_date: dict[str, dict[str, Any]] = {}
    lo125, hi125 = dte_bounds(125)
    lo90, hi90 = dte_bounds(90)
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
        # UNIFORM -15% OTM (0.85 moneyness) for M4 90D!
        c90 = store.select_put_contract(d_a, cl_a, 90, 0.85, lo90, hi90)

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

    def compute_bsm_micro_est(
        cl_v: float,
        vxn_v: float,
        r_v: float = 0.04,
        q_v: float = 0.006,
        vix_v: float | None = None,
        vr_v: float = 0.90,
        skew_v: float = 135.0,
    ) -> dict[str, Any]:
        """OPRA-residual-calibrated Z-surface BSM estimate for post-OPRA sessions (> 2025-12-15), Uniform -15% OTM."""
        t125 = 125.0 / 365.0
        t90 = 90.0 / 365.0
        vix_eff = float(vix_v) if (vix_v is not None and vix_v > 0) else max(10.0, vxn_v * 0.85)
        k_atm = round(cl_v)
        k10 = round(cl_v * 0.90)
        k15 = round(cl_v * 0.85)
        k20 = round(cl_v * 0.80)
        iv_atm = eval_calibrated_opra_iv(cl_v, k_atm, 125, r_v, q_v, vxn_v, vr_v, skew_v)
        iv10 = eval_calibrated_opra_iv(cl_v, k10, 125, r_v, q_v, vxn_v, vr_v, skew_v)
        iv15 = eval_calibrated_opra_iv(cl_v, k15, 125, r_v, q_v, vxn_v, vr_v, skew_v)
        iv20 = eval_calibrated_opra_iv(cl_v, k20, 125, r_v, q_v, vxn_v, vr_v, skew_v)
        # UNIFORM -15% OTM for M4 90D!
        iv90 = eval_calibrated_opra_iv(cl_v, k15, 90, r_v, q_v, vxn_v, vr_v, skew_v)
        mid15 = max(0.05, bsm_price(cl_v, k15, t125, r_v, q_v, iv15, "put"))
        mid90 = max(0.05, bsm_price(cl_v, k15, t90, r_v, q_v, iv90, "put"))
        fwd125 = cl_v * math.exp((r_v - q_v) * t125)
        fwd90 = cl_v * math.exp((r_v - q_v) * t90)
        hs15_f = eval_calibrated_opra_hs(mid15, 125, vix_eff, math.log(max(k15, 1.0) / max(fwd125, 1.0)))
        hs90_f = eval_calibrated_opra_hs(mid90, 90, vix_eff, math.log(max(k15, 1.0) / max(fwd90, 1.0)))
        bid15, ask15 = max(0.01, mid15 * (1.0 - hs15_f)), mid15 * (1.0 + hs15_f)
        bid90, ask90 = max(0.01, mid90 * (1.0 - hs90_f)), mid90 * (1.0 + hs90_f)
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
            "p90_k": float(k15),
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

    def _bsm_calibrated_quote(
        cl_v: float,
        K: float,
        rem_d: int,
        r_v: float,
        q_v: float,
        vxn_v: float,
        vix_v: float,
        vr_v: float = 0.90,
        skew_v: float = 135.0,
    ) -> tuple[float, float, float, float, float]:
        t_rem = max(0, rem_d) / 365.0
        t_eff = max(t_rem, 1.0 / 365.0)
        sig = eval_calibrated_opra_iv(cl_v, K, rem_d, r_v, q_v, vxn_v, vr_v, skew_v)
        mid = max(0.01, bsm_price(cl_v, K, t_rem, r_v, q_v, sig, "put"))
        dl = bsm_delta(cl_v, K, t_rem, r_v, q_v, sig, "put")
        fwd = max(1e-6, cl_v * math.exp((r_v - q_v) * t_eff))
        log_m = math.log(max(K, 1e-6) / fwd)
        hs = eval_calibrated_opra_hs(mid, rem_d, vix_v, log_m)
        bid = max(0.01, mid * (1.0 - hs))
        ask = max(bid + 0.01, mid * (1.0 + hs))
        mid_adj = 0.5 * (bid + ask)
        return bid, ask, mid_adj, sig, dl

    # Build extended sim_rows through latest date in etf_df / existing_pit_rows (2026-11-25)
    # Use Plan D exact M4_latch_v2 (from verified HEAD pit_daily_index ent_mask & 16) and
    # Score = min(100, pillar1_top + pillar2_shock + (10 if M3 else 0) + (35 if M4_latch_v2 else 0))
    # -> M7G_tier_45_65 (>=35: 1 slot, >=45: 2 slots, >=65: 3 slots)!
    def _plan_d_slots_and_m4(ds: str, pr: dict[str, Any] | None) -> tuple[int, bool]:
        m4_v2 = bool(int(pr["ent_mask"]) & 16) if pr is not None else False
        if ds in sig_df.index:
            sr = sig_df.loc[ds]
            p1_v = float(sr["pillar1_top"])
            p2_v = float(sr["pillar2_shock"])
            m3_v = int(bool(sr["M3"]))
        elif pr is not None:
            em = int(pr["ent_mask"])
            p1_v = float(min(45, (35 if (em & 1) else 0) + (20 if (em & 2) else 0)))
            p2_v = float(min(40, (20 if (em & 4) else 0) + (20 if (em & 8) else 0)))
            m3_v = 1 if (em & 32) else 0
        else:
            p1_v, p2_v, m3_v = 0.0, 0.0, 0
        sc = min(100.0, p1_v + p2_v + (10.0 if m3_v else 0.0) + (35.0 if m4_v2 else 0.0))
        sl = 3 if sc >= 65.0 else (2 if sc >= 45.0 else (1 if sc >= 35.0 else 0))
        return sl, m4_v2

    ext_rows: list[dict[str, Any]] = [dict(r) for r in all_rows]
    ext_m7g: list[int] = []
    ext_m4: list[bool] = []
    for r_o in ext_rows:
        ds_o = str(r_o["date"])
        sl_o, m4_o = _plan_d_slots_and_m4(ds_o, existing_pit_by_d.get(ds_o))
        ext_m7g.append(sl_o)
        ext_m4.append(m4_o)

    last_opra_d = str(ext_rows[-1]["date"])
    last_cl = float(ext_rows[-1]["close"])
    last_q_tr = float(etf_df.loc[last_opra_d, "QQQ"])
    last_r_opt = float(ext_rows[-1].get("r", 0.04))

    for d_ext in etf_df.index:
        ds = str(d_ext)
        if ds <= last_opra_d:
            continue
        pr = existing_pit_by_d.get(ds)
        if pr is None:
            continue
        cl = float(pr["qqq"])
        q_tr = float(etf_df.loc[ds, "QQQ"])
        r_tr = (q_tr / last_q_tr - 1.0) if last_q_tr > 0 else 0.0
        r_px = (cl / last_cl - 1.0) if last_cl > 0 else 0.0
        div_ps = max(0.0, last_cl * (r_tr - r_px))
        effr_raw_v = float(etf_df.loc[ds, "EFFR"]) if np.isfinite(float(etf_df.loc[ds, "EFFR"])) else last_r_opt
        last_r_opt = effr_raw_v
        last_cl = cl
        last_q_tr = q_tr
        ext_rows.append({
            "date": ds,
            "close": cl,
            "dividends": div_ps,
            "vix": float(pr["vix"]),
            "vxn": float(pr["vxn"]),
            "vix_ratio": float(pr["vr"]),
            "r": effr_raw_v,
            "div_yield": 0.006,
            "skew_spot": float(skew_spot_map.get(ds) or pr.get("skew_spot") or 135.0),
        })
        sl_e, m4_e = _plan_d_slots_and_m4(ds, pr)
        ext_m7g.append(sl_e)
        ext_m4.append(m4_e)

    # Extract +8% Slow-Bear Hysteresis Latch episodes across ext_dates from existing_pit_rows
    all_latch_episodes: list[dict[str, Any]] = []
    cur_lep: dict[str, Any] | None = None
    for r_p in existing_pit_rows:
        d_p = str(r_p["date"])
        is_on = bool(r_p.get("latch"))
        if is_on and cur_lep is None:
            cur_lep = {
                "arm_date": d_p,
                "peak_date": r_p.get("hi252_date"),
                "arm_qqq_dd252_pct": round(float(r_p.get("dd252") or 0.0), 2),
                "arm_cta_gain_pct": round(float(r_p.get("cta_hi252") or 0.0), 2),
                "peak_cta_gain_pct": round(float(r_p.get("latch_pk") or r_p.get("cta_hi252") or 0.0), 2),
                "arm_corr60": round(float(r_p.get("corr60") or 0.0), 3),
                "reset_date": None,
                "trading_days": 1,
            }
            all_latch_episodes.append(cur_lep)
        elif is_on and cur_lep is not None:
            cur_lep["trading_days"] += 1
            cur_lep["peak_cta_gain_pct"] = max(
                float(cur_lep["peak_cta_gain_pct"]),
                round(float(r_p.get("latch_pk") or 0.0), 2),
            )
        elif (not is_on) and cur_lep is not None:
            cur_lep["reset_date"] = d_p
            cur_lep = None

    ext_end_date = str(ext_rows[-1]["date"])
    ext_dates = [str(r["date"]) for r in ext_rows]

    # Pre-align ETF total returns and EFFR across ext_dates
    p_ext = etf_df.reindex(ext_dates).ffill()
    effr_ext = p_ext["EFFR"].ffill().bfill().to_numpy(dtype=float)
    px_q_ext = p_ext["QQQ"].to_numpy(dtype=float)
    r_q_ext = p_ext["QQQ"].pct_change().fillna(0.0).to_numpy(dtype=float)
    r_aq_ext = p_ext["AQMIX"].pct_change().fillna(0.0).to_numpy(dtype=float)
    idx_km_live = ext_dates.index("2020-12-03")
    idx_db_live = ext_dates.index("2019-05-09")
    r_km_raw_ext = p_ext["KMLM"].pct_change().fillna(0.0).to_numpy(dtype=float)
    r_db_raw_ext = p_ext["DBMF"].pct_change().fillna(0.0).to_numpy(dtype=float)
    r_km_spliced = np.where(np.arange(len(ext_dates)) < idx_km_live, r_aq_ext, r_km_raw_ext)
    r_db_spliced = np.where(np.arange(len(ext_dates)) < idx_db_live, r_aq_ext, r_db_raw_ext)
    px_km_spliced = 100.0 * np.cumprod(1.0 + r_km_spliced)
    px_db_spliced = 100.0 * np.cumprod(1.0 + r_db_spliced)

    # Exact canonical Plan D Double-Champion (B020_M125 + M4_latch_v2 -15% OTM + 20% Dual-CTA Box Stack + CONT_2M 5-Tranche 1Y LTCG, NO daily 1.20x cap)
    def run_taleb_champion_window(
        win_id: str,
        start_d: str,
        zero_splice: bool,
        exec_mode: str,
        fin_spread: float,
    ) -> dict[str, Any]:
        s_idx = ext_dates.index(start_d)
        sim_rows_w = ext_rows[s_idx:]
        dates = ext_dates[s_idx:]
        n = len(dates)
        dt_objs = [datetime.date.fromisoformat(d) for d in dates]
        m7g_w = ext_m7g[s_idx:]
        m4_w = ext_m4[s_idx:]

        effr_w = effr_ext[s_idx:]
        px_qqq_w = px_q_ext[s_idx:]
        r_qqq_w = r_q_ext[s_idx:].copy()
        r_qqq_w[0] = 0.0

        if zero_splice:
            r_km_w = r_km_raw_ext[s_idx:].copy()
            r_db_w = r_db_raw_ext[s_idx:].copy()
            r_km_w[0] = 0.0
            r_db_w[0] = 0.0
            px_km_w = p_ext["KMLM"].to_numpy(dtype=float)[s_idx:]
            px_db_w = p_ext["DBMF"].to_numpy(dtype=float)[s_idx:]
        else:
            r_km_w = r_km_spliced[s_idx:].copy()
            r_db_w = r_db_spliced[s_idx:].copy()
            r_km_w[0] = 0.0
            r_db_w[0] = 0.0
            px_km_w = px_km_spliced[s_idx:]
            px_db_w = px_db_spliced[s_idx:]

        vix_w = np.array([float(r["vix"]) for r in sim_rows_w], dtype=float)
        vr_w = np.array([float(r["vix_ratio"]) for r in sim_rows_w], dtype=float)
        base_gate_w = [bool(vix_w[i] <= 20.0 and vr_w[i] < 1.02) for i in range(n)]

        # ------------------------------------------------------------------
        # LAYER 1: Exact B020_M125 Put Engine + 100% QQQ Core ($100k start)
        # ------------------------------------------------------------------
        px0 = float(sim_rows_w[0]["close"])
        core_shares = INITIAL_CAPITAL / (px0 * (1.0 + STOCK_REBAL_FEE))
        m7_active: list[dict[str, Any]] = []
        base_active: list[dict[str, Any]] = []
        pending_m7_sig: dict[str, Any] | None = None
        pending_base_open = False
        put_ledger: list[dict[str, Any]] = []
        core_nav_list: list[float] = []
        tid = 0
        exec_fallbacks_opra = 0
        post_tp_lockout = False
        non_inv_streak = 0
        m7_locked_prev_eod = False
        base_locked_prev_eod = False
        lockout_days_total = 0
        lockout_episodes: list[dict[str, Any]] = []
        cur_ep: dict[str, Any] | None = None

        # Per-day state trackers for PIT index synchronization
        lock_active_by_day: list[bool] = [False] * n
        lock_streak_by_day: list[int] = [0] * n
        last_tp_by_day: list[str | None] = [None] * n
        active_puts_cnt_by_day: list[int] = [0] * n
        last_tp_d_seen: str | None = None

        run_ath_spot_w = px_qqq_w[0]
        dd_ath_w = np.zeros(n, dtype=float)

        def _core_nav_approx(cl_v: float) -> float:
            nv = core_shares * cl_v
            for tr in m7_active:
                nv += tr.get("last_mtm_usd", tr["entry_cost_usd"])
            for tr in base_active:
                nv += tr.get("last_mtm_usd", tr["entry_cost_usd"])
            return max(nv, 1.0)

        def _select_contract(d: str, dt_d: datetime.date, cl_v: float, t_dte: int, mon: float, row_i: dict[str, Any]):
            if d <= OPRA_CUTOFF_DATE:
                lo, hi = dte_bounds(t_dte)
                c = store.select_put_contract(d, cl_v, t_dte, mon, lo, hi)
                return c, "REAL_OPRA"
            exp_dt_s, dte_s = nearest_monthly_exp(dt_d, t_dte)
            k_s = float(max(5, round(cl_v * mon)))
            bid_s, ask_s, mid_s, iv_s, dl_s = _bsm_calibrated_quote(
                cl_v, k_s, dte_s, float(row_i["r"]), 0.006, float(row_i["vxn"]), float(row_i["vix"]),
                vr_v=float(row_i["vix_ratio"]), skew_v=float(row_i.get("skew_spot") or skew_spot_map.get(d, 135.0)),
            )
            return {
                "exp": exp_dt_s.isoformat(),
                "exp_dt": exp_dt_s,
                "dte": int(dte_s),
                "strike": k_s,
                "k_cents": int(round(k_s * 100)),
                "bid": bid_s,
                "ask": ask_s,
                "mid": mid_s,
                "iv": iv_s,
                "delta": dl_s,
            }, "BSM_SIM_2026"

        def _lookup_contract(d: str, tr: dict[str, Any], cl_v: float, rem_d: int, row_i: dict[str, Any]):
            if d <= OPRA_CUTOFF_DATE:
                bid, ask, mid, iv, dl, src = store.lookup_contract(
                    d, "put", tr["exp"], tr["k_cents"], cl_v, rem_d,
                    float(row_i["r"]), float(row_i["div_yield"]), float(row_i["vxn"]), tr["last_iv"], coeffs,
                )
                return bid, ask, mid, iv, dl, src, "REAL_OPRA"
            bid, ask, mid, iv, dl = _bsm_calibrated_quote(
                cl_v, float(tr["strike"]), rem_d, float(row_i["r"]), 0.006, float(row_i["vxn"]), float(row_i["vix"]),
                vr_v=float(row_i["vix_ratio"]), skew_v=float(row_i.get("skew_spot") or skew_spot_map.get(d, 135.0)),
            )
            return bid, ask, mid, iv, dl, "bsm_ext", "BSM_SIM_2026"

        def _open_tranche(
            i: int,
            book: str,
            is_cta: bool,
            bud_pct: float,
            t_dte: int,
            rl_dte: int,
            cap_slots: int,
            salv: float = 0.0,
        ):
            nonlocal core_shares, tid, exec_fallbacks_opra
            d = dates[i]
            row_i = sim_rows_w[i]
            cl = float(row_i["close"])
            tgt_c, q_src = _select_contract(d, dt_objs[i], cl, t_dte, 0.85, row_i)
            if tgt_c is None:
                if d <= OPRA_CUTOFF_DATE:
                    exec_fallbacks_opra += 1
                if salv > 1e-8:
                    core_shares += salv / (cl * (1.0 + STOCK_REBAL_FEE))
                return None
            buy_px = rb.exec_buy_price(tgt_c["bid"], tgt_c["ask"], tgt_c["mid"], exec_mode)
            cur_nav = _core_nav_approx(cl) + salv
            bud_usd = cur_nav * bud_pct
            if buy_px < 0.03 or bud_usd <= 1.0:
                if salv > 1e-8:
                    core_shares += salv / (cl * (1.0 + STOCK_REBAL_FEE))
                return None
            hedged_sh = bud_usd / buy_px
            net_need = bud_usd - salv
            if net_need > 1e-8:
                core_shares -= net_need / (cl * (1.0 - STOCK_REBAL_FEE))
            elif net_need < -1e-8:
                core_shares += (-net_need) / (cl * (1.0 + STOCK_REBAL_FEE))
            tid += 1
            om_en = opra_micro_by_date.get(d)
            if om_en is None:
                om_en = compute_bsm_micro_est(
                    cl, float(row_i["vxn"]), r_v=float(row_i["r"]), q_v=0.006,
                    vix_v=float(row_i["vix"]), vr_v=float(row_i["vix_ratio"]),
                    skew_v=float(row_i.get("skew_spot") or skew_spot_map.get(d, 135.0)),
                )
            hs_en = ((tgt_c["ask"] - tgt_c["bid"]) / (2.0 * tgt_c["mid"]) * 100.0) if float(tgt_c["mid"]) > 0 else 0.0
            sleeve_code = "base" if book == "base" else ("crisis_m4" if is_cta else "crisis")
            return {
                "tranche_id": tid,
                "book": book,
                "sleeve": sleeve_code,
                "is_cta": is_cta,
                "slot_cap": cap_slots,
                "target_dte": t_dte,
                "roll_dte": rl_dte,
                "entry_date": d,
                "entry_dt": dt_objs[i],
                "exp": tgt_c["exp"],
                "exp_dt": tgt_c["exp_dt"],
                "entry_dte": int(tgt_c["dte"]),
                "strike": float(tgt_c["strike"]),
                "k_cents": int(tgt_c["k_cents"]),
                "entry_spot": cl,
                "entry_fill": float(buy_px),
                "entry_bid": float(tgt_c["bid"]),
                "entry_ask": float(tgt_c["ask"]),
                "entry_mid": float(tgt_c["mid"]),
                "entry_hs_pct": round(float(hs_en), 2),
                "entry_lot_pct": round(float(buy_px) / max(cl, 1.0) * 100.0, 3),
                "entry_sk20_10": om_en.get("opra_sk20_10"),
                "entry_vix": round(float(row_i["vix"]), 2),
                "entry_vr": round(float(row_i["vix_ratio"]), 3),
                "quote_source": q_src,
                "last_iv": float(tgt_c["iv"]) if np.isfinite(tgt_c["iv"]) else None,
                "hedged_shares": hedged_sh,
                "entry_cost_usd": bud_usd,
                "nav_at_entry": cur_nav,
                "last_mtm_usd": bud_usd,
                "last_mid": float(tgt_c["mid"]),
                "last_rem_days": int(tgt_c["dte"]),
                "pending_exit": False,
                "exit_reason": "",
            }

        def _record_exit(tr: dict[str, Any], i: int, rem_d: int, bid: float, ask: float, mid: float, sell_px: float, trade_qsrc: str):
            d = dates[i]
            row_i = sim_rows_w[i]
            cl = float(row_i["close"])
            cp = float(tr["entry_cost_usd"])
            ex = float(tr["hedged_shares"]) * sell_px
            put_ledger.append({
                "tranche_id": tr["tranche_id"],
                "sleeve": tr["sleeve"],
                "book": tr["book"],
                "slot_cap": tr["slot_cap"],
                "entry_date": tr["entry_date"],
                "exit_date": d,
                "exp": tr["exp"],
                "strike": round(float(tr["strike"]), 2),
                "entry_dte": int(tr["entry_dte"]),
                "exit_dte": int(rem_d),
                "entry_spot": round(float(tr["entry_spot"]), 2),
                "exit_spot": round(cl, 2),
                "entry_fill": round(float(tr["entry_fill"]), 3),
                "entry_bid": round(float(tr["entry_bid"]), 2),
                "entry_ask": round(float(tr["entry_ask"]), 2),
                "entry_mid": round(float(tr["entry_mid"]), 2),
                "entry_hs_pct": tr["entry_hs_pct"],
                "entry_lot_pct": tr["entry_lot_pct"],
                "entry_sk20_10": tr["entry_sk20_10"],
                "entry_vix": tr["entry_vix"],
                "entry_vr": tr["entry_vr"],
                "exit_fill": round(float(sell_px), 3),
                "exit_bid": round(float(bid), 2),
                "exit_ask": round(float(ask), 2),
                "exit_mid": round(float(mid), 2),
                "exit_vix": round(float(row_i["vix"]), 2),
                "exit_vr": round(float(row_i["vix_ratio"]), 3),
                "exit_dd_pct": round(float(dd_ath_w[i]) * 100.0, 2),
                "exit_lot_pct": round(float(sell_px) / max(cl, 1.0) * 100.0, 3),
                "contracts": round(float(tr["hedged_shares"]) / 100.0, 2),
                "exit_frac": 1.0,
                "cost_usd": round(cp, 2),
                "exit_usd": round(ex, 2),
                "net_pnl_usd": round(ex - cp, 2),
                "roi_mult": round(ex / cp, 2) if cp > 1e-6 else 0.0,
                "nav_at_entry": round(float(tr["nav_at_entry"]), 2),
                "exit_reason": tr["exit_reason"],
                "quote_source": trade_qsrc,
            })
            return ex

        for i in range(n):
            d = dates[i]
            row_i = sim_rows_w[i]
            cl = float(row_i["close"])
            div = float(row_i.get("dividends", 0.0))
            vxn_cl = float(row_i["vxn"])
            vix_cl = float(row_i["vix"])
            vix_r = float(row_i["vix_ratio"])

            if px_qqq_w[i] >= run_ath_spot_w:
                run_ath_spot_w = float(px_qqq_w[i])
            dd_ath_w[i] = px_qqq_w[i] / run_ath_spot_w - 1.0

            # 1A. Pending T+1 Close Exits for Book M (Crisis M7G)
            if i > 0 and m7_active:
                # Pre-filter surviving (non-exiting) tranches BEFORE evaluating roll slot caps
                # so older tranches at index 0 cannot overlook younger surviving tranches.
                still_m7 = [t for t in m7_active if not t["pending_exit"]]
                m7_roll_reps: list[tuple[float, int, bool]] = []
                for tr in m7_active:
                    if not tr["pending_exit"]:
                        continue
                    rem_d = max(0, (tr["exp_dt"] - dt_objs[i]).days)
                    bid, ask, mid, iv, dl, src, trade_qsrc = _lookup_contract(d, tr, cl, rem_d, row_i)
                    if d <= OPRA_CUTOFF_DATE and src != "exact":
                        exec_fallbacks_opra += 1
                    sell_px = rb.exec_sell_price(bid, ask, mid, exec_mode)
                    ex_usd = _record_exit(tr, i, rem_d, bid, ask, mid, sell_px, trade_qsrc)
                    if tr["exit_reason"].startswith("roll_"):
                        prev_cap = min(3, int(m7g_w[i - 1]))
                        prev_aff = (float(sim_rows_w[i - 1]["vxn"]) <= 27.0 and float(sim_rows_w[i - 1]["vix_ratio"]) < 1.02)
                        if prev_cap > len(still_m7) + len(m7_roll_reps) and prev_aff and not m7_locked_prev_eod:
                            m7_roll_reps.append((ex_usd, prev_cap, bool(m4_w[i - 1])))
                        elif ex_usd > 1e-10:
                            core_shares += ex_usd / (cl * (1.0 + STOCK_REBAL_FEE))
                    else:
                        if ex_usd > 1e-10:
                            core_shares += ex_usd / (cl * (1.0 + STOCK_REBAL_FEE))
                m7_active = still_m7
                for salv_u, cap_sl, is_cta_r in m7_roll_reps:
                    nt = _open_tranche(
                        i, "m7", is_cta_r, 0.0125,
                        90 if is_cta_r else 125,
                        30 if is_cta_r else 75,
                        cap_sl, salv=salv_u,
                    )
                    if nt is not None:
                        m7_active.append(nt)

            # 1B. Pending T+1 Close Exits for Book B (0.20% Base Floor)
            if i > 0 and base_active:
                still_base = [t for t in base_active if not t["pending_exit"]]
                base_roll_cash = 0.0
                want_base_reopen = False
                for tr in base_active:
                    if not tr["pending_exit"]:
                        continue
                    rem_d = max(0, (tr["exp_dt"] - dt_objs[i]).days)
                    bid, ask, mid, iv, dl, src, trade_qsrc = _lookup_contract(d, tr, cl, rem_d, row_i)
                    if d <= OPRA_CUTOFF_DATE and src != "exact":
                        exec_fallbacks_opra += 1
                    sell_px = rb.exec_sell_price(bid, ask, mid, exec_mode)
                    ex_usd = _record_exit(tr, i, rem_d, bid, ask, mid, sell_px, trade_qsrc)
                    if tr["exit_reason"] == "roll_75d":
                        if bool(base_gate_w[i - 1]) and len(still_base) == 0 and (not want_base_reopen) and (not base_locked_prev_eod):
                            want_base_reopen = True
                            base_roll_cash += ex_usd
                        elif ex_usd > 1e-10:
                            core_shares += ex_usd / (cl * (1.0 + STOCK_REBAL_FEE))
                    else:
                        if ex_usd > 1e-10:
                            core_shares += ex_usd / (cl * (1.0 + STOCK_REBAL_FEE))
                base_active = still_base
                if want_base_reopen:
                    nt = _open_tranche(i, "base", False, 0.0020, 125, 75, 1, salv=base_roll_cash)
                    if nt is not None:
                        base_active.append(nt)

            # 2A. Pending New M7 Entry at T+1 Close
            if i > 0 and pending_m7_sig is not None and len(m7_active) < pending_m7_sig["cap_slots"]:
                is_cta_n = bool(pending_m7_sig["is_cta"])
                nt = _open_tranche(
                    i, "m7", is_cta_n, 0.0125,
                    90 if is_cta_n else 125,
                    30 if is_cta_n else 75,
                    pending_m7_sig["cap_slots"], salv=0.0,
                )
                if nt is not None:
                    m7_active.append(nt)
            pending_m7_sig = None

            # 2B. Pending New Base Entry at T+1 Close
            if i > 0 and pending_base_open and len(base_active) == 0:
                nt = _open_tranche(i, "base", False, 0.0020, 125, 75, 1, salv=0.0)
                if nt is not None:
                    base_active.append(nt)
            pending_base_open = False

            # 3. Dividends (DRIP)
            if div > 0.0 and core_shares > 0.0:
                core_shares += (core_shares * div) / (cl * (1.0 + STOCK_REBAL_FEE))

            # 4. EOD Expiries (safety fallback)
            for bl in (m7_active, base_active):
                still_tmp = []
                for tr in bl:
                    if rb.is_expiry_day(i, dt_objs, tr["exp_dt"]):
                        intr = max(0.0, tr["strike"] - cl)
                        tr["exit_reason"] = "expiry_itm" if intr > 0 else "expiry_otm"
                        ex_u = _record_exit(
                            tr, i, 0, intr, intr, intr, intr,
                            "REAL_OPRA" if d <= OPRA_CUTOFF_DATE else "BSM_SIM_2026",
                        )
                        if ex_u > 0.0:
                            core_shares += ex_u / (cl * (1.0 + STOCK_REBAL_FEE))
                    else:
                        still_tmp.append(tr)
                bl[:] = still_tmp

            # 5. Daily MTM & EOD TP / Hard-Roll Signals
            gate_ok_today = bool(base_gate_w[i])
            any_tp_today = False
            tp_triggers_today: list[str] = []

            m7_mtm_tot = 0.0
            for tr in m7_active:
                rem_d = max(1, (tr["exp_dt"] - dt_objs[i]).days)
                bid, ask, mid, iv, dl, _, _ = _lookup_contract(d, tr, cl, rem_d, row_i)
                if np.isfinite(iv) and iv > 0.05:
                    tr["last_iv"] = iv
                val_u = tr["hedged_shares"] * mid
                tr["last_mtm_usd"] = val_u
                tr["last_mid"] = mid
                tr["last_rem_days"] = rem_d
                m7_mtm_tot += val_u
                if not tr["pending_exit"]:
                    trig, rsn = check_tp_near_itm_late5x(vix_cl, vix_r, cl, tr, rem_d, mid, is_base=False)
                    if trig:
                        tr["pending_exit"] = True
                        tr["exit_reason"] = rsn
                        any_tp_today = True
                        tp_triggers_today.append(f"m7:{rsn}")
                    elif rem_d <= tr["roll_dte"]:
                        tr["pending_exit"] = True
                        tr["exit_reason"] = f"roll_{tr['roll_dte']}d"

            base_mtm_tot = 0.0
            for tr in base_active:
                rem_d = max(1, (tr["exp_dt"] - dt_objs[i]).days)
                bid, ask, mid, iv, dl, _, _ = _lookup_contract(d, tr, cl, rem_d, row_i)
                if np.isfinite(iv) and iv > 0.05:
                    tr["last_iv"] = iv
                val_u = tr["hedged_shares"] * mid
                tr["last_mtm_usd"] = val_u
                tr["last_mid"] = mid
                tr["last_rem_days"] = rem_d
                base_mtm_tot += val_u
                if not tr["pending_exit"]:
                    trig, rsn = check_tp_near_itm_late5x(vix_cl, vix_r, cl, tr, rem_d, mid, is_base=True)
                    if trig:
                        tr["pending_exit"] = True
                        tr["exit_reason"] = rsn
                        any_tp_today = True
                        tp_triggers_today.append(f"base:{rsn}")
                    elif rem_d <= 75:
                        tr["pending_exit"] = True
                        tr["exit_reason"] = "roll_75d" if gate_ok_today else "salvage_vix_expensive"

            core_nav_list.append(core_shares * cl + m7_mtm_tot + base_mtm_tot)
            active_puts_cnt_by_day[i] = len(m7_active) + len(base_active)

            # 5.5 Strictly Causal 5D Post-TP Contango Lockout (BOTH books)
            if any_tp_today:
                last_tp_d_seen = d
                if not post_tp_lockout:
                    cur_ep = {
                        "start_signal_date": d,
                        "start_idx": i,
                        "triggers": list(tp_triggers_today),
                        "start_vix": round(vix_cl, 2),
                        "start_vr": round(vix_r, 3),
                        "start_spot": round(cl, 2),
                        "unlock_eod_date": None,
                        "trading_days_locked": 0,
                    }
                    lockout_episodes.append(cur_ep)
                else:
                    if cur_ep is not None:
                        cur_ep["triggers"].extend(tp_triggers_today)
                post_tp_lockout = True
                non_inv_streak = 0
                lockout_days_total += 1
                if cur_ep is not None:
                    cur_ep["trading_days_locked"] += 1
            elif post_tp_lockout:
                if vix_r < 1.00:
                    non_inv_streak += 1
                    if non_inv_streak >= 5:
                        post_tp_lockout = False
                        non_inv_streak = 0
                        if cur_ep is not None:
                            cur_ep["unlock_eod_date"] = d
                            cur_ep["unlock_vix"] = round(vix_cl, 2)
                            cur_ep["unlock_vr"] = round(vix_r, 3)
                            cur_ep["cal_days_locked"] = (dt_objs[i] - dt_objs[cur_ep["start_idx"]]).days
                            cur_ep = None
                    else:
                        lockout_days_total += 1
                        if cur_ep is not None:
                            cur_ep["trading_days_locked"] += 1
                else:
                    non_inv_streak = 0
                    lockout_days_total += 1
                    if cur_ep is not None:
                        cur_ep["trading_days_locked"] += 1

            lock_active_by_day[i] = post_tp_lockout
            lock_streak_by_day[i] = non_inv_streak
            last_tp_by_day[i] = last_tp_d_seen
            m7_locked_prev_eod = post_tp_lockout
            base_locked_prev_eod = post_tp_lockout

            # 6A. M7G Graded Entry Signal -> T+1 Close
            cap_slots = min(3, int(m7g_w[i]))
            eff_m7 = [t for t in m7_active if not t["pending_exit"]]
            if cap_slots > len(eff_m7) and vxn_cl <= 27.0 and vix_r < 1.02 and (not post_tp_lockout):
                req_gap = 21 if cap_slots == 3 else 30
                last_dt = max((t["entry_dt"] for t in eff_m7), default=None)
                if last_dt is None or (dt_objs[i] - last_dt).days >= req_gap:
                    pending_m7_sig = {"cap_slots": cap_slots, "is_cta": bool(m4_w[i])}

            # 6B. Base Floor Entry Signal -> T+1 Close
            if gate_ok_today and (not post_tp_lockout):
                eff_b = [t for t in base_active if not t["pending_exit"]]
                if len(eff_b) == 0:
                    pending_base_open = True

        # Open puts at window end
        open_puts_at_end: list[dict[str, Any]] = []
        for tr in m7_active + base_active:
            open_puts_at_end.append({
                "tranche_id": tr["tranche_id"],
                "sleeve": tr["sleeve"],
                "book": tr["book"],
                "slot_cap": tr["slot_cap"],
                "entry_date": tr["entry_date"],
                "exp": tr["exp"],
                "strike": round(float(tr["strike"]), 2),
                "entry_dte": int(tr["entry_dte"]),
                "rem_dte": int(tr["last_rem_days"]),
                "entry_spot": round(float(tr["entry_spot"]), 2),
                "entry_fill": round(float(tr["entry_fill"]), 3),
                "entry_bid": round(float(tr["entry_bid"]), 2),
                "entry_ask": round(float(tr["entry_ask"]), 2),
                "entry_mid": round(float(tr["entry_mid"]), 2),
                "entry_hs_pct": tr["entry_hs_pct"],
                "entry_lot_pct": tr["entry_lot_pct"],
                "entry_sk20_10": tr["entry_sk20_10"],
                "entry_vix": tr["entry_vix"],
                "entry_vr": tr["entry_vr"],
                "cost_usd": round(float(tr["entry_cost_usd"]), 2),
                "last_mtm_usd": round(float(tr["last_mtm_usd"]), 2),
                "contracts": round(float(tr["hedged_shares"]) / 100.0, 2),
                "quote_source": tr["quote_source"],
            })

        # ------------------------------------------------------------------
        # LAYER 2: 20% Dual-CTA Box Stack + User's CONT_2M 5-Tranche 365D LTCG Rotation (NO Daily 1.20x Forced Cap)
        # ------------------------------------------------------------------
        core_nav_arr = np.asarray(core_nav_list, dtype=float)
        r_core = np.concatenate([[0.0], np.diff(core_nav_arr) / core_nav_arr[:-1]])

        tot_w = 0.20
        cta_w_tgt = {"DBMF": 0.10, "KMLM": 0.10}
        cta_r_map = {"DBMF": r_db_w, "KMLM": r_km_w}
        cta_px_map = {"DBMF": px_db_w, "KMLM": px_km_w}

        nav_arr = np.zeros(n, dtype=float)
        lev_arr = np.zeros(n, dtype=float)
        ltv_arr = np.zeros(n, dtype=float)
        cta_rot_mask_by_day = [0] * n

        core_val = INITIAL_CAPITAL
        rot_q_val = 0.0
        cta_vals = {"DBMF": INITIAL_CAPITAL * 0.10, "KMLM": INITIAL_CAPITAL * 0.10}
        loan = INITIAL_CAPITAL * tot_w
        nav_arr[0] = INITIAL_CAPITAL
        lev_arr[0] = 1.20
        ltv_arr[0] = loan / (core_val + cta_vals["DBMF"] + cta_vals["KMLM"])

        tot_interest = 0.0
        interest_opra = 0.0
        cta_sched: dict[str, dict[str, Any] | None] = {"DBMF": None, "KMLM": None}
        cta_locks: list[dict[str, Any]] = []
        dd_timer_start_dt: datetime.date | None = None
        cta_rot_ledger: list[dict[str, Any]] = []
        cta_restore_ledger: list[dict[str, Any]] = []
        cta_gate_audit: list[dict[str, Any]] = []

        run_ath_px_l2 = float(px_qqq_w[0])
        run_ath_idx_l2 = 0
        dd_arr_l2 = np.zeros(n, dtype=float)

        for i in range(1, n):
            cal_days = max(1, (dt_objs[i] - dt_objs[i - 1]).days)
            core_val *= 1.0 + float(r_core[i])
            rot_q_val *= 1.0 + float(r_qqq_w[i])
            for sl_n in ("DBMF", "KMLM"):
                cta_vals[sl_n] *= 1.0 + float(cta_r_map[sl_n][i])
            int_today = loan * max(0.0, float(effr_w[i - 1]) + fin_spread) * (cal_days / 360.0)
            loan += int_today
            tot_interest += int_today
            if dates[i] <= OPRA_CUTOFF_DATE:
                interest_opra += int_today

            if px_qqq_w[i] >= run_ath_px_l2:
                run_ath_px_l2 = float(px_qqq_w[i])
                run_ath_idx_l2 = i
            dd_arr_l2[i] = px_qqq_w[i] / max(run_ath_px_l2, 1e-6) - 1.0
            dd_prev = float(dd_arr_l2[i - 1])

            # Execute scheduled CONT_2M 5-tranche rotations into pure QQQ (cancel remaining if DD > -12.0%)
            for sl_n in ("DBMF", "KMLM"):
                sch = cta_sched[sl_n]
                if sch is None:
                    continue
                if sch["next_ptr"] < len(sch["exec_idxs"]) and i >= sch["exec_idxs"][sch["next_ptr"]]:
                    if dd_prev >= -0.12:
                        cta_sched[sl_n] = None
                        continue
                    rem_cnt = len(sch["exec_idxs"]) - sch["next_ptr"]
                    sell_amt = cta_vals[sl_n] / float(rem_cnt)
                    if sell_amt > 1.0:
                        cta_vals[sl_n] -= sell_amt
                        rot_q_val += sell_amt * (1.0 - CTA_REBAL_FEE) * (1.0 - CTA_REBAL_FEE)
                        tranche_num = sch["next_ptr"] + 1
                        cta_locks.append({
                            "sleeve": sl_n,
                            "buy_dt": dt_objs[i],
                            "buy_date": dates[i],
                            "target_w_slice": cta_w_tgt[sl_n] / 5.0,
                        })
                        cta_rot_ledger.append({
                            "date": dates[i],
                            "exec_date": dates[i],
                            "sleeve": sl_n,
                            "tranche": int(tranche_num),
                            "sold_usd": round(float(sell_amt), 2),
                            "qqq_dd_pct": round(dd_prev * 100.0, 2),
                            "asset_ret_pct": round(float(sch.get("trig_ret_pct") or 0.0), 2),
                            "cont_days": int(sch.get("cont_days") or 60),
                            "restore_due": (dt_objs[i] + datetime.timedelta(days=365)).isoformat(),
                            "reason": "cont_2m_cta_to_qqq",
                        })
                    sch["next_ptr"] += 1
                    if sch["next_ptr"] >= len(sch["exec_idxs"]):
                        cta_sched[sl_n] = None

            # Mechanical 365-calendar-day LTCG restoration back to 10% DBMF + 10% KMLM
            if cta_locks:
                still_l = []
                mat: dict[str, list[dict[str, Any]]] = {"DBMF": [], "KMLM": []}
                for lt in cta_locks:
                    if (dt_objs[i] - lt["buy_dt"]).days >= 365:
                        mat[lt["sleeve"]].append(lt)
                    else:
                        still_l.append(lt)
                cta_locks = still_l
                for sl_n in ("DBMF", "KMLM"):
                    if not mat[sl_n]:
                        continue
                    nv_now = max(1.0, core_val + rot_q_val + cta_vals["DBMF"] + cta_vals["KMLM"] - loan)
                    add_w = sum(x["target_w_slice"] for x in mat[sl_n])
                    tgt_sl = min(cta_w_tgt[sl_n] * nv_now, cta_vals[sl_n] + add_w * nv_now)
                    buy_need = max(0.0, tgt_sl - cta_vals[sl_n])
                    if buy_need > 1.0:
                        fq1 = min(rot_q_val, buy_need / (1.0 - CTA_REBAL_FEE))
                        rot_q_val -= fq1
                        raised = fq1 * (1.0 - CTA_REBAL_FEE)
                        rem_need = buy_need - raised
                        if rem_need > 1e-6:
                            loan += rem_need
                            raised += rem_need
                        restored_usd = raised * (1.0 - CTA_REBAL_FEE)
                        cta_vals[sl_n] += restored_usd
                        hold_d = int((dt_objs[i] - mat[sl_n][0]["buy_dt"]).days)
                        cta_restore_ledger.append({
                            "date": dates[i],
                            "sleeve": sl_n,
                            "tranches": len(mat[sl_n]),
                            "lots_matured": len(mat[sl_n]),
                            "restored_usd": round(float(restored_usd), 2),
                            "hold_days": hold_d,
                            "vix_eod": round(float(vix_w[i]), 2),
                            "reason": "1y_mechanical_restore",
                        })

            # Quarterly calm calibration when no rotation/lock active (restores 1.200x target, NO daily crash cap!)
            calm_rebal = (not cta_locks) and (cta_sched["DBMF"] is None) and (cta_sched["KMLM"] is None)
            if calm_rebal and i < n - 1:
                q_cur = (int(dates[i][5:7]) - 1) // 3
                q_nxt = (int(dates[i + 1][5:7]) - 1) // 3
                if q_cur != q_nxt or dates[i][:4] != dates[i + 1][:4]:
                    cur_eq = max(1.0, core_val + rot_q_val + cta_vals["DBMF"] + cta_vals["KMLM"] - loan)
                    d_tr = (
                        abs(cur_eq - (core_val + rot_q_val))
                        + abs(cur_eq * 0.10 - cta_vals["DBMF"])
                        + abs(cur_eq * 0.10 - cta_vals["KMLM"])
                    )
                    cur_eq_a = max(1.0, cur_eq - d_tr * CTA_REBAL_FEE)
                    core_val = cur_eq_a
                    rot_q_val = 0.0
                    cta_vals["DBMF"] = cur_eq_a * 0.10
                    cta_vals["KMLM"] = cur_eq_a * 0.10
                    loan = cur_eq_a * tot_w

            gross_v = core_val + rot_q_val + cta_vals["DBMF"] + cta_vals["KMLM"]
            cur_eq = max(1.0, gross_v - loan)
            nav_arr[i] = cur_eq
            lev_arr[i] = gross_v / cur_eq
            ltv_arr[i] = loan / max(gross_v, 1e-6)
            # Bitmask: 1=DBMF rotated/locked, 2=KMLM rotated/locked
            db_rot = any(lt["sleeve"] == "DBMF" for lt in cta_locks) or (cta_sched["DBMF"] is not None)
            km_rot = any(lt["sleeve"] == "KMLM" for lt in cta_locks) or (cta_sched["KMLM"] is not None)
            cta_rot_mask_by_day[i] = (1 if db_rot else 0) | (2 if km_rot else 0)

            # EOD causal CONT_2M 60-calendar-day continuous DD <= -12.0% timer
            if i < n - 1:
                has_av = any(cta_sched[sl_n] is None and cta_vals[sl_n] > 0.01 * cur_eq for sl_n in ("DBMF", "KMLM"))
                if run_ath_idx_l2 == i or dd_arr_l2[i] > -0.12:
                    dd_timer_start_dt = None
                else:
                    if dd_timer_start_dt is None:
                        if has_av:
                            dd_timer_start_dt = dt_objs[i]
                    else:
                        cont_days_now = (dt_objs[i] - dd_timer_start_dt).days
                        if cont_days_now >= 60:
                            for sl_n in ("DBMF", "KMLM"):
                                if cta_sched[sl_n] is None and cta_vals[sl_n] > 0.01 * cur_eq:
                                    c_ret = float(cta_px_map[sl_n][i] / max(cta_px_map[sl_n][run_ath_idx_l2], 1e-6) - 1.0)
                                    ok_rot = bool(c_ret > 0.0)
                                    cta_gate_audit.append({
                                        "trigger_date": dates[i],
                                        "ath_date": dates[run_ath_idx_l2],
                                        "sleeve": sl_n,
                                        "qqq_dd_pct": round(float(dd_arr_l2[i]) * 100.0, 2),
                                        "asset_ret_pct": round(c_ret * 100.0, 2),
                                        "cont_days": int(cont_days_now),
                                        "decision": "ROTATE_5TRANCHE" if ok_rot else "HOLD_CTA_NEG_RET",
                                    })
                                    if ok_rot:
                                        cta_sched[sl_n] = {
                                            "exec_idxs": [min(n - 1, i + 1 + 5 * k) for k in range(5)],
                                            "next_ptr": 0,
                                            "trig_ret_pct": round(c_ret * 100.0, 2),
                                            "cont_days": int(cont_days_now),
                                        }
                            dd_timer_start_dt = None

        latch_eps_w = [ep for ep in all_latch_episodes if ep["arm_date"] >= start_d]

        qqq_nav = INITIAL_CAPITAL * (px_qqq_w / px_qqq_w[0])

        def calc_kpi(arr: Any, dt_sub: list[datetime.date], effr_sub: Any) -> dict[str, Any]:
            yrs_s = max(1e-6, (dt_sub[-1] - dt_sub[0]).days / 365.25)
            cagr = (float(arr[-1]) / INITIAL_CAPITAL) ** (1.0 / yrs_s) - 1.0
            dd_s = arr / np.maximum.accumulate(arr) - 1.0
            mdd = float(dd_s.min())
            calmar = cagr / abs(mdd) if mdd < 0 else 0.0
            dr = np.diff(arr) / arr[:-1]
            ex_r = dr - effr_sub[:-1] / 252.0
            sharpe = float(np.mean(ex_r) / max(np.std(ex_r, ddof=1), 1e-12) * math.sqrt(252.0))
            dn = ex_r[ex_r < 0.0]
            sortino = float(np.mean(ex_r) / max(np.sqrt(np.mean(dn * dn)), 1e-12) * math.sqrt(252.0)) if len(dn) else 0.0
            ann_vol = float(np.std(dr, ddof=1) * math.sqrt(252.0))
            return {
                "end_nav": round(float(arr[-1]), 2),
                "total_return_pct": round((float(arr[-1]) / INITIAL_CAPITAL - 1.0) * 100.0, 2),
                "cagr_pct": round(cagr * 100.0, 2),
                "max_dd_pct": round(mdd * 100.0, 2),
                "calmar": round(calmar, 3),
                "sharpe": round(sharpe, 3),
                "sortino": round(sortino, 3),
                "ann_vol_pct": round(ann_vol * 100.0, 2),
            }

        def enrich_kpi(
            ks: dict[str, Any],
            kq: dict[str, Any],
            nav_sub: Any,
            lev_sub: Any,
            ltv_sub: Any,
            dt_sub: list[datetime.date],
            puts_sub: list[dict[str, Any]],
            rot_sub: list[dict[str, Any]],
            res_sub: list[dict[str, Any]],
            int_sub: float,
            lk_eps_sub: list[dict[str, Any]],
            lk_days_sub: int,
            fallbacks_n: int,
            sim_days_n: int,
        ) -> dict[str, Any]:
            out = dict(ks)
            yrs_s = max(1e-6, (dt_sub[-1] - dt_sub[0]).days / 365.25)
            tot_c = sum(t["cost_usd"] for t in puts_sub)
            tot_e = sum(t["exit_usd"] for t in puts_sub)
            base_tr = [t for t in puts_sub if t["sleeve"] == "base"]
            r1_tr = [t for t in puts_sub if t["sleeve"] == "crisis"]
            m4_tr = [t for t in puts_sub if t["sleeve"] == "crisis_m4"]
            tp_tr = [t for t in puts_sub if "tp_" in t["exit_reason"]]
            non_tp_tr = [t for t in puts_sub if "tp_" not in t["exit_reason"]]
            sim_tr = [t for t in puts_sub if t.get("quote_source") == "BSM_SIM_2026"]

            non_tp_cost = sum(t["cost_usd"] for t in non_tp_tr)
            non_tp_exit = sum(t["exit_usd"] for t in non_tp_tr)
            roll_salvage_pct = (non_tp_exit / non_tp_cost * 100.0) if non_tp_cost > 1e-6 else 0.0
            gross_turn_pct_yr = (
                sum(t["cost_usd"] / max(t.get("nav_at_entry", INITIAL_CAPITAL), 1.0) for t in puts_sub) / yrs_s * 100.0
            )
            true_net_bleed_pct_yr = (
                sum((t["cost_usd"] - t["exit_usd"]) / max(t.get("nav_at_entry", INITIAL_CAPITAL), 1.0) for t in non_tp_tr)
                / yrs_s
                * 100.0
            )
            ann_int_pct = (int_sub / max(float(np.mean(nav_sub)), 1.0)) / yrs_s * 100.0
            peak_ltv = float(np.max(ltv_sub)) * 100.0

            out.update({
                "net_alpha_usd": round(out["end_nav"] - kq["end_nav"], 2),
                "cagr_alpha_pp": round(out["cagr_pct"] - kq["cagr_pct"], 2),
                "mdd_cushion_pp": round(out["max_dd_pct"] - kq["max_dd_pct"], 2),
                "peak_gross_leverage": round(float(lev_sub.max()), 4),
                "avg_gross_leverage": round(float(lev_sub.mean()), 3),
                "peak_ltv_pct": round(peak_ltv, 2),
                "min_equity_ratio_pct": round(100.0 - peak_ltv, 2),
                "ann_box_interest_pct_nav": round(ann_int_pct, 2),
                "put_trades_total": len(puts_sub),
                "put_trades_base": len(base_tr),
                "put_trades_route1": len(r1_tr),
                "put_trades_m4": len(m4_tr),
                "put_trades_sim_ext": len(sim_tr),
                "put_tp_count": len(tp_tr),
                "put_roll_count": len(non_tp_tr),
                "put_cost_usd": round(tot_c, 2),
                "put_exit_usd": round(tot_e, 2),
                "put_net_pnl_usd": round(tot_e - tot_c, 2),
                "put_payoff_mult": round(tot_e / tot_c, 2) if tot_c > 1e-6 else 0.0,
                "put_gross_turnover_pct_nav_yr": round(gross_turn_pct_yr, 2),
                "put_roll_salvage_pct": round(roll_salvage_pct, 1),
                "put_true_net_bleed_pct_nav_yr": round(true_net_bleed_pct_yr, 2),
                "cta_rotation_count": len(rot_sub),
                "cta_reload_count": len(res_sub),
                "lockout_episodes_count": len(lk_eps_sub),
                "lockout_trading_days": int(lk_days_sub),
                "execution_fallbacks": int(fallbacks_n),
                "sim_extension_days": int(sim_days_n),
            })
            return out

        sim_days = sum(1 for d_k in dates if d_k > OPRA_CUTOFF_DATE)
        kpi_q = calc_kpi(qqq_nav, dt_objs, effr_w)
        kpi_s = enrich_kpi(
            calc_kpi(nav_arr, dt_objs, effr_w), kpi_q, nav_arr, lev_arr, ltv_arr, dt_objs,
            put_ledger, cta_rot_ledger, cta_restore_ledger, tot_interest,
            lockout_episodes, lockout_days_total, exec_fallbacks_opra, sim_days,
        )

        # Immutable pure real-OPRA audited snapshot through 2025-12-15
        opra_cut_idx = max((idx_k for idx_k, d_k in enumerate(dates) if d_k <= OPRA_CUTOFF_DATE), default=n - 1)
        kpi_opra_q = calc_kpi(qqq_nav[: opra_cut_idx + 1], dt_objs[: opra_cut_idx + 1], effr_w[: opra_cut_idx + 1])
        lk_eps_opra = [ep for ep in lockout_episodes if ep["start_signal_date"] <= OPRA_CUTOFF_DATE]
        lk_days_opra = sum(1 for j in range(opra_cut_idx + 1) if lock_active_by_day[j])
        kpi_opra_s = enrich_kpi(
            calc_kpi(nav_arr[: opra_cut_idx + 1], dt_objs[: opra_cut_idx + 1], effr_w[: opra_cut_idx + 1]),
            kpi_opra_q,
            nav_arr[: opra_cut_idx + 1],
            lev_arr[: opra_cut_idx + 1],
            ltv_arr[: opra_cut_idx + 1],
            dt_objs[: opra_cut_idx + 1],
            [t for t in put_ledger if t["exit_date"] <= OPRA_CUTOFF_DATE],
            [c for c in cta_rot_ledger if c["date"] <= OPRA_CUTOFF_DATE],
            [r for r in cta_restore_ledger if r["date"] <= OPRA_CUTOFF_DATE],
            interest_opra,
            lk_eps_opra,
            lk_days_opra,
            exec_fallbacks_opra,
            0,
        )

        # Crisis comparison table (8 Real OPRA episodes + 2026.11 BSM Extension)
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
            win_puts = [t for t in put_ledger if cs <= t["exit_date"] <= ce and "tp_" in t["exit_reason"]]
            win_m4 = [t for t in put_ledger if cs <= t["entry_date"] <= ce and t["sleeve"] == "crisis_m4"]
            win_cta = [c for c in cta_rot_ledger if cs <= c["date"] <= ce]
            crisis_rows.append({
                "id": cid,
                "name_en": cname_en,
                "name_zh": cname_zh,
                "start_date": dates[i0],
                "end_date": dates[i1],
                "is_sim_extension": bool(cs > OPRA_CUTOFF_DATE),
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

        # Compact daily event bitmask:
        #   1 = Base 0.20% Open | 2 = M7G Crisis Open | 4 = Put TP | 8 = Hard Roll/Salvage | 16 = CTA Rotate/Reload
        evt_by_d: dict[str, int] = {}
        for tr in put_ledger:
            ed, xd = tr["entry_date"], tr["exit_date"]
            evt_by_d[ed] = evt_by_d.get(ed, 0) | (1 if tr["sleeve"] == "base" else 2)
            if "tp_" in tr["exit_reason"]:
                evt_by_d[xd] = evt_by_d.get(xd, 0) | 4
            else:
                evt_by_d[xd] = evt_by_d.get(xd, 0) | 8
        for tr in open_puts_at_end:
            ed = tr["entry_date"]
            evt_by_d[ed] = evt_by_d.get(ed, 0) | (1 if tr["sleeve"] == "base" else 2)
        for cr in cta_rot_ledger:
            evt_by_d[cr["date"]] = evt_by_d.get(cr["date"], 0) | 16
        for rs in cta_restore_ledger:
            evt_by_d[rs["date"]] = evt_by_d.get(rs["date"], 0) | 16

        dd_s_arr = (nav_arr / np.maximum.accumulate(nav_arr) - 1.0) * 100.0
        dd_q_arr = (qqq_nav / np.maximum.accumulate(qqq_nav) - 1.0) * 100.0

        series_rows = []
        for k in range(n):
            pr_k = existing_pit_by_d.get(dates[k]) or {}
            series_rows.append({
                "date": dates[k],
                "nav_v2": round(float(nav_arr[k]), 2),
                "nav_qqq": round(float(qqq_nav[k]), 2),
                "dd_v2": round(float(dd_s_arr[k]), 2),
                "dd_qqq": round(float(dd_q_arr[k]), 2),
                "lev": round(float(lev_arr[k]), 4),
                "qqq": round(float(sim_rows_w[k]["close"]), 2),
                "vr": round(float(vr_w[k]), 3),
                "latch": 1 if bool(pr_k.get("latch")) else 0,
                "cta_rot": 1 if cta_rot_mask_by_day[k] > 0 else 0,
                "evt": int(evt_by_d.get(dates[k], 0)),
            })

        return {
            "kpi": kpi_s,
            "kpi_qqq": kpi_q,
            "kpi_opra_verified": kpi_opra_s,
            "kpi_opra_verified_qqq": kpi_opra_q,
            "opra_cutoff_date": OPRA_CUTOFF_DATE,
            "sim_extension_days": int(sim_days),
            "end_date": dates[-1],
            "crisis_comparison": crisis_rows,
            "daily_series": pack_table(
                series_rows,
                ["date", "nav_v2", "nav_qqq", "dd_v2", "dd_qqq", "lev", "qqq", "vr", "latch", "cta_rot", "evt"],
            ),
            "put_ledger": put_ledger,
            "open_puts_at_end": open_puts_at_end,
            "cta_rotation_ledger": cta_rot_ledger,
            "cta_restore_ledger": cta_restore_ledger,
            "cta_gate_audit_ledger": cta_gate_audit,
            "latch_episodes": latch_eps_w,
            "lockout_episodes": lockout_episodes,
            "_day_state": {
                "dates": dates,
                "lock_active": lock_active_by_day,
                "lock_streak": lock_streak_by_day,
                "last_tp": last_tp_by_day,
                "cta_rot_mask": cta_rot_mask_by_day,
                "active_puts_cnt": active_puts_cnt_by_day,
                "m7g_slots": m7g_w,
                "m4_flags": m4_w,
            },
        }

    # Build BOTH windows (Primary IBKR Limit + SPX Box 35bp & Stress Full Ask/Bid + IBKR Pro 150bp)
    w11_pri = run_taleb_champion_window("11y_opra", "2015-01-02", False, "real_ibkr_limit", BOX_SPREAD)
    w11_str = run_taleb_champion_window("11y_opra", "2015-01-02", False, "real_ask_bid", IBKR_SPREAD)
    w5_pri = run_taleb_champion_window("5y_live", "2020-12-03", True, "real_ibkr_limit", BOX_SPREAD)
    w5_str = run_taleb_champion_window("5y_live", "2020-12-03", True, "real_ask_bid", IBKR_SPREAD)

    # Synchronize & enrich pit_daily_index with exact Plan D Double-Champion state:
    #   - PRESERVES +8% Slow-Bear Hysteresis Latch (latch, latch_arm, latch_pk, abv200) & CONT_2M timer (c2m_d, c2m_s)
    #   - Updates Uniform -15% OTM 90D Put pricing (p90_*)
    #   - Syncs exact B020_M125 5D Post-TP Lockout state (tp_lock, tp_lstrk, last_tp), cta_rot, m7g_slots, active_puts
    #   - Adds per-ETF since-ATH correlation vs QQQ (db_corr_ath, km_corr_ath)
    ds11 = w11_pri["_day_state"]
    day_state_by_d = {
        ds11["dates"][k]: {
            "tp_lock": 1 if ds11["lock_active"][k] else 0,
            "tp_lstrk": int(ds11["lock_streak"][k]),
            "last_tp": ds11["last_tp"][k],
            "cta_rot": int(ds11["cta_rot_mask"][k]),
            "active_puts": int(ds11["active_puts_cnt"][k]),
            "m7g_slots": int(ds11["m7g_slots"][k]),
        }
        for k in range(len(ds11["dates"]))
    }

    # Compute exact daily since-ATH correlation (DBMF vs QQQ, KMLM vs QQQ) across ext_dates
    db_corr_ath_by_d: dict[str, float] = {}
    km_corr_ath_by_d: dict[str, float] = {}
    run_ath_p = float(px_q_ext[0])
    run_ath_i = 0
    for i, d_k in enumerate(ext_dates):
        if px_q_ext[i] >= run_ath_p:
            run_ath_p = float(px_q_ext[i])
            run_ath_i = i
        lo_c = run_ath_i + 1 if (i - run_ath_i) >= 5 else max(1, i - 19)
        if i >= 3:
            rq_seg = r_q_ext[lo_c : i + 1]
            rdb_seg = r_db_spliced[lo_c : i + 1]
            rkm_seg = r_km_spliced[lo_c : i + 1]
            c_db = (
                float(np.corrcoef(rq_seg, rdb_seg)[0, 1])
                if (len(rq_seg) >= 3 and np.std(rq_seg) > 1e-10 and np.std(rdb_seg) > 1e-10)
                else 0.0
            )
            c_km = (
                float(np.corrcoef(rq_seg, rkm_seg)[0, 1])
                if (len(rq_seg) >= 3 and np.std(rq_seg) > 1e-10 and np.std(rkm_seg) > 1e-10)
                else 0.0
            )
        else:
            c_db, c_km = 0.0, 0.0
        db_corr_ath_by_d[d_k] = round(c_db, 3)
        km_corr_ath_by_d[d_k] = round(c_km, 3)

    pit_rows_v3: list[dict[str, Any]] = []
    last_sk_spot = 132.0
    for r0 in existing_pit_rows:
        d_k = str(r0["date"])
        if d_k not in day_state_by_d:
            continue
        r = dict(r0)
        if d_k in skew_spot_map:
            last_sk_spot = skew_spot_map[d_k]
        elif r.get("skew10") is not None:
            last_sk_spot = float(r["skew10"])
        r["skew_spot"] = round(float(last_sk_spot), 2)

        # Attach Uniform -15% OTM Real OPRA (or post-OPRA calibrated BSM) option microstructure
        om = opra_micro_by_date.get(d_k)
        if om is None:
            effr_dec = float(r.get("effr") or 4.0) / 100.0
            om = compute_bsm_micro_est(
                float(r["qqq"]),
                float(r["vxn"]),
                r_v=effr_dec,
                q_v=0.006,
                vix_v=float(r.get("vix") or 18.0),
                vr_v=float(r.get("vr") or 0.90),
                skew_v=float(last_sk_spot),
            )
        for mk in (
            "opra_src", "opra_sk20_10", "opra_sk15_atm",
            "p125_k", "p125_dte", "p125_bid", "p125_ask", "p125_mid", "p125_lmt", "p125_hs", "p125_iv", "p125_lot_pct", "p125_mid_pct",
            "p90_k", "p90_dte", "p90_bid", "p90_ask", "p90_mid", "p90_lmt", "p90_hs", "p90_iv", "p90_lot_pct", "p90_mid_pct",
        ):
            r[mk] = om.get(mk)

        # Preserve M4_latch_v2 in ent_mask (bit 16) while aligning P1/P2/M3 bits (1,2,4,8,32) with sig_df where available
        m4_v2_bit = 16 if (int(r.get("ent_mask") or 0) & 16) else 0
        if d_k in sig_df.index:
            sr = sig_df.loc[d_k]
            r["ent_mask"] = (
                (1 if bool(sr["M0"]) else 0)
                | (2 if bool(sr["M6"]) else 0)
                | (4 if bool(sr["M2"]) else 0)
                | (8 if bool(sr["M5"]) else 0)
                | m4_v2_bit
                | (32 if bool(sr["M3"]) else 0)
            )

        # Sync exact B020_M125 lockout, CONT_2M CTA rotation, M7G slots, active puts, and since-ATH correlations
        ds_row = day_state_by_d[d_k]
        r["tp_lock"] = ds_row["tp_lock"]
        r["tp_lstrk"] = ds_row["tp_lstrk"]
        r["last_tp"] = ds_row["last_tp"]
        r["cta_rot"] = ds_row["cta_rot"]
        r["active_puts"] = ds_row["active_puts"]
        r["m7g_slots"] = ds_row["m7g_slots"]
        r["db_corr_ath"] = db_corr_ath_by_d.get(d_k, 0.0)
        r["km_corr_ath"] = km_corr_ath_by_d.get(d_k, 0.0)

        pit_rows_v3.append(r)

    pit_cols_v3 = list(pit_rows_v3[0].keys())
    latest_pit = pit_rows_v3[-1]
    latest_date = str(latest_pit["date"])

    # Update live_tail_state cleanly for Node.js live stepping (> 2026-11-25) while PRESERVING latch_state & cont_2m_state!
    live_tail_v3 = dict(old_tail)
    live_tail_v3["opra_skew_coeffs"] = [round(float(c), 6) for c in coeffs]
    live_tail_v3["opra_cal_z13"] = list(OPRA_CAL_Z13)
    live_tail_v3["opra_cal_hs5"] = list(OPRA_CAL_HS5)
    live_tail_v3["put_gate_state"] = {
        "contango_streak": int(latest_pit.get("ct_strk") or 0),
        "post_tp_lockout": bool(latest_pit["tp_lock"]),
        "lockout_streak": int(latest_pit["tp_lstrk"]),
        "last_tp_date": latest_pit["last_tp"],
        "ad_below50": bool(latest_pit["ad_b50"]),
        "cta_rot_mask": int(latest_pit["cta_rot"]),
        "open_puts_strikes": [float(op["strike"]) for op in w11_pri["open_puts_at_end"]],
    }

    roll_econ_11 = {
        "gross_turnover_pct_nav_yr": w11_pri["kpi_opra_verified"]["put_gross_turnover_pct_nav_yr"],
        "roll_salvage_pct": w11_pri["kpi_opra_verified"]["put_roll_salvage_pct"],
        "true_net_bleed_pct_nav_yr": w11_pri["kpi_opra_verified"]["put_true_net_bleed_pct_nav_yr"],
    }

    artifact = {
        "version": ARTIFACT_VERSION,
        "strategy_code": STRATEGY_CODE,
        "put_engine_code": PUT_ENGINE_CODE,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "as_of_date": latest_date,
        "asOfDate": latest_date,
        "dataThrough": latest_date,
        "ruleset": build_ruleset_spec(roll_econ_11),
        "data_freshness": existing_doc.get("data_freshness") or {},
        "backtest": {
            "initial_capital": INITIAL_CAPITAL,
            "opra_provenance": {
                "quotes_count": 6382288,
                "trading_days": 2749,
                "opra_start": "2015-01-02",
                "opra_end": OPRA_CUTOFF_DATE,
                "extended_end": ext_end_date,
                "sim_extension_days": w11_pri["sim_extension_days"],
                "execution_fallbacks": w11_pri["kpi_opra_verified"]["execution_fallbacks"],
                "bsm_calibration": OPRA_BSM_CALIBRATION_REPORT,
                "primary_fill_en": "IBKR 35% Limit + SPX Short Box (EFFR + 35 bps)",
                "primary_fill_zh": "IBKR 35% 限价成交 + SPX Short Box 融资（EFFR + 35 bps）",
                "stress_fill_en": "Full Ask/Bid + IBKR Pro Margin (EFFR + 150 bps)",
                "stress_fill_zh": "保守对手盘 Ask/Bid + IBKR Pro 融资（EFFR + 150 bps）",
            },
            "windows": {
                "11y_opra": {
                    "id": "11y_opra",
                    "label_en": f"12Y Full ({'2015-' + ext_end_date[:7].replace('-', '.')})",
                    "label_zh": f"全周期（2015-{ext_end_date[:7].replace('-', '.')}）",
                    "start_date": "2015-01-02",
                    "end_date": ext_end_date,
                    "opra_cutoff_date": OPRA_CUTOFF_DATE,
                    "sim_extension_days": w11_pri["sim_extension_days"],
                    "zero_splice": False,
                    "disclosure_en": (
                        f"2015-01-02 to {OPRA_CUTOFF_DATE}: 100% real 16:00 ET MIT OPRA QQQ put quotes "
                        f"(audited NAV ${w11_pri['kpi_opra_verified']['end_nav']:,.0f}, "
                        f"{w11_pri['kpi_opra_verified']['cagr_pct']}% CAGR, "
                        f"{w11_pri['kpi_opra_verified']['max_dd_pct']}% MDD, "
                        f"{w11_pri['kpi_opra_verified']['calmar']} Calmar; "
                        f"{roll_econ_11['roll_salvage_pct']}% Hard-75D/30D salvage -> {roll_econ_11['true_net_bleed_pct_nav_yr']}% NAV/yr true net bleed). "
                        f"Post-{OPRA_CUTOFF_DATE} ({w11_pri['sim_extension_days']} sessions to {ext_end_date}): "
                        "100% real market closes (QQQ/DBMF/KMLM/VIX/VXN/EFFR) + OPRA-residual-calibrated Z-surface BSM & half-spread option chain."
                    ),
                    "disclosure_zh": (
                        f"2015-01-02 至 {OPRA_CUTOFF_DATE}：100% 真实美股 16:00 ET OPRA 期权盘口"
                        f"（纯真 OPRA 段终值 ${w11_pri['kpi_opra_verified']['end_nav']:,.0f} / "
                        f"CAGR {w11_pri['kpi_opra_verified']['cagr_pct']}% / "
                        f"MDD {w11_pri['kpi_opra_verified']['max_dd_pct']}% / "
                        f"Calmar {w11_pri['kpi_opra_verified']['calmar']}；"
                        f"75D/30D 强滚回收 {roll_econ_11['roll_salvage_pct']}% 残值，真实净损耗仅 {roll_econ_11['true_net_bleed_pct_nav_yr']}% NAV/yr）。"
                        f"{OPRA_CUTOFF_DATE} 之后（{w11_pri['sim_extension_days']} 个交易日至 {ext_end_date}）："
                        "100% 真实现货与波动率收盘 + OPRA 残差校准 Z-曲面动态 BSM 与半价差模型延展。"
                    ),
                    "kpi_primary": w11_pri["kpi"],
                    "kpi_stress": w11_str["kpi"],
                    "kpi_qqq": w11_pri["kpi_qqq"],
                    "kpi_opra_verified_primary": w11_pri["kpi_opra_verified"],
                    "kpi_opra_verified_stress": w11_str["kpi_opra_verified"],
                    "kpi_opra_verified_qqq": w11_pri["kpi_opra_verified_qqq"],
                    "crisis_comparison": w11_pri["crisis_comparison"],
                    "daily_series": w11_pri["daily_series"],
                    "put_ledger": w11_pri["put_ledger"],
                    "open_puts_at_end": w11_pri["open_puts_at_end"],
                    "cta_rotation_ledger": w11_pri["cta_rotation_ledger"],
                    "cta_restore_ledger": w11_pri["cta_restore_ledger"],
                    "cta_gate_audit_ledger": w11_pri["cta_gate_audit_ledger"],
                    "latch_episodes": w11_pri["latch_episodes"],
                    "lockout_episodes": w11_pri["lockout_episodes"],
                },
                "5y_live": {
                    "id": "5y_live",
                    "label_en": f"6Y Zero-Splice ({'2020.12-' + ext_end_date[:7].replace('-', '.')})",
                    "label_zh": f"零拼接实盘（2020.12-{ext_end_date[:7].replace('-', '.')}）",
                    "start_date": "2020-12-03",
                    "end_date": ext_end_date,
                    "opra_cutoff_date": OPRA_CUTOFF_DATE,
                    "sim_extension_days": w5_pri["sim_extension_days"],
                    "zero_splice": True,
                    "disclosure_en": (
                        f"Zero-splice live ETF window (100% live DBMF + KMLM + NY Fed EFFR): "
                        f"2020-12-03 to {OPRA_CUTOFF_DATE} uses 100% real MIT OPRA puts "
                        f"(audited NAV ${w5_pri['kpi_opra_verified']['end_nav']:,.0f}, "
                        f"{w5_pri['kpi_opra_verified']['cagr_pct']}% CAGR, "
                        f"{w5_pri['kpi_opra_verified']['max_dd_pct']}% MDD, "
                        f"{w5_pri['kpi_opra_verified']['calmar']} Calmar); "
                        f"post-{OPRA_CUTOFF_DATE} ({w5_pri['sim_extension_days']} sessions to {ext_end_date}) uses real spot/vol + OPRA-calibrated Z-surface BSM puts."
                    ),
                    "disclosure_zh": (
                        f"零拼接纯实盘 ETF 窗口（100% 实盘 DBMF + KMLM + 官方 EFFR）："
                        f"2020-12-03 至 {OPRA_CUTOFF_DATE} 为 100% 真实 OPRA 期权盘口"
                        f"（纯真 OPRA 段终值 ${w5_pri['kpi_opra_verified']['end_nav']:,.0f} / "
                        f"CAGR {w5_pri['kpi_opra_verified']['cagr_pct']}% / "
                        f"MDD {w5_pri['kpi_opra_verified']['max_dd_pct']}% / "
                        f"Calmar {w5_pri['kpi_opra_verified']['calmar']}）；"
                        f"{OPRA_CUTOFF_DATE} 之后（至 {ext_end_date}）采用真实现货波动率 + OPRA 残差校准动态 BSM 期权延展。"
                    ),
                    "kpi_primary": w5_pri["kpi"],
                    "kpi_stress": w5_str["kpi"],
                    "kpi_qqq": w5_pri["kpi_qqq"],
                    "kpi_opra_verified_primary": w5_pri["kpi_opra_verified"],
                    "kpi_opra_verified_stress": w5_str["kpi_opra_verified"],
                    "kpi_opra_verified_qqq": w5_pri["kpi_opra_verified_qqq"],
                    "crisis_comparison": w5_pri["crisis_comparison"],
                    "daily_series": w5_pri["daily_series"],
                    "put_ledger": w5_pri["put_ledger"],
                    "open_puts_at_end": w5_pri["open_puts_at_end"],
                    "cta_rotation_ledger": w5_pri["cta_rotation_ledger"],
                    "cta_restore_ledger": w5_pri["cta_restore_ledger"],
                    "cta_gate_audit_ledger": w5_pri["cta_gate_audit_ledger"],
                    "latch_episodes": w5_pri["latch_episodes"],
                    "lockout_episodes": w5_pri["lockout_episodes"],
                },
            },
        },
        "pit_daily_index": pack_table(pit_rows_v3, pit_cols_v3),
        "live_tail_state": live_tail_v3,
    }

    raw_json = json.dumps(artifact, ensure_ascii=False, separators=(",", ":"))
    assert chr(126) not in raw_json, "ASCII tilde found in generated JSON!"
    for banned in (
        "FactOS", "FACT OS", "fact_os", "DuckDB", "Sharadar", "SQLite",
        "Wheel", "wheel", "Covered Call", "Short Put", "卖Call", "领口",
    ):
        assert banned not in raw_json, f"Banned term '{banned}' found in generated JSON!"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(raw_json, encoding="utf-8")
    print(f"Wrote v3.0 Double-Champion (Plan D) artifact {output_path} ({len(raw_json) / 1024:.1f} KB)")
    print(f"  Latest Date: {latest_date} | QQQ=${latest_pit['qqq']} (DD {latest_pit['dd_ath']}%) | VIX={latest_pit['vix']} VXN={latest_pit['vxn']} VR={latest_pit['vr']} | Stress={latest_pit['stress']}/100")
    print(
        f"  11Y Verified OPRA (<=2025-12-15): ${w11_pri['kpi_opra_verified']['end_nav']:,.2f} | "
        f"{w11_pri['kpi_opra_verified']['cagr_pct']}% CAGR | {w11_pri['kpi_opra_verified']['max_dd_pct']}% MDD | "
        f"{w11_pri['kpi_opra_verified']['calmar']} Calmar | PeakLev {w11_pri['kpi_opra_verified']['peak_gross_leverage']}x | "
        f"Gross {w11_pri['kpi_opra_verified']['put_gross_turnover_pct_nav_yr']}% -> Salvage {w11_pri['kpi_opra_verified']['put_roll_salvage_pct']}% -> NetBleed {w11_pri['kpi_opra_verified']['put_true_net_bleed_pct_nav_yr']}%"
    )
    print(
        f"  12Y Full Ext (<=2026-11-25):      ${w11_pri['kpi']['end_nav']:,.2f} | "
        f"{w11_pri['kpi']['cagr_pct']}% CAGR | {w11_pri['kpi']['max_dd_pct']}% MDD | "
        f"{w11_pri['kpi']['calmar']} Calmar | PeakLev {w11_pri['kpi']['peak_gross_leverage']}x | "
        f"Put Trades {w11_pri['kpi']['put_trades_total']} ({w11_pri['kpi']['put_tp_count']} TP) | CTA Rots {w11_pri['kpi']['cta_rotation_count']}"
    )
    print(
        f"  5Y Verified OPRA (<=2025-12-15):  ${w5_pri['kpi_opra_verified']['end_nav']:,.2f} | "
        f"{w5_pri['kpi_opra_verified']['cagr_pct']}% CAGR | {w5_pri['kpi_opra_verified']['max_dd_pct']}% MDD | "
        f"{w5_pri['kpi_opra_verified']['calmar']} Calmar | PeakLev {w5_pri['kpi_opra_verified']['peak_gross_leverage']}x"
    )
    print(
        f"  6Y Zero-Splice Ext (<=2026-11-25):${w5_pri['kpi']['end_nav']:,.2f} | "
        f"{w5_pri['kpi']['cagr_pct']}% CAGR | {w5_pri['kpi']['max_dd_pct']}% MDD | "
        f"{w5_pri['kpi']['calmar']} Calmar | PeakLev {w5_pri['kpi']['peak_gross_leverage']}x"
    )
    return artifact


def run_stdlib_live_refresh(output_path: Path) -> dict[str, Any]:
    """Stdlib-only refresh mode (runs cleanly inside .venv-fact-os without pandas/pyarrow)."""
    if not output_path.exists():
        raise RuntimeError(f"Existing v3 artifact not found at {output_path}")
    doc = json.loads(output_path.read_text(encoding="utf-8"))
    if doc.get("version") != ARTIFACT_VERSION:
        raise RuntimeError("Existing artifact is not v3-taleb-champion; rebuild with pandas/pyarrow environment.")
    doc["generated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    raw_json = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
    assert chr(126) not in raw_json
    output_path.write_text(raw_json, encoding="utf-8")
    print(f"Verified v3 artifact in stdlib mode at {output_path} ({len(raw_json) / 1024:.1f} KB, as_of={doc['as_of_date']})")
    return doc


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build ThesisForge Crisis Observatory v3.0 Original Taleb Champion artifact."
    )
    parser.add_argument("--fact-root", default=str(DEFAULT_FACT_ROOT), help="Compatibility flag for refresh-all-corners.sh")
    parser.add_argument("--output", default=str(DEFAULT_OUT), help="Output JSON path")
    parser.add_argument("--no-live", action="store_true", help="Skip live fetch during build")
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
