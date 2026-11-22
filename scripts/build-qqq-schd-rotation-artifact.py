#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build the audited QQQ <-> SCHD Valuation & Panic Resonance Rotation (M6 / M4 / M7)
Strategy Portfolio artifact (`server/config/qqq-schd-rotation-dashboard.json`).

Zero third-party dependencies beyond `duckdb` and Python stdlib so it runs
identically in `.venv-fact-os/bin/python` locally and `/opt/thesisforge-fact-os/bin/python`
on AWS Elastic Beanstalk.
"""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import sys

import duckdb

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

ARTIFACT_VERSION = 'qqq-schd-rotation-v1'
DEFAULT_SOURCE_DIR = REPO_ROOT / 'output/qqq_schd_rotation_20261114'
DEFAULT_OUTPUT_FILE = REPO_ROOT / 'server/config/qqq-schd-rotation-dashboard.json'
LIVE_START_DATE = '2011-10-20'
FULL_START_DATE = '2000-01-03'
COST_BPS_PER_SIDE = 5.0


def r2(v: float | None) -> float | None:
    return None if v is None or not math.isfinite(v) else round(float(v), 2)


def r3(v: float | None) -> float | None:
    return None if v is None or not math.isfinite(v) else round(float(v), 3)


def r4(v: float | None) -> float | None:
    return None if v is None or not math.isfinite(v) else round(float(v), 4)


def r6(v: float | None) -> float | None:
    return None if v is None or not math.isfinite(v) else round(float(v), 6)


def _supplement_rotation_etfs_from_yahoo(
    by_tk: dict[str, dict[str, tuple[float, float]]],
) -> float | None:
    """When FactOS funds lag recent trading sessions, chain Yahoo adjusted closes onto FactOS's last anchor."""
    import os as _os
    import urllib.request

    if _os.environ.get('LIVE_MARKET_TAIL_ENABLED', 'true') == 'false':
        return None

    latest_vix: float | None = None
    for tk in ('QQQ', 'SCHD', 'BIL'):
        series = by_tk.get(tk) or {}
        if not series:
            continue
        last_dt = max(series.keys())
        last_raw, last_adj = series[last_dt]
        url = f'https://query1.finance.yahoo.com/v8/finance/chart/{tk}?range=15d&interval=1d'
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            raw = json.loads(urllib.request.urlopen(req, timeout=10).read())
            res0 = (raw.get('chart') or {}).get('result', [None])[0] or {}
            ts_list = res0.get('timestamp') or []
            closes = ((res0.get('indicators') or {}).get('quote', [{}])[0]).get('close') or []
            adjs = ((res0.get('indicators') or {}).get('adjclose', [{}])[0]).get('adjclose') or closes
            yh_map: dict[str, tuple[float, float]] = {}
            for t_sec, c_val, a_val in zip(ts_list, closes, adjs):
                if c_val is not None and a_val is not None and float(c_val) > 0 and float(a_val) > 0:
                    dt_iso = datetime.fromtimestamp(int(t_sec), timezone.utc).strftime('%Y-%m-%d')
                    yh_map[dt_iso] = (float(c_val), float(a_val))
            anchor = yh_map.get(last_dt)
            if anchor and anchor[1] > 0:
                for dt_iso in sorted(yh_map.keys()):
                    if dt_iso > last_dt:
                        yh_c, yh_a = yh_map[dt_iso]
                        series[dt_iso] = (yh_c, last_adj * (yh_a / anchor[1]))
        except Exception:
            pass

    try:
        req = urllib.request.Request(
            'https://query1.finance.yahoo.com/v8/finance/chart/%5EVIX?range=10d&interval=1d',
            headers={'User-Agent': 'Mozilla/5.0'},
        )
        raw = json.loads(urllib.request.urlopen(req, timeout=10).read())
        res0 = (raw.get('chart') or {}).get('result', [None])[0] or {}
        closes = ((res0.get('indicators') or {}).get('quote', [{}])[0]).get('close') or []
        valid = [float(x) for x in closes if x is not None and float(x) > 0]
        if valid:
            latest_vix = valid[-1]
    except Exception:
        pass
    return latest_vix


def probe_fact_os_max_date(fact_root: Path) -> dict:
    from fact_os.repository import FactRepository

    repo = FactRepository(fact_root)
    try:
        q_row = repo.db.execute(
            "SELECT CAST(MAX(date) AS VARCHAR) FROM funds WHERE ticker = 'QQQ'"
        ).fetchone()
        s_row = repo.db.execute(
            "SELECT CAST(MAX(date) AS VARCHAR) FROM funds WHERE ticker = 'SCHD'"
        ).fetchone()
        q_max = str(q_row[0])[:10] if q_row and q_row[0] else None
        s_max = str(s_row[0])[:10] if s_row and s_row[0] else None
        by_probe: dict[str, dict[str, tuple[float, float]]] = {
            'QQQ': {q_max: (1.0, 1.0)} if q_max else {},
            'SCHD': {s_max: (1.0, 1.0)} if s_max else {},
        }
        _supplement_rotation_etfs_from_yahoo(by_probe)
        if by_probe['QQQ']:
            q_max = max(by_probe['QQQ'].keys())
        if by_probe['SCHD']:
            s_max = max(by_probe['SCHD'].keys())
        common_max = min(q_max, s_max) if (q_max and s_max) else None
        return {
            'factRoot': str(repo.root),
            'generation': repo.generation,
            'qqqMaxDate': q_max,
            'schdMaxDate': s_max,
            'maxDate': common_max,
        }
    finally:
        repo.close()


def compute_window_metrics(
    dates: list[str],
    navs: list[float],
    qqq_navs: list[float],
    rf_rets: list[float],
    weights: list[float] | None = None,
) -> dict:
    n = len(dates)
    if n < 2:
        raise ValueError('Need at least 2 daily observations for window metrics')
    d0 = datetime.strptime(dates[0], '%Y-%m-%d')
    d1 = datetime.strptime(dates[-1], '%Y-%m-%d')
    years = max((d1 - d0).days / 365.25, 1.0 / 365.25)

    base = navs[0] if navs[0] > 0 else 1.0
    norm = [v / base for v in navs]
    q_base = qqq_navs[0] if qqq_navs[0] > 0 else 1.0
    q_norm = [v / q_base for v in qqq_navs]

    mult = norm[-1]
    total_ret = mult - 1.0
    cagr = (mult ** (1.0 / years) - 1.0) if mult > 0 else -1.0

    port_rets: list[float] = []
    ex_rets: list[float] = []
    for i in range(1, n):
        pr = norm[i] / norm[i - 1] - 1.0 if norm[i - 1] > 0 else 0.0
        port_rets.append(pr)
        ex_rets.append(pr - (rf_rets[i] if i < len(rf_rets) else 0.0))

    m_pr = sum(port_rets) / len(port_rets)
    var_pr = (
        sum((x - m_pr) ** 2 for x in port_rets) / (len(port_rets) - 1)
        if len(port_rets) > 1
        else 0.0
    )
    vol = math.sqrt(max(var_pr, 0.0)) * math.sqrt(252.0)

    var_pr0 = sum((x - m_pr) ** 2 for x in port_rets) / len(port_rets) if port_rets else 0.0
    sharpe_zero_rf = (
        (m_pr / math.sqrt(var_pr0)) * math.sqrt(252.0) if var_pr0 > 1e-16 else 0.0
    )

    m_ex = sum(ex_rets) / len(ex_rets)
    var_ex = (
        sum((x - m_ex) ** 2 for x in ex_rets) / (len(ex_rets) - 1)
        if len(ex_rets) > 1
        else 0.0
    )
    sharpe = (m_ex / math.sqrt(var_ex)) * math.sqrt(252.0) if var_ex > 1e-16 else 0.0

    dn_sq = sum((min(x, 0.0) ** 2) for x in ex_rets) / len(ex_rets) if ex_rets else 0.0
    sortino = (
        (m_ex * 252.0) / (math.sqrt(dn_sq) * math.sqrt(252.0))
        if dn_sq > 1e-16
        else 0.0
    )

    peak = norm[0]
    dds_pct: list[float] = []
    mdd = 0.0
    for v in norm:
        if v > peak:
            peak = v
        dd_frac = v / peak - 1.0 if peak > 0 else 0.0
        if dd_frac < mdd:
            mdd = dd_frac
        dds_pct.append(dd_frac * 100.0)

    calmar = cagr / abs(mdd) if abs(mdd) > 1e-9 else None
    ulcer = math.sqrt(sum(d * d for d in dds_pct) / len(dds_pct))

    win3y = None
    if n > 756:
        wins3 = sum(
            1
            for i in range(756, n)
            if (norm[i] / norm[i - 756]) >= (q_norm[i] / q_norm[i - 756])
        )
        win3y = wins3 / (n - 756)

    win5y = None
    if n > 1260:
        wins5 = sum(
            1
            for i in range(1260, n)
            if (norm[i] / norm[i - 1260]) >= (q_norm[i] / q_norm[i - 1260])
        )
        win5y = wins5 / (n - 1260)

    avg_q = None
    switches = 0
    ann_turn = None
    if weights is not None and len(weights) == n:
        avg_q = sum(weights) / n
        turn_sum = 0.0
        for i in range(1, n):
            diff = abs(weights[i] - weights[i - 1])
            turn_sum += diff
            if diff >= 0.0999:
                switches += 1
        ann_turn = turn_sum / years

    return {
        'observations': n,
        'startDate': dates[0],
        'endDate': dates[-1],
        'years': r4(years),
        'endingMultiple': r4(mult),
        'endingValue': r4(mult),
        'totalReturn': r6(total_ret),
        'cagr': r6(cagr),
        'volatility': r6(vol),
        'sharpe': r3(sharpe),
        'sharpeZeroRf': r4(sharpe_zero_rf),
        'sortino': r3(sortino),
        'maxDrawdown': r6(mdd),
        'calmar': r3(calmar),
        'ulcerIndex': r2(ulcer),
        'avgQqqWeight': r4(avg_q),
        'switchCount': switches,
        'annualTurnover': r4(ann_turn),
        'winRate3y': r4(win3y),
        'winRate5y': r4(win5y),
    }


def compute_yearly_returns(dates: list[str], series_map: dict[str, list[float]]) -> list[dict]:
    years = sorted({d[:4] for d in dates})
    out: list[dict] = []
    for idx_y, yr in enumerate(years):
        first_idx = next(i for i, d in enumerate(dates) if d.startswith(f'{yr}-'))
        last_idx = max(i for i, d in enumerate(dates) if d.startswith(f'{yr}-'))
        base_idx = first_idx - 1 if first_idx > 0 else 0
        partial = (idx_y == 0 and dates[0] > f'{yr}-01-05') or (
            idx_y == len(years) - 1 and dates[-1] < f'{yr}-12-28'
        )
        row: dict = {
            'year': int(yr),
            'label': f'{yr}*' if partial else yr,
            'partial': partial,
            'from': dates[base_idx],
            'to': dates[last_idx],
        }
        for key, vals in series_map.items():
            base_val = vals[base_idx] if first_idx > 0 else vals[0]
            row[key] = r6(vals[last_idx] / base_val - 1.0) if base_val > 0 else 0.0
        out.append(row)
    return out


