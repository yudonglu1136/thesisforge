#!/usr/bin/env python3
"""Hybrid 3-Tier Real-First Historical QQQ Option Chain Store (2015-2026).

Pricing priority (zero look-ahead, T EOD signal -> T+1 Close execution):
  1. Tier 1 (`real_opra`): Philipp Dubach OPRA archive (2015-01-02 -> 2025-12-15,
     9.89M real 4:00 PM ET Bid/Ask + IV + Delta + OI quotes).
     Execution fill uses realistic IBKR Limit (Mid +/- 0.35 * HalfSpread +/- $0.0065/sh;
     strict $0.00 floor if Bid == 0).
  2. Tier 2 (`real_polygon`): Polygon EOD option quotes (`options_normalized.db`,
     2025-12-16 -> 2026-05-11, 244K real traded mid quotes). Applies +/-2.5% half-spread
     (Long Put / CC) or +/-3.0% (Short Put / WC) + $0.0065/sh around real EOD mid.
  3. Tier 3 (`bsm_fallback`): Calibrated OPRA-skew BSM simulation strictly for dates/contracts
     without real historical quotes (2026-05-12 -> 2026-11-24+ & <0.3% missing quotes).

Also supports recording every accessed real selection & contract trajectory so a compact
`< 1 MB` gzipped quote cache (`server/config/crisis-observatory-real-quotes.json.gz`) can be
loaded by Node.js (`server/crisisObservatoryM7.js`) for 100% penny parity on dynamic combos.
"""
from __future__ import annotations

import datetime
import gzip
import json
import math
import sqlite3
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd

DEFAULT_OPRA_PARQUET = Path(
    "/Users/yudonglu/Documents/gemini/qqq-options-backtest/output/"
    "dolthub_real_opra_backtest_20261124/data/qqq_option_chain_real_2015_2025.parquet"
)
DEFAULT_POLYGON_SQLITE = Path(
    "/Users/yudonglu/Documents/gemini/qqq-options-backtest/data/normalized/options_normalized.db"
)

OPT_SLIP_BSM = 0.025
OPT_SLIP_SP_BSM = 0.030
OPT_COMM_PER_SH = 0.0065
IBKR_LIMIT_FRAC = 0.35

# Compact integer source codes for compact JSON export
SRC_TO_CODE = {
    "real_opra": 1,
    "real_opra_interp": 2,
    "real_polygon": 3,
    "real_polygon_interp": 4,
    "bsm_fallback": 0,
}
CODE_TO_SRC = {v: k for k, v in SRC_TO_CODE.items()}


def _norm_cdf(x: float) -> float:
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def _bsm_px(S: float, K: float, T: float, r: float, q: float, sigma: float, opt_type: str) -> float:
    if T <= 1e-9 or sigma <= 1e-9:
        return max(0.0, K - S) if opt_type == "put" else max(0.0, S - K)
    st = sigma * math.sqrt(T)
    d1 = (math.log(max(S, 1e-9) / max(K, 1e-9)) + (r - q + 0.5 * sigma * sigma) * T) / st
    d2 = d1 - st
    df_q = math.exp(-q * T)
    df_r = math.exp(-r * T)
    if opt_type == "put":
        return max(0.0, K * df_r * _norm_cdf(-d2) - S * df_q * _norm_cdf(-d1))
    return max(0.0, S * df_q * _norm_cdf(d1) - K * df_r * _norm_cdf(d2))


def _bsm_delta(S: float, K: float, T: float, r: float, q: float, sigma: float, opt_type: str) -> float:
    if T <= 1e-9 or sigma <= 1e-9:
        if opt_type == "put":
            return -1.0 if S < K else 0.0
        return 1.0 if S > K else 0.0
    st = sigma * math.sqrt(T)
    d1 = (math.log(max(S, 1e-9) / max(K, 1e-9)) + (r - q + 0.5 * sigma * sigma) * T) / st
    df_q = math.exp(-q * T)
    if opt_type == "put":
        return -df_q * _norm_cdf(-d1)
    return df_q * _norm_cdf(d1)


