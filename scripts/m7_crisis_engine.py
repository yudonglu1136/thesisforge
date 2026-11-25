#!/usr/bin/env python3
"""Zero-Lookahead Three-Pillar Probabilistic Put Overlay Engine (M7-Graded & M7 Ensemble).

Pure Python stdlib implementation (zero numpy/pandas/scipy runtime dependency) matching
run_8models_crisis_study.py bit-for-bit across all 2,990 evaluation days (max HMM diff < 1e-13,
exact penny parity on all M7G & M7 backtest configurations).
"""
from __future__ import annotations

import bisect
import csv
import datetime
import gzip
import io
import json
import math
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_M7_PROFILE = "full_m7_adaptive"
DEFAULT_PUT_OTM = "otm15"
DEFAULT_M7_TP_MODE = "standard"
DEFAULT_ROLL_MODE = "adaptive_120_90"
DEFAULT_M0_ENABLED = True

INITIAL_CAPITAL = 200_000.0
STOCK_REBAL_FEE = 0.0003
OPT_SLIP = 0.025
OPT_SLIP_SP = 0.030
OPT_COMM_PER_SH = 0.0065
MARGIN_SPREAD = 0.015
MIN_OPT_BID = 0.05

try:
    import real_option_chain as _roc_mod
except ImportError:
    _roc_mod = None
    _roc_path = Path(__file__).resolve().parent / "real_option_chain.py"
    if _roc_path.exists():
        import importlib.util as _ilu
        _roc_spec = _ilu.spec_from_file_location("real_option_chain", _roc_path)
        if _roc_spec is not None and _roc_spec.loader is not None:
            _roc_mod = _ilu.module_from_spec(_roc_spec)
            _roc_spec.loader.exec_module(_roc_mod)

YF_ETF_KEYS = ["QQQ", "SPY", "RSP", "IWM", "XLP", "XLU", "XLV", "XLK", "HYG", "LQD"]
YF_IDX_KEYS = ["VXN", "VIX", "VIX3M", "VVIX", "SKEW"]
YF_ALL_KEYS = YF_ETF_KEYS + YF_IDX_KEYS
YF_TICKER_MAP = {k: (f"^{k}" if k in YF_IDX_KEYS else k) for k in YF_ALL_KEYS}
FRED_LAGS = {"BAA10Y": 1, "DGS2": 1, "NFCI": 5}

PUT_OTM_SPECS: list[dict[str, Any]] = [
    {
        "id": "otm15",
        "moneyness": 0.85,
        "otm_pct": 15,
        "label_en": "-15% OTM (Default · Core Shield)",
        "label_zh": "-15% OTM（默认主力 · 稳健均衡）",
        "short_en": "-15% OTM",
        "short_zh": "-15% OTM",
        "summary_en": "Spends the 50% -10% OTM reference dollar budget on 90-DTE -15% OTM Puts ($1,682,250 NAV, -28.02% MDD, -24.44% 2022 Bear MDD, Calmar 0.701).",
        "summary_zh": "以等金额预算（50% 仓位 90D -10% Put 基准保费）买入 90-DTE -15% OTM Put（终值 $1,682,250、最大回撤 -28.02%、2022 慢熊回撤 -24.44%、Calmar 0.701）。",
    },
    {
        "id": "otm20",
        "moneyness": 0.80,
        "otm_pct": 20,
        "label_en": "-20% OTM (High Convexity · NAV #1)",
        "label_zh": "-20% OTM（高凸性进攻 · 终值冠军）",
        "short_en": "-20% OTM",
        "short_zh": "-20% OTM",
        "summary_en": "Spends the exact same dollar budget on deeper 90-DTE -20% OTM Puts for higher crash convexity when tail skew IV(-20%)/IV(-10%) <= 1.18 ($1,856,309 NAV, 20.62% CAGR, Calmar 0.737).",
        "summary_zh": "在同等美元保费预算下切换至更深虚值 90-DTE -20% OTM Put，在尾部偏度 IV(-20%)/IV(-10%) <= 1.18 时具备极佳赔率（终值 $1,856,309、年化 20.62%、Calmar 0.737）。",
    },
]

M7_TP_MODE_SPECS: list[dict[str, Any]] = [
    {
        "id": "standard",
        "code": "STANDARD",
        "require_itm": False,
        "label_en": "STANDARD (VIX/3M >= 1.10 · Default)",
        "label_zh": "STANDARD 标准止盈（VIX/3M >= 1.10 · 默认）",
        "short_en": "STANDARD",
        "short_zh": "标准止盈",
        "rule_en": "Exit at T+1 Open when EOD VIX/VIX3M >= 1.10 OR (DTE <= 45 AND Put Mid >= 5x Entry Cost).",
        "rule_zh": "收盘触发 VIX/VIX3M >= 1.10 恐慌倒挂，或（DTE <= 45 且期权中间价 >= 5 倍建仓成本）时次日开盘止盈换股。",
        "summary_en": "Unified fast monetization on panic term-structure inversion (VIX/VIX3M >= 1.10) plus 5x second-half slow-bear profit lock ($1,682,250 on -15% OTM).",
        "summary_zh": "见 VIX/VIX3M >= 1.10 恐慌倒挂即刻次日开盘落袋抄底 QQQ，配合后半程 DTE<=45 & 5x 慢熊锁利（-15% OTM 终值 $1,682,250）。",
    },
    {
        "id": "itm_tp",
        "code": "ITM_TP",
        "require_itm": True,
        "label_en": "ITM_TP (QQQ <= Kp + VIX/3M >= 1.10)",
        "label_zh": "ITM_TP 分层实值止盈（跌破 Kp 才平 · 低回撤）",
        "short_en": "ITM_TP",
        "short_zh": "分层实值 ITM",
        "rule_en": "Exit at T+1 Open when EOD (VIX/VIX3M >= 1.10 AND QQQ <= Strike Kp) OR (DTE <= 45 AND Put Mid >= 5x Entry Cost).",
        "rule_zh": "收盘同时满足（VIX/VIX3M >= 1.10 且 QQQ <= 行权价 Kp 进入实值），或（DTE <= 45 且中间价 >= 5 倍成本）才止盈。",
        "summary_en": "Refuses premature exit on early panic spikes while Put is still OTM (e.g., 2020-02-27), slashing 2020 COVID MDD to -23.33% and full-cycle MDD to -24.44% (Calmar 0.763).",
        "summary_zh": "过滤暴跌初期尚未跌破行权价 Kp 的早鸟倒挂（如 2020-02-27），死拿吃满主跌浪——将 2020 疫情回撤压至 -23.33%、全周期最大回撤压至 -24.44%（Calmar 0.763）。",
    },
]

M7_PROFILE_SPECS: list[dict[str, Any]] = [
    {
        "id": "full_m7_adaptive",
        "strategy_id": "M7G_Graded",
        "default_roll_mode": "adaptive_120_90",
        "locked_roll_mode": None,
        "title_en": "Full M7 Shield · Recommended",
        "title_zh": "全套 M7 护盾 · 默认推荐",
        "badge_en": "RECOMMENDED · 6-MODULE SHIELD",
        "badge_zh": "默认推荐 · 6维全天候护盾",
        "summary_en": "6-Module Radar + Adaptive Roll 120->50 / CTA 90->30 · Shields 2020-type exogenous black swans, #1 in 2021-2025",
        "summary_zh": "6维雷达 + 自适应滚仓 120→50 / CTA 90→30 · 抗2020型外生黑天鹅，2021–2025后半程更强",
        "active_modules": ["M0", "M6", "M2", "M5", "M4", "M3"],
        "disabled_modules": [],
    },
    {
        "id": "core3_adaptive",
        "strategy_id": "Core3_Adaptive",
        "default_roll_mode": "adaptive_120_90",
        "locked_roll_mode": "adaptive_120_90",
        "title_en": "Core-3 Minimal · Low Freq · High PF",
        "title_zh": "精简 3 核 · 低频高赔率",
        "badge_en": "MINIMAL 3-CORE · 2.23x PF",
        "badge_zh": "低频高赔率 · 11年30笔",
        "summary_en": "Only M0+M6+M4 + Adaptive Roll · Just 30 trades in 11 yrs, 2.23x Profit Factor; Note: omits exogenous shock sensors",
        "summary_zh": "仅保留 M0+M6+M4 + 自适应滚仓 · 11年仅30笔、利润因子2.23x；提示：不含外生突发预警",
        "active_modules": ["M0", "M6", "M4"],
        "disabled_modules": ["M2", "M5", "M3"],
    },
]

M7_ROLL_MODE_SPECS: list[dict[str, Any]] = [
    {
        "id": "adaptive_120_90",
        "target_dte": 120,
        "cta_target_dte": 90,
        "ref_dte": 120,
        "cta_ref_dte": 90,
        "roll_dte": 50,
        "cta_roll_dte": 30,
        "five_x_max_dte": 45,
        "label_en": "Adaptive 120->50 / CTA 90->30 (Recommended)",
        "label_zh": "自适应 120→50 / CTA 90→30（推荐）",
        "short_en": "Adaptive 120/90",
        "short_zh": "自适应 120/90",
        "summary_en": "Pillar-Adaptive Real-OPRA Champion: P1/P2 fragility & shock signals buy 120D Puts and roll/salvage at <=50 DTE; P3 M4 CTA bear-rally bounces buy faster 90D Puts and roll/salvage at <=30 DTE.",
        "summary_zh": "真实 OPRA 分支柱自适应冠军：P1/P2 高位背离与外生预警买 120D Put、剩 <=50D 滚仓；P3 M4 熊市死猫跳反弹买更敏捷的 90D Put、剩 <=30D 滚仓回收。",
    },
    {
        "id": "120d_roll50",
        "target_dte": 120,
        "cta_target_dte": 120,
        "ref_dte": 120,
        "cta_ref_dte": 120,
        "roll_dte": 50,
        "cta_roll_dte": 50,
        "five_x_max_dte": 45,
        "label_en": "Uniform 120D -> 50D Roll",
        "label_zh": "统一 120→50 滚仓",
        "short_en": "Uniform 120->50",
        "short_zh": "统一 120→50",
        "summary_en": "Uniform 120D->50D Roll: buys 120-DTE Puts sized to 120D -10% Put Ask across all pillars and salvages/rolls at <= 50 DTE before the Theta cliff.",
        "summary_zh": "统一 120D→50D 滚仓：所有支柱统一建仓 120D Put，剩 <=50 DTE 在 Theta 悬崖前按实盘买一价回收残值或滚入新仓。",
    },
    {
        "id": "90d_hold",
        "target_dte": 90,
        "cta_target_dte": 90,
        "ref_dte": 90,
        "cta_ref_dte": 90,
        "roll_dte": 0,
        "cta_roll_dte": 0,
        "five_x_max_dte": 45,
        "label_en": "90D Hold-to-Expiry",
        "label_zh": "90D 持有到期",
        "short_en": "90D Hold",
        "short_zh": "90D 持有",
        "summary_en": "90D Hold-to-Expiry baseline (Full M7 only): buys 90-DTE OTM Puts sized to 90D -10% Put Ask and holds to panic TP or expiry.",
        "summary_zh": "90D 持有到期对照（仅全套 M7 可选）：按 90D -10% Put 基准保费买入 90D Put，持有至恐慌止盈或到期。",
    },
]

M7_MODULE_META: dict[str, dict[str, Any]] = {
    "M0": {
        "pillar": "P1",
        "points": 35,
        "name_en": "M0 Six Lights Baseline",
        "name_zh": "M0 六灯基线开关",
        "short_en": "M0 Six Lights",
        "short_zh": "M0 六灯基线",
    },
    "M6": {
        "pillar": "P1",
        "points": 20,
        "name_en": "M6 Breadth + Defensive Rotation",
        "name_zh": "M6 宽度恶化 + 防御轮动",
        "short_en": "M6 Breadth/Def",
        "short_zh": "M6 宽度+防御",
    },
    "M2": {
        "pillar": "P2",
        "points": 20,
        "name_en": "M2 Options Desk Warning",
        "name_zh": "M2 期权台尾部预警",
        "short_en": "M2 Vol Desk",
        "short_zh": "M2 期权台预警",
    },
    "M5": {
        "pillar": "P2",
        "points": 20,
        "name_en": "M5 Causal HMM Regime Transition",
        "name_zh": "M5 因果 HMM 状态跃迁",
        "short_en": "M5 Causal HMM",
        "short_zh": "M5 因果HMM",
    },
    "M4": {
        "pillar": "P3",
        "points": 35,
        "name_en": "M4 CTA Bear-Rally Complacency",
        "name_zh": "M4 CTA 熊市反弹自满",
        "short_en": "M4 Bear Rally",
        "short_zh": "M4 熊市反弹自满",
    },
    "M3": {
        "pillar": "P3",
        "points": 20,
        "name_en": "M3 Credit & Macro Stress",
        "name_zh": "M3 信用利差与宏观压力",
        "short_en": "M3 Credit/Macro",
        "short_zh": "M3 信用宏观压力",
    },
}


def quantile_linear(vals: list[float], q: float) -> float:
    s = sorted(vals)
    n = len(s)
    if n == 0:
        return float("nan")
    if n == 1:
        return s[0]
    pos = (n - 1) * q
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return s[lo]
    frac = pos - lo
    return s[lo] * (1.0 - frac) + s[hi] * frac


def rolling_mean(arr: list[float | None], win: int, min_p: int | None = None) -> list[float | None]:
    mp = win if min_p is None else min_p
    out: list[float | None] = [None] * len(arr)
    for i in range(len(arr)):
        w = [x for x in arr[max(0, i - win + 1) : i + 1] if x is not None and not math.isnan(x)]
        if len(w) >= mp and (min_p is not None or len(w) == win):
            out[i] = sum(w) / len(w)
    return out


def rolling_std_ddof1(arr: list[float | None], win: int, min_p: int | None = None) -> list[float | None]:
    mp = win if min_p is None else min_p
    out: list[float | None] = [None] * len(arr)
    for i in range(len(arr)):
        w = [x for x in arr[max(0, i - win + 1) : i + 1] if x is not None and not math.isnan(x)]
        if len(w) >= max(2, mp) and (min_p is not None or len(w) == win):
            mu = sum(w) / len(w)
            var = sum((x - mu) ** 2 for x in w) / (len(w) - 1)
            out[i] = math.sqrt(max(0.0, var))
    return out


def rolling_min(arr: list[float | None], win: int, min_p: int | None = None) -> list[float | None]:
    mp = win if min_p is None else min_p
    out: list[float | None] = [None] * len(arr)
    for i in range(len(arr)):
        w = [x for x in arr[max(0, i - win + 1) : i + 1] if x is not None and not math.isnan(x)]
        if len(w) >= mp and (min_p is not None or len(w) == win):
            out[i] = min(w)
    return out


def rolling_quantile(arr: list[float | None], win: int, q: float, min_p: int) -> list[float | None]:
    out: list[float | None] = [None] * len(arr)
    for i in range(len(arr)):
        w = [x for x in arr[max(0, i - win + 1) : i + 1] if x is not None and not math.isnan(x)]
        if len(w) >= min_p:
            out[i] = quantile_linear(w, q)
    return out


def ewm_span_with_state(arr: list[float | None], span: int) -> tuple[list[float | None], float | None]:
    alpha = 2.0 / (span + 1.0)
    out: list[float | None] = [None] * len(arr)
    cur: float | None = None
    for i, x in enumerate(arr):
        if x is None or math.isnan(x):
            out[i] = cur
            continue
        cur = x if cur is None else ((1.0 - alpha) * cur + alpha * x)
        out[i] = cur
    return out, cur


def fit_gaussian_hmm_em_stdlib(X: list[list[float]], n_iter: int = 35):
    T = len(X)
    D = len(X[0])
    rv_col = [row[1] for row in X]
    q = quantile_linear(rv_col, 0.72)
    g0 = [row for row in X if row[1] < q]
    g1 = [row for row in X if row[1] >= q]
    means = [[0.0] * D for _ in range(2)]
    vars_ = [[0.0] * D for _ in range(2)]
    for k, grp in enumerate((g0, g1)):
        ng = max(1, len(grp))
        for d in range(D):
            mu = sum(r[d] for r in grp) / ng
            means[k][d] = mu
            vars_[k][d] = sum((r[d] - mu) ** 2 for r in grp) / ng + 0.15

    A = [[0.97, 0.03], [0.08, 0.92]]
    pi = [0.80, 0.20]
    two_pi = 2.0 * math.pi

    for _ in range(n_iter):
        v_eff = [[max(vars_[k][d], 0.08) for d in range(D)] for k in range(2)]
        log_const = [-0.5 * sum(math.log(two_pi * v_eff[k][d]) for d in range(D)) for k in range(2)]
        le = [[0.0, 0.0] for _ in range(T)]
        for t in range(T):
            xt = X[t]
            for k in range(2):
                mk = means[k]
                vk = v_eff[k]
                le[t][k] = log_const[k] - 0.5 * sum(((xt[d] - mk[d]) ** 2) / vk[d] for d in range(D))

        alpha = [[0.0, 0.0] for _ in range(T)]
        l0_0 = math.log(max(pi[0], 1e-12)) + le[0][0]
        l0_1 = math.log(max(pi[1], 1e-12)) + le[0][1]
        m0 = max(l0_0, l0_1)
        a0_0 = math.exp(l0_0 - m0)
        a0_1 = math.exp(l0_1 - m0)
        s0 = a0_0 + a0_1
        alpha[0][0] = a0_0 / s0
        alpha[0][1] = a0_1 / s0

        for t in range(1, T):
            p0 = alpha[t - 1][0] * A[0][0] + alpha[t - 1][1] * A[1][0]
            p1 = alpha[t - 1][0] * A[0][1] + alpha[t - 1][1] * A[1][1]
            lt0 = math.log(max(p0, 1e-15)) + le[t][0]
            lt1 = math.log(max(p1, 1e-15)) + le[t][1]
            mt = max(lt0, lt1)
            at0 = math.exp(lt0 - mt)
            at1 = math.exp(lt1 - mt)
            st = at0 + at1
            alpha[t][0] = at0 / st
            alpha[t][1] = at1 / st

        beta = [[0.0, 0.0] for _ in range(T)]
        beta[-1][0] = 1.0
        beta[-1][1] = 1.0
        e_next_cache = [[0.0, 0.0] for _ in range(T)]
        for t in range(1, T):
            mt = max(le[t][0], le[t][1])
            e_next_cache[t][0] = math.exp(le[t][0] - mt)
            e_next_cache[t][1] = math.exp(le[t][1] - mt)

        for t in range(T - 2, -1, -1):
            en0, en1 = e_next_cache[t + 1]
            eb0 = en0 * beta[t + 1][0]
            eb1 = en1 * beta[t + 1][1]
            b0 = A[0][0] * eb0 + A[0][1] * eb1
            b1 = A[1][0] * eb0 + A[1][1] * eb1
            sb = max(b0 + b1, 1e-15)
            beta[t][0] = b0 / sb
            beta[t][1] = b1 / sb

        gamma = [[0.0, 0.0] for _ in range(T)]
        for t in range(T):
            g0v = alpha[t][0] * beta[t][0]
            g1v = alpha[t][1] * beta[t][1]
            sg = max(g0v + g1v, 1e-15)
            gamma[t][0] = g0v / sg
            gamma[t][1] = g1v / sg

        xi00 = xi01 = xi10 = xi11 = 0.0
        for t in range(T - 1):
            en0, en1 = e_next_cache[t + 1]
            eb0 = en0 * beta[t + 1][0]
            eb1 = en1 * beta[t + 1][1]
            m00 = alpha[t][0] * eb0 * A[0][0]
            m01 = alpha[t][0] * eb1 * A[0][1]
            m10 = alpha[t][1] * eb0 * A[1][0]
            m11 = alpha[t][1] * eb1 * A[1][1]
            sm = m00 + m01 + m10 + m11
            if sm > 1e-15:
                xi00 += m00 / sm
                xi01 += m01 / sm
                xi10 += m10 / sm
                xi11 += m11 / sm

        pi0 = max(gamma[0][0], 1e-4)
        pi1 = max(gamma[0][1], 1e-4)
        spi = pi0 + pi1
        pi = [pi0 / spi, pi1 / spi]

        r00 = xi00 + 0.55
        r01 = xi01 + 0.05
        sr0 = r00 + r01
        r10 = xi10 + 0.05
        r11 = xi11 + 0.55
        sr1 = r10 + r11
        A = [[r00 / sr0, r01 / sr0], [r10 / sr1, r11 / sr1]]

        for k in range(2):
            sw = max(sum(gamma[t][k] for t in range(T)), 1e-4)
            for d in range(D):
                mu = sum(gamma[t][k] * X[t][d] for t in range(T)) / sw
                means[k][d] = mu
                vars_[k][d] = sum(gamma[t][k] * ((X[t][d] - mu) ** 2) for t in range(T)) / sw + 0.08

    ranks = [means[k][1] + means[k][3] - 0.7 * means[k][0] + 0.6 * means[k][2] for k in range(2)]
    order = [0, 1] if ranks[0] <= ranks[1] else [1, 0]
    pi_o = [pi[order[0]], pi[order[1]]]
    A_o = [
        [A[order[0]][order[0]], A[order[0]][order[1]]],
        [A[order[1]][order[0]], A[order[1]][order[1]]],
    ]
    means_o = [means[order[0]], means[order[1]]]
    vars_o = [vars_[order[0]], vars_[order[1]]]
    return pi_o, A_o, means_o, vars_o


def hamilton_step(
    state_p: list[float],
    x_row: list[float],
    A: list[list[float]],
    means: list[list[float]],
    vars_: list[list[float]],
) -> list[float]:
    two_pi = 2.0 * math.pi
    le = [0.0, 0.0]
    for k in range(2):
        s = 0.0
        for d in range(4):
            vk = max(vars_[k][d], 0.08)
            s += math.log(two_pi * vk) + ((x_row[d] - means[k][d]) ** 2) / vk
        le[k] = -0.5 * s
    ml = max(le[0], le[1])
    e0 = math.exp(le[0] - ml)
    e1 = math.exp(le[1] - ml)
    pred0 = state_p[0] * A[0][0] + state_p[1] * A[1][0]
    pred1 = state_p[0] * A[0][1] + state_p[1] * A[1][1]
    post0 = pred0 * e0
    post1 = pred1 * e1
    sp = max(post0 + post1, 1e-15)
    return [post0 / sp, post1 / sp]


def _fetch_yahoo_chart_daily(ticker: str, timeout: int = 10) -> dict[str, dict[str, float]]:
    enc = urllib.parse.quote(ticker, safe="")
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{enc}?range=3mo&interval=1d&events=div"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 ThesisForge/2.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    res = ((payload.get("chart") or {}).get("result") or [None])[0]
    if not res:
        return {}
    ts_list = res.get("timestamp") or []
    quote = ((res.get("indicators") or {}).get("quote") or [{}])[0]
    adj_list = (((res.get("indicators") or {}).get("adjclose") or [{}])[0]).get("adjclose") or []
    div_events = ((res.get("events") or {}).get("dividends") or {})
    div_by_date: dict[str, float] = {}
    for dv in div_events.values():
        dts = dv.get("date")
        amt = dv.get("amount")
        if dts is not None and amt is not None:
            iso = datetime.datetime.fromtimestamp(int(dts), tz=datetime.timezone.utc).strftime("%Y-%m-%d")
            div_by_date[iso] = float(amt)

    opens = quote.get("open") or []
    highs = quote.get("high") or []
    lows = quote.get("low") or []
    closes = quote.get("close") or []
    out: dict[str, dict[str, float]] = {}
    for idx, ts in enumerate(ts_list):
        cl = closes[idx] if idx < len(closes) else None
        if cl is None:
            continue
        iso = datetime.datetime.fromtimestamp(int(ts), tz=datetime.timezone.utc).strftime("%Y-%m-%d")
        adj = adj_list[idx] if idx < len(adj_list) and adj_list[idx] is not None else cl
        op = opens[idx] if idx < len(opens) and opens[idx] is not None else cl
        hi = highs[idx] if idx < len(highs) and highs[idx] is not None else cl
        lo = lows[idx] if idx < len(lows) and lows[idx] is not None else cl
        out[iso] = {
            "open": float(op),
            "high": float(hi),
            "low": float(lo),
            "close": float(cl),
            "adjclose": float(adj),
            "div": float(div_by_date.get(iso, 0.0)),
        }
    return out


def _fetch_fred_series(series_id: str, start_date: str = "2025-01-01", timeout: int = 10) -> dict[str, float]:
    url = f"https://fred.stlouisfed.org/graph/fredgraph.csv?id={series_id}&cosd={start_date}"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 ThesisForge/2.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        txt = resp.read().decode("utf-8")
    out: dict[str, float] = {}
    for row in csv.DictReader(io.StringIO(txt)):
        d = (row.get("DATE") or row.get("observation_date") or row.get("date") or "").strip()[:10]
        v = (row.get(series_id) or "").strip()
        if d and v and v != ".":
            try:
                fv = float(v)
                if math.isfinite(fv):
                    out[d] = fv
            except ValueError:
                pass
    return out


