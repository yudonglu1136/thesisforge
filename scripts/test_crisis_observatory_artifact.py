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
    assert doc["default_roll_mode"] == "90d_hold"
    assert doc["default_m0_enabled"] is True
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
    assert abs(smap["M7G_Graded"]["end_nav"] - 1682250.03) <= 0.05
    assert smap["M7G_Graded"]["cagr_pct"] == 19.63
    assert smap["M7G_Graded"]["max_dd_pct"] == -28.02
    assert smap["M7G_Graded"]["calmar"] == 0.701
    assert smap["M7G_Graded"]["sharpe"] == 0.983
    assert abs(smap["M7_Ensemble"]["end_nav"] - 1676747.11) <= 0.05
    assert len(doc["m7_bundles"]) == 16
    assert abs(doc["m7_bundles"]["otm15__standard__120d_roll50__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1625935.17) <= 0.05
    assert doc["m7_bundles"]["otm15__standard__120d_roll50__m0on"]["summaries"]["M7G_Graded"]["roll_50d_count"] == 32
    assert abs(doc["m7_bundles"]["otm20__standard__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1856309.08) <= 0.05
    assert abs(doc["m7_bundles"]["otm20__standard__120d_roll50__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1823635.00) <= 0.05
    assert doc["m7_bundles"]["otm20__standard__120d_roll50__m0on"]["summaries"]["M7G_Graded"]["sharpe"] == 1.038
    assert abs(doc["m7_bundles"]["otm15__itm_tp__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1523801.10) <= 0.05
    assert doc["m7_bundles"]["otm15__itm_tp__90d_hold__m0on"]["summaries"]["M7G_Graded"]["max_dd_pct"] == -24.44
    assert doc["m7_bundles"]["otm15__itm_tp__90d_hold__m0on"]["summaries"]["M7G_Graded"]["calmar"] == 0.763
    assert abs(doc["m7_bundles"]["otm20__itm_tp__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1511253.76) <= 0.05
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

    # Verify alternate selectable TP, Covered-Call, Panic Put Wheel & Wheel Call modes (120 mode bundles: 3*4*(1+3*3))
    assert len(doc["mode_bundles"]) == 120
    std_map = {s["id"]: s for s in doc["mode_bundles"]["standard_dual__cc_off"]["strategies_summary"]}
    assert abs(std_map["U1_PureOptions"]["end_nav"] - 1625377.79) <= 0.50
    assert doc["mode_bundles"]["standard_dual__cc_off"]["live_signal_state"]["regime_code"] == "LOW_SPOT_FREEZE_NO_NEW_COLLAR"
    d4x_map = {s["id"]: s for s in doc["mode_bundles"]["both_4x__cc_off"]["strategies_summary"]}
    assert abs(d4x_map["U1_PureOptions"]["end_nav"] - 1643122.56) <= 0.50
    assert abs(d4x_map["D2_SixLights"]["end_nav"] - 1531284.11) <= 0.50

    d35_map = {s["id"]: s for s in doc["mode_bundles"]["layered_itm__cc_d12_d35"]["strategies_summary"]}
    assert abs(d35_map["U1_PureOptions"]["end_nav"] - 1714946.88) <= 2.0
    assert abs(d35_map["U1_PureOptions"]["extra_shares_pct"] - 33.12) <= 0.05
    assert d35_map["U1_PureOptions"]["cc_trades_count"] == 75
    assert d35_map["U1_PureOptions"]["cc_assigned_count"] == 0
    assert d35_map["U1_PureOptions"]["cc_active_years"] == 11

    r45_map = {s["id"]: s for s in doc["mode_bundles"]["layered_itm__cc_d12_r45"]["strategies_summary"]}
    assert abs(r45_map["U1_PureOptions"]["end_nav"] - 1704612.32) <= 2.0
    assert abs(r45_map["U1_PureOptions"]["extra_shares_pct"] - 32.31) <= 0.05
    assert r45_map["U1_PureOptions"]["cc_trades_count"] == 71
    assert r45_map["U1_PureOptions"]["cc_roll_count"] == 9
    assert r45_map["U1_PureOptions"]["cc_active_years"] == 11

    cr55_map = {s["id"]: s for s in doc["mode_bundles"]["layered_itm__cc_d12_cr55"]["strategies_summary"]}
    assert abs(cr55_map["U1_PureOptions"]["end_nav"] - 1688796.56) <= 2.0
    assert abs(cr55_map["U1_PureOptions"]["extra_shares_pct"] - 31.09) <= 0.05
    assert cr55_map["U1_PureOptions"]["cc_trades_count"] == 71
    assert cr55_map["U1_PureOptions"]["cc_active_years"] == 11

    for sid in ("U1_PureOptions", "B1c_PureAD", "D2_SixLights", "H2_G4_PriceGate", "NoPut_CallOnly"):
        assert d35_map[sid]["end_nav"] > smap[sid]["end_nav"], sid
        assert r45_map[sid]["end_nav"] > smap[sid]["end_nav"], sid
        assert cr55_map[sid]["end_nav"] > smap[sid]["end_nav"], sid


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

    # 1. NEW DEFAULT wc_reclaim_30d_d35 (Hold uncapped < K_assign, then 30D 0.35Δ Call) — 14D 10% Cap
    cap10_rec = doc["mode_bundles"]["layered_itm__cc_d12_d35__sp_14d_cap10"]
    cap10_rec_u1 = next(s for s in cap10_rec["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert cap10_rec["wc_mode"] == "wc_reclaim_30d_d35"
    assert abs(cap10_rec_u1["end_nav"] - 1805855.89) <= 0.05
    assert cap10_rec_u1["cagr_pct"] == 20.34
    assert cap10_rec_u1["max_dd_pct"] == -30.96
    assert cap10_rec_u1["sharpe"] == 0.881
    assert cap10_rec_u1["calmar"] == 0.657
    assert cap10_rec_u1["sp_trades_count"] == 44
    assert cap10_rec_u1["sp_assignments_count"] == 5
    assert cap10_rec_u1["wc_trades_count"] == 8
    assert cap10_rec_u1["wc_called_away_count"] == 4
    assert abs(cap10_rec_u1["wc_gross_prem_usd"] - 8956.46) <= 0.05
    assert abs(cap10_rec_u1["margin_interest_usd"] - 3842.41) <= 0.05
    assert cap10_rec_u1["days_levered_stock"] == 337
    assert cap10_rec_u1["max_wheel_cycle_days"] == 355
    assert cap10_rec_u1["max_gross_stock_lev"] == 1.135
    assert abs(cap10_rec_u1["end_assigned_shares"] - 307.55) <= 0.05
    assert cap10_rec["live_sp_state"]["position_state"] == "wheel_assigned_wait_reclaim"
    assert cap10_rec["live_sp_state"]["min_next_wc_strike"] == 625.43
    assert "水下暂不卖 Call，等涨回 >= $625.43" in cap10_rec["live_sp_state"]["badge_zh"]
    assert len(_unpack_rows(cap10_rec["sp_ledgers_by_strategy"]["U1_PureOptions"])) == 52

    # 2. NEW DEFAULT wc_reclaim_30d_d35 — 10D VIX Falling 20% Cap (New All-Time Record!)
    vixf_rec = doc["mode_bundles"]["layered_itm__cc_d12_d35__sp_10d_vixf"]
    vixf_rec_u1 = next(s for s in vixf_rec["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert abs(vixf_rec_u1["end_nav"] - 1838505.47) <= 0.05
    assert vixf_rec_u1["cagr_pct"] == 20.53
    assert vixf_rec_u1["max_dd_pct"] == -30.38
    assert vixf_rec_u1["sharpe"] == 0.885
    assert vixf_rec_u1["calmar"] == 0.676
    assert vixf_rec_u1["sp_trades_count"] == 27
    assert vixf_rec_u1["sp_assignments_count"] == 3
    assert vixf_rec_u1["wc_trades_count"] == 5
    assert vixf_rec_u1["wc_called_away_count"] == 3
    assert abs(vixf_rec_u1["wc_gross_prem_usd"] - 7976.65) <= 0.05
    assert abs(vixf_rec_u1["margin_interest_usd"] - 1250.65) <= 0.05
    assert vixf_rec_u1["days_levered_stock"] == 133
    assert vixf_rec_u1["max_wheel_cycle_days"] == 106
    assert vixf_rec_u1["max_gross_stock_lev"] == 1.252
    assert vixf_rec_u1["end_assigned_shares"] == 0.0
    assert vixf_rec["live_sp_state"]["position_state"] == "flat_standby"
    assert vixf_rec["live_sp_state"]["vix_falling_signal_on"] is False

    # 3. NEW DEFAULT wc_reclaim_30d_d35 — 14D Unfiltered 20% Cap
    unf_rec = doc["mode_bundles"]["layered_itm__cc_d12_d35__sp_14d_unf"]
    unf_rec_u1 = next(s for s in unf_rec["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert abs(unf_rec_u1["end_nav"] - 1901035.03) <= 0.05
    assert unf_rec_u1["cagr_pct"] == 20.87
    assert unf_rec_u1["max_dd_pct"] == -31.73
    assert unf_rec_u1["sharpe"] == 0.873
    assert unf_rec_u1["calmar"] == 0.658
    assert abs(unf_rec_u1["wc_gross_prem_usd"] - 18463.22) <= 0.05
    assert abs(unf_rec_u1["margin_interest_usd"] - 7942.77) <= 0.05
    assert unf_rec_u1["days_levered_stock"] == 337
    assert unf_rec_u1["max_wheel_cycle_days"] == 355
    assert unf_rec_u1["max_gross_stock_lev"] == 1.276
    assert abs(unf_rec_u1["end_assigned_shares"] - 648.60) <= 0.05

    # 4. COMPARE wc_30d_c5s5 (Immediate 30D + max(1.05*K, 1.05*S)) 100% penny parity
    cap10_b = doc["mode_bundles"]["layered_itm__cc_d12_d35__sp_14d_cap10__wc_30d_c5s5"]
    cap10_u1 = next(s for s in cap10_b["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert cap10_b["wc_mode"] == "wc_30d_c5s5"
    assert abs(cap10_u1["end_nav"] - 1819738.31) <= 0.05
    assert cap10_u1["cagr_pct"] == 20.42
    assert cap10_u1["max_dd_pct"] == -29.82
    assert cap10_u1["sharpe"] == 0.890
    assert cap10_u1["calmar"] == 0.685
    assert cap10_u1["sp_trades_count"] == 44
    assert cap10_u1["sp_assignments_count"] == 6
    assert cap10_u1["wc_trades_count"] == 10
    assert cap10_u1["wc_called_away_count"] == 5
    assert abs(cap10_u1["wc_gross_prem_usd"] - 5041.32) <= 0.05
    assert abs(cap10_u1["margin_interest_usd"] - 1481.18) <= 0.05
    assert cap10_u1["days_levered_stock"] == 221
    assert cap10_u1["max_wheel_cycle_days"] == 111
    assert cap10_u1["max_gross_stock_lev"] == 1.134
    assert abs(cap10_u1["end_assigned_shares"] - 309.91) <= 0.05
    assert cap10_b["live_sp_state"]["position_state"] == "wheel_assigned_wc_armed"
    assert cap10_b["live_sp_state"]["min_next_wc_strike"] == 656.70
    assert "30D Wheel Call（K >= $656.70，max(1.05×成本, 1.05×现价)）" in cap10_b["live_sp_state"]["badge_zh"]
    assert len(_unpack_rows(cap10_b["sp_ledgers_by_strategy"]["U1_PureOptions"])) == 54

    vixf_b = doc["mode_bundles"]["layered_itm__cc_d12_d35__sp_10d_vixf__wc_30d_c5s5"]
    vixf_u1 = next(s for s in vixf_b["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert abs(vixf_u1["end_nav"] - 1831562.63) <= 0.05
    assert abs(vixf_u1["margin_interest_usd"] - 1257.35) <= 0.05

    unf_b = doc["mode_bundles"]["layered_itm__cc_d12_d35__sp_14d_unf__wc_30d_c5s5"]
    unf_u1 = next(s for s in unf_b["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert abs(unf_u1["end_nav"] - 1930238.95) <= 0.05
    assert abs(unf_u1["margin_interest_usd"] - 3062.70) <= 0.05

    # 5. LEGACY wc_14d_c0s2 (14D + max(K, 1.02*S)) 100% penny parity with 2f28247
    cap10_leg = doc["mode_bundles"]["layered_itm__cc_d12_d35__sp_14d_cap10__wc_14d_c0s2"]
    cap10_leg_u1 = next(s for s in cap10_leg["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert cap10_leg["wc_mode"] == "wc_14d_c0s2"
    assert abs(cap10_leg_u1["end_nav"] - 1779823.16) <= 0.05
    assert cap10_leg_u1["calmar"] == 0.677
    assert abs(cap10_leg_u1["margin_interest_usd"] - 816.85) <= 0.05
    assert cap10_leg["live_sp_state"]["min_next_wc_strike"] == 625.43
    assert "14D Wheel Call（K >= $625.43，max(成本, 1.02×现价)）" in cap10_leg["live_sp_state"]["badge_zh"]

    vixf_leg = doc["mode_bundles"]["layered_itm__cc_d12_d35__sp_10d_vixf__wc_14d_c0s2"]
    vixf_leg_u1 = next(s for s in vixf_leg["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert abs(vixf_leg_u1["end_nav"] - 1786932.72) <= 0.05
    assert abs(vixf_leg_u1["margin_interest_usd"] - 504.61) <= 0.05

    unf_leg = doc["mode_bundles"]["layered_itm__cc_d12_d35__sp_14d_unf__wc_14d_c0s2"]
    unf_leg_u1 = next(s for s in unf_leg["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert abs(unf_leg_u1["end_nav"] - 1846991.83) <= 0.05
    assert unf_leg_u1["extra_shares_pct"] == 43.37
    assert abs(unf_leg_u1["margin_interest_usd"] - 1667.62) <= 0.05

    # 6. Standalone Engine 3 on Pure QQQ (NoPut_CallOnly + cc_off + sp_mode)
    bh_unf_rec = next(
        s
        for s in doc["mode_bundles"]["layered_itm__cc_off__sp_14d_unf"]["strategies_summary"]
        if s["id"] == "NoPut_CallOnly"
    )
    assert abs(bh_unf_rec["end_nav"] - 1427923.23) <= 0.05
    bh_unf_30d = next(
        s
        for s in doc["mode_bundles"]["layered_itm__cc_off__sp_14d_unf__wc_30d_c5s5"]["strategies_summary"]
        if s["id"] == "NoPut_CallOnly"
    )
    assert abs(bh_unf_30d["end_nav"] - 1449831.69) <= 0.05
    bh_unf_leg = next(
        s
        for s in doc["mode_bundles"]["layered_itm__cc_off__sp_14d_unf__wc_14d_c0s2"]["strategies_summary"]
        if s["id"] == "NoPut_CallOnly"
    )
    assert abs(bh_unf_leg["end_nav"] - 1387278.02) <= 0.05


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