def _solve_iv_from_mid(
    S: float, K: float, T: float, r: float, q: float, mid: float, opt_type: str
) -> float:
    if T <= 1e-9 or mid <= 1e-6:
        return 0.25
    intr = max(0.0, K - S) if opt_type == "put" else max(0.0, S - K)
    if mid <= intr + 1e-4:
        return 0.15
    lo, hi = 0.04, 2.50
    for _ in range(28):
        m = 0.5 * (lo + hi)
        px = _bsm_px(S, K, T, r, q, m, opt_type)
        if px < mid:
            lo = m
        else:
            hi = m
    return 0.5 * (lo + hi)


def exec_buy_price(bid: float, ask: float, mid: float, source: str, slip_bsm: float = OPT_SLIP_BSM) -> float:
    if source in ("real_opra", "real_opra_interp"):
        hs = 0.5 * max(0.0, ask - bid)
        return mid + IBKR_LIMIT_FRAC * hs + OPT_COMM_PER_SH
    # real_polygon or bsm_fallback (mid-only): apply half-spread + comm
    return mid * (1.0 + slip_bsm) + OPT_COMM_PER_SH


def exec_sell_price(bid: float, ask: float, mid: float, source: str, slip_bsm: float = OPT_SLIP_BSM) -> float:
    if source in ("real_opra", "real_opra_interp"):
        if bid <= 0.0:
            return 0.0
        hs = 0.5 * max(0.0, ask - bid)
        return max(0.0, mid - IBKR_LIMIT_FRAC * hs - OPT_COMM_PER_SH)
    if mid <= 0.0:
        return 0.0
    return max(0.0, mid * (1.0 - slip_bsm) - OPT_COMM_PER_SH)


def is_expiry_day(i: int, dt_objs: list[datetime.date], exp_dt: datetime.date) -> bool:
    if dt_objs[i] >= exp_dt:
        return True
    # Handle Saturday monthly expirations (e.g. 2015-01-17) where Friday is last trading day
    if i + 1 < len(dt_objs) and dt_objs[i + 1] > exp_dt and (exp_dt - dt_objs[i]).days <= 3:
        return True
    return False