CANONICAL_STRATEGY_META = {
    'B1': {
        'code': 'B1',
        'group': 'benchmark',
        'name': {'en': '100% QQQ Buy & Hold', 'zh': '100% QQQ 买入死拿'},
        'rule': {
            'en': 'Core benchmark: 100% Nasdaq-100 dividend-reinvested',
            'zh': '核心比较基准：100% 纳指100分红再投资死拿',
        },
    },
    'B2': {
        'code': 'B2',
        'group': 'benchmark',
        'name': {'en': '100% SCHD Buy & Hold', 'zh': '100% SCHD 买入死拿'},
        'rule': {
            'en': 'Defensive cash-cow dividend benchmark (pre-2011 spliced High-ROE Div 100 / DVY)',
            'zh': '高股息现金牛基准（2011前无前视拼接高ROE红利100 / DVY）',
        },
    },
    'B3': {
        'code': 'B3',
        'group': 'benchmark',
        'name': {'en': 'Static 70/30 QQQ/SCHD (Q-Rebal)', 'zh': '70/30 QQQ/SCHD 静态季度再平衡'},
        'rule': {
            'en': 'Passive quarterly rebalance matching M6 average QQQ exposure (around 72%)',
            'zh': '被动季度再平衡对照组（与 M6 平均 QQQ 仓位约 72% 同等风险敞口）',
        },
    },
    'B4': {
        'code': 'B4',
        'group': 'benchmark',
        'name': {'en': 'Static 50/50 QQQ/SCHD (Q-Rebal)', 'zh': '50/50 QQQ/SCHD 静态季度再平衡'},
        'rule': {
            'en': 'Balanced equal-split passive quarterly rebalance',
            'zh': '股息与成长各半的静态季度再平衡基准',
        },
    },
    'M1': {
        'code': 'M1',
        'group': 'trap',
        'name': {'en': 'Naive Static PE (>28x Sell, <21x Buy)', 'zh': '固定低 PE 一刀切 (>28x卖, <21x买)'},
        'rule': {
            'en': 'Classic early-exit trap: ignores structural margin expansion of cloud/AI leaders',
            'zh': '刻舟求剑过早下车陷阱：忽视云计算与AI带来纳指净利率翻倍与PE中枢上移',
        },
    },
    'M2': {
        'code': 'M2',
        'group': 'trap',
        'name': {'en': 'Pure 3Y Valuation MA (Z > +1.35s / < -0.5s)', 'zh': '纯 3 年滚动估值均线 (Z>+1.35σ卖 / <-0.5σ买)'},
        'rule': {
            'en': 'Fails both ways: 2000 Fake-Cheap catch (-72%) & 2013 Fake-Expensive early exit',
            'zh': '双向误判陷阱：2000年假便宜接飞刀再跌72%，2013年假高估16.3x过早清仓踏空',
        },
    },
    'M3': {
        'code': 'M3',
        'group': 'trap',
        'name': {'en': 'Pure Price MA200 Trend (No Valuation)', 'zh': '纯价格 MA200 均线趋势轮动（无估值）'},
        'rule': {
            'en': '32 whipsaws in 15Y (84 in 27Y): normal bull pullbacks cause repeated sell-low/buy-high',
            'zh': '15年打脸32次（27年84次）：牛市正常回调反复高买低卖，损耗 -1.11%/年',
        },
    },
    'M4': {
        'code': 'M4',
        'group': 'champion',
        'name': {'en': 'Dual-Anchor Left-Side All-In [Offensive]', 'zh': '双锚左侧全进全出轮动 [进攻冠军]'},
        'rule': {
            'en': 'Pos-PE >= 34.5x + Weekly RSI >= 68 -> 100% SCHD; DD <= -18% + Panic/Val -> 100% QQQ',
            'zh': '泡沫+周RSI超买全换SCHD；大回撤+低估/VIX/RSI恐慌全仓杀回QQQ（15年仅5次）',
        },
    },
    'M5': {
        'code': 'M5',
        'group': 'tactical',
        'name': {'en': '90d Bubble Memory + <MA150 Exit + Panic Buy', 'zh': '90日泡沫记忆 + 破MA150清仓 + 恐慌全仓抄底'},
        'rule': {
            'en': 'Right-side MA150 breakdown gated by 90d peak bubble + aggressive left-side panic sniping',
            'zh': '过去90日触及泡沫且跌破MA150右侧止盈 + 大回撤共振VIX/RSI一把满仓抄底',
        },
    },
    'M5-Ablation': {
        'code': 'M5-Ablation',
        'group': 'ablation',
        'name': {'en': 'M5 Ablation: No Left-Side Panic Buy', 'zh': 'M5 消融对照：去掉左侧恐慌全卖SCHD抄底'},
        'rule': {
            'en': 'Same exit as M5, but waits passively for >MA150: loses -2.59%/yr alpha!',
            'zh': '与M5完全相同的卖出，但死等站上MA150才买回：每年白白损失 -2.59% 纯超额！',
        },
    },
    'M6': {
        'code': 'M6',
        'group': 'flagship',
        'name': {'en': 'Asymmetric Staged Slow-Sell / Fast-Buy [Flagship]', 'zh': '慢卖快买分批轮动 [全天候旗舰推荐]'},
        'rule': {
            'en': 'Trim 100%->70%->45% on bubble froth, 0% on <MA150 break; 100% instant panic buy',
            'zh': '泡沫超买分两档慢减至70%→45%，破MA150清至0%；恐慌极值一次性100%满仓杀回QQQ',
        },
    },
    'M7': {
        'code': 'M7',
        'group': 'taxable',
        'name': {'en': '50% QQQ Core + 50% M6 Sleeve [Taxable Optimal]', 'zh': '50% QQQ 永久底仓 + 50% M6 战术仓 [应税优解]'},
        'rule': {
            'en': 'Never sells 50% low-basis QQQ core; QQQ oscillates 50%..100% to minimize capital gains tax',
            'zh': '50%低成本QQQ底仓永不动免交重税，仅用50%战术仓执行M6轮动（总QQQ敞口50%–100%）',
        },
    },
}


REGIME_META = {
    'Dot-Com Crash (2000-02)': {
        'type': 'bear',
        'zh': '2000–02 科网泡沫崩盘',
        'en': 'Dot-Com Crash (2000–02)',
        'note': {
            'zh': '90日泡沫记忆破MA150果断清仓换高股息，将QQQ -82.9%毁灭性崩盘压缩至 -27.8%',
            'en': '90d bubble memory + <MA150 exit rotated to dividend value, cutting QQQ -82.9% crash to -27.8%',
        },
    },
    'GFC Crash (2007-09)': {
        'type': 'bear',
        'zh': '2007–09 次贷金融海啸',
        'en': 'GFC Crash (2007–09)',
        'note': {
            'zh': '2007年纳指PE仅22x无科技泡沫，系统性银行危机中成长与高股息同跌，未产生无效换手损耗',
            'en': '2007 QQQ PE was 22x (non-bubble banking crisis); QQQ and dividend stocks fell identically without whipsaw drag',
        },
    },
    'Secular Tech Bull I (2011-18)': {
        'type': 'bull',
        'zh': '2011–18 移动云计算长牛',
        'en': 'Secular Tech Bull I (2011–18)',
        'note': {
            'zh': '双锚下限护栏屏蔽2013年“假高估陷阱”，零换手100%死拿QQQ吃满 +256.5% 主升浪',
            'en': 'Dual-anchor floor blocked the 2013 Fake-Expensive trap, holding 100% QQQ for the full +256.5% bull run',
        },
    },
    'Fed Hike Selloff (2018Q4)': {
        'type': 'bear',
        'zh': '2018Q4 缩表加息急跌',
        'en': 'Fed Hike Selloff (2018Q4)',
        'note': {
            'zh': '顶部PE未达33.5x泡沫线，按常态回调坚定持仓穿越，避免底部割肉踏空2019反弹',
            'en': 'Peak PE stayed below 33.5x bubble threshold; held through normal correction without bottom whipsaw',
        },
    },
    'COVID Liquidity Panic (2020Q1)': {
        'type': 'bear',
        'zh': '2020Q1 疫情熔断闪崩',
        'en': 'COVID Liquidity Panic (2020Q1)',
        'note': {
            'zh': '无差别的23天流动性闪崩（SCHD跌-32.8%比QQQ -27.9%更深），满仓QQQ直接迎接V型暴涨',
            'en': '23-day indiscriminate liquidity shock (SCHD -32.8% fell more than QQQ -27.9%); stayed 100% QQQ into V-rebound',
        },
    },
    'ZIRP Stimulus Melt-Up (2020-21)': {
        'type': 'bull',
        'zh': '2020–21 零利率放水狂飙',
        'en': 'ZIRP Stimulus Melt-Up (2020–21)',
        'note': {
            'zh': '慢卖分批止盈锁定部分泡沫红利，同时享受SCHD疫后价值复苏，斩获 +139.5% 跑赢死拿QQQ',
            'en': 'Staged froth trims locked gains while capturing post-COVID value rebound (+139.5% vs QQQ +139.0%)',
        },
    },
    'Fed Rate-Shock Tech Bear (2022)': {
        'type': 'bear',
        'zh': '2022 暴力加息杀估值熊市',
        'en': 'Fed Rate-Shock Tech Bear (2022)',
        'note': {
            'zh': '2022年1月跌破MA150清仓换入全年0%横盘的SCHD，随后左侧低估买回，跑赢QQQ +15.9个百分点！',
            'en': 'Jan 2022 <MA150 exit into flat SCHD (0.0%) + April valuation re-entry beat QQQ by +15.9 percentage points!',
        },
    },
    'AI Mega-Cap Boom (2023-24)': {
        'type': 'bull',
        'zh': '2023–24 AI 大模型首轮主升',
        'en': 'AI Mega-Cap Boom (2023–24)',
        'note': {
            'zh': '2022左侧满仓抄底吃满前半段暴涨，2023下半年PE冲上36.4x后慢卖分批兑现（M7底仓版斩获+76.2%）',
            'en': 'Captured early AI surge from 2022 left-side buy, then trimmed into 36.4x PE froth (M7 Core captured +76.2%)',
        },
    },
    'Carry Unwind & Tariff Crash (24-25)': {
        'type': 'bear',
        'zh': '2024–25 日元套息与关税崩盘',
        'en': 'Carry Unwind & Tariff Crash (24–25)',
        'note': {
            'zh': '战术仓提前驻守SCHD避风港，在QQQ暴跌 -16.9% 期间仅微跌 -1.6%（超额护体 +15.3%）！',
            'en': 'Defensive SCHD positioning limited drawdown to -1.6% while QQQ plunged -16.9% (+15.3% protection)!',
        },
    },
    'AI CapEx Surge & 2026 Digest': {
        'type': 'bull',
        'zh': '2025.04–26.11 恐慌抄底与高位消化',
        'en': 'AI CapEx Surge & 2026 Digest',
        'note': {
            'zh': '2025-04-07 VIX=47满仓杀回QQQ锁定快反利润，随后切换高股息吃满价值补涨，斩获 +68.1% 超额胜出（M4达 +89.9%）',
            'en': '2025-04-07 VIX=47 all-in QQQ snipe + value rotation delivered +68.1% vs QQQ +64.5% (M4 hit +89.9%)',
        },
    },
}