def load_m7_seed_and_optional_live(
    m7_seed_gz: Path,
    rows_all: list[dict[str, Any]],
    live_fetch: bool = False,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if not m7_seed_gz.exists():
        raise FileNotFoundError(f"Missing M7 seed archive: {m7_seed_gz}")
    with gzip.open(m7_seed_gz, "rb") as f:
        seed = json.loads(f.read().decode("utf-8"))

    yf_dates: list[str] = list(seed["yf_dates"])
    yf_series: dict[str, list[float | None]] = {k: list(v) for k, v in seed["yf_series"].items()}
    fred_raw: dict[str, dict[str, float]] = {k: dict(v) for k, v in seed["fred_raw"].items()}

    # If rows_all already extended beyond yf_dates[-1] via local warehouse, or live_fetch=True:
    if live_fetch:
        try:
            fetched_yf = {k: _fetch_yahoo_chart_daily(YF_TICKER_MAP[k]) for k in YF_ALL_KEYS}
            for fid in FRED_LAGS:
                try:
                    fred_raw[fid].update(_fetch_fred_series(fid))
                except Exception:
                    pass
            last_seed_dt = yf_dates[-1]
            # Require complete US close on QQQ, SPY, VIX, VIX3M, VXN
            cand_dates = sorted(
                d
                for d in fetched_yf["QQQ"].keys()
                if d > last_seed_dt
                and d in fetched_yf["SPY"]
                and d in fetched_yf["VIX"]
                and d in fetched_yf["VIX3M"]
                and d in fetched_yf["VXN"]
            )
            if cand_dates:
                anchor_dt = last_seed_dt
                for new_d in cand_dates:
                    yf_dates.append(new_d)
                    for k in YF_ALL_KEYS:
                        cur_map = fetched_yf.get(k) or {}
                        prev_val = next((x for x in reversed(yf_series[k]) if x is not None), None)
                        if new_d in cur_map and prev_val is not None:
                            if k in YF_ETF_KEYS and anchor_dt in cur_map and cur_map[anchor_dt]["adjclose"] > 0:
                                # Chain-link dividend-adjusted total return from previous trading date
                                prev_d = yf_dates[-2]
                                if prev_d in cur_map and cur_map[prev_d]["adjclose"] > 0:
                                    val = prev_val * (cur_map[new_d]["adjclose"] / cur_map[prev_d]["adjclose"])
                                else:
                                    val = cur_map[new_d]["adjclose"]
                            else:
                                val = cur_map[new_d]["close"]
                            yf_series[k].append(float(val))
                        else:
                            yf_series[k].append(prev_val)

                # Also extend rows_all if newer than rows_all[-1]["date"]
                existing_row_dates = {r["date"] for r in rows_all}
                for new_d in cand_dates:
                    if new_d in existing_row_dates:
                        continue
                    q_bar = fetched_yf["QQQ"][new_d]
                    vix_c = fetched_yf["VIX"][new_d]["close"]
                    vix3m_c = fetched_yf["VIX3M"][new_d]["close"]
                    vxn_c = fetched_yf["VXN"][new_d]["close"]
                    if vix3m_c <= 0:
                        continue
                    prev_r = rows_all[-1]
                    cl_f = float(q_bar["close"])
                    run_ath = max(float(prev_r["running_ath"]), cl_f)
                    dd_ath = cl_f / run_ath - 1.0
                    tail_closes = [float(x["close"]) for x in rows_all[-199:]] + [cl_f]
                    ma200 = sum(tail_closes) / len(tail_closes)
                    sc = int(prev_r["score"])
                    sc5 = sum([int(x["score"]) for x in rows_all[-4:]] + [sc]) / 5.0
                    prev_vix = float(prev_r["vix"])
                    nr = dict(prev_r)
                    nr.update(
                        {
                            "date": new_d,
                            "open": round(float(q_bar["open"]), 6),
                            "high": round(float(q_bar["high"]), 6),
                            "low": round(float(q_bar["low"]), 6),
                            "close": round(cl_f, 6),
                            "dividends": round(float(q_bar["div"]), 6),
                            "vix": round(float(vix_c), 4),
                            "prev_vix": prev_vix,
                            "vix_falling": bool(float(vix_c) < prev_vix),
                            "vix3m": round(float(vix3m_c), 4),
                            "vix_ratio": round(float(vix_c) / float(vix3m_c), 6),
                            "vxn": round(float(vxn_c), 4),
                            "running_ath": round(run_ath, 6),
                            "dd_from_ath": round(dd_ath, 8),
                            "qqq_ma200": round(ma200, 6),
                            "score_5d": round(sc5, 4),
                            "sw_u1": bool(
                                dd_ath >= -0.05
                                and (float(prev_r["ad_line"]) < float(prev_r["ad_sma50"]) or sc >= 4)
                                and float(vxn_c) <= 22.0
                            ),
                            "sw_b1c": bool(
                                dd_ath >= -0.05
                                and float(prev_r["ad_line"]) < float(prev_r["ad_sma50"])
                                and float(vxn_c) <= 22.0
                            ),
                            "sw_d2": bool(dd_ath >= -0.05 and sc >= 4),
                            "sw_g4": False if dd_ath < -0.05 else bool(prev_r["gate_g4"]),
                        }
                    )
                    rows_all.append(nr)
        except Exception:
            pass

    # Ensure any warehouse-extended rows_all dates > yf_dates[-1] are also reflected in yf_dates via ffill + QQQ/VIX/VXN
    yf_date_set = set(yf_dates)
    for r in rows_all:
        d = r["date"]
        if d > yf_dates[-1] and d not in yf_date_set:
            prev_qqq_cl = next((x["close"] for x in reversed(rows_all) if x["date"] == yf_dates[-1]), float(r["close"]))
            ret_ratio = float(r["close"]) / max(float(prev_qqq_cl), 1e-6)
            yf_dates.append(d)
            yf_date_set.add(d)
            for k in YF_ALL_KEYS:
                last_v = next((x for x in reversed(yf_series[k]) if x is not None), 0.0)
                if k == "QQQ":
                    yf_series[k].append(last_v * ret_ratio)
                elif k == "VXN":
                    yf_series[k].append(float(r["vxn"]))
                elif k == "VIX":
                    yf_series[k].append(float(r["vix"]))
                elif k == "VIX3M":
                    yf_series[k].append(float(r["vix3m"]))
                else:
                    yf_series[k].append(last_v)

    return {"yf_dates": yf_dates, "yf_series": yf_series, "fred_raw": fred_raw}, rows_all


def _clamp01(v: float) -> float:
    return 0.0 if v <= 0.0 else (1.0 if v >= 1.0 else v)


def _round_half_up_int(v: float) -> int:
    return int(math.floor(v + 0.5))


def compute_live_stress_index(
    *,
    hmm_p: float = 0.0,
    vxn: float = 0.0,
    vix_ratio: float = 0.0,
    dd_from_ath: float = 0.0,
    close: float = 0.0,
    sma200: float = 0.0,
    ewmac: float = 0.0,
    hyg_lqd: float = 0.0,
    hyg_sma50: float = 0.0,
    baa_rise63: float | None = 0.0,
    dgs2_jump63: float | None = 0.0,
    nfci_jump20: float | None = 0.0,
    def_ret20: float = 0.0,
    rsp_spy: float = 0.0,
    rsp_sma50: float = 0.0,
    iwm_qqq: float = 0.0,
    iwm_sma50: float = 0.0,
    ad_below50: bool = False,
    vvix: float = 0.0,
    vvix_p75: float = 0.0,
    skew10: float = 0.0,
    skew_p75: float = 0.0,
    vr_jump5: float = 0.0,
) -> dict[str, Any]:
    """Track A continuous Real-Time Market Stress Index (0..100).

    Strictly causal, never zeroed out by the low-vol Put-entry redline.
    """
    baa_eff = 0.0 if (baa_rise63 is None or baa_rise63 <= -900.0) else float(baa_rise63)
    dgs2_eff = 0.0 if (dgs2_jump63 is None or dgs2_jump63 <= -900.0) else float(dgs2_jump63)
    nfci_eff = 0.0 if (nfci_jump20 is None or nfci_jump20 <= -900.0) else float(nfci_jump20)

    regime_vol = (
        _clamp01(float(hmm_p)) * 18.0
        + _clamp01((float(vxn) - 20.0) / 20.0) * 7.0
        + _clamp01((float(vix_ratio) - 0.90) / 0.20) * 5.0
    )
    trend_dd = (
        _clamp01((-float(dd_from_ath) - 0.03) / 0.17) * 12.0
        + (6.0 if (float(sma200) > 0.0 and float(close) < float(sma200)) else 0.0)
        + _clamp01(-float(ewmac) / 0.80) * 7.0
    )
    credit_macro = (
        (8.0 if (float(hyg_sma50) > 0.0 and float(hyg_lqd) < float(hyg_sma50)) else 0.0)
        + _clamp01(max(0.0, baa_eff) / 0.25) * 8.0
        + _clamp01(max(max(0.0, dgs2_eff) / 0.50, max(0.0, nfci_eff) / 0.15)) * 9.0
    )
    breadth_tail = (
        _clamp01(max(0.0, float(def_ret20)) / 0.10) * 8.0
        + (2.0 if (float(rsp_sma50) > 0.0 and float(rsp_spy) < float(rsp_sma50)) else 0.0)
        + (2.0 if (float(iwm_sma50) > 0.0 and float(iwm_qqq) < float(iwm_sma50)) else 0.0)
        + (2.0 if bool(ad_below50) else 0.0)
        + (2.0 if (float(vvix_p75) > 0.0 and float(vvix) >= float(vvix_p75)) else 0.0)
        + (2.0 if (float(skew_p75) > 0.0 and float(skew10) >= float(skew_p75)) else 0.0)
        + (2.0 if float(vr_jump5) >= 0.06 else 0.0)
    )

    raw_total = max(0.0, min(100.0, regime_vol + trend_dd + credit_macro + breadth_tail))
    idx_int = _round_half_up_int(raw_total)
    if idx_int >= 75:
        level, lbl_en, lbl_zh = "crisis", "Active Crisis", "危机爆发中"
    elif idx_int >= 50:
        level, lbl_en, lbl_zh = "elevated", "Elevated Stress", "高压警戒"
    elif idx_int >= 25:
        level, lbl_en, lbl_zh = "building", "Stress Building", "隐患蓄力"
    else:
        level, lbl_en, lbl_zh = "calm", "Calm Low-Vol", "平静低波"

    return {
        "live_stress_index": idx_int,
        "live_stress_level": level,
        "live_stress_label_en": lbl_en,
        "live_stress_label_zh": lbl_zh,
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


def compute_m7_signals_and_tail(
    rows_all: list[dict[str, Any]],
    m7_data: dict[str, Any],
    start_eval_date: str = "2015-01-02",
) -> dict[str, Any]:
    cal: list[str] = list(m7_data["yf_dates"])
    n = len(cal)
    bco_map = {r["date"]: r for r in rows_all}

    yf_ffill: dict[str, list[float]] = {k: [] for k in YF_ALL_KEYS}
    last_v: dict[str, float] = {}
    for i in range(n):
        for k in YF_ALL_KEYS:
            raw_v = m7_data["yf_series"][k][i]
            if raw_v is not None and not math.isnan(float(raw_v)):
                last_v[k] = float(raw_v)
            yf_ffill[k].append(last_v[k])

    def align_and_lag_with_dates(src: dict[str, float], lag: int) -> tuple[list[float | None], list[str | None]]:
        union_dates = sorted(set(cal) | set(src.keys()))
        ff_map: dict[str, float | None] = {}
        dt_map: dict[str, str | None] = {}
        cur: float | None = None
        cur_dt: str | None = None
        for d in union_dates:
            if d in src:
                cur = float(src[d])
                cur_dt = d
            ff_map[d] = cur
            dt_map[d] = cur_dt
        aligned_v = [ff_map[d] for d in cal]
        aligned_d = [dt_map[d] for d in cal]
        return ([None] * lag + aligned_v[:-lag]), ([None] * lag + aligned_d[:-lag])

    baa_lag1, baa_obs_dt = align_and_lag_with_dates(m7_data["fred_raw"]["BAA10Y"], 1)
    dgs2_lag1, dgs2_obs_dt = align_and_lag_with_dates(m7_data["fred_raw"]["DGS2"], 1)
    nfci_lag5, nfci_obs_dt = align_and_lag_with_dates(m7_data["fred_raw"]["NFCI"], 5)

    qqq_cl = [float(bco_map[d]["close"]) if d in bco_map else yf_ffill["QQQ"][i] for i, d in enumerate(cal)]
    vix_r = [
        float(bco_map[d]["vix_ratio"]) if d in bco_map else (yf_ffill["VIX"][i] / max(yf_ffill["VIX3M"][i], 1e-6))
        for i, d in enumerate(cal)
    ]
    vxn_cl = [float(bco_map[d]["vxn"]) if d in bco_map else yf_ffill["VXN"][i] for i, d in enumerate(cal)]
    vvix = yf_ffill["VVIX"]
    skew10 = rolling_mean(yf_ffill["SKEW"], 10)
    vvix_p75 = rolling_quantile(vvix, 252, 0.75, 126)
    skew_p75 = rolling_quantile(skew10, 252, 0.75, 126)

    hyg_lqd = [yf_ffill["HYG"][i] / max(yf_ffill["LQD"][i], 1e-8) for i in range(n)]
    hyg_lqd_sma50 = rolling_mean(hyg_lqd, 50)
    baa_min63 = rolling_min(baa_lag1, 63, 30)

    sma200 = rolling_mean(qqq_cl, 200)
    ema20, ema20_last = ewm_span_with_state(qqq_cl, 20)
    qqq_diff = [None if i == 0 else (qqq_cl[i] - qqq_cl[i - 1]) for i in range(n)]
    px_vol = rolling_std_ddof1(qqq_diff, 60)
    e16, e16_last = ewm_span_with_state(qqq_cl, 16)
    e32, e32_last = ewm_span_with_state(qqq_cl, 32)
    e64, e64_last = ewm_span_with_state(qqq_cl, 64)
    e128, e128_last = ewm_span_with_state(qqq_cl, 128)
    e256, e256_last = ewm_span_with_state(qqq_cl, 256)

    ewmac: list[float | None] = [None] * n
    for i in range(n):
        pv = px_vol[i]
        if pv is not None and pv > 0:
            ewmac[i] = (((e16[i] - e64[i]) / pv) + ((e32[i] - e128[i]) / pv) + ((e64[i] - e256[i]) / pv)) / 3.0

    qqq_ret1 = [None if i == 0 else math.log(qqq_cl[i] / qqq_cl[i - 1]) for i in range(n)]
    rv20_raw = rolling_std_ddof1(qqq_ret1, 20)
    rv20_ann = [None if rv20_raw[i] is None else (rv20_raw[i] * math.sqrt(252.0)) for i in range(n)]

    col_ret5 = [None if i < 5 else math.log(qqq_cl[i] / qqq_cl[i - 5]) for i in range(n)]
    col_lrv = [None if rv20_ann[i] is None else math.log(max(rv20_ann[i], 0.05)) for i in range(n)]
    col_cred = [None if i < 20 else -math.log(hyg_lqd[i] / hyg_lqd[i - 20]) for i in range(n)]
    col_vr = [vix_r[i] for i in range(n)]
    cols_4 = [col_ret5, col_lrv, col_cred, col_vr]

    Z: list[list[float] | None] = [None] * n
    cnt = [0, 0, 0, 0]
    mean_acc = [0.0, 0.0, 0.0, 0.0]
    m2_acc = [0.0, 0.0, 0.0, 0.0]

    for i in range(n):
        if all(cols_4[d][i] is not None and cnt[d] >= 200 for d in range(4)):
            z_row: list[float] = []
            ok = True
            for d in range(4):
                std_d = math.sqrt(m2_acc[d] / (cnt[d] - 1))
                if std_d <= 0:
                    ok = False
                    break
                zv = (float(cols_4[d][i]) - mean_acc[d]) / std_d
                z_row.append(max(-4.5, min(4.5, zv)))
            if ok:
                Z[i] = z_row
        for d in range(4):
            v = cols_4[d][i]
            if v is not None and not math.isnan(v):
                cnt[d] += 1
                delta = v - mean_acc[d]
                mean_acc[d] += delta / cnt[d]
                m2_acc[d] += delta * (v - mean_acc[d])

    p_hmm: list[float | None] = [None] * n
    latest_hmm: dict[str, Any] = {}
    years = sorted({int(d[:4]) for d in cal if int(d[:4]) >= 2015})
    for Y in years:
        y_start = f"{Y}-01-01"
        y_end = f"{Y + 1}-01-01"
        train_idx = [i for i, d in enumerate(cal) if d < y_start and Z[i] is not None]
        test_idx = [i for i, d in enumerate(cal) if y_start <= d < y_end and Z[i] is not None]
        if len(train_idx) < 200 or not test_idx:
            continue
        X_train = [Z[i] for i in train_idx if Z[i] is not None]
        pi, A, means, vars_ = fit_gaussian_hmm_em_stdlib(X_train, n_iter=35)
        state_p = list(pi)
        for row_x in X_train[-60:]:
            state_p = hamilton_step(state_p, row_x, A, means, vars_)
        for idx in test_idx:
            z_cur = Z[idx]
            assert z_cur is not None
            state_p = hamilton_step(state_p, z_cur, A, means, vars_)
            p_hmm[idx] = state_p[1]
        latest_hmm = {
            "year": Y,
            "pi": [round(x, 10) for x in pi],
            "A": [[round(x, 10) for x in row_a] for row_a in A],
            "means": [[round(x, 10) for x in row_m] for row_m in means],
            "vars": [[round(x, 10) for x in row_v] for row_v in vars_],
            "state_p": [round(x, 10) for x in state_p],
        }

    rsp_spy = [yf_ffill["RSP"][i] / max(yf_ffill["SPY"][i], 1e-8) for i in range(n)]
    iwm_qqq = [yf_ffill["IWM"][i] / max(yf_ffill["QQQ"][i], 1e-8) for i in range(n)]
    rsp_sma50 = rolling_mean(rsp_spy, 50)
    iwm_sma50 = rolling_mean(iwm_qqq, 50)
    xlp0, xlu0, xlv0, xlk0 = yf_ffill["XLP"][0], yf_ffill["XLU"][0], yf_ffill["XLV"][0], yf_ffill["XLK"][0]
    def_tech = [
        (((yf_ffill["XLP"][i] / xlp0) + (yf_ffill["XLU"][i] / xlu0) + (yf_ffill["XLV"][i] / xlv0)) / 3.0)
        / (yf_ffill["XLK"][i] / xlk0)
        for i in range(n)
    ]

    cal_idx_by_date = {d: i for i, d in enumerate(cal)}
    rows_eval = [r for r in rows_all if r["date"] >= start_eval_date]

    signals_m0_on: list[dict[str, Any]] = []
    signals_m0_off: list[dict[str, Any]] = []
    feat_cols = [
        "date",
        "skew10",
        "skew_p75",
        "vvix",
        "vvix_p75",
        "vr_jump5",
        "hmm_p",
        "hmm_p5",
        "ewmac",
        "ema20",
        "sma200",
        "hyg_lqd",
        "hyg_sma50",
        "baa_lag1",
        "baa_rise63",
        "dgs2_lag1",
        "dgs2_jump63",
        "nfci_lag5",
        "nfci_jump20",
        "rsp_spy",
        "rsp_sma50",
        "iwm_qqq",
        "iwm_sma50",
        "def_ret20",
        "baa_obs_date",
        "dgs2_obs_date",
        "nfci_obs_date",
    ]
    feat_rows: list[list[Any]] = []

    def _r4(v: float | None) -> float | None:
        return None if (v is None or math.isnan(v)) else round(float(v), 5)

    for b_row in rows_eval:
        d = b_row["date"]
        i = cal_idx_by_date[d]
        vr = vix_r[i]
        vx = vxn_cl[i]
        vr_j5 = (vr - vix_r[i - 5]) if i >= 5 else 0.0

        m2_a = bool(
            skew10[i] is not None
            and skew_p75[i] is not None
            and vvix_p75[i] is not None
            and skew10[i] >= skew_p75[i]
            and vvix[i] >= vvix_p75[i]
            and 0.85 <= vr <= 0.98
        )
        m2_b = bool((0.92 <= vr <= 1.02) and (vr_j5 >= 0.06) and (vvix[i] >= 100.0))
        m2 = bool((m2_a or m2_b) and vx <= 24.0)

        baa_r = (baa_lag1[i] - baa_min63[i]) if (baa_lag1[i] is not None and baa_min63[i] is not None) else -999.0
        dgs2_j = (
            (dgs2_lag1[i] - dgs2_lag1[i - 63])
            if (i >= 63 and dgs2_lag1[i] is not None and dgs2_lag1[i - 63] is not None)
            else -999.0
        )
        nfci_j = (
            (nfci_lag5[i] - nfci_lag5[i - 20])
            if (i >= 20 and nfci_lag5[i] is not None and nfci_lag5[i - 20] is not None)
            else -999.0
        )
        m3 = bool(
            hyg_lqd_sma50[i] is not None
            and hyg_lqd[i] < hyg_lqd_sma50[i]
            and (baa_r >= 0.15 or dgs2_j >= 0.40 or nfci_j >= 0.10)
            and vx <= 26.0
            and vr <= 0.92
        )

        m4 = bool(
            sma200[i] is not None
            and ewmac[i] is not None
            and ema20[i] is not None
            and qqq_cl[i] < sma200[i]
            and ewmac[i] < 0.0
            and qqq_cl[i] > ema20[i]
            and vx <= 27.0
            and vr <= 0.88
        )

        hp_cur = p_hmm[i]
        hp_prev5 = p_hmm[i - 5] if i >= 5 else None
        m5 = bool(
            hp_cur is not None
            and hp_prev5 is not None
            and hp_cur >= 0.55
            and hp_prev5 < 0.40
            and vx <= 24.0
            and vr < 1.02
        )

        ad_weak = bool(
            b_row.get("ad_line") is not None
            and b_row.get("ad_sma50") is not None
            and float(b_row["ad_line"]) < float(b_row["ad_sma50"])
        )
        def_r20 = (def_tech[i] / def_tech[i - 20] - 1.0) if i >= 20 else 0.0
        rsp_weak = bool(rsp_sma50[i] is not None and rsp_spy[i] < rsp_sma50[i])
        iwm_weak = bool(iwm_sma50[i] is not None and iwm_qqq[i] < iwm_sma50[i])

        m0_val = bool(b_row["sw_u1"])
        m6_on = bool(rsp_weak and (iwm_weak or ad_weak) and def_r20 >= 0.025 and vx <= 25.0 and vr <= 0.92)
        m6_off = bool(rsp_weak and iwm_weak and def_r20 >= 0.025 and vx <= 25.0 and vr <= 0.92)

        stress_day = compute_live_stress_index(
            hmm_p=_r4(hp_cur) or 0.0,
            vxn=float(b_row["vxn"]),
            vix_ratio=float(b_row["vix_ratio"]),
            dd_from_ath=float(b_row["dd_from_ath"]),
            close=float(b_row["close"]),
            sma200=_r4(sma200[i]) or 0.0,
            ewmac=_r4(ewmac[i]) or 0.0,
            hyg_lqd=_r4(hyg_lqd[i]) or 0.0,
            hyg_sma50=_r4(hyg_lqd_sma50[i]) or 0.0,
            baa_rise63=_r4(baa_r if baa_r > -900 else None),
            dgs2_jump63=_r4(dgs2_j if dgs2_j > -900 else None),
            nfci_jump20=_r4(nfci_j if nfci_j > -900 else None),
            def_ret20=_r4(def_r20) or 0.0,
            rsp_spy=_r4(rsp_spy[i]) or 0.0,
            rsp_sma50=_r4(rsp_sma50[i]) or 0.0,
            iwm_qqq=_r4(iwm_qqq[i]) or 0.0,
            iwm_sma50=_r4(iwm_sma50[i]) or 0.0,
            ad_below50=ad_weak,
            vvix=_r4(vvix[i]) or 0.0,
            vvix_p75=_r4(vvix_p75[i]) or 0.0,
            skew10=_r4(skew10[i]) or 0.0,
            skew_p75=_r4(skew_p75[i]) or 0.0,
            vr_jump5=_r4(vr_j5) or 0.0,
        )
        live_stress_idx = int(stress_day["live_stress_index"])

        for is_on, m0_b, m6_b, dest in (
            (True, m0_val, m6_on, signals_m0_on),
            (False, False, m6_off, signals_m0_off),
        ):
            p1 = min(45.0, (35.0 if m0_b else 0.0) + (20.0 if m6_b else 0.0))
            p2 = min(40.0, (20.0 if m2 else 0.0) + (20.0 if m5 else 0.0))
            p3 = min(45.0, (35.0 if m4 else 0.0) + (20.0 if m3 else 0.0))
            prob = min(100.0, p1 + p2 + p3)
            t_m7g = 3 if prob >= 65.0 else (2 if prob >= 45.0 else (1 if prob >= 35.0 else 0))
            t_m7 = 2 if prob >= 35.0 else 0
            p1_c3 = p1
            p2_c3 = 0.0
            p3_c3 = 35.0 if m4 else 0.0
            prob_c3 = min(100.0, p1_c3 + p3_c3)
            t_c3 = 3 if prob_c3 >= 65.0 else (2 if prob_c3 >= 45.0 else (1 if prob_c3 >= 35.0 else 0))
            mask = (
                (1 if m0_b else 0)
                | (2 if m6_b else 0)
                | (4 if m2 else 0)
                | (8 if m5 else 0)
                | (16 if m4 else 0)
                | (32 if m3 else 0)
            )
            mask_c3 = (1 if m0_b else 0) | (2 if m6_b else 0) | (16 if m4 else 0)
            dest.append(
                {
                    "date": d,
                    "m0_enabled": is_on,
                    "M0": m0_b,
                    "M6": m6_b,
                    "M2": m2,
                    "M2_silent_tail": m2_a,
                    "M2_term_inflection": m2_b,
                    "M5": m5,
                    "M4": m4,
                    "M3": m3,
                    "p1": p1,
                    "p2": p2,
                    "p3": p3,
                    "crisis_prob": prob,
                    "target_slots_m7g": t_m7g,
                    "target_slots_m7": t_m7,
                    "p1_c3": p1_c3,
                    "p2_c3": p2_c3,
                    "p3_c3": p3_c3,
                    "crisis_prob_c3": prob_c3,
                    "target_slots_c3": t_c3,
                    "mask": mask,
                    "mask_c3": mask_c3,
                    "redline_blocked": bool(vx > 27.0 or vr >= 1.02),
                    "hmm_p": round(float(hp_cur), 4) if hp_cur is not None else 0.0,
                    "live_stress": live_stress_idx,
                }
            )

        feat_rows.append(
            [
                d,
                _r4(skew10[i]),
                _r4(skew_p75[i]),
                _r4(vvix[i]),
                _r4(vvix_p75[i]),
                _r4(vr_j5),
                _r4(hp_cur),
                _r4(hp_prev5),
                _r4(ewmac[i]),
                _r4(ema20[i]),
                _r4(sma200[i]),
                _r4(hyg_lqd[i]),
                _r4(hyg_lqd_sma50[i]),
                _r4(baa_lag1[i]),
                _r4(baa_r if baa_r > -900 else None),
                _r4(dgs2_lag1[i]),
                _r4(dgs2_j if dgs2_j > -900 else None),
                _r4(nfci_lag5[i]),
                _r4(nfci_j if nfci_j > -900 else None),
                _r4(rsp_spy[i]),
                _r4(rsp_sma50[i]),
                _r4(iwm_qqq[i]),
                _r4(iwm_sma50[i]),
                _r4(def_r20),
                baa_obs_dt[i] or d,
                dgs2_obs_dt[i] or d,
                nfci_obs_dt[i] or d,
            ]
        )

    tail_len = min(265, n)
    fred_cutoff_dt = cal[max(0, n - 120)]
    fred_tail = {
        fid: {d: round(float(v), 6) for d, v in m7_data["fred_raw"][fid].items() if d >= fred_cutoff_dt}
        for fid in FRED_LAGS
    }
    rows_recent_fred = [r for r in rows_all if r["date"] >= fred_cutoff_dt]
    fred_tail["DFF"] = {
        r["date"]: round(float(r["dff"]), 6) for r in rows_recent_fred if r.get("dff") is not None
    }
    fred_tail["T10Y2Y"] = {
        r["date"]: round(float(r["t10y2y"]), 6) for r in rows_recent_fred if r.get("t10y2y") is not None
    }
    rows_252 = rows_all[-min(252, len(rows_all)) :]
    last_bco = rows_all[-1]
    six_lights_tail = {
        "dgs2": [round(float(r.get("dgs2") or 0.0), 4) for r in rows_252],
        "dff": [round(float(r.get("dff") or 0.0), 4) for r in rows_252],
        "baa10y": [round(float(r.get("baa10y") or 0.0), 4) for r in rows_252],
        "copper": [round(float(r.get("copper") or 0.0), 4) for r in rows_252],
        "def_cyc": [round(float(r.get("def_cyc") or 0.0), 5) for r in rows_252],
        "t10y2y": [round(float(r.get("t10y2y") or 0.0), 4) for r in rows_252],
        "nfci": [round(float(r.get("nfci") or 0.0), 4) for r in rows_252],
        "scores": [int(r.get("score") or 0) for r in rows_all[-5:]],
        "breadth_fallback": {
            "as_of_date": str(last_bco["date"]),
            "ad_line": round(float(last_bco.get("ad_line") or 0.0), 2),
            "ad_sma50": round(float(last_bco.get("ad_sma50") or 0.0), 2),
            "ad_sma63": round(float(last_bco.get("ad_sma63") or 0.0), 2),
            "ad_hi252": round(float(last_bco.get("ad_hi252") or 0.0), 2),
            "pct_200d": round(float(last_bco.get("pct_200d") or 0.0), 6),
            "pct200_hi252": round(float(last_bco.get("pct200_hi252") or 0.0), 6),
            "sig3_breadth": bool(last_bco.get("sig3_breadth")),
        },
    }
    live_tail_state = {
        "tail_dates": cal[-tail_len:],
        "yf_tail": {k: [round(float(x), 6) for x in yf_ffill[k][-tail_len:]] for k in YF_ALL_KEYS},
        "fred_tail": fred_tail,
        "six_lights_tail": six_lights_tail,
        "base_2013": {
            "XLP": round(xlp0, 8),
            "XLU": round(xlu0, 8),
            "XLV": round(xlv0, 8),
            "XLK": round(xlk0, 8),
        },
        "ewm_state": {
            "ema20": round(float(ema20_last or 0.0), 8),
            "e16": round(float(e16_last or 0.0), 8),
            "e32": round(float(e32_last or 0.0), 8),
            "e64": round(float(e64_last or 0.0), 8),
            "e128": round(float(e128_last or 0.0), 8),
            "e256": round(float(e256_last or 0.0), 8),
        },
        "welford_4d": {
            "count": list(cnt),
            "mean": [round(x, 10) for x in mean_acc],
            "m2": [round(x, 10) for x in m2_acc],
        },
        "hmm": latest_hmm,
        "p_hmm_tail": [round(float(x or 0.0), 8) for x in p_hmm[-10:]],
    }

    return {
        "signals_m0_on": signals_m0_on,
        "signals_m0_off": signals_m0_off,
        "feature_table": {"_cols": feat_cols, "_rows": feat_rows},
        "live_tail_state": live_tail_state,
    }


def format_m7_trigger_labels(
    sig_day: dict[str, Any], max_slots: int, core3_only: bool = False
) -> tuple[list[str], str, str, str]:
    mods: list[str] = []
    p1_parts: list[str] = []
    p2_parts: list[str] = []
    p3_parts: list[str] = []
    if sig_day.get("M0"):
        mods.append("M0")
        p1_parts.append("M0(+35)")
    if sig_day.get("M6"):
        mods.append("M6")
        p1_parts.append("M6(+20)")
    if not core3_only and sig_day.get("M2"):
        mods.append("M2")
        p2_parts.append("M2(+20)")
    if not core3_only and sig_day.get("M5"):
        mods.append("M5")
        p2_parts.append("M5(+20)")
    if sig_day.get("M4"):
        mods.append("M4")
        p3_parts.append("M4(+35)")
    if not core3_only and sig_day.get("M3"):
        mods.append("M3")
        p3_parts.append("M3(+20)")

    pillar_tags: list[str] = []
    if p1_parts:
        pillar_tags.append("P1:" + "+".join(m.split("(")[0] for m in p1_parts))
    if p2_parts:
        pillar_tags.append("P2:" + "+".join(m.split("(")[0] for m in p2_parts))
    if p3_parts:
        pillar_tags.append("P3:" + "+".join(m.split("(")[0] for m in p3_parts))
    code = " + ".join(pillar_tags) if pillar_tags else ("Core-3" if core3_only else "M7")
    if core3_only:
        prob = int(round(float(sig_day.get("crisis_prob_c3") or 0.0)))
        tslots = int(sig_day.get("target_slots_c3") or 1)
    else:
        prob = int(round(float(sig_day.get("crisis_prob") or 0.0)))
        tslots = int(sig_day.get("target_slots_m7g" if max_slots == 3 else "target_slots_m7") or 1)
    trig_en = f"{code} · Score {prob}% (Target {tslots}/{max_slots} Slots)"
    trig_zh = f"{code} · 概率 {prob}%（目标 {tslots}/{max_slots} 槽）"
    return mods, code, trig_en, trig_zh


def compute_m7_bh_parity(rows_eval: list[dict[str, Any]], use_close_start: bool = True) -> dict[str, Any]:
    px0 = float(rows_eval[0]["close"]) if use_close_start else float(rows_eval[0]["open"])
    sh = INITIAL_CAPITAL / (px0 * (1.0 + STOCK_REBAL_FEE))
    navs: list[float] = []
    post_sh: list[float] = []
    pre_sh: list[float] = []
    for r in rows_eval:
        pre_sh.append(sh)
        div = float(r["dividends"])
        cl = float(r["close"])
        if div > 0.0:
            sh += (sh * div) / (cl * (1.0 + STOCK_REBAL_FEE))
        post_sh.append(sh)
        navs.append(sh * cl)
    return {
        "nav": navs,
        "end_nav": navs[-1],
        "final_shares": sh,
        "pre_sh": pre_sh,
        "post_sh": post_sh,
    }


def _classify_trade_source(entry_src: str, exit_src: str) -> str:
    if entry_src.startswith("real_opra") and exit_src.startswith("real_opra"):
        return "real_opra"
    if entry_src.startswith("real_polygon") or exit_src.startswith("real_polygon"):
        return "real_polygon"
    return "bsm_fallback"


def _classify_quote_source_tag(
    entry_src: str,
    exit_src: str,
    entry_date: str | None = None,
    exit_date: str | None = None,
    opra_max_date: str = "2025-12-15",
) -> str:
    in_opra_en = entry_src.startswith("real_opra") and (not entry_date or entry_date <= opra_max_date)
    in_opra_ex = exit_src.startswith("real_opra") and (exit_date is not None and exit_date <= opra_max_date)
    if in_opra_en and in_opra_ex:
        return "REAL_OPRA"
    return "CALIBRATED_BSM"


def simulate_m7_strategy(
    rows_eval: list[dict[str, Any]],
    coeffs: list[float],
    bco_mod: Any,
    strategy_id: str,
    sig_series: list[dict[str, Any]],
    put_otm: str = DEFAULT_PUT_OTM,
    m7_tp_mode: str = DEFAULT_M7_TP_MODE,
    roll_mode: str = DEFAULT_ROLL_MODE,
    m0_enabled: bool = DEFAULT_M0_ENABLED,
    cc_mode: str = "cc_off",
    sp_mode: str = "sp_off",
    wc_mode: str = "wc_reclaim_30d_d35",
    real_store: Any = None,
    fill_mode: str = "ask_bid",
) -> dict[str, Any]:
    """Simulate M7G_Graded (Full 6-Module Adaptive), Core3_Adaptive (M0+M6+M4 Minimal Adaptive),
    or M7_Ensemble (2 slots) using MIT Real QQQ OPRA Option Chain (2015-01-02..2025-12-15, strict
    Ask/Bid by default) + OPRA-Calibrated BSM (2025-12-16..Live with real-IV seam continuity),
    plus full Engine 2 Covered Call & Engine 3 Panic Put Reverse Wheel overlays.
    """
    use_real = real_store is not None and _roc_mod is not None
    is_core3 = strategy_id == "Core3_Adaptive"
    is_graded = strategy_id in ("M7G_Graded", "Core3_Adaptive")
    max_slots = 3 if is_graded else 2
    if is_core3 and roll_mode == "90d_hold":
        # Safety guardrail: never allow 90D Hold on Core-3 (degrades to 0.87x PF)
        roll_mode = "adaptive_120_90"
    if roll_mode not in ("adaptive_120_90", "120d_roll50", "90d_hold"):
        roll_mode = DEFAULT_ROLL_MODE

    put_moneyness = 0.80 if put_otm == "otm20" else 0.85
    otm_pct_int = 20 if put_otm == "otm20" else 15
    require_itm_tp = m7_tp_mode == "itm_tp"
    tp_code = "ITM_TP" if require_itm_tp else "STANDARD"
    is_adaptive = roll_mode == "adaptive_120_90"
    is_roll50 = roll_mode == "120d_roll50"
    opra_max_d = str(getattr(real_store, "opra_date_max", "2025-12-15") or "2025-12-15") if use_real else ""

    def _slots_for_sig(sd: dict[str, Any]) -> int:
        if is_core3:
            return int(sd["target_slots_c3"])
        if is_graded:
            return int(sd["target_slots_m7g"])
        return int(sd["target_slots_m7"])

    def _prob_tuple(sd: dict[str, Any]) -> tuple[float, float, float, float]:
        if is_core3:
            return (
                float(sd["crisis_prob_c3"]),
                float(sd["p1_c3"]),
                float(sd["p2_c3"]),
                float(sd["p3_c3"]),
            )
        return (
            float(sd["crisis_prob"]),
            float(sd["p1"]),
            float(sd["p2"]),
            float(sd["p3"]),
        )

    def _tenor_for_sig(is_cta_flag: bool) -> tuple[int, int, int, tuple[int, int], tuple[int, int]]:
        if is_adaptive:
            if is_cta_flag:
                return 90, 90, 30, (65, 120), (65, 120)
            return 120, 120, 50, (90, 155), (90, 155)
        if is_roll50:
            return 120, 120, 50, (90, 155), (90, 155)
        return 90, 90, 0, (65, 120), (65, 120)

    dates = [r["date"] for r in rows_eval]
    dt_objs = [datetime.date.fromisoformat(d) for d in dates]
    n_days = len(rows_eval)

    bh_m7 = compute_m7_bh_parity(rows_eval, use_close_start=use_real)
    final_bh_sh = bh_m7["final_shares"]
    final_cl = float(rows_eval[-1]["close"])

    px0 = float(rows_eval[0]["close"]) if use_real else float(rows_eval[0]["open"])
    core_shares = INITIAL_CAPITAL / (px0 * (1.0 + STOCK_REBAL_FEE))

    slot_coverage = 0.50
    ref_moneyness = 0.90
    target_dte = 120 if (is_adaptive or is_roll50) else 90
    roll_dte_thr = 50 if (is_adaptive or is_roll50) else 0
    step_cal_days = 30
    escalate_min_days = 21
    vix_ratio_tp = 1.10
    put_mult_tp = 5.0
    put_mult_max_dte = 45

    q_stats = {
        "total_lookups": 0,
        "real_opra_hits": 0,
        "real_polygon_hits": 0,
        "bsm_fallbacks": 0,
        "opra_window_fallbacks": 0,
    }

    def _rec_src(src: str, d_str: str = "") -> None:
        q_stats["total_lookups"] += 1
        if src.startswith("real_opra"):
            q_stats["real_opra_hits"] += 1
        elif src.startswith("real_polygon"):
            q_stats["real_polygon_hits"] += 1
        else:
            q_stats["bsm_fallbacks"] += 1
            if opra_max_d and d_str and d_str <= opra_max_d:
                q_stats["opra_window_fallbacks"] += 1

    def _is_exp(idx: int, exp_dt: datetime.date) -> bool:
        if use_real:
            return _roc_mod.is_expiry_day(idx, dt_objs, exp_dt)
        return dt_objs[idx] >= exp_dt

    def _occ(exp_str: str, opt_type: str, k_val: float) -> str:
        if _roc_mod is not None and hasattr(_roc_mod, "format_occ_symbol"):
            return _roc_mod.format_occ_symbol("QQQ", exp_str, opt_type, k_val)
        return f"QQQ-{exp_str}-{opt_type[0].upper()}-{k_val:.2f}"

    def _lookup_opt(
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
        slip_bsm: float = OPT_SLIP,
        iv_ratio_anchor: float | None = None,
    ) -> tuple[float, float, float, float, float, str]:
        if use_real and k_cents is not None:
            b, a, m, iv, dl, src = real_store.lookup_contract(
                d_str,
                opt_type,
                exp_str,
                k_cents,
                spot_px,
                rem_days,
                r_c,
                q_c,
                vxn_c,
                last_iv,
                coeffs,
                bco_mod.eval_skew_iv,
                bco_mod.bsm_price,
                slip_bsm=slip_bsm,
                iv_ratio_anchor=iv_ratio_anchor,
            )
            _rec_src(src, d_str)
            return b, a, m, iv, dl, src
        t_r = max(0, rem_days) / 365.0
        sig = bco_mod.eval_skew_iv(spot_px, k_val, max(t_r, 1.0 / 365.0), r_c, q_c, vxn_c, coeffs)
        if iv_ratio_anchor is not None and math.isfinite(iv_ratio_anchor) and 0.4 <= iv_ratio_anchor <= 2.5:
            sig = max(0.05, min(2.5, sig * iv_ratio_anchor))
        mid = bco_mod.bsm_price(spot_px, k_val, t_r, r_c, q_c, sig, opt_type)
        dl = bco_mod.bsm_call_delta(spot_px, k_val, t_r, r_c, q_c, sig) if opt_type == "call" else (bco_mod.bsm_call_delta(spot_px, k_val, t_r, r_c, q_c, sig) - math.exp(-q_c * t_r))
        _rec_src("bsm_fallback", d_str)
        return max(0.0, mid * (1.0 - slip_bsm)), mid * (1.0 + slip_bsm), mid, sig, dl, "bsm_fallback"

    def _buy_px(bid: float, ask: float, mid: float, src: str, slip_bsm: float = OPT_SLIP) -> float:
        if use_real:
            return _roc_mod.exec_buy_price(bid, ask, mid, src, slip_bsm=slip_bsm, fill_mode=fill_mode)
        return mid * (1.0 + slip_bsm) + OPT_COMM_PER_SH

    def _sell_px(bid: float, ask: float, mid: float, src: str, slip_bsm: float = OPT_SLIP) -> float:
        if use_real:
            return _roc_mod.exec_sell_price(bid, ask, mid, src, slip_bsm=slip_bsm, fill_mode=fill_mode)
        return max(0.0, mid * (1.0 - slip_bsm) - OPT_COMM_PER_SH)

    cc_cfg_map: dict[str, tuple[float, float, float, float | None, str | None]] = {
        "cc_d12_d35": (0.0, 0.12, 0.05, 0.35, None),
        "cc_d12_r45": (0.0, 0.12, 0.05, 0.45, "fresh_30d"),
        "cc_d12_cr55": (0.0, 0.12, 0.05, 0.55, "credit_45d"),
    }
    cc_enabled = cc_mode in cc_cfg_map
    cc_min_vxn, cc_target_delta, cc_min_otm, cc_stop_delta, cc_roll_mode = cc_cfg_map.get(
        cc_mode, (0.0, 0.12, 0.05, None, None)
    )
    cc_ath_limit = 0.03
    cc_dte = 25
    cc_max_rolls = 3

    sp_cfg_map: dict[str, tuple[int, float, float, float, bool]] = {
        "sp_14d_cap10": (14, 0.05, 0.10, 1.00, False),
        "sp_10d_vixf": (10, 0.05, 0.20, 1.00, True),
        "sp_14d_unf": (14, 0.05, 0.20, 1.00, False),
    }
    sp_enabled = sp_mode in sp_cfg_map
    sp_dte, sp_otm_pct, sp_max_lev, sp_vix_thr, sp_require_vix_falling = sp_cfg_map.get(
        sp_mode, (14, 0.05, 0.0, 1.00, False)
    )

    active_tranches: list[dict[str, Any]] = []
    pending_sig: dict[str, Any] | None = None
    active_cc: dict[str, Any] | None = None
    pending_cc: dict[str, Any] | None = None
    pending_cc_deploy = False
    cc_cash = 0.0
    cc_gross_prem = 0.0
    cc_gross_loss = 0.0
    cc_assigned_cnt = 0
    cc_funded_puts = 0.0
    cc_tid = 0
    cc_ledger: list[dict[str, Any]] = []

    active_sp: dict[str, Any] | None = None
    pending_sp: dict[str, Any] | None = None
    active_wc: dict[str, Any] | None = None
    pending_wc: dict[str, Any] | None = None
    assigned_shares = 0.0
    assigned_cost_k = 0.0
    sp_cash = 0.0
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
    sp_tid = 0
    wc_tid = 0
    sp_closed_ledger: list[dict[str, Any]] = []
    wc_closed_ledger: list[dict[str, Any]] = []

    ledger: list[dict[str, Any]] = []
    nav_list: list[float] = []
    equiv_sh_list: list[float] = []
    active_slots_list: list[int] = []
    any_active_list: list[int] = []
    tid = 0

    def _sweep_sp_cash(px: float) -> None:
        nonlocal core_shares, sp_cash
        if abs(sp_cash) > 1e-8:
            denom = px * (1.0 + (STOCK_REBAL_FEE if sp_cash > 0 else -STOCK_REBAL_FEE))
            core_shares += sp_cash / denom
            sp_cash = 0.0

    def _estimate_nav_exec(ex_px: float, vxn_e: float, r_c: float, q_c: float, cur_dt: datetime.date, d_str: str) -> float:
        mtm_p = 0.0
        for tr_o in active_tranches:
            rem_d_o = max(1, (tr_o["exp_dt"] - cur_dt).days)
            _, _, pm_o, _, _, _ = _lookup_opt(
                d_str, "put", tr_o["exp_date"], tr_o["kp"], tr_o.get("k_cents"),
                ex_px, rem_d_o, r_c, q_c, vxn_e, tr_o.get("last_iv"), slip_bsm=OPT_SLIP
            )
            mtm_p += tr_o["hedged_shares"] * pm_o
        mtm_cc_o = 0.0
        if active_cc is not None:
            rem_c_o = max(1, (active_cc["exp_dt"] - cur_dt).days)
            _, _, cm_o, _, _, _ = _lookup_opt(
                d_str, "call", active_cc["exp_date"], active_cc["kc"], active_cc.get("k_cents"),
                ex_px, rem_c_o, r_c, q_c, vxn_e, active_cc.get("last_iv"), slip_bsm=OPT_SLIP
            )
            mtm_cc_o = -active_cc["shares"] * cm_o
        return max(1.0, (core_shares + assigned_shares) * ex_px + cc_cash + sp_cash + mtm_p + mtm_cc_o)

    for i, d in enumerate(dates):
        row = rows_eval[i]
        sig_d = sig_series[i]
        op = float(row["open"])
        cl = float(row["close"])
        div = float(row["dividends"])
        vxn_cl = float(row["vxn"])
        vix_r = float(row["vix_ratio"])
        r_cur = float(row["r"])
        q_cur = float(row["div_yield"])
        dd_cur = float(row["dd_from_ath"])

        if use_real:
            exec_px = cl
            vxn_ex = vxn_cl
        else:
            exec_px = op
            if i > 0:
                prev_vxn = float(rows_eval[i - 1]["vxn"])
                prev_cl = float(rows_eval[i - 1]["close"])
                vxn_ex = max(10.0, prev_vxn - 0.45 * (op / prev_cl - 1.0) * 100.0)
            else:
                vxn_ex = vxn_cl

        mult_morning = (final_bh_sh / bh_m7["pre_sh"][i]) * final_cl
        mult_eod = (final_bh_sh / bh_m7["post_sh"][i]) * final_cl

        if i > 0:
            dt_yr = max(1, (dt_objs[i] - dt_objs[i - 1]).days) / 365.0
            r_prev = float(rows_eval[i - 1]["r"])
            if cc_cash > 0.0:
                cc_cash *= 1.0 + r_prev * dt_yr
            if sp_cash > 0.0:
                sp_cash *= 1.0 + r_prev * dt_yr
            elif sp_cash < 0.0:
                m_int = abs(sp_cash) * (r_prev + MARGIN_SPREAD) * dt_yr
                sp_cash -= m_int
                sp_margin_interest_total += m_int

        if i > 0 and pending_cc_deploy and cc_cash > 1.0:
            core_shares += cc_cash / (exec_px * (1.0 + STOCK_REBAL_FEE))
            cc_cash = 0.0
            pending_cc_deploy = False

        if i > 0 and active_cc is not None and active_cc.get("pending_close"):
            rem_cc = max(0, (active_cc["exp_dt"] - dt_objs[i]).days)
            if _is_exp(i, active_cc["exp_dt"]):
                c_ask_ex = max(0.0, exec_px - active_cc["kc"])
                src_cc_ex = active_cc.get("entry_source", "bsm_fallback")
            else:
                b_c, a_c, m_c, _, _, src_cc_ex = _lookup_opt(
                    d, "call", active_cc["exp_date"], active_cc["kc"], active_cc.get("k_cents"),
                    exec_px, rem_cc, r_cur, q_cur, vxn_ex, active_cc.get("last_iv"), slip_bsm=OPT_SLIP
                )
                c_ask_ex = _buy_px(b_c, a_c, m_c, src_cc_ex, slip_bsm=OPT_SLIP)
            cost_cl = active_cc["shares"] * c_ask_ex
            cc_gross_loss += cost_cl
            if cc_cash >= cost_cl:
                cc_cash -= cost_cl
            else:
                core_shares -= (cost_cl - cc_cash) / (exec_px * (1.0 - STOCK_REBAL_FEE))
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
                    "exit_spot": round(exec_px, 2),
                    "entry_vxn": round(active_cc["entry_vxn"], 2),
                    "shares": round(old_sh, 2),
                    "prem_usd": round(active_cc["prem_usd"], 2),
                    "loss_usd": round(cost_cl, 2),
                    "net_pnl_usd": round(active_cc["prem_usd"] - cost_cl, 2),
                    "exit_reason": close_reason,
                    "roll_gen": old_rolls,
                    "pricing_source": _classify_trade_source(cc_en_src, src_cc_ex),
                }
            )
            active_cc = None
            if close_reason in ("delta_roll_up", "delta_credit_roll") and cc_roll_mode is not None and old_rolls < cc_max_rolls:
                roll_days = 45 if cc_roll_mode == "credit_45d" else 30
                c_roll = None
                if use_real:
                    if cc_roll_mode == "credit_45d":
                        c_roll = real_store.select_call_contract_for_bid(
                            d, exec_px, 45, c_ask_ex, exec_px * 1.01, 32, 62, r_cur, q_cur,
                            rec_tag=f"cc_45_cr_{int(round(c_ask_ex * 100))}",
                        )
                    elif cc_roll_mode == "fresh_30d":
                        c_roll = real_store.select_call_contract_delta(
                            d, exec_px, 30, cc_target_delta, exec_px * (1.0 + cc_min_otm), 20, 42, r_cur, q_cur,
                            rec_tag="cc_30_d12",
                        )
                if c_roll is not None:
                    _rec_src(c_roll["source"])
                    exp_date_r, exp_dt_r = c_roll["exp"], c_roll["exp_dt"]
                    kc_new = c_roll["strike"]
                    k_cents_r = c_roll["k_cents"]
                    c_bid_r = _sell_px(c_roll["bid"], c_roll["ask"], c_roll["mid"], c_roll["source"], slip_bsm=OPT_SLIP)
                    iv_r = c_roll["iv"]
                    src_r = c_roll["source"]
                else:
                    target_r = dt_objs[i] + datetime.timedelta(days=roll_days)
                    pos_r = bisect.bisect_left(dt_objs, target_r)
                    exp_date_r, exp_dt_r = (dates[pos_r], dt_objs[pos_r]) if pos_r < n_days else (target_r.isoformat(), target_r)
                    t_r = max(1, (exp_dt_r - dt_objs[i]).days) / 365.0
                    kc_new = None
                    if cc_roll_mode == "credit_45d":
                        kc_new = bco_mod.solve_call_strike_for_bid(exec_px, t_r, r_cur, q_cur, vxn_ex, coeffs, c_ask_ex, OPT_SLIP)
                    elif cc_roll_mode == "fresh_30d":
                        kc_new = max(
                            exec_px * (1.0 + cc_min_otm),
                            bco_mod.solve_call_strike_for_delta(exec_px, t_r, r_cur, q_cur, vxn_ex, coeffs, cc_target_delta),
                        )
                    if kc_new is not None and kc_new > exec_px * 1.01:
                        iv_r = bco_mod.eval_skew_iv(exec_px, kc_new, t_r, r_cur, q_cur, vxn_ex, coeffs)
                        cm_r = bco_mod.bsm_price(exec_px, kc_new, t_r, r_cur, q_cur, iv_r, "call")
                        c_bid_r = _sell_px(cm_r * (1.0 - OPT_SLIP), cm_r * (1.0 + OPT_SLIP), cm_r, "bsm_fallback", slip_bsm=OPT_SLIP)
                        k_cents_r = int(round(kc_new * 100.0))
                        src_r = "bsm_fallback"
                        _rec_src(src_r)
                    else:
                        c_bid_r = 0.0
                        k_cents_r = None
                        iv_r = None
                        src_r = "bsm_fallback"
                if kc_new is not None and kc_new > exec_px * 1.01 and c_bid_r >= 0.05:
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
                        "entry_spot": exec_px,
                        "entry_vxn": vxn_ex,
                        "kc": kc_new,
                        "k_cents": k_cents_r,
                        "last_iv": iv_r,
                        "entry_source": src_r,
                        "shares": old_sh,
                        "prem_usd": prem_r,
                        "pending_close": False,
                        "roll_count": old_rolls + 1,
                    }

        # 1. Pending M7 TP / Adaptive-Roll Exits at T+1
        if i > 0 and any(t.get("pending_tp") or t.get("pending_roll") for t in active_tranches):
            still_open: list[dict[str, Any]] = []
            roll_replacements: list[tuple[float, int, dict[str, Any]]] = []
            for tr in active_tranches:
                if not tr.get("pending_tp") and not tr.get("pending_roll"):
                    still_open.append(tr)
                    continue
                rem_days = max(0, (tr["exp_dt"] - dt_objs[i]).days)
                t_rem = rem_days / 365.0
                if _is_exp(i, tr["exp_dt"]):
                    put_bid = max(0.0, tr["kp"] - exec_px)
                    b_ex, a_ex = put_bid, put_bid
                    src_ex = tr.get("entry_source", "bsm_fallback")
                else:
                    b_ex, a_ex, m_ex, _, _, src_ex = _lookup_opt(
                        d, "put", tr["exp_date"], tr["kp"], tr.get("k_cents"),
                        exec_px, rem_days, r_cur, q_cur, vxn_ex, tr.get("last_iv"),
                        slip_bsm=OPT_SLIP, iv_ratio_anchor=tr.get("iv_ratio_anchor"),
                    )
                    put_bid = _sell_px(b_ex, a_ex, m_ex, src_ex, slip_bsm=OPT_SLIP)
                exit_usd = tr["hedged_shares"] * put_bid
                is_roll_exit = bool(tr.get("pending_roll")) and not bool(tr.get("pending_tp"))
                tr_roll_thr_val = int(tr.get("roll_dte_thr") or 50)
                exit_rsn = (tr.get("tp_reason") or f"roll_{tr_roll_thr_val}d") if is_roll_exit else tr["tp_reason"]

                prev_sig_d = sig_series[i - 1]
                prev_cap = _slots_for_sig(prev_sig_d)
                will_auto_roll = is_roll_exit and prev_cap > len(still_open) + len(roll_replacements)

                d_sh = 0.0
                if not will_auto_roll and abs(exit_usd) > 1e-10:
                    denom = exec_px * (1.0 + (STOCK_REBAL_FEE if exit_usd >= 0 else -STOCK_REBAL_FEE))
                    d_sh = exit_usd / denom
                    core_shares += d_sh
                elif will_auto_roll:
                    roll_replacements.append((exit_usd, prev_cap, prev_sig_d))

                roi_mult = (exit_usd / tr["entry_cost_usd"]) if tr["entry_cost_usd"] > 1e-6 else 0.0
                actual_net_sh = put_bid - tr["entry_put_ask"]
                conv = bco_mod.decompose_tranche_convexity(
                    "naked_put",
                    tr["entry_spot"],
                    exec_px,
                    tr["kp"],
                    None,
                    tr["T_entry"],
                    t_rem,
                    tr["entry_r"],
                    r_cur,
                    tr["entry_q"],
                    q_cur,
                    tr["entry_vxn"],
                    vxn_ex,
                    coeffs,
                    actual_net_sh,
                )
                hs = tr["hedged_shares"]
                en_src = tr.get("entry_source", "bsm_fallback")
                q_tag = _classify_quote_source_tag(en_src, src_ex, tr["entry_date"], d, opra_max_d or "2025-12-15")
                occ_sym = str(tr.get("occ_symbol") or _occ(tr["exp_date"], "put", tr["kp"]))
                ledger.append(
                    {
                        "tranche_id": tr["tranche_id"],
                        "strategy_id": strategy_id,
                        "slot_num": tr["slot_num"],
                        "tier": tr["tier"],
                        "max_slots": max_slots,
                        "tranche_type": "naked_put",
                        "put_otm_pct": otm_pct_int,
                        "tp_mode": tp_code,
                        "roll_mode": roll_mode,
                        "target_dte": int(tr.get("target_dte") or target_dte),
                        "roll_dte": int(tr.get("roll_dte_thr") or 0),
                        "is_cta": bool(tr.get("is_cta", False)),
                        "quoteSource": q_tag,
                        "quote_source": q_tag,
                        "occSymbol": occ_sym,
                        "occ_symbol": occ_sym,
                        "exp": tr["exp_date"],
                        "strike": round(tr["kp"], 2),
                        "entryBid": round(float(tr.get("entry_bid_raw", tr["entry_put_ask"])), 3),
                        "entryAsk": round(float(tr.get("entry_ask_raw", tr["entry_put_ask"])), 3),
                        "exitBid": round(float(b_ex), 3),
                        "exitAsk": round(float(a_ex), 3),
                        "pricing_source": _classify_trade_source(en_src, src_ex),
                        "entry_source": en_src,
                        "exit_source": src_ex,
                        "signal_date": tr["signal_date"],
                        "entry_date": tr["entry_date"],
                        "planned_exp_date": tr["exp_date"],
                        "exit_date": d,
                        "actual_days_held": (dt_objs[i] - tr["entry_dt"]).days,
                        "rem_dte_at_exit": rem_days,
                        "exit_reason": exit_rsn,
                        "sig_score": tr["sig_score"],
                        "sig_ad_below50": tr["sig_ad_below50"],
                        "crisis_prob": tr["crisis_prob"],
                        "p1": tr["p1"],
                        "p2": tr["p2"],
                        "p3": tr["p3"],
                        "triggered_modules": tr["triggered_modules"],
                        "trigger_code": tr["trigger_code"],
                        "trigger_en": tr["trigger_en"],
                        "trigger_zh": tr["trigger_zh"],
                        "entry_spot": round(tr["entry_spot"], 2),
                        "entry_vxn": round(tr["entry_vxn"], 2),
                        "entry_vix_ratio": round(tr["entry_vix_ratio"], 3),
                        "kp": round(tr["kp"], 2),
                        "kc": None,
                        "call_cap_pct": None,
                        "hedged_shares": round(hs, 2),
                        "contracts_est": round(hs / 100.0, 2),
                        "slot_coverage": round(tr["hedged_ratio"], 4),
                        "entry_put_ask_sh": round(tr["entry_put_ask"], 4),
                        "tp_target_5x_sh": round(5.0 * tr["entry_put_ask"], 4),
                        "entry_cost_usd": round(tr["entry_cost_usd"], 2),
                        "entry_shares_sold": round(tr["entry_shares_sold"], 4),
                        "exit_spot": round(exec_px, 2),
                        "exit_vxn": round(vxn_ex, 2),
                        "exit_vix_ratio": round(tr["tp_trigger_ratio"], 3),
                        "underlying_ret_pct": round((exec_px / tr["entry_spot"] - 1.0) * 100.0, 2),
                        "put_exit_val_sh": round(put_bid, 4),
                        "call_exit_cost_sh": 0.0,
                        "exit_net_cash_usd": round(exit_usd, 2),
                        "net_pnl_usd": round(exit_usd - tr["entry_cost_usd"], 2),
                        "roi_mult": round(roi_mult, 2),
                        "exit_shares_delta": round(d_sh, 2),
                        "shares_added": round(tr["entry_shares_sold"] + d_sh, 2),
                        "delta0": round(float(conv["delta0"]), 4),
                        "delta_usd": round(float(conv["dV_delta_sh"]) * hs, 2),
                        "gamma_usd": round(float(conv["dV_gamma_sh"]) * hs, 2),
                        "vega_usd": round(float(conv["dV_vega_sh"]) * hs, 2),
                        "theta_slip_usd": round(
                            round(exit_usd - tr["entry_cost_usd"], 2)
                            - (
                                round(float(conv["dV_delta_sh"]) * hs, 2)
                                + round(float(conv["dV_gamma_sh"]) * hs, 2)
                                + round(float(conv["dV_vega_sh"]) * hs, 2)
                            ),
                            2,
                        ),
                        "convexity_mult": round(float(conv["conv_mult"]), 2) if conv["conv_mult"] is not None else None,
                        "comp_entry_cost_usd": round(tr["comp_entry_cost_usd"], 2),
                        "comp_put_gain_usd": round(d_sh * mult_morning, 2),
                        "comp_call_drag_usd": 0.0,
                    }
                )
            active_tranches = still_open

            # Direct Adaptive Roll replacements using salvaged cash without double stock-fee churn
            for salv_usd, r_cap, r_sig_d in roll_replacements:
                r_en, q_en = r_cur, q_cur
                vxn_en = vxn_ex
                is_cta_r = bool(r_sig_d.get("M4", False))
                tr_tgt_dte, tr_ref_dte, tr_roll_thr, (lo_put_r, hi_put_r), (lo_ref_r, hi_ref_r) = _tenor_for_sig(is_cta_r)
                c_ref = None
                c_en = None
                if use_real:
                    c_ref = real_store.select_put_contract(
                        d, exec_px, tr_ref_dte, ref_moneyness, lo_ref_r, hi_ref_r, r_en, q_en,
                        rec_tag=f"p_{tr_ref_dte}_10",
                    )
                    c_en = real_store.select_put_contract(
                        d, exec_px, tr_tgt_dte, put_moneyness, lo_put_r, hi_put_r, r_en, q_en,
                        rec_tag=f"p_{tr_tgt_dte}_{otm_pct_int}",
                    )
                    if opra_max_d and d <= opra_max_d and (c_ref is None or c_en is None):
                        if salv_usd > 1e-8:
                            core_shares += salv_usd / (exec_px * (1.0 + STOCK_REBAL_FEE))
                        continue
                if c_ref is not None:
                    _rec_src(c_ref["source"], d)
                    put_ask_ref = _buy_px(c_ref["bid"], c_ref["ask"], c_ref["mid"], c_ref["source"], slip_bsm=OPT_SLIP)
                else:
                    ref_cal = dt_objs[i] + datetime.timedelta(days=tr_ref_dte)
                    pos_ref = bisect.bisect_left(dt_objs, ref_cal)
                    exp_dt_ref = dt_objs[pos_ref] if pos_ref < n_days else ref_cal
                    t_ref = max(1, (exp_dt_ref - dt_objs[i]).days) / 365.0
                    kp_ref = exec_px * ref_moneyness
                    sig_ref = bco_mod.eval_skew_iv(exec_px, kp_ref, t_ref, r_en, q_en, vxn_en, coeffs)
                    mid_ref = bco_mod.bsm_price(exec_px, kp_ref, t_ref, r_en, q_en, sig_ref, "put")
                    put_ask_ref = _buy_px(mid_ref * (1.0 - OPT_SLIP), mid_ref * (1.0 + OPT_SLIP), mid_ref, "bsm_fallback", slip_bsm=OPT_SLIP)
                    _rec_src("bsm_fallback", d)
                if c_en is not None:
                    _rec_src(c_en["source"], d)
                    exp_date = c_en["exp"]
                    exp_dt = c_en["exp_dt"]
                    t_en = max(1, (exp_dt - dt_objs[i]).days) / 365.0
                    kp = c_en["strike"]
                    k_cents_en = c_en["k_cents"]
                    en_bid_raw = float(c_en["bid"])
                    en_ask_raw = float(c_en["ask"])
                    put_ask_en = _buy_px(en_bid_raw, en_ask_raw, c_en["mid"], c_en["source"], slip_bsm=OPT_SLIP)
                    iv_en = c_en["iv"]
                    src_en = c_en["source"]
                    occ_en = str(c_en.get("occ_symbol") or _occ(exp_date, "put", kp))
                else:
                    target_cal = dt_objs[i] + datetime.timedelta(days=tr_tgt_dte)
                    pos = bisect.bisect_left(dt_objs, target_cal)
                    exp_date, exp_dt = (dates[pos], dt_objs[pos]) if pos < n_days else (target_cal.isoformat(), target_cal)
                    t_en = max(1, (exp_dt - dt_objs[i]).days) / 365.0
                    kp = round(exec_px * put_moneyness, 2)
                    k_cents_en = int(round(kp * 100.0))
                    iv_en = bco_mod.eval_skew_iv(exec_px, kp, t_en, r_en, q_en, vxn_en, coeffs)
                    mid_en = bco_mod.bsm_price(exec_px, kp, t_en, r_en, q_en, iv_en, "put")
                    en_bid_raw = max(0.0, mid_en * (1.0 - OPT_SLIP))
                    en_ask_raw = mid_en * (1.0 + OPT_SLIP)
                    put_ask_en = _buy_px(en_bid_raw, en_ask_raw, mid_en, "bsm_fallback", slip_bsm=OPT_SLIP)
                    src_en = "bsm_fallback"
                    occ_en = _occ(exp_date, "put", kp)
                    _rec_src(src_en, d)

                iv_anchor_en = None
                if src_en.startswith("real_opra") and iv_en is not None and math.isfinite(iv_en) and 0.02 <= iv_en <= 3.0:
                    bsm_iv_ref = bco_mod.eval_skew_iv(exec_px, kp, max(t_en, 1.0 / 365.0), r_en, q_en, vxn_en, coeffs)
                    iv_anchor_en = max(0.5, min(2.0, iv_en / max(bsm_iv_ref, 0.05)))

                already_ref_cov = sum(t["ref_cov_sh"] for t in active_tranches)
                cost_sh_frac_ref = put_ask_ref / (exec_px * (1.0 - STOCK_REBAL_FEE))
                max_cov = core_shares * (slot_coverage * max(2, r_cap))
                avail_sh_ref = max(0.0, max_cov - already_ref_cov)
                ref_hedged_sh = min(core_shares * slot_coverage, avail_sh_ref / (1.0 + cost_sh_frac_ref))
                ref_budget_usd = ref_hedged_sh * put_ask_ref
                if put_ask_en >= 0.03 and ref_budget_usd > 1.0:
                    hedged_sh = ref_budget_usd / put_ask_en
                    entry_cost_usd = ref_budget_usd
                    rem_need = entry_cost_usd - salv_usd
                    d_sh_entry = 0.0
                    if rem_need < -1e-8:
                        d_sh_entry = (-rem_need) / (exec_px * (1.0 + STOCK_REBAL_FEE))
                        core_shares += d_sh_entry
                    elif rem_need > 1e-8:
                        if cc_enabled and cc_cash > 0.0:
                            use_cc = min(cc_cash, rem_need)
                            cc_cash -= use_cc
                            cc_funded_puts += use_cc
                            rem_need -= use_cc
                        if rem_need > 1e-8:
                            d_sh_entry = -rem_need / (exec_px * (1.0 - STOCK_REBAL_FEE))
                            core_shares += d_sh_entry
                    tid += 1
                    used_slots = {t["slot_num"] for t in active_tranches}
                    slot_num = min(s for s in range(1, max(max_slots, r_cap) + 1) if s not in used_slots)
                    hr = hedged_sh / max(core_shares, 1e-6)
                    prev_row = rows_eval[i - 1]
                    mods, t_code, t_en_l, t_zh_l = format_m7_trigger_labels(r_sig_d, max_slots, core3_only=is_core3)
                    c_prob_r, p1_r, p2_r, p3_r = _prob_tuple(r_sig_d)
                    active_tranches.append(
                        {
                            "tranche_id": tid,
                            "slot_num": slot_num,
                            "tier": r_cap,
                            "is_cta": is_cta_r,
                            "target_dte": tr_tgt_dte,
                            "roll_dte_thr": tr_roll_thr,
                            "occ_symbol": occ_en,
                            "signal_date": dates[i - 1],
                            "sig_score": int(prev_row["score"]),
                            "sig_ad_below50": bool(float(prev_row["ad_line"]) < float(prev_row["ad_sma50"])),
                            "crisis_prob": c_prob_r,
                            "p1": p1_r,
                            "p2": p2_r,
                            "p3": p3_r,
                            "triggered_modules": mods,
                            "trigger_code": t_code,
                            "trigger_en": t_en_l,
                            "trigger_zh": t_zh_l,
                            "entry_date": d,
                            "entry_dt": dt_objs[i],
                            "exp_date": exp_date,
                            "exp_dt": exp_dt,
                            "T_entry": t_en,
                            "entry_spot": exec_px,
                            "entry_vxn": vxn_en,
                            "entry_vix_ratio": float(prev_row["vix_ratio"]),
                            "entry_r": r_en,
                            "entry_q": q_en,
                            "kp": kp,
                            "k_cents": k_cents_en,
                            "last_iv": iv_en if (iv_en is not None and math.isfinite(iv_en)) else None,
                            "iv_ratio_anchor": iv_anchor_en,
                            "entry_source": src_en,
                            "entry_bid_raw": en_bid_raw,
                            "entry_ask_raw": en_ask_raw,
                            "hedged_shares": hedged_sh,
                            "ref_cov_sh": ref_hedged_sh,
                            "hedged_ratio": hr,
                            "entry_put_ask": put_ask_en,
                            "entry_cost_usd": entry_cost_usd,
                            "entry_shares_sold": d_sh_entry,
                            "comp_entry_cost_usd": d_sh_entry * mult_morning,
                            "pending_tp": False,
                            "pending_roll": False,
                            "tp_trigger_ratio": 0.0,
                            "tp_reason": "",
                        }
                    )
                elif salv_usd > 1e-8:
                    core_shares += salv_usd / (exec_px * (1.0 + STOCK_REBAL_FEE))

        # 2. Pending New M7 Tranche Entry at T+1
        if i > 0 and pending_sig is not None and len(active_tranches) < pending_sig["cap_slots"]:
            r_en, q_en = pending_sig["r"], pending_sig["q"]
            vxn_en = vxn_ex
            is_cta_en = bool(pending_sig.get("is_cta", False))
            tr_tgt_dte, tr_ref_dte, tr_roll_thr, (lo_put_e, hi_put_e), (lo_ref_e, hi_ref_e) = _tenor_for_sig(is_cta_en)

            c_ref = None
            c_en = None
            if use_real:
                c_ref = real_store.select_put_contract(
                    d, exec_px, tr_ref_dte, ref_moneyness, lo_ref_e, hi_ref_e, r_en, q_en,
                    rec_tag=f"p_{tr_ref_dte}_10",
                )
                c_en = real_store.select_put_contract(
                    d, exec_px, tr_tgt_dte, put_moneyness, lo_put_e, hi_put_e, r_en, q_en,
                    rec_tag=f"p_{tr_tgt_dte}_{otm_pct_int}",
                )

            if use_real and opra_max_d and d <= opra_max_d and (c_ref is None or c_en is None):
                pending_sig = None
            else:
                if c_ref is not None:
                    _rec_src(c_ref["source"], d)
                    put_ask_ref = _buy_px(c_ref["bid"], c_ref["ask"], c_ref["mid"], c_ref["source"], slip_bsm=OPT_SLIP)
                else:
                    ref_cal = dt_objs[i] + datetime.timedelta(days=tr_ref_dte)
                    pos_ref = bisect.bisect_left(dt_objs, ref_cal)
                    exp_dt_ref = dt_objs[pos_ref] if pos_ref < n_days else ref_cal
                    t_ref = max(1, (exp_dt_ref - dt_objs[i]).days) / 365.0
                    kp_ref = exec_px * ref_moneyness
                    sig_ref = bco_mod.eval_skew_iv(exec_px, kp_ref, t_ref, r_en, q_en, vxn_en, coeffs)
                    mid_ref = bco_mod.bsm_price(exec_px, kp_ref, t_ref, r_en, q_en, sig_ref, "put")
                    put_ask_ref = _buy_px(mid_ref * (1.0 - OPT_SLIP), mid_ref * (1.0 + OPT_SLIP), mid_ref, "bsm_fallback", slip_bsm=OPT_SLIP)
                    _rec_src("bsm_fallback", d)

                if c_en is not None:
                    _rec_src(c_en["source"], d)
                    exp_date = c_en["exp"]
                    exp_dt = c_en["exp_dt"]
                    t_en = max(1, (exp_dt - dt_objs[i]).days) / 365.0
                    kp = c_en["strike"]
                    k_cents_en = c_en["k_cents"]
                    en_bid_raw = float(c_en["bid"])
                    en_ask_raw = float(c_en["ask"])
                    put_ask_en = _buy_px(en_bid_raw, en_ask_raw, c_en["mid"], c_en["source"], slip_bsm=OPT_SLIP)
                    iv_en = c_en["iv"]
                    src_en = c_en["source"]
                    occ_en = str(c_en.get("occ_symbol") or _occ(exp_date, "put", kp))
                else:
                    target_cal = dt_objs[i] + datetime.timedelta(days=tr_tgt_dte)
                    pos = bisect.bisect_left(dt_objs, target_cal)
                    exp_date, exp_dt = (dates[pos], dt_objs[pos]) if pos < n_days else (target_cal.isoformat(), target_cal)
                    t_en = max(1, (exp_dt - dt_objs[i]).days) / 365.0
                    kp = round(exec_px * put_moneyness, 2)
                    k_cents_en = int(round(kp * 100.0))
                    iv_en = bco_mod.eval_skew_iv(exec_px, kp, t_en, r_en, q_en, vxn_en, coeffs)
                    mid_en = bco_mod.bsm_price(exec_px, kp, t_en, r_en, q_en, iv_en, "put")
                    en_bid_raw = max(0.0, mid_en * (1.0 - OPT_SLIP))
                    en_ask_raw = mid_en * (1.0 + OPT_SLIP)
                    put_ask_en = _buy_px(en_bid_raw, en_ask_raw, mid_en, "bsm_fallback", slip_bsm=OPT_SLIP)
                    src_en = "bsm_fallback"
                    occ_en = _occ(exp_date, "put", kp)
                    _rec_src(src_en, d)

                iv_anchor_en = None
                if src_en.startswith("real_opra") and iv_en is not None and math.isfinite(iv_en) and 0.02 <= iv_en <= 3.0:
                    bsm_iv_ref = bco_mod.eval_skew_iv(exec_px, kp, max(t_en, 1.0 / 365.0), r_en, q_en, vxn_en, coeffs)
                    iv_anchor_en = max(0.5, min(2.0, iv_en / max(bsm_iv_ref, 0.05)))

                already_ref_cov = sum(t["ref_cov_sh"] for t in active_tranches)
                cost_sh_frac_ref = put_ask_ref / (exec_px * (1.0 - STOCK_REBAL_FEE))
                max_cov = core_shares * (slot_coverage * max(2, pending_sig["cap_slots"]))
                avail_sh_ref = max(0.0, max_cov - already_ref_cov)
                ref_hedged_sh = min(core_shares * slot_coverage, avail_sh_ref / (1.0 + cost_sh_frac_ref))
                ref_budget_usd = ref_hedged_sh * put_ask_ref

                if put_ask_en >= 0.03 and ref_budget_usd > 1.0:
                    hedged_sh = ref_budget_usd / put_ask_en
                    entry_cost_usd = ref_budget_usd
                    if cc_enabled and cc_cash >= entry_cost_usd:
                        cc_cash -= entry_cost_usd
                        cc_funded_puts += entry_cost_usd
                        d_sh_entry = 0.0
                    elif cc_enabled and cc_cash > 0.0:
                        paid_cc = cc_cash
                        cc_funded_puts += paid_cc
                        rem_cost = entry_cost_usd - paid_cc
                        cc_cash = 0.0
                        d_sh_entry = -rem_cost / (exec_px * (1.0 - STOCK_REBAL_FEE))
                        core_shares += d_sh_entry
                    else:
                        d_sh_entry = -entry_cost_usd / (exec_px * (1.0 - STOCK_REBAL_FEE))
                        core_shares += d_sh_entry

                    tid += 1
                    used_slots = {t["slot_num"] for t in active_tranches}
                    slot_num = min(s for s in range(1, max(max_slots, pending_sig["cap_slots"]) + 1) if s not in used_slots)
                    hr = hedged_sh / max(core_shares, 1e-6)
                    active_tranches.append(
                        {
                            "tranche_id": tid,
                            "slot_num": slot_num,
                            "tier": pending_sig["tier"],
                            "is_cta": is_cta_en,
                            "target_dte": tr_tgt_dte,
                            "roll_dte_thr": tr_roll_thr,
                            "occ_symbol": occ_en,
                            "signal_date": pending_sig["signal_date"],
                            "sig_score": pending_sig["sig_score"],
                            "sig_ad_below50": pending_sig["sig_ad_below50"],
                            "crisis_prob": pending_sig["crisis_prob"],
                            "p1": pending_sig["p1"],
                            "p2": pending_sig["p2"],
                            "p3": pending_sig["p3"],
                            "triggered_modules": pending_sig["triggered_modules"],
                            "trigger_code": pending_sig["trigger_code"],
                            "trigger_en": pending_sig["trigger_en"],
                            "trigger_zh": pending_sig["trigger_zh"],
                            "entry_date": d,
                            "entry_dt": dt_objs[i],
                            "exp_date": exp_date,
                            "exp_dt": exp_dt,
                            "T_entry": t_en,
                            "entry_spot": exec_px,
                            "entry_vxn": vxn_en,
                            "entry_vix_ratio": pending_sig["vix_ratio"],
                            "entry_r": r_en,
                            "entry_q": q_en,
                            "kp": kp,
                            "k_cents": k_cents_en,
                            "last_iv": iv_en if (iv_en is not None and math.isfinite(iv_en)) else None,
                            "iv_ratio_anchor": iv_anchor_en,
                            "entry_source": src_en,
                            "entry_bid_raw": en_bid_raw,
                            "entry_ask_raw": en_ask_raw,
                            "hedged_shares": hedged_sh,
                            "ref_cov_sh": ref_hedged_sh,
                            "hedged_ratio": hr,
                            "entry_put_ask": put_ask_en,
                            "entry_cost_usd": entry_cost_usd,
                            "entry_shares_sold": d_sh_entry,
                            "comp_entry_cost_usd": d_sh_entry * mult_morning,
                            "pending_tp": False,
                            "pending_roll": False,
                            "tp_trigger_ratio": 0.0,
                            "tp_reason": "",
                        }
                    )
                pending_sig = None
        else:
            pending_sig = None

        # 2b. Engine 2 Covered Call & Engine 3 Wheel T+1 executions
        if i > 0 and cc_enabled and pending_cc is not None and active_cc is None:
            r_cc, q_cc = pending_cc["r"], pending_cc["q"]
            vxn_cc = vxn_ex
            cc_sh = max(0.0, core_shares)
            if cc_sh > 1e-6:
                c_cc = None
                if use_real:
                    c_cc = real_store.select_call_contract_delta(
                        d, exec_px, cc_dte, cc_target_delta, exec_px * (1.0 + cc_min_otm), 17, 36, r_cc, q_cc,
                        rec_tag="cc_25_d12",
                    )
                if c_cc is not None:
                    _rec_src(c_cc["source"])
                    exp_date_cc, exp_dt_cc = c_cc["exp"], c_cc["exp_dt"]
                    kc_cc = c_cc["strike"]
                    k_cents_cc = c_cc["k_cents"]
                    c_bid_cc = _sell_px(c_cc["bid"], c_cc["ask"], c_cc["mid"], c_cc["source"], slip_bsm=OPT_SLIP)
                    iv_cc = c_cc["iv"]
                    src_cc = c_cc["source"]
                else:
                    target_cc = dt_objs[i] + datetime.timedelta(days=cc_dte)
                    pos_cc = bisect.bisect_left(dt_objs, target_cc)
                    exp_date_cc, exp_dt_cc = (dates[pos_cc], dt_objs[pos_cc]) if pos_cc < n_days else (target_cc.isoformat(), target_cc)
                    t_cc = max(1, (exp_dt_cc - dt_objs[i]).days) / 365.0
                    kc_cc = max(
                        exec_px * (1.0 + cc_min_otm),
                        bco_mod.solve_call_strike_for_delta(exec_px, t_cc, r_cc, q_cc, vxn_cc, coeffs, cc_target_delta),
                    )
                    iv_cc = bco_mod.eval_skew_iv(exec_px, kc_cc, t_cc, r_cc, q_cc, vxn_cc, coeffs)
                    cm_cc = bco_mod.bsm_price(exec_px, kc_cc, t_cc, r_cc, q_cc, iv_cc, "call")
                    c_bid_cc = _sell_px(cm_cc * (1.0 - OPT_SLIP), cm_cc * (1.0 + OPT_SLIP), cm_cc, "bsm_fallback", slip_bsm=OPT_SLIP)
                    k_cents_cc = int(round(kc_cc * 100.0))
                    src_cc = "bsm_fallback"
                    _rec_src(src_cc)
                if c_bid_cc >= 0.04:
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
                        "entry_spot": exec_px,
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

        if i > 0 and sp_enabled and pending_wc is not None and assigned_shares > 1e-6 and active_wc is None:
            pw = pending_wc
            pending_wc = None
            vxn_wc = vxn_ex
            c_wc = None
            if use_real:
                if wc_mode == "wc_reclaim_30d_d35":
                    c_wc = real_store.select_call_contract_delta(
                        d, exec_px, 30, 0.35, assigned_cost_k, 20, 42, pw["r"], pw["q"],
                        rec_tag=f"wc_30_d35_{int(round(assigned_cost_k * 100))}",
                    )
                elif wc_mode == "wc_30d_c5s5":
                    min_k_wc = max(assigned_cost_k * 1.05, exec_px * 1.05)
                    c_wc = real_store.select_call_contract_strike(
                        d, exec_px, 30, min_k_wc, 20, 42, pw["r"], pw["q"],
                        rec_tag=f"wc_30_k_{int(round(min_k_wc * 100))}",
                    )
                else:
                    min_k_wc = max(assigned_cost_k, exec_px * 1.02)
                    lo_w, hi_w = (6, 14) if sp_dte <= 10 else (8, 17)
                    c_wc = real_store.select_call_contract_strike(
                        d, exec_px, sp_dte, min_k_wc, lo_w, hi_w, pw["r"], pw["q"],
                        rec_tag=f"wc_{sp_dte}_k_{int(round(min_k_wc * 100))}",
                    )
            if c_wc is not None:
                _rec_src(c_wc["source"])
                exp_date_wc, exp_dt_wc = c_wc["exp"], c_wc["exp_dt"]
                act_dte_wc = max(1, (exp_dt_wc - dt_objs[i]).days)
                kc_wc = c_wc["strike"]
                k_cents_wc = c_wc["k_cents"]
                c_bid_wc = _sell_px(c_wc["bid"], c_wc["ask"], c_wc["mid"], c_wc["source"], slip_bsm=OPT_SLIP_SP)
                iv_wc = c_wc["iv"]
                src_wc = c_wc["source"]
            else:
                if wc_mode == "wc_reclaim_30d_d35":
                    target_wc_dt = dt_objs[i] + datetime.timedelta(days=30)
                    pos_wc = bisect.bisect_left(dt_objs, target_wc_dt)
                    exp_date_wc, exp_dt_wc = (dates[pos_wc], dt_objs[pos_wc]) if pos_wc < n_days else (target_wc_dt.isoformat(), target_wc_dt)
                    act_dte_wc = max(1, (exp_dt_wc - dt_objs[i]).days)
                    k_d35 = bco_mod.solve_call_strike_for_delta(exec_px, act_dte_wc / 365.0, pw["r"], pw["q"], vxn_wc, coeffs, 0.35)
                    kc_wc = max(assigned_cost_k, k_d35)
                elif wc_mode == "wc_30d_c5s5":
                    target_wc_dt = dt_objs[i] + datetime.timedelta(days=30)
                    pos_wc = bisect.bisect_left(dt_objs, target_wc_dt)
                    exp_date_wc, exp_dt_wc = (dates[pos_wc], dt_objs[pos_wc]) if pos_wc < n_days else (target_wc_dt.isoformat(), target_wc_dt)
                    act_dte_wc = max(1, (exp_dt_wc - dt_objs[i]).days)
                    kc_wc = max(assigned_cost_k * 1.05, exec_px * 1.05)
                else:
                    exp_date_wc, exp_dt_wc, act_dte_wc = bco_mod._pick_expiry_strict_max14(dt_objs, dates, i, sp_dte, 14)
                    kc_wc = max(assigned_cost_k, exec_px * 1.02)
                c_bid_wc, _ = bco_mod._opt_exec_price_sp(exec_px, kc_wc, act_dte_wc / 365.0, pw["r"], pw["q"], vxn_wc, coeffs, "call", "sell", OPT_SLIP_SP)
                k_cents_wc = int(round(kc_wc * 100.0))
                iv_wc = None
                src_wc = "bsm_fallback"
                _rec_src(src_wc)
            if c_bid_wc >= MIN_OPT_BID:
                prem_wc = assigned_shares * c_bid_wc
                if not use_real:
                    sp_comm_total += assigned_shares * OPT_COMM_PER_SH
                else:
                    # Commission already deducted in _sell_px; track separately for telemetry
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
                    "entry_spot": exec_px,
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
            vxn_sp = vxn_ex
            c_sp = None
            if use_real:
                lo_sp, hi_sp = (6, 14) if sp_dte <= 10 else (8, 17)
                c_sp = real_store.select_put_contract(
                    d, exec_px, sp_dte, 1.0 - sp_otm_pct, lo_sp, hi_sp, ps["r"], ps["q"],
                    require_bid=MIN_OPT_BID,
                    rec_tag=f"sp_{sp_dte}_5",
                )
            if c_sp is not None:
                _rec_src(c_sp["source"])
                exp_date_sp, exp_dt_sp = c_sp["exp"], c_sp["exp_dt"]
                act_dte_sp = max(1, (exp_dt_sp - dt_objs[i]).days)
                kp_sp = c_sp["strike"]
                k_cents_sp = c_sp["k_cents"]
                p_bid_sp = _sell_px(c_sp["bid"], c_sp["ask"], c_sp["mid"], c_sp["source"], slip_bsm=OPT_SLIP_SP)
                iv_sp = c_sp["iv"]
                src_sp = c_sp["source"]
            else:
                exp_date_sp, exp_dt_sp, act_dte_sp = bco_mod._pick_expiry_strict_max14(dt_objs, dates, i, sp_dte, 14)
                kp_sp = exec_px * (1.0 - sp_otm_pct)
                p_bid_sp, _ = bco_mod._opt_exec_price_sp(exec_px, kp_sp, act_dte_sp / 365.0, ps["r"], ps["q"], vxn_sp, coeffs, "put", "sell", OPT_SLIP_SP)
                k_cents_sp = int(round(kp_sp * 100.0))
                iv_sp = None
                src_sp = "bsm_fallback"
                _rec_src(src_sp)
            if p_bid_sp >= MIN_OPT_BID:
                nav_open = _estimate_nav_exec(exec_px, vxn_sp, ps["r"], ps["q"], dt_objs[i], d)
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
                    "entry_spot": exec_px,
                    "kp": kp_sp,
                    "k_cents": k_cents_sp,
                    "last_iv": iv_sp,
                    "entry_source": src_sp,
                    "shares": put_sh,
                    "prem_usd": prem_sp,
                    "entry_vix_ratio": ps["vix_ratio"],
                }

        # 3. Dividends DRIP (exact STOCK_REBAL_FEE parity with 05_cta_shorter_dte_real_opra_study.py)
        if div > 0.0 and core_shares > 0.0:
            core_shares += (core_shares * div) / (cl * (1.0 + STOCK_REBAL_FEE))
            if assigned_shares > 0.0:
                sp_cash += assigned_shares * div

        was_active_today = len(active_tranches) > 0
        active_slots_today = len(active_tranches)

        # 4. EOD Expiries
        still_open_exp: list[dict[str, Any]] = []
        for tr in active_tranches:
            if _is_exp(i, tr["exp_dt"]):
                put_intr = max(0.0, tr["kp"] - cl)
                settle_usd = tr["hedged_shares"] * put_intr
                d_sh = 0.0
                if abs(settle_usd) > 1e-10:
                    d_sh = settle_usd / (cl * (1.0 + STOCK_REBAL_FEE))
                    core_shares += d_sh
                roi_mult = (settle_usd / tr["entry_cost_usd"]) if tr["entry_cost_usd"] > 1e-6 else 0.0
                actual_net_sh = put_intr - tr["entry_put_ask"]
                conv = bco_mod.decompose_tranche_convexity(
                    "naked_put",
                    tr["entry_spot"],
                    cl,
                    tr["kp"],
                    None,
                    tr["T_entry"],
                    0.0,
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
                en_src = tr.get("entry_source", "bsm_fallback")
                ex_src_exp = "real_opra_exact" if (use_real and opra_max_d and d <= opra_max_d) else en_src
                q_tag_exp = _classify_quote_source_tag(en_src, ex_src_exp, tr["entry_date"], d, opra_max_d or "2025-12-15")
                occ_sym = str(tr.get("occ_symbol") or _occ(tr["exp_date"], "put", tr["kp"]))
                tr_tgt_d = int(tr.get("target_dte") or target_dte)
                ledger.append(
                    {
                        "tranche_id": tr["tranche_id"],
                        "strategy_id": strategy_id,
                        "slot_num": tr["slot_num"],
                        "tier": tr["tier"],
                        "max_slots": max_slots,
                        "tranche_type": "naked_put",
                        "put_otm_pct": otm_pct_int,
                        "tp_mode": tp_code,
                        "roll_mode": roll_mode,
                        "target_dte": tr_tgt_d,
                        "roll_dte": int(tr.get("roll_dte_thr") or 0),
                        "is_cta": bool(tr.get("is_cta", False)),
                        "quoteSource": q_tag_exp,
                        "quote_source": q_tag_exp,
                        "occSymbol": occ_sym,
                        "occ_symbol": occ_sym,
                        "exp": tr["exp_date"],
                        "strike": round(tr["kp"], 2),
                        "entryBid": round(float(tr.get("entry_bid_raw", tr["entry_put_ask"])), 3),
                        "entryAsk": round(float(tr.get("entry_ask_raw", tr["entry_put_ask"])), 3),
                        "exitBid": round(float(put_intr), 3),
                        "exitAsk": round(float(put_intr), 3),
                        "pricing_source": _classify_trade_source(en_src, ex_src_exp),
                        "entry_source": en_src,
                        "exit_source": ex_src_exp,
                        "signal_date": tr["signal_date"],
                        "entry_date": tr["entry_date"],
                        "planned_exp_date": tr["exp_date"],
                        "exit_date": d,
                        "actual_days_held": (dt_objs[i] - tr["entry_dt"]).days,
                        "rem_dte_at_exit": 0,
                        "exit_reason": f"expiry_{tr_tgt_d}dte",
                        "sig_score": tr["sig_score"],
                        "sig_ad_below50": tr["sig_ad_below50"],
                        "crisis_prob": tr["crisis_prob"],
                        "p1": tr["p1"],
                        "p2": tr["p2"],
                        "p3": tr["p3"],
                        "triggered_modules": tr["triggered_modules"],
                        "trigger_code": tr["trigger_code"],
                        "trigger_en": tr["trigger_en"],
                        "trigger_zh": tr["trigger_zh"],
                        "entry_spot": round(tr["entry_spot"], 2),
                        "entry_vxn": round(tr["entry_vxn"], 2),
                        "entry_vix_ratio": round(tr["entry_vix_ratio"], 3),
                        "kp": round(tr["kp"], 2),
                        "kc": None,
                        "call_cap_pct": None,
                        "hedged_shares": round(hs, 2),
                        "contracts_est": round(hs / 100.0, 2),
                        "slot_coverage": round(tr["hedged_ratio"], 4),
                        "entry_put_ask_sh": round(tr["entry_put_ask"], 4),
                        "tp_target_5x_sh": round(5.0 * tr["entry_put_ask"], 4),
                        "entry_cost_usd": round(tr["entry_cost_usd"], 2),
                        "entry_shares_sold": round(tr["entry_shares_sold"], 4),
                        "exit_spot": round(cl, 2),
                        "exit_vxn": round(vxn_cl, 2),
                        "exit_vix_ratio": round(vix_r, 3),
                        "underlying_ret_pct": round((cl / tr["entry_spot"] - 1.0) * 100.0, 2),
                        "put_exit_val_sh": round(put_intr, 4),
                        "call_exit_cost_sh": 0.0,
                        "exit_net_cash_usd": round(settle_usd, 2),
                        "net_pnl_usd": round(settle_usd - tr["entry_cost_usd"], 2),
                        "roi_mult": round(roi_mult, 2),
                        "exit_shares_delta": round(d_sh, 2),
                        "shares_added": round(tr["entry_shares_sold"] + d_sh, 2),
                        "delta0": round(float(conv["delta0"]), 4),
                        "delta_usd": round(float(conv["dV_delta_sh"]) * hs, 2),
                        "gamma_usd": round(float(conv["dV_gamma_sh"]) * hs, 2),
                        "vega_usd": round(float(conv["dV_vega_sh"]) * hs, 2),
                        "theta_slip_usd": round(
                            round(settle_usd - tr["entry_cost_usd"], 2)
                            - (
                                round(float(conv["dV_delta_sh"]) * hs, 2)
                                + round(float(conv["dV_gamma_sh"]) * hs, 2)
                                + round(float(conv["dV_vega_sh"]) * hs, 2)
                            ),
                            2,
                        ),
                        "convexity_mult": round(float(conv["conv_mult"]), 2) if conv["conv_mult"] is not None else None,
                        "comp_entry_cost_usd": round(tr["comp_entry_cost_usd"], 2),
                        "comp_put_gain_usd": round(d_sh * mult_eod, 2),
                        "comp_call_drag_usd": 0.0,
                    }
                )
            else:
                still_open_exp.append(tr)
        active_tranches = still_open_exp

        # 5. EOD MTM & Unified TP / Adaptive Roll Check
        put_mtm = 0.0
        for tr in active_tranches:
            rem_days = max(1, (tr["exp_dt"] - dt_objs[i]).days)
            _, _, put_mid, iv_m, _, src_mtm = _lookup_opt(
                d, "put", tr["exp_date"], tr["kp"], tr.get("k_cents"),
                cl, rem_days, r_cur, q_cur, vxn_cl, tr.get("last_iv"),
                slip_bsm=OPT_SLIP, iv_ratio_anchor=tr.get("iv_ratio_anchor"),
            )
            if math.isfinite(iv_m) and 0.02 <= iv_m <= 3.0:
                tr["last_iv"] = iv_m
                if src_mtm.startswith("real_opra"):
                    bsm_iv_m = bco_mod.eval_skew_iv(cl, tr["kp"], max(rem_days / 365.0, 1.0 / 365.0), r_cur, q_cur, vxn_cl, coeffs)
                    tr["iv_ratio_anchor"] = max(0.5, min(2.0, iv_m / max(bsm_iv_m, 0.05)))
            put_mtm += tr["hedged_shares"] * put_mid
            tr_roll_thr_cur = int(tr.get("roll_dte_thr") or 0)
            if not tr["pending_tp"]:
                vix_ok = (vix_r >= vix_ratio_tp) and ((cl <= tr["kp"]) if require_itm_tp else True)
                if vix_ok:
                    tr["pending_tp"] = True
                    tr["tp_trigger_ratio"] = vix_r
                    tr["tp_reason"] = "vix_inv_1.10_itm_tp" if require_itm_tp else "vix_inv_1.10_tp"
                elif rem_days <= put_mult_max_dte and tr["entry_put_ask"] > 1e-6 and put_mid >= tr["entry_put_ask"] * put_mult_tp:
                    tr["pending_tp"] = True
                    tr["tp_trigger_ratio"] = vix_r
                    tr["tp_reason"] = "put_5x_dte45_tp"
                elif tr_roll_thr_cur > 0 and rem_days <= tr_roll_thr_cur and not tr.get("pending_roll"):
                    tr["pending_roll"] = True
                    tr["tp_trigger_ratio"] = vix_r
                    tr["tp_reason"] = f"roll_{tr_roll_thr_cur}d"

        # 5b. Engine 2 & Engine 3 EOD MTM/Expiries
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
                cc_en_src = active_cc.get("entry_source", "bsm_fallback")
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
                        "pricing_source": _classify_trade_source(cc_en_src, cc_en_src),
                    }
                )
                active_cc = None
            else:
                rem_cc = max(1, (active_cc["exp_dt"] - dt_objs[i]).days)
                _, _, cm_cc, iv_cc_m, cur_delta, _ = _lookup_opt(
                    d, "call", active_cc["exp_date"], active_cc["kc"], active_cc.get("k_cents"),
                    cl, rem_cc, r_cur, q_cur, vxn_cl, active_cc.get("last_iv"), slip_bsm=OPT_SLIP
                )
                if math.isfinite(iv_cc_m) and 0.03 <= iv_cc_m <= 2.5:
                    active_cc["last_iv"] = iv_cc_m
                cc_mtm = -active_cc["shares"] * cm_cc
                if rem_cc >= 3 and vix_r >= 1.10:
                    active_cc["pending_close"] = True
                    active_cc["close_reason"] = "panic_close_uncap"
                elif cc_stop_delta is not None and cur_delta >= cc_stop_delta:
                    active_cc["pending_close"] = True
                    active_cc["close_reason"] = (
                        "delta_roll_up" if cc_roll_mode == "fresh_30d" else ("delta_credit_roll" if cc_roll_mode == "credit_45d" else "delta_stop")
                    )

        sp_mtm = 0.0
        if active_sp is not None:
            days_short_put_open += 1
            if _is_exp(i, active_sp["exp_dt"]):
                sp_en_src = active_sp.get("entry_source", "bsm_fallback")
                if cl >= active_sp["kp"]:
                    sp_closed_ledger.append(
                        {
                            "leg_id": f"SP-{active_sp['sp_id']}",
                            "sp_id": active_sp["sp_id"],
                            "cycle_id": active_sp["cycle_id"],
                            "leg_type": "short_put",
                            "is_open_live": False,
                            "pricing_source": _classify_trade_source(sp_en_src, sp_en_src),
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
                        }
                    )
                    active_sp = None
                    if assigned_shares <= 1e-6:
                        cur_cycle_start_dt = None
                        _sweep_sp_cash(cl)
                else:
                    assigned_shares = active_sp["shares"]
                    assigned_cost_k = active_sp["kp"]
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
                            "pricing_source": _classify_trade_source(sp_en_src, sp_en_src),
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
                        }
                    )
                    active_sp = None
            else:
                rem_sp = max(1, (active_sp["exp_dt"] - dt_objs[i]).days)
                _, _, pm_sp, iv_sp_m, _, _ = _lookup_opt(
                    d, "put", active_sp["exp_date"], active_sp["kp"], active_sp.get("k_cents"),
                    cl, rem_sp, r_cur, q_cur, vxn_cl, active_sp.get("last_iv"), slip_bsm=OPT_SLIP_SP
                )
                if math.isfinite(iv_sp_m) and 0.03 <= iv_sp_m <= 2.5:
                    active_sp["last_iv"] = iv_sp_m
                sp_mtm = -active_sp["shares"] * pm_sp

        wc_mtm = 0.0
        if active_wc is not None:
            if _is_exp(i, active_wc["exp_dt"]):
                wc_en_src = active_wc.get("entry_source", "bsm_fallback")
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
                            "pricing_source": _classify_trade_source(wc_en_src, wc_en_src),
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
                        }
                    )
                    assigned_shares = 0.0
                    assigned_cost_k = 0.0
                    active_wc = None
                    if cur_cycle_start_dt is not None:
                        max_wheel_cycle_days = max(max_wheel_cycle_days, (dt_objs[i] - cur_cycle_start_dt).days)
                        cur_cycle_start_dt = None
                    _sweep_sp_cash(cl)
                else:
                    wc_closed_ledger.append(
                        {
                            "leg_id": f"WC-{active_wc['wc_id']}",
                            "wc_id": active_wc["wc_id"],
                            "cycle_id": active_wc["cycle_id"],
                            "leg_type": "wheel_call",
                            "is_open_live": False,
                            "pricing_source": _classify_trade_source(wc_en_src, wc_en_src),
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
                        }
                    )
                    active_wc = None
            else:
                rem_wc = max(1, (active_wc["exp_dt"] - dt_objs[i]).days)
                _, _, cm_wc, iv_wc_m, _, _ = _lookup_opt(
                    d, "call", active_wc["exp_date"], active_wc["kc"], active_wc.get("k_cents"),
                    cl, rem_wc, r_cur, q_cur, vxn_cl, active_wc.get("last_iv"), slip_bsm=OPT_SLIP_SP
                )
                if math.isfinite(iv_wc_m) and 0.03 <= iv_wc_m <= 2.5:
                    active_wc["last_iv"] = iv_wc_m
                wc_mtm = -active_wc["shares"] * cm_wc

        nav = (core_shares + assigned_shares) * cl + cc_cash + sp_cash + put_mtm + cc_mtm + sp_mtm + wc_mtm
        if sp_enabled:
            gross_stock_lev = ((core_shares + assigned_shares) * cl) / max(nav, 1.0)
            put_notional = (active_sp["shares"] * active_sp["kp"]) if active_sp is not None else 0.0
            notional_lev = ((core_shares + assigned_shares) * cl + put_notional) / max(nav, 1.0)
            if assigned_shares > 1e-6:
                days_levered += 1
            max_gross_stock_lev = max(max_gross_stock_lev, gross_stock_lev)
            max_notional_lev = max(max_notional_lev, notional_lev)

        nav_list.append(nav)
        equiv_sh_list.append(nav / cl)
        any_active_list.append(1 if (was_active_today or len(active_tranches) > 0) else 0)
        active_slots_list.append(max(active_slots_today, len(active_tranches)))

        # 6. EOD M7 Signal & Hard Redline Gate for T+1 Open (exact parity with 05_cta_shorter_dte_real_opra_study.py)
        cap_slots = _slots_for_sig(sig_d)
        redline_blocked = bool(vxn_cl > 27.0 or vix_r >= 1.02)
        eff_open = active_tranches
        if cap_slots > 0 and not redline_blocked and len(eff_open) < cap_slots:
            min_gap = step_cal_days if cap_slots <= 2 else escalate_min_days
            recent = any((dt_objs[i] - t["entry_dt"]).days < min_gap for t in eff_open)
            if not recent:
                mods, t_code, t_en, t_zh = format_m7_trigger_labels(sig_d, max_slots, core3_only=is_core3)
                c_prob_s, p1_s, p2_s, p3_s = _prob_tuple(sig_d)
                pending_sig = {
                    "signal_date": d,
                    "is_cta": bool(sig_d.get("M4", False)),
                    "vxn": vxn_cl,
                    "close": cl,
                    "vix_ratio": vix_r,
                    "r": r_cur,
                    "q": q_cur,
                    "cap_slots": cap_slots,
                    "tier": cap_slots,
                    "sig_score": int(row["score"]),
                    "sig_ad_below50": bool(float(row["ad_line"]) < float(row["ad_sma50"])),
                    "crisis_prob": c_prob_s,
                    "p1": p1_s,
                    "p2": p2_s,
                    "p3": p3_s,
                    "triggered_modules": mods,
                    "trigger_code": t_code,
                    "trigger_en": t_en,
                    "trigger_zh": t_zh,
                }

        if cc_enabled and i < n_days - 1:
            if active_cc is None and dd_cur >= -cc_ath_limit and vxn_cl >= cc_min_vxn:
                pending_cc = {"close": cl, "vxn": vxn_cl, "r": r_cur, "q": q_cur}
            if cc_cash > 1.0 and vix_r >= 1.10:
                pending_cc_deploy = True

        wc_reclaim_ready = (cl >= assigned_cost_k) if wc_mode == "wc_reclaim_30d_d35" else True
        if sp_enabled and assigned_shares > 1e-6 and active_wc is None and wc_reclaim_ready:
            pending_wc = {"signal_date": d, "close": cl, "vxn": vxn_cl, "vix_ratio": vix_r, "r": r_cur, "q": q_cur}
        if sp_enabled and active_sp is None and assigned_shares <= 1e-6:
            trig_sp = vix_r >= sp_vix_thr
            if trig_sp and sp_require_vix_falling:
                trig_sp = bool(row.get("vix_falling"))
            if trig_sp:
                pending_sp = {"signal_date": d, "close": cl, "vxn": vxn_cl, "vix_ratio": vix_r, "r": r_cur, "q": q_cur}

    closed_trades_count = len(ledger)

    # Serialize any open live tranches at final EOD
    last_r = rows_eval[-1]
    last_d = dates[-1]
    last_dt = dt_objs[-1]
    last_cl = float(last_r["close"])
    last_vxn = float(last_r["vxn"])
    last_vr = float(last_r["vix_ratio"])
    last_rf = float(last_r["r"])
    last_q = float(last_r["div_yield"])
    mult_last = (final_bh_sh / bh_m7["post_sh"][-1]) * final_cl

    active_tranches_serialized: list[dict[str, Any]] = []
    for tr in active_tranches:
        rem_d = max(1, (tr["exp_dt"] - last_dt).days)
        t_rem = rem_d / 365.0
        b_live, a_live, pm, _, _, src_live = _lookup_opt(
            last_d, "put", tr["exp_date"], tr["kp"], tr.get("k_cents"),
            last_cl, rem_d, last_rf, last_q, last_vxn, tr.get("last_iv"),
            slip_bsm=OPT_SLIP, iv_ratio_anchor=tr.get("iv_ratio_anchor"),
        )
        hs = tr["hedged_shares"]
        mtm_cash_usd = hs * pm
        mtm_net_pnl = mtm_cash_usd - tr["entry_cost_usd"]
        roi_mult = (mtm_cash_usd / tr["entry_cost_usd"]) if tr["entry_cost_usd"] > 1e-6 else 0.0
        est_d_sh = mtm_cash_usd / (last_cl * (1.0 + STOCK_REBAL_FEE)) if abs(mtm_cash_usd) > 1e-8 else 0.0
        est_sh_added = tr["entry_shares_sold"] + est_d_sh
        actual_net_sh = pm - tr["entry_put_ask"]
        conv = bco_mod.decompose_tranche_convexity(
            "naked_put",
            tr["entry_spot"],
            last_cl,
            tr["kp"],
            None,
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
        tr_tgt_d = int(tr.get("target_dte") or target_dte)
        tr_roll_d = int(tr.get("roll_dte_thr") or 0)
        is_armed = bool(tr.get("pending_tp")) or bool(tr.get("pending_roll"))
        armed_reason = tr.get("tp_reason") or (f"roll_{tr_roll_d}d" if tr.get("pending_roll") else "")
        if is_armed and str(armed_reason).startswith("roll_"):
            live_reason = f"live_{armed_reason}_armed_next_open"
        elif is_armed:
            live_reason = "live_tp_armed_next_open"
        else:
            live_reason = "open_live_mtm"
        en_src_l = tr.get("entry_source", "bsm_fallback")
        q_tag_live = _classify_quote_source_tag(en_src_l, src_live, tr["entry_date"], last_d, opra_max_d or "2025-12-15")
        occ_sym = str(tr.get("occ_symbol") or _occ(tr["exp_date"], "put", tr["kp"]))
        ledger.append(
            {
                "tranche_id": tr["tranche_id"],
                "strategy_id": strategy_id,
                "slot_num": tr["slot_num"],
                "tier": tr["tier"],
                "max_slots": max_slots,
                "tranche_type": "naked_put",
                "put_otm_pct": otm_pct_int,
                "tp_mode": tp_code,
                "roll_mode": roll_mode,
                "target_dte": tr_tgt_d,
                "roll_dte": tr_roll_d,
                "is_cta": bool(tr.get("is_cta", False)),
                "quoteSource": q_tag_live,
                "quote_source": q_tag_live,
                "occSymbol": occ_sym,
                "occ_symbol": occ_sym,
                "exp": tr["exp_date"],
                "strike": round(tr["kp"], 2),
                "entryBid": round(float(tr.get("entry_bid_raw", tr["entry_put_ask"])), 3),
                "entryAsk": round(float(tr.get("entry_ask_raw", tr["entry_put_ask"])), 3),
                "exitBid": round(float(b_live), 3),
                "exitAsk": round(float(a_live), 3),
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
                "pricing_source": _classify_trade_source(en_src_l, src_live),
                "entry_source": en_src_l,
                "exit_source": src_live,
                "sig_score": tr["sig_score"],
                "sig_ad_below50": tr["sig_ad_below50"],
                "crisis_prob": tr["crisis_prob"],
                "p1": tr["p1"],
                "p2": tr["p2"],
                "p3": tr["p3"],
                "triggered_modules": tr["triggered_modules"],
                "trigger_code": tr["trigger_code"],
                "trigger_en": tr["trigger_en"],
                "trigger_zh": tr["trigger_zh"],
                "entry_spot": round(tr["entry_spot"], 2),
                "entry_vxn": round(tr["entry_vxn"], 2),
                "entry_vix_ratio": round(tr["entry_vix_ratio"], 3),
                "kp": round(tr["kp"], 2),
                "kc": None,
                "call_cap_pct": None,
                "hedged_shares": round(hs, 2),
                "contracts_est": round(hs / 100.0, 2),
                "slot_coverage": round(tr["hedged_ratio"], 4),
                "entry_put_ask_sh": round(tr["entry_put_ask"], 4),
                "tp_target_5x_sh": round(5.0 * tr["entry_put_ask"], 4),
                "entry_cost_usd": round(tr["entry_cost_usd"], 2),
                "entry_shares_sold": round(tr["entry_shares_sold"], 4),
                "exit_spot": round(last_cl, 2),
                "exit_vxn": round(last_vxn, 2),
                "exit_vix_ratio": round(last_vr, 3),
                "underlying_ret_pct": round((last_cl / tr["entry_spot"] - 1.0) * 100.0, 2),
                "put_exit_val_sh": round(pm, 4),
                "call_exit_cost_sh": 0.0,
                "exit_net_cash_usd": round(mtm_cash_usd, 2),
                "net_pnl_usd": round(mtm_net_pnl, 2),
                "roi_mult": round(roi_mult, 2),
                "exit_shares_delta": round(est_d_sh, 2),
                "shares_added": round(est_sh_added, 2),
                "delta0": round(float(conv["delta0"]), 4),
                "delta_usd": round(float(conv["dV_delta_sh"]) * hs, 2),
                "gamma_usd": round(float(conv["dV_gamma_sh"]) * hs, 2),
                "vega_usd": round(float(conv["dV_vega_sh"]) * hs, 2),
                "theta_slip_usd": round(
                    round(mtm_net_pnl, 2)
                    - (
                        round(float(conv["dV_delta_sh"]) * hs, 2)
                        + round(float(conv["dV_gamma_sh"]) * hs, 2)
                        + round(float(conv["dV_vega_sh"]) * hs, 2)
                    ),
                    2,
                ),
                "convexity_mult": round(float(conv["conv_mult"]), 2) if conv["conv_mult"] is not None else None,
                "comp_entry_cost_usd": round(tr["comp_entry_cost_usd"], 2),
                "comp_put_gain_usd": round((hs * pm / last_cl) * mult_last, 2),
                "comp_call_drag_usd": 0.0,
            }
        )
        active_tranches_serialized.append(
            {
                "tranche_id": tr["tranche_id"],
                "slot_num": tr["slot_num"],
                "tier": tr["tier"],
                "tranche_type": "naked_put",
                "put_otm_pct": otm_pct_int,
                "roll_mode": roll_mode,
                "target_dte": tr_tgt_d,
                "roll_dte": tr_roll_d,
                "is_cta": bool(tr.get("is_cta", False)),
                "occSymbol": occ_sym,
                "quoteSource": q_tag_live,
                "days_to_roll": max(0, rem_d - tr_roll_d) if tr_roll_d > 0 else None,
                "days_to_roll50": max(0, rem_d - tr_roll_d) if tr_roll_d > 0 else None,
                "entry_date": tr["entry_date"],
                "exp_date": tr["exp_date"],
                "rem_dte": rem_d,
                "entry_spot": round(tr["entry_spot"], 2),
                "mtm_spot": round(last_cl, 2),
                "mtm_date": last_d,
                "kp": round(tr["kp"], 2),
                "kc": None,
                "hedged_shares": round(hs, 2),
                "contracts_est": round(hs / 100.0, 2),
                "entry_put_ask_sh": round(tr["entry_put_ask"], 4),
                "tp_target_5x_sh": round(5.0 * tr["entry_put_ask"], 4),
                "entry_cost_usd": round(tr["entry_cost_usd"], 2),
                "mtm_put_val_sh": round(pm, 4),
                "mtm_call_val_sh": 0.0,
                "mtm_pnl_usd": round(mtm_net_pnl, 2),
                "roi_mult": round(roi_mult, 2),
                "est_shares_added": round(est_sh_added, 2),
                "pending_tp": is_armed,
                "tp_reason": tr.get("tp_reason") or "",
                "tp_trigger_ratio": round(float(tr.get("tp_trigger_ratio") or last_vr), 3),
                "trigger_code": tr["trigger_code"],
                "crisis_prob": tr["crisis_prob"],
            }
        )

    # Metrics (matching 02_run_real_quotes_backtest.py & 09_core3_pruned_ablation_real_opra.py!)
    yrs = (dt_objs[-1] - dt_objs[0]).days / 365.25
    cagr = (nav_list[-1] / INITIAL_CAPITAL) ** (1.0 / yrs) - 1.0
    rets = [nav_list[j] / nav_list[j - 1] - 1.0 for j in range(1, n_days)]
    mean_r = sum(rets) / len(rets)
    var_r = sum((x - mean_r) ** 2 for x in rets) / max(1, len(rets) - 1)
    vol = math.sqrt(var_r) * math.sqrt(252.0)
    sharpe = (mean_r * 252.0) / vol if vol > 0 else 0.0
    neg_rets = [x for x in rets if x < 0.0]
    if len(neg_rets) > 1:
        mu_neg = sum(neg_rets) / len(neg_rets)
        down_std = math.sqrt(sum((x - mu_neg) ** 2 for x in neg_rets) / (len(neg_rets) - 1)) * math.sqrt(252.0)
        sortino = (mean_r * 252.0) / down_std if down_std > 0 else 0.0
    else:
        sortino = 0.0

    peak = nav_list[0]
    mdd = 0.0
    for v in nav_list:
        if v > peak:
            peak = v
        dd = v / peak - 1.0
        if dd < mdd:
            mdd = dd
    calmar = cagr / abs(mdd) if mdd < 0 else 0.0

    closed_rows = [x for x in ledger if not x.get("is_open_live")]
    n_closed = len(closed_rows)
    closed_pnls = [float(x["exit_net_cash_usd"]) - float(x["entry_cost_usd"]) for x in closed_rows]
    win_cnt = sum(1 for p in closed_pnls if p > 0.0)
    win_rate_pct = (win_cnt / n_closed * 100.0) if n_closed > 0 else 0.0
    gross_win_usd = sum(p for p in closed_pnls if p > 0.0)
    gross_loss_usd = sum(-p for p in closed_pnls if p <= 0.0)
    profit_factor = (gross_win_usd / gross_loss_usd) if gross_loss_usd > 1e-6 else 0.0

    n_tp = sum(1 for x in closed_rows if "tp" in str(x["exit_reason"]))
    roll_exits = [x for x in closed_rows if str(x["exit_reason"]).startswith("roll_")]
    roll_salvage_count = len(roll_exits)
    roll_30d_count = sum(1 for x in closed_rows if x["exit_reason"] == "roll_30d")
    roll_50d_count = sum(1 for x in closed_rows if x["exit_reason"] == "roll_50d")
    avg_roll_salvage_pct = (
        (sum(float(x.get("roi_mult") or 0.0) for x in roll_exits) / roll_salvage_count) * 100.0
        if roll_salvage_count > 0
        else 0.0
    )
    naked_spent = sum(x["entry_cost_usd"] for x in ledger)
    gross_put = sum(x["exit_net_cash_usd"] for x in closed_rows)
    payout_to_cost = (gross_put / sum(x["entry_cost_usd"] for x in closed_rows)) if closed_rows else 0.0
    net_alpha = nav_list[-1] - bh_m7["end_nav"]
    pct_active = (sum(any_active_list) / n_days) * 100.0
    active_days = max(1, sum(any_active_list))
    extra_sh_vs_bh = equiv_sh_list[-1] - final_bh_sh
    extra_sh_pct = (extra_sh_vs_bh / final_bh_sh) * 100.0 if final_bh_sh > 0 else 0.0
    max_roi = max((float(x.get("roi_mult") or 0.0) for x in closed_rows), default=0.0)

    sp_wins = sum(1 for x in sp_closed_ledger if x["net_pnl_usd"] > 0)
    sp_win_rate = (sp_wins / len(sp_closed_ledger) * 100.0) if sp_closed_ledger else 0.0
    sp_gross_prem_val = sum(x["prem_usd"] for x in sp_closed_ledger)
    wc_gross_prem_val = sum(x["prem_usd"] for x in wc_closed_ledger)
    wc_called_cnt = sum(1 for x in wc_closed_ledger if x["exit_reason"] == "called_away")

    open_sp_ser = None
    open_wc_ser = None
    sp_combined_ledger = list(sp_closed_ledger) + list(wc_closed_ledger)
    if active_sp is not None:
        rem_sp_last = max(1, (active_sp["exp_dt"] - last_dt).days)
        _, pm_sp_last = bco_mod._opt_exec_price_sp(last_cl, active_sp["kp"], rem_sp_last / 365.0, last_rf, last_q, last_vxn, coeffs, "put", "buy", OPT_SLIP)
        mtm_cost_sp = active_sp["shares"] * pm_sp_last
        open_sp_ser = {
            "leg_id": f"SP-{active_sp['sp_id']}",
            "sp_id": active_sp["sp_id"],
            "cycle_id": active_sp["cycle_id"],
            "leg_type": "short_put",
            "is_open_live": True,
            "signal_date": active_sp["signal_date"],
            "entry_date": active_sp["entry_date"],
            "exp_date": active_sp["exp_date"],
            "exit_date": None,
            "dte": active_sp["dte"],
            "rem_dte": rem_sp_last,
            "entry_spot": round(active_sp["entry_spot"], 2),
            "strike": round(active_sp["kp"], 2),
            "kp": round(active_sp["kp"], 2),
            "exit_spot": round(last_cl, 2),
            "shares": round(active_sp["shares"], 2),
            "prem_usd": round(active_sp["prem_usd"], 2),
            "exit_cost_usd": round(mtm_cost_sp, 2),
            "mtm_pnl_usd": round(active_sp["prem_usd"] - mtm_cost_sp, 2),
            "net_pnl_usd": round(active_sp["prem_usd"] - mtm_cost_sp, 2),
            "exit_reason": "open_live_short_put",
        }
        sp_combined_ledger.append(open_sp_ser)
    if active_wc is not None:
        rem_wc_last = max(1, (active_wc["exp_dt"] - last_dt).days)
        _, cm_wc_last = bco_mod._opt_exec_price_sp(last_cl, active_wc["kc"], rem_wc_last / 365.0, last_rf, last_q, last_vxn, coeffs, "call", "buy", OPT_SLIP)
        mtm_cost_wc = active_wc["shares"] * cm_wc_last
        open_wc_ser = {
            "leg_id": f"WC-{active_wc['wc_id']}",
            "wc_id": active_wc["wc_id"],
            "cycle_id": active_wc["cycle_id"],
            "leg_type": "wheel_call",
            "is_open_live": True,
            "signal_date": active_wc["signal_date"],
            "entry_date": active_wc["entry_date"],
            "exp_date": active_wc["exp_date"],
            "exit_date": None,
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
            "mtm_pnl_usd": round(active_wc["prem_usd"] - mtm_cost_wc, 2),
            "net_pnl_usd": round(active_wc["prem_usd"] - mtm_cost_wc, 2),
            "exit_reason": "open_live_wheel_call",
        }
        sp_combined_ledger.append(open_wc_ser)
    sp_combined_ledger.sort(key=lambda x: (x["entry_date"], 0 if x["leg_type"] == "short_put" else 1))

    if cur_cycle_start_dt is not None and assigned_shares > 1e-6:
        max_wheel_cycle_days = max(max_wheel_cycle_days, (last_dt - cur_cycle_start_dt).days)

    end_gross_lev = ((core_shares + assigned_shares) * last_cl) / max(nav_list[-1], 1.0)
    end_put_notional = (active_sp["shares"] * active_sp["kp"]) if active_sp is not None else 0.0
    end_notional_lev = ((core_shares + assigned_shares) * last_cl + end_put_notional) / max(nav_list[-1], 1.0)

    all_leg_sources = (
        [str(x.get("pricing_source") or "bsm_fallback") for x in ledger]
        + [str(x.get("pricing_source") or "bsm_fallback") for x in cc_ledger]
        + [str(x.get("pricing_source") or "bsm_fallback") for x in sp_combined_ledger]
    )
    real_opra_tr_cnt = sum(1 for s in all_leg_sources if s == "real_opra")
    real_poly_tr_cnt = sum(1 for s in all_leg_sources if s == "real_polygon")
    real_tr_cnt = real_opra_tr_cnt + real_poly_tr_cnt
    sim_tr_cnt = len(all_leg_sources) - real_tr_cnt
    real_tr_pct = (real_tr_cnt / len(all_leg_sources) * 100.0) if all_leg_sources else 0.0
    tot_lk = q_stats["total_lookups"]
    real_lk = q_stats["real_opra_hits"] + q_stats["real_polygon_hits"]
    real_hit_pct = (real_lk / tot_lk * 100.0) if tot_lk > 0 else 0.0

    summary = {
        "id": strategy_id,
        "profile": "core3_adaptive" if is_core3 else "full_m7_adaptive",
        "arch": "m7_equal_dollar",
        "pricing_basis": "real_opra_2015_2025_calibrated_bsm" if use_real else "bsm_simulated",
        "fill_mode": fill_mode,
        "real_trades_count": real_tr_cnt,
        "real_opra_trades_count": real_opra_tr_cnt,
        "real_polygon_trades_count": real_poly_tr_cnt,
        "sim_trades_count": sim_tr_cnt,
        "real_trades_pct": round(real_tr_pct, 1),
        "real_quote_lookups": tot_lk,
        "real_quote_hits": real_lk,
        "real_quote_hit_pct": round(real_hit_pct, 1),
        "opra_window_fallbacks": q_stats["opra_window_fallbacks"],
        "opra_window_end": real_store.opra_date_max if use_real else "",
        "polygon_window_end": real_store.polygon_date_max if use_real else "",
        "put_otm": put_otm,
        "put_otm_pct": otm_pct_int,
        "m7_tp_mode": m7_tp_mode,
        "roll_mode": roll_mode,
        "target_dte": target_dte,
        "roll_dte": roll_dte_thr,
        "m0_enabled": m0_enabled,
        "max_slots": max_slots,
        "slot_coverage": 0.50,
        "end_nav": round(nav_list[-1], 2),
        "bh_parity_end_nav": round(bh_m7["end_nav"], 2),
        "net_alpha_usd": round(net_alpha, 2),
        "cagr_pct": round(cagr * 100.0, 2),
        "vol_pct": round(vol * 100.0, 2),
        "max_dd_pct": round(mdd * 100.0, 2),
        "sharpe": round(sharpe, 3),
        "sortino": round(sortino, 3),
        "calmar": round(calmar, 3),
        "win_rate_pct": round(win_rate_pct, 1),
        "profit_factor": round(profit_factor, 3),
        "payout_to_cost": round(payout_to_cost, 3),
        "final_shares": round(equiv_sh_list[-1], 2),
        "bh_final_shares": round(final_bh_sh, 2),
        "extra_shares_vs_bh": round(extra_sh_vs_bh, 2),
        "extra_shares_pct": round(extra_sh_pct, 2),
        "pct_days_hedged": round(pct_active, 1),
        "alpha_per_active_day_usd": round(net_alpha / active_days, 2),
        "tranches_total": len(ledger),
        "closed_trades_count": closed_trades_count,
        "naked_count": len(ledger),
        "collar_count": 0,
        "tp_count": n_tp,
        "roll_salvage_count": roll_salvage_count,
        "roll_30d_count": roll_30d_count,
        "roll_50d_count": roll_50d_count,
        "avg_roll_salvage_pct": round(avg_roll_salvage_pct, 1),
        "max_roi_mult": round(max_roi, 2),
        "naked_prem_spent_usd": round(naked_spent, 2),
        "gross_put_monetized_usd": round(gross_put, 2),
        "gross_call_drag_usd": 0.0,
        "sum_delta_usd": round(sum(x["delta_usd"] for x in ledger), 2),
        "sum_gamma_usd": round(sum(x["gamma_usd"] for x in ledger), 2),
        "sum_vega_usd": round(sum(x["vega_usd"] for x in ledger), 2),
        "sum_theta_slip_usd": round(sum(x["theta_slip_usd"] for x in ledger), 2),
        "cc_mode": cc_mode,
        "cc_trades_count": len(cc_ledger),
        "cc_assigned_count": cc_assigned_cnt,
        "cc_stop_count": sum(1 for x in cc_ledger if x["exit_reason"] in ("delta_stop", "delta_roll_up", "delta_credit_roll")),
        "cc_roll_count": sum(1 for x in cc_ledger if int(x.get("roll_gen", 0)) > 0),
        "cc_active_years": len({x["entry_date"][:4] for x in cc_ledger}),
        "cc_gross_prem_usd": round(cc_gross_prem, 2),
        "cc_gross_loss_usd": round(cc_gross_loss, 2),
        "cc_net_pnl_usd": round(cc_gross_prem - cc_gross_loss, 2),
        "cc_funded_puts_usd": round(cc_funded_puts, 2),
        "cc_cash_end_usd": round(cc_cash, 2),
        "sp_mode": sp_mode,
        "wc_mode": wc_mode,
        "sp_trades_count": len(sp_closed_ledger) + (1 if open_sp_ser else 0),
        "sp_win_rate_pct": round(sp_win_rate, 1),
        "sp_assignments_count": sp_assign_count,
        "wc_trades_count": len(wc_closed_ledger) + (1 if open_wc_ser else 0),
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
        "end_sp_cash_usd": round(sp_cash, 2),
    }

    sp_live_eod = {
        "sp_mode": sp_mode,
        "wc_mode": wc_mode,
        "enabled": sp_enabled,
        "sp_dte": sp_dte,
        "sp_otm_pct": sp_otm_pct,
        "sp_max_lev": sp_max_lev,
        "require_vix_falling": sp_require_vix_falling,
        "assigned_shares": round(assigned_shares, 2),
        "assigned_cost_k": round(assigned_cost_k, 2),
        "sp_cash_usd": round(sp_cash, 2),
        "gross_stock_lev": round(end_gross_lev, 3),
        "notional_lev": round(end_notional_lev, 3),
        "pending_sp_eod": pending_sp is not None,
        "pending_wc_eod": pending_wc is not None,
        "open_short_put": open_sp_ser,
        "open_wheel_call": open_wc_ser,
    }

    return {
        "summary": summary,
        "nav": nav_list,
        "equiv_shares": equiv_sh_list,
        "any_active": any_active_list,
        "active_slots": active_slots_list,
        "slot1_naked": [s > 0 for s in active_slots_list],
        "ledger": ledger,
        "cc_ledger": cc_ledger,
        "sp_ledger": sp_combined_ledger,
        "shield_events": [],
        "active_tranches_eod": active_tranches_serialized,
        "pending_sig_eod": pending_sig,
        "sp_live_eod": sp_live_eod,
    }


def build_m7_live_dashboard(
    row: dict[str, Any],
    sig_day: dict[str, Any],
    feat_row_dict: dict[str, Any],
    m7_sim: dict[str, Any],
    coeffs: list[float],
    bco_mod: Any,
    put_otm: str = DEFAULT_PUT_OTM,
    m7_tp_mode: str = DEFAULT_M7_TP_MODE,
    roll_mode: str = DEFAULT_ROLL_MODE,
    m0_enabled: bool = DEFAULT_M0_ENABLED,
) -> dict[str, Any]:
    d = str(row["date"])
    cl = float(row["close"])
    ath = float(row["running_ath"])
    dd_pct = float(row["dd_from_ath"]) * 100.0
    vxn = float(row["vxn"])
    vr = float(row["vix_ratio"])
    r_cur = float(row["r"])
    q_cur = float(row["div_yield"])
    sc = int(row["score"])
    ad_line = float(row["ad_line"])
    ad_sma50 = float(row["ad_sma50"])
    ad_below = ad_line < ad_sma50

    strategy_id = str(m7_sim["summary"]["id"])
    is_core3 = strategy_id == "Core3_Adaptive"
    if is_core3 and roll_mode == "90d_hold":
        roll_mode = "adaptive_120_90"
    is_adaptive = roll_mode == "adaptive_120_90"
    is_roll50 = roll_mode == "120d_roll50"
    is_cta_now = bool(sig_day.get("M4", False))
    if is_adaptive:
        entry_dte = 90 if is_cta_now else 120
        roll_dte = 30 if is_cta_now else 50
    elif is_roll50:
        entry_dte = 120
        roll_dte = 50
    else:
        entry_dte = 90
        roll_dte = 0
    five_x_dte = 45

    max_slots = int(m7_sim["summary"]["max_slots"])
    is_graded = max_slots == 3
    if is_core3:
        prob = float(sig_day["crisis_prob_c3"])
        p1 = float(sig_day["p1_c3"])
        p2 = 0.0
        p3 = float(sig_day["p3_c3"])
        target_slots = int(sig_day["target_slots_c3"])
    else:
        prob = float(sig_day["crisis_prob"])
        p1 = float(sig_day["p1"])
        p2 = float(sig_day["p2"])
        p3 = float(sig_day["p3"])
        target_slots = int(sig_day["target_slots_m7g" if is_graded else "target_slots_m7"])

    active_tr = m7_sim["active_tranches_eod"]
    active_slots = len(active_tr)
    eff_active_tr = active_tr
    pend_sig = m7_sim["pending_sig_eod"]

    vxn_red_ok = vxn <= 27.0
    vr_red_ok = vr < 1.02
    redline_blocked = not (vxn_red_ok and vr_red_ok)

    req_gap = 21 if target_slots == 3 else 30
    cur_dt = datetime.date.fromisoformat(d)
    last_entry_dt_str: str | None = None
    days_since_last: int | None = None
    if eff_active_tr:
        last_entry_dt_str = max(t["entry_date"] for t in eff_active_tr)
        days_since_last = (cur_dt - datetime.date.fromisoformat(last_entry_dt_str)).days
    cooldown_passed = (days_since_last is None) or (days_since_last >= req_gap)

    mods_active, trig_code, _, _ = format_m7_trigger_labels(sig_day, max_slots, core3_only=is_core3)

    def _fv(key: str, default: float = 0.0) -> float:
        v = feat_row_dict.get(key)
        return default if v is None else float(v)

    def _fv_opt(key: str) -> float | None:
        v = feat_row_dict.get(key)
        return None if v is None else float(v)

    rsp_spy_v, rsp_sma_v = _fv("rsp_spy"), _fv("rsp_sma50")
    iwm_qqq_v, iwm_sma_v = _fv("iwm_qqq"), _fv("iwm_sma50")
    def_ret20_raw = _fv("def_ret20")
    def_ret20_pct = def_ret20_raw * 100.0
    skew10_v, skew_p75_v = _fv("skew10"), _fv("skew_p75")
    vvix_v, vvix_p75_v = _fv("vvix"), _fv("vvix_p75")
    vr_j5_v = _fv("vr_jump5")
    hmm_p_v, hmm_p5_v = _fv("hmm_p"), _fv("hmm_p5")
    ewmac_v, ema20_v, sma200_v = _fv("ewmac"), _fv("ema20"), _fv("sma200")
    hyg_v, hyg_sma_v = _fv("hyg_lqd"), _fv("hyg_sma50")
    baa_v = _fv("baa_lag1")
    baa_r_opt = _fv_opt("baa_rise63")
    baa_r_v = baa_r_opt if baa_r_opt is not None else 0.0
    dgs2_j_opt = _fv_opt("dgs2_jump63")
    dgs2_j_v = dgs2_j_opt if dgs2_j_opt is not None else 0.0
    nfci_j_opt = _fv_opt("nfci_jump20")
    nfci_j_v = nfci_j_opt if nfci_j_opt is not None else 0.0

    stress_pack = compute_live_stress_index(
        hmm_p=hmm_p_v,
        vxn=vxn,
        vix_ratio=vr,
        dd_from_ath=float(row["dd_from_ath"]),
        close=cl,
        sma200=sma200_v,
        ewmac=ewmac_v,
        hyg_lqd=hyg_v,
        hyg_sma50=hyg_sma_v,
        baa_rise63=baa_r_opt,
        dgs2_jump63=dgs2_j_opt,
        nfci_jump20=nfci_j_opt,
        def_ret20=def_ret20_raw,
        rsp_spy=rsp_spy_v,
        rsp_sma50=rsp_sma_v,
        iwm_qqq=iwm_qqq_v,
        iwm_sma50=iwm_sma_v,
        ad_below50=ad_below,
        vvix=vvix_v,
        vvix_p75=vvix_p75_v,
        skew10=skew10_v,
        skew_p75=skew_p75_v,
        vr_jump5=vr_j5_v,
    )
    stress_idx = int(stress_pack["live_stress_index"])
    stress_lbl_en = str(stress_pack["live_stress_label_en"])
    stress_lbl_zh = str(stress_pack["live_stress_label_zh"])

    # T+1 Open Execution Order Verdict
    any_tp_armed = any(bool(t.get("pending_tp")) and not str(t.get("tp_reason", "")).startswith("roll_") for t in active_tr)
    any_roll_armed = any(bool(t.get("pending_tp")) and str(t.get("tp_reason", "")).startswith("roll_") for t in active_tr)
    armed_roll_d = next(
        (int(t.get("roll_dte") or 50) for t in active_tr if bool(t.get("pending_tp")) and str(t.get("tp_reason", "")).startswith("roll_")),
        roll_dte if roll_dte > 0 else 50,
    )
    otm_lbl = "-20% OTM" if put_otm == "otm20" else "-15% OTM"
    if is_adaptive:
        tenor_lbl_en = f"{entry_dte}D (Roll@{roll_dte}D)"
        tenor_lbl_zh = f"{entry_dte}D（剩{roll_dte}天滚仓）"
    elif is_roll50:
        tenor_lbl_en = "120D (Roll@50D)"
        tenor_lbl_zh = "120D（剩50天滚仓）"
    else:
        tenor_lbl_en = "90D"
        tenor_lbl_zh = "90D"

    if any_tp_armed:
        t1_code = "TP_ARMED_NEXT_OPEN"
        t1_tone = "tp"
        t1_badge_en = "T+1 OPEN: TAKE-PROFIT MONETIZE & RELOAD QQQ"
        t1_badge_zh = "T+1 开盘指令：触发恐慌止盈 · 变现 Put 抄底加仓 QQQ"
        t1_title_en = "Panic Take-Profit Triggered — Monetize Active Put Slot(s) at Next Open"
        t1_title_zh = "恐慌止盈阈值已触发 —— 次日开盘全额平仓变现并复投 QQQ 正股"
    elif any_roll_armed and target_slots > 0:
        t1_code = "ROLL_50D_AND_REOPEN"
        t1_tone = "armed"
        t1_badge_en = f"T+1 OPEN: {armed_roll_d}-DTE ROLL -> HARVEST RESIDUAL & OPEN {entry_dte}D {otm_lbl} PUT"
        t1_badge_zh = f"T+1 开盘指令：剩 <={armed_roll_d} DTE 触发滚仓 · 回收残值并换入新 {entry_dte}D {otm_lbl} Put"
        t1_title_en = f"Low-Vol Entry Gate {prob:.0f}% ({trig_code}) Active at <={armed_roll_d} DTE — Salvage Expiring Slot & Roll Into Fresh {entry_dte}-DTE {otm_lbl} Put"
        t1_title_zh = f"在途槽位剩 <={armed_roll_d} DTE 且买盾执行分 {prob:.0f}%（{trig_code}）仍亮 —— 次日开盘回收残值并滚入新 {entry_dte}D {otm_lbl} Put"
    elif any_roll_armed:
        t1_code = "SALVAGE_50D_EXIT"
        t1_tone = "active"
        t1_badge_en = f"T+1 OPEN: {armed_roll_d}-DTE SALVAGE EXIT -> HARVEST RESIDUAL TO QQQ"
        t1_badge_zh = f"T+1 开盘指令：剩 <={armed_roll_d} DTE 信号熄灭 · 平仓回收残值复投 QQQ"
        t1_title_en = f"Slot Reached <={armed_roll_d} DTE With Entry Gate Off — Exit Before Theta Cliff & Reinvest Residual Cash Into QQQ"
        t1_title_zh = f"在途槽位剩 <={armed_roll_d} DTE 且买盾执行信号已解除 —— 在 Theta 悬崖前平仓回收残值并复投 QQQ"
    elif pend_sig is not None:
        next_slot_idx = len(eff_active_tr) + 1
        t1_code = "OPEN_NEW_SLOT"
        t1_tone = "armed"
        t1_badge_en = f"T+1 OPEN: BUY 1 NEW SLOT (SLOT {next_slot_idx}/{max_slots} · {tenor_lbl_en} {otm_lbl} PUT)"
        t1_badge_zh = f"T+1 开盘指令：新开 1 槽保护（第 {next_slot_idx}/{max_slots} 槽 · {tenor_lbl_zh} {otm_lbl} Put）"
        t1_title_en = f"Real-Time Stress {stress_idx}% · Low-Vol Gate {prob:.0f}% ({trig_code}) -> Open Slot {next_slot_idx}/{max_slots} Equal-Dollar {entry_dte}-DTE {otm_lbl} Put"
        t1_title_zh = f"实时压力 {stress_idx}% · 低波买盾执行分 {prob:.0f}%（{trig_code}）-> 次日开盘按等金额预算买入第 {next_slot_idx}/{max_slots} 槽 {tenor_lbl_zh} {otm_lbl} Put"
    elif target_slots > len(eff_active_tr) and redline_blocked:
        t1_code = "REDLINE_BLOCKED"
        t1_tone = "blocked"
        t1_badge_en = "T+1 OPEN: HARD REDLINE BLOCKED (NO NEW PUTS IN HIGH IV)"
        t1_badge_zh = "T+1 开盘指令：风控红线锁死禁开新仓（拒绝高波追买天价 Put）"
        t1_title_en = f"Real-Time Stress {stress_idx}% ({stress_lbl_en}) · Hard Redline Active (VXN {vxn:.1f} > 27 or VIX/3M {vr:.3f} >= 1.02) — Chasing Expensive Puts Forbidden"
        t1_title_zh = f"实时危机压力 {stress_idx}%（{stress_lbl_zh}）· 绝对风控红线生效（VXN {vxn:.1f} > 27 或 VIX/3M {vr:.3f} >= 1.02）—— 严禁高波追高买贵盾"
    elif target_slots > len(eff_active_tr) and not cooldown_passed:
        rem_wait = max(1, req_gap - (days_since_last or 0))
        t1_code = "COOLDOWN_WAIT"
        t1_tone = "cooldown"
        t1_badge_en = f"T+1 OPEN: COOLDOWN WAIT ({days_since_last}D / {req_gap}D · {rem_wait}D LEFT)"
        t1_badge_zh = f"T+1 开盘指令：加仓冷却期等待中（距上槽 {days_since_last}/{req_gap} 天 · 还需 {rem_wait} 天）"
        t1_title_en = f"Low-Vol Entry Gate {prob:.0f}% Wants {target_slots} Slots, Waiting {rem_wait} Calendar Days for {req_gap}D Step Cooldown"
        t1_title_zh = f"低波买盾执行分 {prob:.0f}% 指向 {target_slots} 槽，当前距上一槽仅 {days_since_last} 天（未满 {req_gap} 天冷却期，暂缓加槽）"
    elif active_slots > 0:
        t1_code = "HOLD_ACTIVE_SLOTS"
        t1_tone = "active"
        roll_note_en = f" · ROLL @ <={roll_dte} DTE" if roll_dte > 0 else ""
        roll_note_zh = f" · 剩<={roll_dte}天滚仓" if roll_dte > 0 else ""
        t1_badge_en = f"T+1 OPEN: HOLD {active_slots}/{max_slots} ACTIVE PUT SLOT(S) · MONITOR TP{roll_note_en}"
        t1_badge_zh = f"T+1 开盘指令：继续持有 {active_slots}/{max_slots} 槽在途 Put · 盯紧止盈线{roll_note_zh}"
        t1_title_en = f"Real-Time Stress {stress_idx}% ({stress_lbl_en}) · {active_slots}/{max_slots} Equal-Dollar Put Slot(s) Shielding 100% Uncapped QQQ Core"
        t1_title_zh = f"实时危机压力 {stress_idx}%（{stress_lbl_zh}）· 当前 {active_slots}/{max_slots} 槽等金额裸 Put 在途护航（100% QQQ 底仓无封顶持有）"
    else:
        t1_code = "STANDBY"
        t1_tone = "standby"
        prof_lbl_en = "Core-3 Minimal" if is_core3 else "Full M7 Shield"
        prof_lbl_zh = "精简3核" if is_core3 else "全套M7护盾"
        if redline_blocked:
            t1_badge_en = "T+1 OPEN: STANDBY (100% QQQ · HIGH-VOL REDLINE FREEZE)"
            t1_badge_zh = "T+1 开盘指令：空盾待命（100% 满仓 QQQ · 高波红线冻结禁追买贵盾）"
            t1_title_en = (
                f"Real-Time Stress {stress_idx}% ({stress_lbl_en}) · {prof_lbl_en} Low-Vol Entry Gate {prob:.0f}% "
                f"(High-IV Redline VXN {vxn:.1f} / VIX/3M {vr:.3f} Freezes Chasing Expensive Puts — Hold 100% QQQ Uncapped)"
            )
            t1_title_zh = (
                f"实时危机压力 {stress_idx}%（{stress_lbl_zh}）· {prof_lbl_zh}低波买盾执行分 {prob:.0f}% "
                f"（高波红线 VXN {vxn:.1f} / VIX/3M {vr:.3f} 冻结禁追高买贵盾 —— 100% QQQ 零损耗待弹）"
            )
        else:
            t1_badge_en = "T+1 OPEN: STANDBY · ZERO PUT SPEND (100% QQQ CRUISE)"
            t1_badge_zh = "T+1 开盘指令：静默待命 · 零保费损耗（100% 满仓 QQQ 复利巡航）"
            t1_title_en = (
                f"Real-Time Stress {stress_idx}% ({stress_lbl_en}) · {prof_lbl_en} Low-Vol Entry Gate {prob:.0f}% "
                f"(< 35% Threshold) — Zero Option Drag, 100% QQQ Compounding"
            )
            t1_title_zh = (
                f"实时危机压力 {stress_idx}%（{stress_lbl_zh}）· {prof_lbl_zh}低波买盾执行分 {prob:.0f}% "
                f"（低于 35% 开仓线）—— 零期权保费损耗，100% QQQ 顺风复利"
            )

    # Equal-Dollar Strike & Budget Calculator (90-DTE or 120-DTE matched reference)
    tau_calc = float(entry_dte) / 365.0
    k10 = cl * 0.90
    k15 = cl * 0.85
    k20 = cl * 0.80
    iv10 = bco_mod.eval_skew_iv(cl, k10, tau_calc, r_cur, q_cur, vxn, coeffs)
    iv15 = bco_mod.eval_skew_iv(cl, k15, tau_calc, r_cur, q_cur, vxn, coeffs)
    iv20 = bco_mod.eval_skew_iv(cl, k20, tau_calc, r_cur, q_cur, vxn, coeffs)
    mid10 = bco_mod.bsm_price(cl, k10, tau_calc, r_cur, q_cur, iv10, "put")
    mid15 = bco_mod.bsm_price(cl, k15, tau_calc, r_cur, q_cur, iv15, "put")
    mid20 = bco_mod.bsm_price(cl, k20, tau_calc, r_cur, q_cur, iv20, "put")
    ask10_ref = mid10 * (1.0 + OPT_SLIP) + OPT_COMM_PER_SH
    ask15 = mid15 * (1.0 + OPT_SLIP) + OPT_COMM_PER_SH
    ask20 = mid20 * (1.0 + OPT_SLIP) + OPT_COMM_PER_SH
    skew_ratio = iv20 / max(iv10, 1e-6)
    favorable_20 = skew_ratio <= 1.18

    sel_ask = ask20 if put_otm == "otm20" else ask15
    sel_k = k20 if put_otm == "otm20" else k15
    ref_sh_1000 = 1000.0
    budget_per_1000_sh = (ref_sh_1000 * 0.50) * ask10_ref
    contracts_per_1000_sh = (budget_per_1000_sh / max(sel_ask, 1e-6)) / 100.0

    roll_formula_en = (
        " · Adaptive Roll: P1/P2 120D->50D, CTA M4 90D->30D"
        if is_adaptive
        else (" · Salvage/Roll at <= 50 DTE" if is_roll50 else "")
    )
    roll_formula_zh = (
        " · 自适应滚仓：P1/P2 120D->50D、CTA(M4) 90D->30D"
        if is_adaptive
        else (" · 剩 <=50 DTE 残值滚仓/平仓" if is_roll50 else "")
    )

    sizing_calc = {
        "qqq_spot": round(cl, 2),
        "vxn": round(vxn, 2),
        "dte": entry_dte,
        "roll_dte": roll_dte,
        "roll_mode": roll_mode,
        "selected_otm": put_otm,
        "formula_en": f"Per-Slot Budget = Current QQQ Shares × 50% × Ask({entry_dte}D -10% OTM Put){roll_formula_en}",
        "formula_zh": f"单槽美元预算 = 当前持有 QQQ 股数 × 50% × {entry_dte}-DTE -10% OTM Put 卖一价(Ask){roll_formula_zh}",
        "ref_otm10": {
            "otm_pct": 10,
            "strike": round(k10, 2),
            "iv_pct": round(iv10 * 100.0, 2),
            "mid_sh": round(mid10, 2),
            "ask_sh": round(ask10_ref, 2),
        },
        "otm15": {
            "otm_pct": 15,
            "strike": round(k15, 2),
            "iv_pct": round(iv15 * 100.0, 2),
            "mid_sh": round(mid15, 2),
            "ask_sh": round(ask15, 2),
        },
        "otm20": {
            "otm_pct": 20,
            "strike": round(k20, 2),
            "iv_pct": round(iv20 * 100.0, 2),
            "mid_sh": round(mid20, 2),
            "ask_sh": round(ask20, 2),
        },
        "skew_ratio_20_10": round(skew_ratio, 3),
        "skew_switch_threshold": 1.18,
        "favorable_otm20_skew": favorable_20,
        "skew_tip_en": (
            f"Tail Skew Favorable: IV(-20%)/IV(-10%) = {skew_ratio:.3f} <= 1.18 — switching equal budget to -20% OTM offers superior crash convexity!"
            if favorable_20
            else f"Steep Tail Skew: IV(-20%)/IV(-10%) = {skew_ratio:.3f} > 1.18 — keep default -15% OTM to avoid overpaying deep-tail skew."
        ),
        "skew_tip_zh": (
            f"偏度性价比极佳：当前 IV(-20%)/IV(-10%) = {skew_ratio:.3f} <= 1.18 —— 等金额切换至 -20% OTM 可获更高崩盘凸性赔率！"
            if favorable_20
            else f"尾部偏度较陡：当前 IV(-20%)/IV(-10%) = {skew_ratio:.3f} > 1.18 —— 建议维持默认 -15% OTM，避免为深虚值高偏度溢价买单。"
        ),
        "default_qqq_shares": 1000,
        "model_qqq_shares": round(float(m7_sim["summary"]["final_shares"]), 2),
        "sample_1000sh_budget_usd": round(budget_per_1000_sh, 2),
        "sample_1000sh_selected_strike": round(sel_k, 2),
        "sample_1000sh_selected_ask": round(sel_ask, 2),
        "sample_1000sh_contracts": round(contracts_per_1000_sh, 2),
    }

    # TP Monitor
    tp_spec = next((x for x in M7_TP_MODE_SPECS if x["id"] == m7_tp_mode), M7_TP_MODE_SPECS[0])
    roll_rule_en = (
        "; else salvage/roll at DTE <= 50 (Non-CTA 120D) or DTE <= 30 (CTA M4 90D)."
        if is_adaptive
        else ("; else at DTE <= 50 salvage residual (and roll into fresh 120D Put if M7 stays active)." if is_roll50 else ".")
    )
    roll_rule_zh = (
        "；未止盈则在非CTA槽 DTE<=50 / CTA(M4)槽 DTE<=30 时回收残值（信号仍亮则自动滚仓）。"
        if is_adaptive
        else ("；未止盈且 DTE <= 50 时次日开盘回收残值（信号仍亮则同步滚入新 120D Put）。" if is_roll50 else "。")
    )
    tp_rule_en = (
        (
            f"Exit at T+1 Open when EOD (VIX/VIX3M >= 1.10 AND QQQ <= Strike Kp) OR (DTE <= {five_x_dte} AND Put Mid >= 5x Cost)"
            if m7_tp_mode == "itm_tp"
            else f"Exit at T+1 Open when EOD VIX/VIX3M >= 1.10 OR (DTE <= {five_x_dte} AND Put Mid >= 5x Cost)"
        )
        + roll_rule_en
    )
    tp_rule_zh = (
        (
            f"收盘同时满足（VIX/VIX3M >= 1.10 且 QQQ <= 行权价 Kp 实值），或（DTE <= {five_x_dte} 且中间价 >= 5 倍成本）次日开盘止盈"
            if m7_tp_mode == "itm_tp"
            else f"收盘触发 VIX/VIX3M >= 1.10 恐慌倒挂，或（DTE <= {five_x_dte} 且期权中间价 >= 5 倍成本）次日开盘止盈"
        )
        + roll_rule_zh
    )
    tp_slots_live: list[dict[str, Any]] = []
    for tr in active_tr:
        kp_tr = float(tr["kp"])
        rem_tr = int(tr["rem_dte"])
        tr_rd = int(tr.get("roll_dte") or 0)
        is_itm = cl <= kp_tr
        tp_vix_ok = (vr >= 1.10) and (is_itm if m7_tp_mode == "itm_tp" else True)
        tp_5x_ok = rem_tr <= five_x_dte and float(tr["mtm_put_val_sh"]) >= float(tr["tp_target_5x_sh"])
        roll50_due = bool(tr_rd > 0 and rem_tr <= tr_rd and not tp_vix_ok and not tp_5x_ok)
        tp_slots_live.append(
            {
                "slot_num": tr["slot_num"],
                "entry_date": tr["entry_date"],
                "exp_date": tr["exp_date"],
                "rem_dte": rem_tr,
                "roll_dte": tr_rd,
                "days_to_roll50": max(0, rem_tr - tr_rd) if tr_rd > 0 else None,
                "roll50_due": roll50_due,
                "kp": kp_tr,
                "spot_vs_kp_pct": round((cl / kp_tr - 1.0) * 100.0, 2),
                "is_itm": is_itm,
                "entry_ask_sh": tr["entry_put_ask_sh"],
                "current_mid_sh": tr["mtm_put_val_sh"],
                "target_5x_mid_sh": tr["tp_target_5x_sh"],
                "roi_mult": tr["roi_mult"],
                "mtm_pnl_usd": tr["mtm_pnl_usd"],
                "vix_leg_met": tp_vix_ok,
                "five_x_leg_met": tp_5x_ok,
                "pending_tp": bool(tr["pending_tp"]),
                "tp_reason": tr.get("tp_reason") or "",
            }
        )

    tp_monitor = {
        "tp_mode": m7_tp_mode,
        "tp_code": tp_spec["code"],
        "roll_mode": roll_mode,
        "five_x_max_dte": five_x_dte,
        "roll_dte": roll_dte,
        "label_en": tp_spec["label_en"],
        "label_zh": tp_spec["label_zh"],
        "rule_en": tp_rule_en,
        "rule_zh": tp_rule_zh,
        "vix_ratio_now": round(vr, 3),
        "vix_ratio_target": 1.10,
        "vix_ratio_met": bool(vr >= 1.10),
        "qqq_spot_now": round(cl, 2),
        "simulated_next_slot_kp": round(sel_k, 2),
        "simulated_next_slot_5x_mid": round(5.0 * sel_ask, 2),
        "open_slots": tp_slots_live,
    }

    # Three-Pillar & 6 Sub-Module Status Grid (dimming M2/M5/M3 cleanly when Core-3 Minimal is active)
    # Compute per-module real-time readiness, sensor_triggered (ignoring low-vol VXN/VIX3M gate), status_code & next_trigger_hint
    m0_ath_ok = bool(dd_pct >= -5.0)
    m0_ad_ok = bool(m0_enabled and ad_below)
    m0_sc_ok = bool(m0_enabled and sc >= 4)
    m0_vg_ok = bool(vxn <= 22.0)
    m0_trig = bool(sig_day["M0"])
    m0_sensor = bool(m0_enabled and m0_ath_ok and (m0_ad_ok or m0_sc_ok))
    if not m0_enabled:
        m0_met = 0
        m0_status = "DISABLED_M0_OFF"
        m0_hint_en = "M0 Six-Lights baseline switch disabled by user"
        m0_hint_zh = "用户已手动关闭 M0 六灯基线开关"
    elif m0_trig:
        m0_met = int(m0_ath_ok) + int(m0_ad_ok) + int(m0_sc_ok)
        m0_status = "ARMED_BUY"
        m0_hint_en = "Near-ATH fragility active & VXN <= 22 — contributing +35% to P1"
        m0_hint_zh = "高位顶背离确认且 VXN <= 22 —— 已为 P1 贡献 +35% 买盾分"
    elif m0_sensor and not m0_vg_ok:
        m0_met = int(m0_ath_ok) + int(m0_ad_ok) + int(m0_sc_ok)
        m0_status = "SENSOR_RED_VOL_BLOCKED"
        m0_hint_en = f"Breadth/Macro warning lit near highs · Blocked by VXN {vxn:.1f} > 22.0"
        m0_hint_zh = f"高位宽度/六灯预警已亮 · 因 VXN {vxn:.1f} > 22.0 暂禁追买"
    elif m0_ad_ok or m0_sc_ok:
        m0_met = int(m0_ath_ok) + int(m0_ad_ok) + int(m0_sc_ok)
        m0_status = "WARMING_UP"
        m0_hint_en = f"Macro/AD warning lit ({m0_met}/3) · M0 only arms near highs (QQQ {dd_pct:+.1f}% < -5% ATH)"
        m0_hint_zh = f"宽度/六灯已亮 ({m0_met}/3) · M0 仅在距前高 -5% 内潜伏（当前 {dd_pct:+.1f}%）"
    elif sc == 3:
        m0_met = 1
        m0_status = "WARMING_UP"
        m0_hint_en = f"Macro lights warming ({sc}/6) · Needs >=4/6 lights or AD < 50DMA"
        m0_hint_zh = f"宏观六灯预热中 ({sc}/6) · 需亮满 >=4/6 灯或 AD 跌破 50DMA"
    else:
        m0_met = 0
        m0_status = "CALM"
        m0_hint_en = f"Breadth healthy & macro lights {sc}/6 — calm regime"
        m0_hint_zh = f"市场宽度健康且宏观六灯 {sc}/6 —— 平静巡航"

    m6_rsp_ok = bool(rsp_sma_v > 0 and rsp_spy_v < rsp_sma_v)
    m6_iwm_ok = bool((iwm_sma_v > 0 and iwm_qqq_v < iwm_sma_v) or (m0_enabled and ad_below))
    m6_def_ok = bool(def_ret20_pct >= 2.50)
    m6_vg_ok = bool(vxn <= 25.0 and vr <= 0.92)
    m6_trig = bool(sig_day["M6"])
    m6_sensor = bool(m6_rsp_ok and m6_iwm_ok and m6_def_ok)
    m6_met = int(m6_rsp_ok) + int(m6_iwm_ok) + int(m6_def_ok)
    if m6_trig:
        m6_status = "ARMED_BUY"
        m6_hint_en = "All 3 breadth + defensive rotation checks lit in low vol (+20%)"
        m6_hint_zh = "宽度恶化 + 防御轮动 3/3 全亮且低波达标（+20% 买盾分）"
    elif m6_sensor and not m6_vg_ok:
        m6_status = "SENSOR_RED_VOL_BLOCKED"
        m6_hint_en = f"Breadth + defensive rotation 3/3 lit · Vol gate VXN {vxn:.1f} / VIX/3M {vr:.3f} freezes chasing"
        m6_hint_zh = "宽度恶化与防御抢跑 3/3 预警已亮 · 因高波红线暂缓追高买贵盾"
    elif m6_met > 0:
        m6_status = "WARMING_UP"
        m6_miss_en: list[str] = []
        m6_miss_zh: list[str] = []
        if not m6_rsp_ok:
            m6_miss_en.append("RSP/SPY<SMA50")
            m6_miss_zh.append("等权走弱")
        if not m6_iwm_ok:
            m6_miss_en.append("IWM/QQQ<SMA50")
            m6_miss_zh.append("小盘走弱")
        if not m6_def_ok:
            m6_miss_en.append("Def/XLK>=+2.5%")
            m6_miss_zh.append("防御轮动>=+2.5%")
        m6_hint_en = f"Breadth/Rotation {m6_met}/3 lit · Awaiting {' & '.join(m6_miss_en)} (& VXN<=25)"
        m6_hint_zh = f"宽度/防御已亮 {m6_met}/3 · 待触发{'、'.join(m6_miss_zh)}（且低波达标）"
    else:
        m6_status = "CALM"
        m6_hint_en = "Equal-weight, small-caps & tech leadership intact (0/3)"
        m6_hint_zh = "等权、小盘与科技领涨结构完好（0/3 平静）"

    m2_core_a = bool(skew_p75_v > 0 and vvix_p75_v > 0 and skew10_v >= skew_p75_v and vvix_v >= vvix_p75_v)
    m2_core_b = bool(vr_j5_v >= 0.06 and vvix_v >= 100.0)
    m2_vg_ok = bool(vxn <= 24.0 and vr <= 1.02)
    m2_trig = False if is_core3 else bool(sig_day["M2"])
    m2_sensor = False if is_core3 else bool(m2_trig or (m2_core_a and vr >= 0.85) or (m2_core_b and vr >= 0.92))
    m2_met = 0 if is_core3 else (int(bool(sig_day["M2_silent_tail"]) or m2_core_a) + int(bool(sig_day["M2_term_inflection"]) or m2_core_b))
    if is_core3:
        m2_status = "DISABLED_IN_CORE3"
        m2_hint_en = "Omitted in Core-3 Minimal (switch to Full M7 Shield to enable)"
        m2_hint_zh = "精简 3 核模式下已关闭（切换全套 M7 护盾可启用外生预警）"
    elif m2_trig:
        m2_status = "ARMED_BUY"
        m2_hint_en = "Options desk skew/VVIX tail warning active in calm IV (+20%)"
        m2_hint_zh = "期权台偏度/VVIX 买尾预警在低波区触发（+20% 买盾分）"
    elif m2_sensor and not m2_vg_ok:
        m2_status = "SENSOR_RED_VOL_BLOCKED"
        m2_hint_en = f"Options tail stress {m2_met}/2 active · High-IV gate (VXN {vxn:.1f} > 24) blocks chasing"
        m2_hint_zh = f"期权台尾部异动 {m2_met}/2 已亮 · 因高波门控（VXN {vxn:.1f} > 24）禁追高"
    elif m2_met > 0:
        m2_status = "WARMING_UP"
        m2_hint_en = f"Tail skew/VVIX warming ({m2_met}/2) · Awaiting calm term-structure window"
        m2_hint_zh = f"偏度/VVIX 异动预热 ({m2_met}/2) · 等待期限结构落入低波击球区"
    else:
        m2_status = "CALM"
        m2_hint_en = "SKEW & VVIX below tail alert thresholds (0/2)"
        m2_hint_zh = "SKEW 偏度与 VVIX 均未触发买尾异动（0/2 平静）"

    m5_cur_ok = bool(hmm_p_v >= 0.55)
    m5_fresh_ok = bool(hmm_p5_v < 0.40)
    m5_vg_ok = bool(vxn <= 24.0 and vr < 1.02)
    m5_trig = False if is_core3 else bool(sig_day["M5"])
    m5_sensor = False if is_core3 else bool(m5_cur_ok and m5_fresh_ok)
    m5_met = 0 if is_core3 else (2 if (m5_cur_ok and m5_fresh_ok) else (1 if (m5_cur_ok or hmm_p_v >= 0.25) else 0))
    if is_core3:
        m5_status = "DISABLED_IN_CORE3"
        m5_hint_en = "Omitted in Core-3 Minimal (switch to Full M7 Shield to enable)"
        m5_hint_zh = "精简 3 核模式下已关闭（切换全套 M7 护盾可启用外生预警）"
    elif m5_trig:
        m5_status = "ARMED_BUY"
        m5_hint_en = "Fresh HMM stress regime jump in calm IV (+20%)"
        m5_hint_zh = "因果 HMM 初入高压跃迁且低波达标（+20% 买盾分）"
    elif m5_sensor and not m5_vg_ok:
        m5_status = "SENSOR_RED_VOL_BLOCKED"
        m5_hint_en = f"Fresh HMM regime jump 2/2 lit · High-IV gate (VXN {vxn:.1f}) blocks chasing"
        m5_hint_zh = f"HMM 状态跃迁 2/2 已亮 · 因高波红线（VXN {vxn:.1f}）暂禁追买"
    elif m5_cur_ok and not m5_fresh_ok:
        m5_status = "WARMING_UP"
        m5_hint_en = f"HMM already in persistent stress ({hmm_p_v * 100.0:.0f}% · 1/2) · M5 only fires on fresh jump (P_t-5 < 40%)"
        m5_hint_zh = f"HMM 已处于持续高压态 ({hmm_p_v * 100.0:.0f}% · 1/2) · M5 仅在初入跃迁瞬间（5日前<40%）买盾"
    elif m5_met > 0:
        m5_status = "WARMING_UP"
        m5_hint_en = f"HMM stress rising ({hmm_p_v * 100.0:.1f}%) · Needs >= 55% with VXN <= 24"
        m5_hint_zh = f"HMM 高压概率抬头 ({hmm_p_v * 100.0:.1f}%) · 达 >=55% 且 VXN<=24 触发"
    else:
        m5_status = "CALM"
        m5_hint_en = f"Hamilton stress probability {hmm_p_v * 100.0:.1f}% < 55% — calm regime"
        m5_hint_zh = f"因果 HMM 高压后验概率 {hmm_p_v * 100.0:.1f}% < 55% —— 平静低波态"

    m4_below200 = bool(sma200_v > 0 and cl < sma200_v)
    m4_ewmac = bool(ewmac_v < 0.0)
    m4_ema20 = bool(ema20_v > 0 and cl > ema20_v)
    m4_vg_ok = bool(vxn <= 27.0 and vr <= 0.88)
    m4_trig = bool(sig_day["M4"])
    m4_sensor = bool(m4_below200 and m4_ewmac and m4_ema20)
    m4_met = (int(m4_below200) + int(m4_ewmac) + int(m4_ema20)) if (m4_below200 or m4_ewmac) else 0
    if m4_trig:
        m4_status = "ARMED_BUY"
        m4_hint_en = "Bear rally above EMA20 with cheap IV — buying Put shield (+35%)"
        m4_hint_zh = "熊市死猫跳上穿 EMA20 且波动率回落 —— 触发买盾（+35%）"
    elif m4_sensor and not m4_vg_ok:
        m4_status = "SENSOR_RED_VOL_BLOCKED"
        m4_hint_en = f"Bear bounce 3/3 met · Waiting for IV crush (VXN {vxn:.1f}<=27 & VIX/3M {vr:.3f}<=0.88)"
        m4_hint_zh = f"熊市反抽 3/3 已满足 · 等待波动率回落（VXN<=27 且 VIX/3M<=0.88）再低买"
    elif m4_below200 and m4_ewmac and not m4_ema20:
        m4_status = "WARMING_UP"
        m4_hint_en = f"Bear trend broken (2/3) · Awaiting bounce > EMA20 (${ema20_v:.1f}) & VXN <= 27"
        m4_hint_zh = f"趋势已破位 2/3 · 等待反抽 EMA20 (${ema20_v:.1f}) 且 VXN <= 27"
    elif m4_met > 0:
        m4_status = "WARMING_UP"
        m4_hint_en = f"Trend weakening ({m4_met}/3) · Needs QQQ < SMA200 (${sma200_v:.1f}), EWMAC < 0 & > EMA20"
        m4_hint_zh = f"趋势转弱预热 ({m4_met}/3) · 需跌破 200DMA (${sma200_v:.1f}) 且 EWMAC<0 后反抽 EMA20"
    else:
        m4_status = "CALM"
        m4_hint_en = f"Uptrend intact above SMA200 (${sma200_v:.1f}) & EWMAC >= 0"
        m4_hint_zh = f"牛市主趋势完好（站稳 200DMA ${sma200_v:.1f} 且 EWMAC>=0）"

    m3_hyg = bool(hyg_sma_v > 0 and hyg_v < hyg_sma_v)
    m3_baa = bool(baa_r_opt is not None and baa_r_v >= 0.15)
    m3_macro = bool((dgs2_j_opt is not None and dgs2_j_v >= 0.40) or (nfci_j_opt is not None and nfci_j_v >= 0.10))
    m3_vg_ok = bool(vxn <= 26.0 and vr <= 0.92)
    m3_trig = False if is_core3 else bool(sig_day["M3"])
    m3_sensor = False if is_core3 else bool(m3_hyg and (m3_baa or m3_macro))
    m3_met = 0 if is_core3 else (int(m3_hyg) + int(m3_baa) + int(m3_macro))
    if is_core3:
        m3_status = "DISABLED_IN_CORE3"
        m3_hint_en = "Omitted in Core-3 Minimal (switch to Full M7 Shield to enable)"
        m3_hint_zh = "精简 3 核模式下已关闭（切换全套 M7 护盾可启用信用雷达）"
    elif m3_trig:
        m3_status = "ARMED_BUY"
        m3_hint_en = "Credit spread + macro stress lit in low vol (+20%)"
        m3_hint_zh = "信用利差与宏观紧缩共振且低波达标（+20% 买盾分）"
    elif m3_sensor and not m3_vg_ok:
        m3_status = "SENSOR_RED_VOL_BLOCKED"
        m3_hint_en = f"Credit/Macro {m3_met}/3 warning lit · High-vol redline pauses chasing expensive puts"
        m3_hint_zh = f"信用与宏观 {m3_met}/3 预警已亮 · 因高波红线暂缓追高买贵盾"
    elif m3_met > 0:
        m3_status = "WARMING_UP"
        if not m3_hyg:
            m3_hint_en = f"Macro leg lit ({m3_met}/3) · Needs HYG/LQD < SMA50 ({hyg_sma_v:.4f})"
            m3_hint_zh = f"宏观分项已亮 ({m3_met}/3) · 待 HYG/LQD 跌破 50DMA ({hyg_sma_v:.4f})"
        else:
            m3_hint_en = f"HYG/LQD weak ({m3_met}/3) · Needs Baa >=+15bp, 2Y >=+40bp or NFCI >=+0.10"
            m3_hint_zh = f"高收益债走弱 ({m3_met}/3) · 待 Baa走阔>=15bp 或 2Y>=40bp / NFCI>=0.10"
    else:
        m3_status = "CALM"
        m3_hint_en = "Credit spreads & financial conditions benign (0/3)"
        m3_hint_zh = "高收益债利差与金融条件平稳（0/3 平静）"

    pillars = [
        {
            "id": "P1",
            "title_en": "Pillar 1 · Calm-Top Fragility",
            "title_zh": "第一支柱 P1 · 高位脆弱与顶背离",
            "subtitle_en": "Detects stealth breadth decay & defensive rotation near highs while IV is cheap",
            "subtitle_zh": "捕捉指数高位横盘期内部宽度恶化与防御板块暗中抢跑（低波潜伏买盾）",
            "score": round(p1, 0),
            "cap": 45,
            "modules": [
                {
                    "id": "M0",
                    "name_en": "M0 Six Lights Baseline",
                    "name_zh": "M0 六灯基线开关",
                    "points": 35,
                    "earned_points": 35 if m0_trig else 0,
                    "triggered": m0_trig,
                    "raw_triggered": bool(sig_day["M0"]),
                    "sensor_triggered": m0_sensor,
                    "readiness_met": m0_met,
                    "readiness_total": 3,
                    "status_code": m0_status,
                    "next_trigger_hint_en": m0_hint_en,
                    "next_trigger_hint_zh": m0_hint_zh,
                    "pluggable": True,
                    "enabled": m0_enabled,
                    "disabled_in_core3": False,
                    "vol_gate_passed": m0_vg_ok,
                    "vol_gate_en": f"VXN {vxn:.2f} <= 22.0",
                    "vol_gate_zh": f"VXN {vxn:.2f} <= 22.0 低波门控",
                    "metrics": [
                        {
                            "label_en": "QQQ vs ATH",
                            "label_zh": "QQQ 距历史前高",
                            "value": f"{dd_pct:+.2f}% (${cl:.2f})",
                            "threshold": ">= -5.00% (0.95*ATH)",
                            "passed": m0_ath_ok,
                        },
                        {
                            "label_en": "A-D Line < SMA50",
                            "label_zh": "腾落线 AD < 50DMA",
                            "value": f"{ad_line - ad_sma50:+,.0f}",
                            "threshold": "< 0",
                            "passed": m0_ad_ok,
                        },
                        {
                            "label_en": "Macro Crisis Lights",
                            "label_zh": "宏观六灯亮灯数",
                            "value": f"{sc} / 6",
                            "threshold": ">= 4 / 6",
                            "passed": m0_sc_ok,
                        },
                    ],
                },
                {
                    "id": "M6",
                    "name_en": "M6 Breadth + Defensive Rotation",
                    "name_zh": "M6 宽度恶化 + 防御轮动",
                    "points": 20,
                    "earned_points": 20 if m6_trig else 0,
                    "triggered": m6_trig,
                    "raw_triggered": bool(sig_day["M6"]),
                    "sensor_triggered": m6_sensor,
                    "readiness_met": m6_met,
                    "readiness_total": 3,
                    "status_code": m6_status,
                    "next_trigger_hint_en": m6_hint_en,
                    "next_trigger_hint_zh": m6_hint_zh,
                    "pluggable": False,
                    "enabled": True,
                    "disabled_in_core3": False,
                    "vol_gate_passed": m6_vg_ok,
                    "vol_gate_en": f"VXN {vxn:.1f}<=25 & VIX/3M {vr:.3f}<=0.92",
                    "vol_gate_zh": f"VXN {vxn:.1f}<=25 且 VIX/3M {vr:.3f}<=0.92",
                    "metrics": [
                        {
                            "label_en": "RSP/SPY vs SMA50",
                            "label_zh": "等权 RSP/SPY vs 50DMA",
                            "value": f"{rsp_spy_v:.4f} vs {rsp_sma_v:.4f}",
                            "threshold": "< SMA50",
                            "passed": m6_rsp_ok,
                        },
                        {
                            "label_en": "IWM/QQQ (<SMA50 or AD)",
                            "label_zh": "小盘 IWM/QQQ (<50DMA 或 AD弱)",
                            "value": f"{iwm_qqq_v:.4f} vs {iwm_sma_v:.4f}",
                            "threshold": "< SMA50" + (" or AD<50D" if m0_enabled else ""),
                            "passed": m6_iwm_ok,
                        },
                        {
                            "label_en": "(XLP+XLU+XLV)/XLK 20D",
                            "label_zh": "防御/科技 20日超额轮动",
                            "value": f"{def_ret20_pct:+.2f}%",
                            "threshold": ">= +2.50%",
                            "passed": m6_def_ok,
                        },
                    ],
                },
            ],
        },
        {
            "id": "P2",
            "title_en": "Pillar 2 · Exogenous Shock Ignition",
            "title_zh": "第二支柱 P2 · 外生黑天鹅启爆",
            "subtitle_en": (
                "Off in Core-3 Minimal (omits exogenous shock sensors M2 & M5 for low-frequency purity)"
                if is_core3
                else "Requires dual-sensor consensus (M2 + M5 = 40% >= 35%) to catch sudden shocks like 2020-01-28"
            ),
            "subtitle_zh": (
                "精简 3 核模式下已关闭（剔除外生预警 M2 & M5，专注低频高赔率主趋势崩盘）"
                if is_core3
                else "要求期权台偏度与因果 HMM 双传感器共振（20+20=40% >= 35%），精准捕获 2020-01-28 等突发黑天鹅"
            ),
            "score": round(p2, 0),
            "cap": 0 if is_core3 else 40,
            "disabled_in_core3": is_core3,
            "modules": [
                {
                    "id": "M2",
                    "name_en": "M2 Options Desk Warning",
                    "name_zh": "M2 期权台尾部预警",
                    "points": 20,
                    "earned_points": 20 if m2_trig else 0,
                    "triggered": m2_trig,
                    "raw_triggered": bool(sig_day["M2"]),
                    "sensor_triggered": m2_sensor,
                    "readiness_met": m2_met,
                    "readiness_total": 2,
                    "status_code": m2_status,
                    "next_trigger_hint_en": m2_hint_en,
                    "next_trigger_hint_zh": m2_hint_zh,
                    "pluggable": False,
                    "enabled": not is_core3,
                    "disabled_in_core3": is_core3,
                    "vol_gate_passed": m2_vg_ok,
                    "vol_gate_en": f"VXN {vxn:.1f}<=24 & VIX/3M {vr:.3f}<=1.02",
                    "vol_gate_zh": f"VXN {vxn:.1f}<=24 且 VIX/3M {vr:.3f}<=1.02",
                    "metrics": [
                        {
                            "label_en": "A) Silent Tail (SKEW10 & VVIX)",
                            "label_zh": "A) 静默买尾 (SKEW10 & VVIX>=P75)",
                            "value": f"SKEW {skew10_v:.1f}/{skew_p75_v:.1f} · VVIX {vvix_v:.1f}/{vvix_p75_v:.1f}",
                            "threshold": ">=252D P75 & 0.85<=V/V3M<=0.98",
                            "passed": bool(sig_day["M2_silent_tail"]) or m2_core_a,
                        },
                        {
                            "label_en": "B) Term Inflection (5D Jump)",
                            "label_zh": "B) 期限拐点 (5日跃升 & VVIX>=100)",
                            "value": f"Δ5D {vr_j5_v:+.3f} · VVIX {vvix_v:.1f}",
                            "threshold": "0.92..1.02 & Δ>=+0.06 & VVIX>=100",
                            "passed": bool(sig_day["M2_term_inflection"]) or m2_core_b,
                        },
                    ],
                },
                {
                    "id": "M5",
                    "name_en": "M5 Causal HMM Regime Transition",
                    "name_zh": "M5 因果 HMM 状态跃迁",
                    "points": 20,
                    "earned_points": 20 if m5_trig else 0,
                    "triggered": m5_trig,
                    "raw_triggered": bool(sig_day["M5"]),
                    "sensor_triggered": m5_sensor,
                    "readiness_met": m5_met,
                    "readiness_total": 2,
                    "status_code": m5_status,
                    "next_trigger_hint_en": m5_hint_en,
                    "next_trigger_hint_zh": m5_hint_zh,
                    "pluggable": False,
                    "enabled": not is_core3,
                    "disabled_in_core3": is_core3,
                    "vol_gate_passed": m5_vg_ok,
                    "vol_gate_en": f"VXN {vxn:.1f}<=24 & VIX/3M {vr:.3f}<1.02",
                    "vol_gate_zh": f"VXN {vxn:.1f}<=24 且 VIX/3M {vr:.3f}<1.02",
                    "metrics": [
                        {
                            "label_en": "Hamilton P_t(Stress)",
                            "label_zh": "当前高压态后验概率 P_t",
                            "value": f"{hmm_p_v * 100.0:.1f}%",
                            "threshold": ">= 55.0%",
                            "passed": m5_cur_ok,
                        },
                        {
                            "label_en": "5D Prior P_{t-5}(Stress)",
                            "label_zh": "5日前后验概率 P_{t-5}（新鲜跃迁）",
                            "value": f"{hmm_p5_v * 100.0:.1f}%",
                            "threshold": "< 40.0%",
                            "passed": m5_fresh_ok,
                        },
                    ],
                },
            ],
        },
        {
            "id": "P3",
            "title_en": "Pillar 3 · Bear Continuation & Credit Crunch",
            "title_zh": "第三支柱 P3 · 熊市延续与信用紧缩",
            "subtitle_en": "Buys cheap puts on bear-market dead-cat rallies (>EMA20 while <SMA200 & EWMAC<0) + lagged FRED credit stress",
            "subtitle_zh": "专抓 2022 式慢熊死猫跳自满期（跌破年线且 EWMAC<0 但反弹上穿 EMA20 压低波动率）叠加滞后信用压力",
            "score": round(p3, 0),
            "cap": 35 if is_core3 else 45,
            "modules": [
                {
                    "id": "M4",
                    "name_en": "M4 CTA Bear-Rally Complacency",
                    "name_zh": "M4 CTA 熊市反弹自满",
                    "points": 35,
                    "earned_points": 35 if m4_trig else 0,
                    "triggered": m4_trig,
                    "raw_triggered": bool(sig_day["M4"]),
                    "sensor_triggered": m4_sensor,
                    "readiness_met": m4_met,
                    "readiness_total": 3,
                    "status_code": m4_status,
                    "next_trigger_hint_en": m4_hint_en,
                    "next_trigger_hint_zh": m4_hint_zh,
                    "pluggable": False,
                    "enabled": True,
                    "disabled_in_core3": False,
                    "vol_gate_passed": m4_vg_ok,
                    "vol_gate_en": f"VXN {vxn:.1f}<=27 & VIX/3M {vr:.3f}<=0.88",
                    "vol_gate_zh": f"VXN {vxn:.1f}<=27 且 VIX/3M {vr:.3f}<=0.88",
                    "metrics": [
                        {
                            "label_en": "QQQ < SMA200",
                            "label_zh": "熊市主趋势 QQQ < 200DMA",
                            "value": f"${cl:.2f} vs ${sma200_v:.2f}",
                            "threshold": "< SMA200",
                            "passed": m4_below200,
                        },
                        {
                            "label_en": "3-Speed EWMAC (16/32/64)",
                            "label_zh": "三速 EWMAC 趋势均值",
                            "value": f"{ewmac_v:+.2f}",
                            "threshold": "< 0.00",
                            "passed": m4_ewmac,
                        },
                        {
                            "label_en": "Bear Bounce QQQ > EMA20",
                            "label_zh": "死猫跳反弹 QQQ > EMA20",
                            "value": f"${cl:.2f} vs ${ema20_v:.2f}",
                            "threshold": "> EMA20",
                            "passed": m4_ema20,
                        },
                    ],
                },
                {
                    "id": "M3",
                    "name_en": "M3 Credit & Macro Stress (FRED PIT)",
                    "name_zh": "M3 信用利差与宏观压力 (FRED 严格滞后)",
                    "points": 20,
                    "earned_points": 20 if m3_trig else 0,
                    "triggered": m3_trig,
                    "raw_triggered": bool(sig_day["M3"]),
                    "sensor_triggered": m3_sensor,
                    "readiness_met": m3_met,
                    "readiness_total": 3,
                    "status_code": m3_status,
                    "next_trigger_hint_en": m3_hint_en,
                    "next_trigger_hint_zh": m3_hint_zh,
                    "pluggable": False,
                    "enabled": not is_core3,
                    "disabled_in_core3": is_core3,
                    "vol_gate_passed": m3_vg_ok,
                    "vol_gate_en": f"VXN {vxn:.1f}<=26 & VIX/3M {vr:.3f}<=0.92",
                    "vol_gate_zh": f"VXN {vxn:.1f}<=26 且 VIX/3M {vr:.3f}<=0.92",
                    "metrics": [
                        {
                            "label_en": "HYG/LQD < SMA50",
                            "label_zh": "高收益/投资级 HYG/LQD < 50DMA",
                            "value": f"{hyg_v:.4f} vs {hyg_sma_v:.4f}",
                            "threshold": "< SMA50",
                            "passed": m3_hyg,
                        },
                        {
                            "label_en": "BAA10Y (+1d lag) 63D Widening",
                            "label_zh": "Baa利差 (+1日滞后) 63D走阔",
                            "value": f"{baa_v:.2f}% ({(baa_r_v * 100.0 if baa_r_opt is not None else 0.0):+.0f}bp)",
                            "threshold": ">= +15bp (+0.15)",
                            "passed": m3_baa,
                        },
                        {
                            "label_en": "DGS2 (+1d) 63D / NFCI (+5d) 20D",
                            "label_zh": "2Y美债(+1日)63D / NFCI(+5日)20D",
                            "value": f"2Y {(dgs2_j_v * 100.0 if dgs2_j_opt is not None else 0.0):+.0f}bp · NFCI {(nfci_j_v if nfci_j_opt is not None else 0.0):+.2f}",
                            "threshold": "2Y>=+40bp OR NFCI>=+0.10",
                            "passed": m3_macro,
                        },
                    ],
                },
            ],
        },
    ]

    all_mods_flat = [m for p in pillars for m in p["modules"]]
    sensor_red_count = sum(1 for m in all_mods_flat if bool(m["enabled"]) and bool(m["sensor_triggered"]))
    vol_blocked_sensor_count = sum(1 for m in all_mods_flat if m["status_code"] == "SENSOR_RED_VOL_BLOCKED")
    warming_count = sum(1 for m in all_mods_flat if m["status_code"] == "WARMING_UP")

    data_freshness = {
        "yahoo_eod_date": d,
        "fred_baa_date": str(feat_row_dict.get("baa_obs_date") or ""),
        "fred_baa_lag_days": 1,
        "fred_dgs2_date": str(feat_row_dict.get("dgs2_obs_date") or ""),
        "fred_dgs2_lag_days": 1,
        "fred_nfci_date": str(feat_row_dict.get("nfci_obs_date") or ""),
        "fred_nfci_lag_days": 5,
        "ad_line_date": str(row.get("ad_line_date") or d),
        "is_pit_replay": bool(row.get("_is_pit_replay", False)),
    }

    return {
        "as_of_date": d,
        "strategy_id": strategy_id,
        "profile": "core3_adaptive" if is_core3 else "full_m7_adaptive",
        "put_otm": put_otm,
        "m7_tp_mode": m7_tp_mode,
        "roll_mode": roll_mode,
        "m0_enabled": m0_enabled,
        "crisis_prob": round(prob, 0),
        "p1_score": round(p1, 0),
        "p2_score": round(p2, 0),
        "p3_score": round(p3, 0),
        "live_stress_index": stress_idx,
        "live_stress_level": str(stress_pack["live_stress_level"]),
        "live_stress_label_en": stress_lbl_en,
        "live_stress_label_zh": stress_lbl_zh,
        "live_stress_breakdown": dict(stress_pack["live_stress_breakdown"]),
        "sensor_red_count": sensor_red_count,
        "vol_blocked_sensor_count": vol_blocked_sensor_count,
        "warming_count": warming_count,
        "data_freshness": data_freshness,
        "target_slots": target_slots,
        "active_slots": active_slots,
        "max_slots": max_slots,
        "triggered_modules": mods_active,
        "trigger_code": trig_code if mods_active else "NONE",
        "tier_rule_en": (
            "Core-3 Minimal: M0=35% (1 Slot) · M0+M6=45% (2 Slots) · M4=35% (1 Slot) · M0+M4=70% (3 Slots); M6 alone=20% (0 Slots)"
            if is_core3
            else "<35%: 0 Slots · 35-44%: 1 Slot · 45-64%: 2 Slots · >=65%: 3 Slots"
        ),
        "tier_rule_zh": (
            "精简3核权重：M0=35%（1槽）· M0+M6=45%（2槽）· M4=35%（1槽）· M0+M4=70%（3槽）；M6单亮=20%不单发"
            if is_core3
            else "<35%：0槽 · 35–44%：1槽 · 45–64%：2槽 · >=65%：3槽满配"
        ),
        "redline": {
            "blocked": redline_blocked,
            "vxn": round(vxn, 2),
            "vxn_max": 27.0,
            "vxn_ok": vxn_red_ok,
            "vix_ratio": round(vr, 3),
            "vix_ratio_max": 1.02,
            "vix_ratio_ok": vr_red_ok,
            "label_en": (
                f"REDLINE BLOCKED (VXN {vxn:.1f} > 27 or VIX/3M {vr:.3f} >= 1.02)"
                if redline_blocked
                else f"REDLINE CLEAR (VXN {vxn:.1f} <= 27 & VIX/3M {vr:.3f} < 1.02)"
            ),
            "label_zh": (
                f"红线禁开生效（VXN {vxn:.1f} > 27 或 VIX/3M {vr:.3f} >= 1.02）"
                if redline_blocked
                else f"风控红线安全（VXN {vxn:.1f} <= 27 且 VIX/3M {vr:.3f} < 1.02）"
            ),
        },
        "cooldown": {
            "required_days": req_gap,
            "days_since_last_entry": days_since_last,
            "last_entry_date": last_entry_dt_str,
            "passed": cooldown_passed,
            "label_en": (
                f"No open slots ({req_gap}D cooldown ready)"
                if days_since_last is None
                else f"{days_since_last}D since {last_entry_dt_str} (Req >= {req_gap}D: {'READY' if cooldown_passed else 'WAIT'})"
            ),
            "label_zh": (
                f"当前无在途槽位（{req_gap}天阶梯冷却已就绪）"
                if days_since_last is None
                else f"距上槽 {last_entry_dt_str} 已过 {days_since_last} 天（要求 >= {req_gap} 天：{'已就绪' if cooldown_passed else '冷却中'}）"
            ),
        },
        "t1_action": {
            "code": t1_code,
            "tone": t1_tone,
            "badge_en": t1_badge_en,
            "badge_zh": t1_badge_zh,
            "title_en": t1_title_en,
            "title_zh": t1_title_zh,
        },
        "sizing_calculator": sizing_calc,
        "tp_monitor": tp_monitor,
        "pillars": pillars,
    }
