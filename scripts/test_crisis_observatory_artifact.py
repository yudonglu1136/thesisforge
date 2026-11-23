"""Pytest verification suite for Crisis Observatory artifact & BSM/OPRA pricing engine."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT / "scripts" / "build-crisis-observatory-artifact.py"
ARTIFACT_PATH = ROOT / "server" / "config" / "crisis-observatory-dashboard.json"


def _load_builder():
    spec = importlib.util.spec_from_file_location("crisis_observatory_builder", SCRIPT_PATH)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_bsm_put_call_parity_and_zero_cost_collar():
    mod = _load_builder()
    coeffs = [14.451937, 3.633397, -2.033957, 0.944197]
    spot = 749.35
    kp = round(spot * 0.90, 4)
    tau = 90.0 / 365.25
    r = 0.042
    q = 0.006
    vxn = 21.21

    put_sig = mod.eval_skew_iv(spot, kp, tau, r, q, vxn, coeffs)
    put_mid = mod.bsm_price(spot, kp, tau, r, q, put_sig, "put")
    call_mid = mod.bsm_price(spot, kp, tau, r, q, put_sig, "call")
    # Continuous dividend BSM put-call parity: C - P = S*exp(-q*T) - K*exp(-r*T)
    lhs = call_mid - put_mid
    rhs = spot * __import__("math").exp(-q * tau) - kp * __import__("math").exp(-r * tau)
    assert abs(lhs - rhs) < 1e-6

    put_ask = put_mid * (1.0 + mod.DEFAULT_SLIPPAGE)
    kc = mod.solve_zero_cost_call_strike(spot, kp, tau, r, q, vxn, coeffs, mod.DEFAULT_SLIPPAGE)
    assert kc > spot * 1.03
    call_sig = mod.eval_skew_iv(spot, kc, tau, r, q, vxn, coeffs)
    call_bid = mod.bsm_price(spot, kc, tau, r, q, call_sig, "call") * (1.0 - mod.DEFAULT_SLIPPAGE)
    assert abs(call_bid - put_ask) < 1e-3


def test_artifact_matches_audited_2026_11_20_benchmarks():
    assert ARTIFACT_PATH.exists(), "crisis-observatory-dashboard.json must exist"
    raw = ARTIFACT_PATH.read_text(encoding="utf-8")
    assert chr(126) not in raw
    for banned in ("FactOS", "FACT OS", "fact_os", "DuckDB", "Sharadar", "SQLite"):
        assert banned not in raw

    doc = json.loads(raw)
    assert doc["as_of_date"] == "2026-11-20"
    assert doc["default_strategy_id"] == "U1_PureOptions"
    for forbidden in ("U4_DualEngine", "T-Bill", "slow_bear_shield", "慢熊盾", "美债慢熊盾", "短债"):
        assert forbidden not in raw, f"Forbidden T-Bill/U4 term found in artifact: {forbidden}"

    snap = doc["live_market_snapshot"]
    assert snap["qqq_close"] == 608.45
    assert snap["running_ath"] == 759.66
    assert snap["dd_from_ath_pct"] == -19.90
    assert snap["vix"] == 35.89
    assert snap["vix3m"] == 30.94
    assert snap["vix_vix3m_ratio"] == 1.160
    assert snap["vxn"] == 45.25
    assert snap["raw_crisis_score"] == 6

    lights = doc["six_crisis_lights"]
    assert len(lights) == 6
    assert all(item["lit"] is True for item in lights)

    ad = doc["ad_line_signal"]
    assert ad["below_50ma"] is True
    assert ad["ad_line"] == 216528.0
    assert ad["ad_sma50"] == 217785.0
    assert ad["days_below_50ma"] == 5

    sig = doc["live_signal_state"]
    assert sig["regime_code"] == "LOW_SPOT_FREEZE_NO_NEW_COLLAR"
    assert sig["target_equity_pct"] == 100.0
    assert sig["target_tbill_pct"] == 0.0
    assert "slow_bear_shield" not in sig
    assert sig["slot1_naked_put"]["status"] == "MONETIZED_STANDBY"
    assert sig["slot2_collar"]["status"] == "FROZEN_BELOW_ATH5"
    assert len(sig["gate_checklist"]) == 5
    assert all(g.get("reading") and g.get("current_value") for g in sig["gate_checklist"])

    smap = {s["id"]: s for s in doc["strategies_summary"]}
    assert "U4_DualEngine" not in smap
    assert list(smap.keys()) == [
        "U1_PureOptions",
        "B1c_PureAD",
        "D2_SixLights",
        "H2_G4_PriceGate",
        "BH_Pure_QQQ",
    ]
    assert abs(smap["U1_PureOptions"]["end_nav"] - 1454617.86) <= 0.02
    assert abs(smap["U1_PureOptions"]["net_alpha_usd"] - 166313.09) <= 0.02
    assert smap["U1_PureOptions"]["cagr_pct"] == 18.17
    assert smap["U1_PureOptions"]["sharpe"] == 0.810
    assert abs(smap["B1c_PureAD"]["end_nav"] - 1453135.67) <= 0.02
    assert abs(smap["D2_SixLights"]["end_nav"] - 1442693.31) <= 0.02
    assert abs(smap["H2_G4_PriceGate"]["end_nav"] - 1380701.67) <= 0.02
    assert abs(smap["BH_Pure_QQQ"]["end_nav"] - 1288304.77) <= 0.02


def test_crisis_windows_and_4factor_convexity_identity():
    doc = json.loads(ARTIFACT_PATH.read_text(encoding="utf-8"))
    win_ids = [w["id"] for w in doc["crisis_windows"]]
    assert win_ids == [
        "2015-08",
        "2018-Q4",
        "2020-03",
        "2022",
        "2024-08",
        "2025-04",
        "2026-08_11_LIVE",
    ]
    live_win = doc["crisis_windows"][-1]
    assert live_win["is_live"] is True
    assert live_win["u1_mdd"] == -17.54
    assert live_win["qqq_mdd"] == -19.90
    assert abs(live_win["harvested_usd"] - 35737.07) <= 0.05
    assert abs(live_win["harvested_usd_u1"] - 35737.07) <= 0.05
    assert doc["shield_events"] == []

    for sid, ledger in doc["trade_ledgers_by_strategy"].items():
        assert len(ledger) > 0, sid
        for tr in ledger:
            decomp_sum = tr["delta_usd"] + tr["gamma_usd"] + tr["vega_usd"] + tr["theta_slip_usd"]
            assert abs(decomp_sum - tr["net_pnl_usd"]) <= 0.05