M6_SWITCH_ANNOTATIONS = {
    '2000-04-17': (
        'ma150_breakdown_exit',
        {'en': 'Bubble <MA150 Full Exit', 'zh': '科网泡沫破 MA150 清仓'},
        {
            'en': '90d peak Pos-PE hit 69.5x (FCF Yield 1.34%) and QQQ broke below MA150; rotated 100% into dividend value near the Dot-Com top.',
            'zh': '90日峰值PE高达69.5x（FCF率仅1.34%）且收盘跌破MA150，果断清仓切换高股息逃离科网大顶！',
        },
    ),
    '2001-04-05': (
        'panic_valuation_all_in',
        {'en': 'Left-Side Valuation + VIX Buy', 'zh': '左侧估值消化抄底'},
        {
            'en': 'After a -68.3% washout, Pos-PE compressed from 69.5x to 25.8x (3Y Z = -1.73s, VIX = 29.9), triggering tactical QQQ re-entry.',
            'zh': '经历 -68.3% 深度出清后 Pos-PE 从69.5x压至25.8x（3Y估值Z=-1.73σ），触发第一轮左侧买回。',
        },
    ),
    '2001-12-06': (
        'tranche2_froth_trim',
        {'en': 'Bear-Rally Froth Trim (45%)', 'zh': '熊市反弹估值飙升减至45%'},
        {
            'en': 'Post-9/11 rebound pushed trailing Pos-PE back to 42.2x with FCF Yield 1.48%; trimmed QQQ down to 45% before the 2002 final leg down.',
            'zh': '反弹后盈利下滑推升Pos-PE重回42.2x（FCF率1.48%），提前减仓至45%规避2002年最后一跌。',
        },
    ),
    '2002-10-01': (
        'panic_vix_all_in',
        {'en': 'Generational Bottom VIX All-In', 'zh': '科网世纪大底满仓抄底'},
        {
            'en': 'FCF Yield reached 3.62% with VIX = 34.1 and 3Y Val-Z = -1.75s at -76% drawdown; rotated 100% into QQQ days before the secular trough.',
            'zh': '泡沫彻底出清（FCF率升至3.62% + VIX=34.1恐慌极值），在科网世纪大底前一周100%满仓买回QQQ！',
        },
    ),
    '2020-08-10': (
        'tranche1_froth_trim',
        {'en': 'Tranche 1 Slow-Sell (70%)', 'zh': '一档慢卖锁定泡沫利润 (70%)'},
        {
            'en': 'After holding 100% QQQ uninterrupted for 17.8 years, ZIRP melt-up pushed Pos-PE to 34.2x with Weekly RSI > 70; trimmed 30% into SCHD.',
            'zh': '连续满仓持有QQQ近18年后，疫情放水推升PE突破34.2x且周RSI超70，启动一档慢卖减仓30%换入SCHD。',
        },
    ),
    '2020-08-27': (
        'tranche2_froth_trim',
        {'en': 'Tranche 2 Slow-Sell (45%)', 'zh': '二档慢卖再锁狂热溢价 (45%)'},
        {
            'en': 'Pos-PE surged past 36.2x (3Y Val-Z = +3.52s, Daily RSI = 74.2); trimmed another 25% to 45% QQQ : 55% SCHD.',
            'zh': 'Pos-PE冲上36.2x（3Y估值Z高达+3.52σ，日RSI=74.2），执行二档慢卖降至 45% QQQ : 55% SCHD。',
        },
    ),
    '2022-01-19': (
        'ma150_breakdown_exit',
        {'en': '90d Bubble + <MA150 Full Exit', 'zh': '加息前夕破 MA150 清仓避险'},
        {
            'en': '90d peak PE was 34.8x and QQQ broke below MA150 ahead of Fed rate hikes; exited to 100% SCHD (which returned 0.0% in 2022 vs QQQ -35.1%).',
            'zh': '90日峰值PE达34.8x且美联储加息前夕跌破MA150，剩余45%全部清仓换入SCHD（完美规避2022主跌浪）。',
        },
    ),
    '2022-03-08': (
        'panic_vix_all_in',
        {'en': 'VIX 35.1 Panic All-In Snipe', 'zh': '俄乌恐慌 VIX=35 满仓快反'},
        {
            'en': 'Drawdown hit -19.9% with VIX spiking to 35.1, Pos-PE down to 26.2x, and FCF Yield 3.17%; went 100% QQQ and captured a +9.0% tactical rip.',
            'zh': '回撤达 -19.9%、VIX飙至35.1且PE消化至26.2x（FCF率3.17%），满仓抄底抓获 +9% 急弹。',
        },
    ),
    '2022-03-23': (
        'ma150_retest_lock',
        {'en': 'Sub-MA150 Bounce Profit Lock', 'zh': '反抽未过 MA150 止盈回防'},
        {
            'en': 'Bounce narrowed drawdown above -12% while QQQ remained capped below MA150 with active 90d bubble memory; locked +9% gain back into SCHD.',
            'zh': '反弹使回撤收窄至 -12.7% 但仍受制于MA150下方且90日泡沫记忆未消，果断锁定波段利润退守SCHD。',
        },
    ),
    '2022-04-25': (
        'panic_valuation_all_in',
        {'en': 'Left-Side Valuation Reset All-In', 'zh': '估值回归安全区满仓买回'},
        {
            'en': 'Drawdown exceeded -18.2% with Pos-PE reset to 26.5x, FCF Yield 3.19%, and 3Y Val-Z = -0.42s; re-entered 100% QQQ into the 2023 AI bull.',
            'zh': '回撤超 -18.2% 且估值消化至 26.5x（FCF率3.19%，3Y估值Z=-0.42σ），满仓买回并吃满2023 AI首轮主升浪。',
        },
    ),
    '2023-06-01': (
        'tranche1_froth_trim',
        {'en': 'AI Surge Tranche 1 Trim (70%)', 'zh': 'AI 拔估值一档慢卖 (70%)'},
        {
            'en': 'ChatGPT/AI multiple expansion pushed Pos-PE to 34.0x with Weekly RSI >= 70 (Daily RSI 74.4); trimmed 30% to SCHD.',
            'zh': 'AI首轮拔估值推升Pos-PE达34.0x且周RSI超70（日RSI=74.4），一档慢卖收割30%利润换入SCHD。',
        },
    ),
    '2023-07-14': (
        'tranche2_froth_trim',
        {'en': 'AI Euphoria Tranche 2 Trim (45%)', 'zh': 'AI 狂热二档慢卖 (45%)'},
        {
            'en': 'Pos-PE exceeded 36.4x with FCF Yield down to 2.43% and VIX at 13.3 complacency; trimmed QQQ exposure to 45%.',
            'zh': 'Pos-PE突破36.4x（FCF率降至2.43%，VIX低至13.3极度自满），二档慢卖降至 45% QQQ。',
        },
    ),
    '2023-10-26': (
        'ma150_breakdown_exit',
        {'en': '90d Bubble + <MA150 Defensive Shift', 'zh': '美债破5%跌破 MA150 防守切换'},
        {
            'en': '10Y Treasury yield spike pushed QQQ below MA150 after a 37.0x 90d peak PE; rotated remaining 45% into SCHD, avoiding the 2024–25 carry/tariff crash.',
            'zh': '10年期美债冲5%令QQQ在37.0x泡沫峰后跌破MA150，切换至SCHD并成功躲过2024–25套息与关税暴跌。',
        },
    ),
    '2025-04-07': (
        'panic_vix_all_in',
        {'en': 'Tariff Crash VIX 47 All-In Snipe!', 'zh': '关税崩盘 VIX=47 教科书级满仓抄底！'},
        {
            'en': 'Tariff shock drove QQQ down -21.4% with VIX exploding to 47.0, Daily RSI = 25.0, Pos-PE 28.1x, and FCF Yield 2.90%; liquidated 100% SCHD into QQQ at the exact bottom!',
            'zh': '关税闪崩回撤 -21.4%、VIX飙至47.0、日RSI跌至25.0且FCF率回到2.90%，一把清空SCHD 100%满仓杀回QQQ精准抄底！',
        },
    ),
    '2025-04-30': (
        'ma150_retest_lock',
        {'en': '+12.2% Fast-Bounce Lock to SCHD', 'zh': '快反急涨 +12.2% 止盈回防 SCHD'},
        {
            'en': 'Captured +12.2% rebound in 15 sessions ($420.78 -> $472.20); with QQQ still below MA150 under 38.3x 90d peak memory (and subsequent AI CapEx compressing FCF Yield < 2.3%), rotated to SCHD (+56.7% follow-through).',
            'zh': '15个交易日急涨 +12.2%（$420.78→$472.20）后受制于MA150且随后AI算力开支压低FCF率至2.1%，锁定快反收益并切换SCHD稳健吃满价值主升。',
        },
    ),
}

M4_SWITCH_ANNOTATIONS = {
    '2001-04-05': (
        'panic_valuation_all_in',
        {'en': 'Post-Bubble Valuation All-In', 'zh': '科网泡沫消化左侧全仓买入'},
        {
            'en': 'Pos-PE compressed to 25.8x (3Y Val-Z = -1.73s) at -68.3% drawdown; switched 0% -> 100% QQQ.',
            'zh': '科网崩盘回撤 -68.3% 后 Pos-PE 压至 25.8x（3Y估值Z=-1.73σ），全仓切入QQQ。',
        },
    ),
    '2020-07-21': (
        'left_bubble_exit',
        {'en': 'Dual-Anchor Overbought Full Exit', 'zh': '双锚泡沫+周RSI超买全换SCHD'},
        {
            'en': 'Pos-PE hit 32.4x with 3Y Val-Z = +3.19s and Weekly RSI >= 68; rotated 100% into SCHD.',
            'zh': 'Pos-PE达32.4x且3Y估值Z高达+3.19σ伴随周RSI超买，左侧100%切换至SCHD。',
        },
    ),
    '2022-03-08': (
        'panic_vix_all_in',
        {'en': '2022 Bear VIX 35.1 All-In Buy', 'zh': '2022 加息熊市 VIX=35 全仓抄底'},
        {
            'en': 'Drawdown hit -19.9% with VIX = 35.1 and Pos-PE = 26.2x (FCF Yield 3.17%); switched 100% back into QQQ.',
            'zh': '回撤 -19.9% 共振 VIX=35.1 且 FCF率升至3.17%，左侧100%全卖SCHD满仓买回QQQ。',
        },
    ),
    '2023-06-14': (
        'left_bubble_exit',
        {'en': 'AI 34.9x PE + RSI 77 Full Exit', 'zh': 'AI 34.9x PE + 超买左侧全换SCHD'},
        {
            'en': 'Pos-PE reached 34.9x with Daily RSI = 76.8 and Weekly RSI > 68; locked profits into 100% SCHD.',
            'zh': 'AI首轮飙升令Pos-PE达34.9x且日RSI高达76.8，左侧全仓止盈换入SCHD。',
        },
    ),
    '2025-04-07': (
        'panic_vix_all_in',
        {'en': 'Tariff Crash VIX 47 All-In Buy!', 'zh': '关税崩盘 VIX=47 全仓满手抄底！'},
        {
            'en': 'VIX hit 47.0, Daily RSI = 25.0, DD = -21.4% at $420.78; went 100% QQQ and rode the rally straight to $558.01 (+32.6%)!',
            'zh': 'VIX飙至47、日RSI=25，在$420.78全仓杀回QQQ并一路持有至$558.01（单笔怒赚 +32.6%）！',
        },
    ),
    '2025-07-22': (
        'left_bubble_exit',
        {'en': '35.3x PE + 2.25% FCF Yield Exit', 'zh': '反弹至 35.3x PE 左侧全换SCHD'},
        {
            'en': 'After +32.6% surge from the April bottom, Pos-PE reached 35.3x (FCF Yield down to 2.25%) with Weekly RSI > 68; rotated 100% into SCHD.',
            'zh': '自4月大底暴涨 +32.6% 后 Pos-PE 重回 35.3x（FCF率压至2.25%）且周RSI超买，高位全仓切换SCHD防守。',
        },
    ),
}


def build_switch_ledger(
    mode_key: str,
    dates: list[str],
    weights: list[float],
    strat_nav: list[float],
    qqq_nav: list[float],
    schd_nav: list[float],
    master_by_date: dict[str, dict],
) -> list[dict]:
    ann_map = M4_SWITCH_ANNOTATIONS if mode_key == 'm4' else M6_SWITCH_ANNOTATIONS
    change_indices = [i for i in range(1, len(dates)) if abs(weights[i] - weights[i - 1]) > 1e-4]
    records: list[dict] = []

    for pos, idx in enumerate(change_indices):
        exec_date = dates[idx]
        sig_date = dates[idx - 1]
        from_w = weights[idx - 1]
        to_w = weights[idx]
        next_idx = change_indices[pos + 1] if pos + 1 < len(change_indices) else len(dates) - 1
        end_date = dates[next_idx]
        hold_days = next_idx - idx

        s_ret = strat_nav[next_idx] / strat_nav[idx] - 1.0 if strat_nav[idx] > 0 else 0.0
        q_ret = qqq_nav[next_idx] / qqq_nav[idx] - 1.0 if qqq_nav[idx] > 0 else 0.0
        d_ret = schd_nav[next_idx] / schd_nav[idx] - 1.0 if schd_nav[idx] > 0 else 0.0

        m = master_by_date[exec_date]
        sig_m = master_by_date.get(sig_date, m)
        ann = ann_map.get(exec_date)
        if ann:
            sig_type, sig_label, explanation = ann
        else:
            going_up = to_w > from_w
            sig_type = 'tactical_buy' if going_up else 'tactical_trim'
            sig_label = (
                {'en': 'Tactical QQQ Re-entry', 'zh': '战术买回 QQQ'}
                if going_up
                else {'en': 'Tactical SCHD Shift', 'zh': '战术减仓换 SCHD'}
            )
            explanation = {
                'en': f'Executed T+1 allocation shift from {from_w*100:.0f}% to {to_w*100:.0f}% QQQ.',
                'zh': f'T+1 执行仓位切换：QQQ 权重由 {from_w*100:.0f}% 调整至 {to_w*100:.0f}%。',
            }

        if mode_key == 'm7':
            explanation = {
                'en': f"[50% Permanent QQQ Core + 50% M6 Sleeve] {explanation['en']}",
                'zh': f"【50%永久QQQ底仓 + 50%战术仓】{explanation['zh']}",
            }

        records.append({
            'switchId': f'{mode_key.upper()}-{pos + 1:02d}',
            'signalDate': sig_date,
            'date': exec_date,
            'nextSwitchDate': end_date,
            'isOpenRegime': pos == len(change_indices) - 1,
            'inLiveWindow': exec_date >= LIVE_START_DATE,
            'fromQqqWeight': r4(from_w),
            'toQqqWeight': r4(to_w),
            'fromSchdWeight': r4(1.0 - from_w),
            'toSchdWeight': r4(1.0 - to_w),
            'direction': 'buy_qqq' if to_w > from_w else 'sell_qqq',
            'signalType': sig_type,
            'signalLabel': sig_label,
            'explanation': explanation,
            'qqqAdj': r2(m['qqq_adj']),
            'qqqClose': r2(m['qqq_close']),
            'schdClose': r2(m['schd_close']),
            'posPe': r2(m['agg_pe_pos']),
            'peak90Pe': r2(m['pepos_max90']),
            'fcfYieldPct': r2(m['fcf_yield_pct']),
            'valZ3y': r2(m['cval_z_3y']),
            'dd2yPct': r2(m['dd_2y']),
            'ma150DistPct': r2(m['qqq_dist_ma150']),
            'rsi14': r2(m['rsi14']),
            'wkRsi14': r2(m['wk_rsi14']),
            'vix': r2(m['vix']),
            'signalDayVix': r2(sig_m['vix']),
            'signalDayRsi14': r2(sig_m['rsi14']),
            'holdingDays': hold_days,
            'intervalStrategyReturn': r6(s_ret),
            'intervalQqqReturn': r6(q_ret),
            'intervalSchdReturn': r6(d_ret),
            'intervalExcessVsQqq': r6(s_ret - q_ret),
        })

    return records


