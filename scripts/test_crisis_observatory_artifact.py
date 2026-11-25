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
    assert doc["default_strategy_id"] == "M7G_Graded"
    assert doc["default_put_otm"] == "otm15"
    assert doc["default_m7_tp_mode"] == "standard"
    assert doc["default_roll_mode"] == "120d_roll50"
    assert doc["default_m0_enabled"] is True
    assert doc["pricing_provenance"]["mode"] == "hybrid_real_first"
    assert doc["pricing_provenance"]["tier1_opra"]["trading_days"] == 2749
    assert doc["pricing_provenance"]["tier2_polygon"]["trading_days"] == 104
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
        "M7G_Graded",
        "M7_Ensemble",
        "U1_PureOptions",
        "B1c_PureAD",
        "D2_SixLights",
        "H2_G4_PriceGate",
        "NoPut_CallOnly",
        "BH_Pure_QQQ",
    ]
    # Real-OPRA #1 Default: M7G_Graded 120D->50D Roll (-15% OTM · STANDARD)
    assert smap["M7G_Graded"]["pricing_basis"] == "hybrid_real_opra_polygon_bsm"
    assert smap["M7G_Graded"]["real_trades_pct"] == 95.7
    assert smap["M7G_Graded"]["real_opra_trades_count"] == 44
    assert smap["M7G_Graded"]["real_polygon_trades_count"] == 1
    assert smap["M7G_Graded"]["sim_trades_count"] == 2
    assert abs(smap["M7G_Graded"]["end_nav"] - 1462057.97) <= 0.05
    assert smap["M7G_Graded"]["cagr_pct"] == 18.22
    assert smap["M7G_Graded"]["max_dd_pct"] == -29.20
    assert smap["M7G_Graded"]["calmar"] == 0.624
    assert smap["M7G_Graded"]["sharpe"] == 0.917
    assert smap["M7G_Graded"]["roll_50d_count"] == 33
    assert abs(smap["M7G_Graded"]["avg_roll_salvage_pct"] - 58.1) <= 0.2
    assert abs(smap["M7_Ensemble"]["end_nav"] - 1429844.86) <= 0.05
    assert len(doc["m7_bundles"]) == 16
    assert abs(doc["m7_bundles"]["otm15__standard__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1356201.32) <= 0.05
    assert abs(doc["m7_bundles"]["otm20__standard__120d_roll50__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1453499.45) <= 0.05
    assert abs(doc["m7_bundles"]["otm20__standard__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1289101.35) <= 0.05
    assert abs(doc["m7_bundles"]["otm15__itm_tp__120d_roll50__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1328138.56) <= 0.05
    assert abs(doc["m7_bundles"]["otm15__itm_tp__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1298625.21) <= 0.05
    assert abs(doc["m7_bundles"]["otm20__itm_tp__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1233832.27) <= 0.05

    # Legacy strategies on real OPRA+Polygon+BSM
    assert smap["U1_PureOptions"]["pricing_basis"] == "hybrid_real_opra_polygon_bsm"
    assert smap["U1_PureOptions"]["real_trades_pct"] == 93.9
    assert abs(smap["U1_PureOptions"]["end_nav"] - 1325413.01) <= 0.05
    assert smap["M7G_Graded"]["end_nav"] > smap["U1_PureOptions"]["end_nav"] + 130000.0
    assert smap["U1_PureOptions"]["cagr_pct"] == 17.25
    assert smap["U1_PureOptions"]["max_dd_pct"] == -33.24
    assert abs(smap["B1c_PureAD"]["end_nav"] - 1350441.37) <= 0.05
    assert abs(smap["D2_SixLights"]["end_nav"] - 1353954.68) <= 0.05
    assert abs(smap["H2_G4_PriceGate"]["end_nav"] - 1259365.40) <= 0.05
    assert abs(smap["BH_Pure_QQQ"]["end_nav"] - 1288304.78) <= 0.02

    # Verify alternate selectable TP & Covered-Call modes (120 mode bundles)
    assert len(doc["mode_bundles"]) == 120
    d35_map = {s["id"]: s for s in doc["mode_bundles"]["layered_itm__cc_d12_d35"]["strategies_summary"]}
    assert abs(d35_map["U1_PureOptions"]["end_nav"] - 1308724.93) <= 0.50
    assert abs(d35_map["NoPut_CallOnly"]["end_nav"] - 1270341.73) <= 0.50


def _unpack_rows(val):
    if isinstance(val, list):
        return val
    if isinstance(val, dict) and "_cols" in val and "_rows" in val:
        cols = val["_cols"]
        return [dict(zip(cols, r)) for r in val["_rows"]]
    return []


def test_third_engine_panic_put_wheel_3d_matrix():
    doc = json.loads(ARTIFACT_PATH.read_text(encoding="utf-8"))
    assert doc["default_sp_mode"] == "sp_off"
    assert doc["sp_mode"] == "sp_off"
    assert doc["default_wc_mode"] == "wc_reclaim_30d_d35"
    assert doc["wc_mode"] == "wc_reclaim_30d_d35"
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
    assert len(doc["mode_bundles"]) == 120

    # 1. Real-OPRA Engine 3 with default wc_reclaim_30d_d35 + cc_off
    cap10_rec = doc["mode_bundles"]["layered_itm__cc_off__sp_14d_cap10"]
    cap10_rec_u1 = next(s for s in cap10_rec["strategies_summary"] if s["id"] == "U1_PureOptions")
    cap10_rec_np = next(s for s in cap10_rec["strategies_summary"] if s["id"] == "NoPut_CallOnly")
    assert cap10_rec["wc_mode"] == "wc_reclaim_30d_d35"
    assert abs(cap10_rec_u1["end_nav"] - 1414477.26) <= 0.05
    assert cap10_rec_u1["max_dd_pct"] == -32.25
    assert cap10_rec_u1["real_trades_pct"] >= 95.0
    assert abs(cap10_rec_np["end_nav"] - 1374702.58) <= 0.05
    assert cap10_rec["live_sp_state"]["position_state"] == "wheel_assigned_wait_reclaim"
    assert cap10_rec["live_sp_state"]["min_next_wc_strike"] == 623.29

    # 2. 10D VIX Falling 20% Cap
    vixf_rec = doc["mode_bundles"]["layered_itm__cc_off__sp_10d_vixf"]
    vixf_rec_u1 = next(s for s in vixf_rec["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert abs(vixf_rec_u1["end_nav"] - 1393888.22) <= 0.05
    assert vixf_rec_u1["real_trades_pct"] >= 94.0

    # 3. 14D Unfiltered 20% Cap
    unf_rec = doc["mode_bundles"]["layered_itm__cc_off__sp_14d_unf"]
    unf_rec_u1 = next(s for s in unf_rec["strategies_summary"] if s["id"] == "U1_PureOptions")
    unf_rec_np = next(s for s in unf_rec["strategies_summary"] if s["id"] == "NoPut_CallOnly")
    assert abs(unf_rec_u1["end_nav"] - 1508962.73) <= 0.05
    assert abs(unf_rec_np["end_nav"] - 1466347.09) <= 0.05

    # 4. wc_reclaim_30d_d35 beats both compare modes on real OPRA too!
    cap10_30d = doc["mode_bundles"]["layered_itm__cc_off__sp_14d_cap10__wc_30d_c5s5"]
    cap10_30d_u1 = next(s for s in cap10_30d["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert abs(cap10_30d_u1["end_nav"] - 1404028.47) <= 0.05
    assert cap10_rec_u1["end_nav"] > cap10_30d_u1["end_nav"]

    cap10_14d = doc["mode_bundles"]["layered_itm__cc_off__sp_14d_cap10__wc_14d_c0s2"]
    cap10_14d_u1 = next(s for s in cap10_14d["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert abs(cap10_14d_u1["end_nav"] - 1383482.45) <= 0.05
    assert cap10_rec_u1["end_nav"] > cap10_14d_u1["end_nav"]


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
    assert win_2022["m7g_mdd"] == -29.20
    assert win_2022["u1_mdd"] == -33.24
    assert win_2022["qqq_mdd"] == -35.12
    assert abs(win_2022["harvested_usd"] - 18441.95) <= 0.05

    live_win = doc["crisis_windows"][-1]
    assert live_win["is_live"] is True
    assert live_win["m7g_mdd"] == -18.46
    assert live_win["u1_mdd"] == -14.78
    assert live_win["qqq_mdd"] == -19.90
    assert abs(live_win["harvested_usd_m7g"] - 18653.35) <= 0.10
    assert abs(live_win["harvested_usd"] - 74675.65) <= 0.10
    assert doc["shield_events"] == []

    for mode_key, mode_bundle in doc["mode_bundles"].items():
        for sid, raw_ledger in mode_bundle["trade_ledgers_by_strategy"].items():
            ledger = _unpack_rows(raw_ledger)
            if sid == "NoPut_CallOnly":
                assert len(ledger) == 0, (mode_key, sid)
                continue
            assert len(ledger) > 0, (mode_key, sid)
            for tr in ledger:
                decomp_sum = tr["delta_usd"] + tr["gamma_usd"] + tr["vega_usd"] + tr["theta_slip_usd"]
                assert abs(decomp_sum - tr["net_pnl_usd"]) <= 0.05
                assert tr.get("pricing_source") in ("real_opra", "real_polygon", "real_hybrid", "bsm_fallback")