class HybridRealOptionChainStore:
    """Fast in-memory 3-tier historical QQQ option chain (OPRA + Polygon + BSM fallback)."""

    def __init__(
        self,
        opra_parquet: Path = DEFAULT_OPRA_PARQUET,
        polygon_sqlite: Path = DEFAULT_POLYGON_SQLITE,
        include_polygon_2026: bool = True,
    ):
        # by_date[d][(opt_type, exp_str)] = (k_cents, bid, ask, iv, delta, oi, dte_int, tier_code)
        self.by_date: dict[str, dict[tuple[str, str], tuple[Any, ...]]] = {}
        # exp_meta[d][opt_type] = [(exp_str, dte_int, n_strikes, tot_oi, tier_code), ...]
        self.exp_meta: dict[str, dict[str, list[tuple[str, int, int, int, int]]]] = {}
        self.opra_date_min = ""
        self.opra_date_max = ""
        self.polygon_date_min = ""
        self.polygon_date_max = ""
        self.opra_days = 0
        self.polygon_days = 0

        # Recorder for Node.js compact export
        self._recording = False
        self._rec_contracts: dict[str, dict[str, list[Any]]] = {}
        self._rec_selections: dict[str, list[Any]] = {}

        if opra_parquet.exists():
            self._load_opra_parquet(opra_parquet)
        if include_polygon_2026 and polygon_sqlite.exists():
            self._load_polygon_2026(polygon_sqlite)

    def _load_opra_parquet(self, pq_path: Path) -> None:
        df = pd.read_parquet(pq_path)
        df = df[(df["ask"] > 0.0) & (df["bid"] >= 0.0) & (df["ask"] >= df["bid"])].copy()
        df["k_cents"] = np.round(df["strike"].values * 100.0).astype(np.int64)
        df.sort_values(["date", "type", "expiration", "k_cents"], inplace=True)

        dates = df["date"].values
        types = df["type"].values
        exps = df["expiration"].values
        dtes = df["dte"].values
        kc = df["k_cents"].values
        bids = df["bid"].values.astype(np.float64)
        asks = df["ask"].values.astype(np.float64)
        ivs = df["implied_volatility"].values.astype(np.float64)
        deltas = df["delta"].values.astype(np.float64)
        ois = df["open_interest"].values.astype(np.int64)

        n = len(df)
        if n > 0:
            self.opra_date_min = str(dates[0])
            self.opra_date_max = str(dates[-1])
        opra_date_set: set[str] = set()
        i = 0
        while i < n:
            d = str(dates[i])
            t = str(types[i])
            e = str(exps[i])
            j = i + 1
            while j < n and dates[j] == d and types[j] == t and exps[j] == e:
                j += 1
            opra_date_set.add(d)
            d_dict = self.by_date.setdefault(d, {})
            dte_val = int(dtes[i])
            oi_slice = ois[i:j]
            d_dict[(t, e)] = (
                kc[i:j],
                bids[i:j],
                asks[i:j],
                ivs[i:j],
                deltas[i:j],
                oi_slice,
                dte_val,
                1,  # real_opra
            )
            self.exp_meta.setdefault(d, {}).setdefault(t, []).append(
                (e, dte_val, j - i, int(oi_slice.sum()), 1)
            )
            i = j
        self.opra_days = len(opra_date_set)

    def _load_polygon_2026(self, db_path: Path) -> None:
        cutoff = self.opra_date_max or "2025-12-15"
        con = sqlite3.connect(str(db_path))
        try:
            df = pd.read_sql_query(
                """
                SELECT trade_date AS date, expiration, dte, type, strike, mid, volume
                FROM option_quotes
                WHERE trade_date > ? AND mid IS NOT NULL AND mid > 0
                """,
                con,
                params=(cutoff,),
            )
        finally:
            con.close()
        if df.empty:
            return
        df["k_cents"] = np.round(df["strike"].values * 100.0).astype(np.int64)
        df["volume"] = df["volume"].fillna(0).astype(np.int64)
        df.sort_values(["date", "type", "expiration", "k_cents"], inplace=True)

        dates = df["date"].values
        types = df["type"].values
        exps = df["expiration"].values
        dtes = df["dte"].values
        kc = df["k_cents"].values
        mids = df["mid"].values.astype(np.float64)
        vols = df["volume"].values.astype(np.int64)

        n = len(df)
        self.polygon_date_min = str(dates[0])
        self.polygon_date_max = str(dates[-1])
        poly_dates: set[str] = set()
        i = 0
        while i < n:
            d = str(dates[i])
            t = str(types[i])
            e = str(exps[i])
            j = i + 1
            while j < n and dates[j] == d and types[j] == t and exps[j] == e:
                j += 1
            poly_dates.add(d)
            d_dict = self.by_date.setdefault(d, {})
            if (t, e) in d_dict:
                i = j
                continue
            dte_val = int(dtes[i])
            m_slice = mids[i:j]
            b_slice = m_slice * (1.0 - OPT_SLIP_BSM)
            a_slice = m_slice * (1.0 + OPT_SLIP_BSM)
            iv_slice = np.full(j - i, np.nan, dtype=np.float64)
            dl_slice = np.full(j - i, np.nan, dtype=np.float64)
            v_slice = vols[i:j]
            d_dict[(t, e)] = (
                kc[i:j],
                b_slice,
                a_slice,
                iv_slice,
                dl_slice,
                v_slice,
                dte_val,
                3,  # real_polygon
            )
            self.exp_meta.setdefault(d, {}).setdefault(t, []).append(
                (e, dte_val, j - i, int(v_slice.sum()), 3)
            )
            i = j
        self.polygon_days = len(poly_dates)

    def start_recording(self) -> None:
        self._recording = True
        self._rec_contracts = {}
        self._rec_selections = {}

    def stop_recording(self) -> None:
        self._recording = False

    def _rec_sel(self, sel_key: str, res: dict[str, Any] | None) -> None:
        if not self._recording or res is None:
            return
        src = str(res.get("source", "bsm_fallback"))
        if src == "bsm_fallback":
            return
        if sel_key not in self._rec_selections:
            iv_v = res.get("iv")
            dl_v = res.get("delta")
            self._rec_selections[sel_key] = [
                res["exp"],
                int(res["k_cents"]),
                round(float(res["bid"]), 4),
                round(float(res["ask"]), 4),
                round(float(iv_v), 4) if iv_v is not None and math.isfinite(iv_v) else None,
                round(float(dl_v), 4) if dl_v is not None and math.isfinite(dl_v) else None,
                SRC_TO_CODE.get(src, 1),
            ]
        # Also record the entry day quote in contract trajectory
        ckey = f"{res['opt_type'][0]}|{res['exp']}|{int(res['k_cents'])}"
        cmap = self._rec_contracts.setdefault(ckey, {})
        d = res["date"]
        if d not in cmap:
            iv_v = res.get("iv")
            dl_v = res.get("delta")
            cmap[d] = [
                round(float(res["bid"]), 4),
                round(float(res["ask"]), 4),
                round(float(iv_v), 4) if iv_v is not None and math.isfinite(iv_v) else None,
                round(float(dl_v), 4) if dl_v is not None and math.isfinite(dl_v) else None,
                SRC_TO_CODE.get(src, 1),
            ]

    def _rec_quote(
        self,
        d: str,
        opt_type: str,
        exp_str: str,
        k_cents: int,
        bid: float,
        ask: float,
        iv: float,
        delta: float,
        src: str,
    ) -> None:
        if not self._recording or src == "bsm_fallback":
            return
        ckey = f"{opt_type[0]}|{exp_str}|{int(k_cents)}"
        cmap = self._rec_contracts.setdefault(ckey, {})
        if d not in cmap:
            cmap[d] = [
                round(float(bid), 4),
                round(float(ask), 4),
                round(float(iv), 4) if math.isfinite(iv) else None,
                round(float(delta), 4) if math.isfinite(delta) else None,
                SRC_TO_CODE.get(src, 1),
            ]

    def export_recorded_cache(self, out_path: Path) -> dict[str, Any]:
        payload = {
            "version": "real-quotes-v1",
            "opra_range": [self.opra_date_min, self.opra_date_max],
            "opra_days": self.opra_days,
            "polygon_range": [self.polygon_date_min, self.polygon_date_max],
            "polygon_days": self.polygon_days,
            "src_codes": CODE_TO_SRC,
            "selections": self._rec_selections,
            "contracts": self._rec_contracts,
        }
        raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with gzip.open(out_path, "wb", compresslevel=9) as fh:
            fh.write(raw)
        return {
            "selections": len(self._rec_selections),
            "contracts": len(self._rec_contracts),
            "contract_day_quotes": sum(len(v) for v in self._rec_contracts.values()),
            "raw_kb": round(len(raw) / 1024.0, 1),
            "gz_kb": round(out_path.stat().st_size / 1024.0, 1),
        }

    def has_real_date(self, d: str) -> bool:
        return d in self.by_date

    def _pick_expiry(
        self, d: str, opt_type: str, target_dte: int, lo_dte: int, hi_dte: int, min_strikes: int = 3
    ) -> tuple[str, int, int] | None:
        metas = self.exp_meta.get(d, {}).get(opt_type)
        if not metas:
            return None
        cands = [m for m in metas if lo_dte <= m[1] <= hi_dte and m[2] >= min_strikes]
        if not cands:
            cands = [
                m
                for m in metas
                if max(3, lo_dte - 12) <= m[1] <= hi_dte + 20 and m[2] >= 2
            ]
        if not cands:
            return None
        min_dist = min(abs(m[1] - target_dte) for m in cands)
        tol = 5 if target_dte >= 40 else 3
        near = [m for m in cands if abs(m[1] - target_dte) <= min_dist + tol]
        near.sort(key=lambda m: (-m[3], abs(m[1] - target_dte)))
        return near[0][0], near[0][1], near[0][4]

    def select_put_contract(
        self,
        d: str,
        spot: float,
        target_dte: int,
        moneyness: float,
        lo_dte: int,
        hi_dte: int,
        r_cur: float = 0.03,
        q_cur: float = 0.006,
        require_bid: float = 0.0,
        rec_tag: str | None = None,
    ) -> dict[str, Any] | None:
        picked = self._pick_expiry(d, "put", target_dte, lo_dte, hi_dte, min_strikes=3)
        if picked is None:
            return None
        exp_str, dte_val, tier_code = picked
        k_arr, b_arr, a_arr, iv_arr, dl_arr, oi_arr, _, _ = self.by_date[d][("put", exp_str)]
        target_kc = int(round(spot * moneyness * 100.0))
        if require_bid > 0.0:
            valid = np.where((b_arr >= require_bid) & (a_arr > 0.0))[0]
            if len(valid) == 0:
                return None
            idx = int(valid[int(np.argmin(np.abs(k_arr[valid] - target_kc)))])
        else:
            idx = int(np.argmin(np.abs(k_arr - target_kc)))
        strike = float(k_arr[idx]) / 100.0
        if abs(strike - spot * moneyness) / max(spot * moneyness, 1.0) > 0.05:
            return None
        bid = float(b_arr[idx])
        ask = float(a_arr[idx])
        mid = 0.5 * (bid + ask)
        intr = max(0.0, strike - spot)
        if tier_code == 3 and (mid < intr * 0.90 or mid > spot):
            return None
        iv = float(iv_arr[idx])
        dl = float(dl_arr[idx])
        t_yr = max(1, dte_val) / 365.0
        if not math.isfinite(iv) or iv < 0.02 or iv > 3.0:
            iv = _solve_iv_from_mid(spot, strike, t_yr, r_cur, q_cur, mid, "put")
        if not math.isfinite(dl):
            dl = _bsm_delta(spot, strike, t_yr, r_cur, q_cur, iv, "put")
        src = "real_opra" if tier_code == 1 else "real_polygon"
        res = {
            "date": d,
            "opt_type": "put",
            "exp": exp_str,
            "exp_dt": datetime.date.fromisoformat(exp_str),
            "dte": dte_val,
            "strike": strike,
            "k_cents": int(k_arr[idx]),
            "bid": bid,
            "ask": ask,
            "mid": mid,
            "iv": iv,
            "delta": dl,
            "oi": int(oi_arr[idx]),
            "source": src,
        }
        if rec_tag:
            self._rec_sel(f"{d}|{rec_tag}", res)
        return res

    def select_call_contract_delta(
        self,
        d: str,
        spot: float,
        target_dte: int,
        target_delta: float,
        min_strike: float,
        lo_dte: int = 17,
        hi_dte: int = 38,
        r_cur: float = 0.03,
        q_cur: float = 0.006,
        rec_tag: str | None = None,
    ) -> dict[str, Any] | None:
        picked = self._pick_expiry(d, "call", target_dte, lo_dte, hi_dte, min_strikes=3)
        if picked is None:
            return None
        exp_str, dte_val, tier_code = picked
        k_arr, b_arr, a_arr, iv_arr, dl_arr, oi_arr, _, _ = self.by_date[d][("call", exp_str)]
        min_kc = int(math.ceil(min_strike * 100.0))
        t_yr = max(1, dte_val) / 365.0

        # If Polygon tier (no precomputed delta), compute deltas for candidate strikes >= min_kc
        cand_idx = np.where((k_arr >= min_kc) & (b_arr >= 0.05) & (a_arr >= b_arr))[0]
        if len(cand_idx) == 0:
            return None
        best_idx = -1
        best_dist = 999.0
        best_iv = 0.25
        best_dl = target_delta
        for idx in cand_idx:
            k_val = float(k_arr[idx]) / 100.0
            if k_val > max(min_strike * 1.25, spot * 1.35):
                break
            mid = 0.5 * (float(b_arr[idx]) + float(a_arr[idx]))
            iv = float(iv_arr[idx])
            dl = float(dl_arr[idx])
            if not math.isfinite(iv) or iv < 0.02 or iv > 3.0:
                iv = _solve_iv_from_mid(spot, k_val, t_yr, r_cur, q_cur, mid, "call")
            if not math.isfinite(dl) or dl <= 0.005 or dl >= 0.90:
                dl = _bsm_delta(spot, k_val, t_yr, r_cur, q_cur, iv, "call")
            if dl < 0.01 or dl > 0.70:
                continue
            dist = abs(dl - target_delta)
            if dist < best_dist:
                best_dist = dist
                best_idx = int(idx)
                best_iv = iv
                best_dl = dl
        if best_idx < 0:
            return None
        strike = float(k_arr[best_idx]) / 100.0
        bid = float(b_arr[best_idx])
        ask = float(a_arr[best_idx])
        mid = 0.5 * (bid + ask)
        src = "real_opra" if tier_code == 1 else "real_polygon"
        res = {
            "date": d,
            "opt_type": "call",
            "exp": exp_str,
            "exp_dt": datetime.date.fromisoformat(exp_str),
            "dte": dte_val,
            "strike": strike,
            "k_cents": int(k_arr[best_idx]),
            "bid": bid,
            "ask": ask,
            "mid": mid,
            "iv": best_iv,
            "delta": best_dl,
            "oi": int(oi_arr[best_idx]),
            "source": src,
        }
        if rec_tag:
            self._rec_sel(f"{d}|{rec_tag}", res)
        return res

    def select_call_contract_strike(
        self,
        d: str,
        spot: float,
        target_dte: int,
        min_strike: float,
        lo_dte: int,
        hi_dte: int,
        r_cur: float = 0.03,
        q_cur: float = 0.006,
        rec_tag: str | None = None,
    ) -> dict[str, Any] | None:
        picked = self._pick_expiry(d, "call", target_dte, lo_dte, hi_dte, min_strikes=2)
        if picked is None:
            return None
        exp_str, dte_val, tier_code = picked
        k_arr, b_arr, a_arr, iv_arr, dl_arr, oi_arr, _, _ = self.by_date[d][("call", exp_str)]
        min_kc = int(math.ceil(min_strike * 100.0))
        valid = np.where((k_arr >= min_kc) & (b_arr >= 0.05) & (a_arr >= b_arr))[0]
        if len(valid) == 0:
            return None
        idx = int(valid[0])
        strike = float(k_arr[idx]) / 100.0
        if (strike - min_strike) / max(min_strike, 1.0) > 0.06:
            return None
        bid = float(b_arr[idx])
        ask = float(a_arr[idx])
        mid = 0.5 * (bid + ask)
        t_yr = max(1, dte_val) / 365.0
        iv = float(iv_arr[idx])
        dl = float(dl_arr[idx])
        if not math.isfinite(iv) or iv < 0.02 or iv > 3.0:
            iv = _solve_iv_from_mid(spot, strike, t_yr, r_cur, q_cur, mid, "call")
        if not math.isfinite(dl):
            dl = _bsm_delta(spot, strike, t_yr, r_cur, q_cur, iv, "call")
        src = "real_opra" if tier_code == 1 else "real_polygon"
        res = {
            "date": d,
            "opt_type": "call",
            "exp": exp_str,
            "exp_dt": datetime.date.fromisoformat(exp_str),
            "dte": dte_val,
            "strike": strike,
            "k_cents": int(k_arr[idx]),
            "bid": bid,
            "ask": ask,
            "mid": mid,
            "iv": iv,
            "delta": dl,
            "oi": int(oi_arr[idx]),
            "source": src,
        }
        if rec_tag:
            self._rec_sel(f"{d}|{rec_tag}", res)
        return res

    def select_call_contract_for_bid(
        self,
        d: str,
        spot: float,
        target_dte: int,
        target_bid: float,
        min_strike: float,
        lo_dte: int,
        hi_dte: int,
        r_cur: float = 0.03,
        q_cur: float = 0.006,
        exp_override: str | None = None,
        rec_tag: str | None = None,
    ) -> dict[str, Any] | None:
        if exp_override is not None and ("call", exp_override) in self.by_date.get(d, {}):
            entry = self.by_date[d][("call", exp_override)]
            exp_str, dte_val, tier_code = exp_override, int(entry[6]), int(entry[7])
        else:
            picked = self._pick_expiry(d, "call", target_dte, lo_dte, hi_dte, min_strikes=3)
            if picked is None:
                return None
            exp_str, dte_val, tier_code = picked
        k_arr, b_arr, a_arr, iv_arr, dl_arr, oi_arr, _, _ = self.by_date[d][("call", exp_str)]
        src = "real_opra" if tier_code == 1 else "real_polygon"
        min_kc = int(math.ceil(min_strike * 100.0))
        valid = np.where((k_arr >= min_kc) & (b_arr >= 0.05) & (a_arr >= b_arr))[0]
        if len(valid) == 0:
            return None
        # Highest strike whose realistic sell price >= target_bid
        chosen = -1
        for idx in valid:
            b_v = float(b_arr[idx])
            a_v = float(a_arr[idx])
            m_v = 0.5 * (b_v + a_v)
            sell_px = exec_sell_price(b_v, a_v, m_v, src)
            if sell_px >= target_bid:
                chosen = int(idx)
        if chosen < 0:
            return None
        strike = float(k_arr[chosen]) / 100.0
        bid = float(b_arr[chosen])
        ask = float(a_arr[chosen])
        mid = 0.5 * (bid + ask)
        t_yr = max(1, dte_val) / 365.0
        iv = float(iv_arr[chosen])
        dl = float(dl_arr[chosen])
        if not math.isfinite(iv) or iv < 0.02 or iv > 3.0:
            iv = _solve_iv_from_mid(spot, strike, t_yr, r_cur, q_cur, mid, "call")
        if not math.isfinite(dl):
            dl = _bsm_delta(spot, strike, t_yr, r_cur, q_cur, iv, "call")
        res = {
            "date": d,
            "opt_type": "call",
            "exp": exp_str,
            "exp_dt": datetime.date.fromisoformat(exp_str),
            "dte": dte_val,
            "strike": strike,
            "k_cents": int(k_arr[chosen]),
            "bid": bid,
            "ask": ask,
            "mid": mid,
            "iv": iv,
            "delta": dl,
            "oi": int(oi_arr[chosen]),
            "source": src,
        }
        if rec_tag:
            self._rec_sel(f"{d}|{rec_tag}", res)
        return res

    def lookup_contract(
        self,
        d: str,
        opt_type: str,
        exp_str: str,
        k_cents: int,
        spot: float,
        rem_days: int,
        r_cur: float,
        q_cur: float,
        vxn_cl: float,
        last_iv: float | None,
        coeffs: list[float],
        eval_skew_fn: Any,
        bsm_price_fn: Any,
        slip_bsm: float = OPT_SLIP_BSM,
    ) -> tuple[float, float, float, float, float, str]:
        """Return (bid, ask, mid, iv, delta, source) with 3-tier priority."""
        entry = self.by_date.get(d, {}).get((opt_type, exp_str))
        if entry is not None:
            k_arr, b_arr, a_arr, iv_arr, dl_arr, _, _, tier_code = entry
            base_src = "real_opra" if tier_code == 1 else "real_polygon"
            pos = int(np.searchsorted(k_arr, k_cents))
            t_yr = max(1, rem_days) / 365.0
            K = k_cents / 100.0
            if pos < len(k_arr) and int(k_arr[pos]) == k_cents:
                bid = float(b_arr[pos])
                ask = float(a_arr[pos])
                mid = 0.5 * (bid + ask)
                intr = max(0.0, K - spot) if opt_type == "put" else max(0.0, spot - K)
                if tier_code == 1 or (mid >= intr * 0.90 and mid <= spot):
                    iv = float(iv_arr[pos])
                    dl = float(dl_arr[pos])
                    if not math.isfinite(iv) or iv < 0.02 or iv > 3.0:
                        iv = _solve_iv_from_mid(spot, K, t_yr, r_cur, q_cur, mid, opt_type)
                    if not math.isfinite(dl):
                        dl = _bsm_delta(spot, K, t_yr, r_cur, q_cur, iv, opt_type)
                    self._rec_quote(d, opt_type, exp_str, k_cents, bid, ask, iv, dl, base_src)
                    return bid, ask, mid, iv, dl, base_src
            # Bracket strike interpolation on same (date, type, expiration)
            if 0 < pos < len(k_arr):
                k0, k1 = int(k_arr[pos - 1]), int(k_arr[pos])
                if (k1 - k0) <= max(500, int(spot * 5)):
                    w = (k_cents - k0) / float(k1 - k0)
                    bid = float(b_arr[pos - 1] * (1.0 - w) + b_arr[pos] * w)
                    ask = max(bid, float(a_arr[pos - 1] * (1.0 - w) + a_arr[pos] * w))
                    mid = 0.5 * (bid + ask)
                    intr = max(0.0, K - spot) if opt_type == "put" else max(0.0, spot - K)
                    if tier_code == 1 or (mid >= intr * 0.90 and mid <= spot):
                        iv0, iv1 = float(iv_arr[pos - 1]), float(iv_arr[pos])
                        iv = (
                            iv0 * (1.0 - w) + iv1 * w
                            if math.isfinite(iv0) and math.isfinite(iv1)
                            else _solve_iv_from_mid(spot, K, t_yr, r_cur, q_cur, mid, opt_type)
                        )
                        dl0, dl1 = float(dl_arr[pos - 1]), float(dl_arr[pos])
                        dl = (
                            dl0 * (1.0 - w) + dl1 * w
                            if math.isfinite(dl0) and math.isfinite(dl1)
                            else _bsm_delta(spot, K, t_yr, r_cur, q_cur, iv, opt_type)
                        )
                        interp_src = f"{base_src}_interp"
                        self._rec_quote(d, opt_type, exp_str, k_cents, bid, ask, iv, dl, interp_src)
                        return bid, ask, mid, iv, dl, interp_src

        # Tier 3 fallback: calibrated OPRA-skew BSM (or last observed real IV on same contract)
        K = k_cents / 100.0
        t_rem = max(0, rem_days) / 365.0
        if last_iv is not None and math.isfinite(last_iv) and 0.04 <= last_iv <= 2.5 and d <= (self.opra_date_max or "2025-12-15"):
            sig = float(last_iv)
        else:
            sig = float(eval_skew_fn(spot, K, max(t_rem, 1.0 / 365.0), r_cur, q_cur, vxn_cl, coeffs))
        px = float(bsm_price_fn(spot, K, t_rem, r_cur, q_cur, sig, opt_type))
        dl = _bsm_delta(spot, K, t_rem, r_cur, q_cur, sig, opt_type)
        bid = max(0.0, px * (1.0 - slip_bsm))
        ask = max(bid, px * (1.0 + slip_bsm))
        return bid, ask, px, sig, dl, "bsm_fallback"