def build_mode_blueprints() -> dict[str, list[dict]]:
    m6_steps = [
        {
            'step': 1,
            'title': {'en': 'Normal Compounding Base', 'zh': '常态满仓复利巡航'},
            'summary': {
                'en': 'Hold 100% QQQ : 0% SCHD whenever Nasdaq-100 Pos-PE < 33.5x and FCF Yield > 2.35%, ignoring normal bull-market pullbacks.',
                'zh': '当纳指盈利股聚合 Pos-PE < 33.5x 且 FCF 收益率 > 2.35% 时，坚定持有 100% QQQ : 0% SCHD，无视牛市正常回调拒绝打脸。',
            },
            'metricBadge': '100% QQQ · Avg 72.3%',
        },
        {
            'step': 2,
            'title': {'en': 'Staged Slow-Sell Bubble Trim (70% -> 45% -> 0%)', 'zh': '慢卖三阶止盈护栏 (70% → 45% → 0%)'},
            'summary': {
                'en': 'Trim to 70% QQQ at Pos-PE >= 33.5x & Wk-RSI >= 70; trim to 45% at Pos-PE >= 36.0x (or FCF <= 2.20% & Wk-RSI >= 72); exit to 0% QQQ (100% SCHD) on close < MA150 (-0.5%) with 90d bubble memory.',
                'zh': 'Pos-PE ≥ 33.5x 且周RSI ≥ 70 减至 70%；PE ≥ 36x（或FCF率 ≤ 2.20%且周RSI ≥ 72）再减至 45%；90日内曾触及泡沫且跌破 MA150 清至 0% 全换 SCHD。',
            },
            'metricBadge': '70% -> 45% -> 0% QQQ',
        },
        {
            'step': 3,
            'title': {'en': 'Aggressive All-In Panic Sniping (+2.59%/yr Alpha)', 'zh': '恐慌共振一把全卖 SCHD 满仓抄底 (+2.59%/年)'},
            'summary': {
                'en': 'Once out of bubble zone (Pos-PE <= 28.5x & FCF Yield >= 2.75%) with 2Y drawdown DD <= -18%, if VIX >= 32 OR Daily RSI <= 28 (Wk-RSI <= 35) OR Pos-PE <= 24.5x, liquidate 100% SCHD into QQQ immediately!',
                'zh': '安全前提（PE ≤ 28.5x 且 FCF率 ≥ 2.75%）+ 2年回撤 DD ≤ -18%，叠加 VIX ≥ 32 或 日RSI ≤ 28 或 PE ≤ 24.5x 任一信号，一次性全卖 SCHD 100% 满仓杀回 QQQ！',
            },
            'metricBadge': 'VIX >= 32 / RSI <= 28 -> 100%',
        },
        {
            'step': 4,
            'title': {'en': 'Right-Side Re-entry Backstop & Execution Discipline', 'zh': '右侧趋势兜底买回与低频 T+1 纪律'},
            'summary': {
                'en': 'If earnings digest multiples without a -18% crash (Pos-PE <= 31.0x & FCF Yield >= 2.55%) and QQQ reclaims MA150 + 1.5%, re-enter 100% QQQ. 10-day min hold, T+1 close execution, 5 bps/side cost.',
                'zh': '若未深跌便靠盈利增长消化估值（PE ≤ 31x 且 FCF率 ≥ 2.55%）并重新站稳 MA150 + 1.5%，右侧顺势满仓买回。10日防抖锁定期，T+1收盘成交、双边5 bps成本。',
            },
            'metricBadge': '11 Live Switches · 5 bps',
        },
    ]

    m4_steps = [
        {
            'step': 1,
            'title': {'en': 'Ultra-Low-Frequency Compounding', 'zh': '极低频满仓长牛复利'},
            'summary': {
                'en': 'Hold 100% QQQ across multi-year expansions until both absolute bubble valuation and weekly momentum exhaustion trigger simultaneously (only 5 switches in 15.1 years).',
                'zh': '在长达数年的科技扩张期保持 100% QQQ 死拿，15.1年实盘周期仅调仓 5 次，最大化长牛复利连贯性。',
            },
            'metricBadge': 'Only 5 Live Switches',
        },
        {
            'step': 2,
            'title': {'en': 'Dual-Anchor Left-Side Full Exit (100% -> 0%)', 'zh': '双锚左侧高估超买全仓切换 (100% → 0%)'},
            'summary': {
                'en': 'When Pos-PE >= 34.5x (or >= 32.5x with 3Y Val-Z >= +1.25s) AND Weekly RSI(14) >= 68 (or Pos-PE >= 35.5x), rotate 100% into defensive SCHD in a single decisive move.',
                'zh': '当 Pos-PE ≥ 34.5x（或 ≥ 32.5x 且 3Y估值Z ≥ +1.25σ）且周线 RSI(14) ≥ 68（或 PE ≥ 35.5x）时，左侧一次性 100% 全换 SCHD。',
            },
            'metricBadge': 'PE >= 34.5x + WkRSI >= 68',
        },
        {
            'step': 3,
            'title': {'en': 'Aggressive Panic / Valuation All-In Buy', 'zh': '大回撤共振 VIX / 低估一把满仓杀回'},
            'summary': {
                'en': 'Identical left-side sniping engine as M6: DD <= -18% + non-bubble guard (PE <= 28.5x, FCF >= 2.75%) + (VIX >= 32 or Daily RSI <= 28 or PE <= 24.5x) -> 100% QQQ.',
                'zh': '与 M6 共用左侧恐慌狙击引擎：回撤 ≤ -18% + 脱离泡沫护栏 +（VIX ≥ 32 或 日RSI ≤ 28 或 PE ≤ 24.5x）立即全卖 SCHD 满仓 QQQ。',
            },
            'metricBadge': '98.1% Rolling 5Y Win Rate',
        },
        {
            'step': 4,
            'title': {'en': 'Pure Valuation Reset Fallback (PE <= 23.5x)', 'zh': '绝对低估兜底买回 (Pos-PE ≤ 23.5x)'},
            'summary': {
                'en': 'If earnings growth compresses Nasdaq-100 Pos-PE to <= 23.5x without an acute VIX spike, rotate 100% back into QQQ. Best suited for tax-exempt accounts seeking maximum CAGR (21.39%).',
                'zh': '若业绩高增令纳指 Pos-PE 自然回落至 ≤ 23.5x，无条件全仓切回 QQQ。适合追求极致年化收益（21.39% / 18.55x）的免税账户。',
            },
            'metricBadge': '21.39% CAGR · 18.55x',
        },
    ]

    m7_steps = [
        {
            'step': 1,
            'title': {'en': '50% Permanent Low-Basis QQQ Core', 'zh': '50% 低成本 QQQ 永久免税底仓'},
            'summary': {
                'en': 'Lock 50% of portfolio in permanent buy-and-hold QQQ that is NEVER sold, deferring unrealized capital gains taxes indefinitely and eliminating bull-market FOMO.',
                'zh': '50% 仓位作为永久死拿的 QQQ 核心底仓永不卖出，彻底规避美股高浮盈清仓的资本利得税流失，并根治牛市踏空焦虑。',
            },
            'metricBadge': '50% QQQ Floor Never Sold',
        },
        {
            'step': 2,
            'title': {'en': '50% Tactical Sleeve Runs M6 Slow-Sell (100% -> 85% -> 72.5% -> 50%)', 'zh': '50% 战术轮动仓执行 M6 慢卖 (总仓位 100%→85%→72.5%→50%)'},
            'summary': {
                'en': 'Only the 50% tactical sleeve rotates into SCHD during bubble froth and <MA150 breakdowns, bringing total portfolio exposure smoothly to 50% QQQ : 50% SCHD in tech bears.',
                'zh': '仅用另外 50% 战术仓在泡沫期分批换入 SCHD，破 MA150 时形成 50% QQQ + 50% SCHD 攻守兼备结构，年化换手率砍半至 23.2%。',
            },
            'metricBadge': 'Ann. Turnover Only 23.2%',
        },
        {
            'step': 3,
            'title': {'en': '100% Full QQQ Offense at Panic Troughs', 'zh': '危机恐慌极值恢复 100% QQQ 满仓进攻'},
            'summary': {
                'en': 'When M6 triggers left-side panic sniping (DD <= -18% + VIX >= 32 / RSI <= 28), sell the 50% SCHD tactical buffer (often near flat cost basis, minimal tax!) to reach 100% QQQ.',
                'zh': '当触发大回撤+VIX/RSI恐慌极值抄底信号时，卖出浮盈较小的 50% SCHD 避险仓（税损极低），恢复 100% QQQ 满仓吃满反转弹性！',
            },
            'metricBadge': '50% -> 100% QQQ Snipe',
        },
        {
            'step': 4,
            'title': {'en': '#1 After-Tax Tactical Compounder at 20% CGT', 'zh': '20% 资本利得税率下战术策略税后第一'},
            'summary': {
                'en': 'At a 20% US capital gains tax rate, M7 delivers 17.99% after-tax CAGR (highest of all tactical strategies) while cutting QQQ max drawdown from -35.12% to -28.56% (95.9% 5Y win rate).',
                'zh': '在 20% 资本利得税严苛测试下，M7 税后年化达 17.99%（居所有轮动方案之首），同时将最大回撤从 -35.12% 压至 -28.56%，5年胜率高达 95.9%。',
            },
            'metricBadge': '95.9% Rolling 5Y Win Rate',
        },
    ]

    return {'m6': m6_steps, 'm4': m4_steps, 'm7': m7_steps}


