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
    assert doc["default_tp_mode"] == "layered_itm"
    assert doc["tp_mode"] == "layered_itm"
    assert set(doc["tp_modes"].keys()) == {"layered_itm", "standard_dual", "both_4x"}
    assert sig["regime_code"] == "VIX110_TP_TRIGGERED"
    assert sig["target_equity_pct"] == 100.0
    assert sig["target_tbill_pct"] == 0.0
    assert "slow_bear_shield" not in sig
    assert sig["slot1_naked_put"]["status"] == "TP_TRIGGERED_NEXT_OPEN"
    assert sig["slot1_naked_put"]["open_position"]["pending_tp"] is True
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
    assert abs(smap["U1_PureOptions"]["end_nav"] - 1654577.25) <= 0.50
    assert abs(smap["U1_PureOptions"]["net_alpha_usd"] - 366272.47) <= 0.50
    assert abs(smap["U1_PureOptions"]["final_shares"] - 2719.33) <= 0.10
    assert abs(smap["U1_PureOptions"]["bh_final_shares"] - 2117.35) <= 0.10
    assert abs(smap["U1_PureOptions"]["extra_shares_pct"] - 28.43) <= 0.05
    assert smap["U1_PureOptions"]["cagr_pct"] == 19.46
    assert smap["U1_PureOptions"]["max_dd_pct"] == -31.52
    assert smap["U1_PureOptions"]["sharpe"] == 0.859
    assert abs(smap["B1c_PureAD"]["end_nav"] - 1587800.99) <= 0.50
    assert abs(smap["D2_SixLights"]["end_nav"] - 1497620.82) <= 0.50
    assert abs(smap["H2_G4_PriceGate"]["end_nav"] - 1402250.68) <= 0.50
    assert abs(smap["BH_Pure_QQQ"]["end_nav"] - 1288304.78) <= 0.02

    # Verify alternate selectable TP & Covered-Call modes (12 mode bundles: 3 TP x 4 CC)
    assert len(doc["mode_bundles"]) == 12
    std_map = {s["id"]: s for s in doc["mode_bundles"]["standard_dual__cc_off"]["strategies_summary"]}
    assert abs(std_map["U1_PureOptions"]["end_nav"] - 1625377.79) <= 0.50
    assert doc["mode_bundles"]["standard_dual__cc_off"]["live_signal_state"]["regime_code"] == "LOW_SPOT_FREEZE_NO_NEW_COLLAR"
    d4x_map = {s["id"]: s for s in doc["mode_bundles"]["both_4x__cc_off"]["strategies_summary"]}
    assert abs(d4x_map["U1_PureOptions"]["end_nav"] - 1643122.56) <= 0.50
    assert abs(d4x_map["D2_SixLights"]["end_nav"] - 1531284.11) <= 0.50

    hv8_map = {s["id"]: s for s in doc["mode_bundles"]["layered_itm__cc_hv_8"]["strategies_summary"]}
    assert abs(hv8_map["U1_PureOptions"]["end_nav"] - 1708351.0) <= 1.0
    assert abs(hv8_map["U1_PureOptions"]["extra_shares_pct"] - 32.60) <= 0.05
    assert hv8_map["U1_PureOptions"]["cc_trades_count"] == 14
    assert hv8_map["U1_PureOptions"]["cc_assigned_count"] == 0

    hv9_map = {s["id"]: s for s in doc["mode_bundles"]["layered_itm__cc_hv_9"]["strategies_summary"]}
    assert abs(hv9_map["U1_PureOptions"]["end_nav"] - 1693978.0) <= 1.0
    assert abs(hv9_map["U1_PureOptions"]["extra_shares_pct"] - 31.49) <= 0.05
    assert hv9_map["U1_PureOptions"]["cc_trades_count"] == 14
    assert hv9_map["U1_PureOptions"]["cc_assigned_count"] == 0

    for sid in ("U1_PureOptions", "B1c_PureAD", "D2_SixLights", "H2_G4_PriceGate"):
        assert hv8_map[sid]["end_nav"] > hv9_map[sid]["end_nav"] > smap[sid]["end_nav"], sid

    al8_map = {s["id"]: s for s in doc["mode_bundles"]["layered_itm__cc_always_8"]["strategies_summary"]}
    assert abs(al8_map["U1_PureOptions"]["end_nav"] - 1643395.0) <= 1.0
    assert al8_map["U1_PureOptions"]["cc_trades_count"] == 51
    assert al8_map["U1_PureOptions"]["cc_assigned_count"] == 1


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
    win_2022 = next(w for w in doc["crisis_windows"] if w["id"] == "2022")
    assert win_2022["u1_mdd"] == -31.52
    assert win_2022["qqq_mdd"] == -35.12
    assert abs(win_2022["harvested_usd"] - 37675.29) <= 0.05

    live_win = doc["crisis_windows"][-1]
    assert live_win["is_live"] is True
    assert live_win["u1_mdd"] == -14.81
    assert live_win["qqq_mdd"] == -19.90
    assert abs(live_win["harvested_usd"] - 89916.08) <= 0.10
    assert abs(live_win["harvested_usd_u1"] - 89916.08) <= 0.10
    assert doc["shield_events"] == []

    for mode_id, mode_bundle in doc["tp_modes"].items():
        for sid, ledger in mode_bundle["trade_ledgers_by_strategy"].items():
            assert len(ledger) > 0, (mode_id, sid)
            for tr in ledger:
                decomp_sum = tr["delta_usd"] + tr["gamma_usd"] + tr["vega_usd"] + tr["theta_slip_usd"]
                assert abs(decomp_sum - tr["net_pnl_usd"]) <= 0.05