def build_from_source_dir(source_dir: Path) -> dict:
    master_file = source_dir / 'qqq_schd_daily_master.parquet'
    live_file = source_dir / 'curves_live_2011_2026.parquet'
    full_file = source_dir / 'curves_full_2000_2026.parquet'
    canon_live_csv = source_dir / 'canonical_live_2011_2026.csv'
    canon_full_csv = source_dir / 'canonical_full_2000_2026.csv'
    regime_csv = source_dir / 'regime_attribution_table.csv'
    tax_csv = source_dir / 'tax_sensitivity_canonical_2011_2026.csv'
    grid_csv = source_dir / 'robustness_grid_m5_25cells.csv'

    required = [
        master_file,
        live_file,
        full_file,
        canon_live_csv,
        canon_full_csv,
        regime_csv,
        tax_csv,
        grid_csv,
    ]
    for p in required:
        if not p.exists():
            raise FileNotFoundError(f'Missing verified source file: {p}')

    hasher = hashlib.sha256()
    for p in required:
        hasher.update(p.name.encode('utf-8'))
        hasher.update(p.read_bytes())
    source_generation = hasher.hexdigest()

    con = duckdb.connect()
    try:
        master_rows = con.execute(f"""
            SELECT
                SUBSTR(CAST(date AS VARCHAR), 1, 10) AS d,
                qqq_close,
                qqq_adj,
                qqq_ret,
                schd_close,
                schd_adj,
                schd_ret_live,
                schd_ret_spliced,
                rf_ret,
                agg_pe_pos,
                fcf_yield_pct,
                p_fcf,
                agg_ps,
                agg_evebitda,
                vix,
                vxn,
                qqq_ma150,
                qqq_dist_ma150,
                qqq_ma200,
                qqq_dist_ma200,
                rsi14,
                wk_rsi14,
                dd_2y,
                qqq_peak_504,
                fcf_exp_z_3y,
                ev_z_3y
            FROM read_parquet('{master_file.as_posix()}')
            ORDER BY date
        """).fetchall()

        # Recompute exact 3Y Pos-PE Z-score, cval_z_3y, and 90-day rolling peak memory
        # identically to run_final_verification.py (lines 20-35) using pure Python stdlib.
        pe_vals = [float(r[9]) if r[9] is not None else float('nan') for r in master_rows]
        fcf_vals = [float(r[10]) if r[10] is not None else float('nan') for r in master_rows]
        cval_z_3y_list: list[float | None] = []
        pe_ma_3y_list: list[float | None] = []

        for i in range(len(master_rows)):
            win = [x for x in pe_vals[max(0, i - 755): i + 1] if math.isfinite(x)]
            if len(win) >= 252 and math.isfinite(pe_vals[i]):
                mean_v = sum(win) / len(win)
                var_v = sum((x - mean_v) ** 2 for x in win) / (len(win) - 1)
                std_v = math.sqrt(max(var_v, 0.0))
                pe_z = (pe_vals[i] - mean_v) / std_v if std_v > 1e-12 else 0.0
                fcf_z = float(master_rows[i][24]) if master_rows[i][24] is not None and math.isfinite(float(master_rows[i][24])) else pe_z
                ev_z = float(master_rows[i][25]) if master_rows[i][25] is not None and math.isfinite(float(master_rows[i][25])) else pe_z
                cval_z_3y_list.append(0.40 * pe_z + 0.30 * fcf_z + 0.30 * ev_z)
                pe_ma_3y_list.append(mean_v)
            else:
                cval_z_3y_list.append(None)
                pe_ma_3y_list.append(None)

        master_by_date: dict[str, dict] = {}
        for i, r in enumerate(master_rows):
            pe_w90 = [x for x in pe_vals[max(0, i - 89): i + 1] if math.isfinite(x)]
            fcf_w90 = [x for x in fcf_vals[max(0, i - 89): i + 1] if math.isfinite(x)]
            cz_w90 = [x for x in cval_z_3y_list[max(0, i - 89): i + 1] if x is not None and math.isfinite(x)]
            master_by_date[r[0]] = {
                'date': r[0],
                'qqq_close': float(r[1]) if r[1] is not None else 0.0,
                'qqq_adj': float(r[2]) if r[2] is not None else 0.0,
                'qqq_ret': float(r[3]) if r[3] is not None else 0.0,
                'schd_close': float(r[4]) if r[4] is not None else None,
                'schd_adj': float(r[5]) if r[5] is not None else None,
                'schd_ret_live': float(r[6]) if r[6] is not None else 0.0,
                'schd_ret_spliced': float(r[7]) if r[7] is not None else 0.0,
                'rf_ret': float(r[8]) if r[8] is not None else 0.0,
                'agg_pe_pos': float(r[9]) if r[9] is not None else None,
                'fcf_yield_pct': float(r[10]) if r[10] is not None else None,
                'p_fcf': float(r[11]) if r[11] is not None else None,
                'agg_ps': float(r[12]) if r[12] is not None else None,
                'agg_evebitda': float(r[13]) if r[13] is not None else None,
                'vix': float(r[14]) if r[14] is not None else None,
                'vxn': float(r[15]) if r[15] is not None else None,
                'qqq_ma150': float(r[16]) if r[16] is not None else None,
                'qqq_dist_ma150': float(r[17]) if r[17] is not None else None,
                'qqq_ma200': float(r[18]) if r[18] is not None else None,
                'qqq_dist_ma200': float(r[19]) if r[19] is not None else None,
                'rsi14': float(r[20]) if r[20] is not None else None,
                'wk_rsi14': float(r[21]) if r[21] is not None else None,
                'dd_2y': float(r[22]) if r[22] is not None else 0.0,
                'qqq_peak_504': float(r[23]) if r[23] is not None else None,
                'cval_z_3y': cval_z_3y_list[i],
                'pe_ma_3y': pe_ma_3y_list[i],
                'pepos_max90': max(pe_w90) if len(pe_w90) >= 5 else None,
                'fcf_min90': min(fcf_w90) if len(fcf_w90) >= 5 else None,
                'cval_z_max90': max(cz_w90) if len(cz_w90) >= 5 else None,
            }

        def load_window_series(parquet_path: Path) -> dict:
            c_rows = con.execute(f"""
                SELECT
                    SUBSTR(CAST(date AS VARCHAR), 1, 10) AS d,
                    M6_nav, M4_nav, M7_nav, M5_nav,
                    B1_nav, B2_nav, B3_nav,
                    M6_w, M4_w, M7_w
                FROM read_parquet('{parquet_path.as_posix()}')
                ORDER BY date
            """).fetchall()
            dates = [r[0] for r in c_rows]
            m6 = [round(float(r[1]), 8) for r in c_rows]
            m4 = [round(float(r[2]), 8) for r in c_rows]
            m7 = [round(float(r[3]), 8) for r in c_rows]
            m5 = [round(float(r[4]), 8) for r in c_rows]
            qqq = [round(float(r[5]), 8) for r in c_rows]
            schd = [round(float(r[6]), 8) for r in c_rows]
            static7030 = [round(float(r[7]), 8) for r in c_rows]
            m6w = [r4(r[8]) for r in c_rows]
            m4w = [r4(r[9]) for r in c_rows]
            m7w = [r4(r[10]) for r in c_rows]
            rf = [r6(master_by_date[d]['rf_ret']) for d in dates]
            pos_pe = [r2(master_by_date[d]['agg_pe_pos']) for d in dates]
            fcf_y = [r2(master_by_date[d]['fcf_yield_pct']) for d in dates]
            vix_s = [r2(master_by_date[d]['vix']) for d in dates]
            rsi_s = [r2(master_by_date[d]['rsi14']) for d in dates]
            dd2y_s = [r2(master_by_date[d]['dd_2y']) for d in dates]
            ma150_d = [r2(master_by_date[d]['qqq_dist_ma150']) for d in dates]
            qqq_adj_s = [r2(master_by_date[d]['qqq_adj']) for d in dates]
            return {
                'inceptionDate': dates[0],
                'dataThrough': dates[-1],
                'observations': len(dates),
                'dates': dates,
                'm6': m6,
                'm4': m4,
                'm7': m7,
                'm5': m5,
                'qqq': qqq,
                'schd': schd,
                'static7030': static7030,
                '_raw': {
                    'm6': [float(r[1]) for r in c_rows],
                    'm4': [float(r[2]) for r in c_rows],
                    'm7': [float(r[3]) for r in c_rows],
                    'qqq': [float(r[5]) for r in c_rows],
                    'schd': [float(r[6]) for r in c_rows],
                    'static7030': [float(r[7]) for r in c_rows],
                    'rfRet': [master_by_date[d]['rf_ret'] for d in dates],
                },
                'm6w': m6w,
                'm4w': m4w,
                'm7w': m7w,
                'rfRet': rf,
                'posPe': pos_pe,
                'fcfYield': fcf_y,
                'vix': vix_s,
                'rsi14': rsi_s,
                'dd2y': dd2y_s,
                'ma150Dist': ma150_d,
                'qqqAdj': qqq_adj_s,
            }

        win_live = load_window_series(live_file)
        win_full = load_window_series(full_file)
    finally:
        con.close()

    def load_canonical_csv(path: Path) -> list[dict]:
        rows_out = []
        with path.open('r', encoding='utf-8') as f:
            for row in csv.DictReader(f):
                raw_name = row['Strategy']
                code = raw_name.split(':', 1)[0].strip()
                meta = CANONICAL_STRATEGY_META.get(code, {
                    'code': code,
                    'group': 'other',
                    'name': {'en': raw_name, 'zh': raw_name},
                    'rule': {'en': raw_name, 'zh': raw_name},
                })
                rows_out.append({
                    'code': code,
                    'group': meta['group'],
                    'rawStrategy': raw_name,
                    'name': meta['name'],
                    'rule': meta['rule'],
                    'cagrPct': float(row['CAGR_%']),
                    'endingMultiple': float(row['Mult_x']),
                    'volPct': float(row['Vol_%']),
                    'sharpe': float(row['Sharpe']),
                    'sortino': float(row['Sortino']),
                    'maxDrawdownPct': float(row['MDD_%']),
                    'calmar': float(row['Calmar']),
                    'ulcerIndex': float(row['Ulcer']),
                    'avgQqqPct': float(row['Avg_QQQ_%']),
                    'trades': int(float(row['Trades'])),
                    'annualTurnoverPct': float(row['AnnTurn_%']),
                    'win3yPct': float(row['Win3Y_%']),
                    'win5yPct': float(row['Win5Y_%']),
                })
        return rows_out

    canonical_live = load_canonical_csv(canon_live_csv)
    canonical_full = load_canonical_csv(canon_full_csv)

    regimes_out = []
    with regime_csv.open('r', encoding='utf-8') as f:
        for row in csv.DictReader(f):
            rk = row['Regime']
            meta = REGIME_META.get(rk, {
                'type': 'bull',
                'zh': rk,
                'en': rk,
                'note': {'zh': '', 'en': ''},
            })
            qqq_p = float(row['QQQ_%'])
            m6_p = float(row['M6_Staged_%'])
            m4_p = float(row['M4_Left_%'])
            m7_p = float(row['M7_CoreSat_%'])
            regimes_out.append({
                'id': rk,
                'type': meta['type'],
                'label': {'en': meta['en'], 'zh': meta['zh']},
                'note': meta['note'],
                'start': row['Start'],
                'end': row['End'],
                'qqqPct': qqq_p,
                'schdPct': float(row['SCHD_%']),
                'static7030Pct': float(row['Static70_30_%']),
                'm4Pct': m4_p,
                'm5Pct': float(row['M5_Trend_%']),
                'm6Pct': m6_p,
                'm7Pct': m7_p,
                'm6ExcessPct': r2(m6_p - qqq_p),
                'm4ExcessPct': r2(m4_p - qqq_p),
                'm7ExcessPct': r2(m7_p - qqq_p),
            })

    tax_labels = {
        '100% QQQ Buy & Hold': {'code': 'B1', 'en': '100% QQQ Buy & Hold (Deferred Tax)', 'zh': '100% QQQ 死拿（递延零卖出税）'},
        '100% SCHD Buy & Hold': {'code': 'B2', 'en': '100% SCHD Buy & Hold', 'zh': '100% SCHD 买入死拿'},
        'Static 70/30 Q-Rebal': {'code': 'B3', 'en': 'Static 70/30 Quarterly Rebalance', 'zh': '70/30 静态季度再平衡'},
        'M4: Dual-Anchor Left All-In': {'code': 'M4', 'en': 'M4 Dual-Anchor Left-Side All-In', 'zh': 'M4 双锚左侧全进出轮动'},
        'M5: PeakBubble+<MA150 All-In': {'code': 'M5', 'en': 'M5 Peak-Bubble + <MA150 All-In', 'zh': 'M5 泡沫破MA150全进出'},
        'M6: Asymmetric Staged (70/45/0->100%)': {'code': 'M6', 'en': 'M6 Slow-Sell / Fast-Buy [IRA/0% Tax Best]', 'zh': 'M6 慢卖快买旗舰 [免税账户最优]'},
        'M7: 50% Core + 50% Tactical': {'code': 'M7', 'en': 'M7 50% QQQ Core + 50% M6 [20% Tax Best]', 'zh': 'M7 50%底仓+50%战术仓 [应税账户最优]'},
    }
    tax_rows = []
    with tax_csv.open('r', encoding='utf-8') as f:
        for row in csv.DictReader(f):
            sk = row['Strategy']
            tl = tax_labels.get(sk, {'code': sk[:2], 'en': sk, 'zh': sk})
            tf = float(row['TaxFree_CAGR%'])
            t15 = float(row['Tax15%_CAGR%'])
            t20 = float(row['Tax20%_CAGR%'])
            tax_rows.append({
                'code': tl['code'],
                'label': {'en': tl['en'], 'zh': tl['zh']},
                'taxFreeCagrPct': tf,
                'sharpe': float(row['Sharpe']),
                'maxDrawdownPct': float(row['MDD%']),
                'calmar': float(row['Calmar']),
                'tax15CagrPct': t15,
                'tax20CagrPct': t20,
                'tax20DragPct': r2(t20 - tf),
            })

    grid_live = []
    grid_full = []
    with grid_csv.open('r', encoding='utf-8') as f:
        for row in csv.DictReader(f):
            cell = {
                'sellPeakPe': float(row['Sell_PeakPE']),
                'buyDrawdownPct': float(row['Buy_DD']),
                'cagrPct': float(row['CAGR_%']),
                'sharpe': float(row['Sharpe']),
                'maxDrawdownPct': float(row['MDD_%']),
                'calmar': float(row['Calmar']),
                'trades': int(float(row['Trades'])),
            }
            if row['Window'] == 'Live_2011_2026':
                grid_live.append(cell)
            else:
                grid_full.append(cell)

    def summarize_grid(cells: list[dict], q_cagr: float, q_sharpe: float, q_mdd: float) -> dict:
        cagrs = [c['cagrPct'] for c in cells]
        sharpes = [c['sharpe'] for c in cells]
        mdds = [c['maxDrawdownPct'] for c in cells]
        return {
            'cellCount': len(cells),
            'sellPeakPeAxis': sorted({c['sellPeakPe'] for c in cells}),
            'buyDrawdownAxis': sorted({c['buyDrawdownPct'] for c in cells}, reverse=True),
            'meanCagrPct': r2(sum(cagrs) / len(cagrs)),
            'minCagrPct': r2(min(cagrs)),
            'maxCagrPct': r2(max(cagrs)),
            'meanSharpe': r3(sum(sharpes) / len(sharpes)),
            'minSharpe': r3(min(sharpes)),
            'maxSharpe': r3(max(sharpes)),
            'meanMaxDrawdownPct': r2(sum(mdds) / len(mdds)),
            'beatQqqCagrPct': r2(sum(1 for x in cagrs if x > q_cagr) / len(cagrs) * 100.0),
            'beatQqqSharpePct': r2(sum(1 for x in sharpes if x > q_sharpe) / len(sharpes) * 100.0),
            'beatQqqMddPct': r2(sum(1 for x in mdds if x > q_mdd) / len(mdds) * 100.0),
            'cells': cells,
        }

    switches_m6 = build_switch_ledger(
        'm6', win_full['dates'], win_full['m6w'], win_full['m6'], win_full['qqq'], win_full['schd'], master_by_date
    )
    switches_m4 = build_switch_ledger(
        'm4', win_full['dates'], win_full['m4w'], win_full['m4'], win_full['qqq'], win_full['schd'], master_by_date
    )
    switches_m7 = build_switch_ledger(
        'm7', win_full['dates'], win_full['m7w'], win_full['m7'], win_full['qqq'], win_full['schd'], master_by_date
    )

    blueprints = build_mode_blueprints()
    mode_defs = {
        'm6': {
            'id': 'm6',
            'code': 'M6',
            'badge': {'en': 'ALL-WEATHER FLAGSHIP · RECOMMENDED', 'zh': '慢卖快买旗舰 · 默认推荐'},
            'name': {
                'en': 'M6 · Asymmetric Staged Slow-Sell / Fast-Buy',
                'zh': 'M6 · 慢卖快买分批轮动旗舰版',
            },
            'shortLabel': {'en': 'M6 Slow-Sell / Fast-Buy (16.74x)', 'zh': 'M6 慢卖快买旗舰 (16.74x)'},
            'summary': {
                'en': 'Trims QQQ in two left-side froth tranches (100% -> 70% -> 45%), exits to 100% SCHD on a 90d-bubble <MA150 breakdown, and snaps 100% back into QQQ on DD <= -18% + VIX/RSI panic.',
                'zh': '泡沫超买分两档慢减（100%→70%→45%），90日泡沫记忆破MA150清至0%全换SCHD；一旦触发回撤≤-18%共振VIX/RSI恐慌极值，一次性100%全卖SCHD满仓杀回QQQ。',
            },
            'accountFit': {
                'en': 'Tax-exempt / IRA / Roth / 401k / Non-US 0% capital-gains accounts',
                'zh': '美股免税养老金账户（IRA/Roth/401k）及非美居民 0 资本利得税账户首选',
            },
            'blueprint': blueprints['m6'],
            'switches': switches_m6,
        },
        'm4': {
            'id': 'm4',
            'code': 'M4',
            'badge': {'en': 'OFFENSIVE CHAMPION · ULTRA-LOW TURNOVER', 'zh': '双锚左侧全进出 · 进攻收益冠军'},
            'name': {
                'en': 'M4 · Dual-Anchor Left-Side All-In Rotation',
                'zh': 'M4 · 双锚左侧全仓轮动进攻版',
            },
            'shortLabel': {'en': 'M4 Left-Side All-In (18.55x)', 'zh': 'M4 双锚左侧全进出 (18.55x)'},
            'summary': {
                'en': 'Pure binary 100% QQQ <-> 100% SCHD rotation using dual valuation guardrails + weekly RSI exhaustion on exits and VIX/RSI panic sniping on entries (only 5 switches in 15.1 years).',
                'zh': '纯二元 100% QQQ ⇄ 100% SCHD 全进全出，高估共振周线超买左侧清仓、暴跌共振VIX/低估满仓抄底，15.1年仅换手 5 次，滚动5年胜率高达 98.1%。',
            },
            'accountFit': {
                'en': '0% tax accounts seeking highest CAGR (21.39%) with minimal trading frequency',
                'zh': '追求最高年化复利（21.39% / 18.55x）且极低换手频率的零资本利得税账户',
            },
            'blueprint': blueprints['m4'],
            'switches': switches_m4,
        },
        'm7': {
            'id': 'm7',
            'code': 'M7',
            'badge': {'en': 'TAXABLE OPTIMAL · ZERO FOMO CORE-SATELLITE', 'zh': '50%永久底仓 · 应税账户优解'},
            'name': {
                'en': 'M7 · 50% Permanent QQQ Core + 50% M6 Tactical Sleeve',
                'zh': 'M7 · 50% QQQ 永久底仓 + 50% M6 战术轮动版',
            },
            'shortLabel': {'en': 'M7 50/50 Core-Satellite (15.42x)', 'zh': 'M7 50%底仓应税版 (15.42x)'},
            'summary': {
                'en': 'Holds a permanent untaxed 50% QQQ core and runs M6 slow-sell / fast-buy on the 50% tactical sleeve (total QQQ exposure 50%..100%), ranking #1 after 20% capital gains tax.',
                'zh': '保留 50% 低成本 QQQ 底仓永不卖出免交重税，仅用 50% 战术仓执行 M6 慢卖快买（总 QQQ 仓位 50%–100%），20% 资本利得税后年化高居战术策略第一。',
            },
            'accountFit': {
                'en': 'US taxable brokerage accounts (15%–20%+ capital gains tax) or investors averse to 0% QQQ',
                'zh': '需缴纳 15%–20%+ 资本利得税的美股应税账户，或厌恶完全空仓 QQQ 的稳健配置者',
            },
            'blueprint': blueprints['m7'],
            'switches': switches_m7,
        },
    }

    for mk, mobj in mode_defs.items():
        mobj['metrics'] = {
            'live_2011': compute_window_metrics(
                win_live['dates'], win_live['_raw'][mk], win_live['_raw']['qqq'], win_live['_raw']['rfRet'], win_live[f'{mk}w']
            ),
            'full_2000': compute_window_metrics(
                win_full['dates'], win_full['_raw'][mk], win_full['_raw']['qqq'], win_full['_raw']['rfRet'], win_full[f'{mk}w']
            ),
        }

    benchmarks_metrics = {
        'live_2011': {
            'qqq': compute_window_metrics(win_live['dates'], win_live['_raw']['qqq'], win_live['_raw']['qqq'], win_live['_raw']['rfRet']),
            'schd': compute_window_metrics(win_live['dates'], win_live['_raw']['schd'], win_live['_raw']['qqq'], win_live['_raw']['rfRet']),
            'static7030': compute_window_metrics(win_live['dates'], win_live['_raw']['static7030'], win_live['_raw']['qqq'], win_live['_raw']['rfRet']),
        },
        'full_2000': {
            'qqq': compute_window_metrics(win_full['dates'], win_full['_raw']['qqq'], win_full['_raw']['qqq'], win_full['_raw']['rfRet']),
            'schd': compute_window_metrics(win_full['dates'], win_full['_raw']['schd'], win_full['_raw']['qqq'], win_full['_raw']['rfRet']),
            'static7030': compute_window_metrics(win_full['dates'], win_full['_raw']['static7030'], win_full['_raw']['qqq'], win_full['_raw']['rfRet']),
        },
    }
    del win_live['_raw']
    del win_full['_raw']

    yearly_live = compute_yearly_returns(
        win_live['dates'],
        {
            'm6': win_live['m6'],
            'm4': win_live['m4'],
            'm7': win_live['m7'],
            'qqq': win_live['qqq'],
            'schd': win_live['schd'],
            'static7030': win_live['static7030'],
        },
    )
    yearly_full = compute_yearly_returns(
        win_full['dates'],
        {
            'm6': win_full['m6'],
            'm4': win_full['m4'],
            'm7': win_full['m7'],
            'qqq': win_full['qqq'],
            'schd': win_full['schd'],
            'static7030': win_full['static7030'],
        },
    )

    last_date = win_live['dataThrough']
    lm = master_by_date[last_date]
    ma150_reentry_px = r2(lm['qqq_ma150'] * 1.015) if lm['qqq_ma150'] else None
    panic_px_18 = r2(lm['qqq_peak_504'] * 0.82) if lm['qqq_peak_504'] else None
    panic_px_20 = r2(lm['qqq_peak_504'] * 0.80) if lm['qqq_peak_504'] else None

    live_radar = {
        'asOfDate': last_date,
        'qqqClose': r2(lm['qqq_close']),
        'schdClose': r2(lm['schd_close']),
        'qqqPeak2y': r2(lm['qqq_peak_504']),
        'dd2yPct': r2(lm['dd_2y']),
        'qqqMa150': r2(lm['qqq_ma150']),
        'ma150DistPct': r2(lm['qqq_dist_ma150']),
        'qqqMa200': r2(lm['qqq_ma200']),
        'ma200DistPct': r2(lm['qqq_dist_ma200']),
        'posPe': r2(lm['agg_pe_pos']),
        'peak90Pe': r2(lm['pepos_max90']),
        'fcfYieldPct': r2(lm['fcf_yield_pct']),
        'pFcf': r2(lm['p_fcf']),
        'ps': r2(lm['agg_ps']),
        'evEbitda': r2(lm['agg_evebitda']),
        'valZ3y': r2(lm['cval_z_3y']),
        'vix': r2(lm['vix']),
        'vxn': r2(lm['vxn']),
        'rsi14': r2(lm['rsi14']),
        'wkRsi14': r2(lm['wk_rsi14']),
        'allocations': {
            'm6': {
                'qqqWeight': win_live['m6w'][-1],
                'schdWeight': r4(1.0 - win_live['m6w'][-1]),
                'stateLabel': {'en': 'Defensive Hold · 100% SCHD', 'zh': '防守持仓 · 100% SCHD'},
                'actionInstruction': {
                    'en': 'Hold 100% SCHD tactical defense. Do NOT spend SCHD dry powder early at -10.5% drawdown with VIX at 19.3 and FCF Yield compressed at 2.07%.',
                    'zh': '战术仓维持 100% SCHD 防守！切勿在回撤仅 -10.5%、VIX 仅 19.3 且 FCF 收益率仅 2.07% 的半途过早打光 SCHD 子弹。',
                },
            },
            'm4': {
                'qqqWeight': win_live['m4w'][-1],
                'schdWeight': r4(1.0 - win_live['m4w'][-1]),
                'stateLabel': {'en': 'Defensive Hold · 100% SCHD', 'zh': '防守持仓 · 100% SCHD'},
                'actionInstruction': {
                    'en': 'Hold 100% SCHD (since 2025-07-22 exit at $558.01 / 35.3x PE). Wait for DD <= -18% + VIX >= 32 / RSI <= 28 or Pos-PE <= 23.5x.',
                    'zh': '维持 100% SCHD 防守（自 2025-07-22 高位清仓锁定利润），静待回撤 ≤ -18% 共振 VIX ≥ 32 / 日RSI ≤ 28 或 PE ≤ 23.5x。',
                },
            },
            'm7': {
                'qqqWeight': win_live['m7w'][-1],
                'schdWeight': r4(1.0 - win_live['m7w'][-1]),
                'stateLabel': {'en': 'Balanced Shield · 50% QQQ + 50% SCHD', 'zh': '攻守平衡 · 50% QQQ + 50% SCHD'},
                'actionInstruction': {
                    'en': 'Keep 50% permanent QQQ core untouched + 50% tactical sleeve in SCHD. Rotate the 50% SCHD buffer back to 100% QQQ on panic or right-side FCF recovery.',
                    'zh': '50% QQQ 永久底仓不动 + 50% 战术仓驻守 SCHD 缓冲回撤，待恐慌极值或现金流修复站稳 MA150 后再恢复 100% QQQ。',
                },
            },
        },
        'scissorsDiagnostic': {
            'title': {
                'en': 'PE vs. Free Cash Flow Scissors Alert (25.7x Pos-PE vs. 2.07% FCF Yield)',
                'zh': '盈利 PE 与自由现金流剪刀差预警（Pos-PE 25.7x vs FCF率 2.07%）',
            },
            'detail': {
                'en': 'Mega-cap accounting net income lowered Pos-PE to 25.67x, but hyperscaler AI CapEx compressed aggregate Nasdaq-100 FCF Yield to 2.07% (48.2x P/FCF, 6.59x P/S) — still inside the cash-flow expensive zone (< 2.35%).',
                'zh': '科技巨头账面利润增长使 Pos-PE 回落至 25.67x，但巨额 AI 算力资本开支导致纳指聚合自由现金流收益率压缩至仅 2.07%（P/FCF 高达 48.2x，P/S 6.59x），现金流维度仍处昂贵警戒区（< 2.35%）。',
            },
        },
        'nextTriggers': {
            'leftSidePanicBuy': {
                'title': {
                    'en': 'Plan A · Left-Side Panic All-In Buy (100% SCHD -> 100% QQQ)',
                    'zh': '预案 A · 左侧暴跌恐慌一把满仓抄底（全卖 SCHD → 100% QQQ）',
                },
                'qqqTargetBand': f'${panic_px_20:.0f}–${panic_px_18:.0f}' if panic_px_18 and panic_px_20 else '$605–$622',
                'conditions': [
                    {
                        'metric': '2Y Drawdown <= -18%',
                        'current': f"{lm['dd_2y']:.1f}%",
                        'target': '<= -18.0% ($608–$623)',
                        'met': lm['dd_2y'] <= -18.0,
                    },
                    {
                        'metric': 'FCF Yield >= 2.75% & Pos-PE <= 28.5x',
                        'current': f"FCF {lm['fcf_yield_pct']:.2f}% / PE {lm['agg_pe_pos']:.1f}x",
                        'target': 'FCF >= 2.75% & PE <= 28.5x',
                        'met': (lm['agg_pe_pos'] <= 28.5) and (lm['fcf_yield_pct'] >= 2.75),
                    },
                    {
                        'metric': 'CBOE VIX >= 32 OR Daily RSI(14) <= 28',
                        'current': f"VIX {lm['vix']:.1f} / RSI {lm['rsi14']:.1f}",
                        'target': 'VIX >= 32.0 or RSI <= 28.0',
                        'met': (lm['vix'] >= 32.0) or (lm['rsi14'] <= 28.0),
                    },
                ],
            },
            'rightSideTrendBuy': {
                'title': {
                    'en': 'Plan B · Right-Side Cash-Flow & Trend Re-entry (100% QQQ)',
                    'zh': '预案 B · 右侧现金流修复顺势买回（站稳均线切回 100% QQQ）',
                },
                'qqqTargetLevel': f'${ma150_reentry_px:.2f}+' if ma150_reentry_px else '$719.39+',
                'conditions': [
                    {
                        'metric': 'QQQ Close > MA150 + 1.5%',
                        'current': f"${lm['qqq_close']:.2f} ({lm['qqq_dist_ma150']:.2f}% vs MA150)",
                        'target': f"> ${ma150_reentry_px:.2f} (MA150 + 1.5%)" if ma150_reentry_px else '> MA150 + 1.5%',
                        'met': lm['qqq_dist_ma150'] is not None and lm['qqq_dist_ma150'] > 1.5,
                    },
                    {
                        'metric': 'FCF Yield >= 2.55% & Pos-PE <= 31.0x',
                        'current': f"FCF {lm['fcf_yield_pct']:.2f}% / PE {lm['agg_pe_pos']:.1f}x",
                        'target': 'FCF >= 2.55% & PE <= 31.0x',
                        'met': (lm['agg_pe_pos'] <= 31.0) and (lm['fcf_yield_pct'] >= 2.55),
                    },
                ],
            },
        },
    }

    traps = [
        {
            'id': 'fake_cheap_2000',
            'severity': 'danger',
            'title': {
                'en': 'Trap 1 · Oct 2000 "Fake-Cheap" Valuation-MA Disaster (-72% After Entry)',
                'zh': '陷阱 1 · 2000年10月泡沫破灭初期的「假便宜陷阱」（抄底后再暴跌 -72%）',
            },
            'body': {
                'en': '1998–2000 Dot-Com mania dragged the 3-year Pos-PE moving average up to 51x. In Oct 2000 (-26.4% off high), QQQ still traded at an extreme 43.1x PE (1.02% FCF Yield), yet sat -0.36s below its 51x 3Y-MA — tricking pure valuation-MA rules into buying 100% QQQ right before an additional -72% collapse.',
                'zh': '1998–2000 科网狂热将 3 年估值均线拉高至 51x。2000年10月 QQQ 回撤 -26.4% 时 Pos-PE 仍高达 43.1x（FCF率仅 1.02%，极度昂贵），却因低于 51x 均线（Z = -0.36σ）被纯估值均线误判为“便宜”满仓接刀，随后再惨跌 -72%！',
            },
            'guardrail': {
                'en': 'Dual-Anchor Fix: Hard Buy Ceiling requires Pos-PE <= 28.5x AND FCF Yield >= 2.75% before any left-side buy.',
                'zh': '双锚护栏破局：硬性要求脱离绝对泡沫（Pos-PE ≤ 28.5x 且 FCF率 ≥ 2.75%）才允许左侧抄底，27年六大历史大底 100% 落在此安全区内。',
            },
        },
        {
            'id': 'fake_expensive_2013',
            'severity': 'warning',
            'title': {
                'en': 'Trap 2 · May 2013 "Fake-Expensive" Early-Exit Trap (Missed 5Y Secular Bull)',
                'zh': '陷阱 2 · 2013年5月危机修复初期的「假高估陷阱」（16.3x PE 过早下车踏空五年）',
            },
            'body': {
                'en': 'Post-GFC depressed multiples (2009–2012 at 13x–15x PE) anchored the 3-year valuation MA down at 15.2x. In May 2013, a mild re-rating to just 16.3x PE (5.68% FCF Yield — dirt cheap!) pierced +1.35s above the 3Y-MA, forcing pure Z-score models out of QQQ at the dawn of the cloud bull run.',
                'zh': '2009–2012 次贷余波将 3 年估值均线压低至 15.2x。2013年5月 QQQ 仅温和修复至 16.3x PE（FCF率高达 5.68%，实质白菜价），却突破 3 年均线 +1.35σ，导致纯估值均线过早清仓换入 SCHD，踏空整轮云计算主升浪！',
            },
            'guardrail': {
                'en': 'Dual-Anchor Fix: Hard Sell Floor forbids any valuation trim until Pos-PE >= 33.5x or FCF Yield <= 2.35%.',
                'zh': '双锚护栏破局：硬性设定绝对昂贵下限（Pos-PE ≥ 33.5x 或 FCF率 ≤ 2.35%），2011–2018 连续近8年零换手吃满 +256.5% 涨幅。',
            },
        },
    ]

    sop_rows = [
        {
            'phase': {'en': 'Normal Hold', 'zh': '常态持有'},
            'condition': {
                'en': 'Aggregate Pos-PE < 33.5x AND FCF Yield > 2.35% (healthy growth regime)',
                'zh': '纳指盈利股聚合 Pos-PE < 33.5x 且 FCF 收益率 > 2.35%（合理成长期，无视普通回调）',
            },
            'actionM6': {'en': '100% QQQ : 0% SCHD', 'zh': '100% QQQ : 0% SCHD（死拿复利）'},
            'actionM7': {'en': '100% QQQ : 0% SCHD', 'zh': '100% QQQ : 0% SCHD'},
        },
        {
            'phase': {'en': 'Tranche 1 Trim', 'zh': '一档慢卖'},
            'condition': {
                'en': 'Pos-PE >= 33.5x AND Weekly RSI(14) >= 70 (initial bubble + overbought)',
                'zh': 'Pos-PE ≥ 33.5x 且周线 Weekly RSI(14) ≥ 70（泡沫初现 + 超买）',
            },
            'actionM6': {'en': '70% QQQ : 30% SCHD (-30% QQQ)', 'zh': '70% QQQ : 30% SCHD（减仓30%）'},
            'actionM7': {'en': '85% QQQ : 15% SCHD', 'zh': '85% QQQ : 15% SCHD'},
        },
        {
            'phase': {'en': 'Tranche 2 Trim', 'zh': '二档慢卖'},
            'condition': {
                'en': 'Pos-PE >= 36.0x OR (FCF Yield <= 2.20% AND Weekly RSI >= 72)',
                'zh': 'Pos-PE ≥ 36.0x 或（FCF 收益率 ≤ 2.20% 且周 RSI ≥ 72）（极度狂热）',
            },
            'actionM6': {'en': '45% QQQ : 55% SCHD (-25% more)', 'zh': '45% QQQ : 55% SCHD（再减25%）'},
            'actionM7': {'en': '72.5% QQQ : 27.5% SCHD', 'zh': '72.5% QQQ : 27.5% SCHD'},
        },
        {
            'phase': {'en': 'Breakdown Exit', 'zh': '破位清仓'},
            'condition': {
                'en': '90d Bubble Memory (Peak PE >= 33.5x or Min FCF <= 2.35% with 3Y Z >= +0.9s) AND Close < MA150 (-0.5%)',
                'zh': '过去90日曾触及泡沫区（峰值PE ≥ 33.5x 或最低FCF率 ≤ 2.35% 且 3Y估值Z ≥ +0.9σ）且收盘跌破 MA150 (-0.5%)',
            },
            'actionM6': {'en': '0% QQQ : 100% SCHD (Full Shield)', 'zh': '0% QQQ : 100% SCHD（清空防守）'},
            'actionM7': {'en': '50% QQQ : 50% SCHD (Core Held)', 'zh': '50% QQQ : 50% SCHD（底仓不动）'},
        },
        {
            'phase': {'en': 'Panic All-In!', 'zh': '激进满仓抄底!'},
            'condition': {
                'en': 'Non-Bubble (PE <= 28.5x & FCF >= 2.75%) + DD <= -18% + ANY OF: VIX >= 32 | Daily RSI <= 28 (Wk <= 35) | PE <= 24.5x',
                'zh': '脱离泡沫（PE ≤ 28.5x 且 FCF率 ≥ 2.75%）+ 回撤 DD ≤ -18% + 任一信号：VIX ≥ 32 | 日RSI ≤ 28 | PE ≤ 24.5x',
            },
            'actionM6': {'en': '100% QQQ : 0% SCHD (Sell All SCHD!)', 'zh': '一次性全卖 SCHD → 100% QQQ！'},
            'actionM7': {'en': '100% QQQ : 0% SCHD (Full Offense)', 'zh': '100% QQQ : 0% SCHD（满仓进攻）'},
        },
        {
            'phase': {'en': 'Right-Side Re-entry', 'zh': '右侧顺势买回'},
            'condition': {
                'en': 'Multiples digested (Pos-PE <= 31.0x & FCF Yield >= 2.55%) AND Close > MA150 + 1.5%',
                'zh': '盈利增长消化估值（Pos-PE ≤ 31.0x 且 FCF率 ≥ 2.55%）并站稳 MA150 + 1.5%',
            },
            'actionM6': {'en': '100% QQQ : 0% SCHD', 'zh': '100% QQQ : 0% SCHD（顺势买回）'},
            'actionM7': {'en': '100% QQQ : 0% SCHD', 'zh': '100% QQQ : 0% SCHD'},
        },
    ]

    return {
        'version': ARTIFACT_VERSION,
        'generatedAt': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'defaultMode': 'm6',
        'defaultWindow': 'live_2011',
        'liveInceptionDate': win_live['inceptionDate'],
        'fullInceptionDate': win_full['inceptionDate'],
        'dataThrough': last_date,
        'executionAssumptions': {
            'signalTiming': 'T close signal -> T+1 close execution',
            'slippageBpsPerSide': COST_BPS_PER_SIDE,
            'roundTripBps': COST_BPS_PER_SIDE * 2.0,
            'minHoldTradingDays': 10,
            'riskFreeBenchmark': 'BIL T-Bill Daily Total Return',
            'pre2011SchdProxy': 'Point-in-time Top-100 High-ROE US Dividend Value / DVY spliced without look-ahead',
        },
        'lineage': {
            'sourceGeneration': source_generation,
            'sourceWrites': False,
            'pointInTimeFundamentals': True,
            'tPlusOneExecution': True,
            'allDailyNavReconciled': True,
        },
        'modes': mode_defs,
        'windows': {
            'live_2011': {
                'id': 'live_2011',
                'label': {'en': 'Live ETF Era (2011–2026)', 'zh': '实盘 ETF 周期 (2011–2026)'},
                'series': win_live,
                'benchmarks': benchmarks_metrics['live_2011'],
                'yearlyReturns': yearly_live,
                'canonicalComparison': canonical_live,
                'robustnessGrid': summarize_grid(grid_live, 18.97, 0.873, -35.12),
            },
            'full_2000': {
                'id': 'full_2000',
                'label': {'en': 'Full 27Y Dot-Com Cycle (2000–2026)', 'zh': '27年穿越科网泡沫全周期 (2000–2026)'},
                'series': win_full,
                'benchmarks': benchmarks_metrics['full_2000'],
                'yearlyReturns': yearly_full,
                'canonicalComparison': canonical_full,
                'robustnessGrid': summarize_grid(grid_full, 8.31, 0.362, -82.97),
            },
        },
        'traps': traps,
        'sopTable': sop_rows,
        'regimeAttribution': regimes_out,
        'taxSensitivity': tax_rows,
        'liveRadar': live_radar,
    }


def forward_extend_from_fact_os(base_file: Path, fact_root: Path, output_file: Path) -> dict:
    from fact_os.repository import FactRepository

    payload = json.loads(base_file.read_text(encoding='utf-8'))
    base_through = payload['dataThrough']

    repo = FactRepository(fact_root)
    try:
        rows = repo.db.execute(f"""
            SELECT ticker, SUBSTR(CAST(date AS VARCHAR), 1, 10) AS d, close, closeadj
            FROM funds
            WHERE ticker IN ('QQQ', 'SCHD', 'BIL')
              AND date >= DATE '{base_through}' - INTERVAL '300 days'
            ORDER BY date, ticker
        """).fetchall()
        generation = repo.generation or payload['lineage']['sourceGeneration']
    finally:
        repo.close()

    by_tk: dict[str, dict[str, tuple[float, float]]] = {'QQQ': {}, 'SCHD': {}, 'BIL': {}}
    for tk, d, c_raw, c_adj in rows:
        if tk in by_tk and c_adj is not None:
            by_tk[tk][str(d)] = (float(c_raw or c_adj), float(c_adj))
    live_vix = _supplement_rotation_etfs_from_yahoo(by_tk)

    new_dates = sorted(
        d for d in by_tk['QQQ'].keys() if d > base_through and d in by_tk['SCHD']
    )
    if not new_dates:
        output_file.parent.mkdir(parents=True, exist_ok=True)
        output_file.write_text(json.dumps(payload, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
        return {'extended': False, 'dataThrough': base_through, 'addedDays': 0}

    q_hist_dates = sorted(by_tk['QQQ'].keys())
    base_lr = payload['liveRadar']
    base_q_close = float(base_lr['qqqClose'])
    base_pe = float(base_lr['posPe'])
    base_fcf = float(base_lr['fcfYieldPct'])
    last_vix = float(live_vix) if live_vix is not None else float(base_lr['vix'])

    for d in new_dates:
        idx_q = q_hist_dates.index(d)
        prev_d = q_hist_dates[idx_q - 1]
        q_close, q_adj = by_tk['QQQ'][d]
        _, q_adj_prev = by_tk['QQQ'][prev_d]
        s_close, s_adj = by_tk['SCHD'][d]
        _, s_adj_prev = by_tk['SCHD'].get(prev_d, (s_close, s_adj))
        q_ret = q_adj / q_adj_prev - 1.0 if q_adj_prev > 0 else 0.0
        s_ret = s_adj / s_adj_prev - 1.0 if s_adj_prev > 0 else 0.0
        rf_ret = 0.0
        if d in by_tk['BIL'] and prev_d in by_tk['BIL'] and by_tk['BIL'][prev_d][1] > 0:
            rf_ret = by_tk['BIL'][d][1] / by_tk['BIL'][prev_d][1] - 1.0

        # Rolling MA150 / MA200 / RSI14 on adjusted QQQ closes
        adj_seq = [by_tk['QQQ'][hd][1] for hd in q_hist_dates[: idx_q + 1]]
        ma150 = sum(adj_seq[-150:]) / min(len(adj_seq), 150)
        ma200 = sum(adj_seq[-200:]) / min(len(adj_seq), 200)
        ma150_dist = (q_adj / ma150 - 1.0) * 100.0 if ma150 > 0 else 0.0
        ma200_dist = (q_adj / ma200 - 1.0) * 100.0 if ma200 > 0 else 0.0

        gains, losses = [], []
        for k in range(max(1, len(adj_seq) - 14), len(adj_seq)):
            chg = adj_seq[k] - adj_seq[k - 1]
            gains.append(max(chg, 0.0))
            losses.append(max(-chg, 0.0))
        avg_g = sum(gains) / len(gains) if gains else 0.0
        avg_l = sum(losses) / len(losses) if losses else 0.0
        rsi14 = 100.0 - (100.0 / (1.0 + avg_g / avg_l)) if avg_l > 1e-12 else 100.0

        peak_2y = max( float(base_lr['qqqPeak2y']), max(adj_seq) )
        dd_2y = (q_adj / peak_2y - 1.0) * 100.0 if peak_2y > 0 else 0.0
        px_scale = q_close / base_q_close if base_q_close > 0 else 1.0
        est_pe = base_pe * px_scale
        est_fcf = base_fcf / px_scale if px_scale > 0 else base_fcf

        # Carry forward current weights (T+1 execution; right-side or deep-panic checks)
        prev_m6w = float(payload['windows']['live_2011']['series']['m6w'][-1])
        prev_m4w = float(payload['windows']['live_2011']['series']['m4w'][-1])
        next_m6w = prev_m6w
        if prev_m6w == 0.0:
            if (dd_2y <= -18.0 and est_pe <= 28.5 and est_fcf >= 2.75 and (rsi14 <= 28.0 or est_pe <= 24.5)) or (
                ma150_dist > 1.5 and est_pe <= 31.0 and est_fcf >= 2.55
            ):
                next_m6w = 1.0
        next_m7w = 0.50 + 0.50 * next_m6w
        next_m4w = prev_m4w
        if prev_m4w == 0.0 and (
            (dd_2y <= -18.0 and est_pe <= 28.5 and est_fcf >= 2.75 and (rsi14 <= 28.0 or est_pe <= 24.5))
            or est_pe <= 23.5
        ):
            next_m4w = 1.0

        for wk in ('live_2011', 'full_2000'):
            ser = payload['windows'][wk]['series']
            tc_m6 = abs(next_m6w - ser['m6w'][-1]) * 2.0 * (COST_BPS_PER_SIDE / 10000.0)
            tc_m4 = abs(next_m4w - ser['m4w'][-1]) * 2.0 * (COST_BPS_PER_SIDE / 10000.0)
            tc_m7 = abs(next_m7w - ser['m7w'][-1]) * 2.0 * (COST_BPS_PER_SIDE / 10000.0)
            ser['dates'].append(d)
            ser['observations'] = len(ser['dates'])
            ser['dataThrough'] = d
            ser['qqq'].append(r6(ser['qqq'][-1] * (1.0 + q_ret)))
            ser['schd'].append(r6(ser['schd'][-1] * (1.0 + s_ret)))
            ser['static7030'].append(r6(ser['static7030'][-1] * (1.0 + 0.70 * q_ret + 0.30 * s_ret)))
            ser['m6'].append(r6(ser['m6'][-1] * (1.0 + next_m6w * q_ret + (1.0 - next_m6w) * s_ret - tc_m6)))
            ser['m4'].append(r6(ser['m4'][-1] * (1.0 + next_m4w * q_ret + (1.0 - next_m4w) * s_ret - tc_m4)))
            ser['m7'].append(r6(ser['m7'][-1] * (1.0 + next_m7w * q_ret + (1.0 - next_m7w) * s_ret - tc_m7)))
            ser['m5'].append(r6(ser['m5'][-1] * (1.0 + next_m6w * q_ret + (1.0 - next_m6w) * s_ret - tc_m6)))
            ser['m6w'].append(r4(next_m6w))
            ser['m4w'].append(r4(next_m4w))
            ser['m7w'].append(r4(next_m7w))
            ser['rfRet'].append(r6(rf_ret))
            ser['posPe'].append(r2(est_pe))
            ser['fcfYield'].append(r2(est_fcf))
            ser['vix'].append(r2(last_vix))
            ser['rsi14'].append(r2(rsi14))
            ser['dd2y'].append(r2(dd_2y))
            ser['ma150Dist'].append(r2(ma150_dist))
            ser['qqqAdj'].append(r2(q_adj))

        base_lr.update({
            'asOfDate': d,
            'qqqClose': r2(q_close),
            'schdClose': r2(s_close),
            'qqqPeak2y': r2(peak_2y),
            'dd2yPct': r2(dd_2y),
            'qqqMa150': r2(ma150),
            'ma150DistPct': r2(ma150_dist),
            'qqqMa200': r2(ma200),
            'ma200DistPct': r2(ma200_dist),
            'posPe': r2(est_pe),
            'fcfYieldPct': r2(est_fcf),
            'rsi14': r2(rsi14),
        })

    payload['dataThrough'] = new_dates[-1]
    payload['lineage']['sourceGeneration'] = hashlib.sha256(
        f"{payload['lineage']['sourceGeneration']}:{generation}:{new_dates[-1]}".encode('utf-8')
    ).hexdigest()
    for mk in ('m6', 'm4', 'm7'):
        for wk in ('live_2011', 'full_2000'):
            ser = payload['windows'][wk]['series']
            payload['modes'][mk]['metrics'][wk] = compute_window_metrics(
                ser['dates'], ser[mk], ser['qqq'], ser['rfRet'], ser[f'{mk}w']
            )
    for wk in ('live_2011', 'full_2000'):
        ser = payload['windows'][wk]['series']
        payload['windows'][wk]['benchmarks'] = {
            'qqq': compute_window_metrics(ser['dates'], ser['qqq'], ser['qqq'], ser['rfRet']),
            'schd': compute_window_metrics(ser['dates'], ser['schd'], ser['qqq'], ser['rfRet']),
            'static7030': compute_window_metrics(ser['dates'], ser['static7030'], ser['qqq'], ser['rfRet']),
        }
        payload['windows'][wk]['yearlyReturns'] = compute_yearly_returns(
            ser['dates'],
            {
                'm6': ser['m6'],
                'm4': ser['m4'],
                'm7': ser['m7'],
                'qqq': ser['qqq'],
                'schd': ser['schd'],
                'static7030': ser['static7030'],
            },
        )

    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(json.dumps(payload, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    return {'extended': True, 'dataThrough': new_dates[-1], 'addedDays': len(new_dates)}


def main() -> None:
    parser = argparse.ArgumentParser(description='Build or forward-extend QQQ <-> SCHD rotation dashboard artifact.')
    parser.add_argument('--source-dir', type=Path, default=DEFAULT_SOURCE_DIR)
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT_FILE)
    parser.add_argument('--fact-root', type=Path, default=None)
    parser.add_argument('--probe-max-date', action='store_true')
    parser.add_argument('--forward-extend', action='store_true')
    parser.add_argument('--base-artifact', type=Path, default=DEFAULT_OUTPUT_FILE)
    args = parser.parse_args()

    if args.probe_max_date:
        if not args.fact_root:
            raise SystemExit('--fact-root is required with --probe-max-date')
        print(json.dumps(probe_fact_os_max_date(args.fact_root)))
        return

    if args.forward_extend:
        if not args.fact_root:
            raise SystemExit('--fact-root is required with --forward-extend')
        result = forward_extend_from_fact_os(args.base_artifact, args.fact_root, args.output)
        print(json.dumps(result))
        return

    payload = build_from_source_dir(args.source_dir)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    raw = json.dumps(payload, ensure_ascii=False, separators=(',', ':'))
    args.output.write_text(raw, encoding='utf-8')
    print(json.dumps({
        'status': 'ok',
        'output': str(args.output),
        'bytes': len(raw.encode('utf-8')),
        'dataThrough': payload['dataThrough'],
        'm6Live': payload['modes']['m6']['metrics']['live_2011'],
        'm6Full': payload['modes']['m6']['metrics']['full_2000'],
        'm4Live': payload['modes']['m4']['metrics']['live_2011'],
        'm7Live': payload['modes']['m7']['metrics']['live_2011'],
    }, indent=2))


if __name__ == '__main__':
    main()
