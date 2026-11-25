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
    assert doc["default_fill_mode"] == "ibkr_limit"
    assert doc["fill_mode"] == "ibkr_limit"
    assert [m["id"] for m in doc["fill_modes_meta"]] == ["ibkr_limit", "ask_bid"]
    assert doc["hardcoded_ruleset"]["code"] == "B020_M125_HARD75_NEARITM_5DLOCK"
    assert doc["hardcoded_ruleset"]["locked"] is True
    assert doc["hardcoded_ruleset"]["base_book"]["budget_pct_nav"] == 0.2
    assert doc["hardcoded_ruleset"]["base_book"]["vix_max"] == 20.0
    assert doc["hardcoded_ruleset"]["base_book"]["target_dte"] == 125
    assert doc["hardcoded_ruleset"]["base_book"]["roll_dte"] == 75
    assert doc["hardcoded_ruleset"]["m7_book"]["budget_pct_nav_per_slot"] == 1.25
    assert doc["hardcoded_ruleset"]["near_itm_tp"]["near_itm_strike_mult"] == 1.05
    assert doc["hardcoded_ruleset"]["post_tp_lockout"]["consecutive_days"] == 5
    assert doc["default_profile"] == "full_m7_adaptive"
    assert doc["default_strategy_id"] == "M7G_Graded"
    assert doc["default_put_otm"] == "otm15"
    assert doc["default_m7_tp_mode"] == "standard"
    assert doc["default_roll_mode"] == "adaptive_120_90"
    assert doc["default_m0_enabled"] is True
    assert [p["id"] for p in doc["profiles_meta"]] == ["full_m7_adaptive", "core3_adaptive"]
    assert doc["pricing_provenance"]["mode"] == "real_opra_calibrated_bsm"
    assert doc["pricing_provenance"]["segment1_real_opra"]["trading_days"] == 2749
    assert doc["pricing_provenance"]["segment1_real_opra"]["quotes_count"] == 9875299
    assert doc["pricing_provenance"]["segment1_real_opra"]["execution_fallbacks"] == 0
    opra_bench = doc["pricing_provenance"]["audited_opra_benchmarks_2015_2025"]
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["end_nav"] == 1740267.20
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["net_alpha_usd"] == 453939.75
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["cagr_pct"] == 21.85
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["max_dd_pct"] == -26.17
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["calmar"] == 0.835
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["sharpe"] == 1.011
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["sortino"] == 1.355
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["trades"] == 116
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["base_trades"] == 67
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["m7_trades"] == 49
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["tp_count"] == 13
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["profit_factor"] == 2.28
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["lockout_episodes"] == 6
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["lockout_days"] == 91
    assert opra_bench["full_m7_adaptive_ibkr_limit"]["blocked_base_entries"] == 2
    assert opra_bench["full_m7_adaptive_ask_bid"]["end_nav"] == 1688420.02
    assert opra_bench["full_m7_adaptive_ask_bid"]["net_alpha_usd"] == 402092.57
    assert opra_bench["full_m7_adaptive_ask_bid"]["cagr_pct"] == 21.51
    assert opra_bench["full_m7_adaptive_ask_bid"]["calmar"] == 0.819
    assert opra_bench["full_m7_adaptive_ask_bid"]["profit_factor"] == 2.19
    assert opra_bench["core3_adaptive_ibkr_limit"]["end_nav"] == 1514395.10
    assert opra_bench["core3_adaptive_ask_bid"]["end_nav"] == 1478048.67
    assert doc["pricing_provenance"]["seam_continuity_audit"]["last_opra_date"] == "2025-12-15"
    seam_row = next(r for r in doc["daily_series"] if r["date"] == "2025-12-15")
    assert seam_row["nav_m7g"] == 1740267.20
    assert seam_row["nav_c3"] == 1514395.10
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
        "Core3_Adaptive",
        "M7_Ensemble",
        "U1_PureOptions",
        "B1c_PureAD",
        "D2_SixLights",
        "H2_G4_PriceGate",
        "NoPut_CallOnly",
        "BH_Pure_QQQ",
    ]
    # Real-OPRA IBKR Limit + Calibrated BSM Default: B020_M125 Dual-Book M7G_Graded (0.20% Base VIX<=20 + 1.25% M7G · 125->75 / CTA 90->30 · 5D Lockout)
    assert smap["M7G_Graded"]["pricing_basis"] == "real_opra_2015_2025_calibrated_bsm"
    assert smap["M7G_Graded"]["fill_mode"] == "ibkr_limit"
    assert smap["M7G_Graded"]["ruleset_code"] == "B020_M125_HARD75_NEARITM_5DLOCK"
    assert smap["M7G_Graded"]["base_budget_pct"] == 0.2
    assert smap["M7G_Graded"]["m7_budget_pct"] == 1.25
    assert smap["M7G_Graded"]["real_trades_pct"] == 89.8
    assert smap["M7G_Graded"]["real_opra_trades_count"] == 114
    assert smap["M7G_Graded"]["sim_trades_count"] == 13
    assert abs(smap["M7G_Graded"]["end_nav"] - 1775771.98) <= 0.05
    assert smap["M7G_Graded"]["cagr_pct"] == 20.18
    assert smap["M7G_Graded"]["max_dd_pct"] == -26.17
    assert smap["M7G_Graded"]["calmar"] == 0.771
    assert smap["M7G_Graded"]["sharpe"] == 0.931
    assert smap["M7G_Graded"]["roll_75d_count"] == 99
    assert smap["M7G_Graded"]["roll_30d_count"] == 3
    assert smap["M7G_Graded"]["salvage_vix_expensive_count"] == 9
    assert abs(smap["M7G_Graded"]["avg_roll_salvage_pct"] - 55.4) <= 0.2

    # Core-3 Minimal Adaptive: Book B 0.20% + Book M 1.25%/slot (M0+M6+M4) + Adaptive 125->75 / CTA 90->30
    assert smap["Core3_Adaptive"]["pricing_basis"] == "real_opra_2015_2025_calibrated_bsm"
    assert smap["Core3_Adaptive"]["real_opra_trades_count"] == 98
    assert smap["Core3_Adaptive"]["sim_trades_count"] == 12
    assert abs(smap["Core3_Adaptive"]["end_nav"] - 1506551.86) <= 0.05
    assert smap["Core3_Adaptive"]["cagr_pct"] == 18.53
    assert smap["Core3_Adaptive"]["max_dd_pct"] == -28.05
    assert smap["Core3_Adaptive"]["profit_factor"] == 1.32

    assert abs(smap["M7_Ensemble"]["end_nav"] - 1620258.94) <= 0.05
    assert len(doc["m7_bundles"]) == 24
    # Core-3 safety guardrail: 90d_hold bundle locks Core3_Adaptive to adaptive_120_90
    c3_guard = doc["m7_bundles"]["otm15__standard__90d_hold__m0on"]["summaries"]["Core3_Adaptive"]
    assert c3_guard["roll_mode"] == "adaptive_120_90"
    assert abs(c3_guard["end_nav"] - 1506551.86) <= 0.05

    assert abs(doc["m7_bundles"]["otm15__standard__120d_roll50__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1338003.36) <= 0.05
    assert abs(doc["m7_bundles"]["otm15__standard__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1359770.65) <= 0.05
    assert abs(doc["m7_bundles"]["otm20__standard__adaptive_120_90__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1501151.01) <= 0.05
    assert abs(doc["m7_bundles"]["otm20__standard__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1163317.78) <= 0.05
    assert abs(doc["m7_bundles"]["otm15__itm_tp__adaptive_120_90__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1521000.10) <= 0.05
    assert abs(doc["m7_bundles"]["otm15__itm_tp__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1217359.98) <= 0.05
    assert abs(doc["m7_bundles"]["otm20__itm_tp__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1134462.67) <= 0.05

    # Verify M7 trade ledger quoteSource tags (>=98% REAL_OPRA inside 2015..2025-12-15; CALIBRATED_BSM > 2025-12-15)
    for sid in ("M7G_Graded", "Core3_Adaptive"):
        m7_ledger = _unpack_rows(doc["m7_bundles"]["otm15__standard__adaptive_120_90__m0on"]["ledgers"][sid])
        assert len(m7_ledger) >= 100
        in_opra = [
            tr for tr in m7_ledger
            if str(tr["entry_date"]) <= "2025-12-15"
            and (tr.get("exit_date") is None or str(tr["exit_date"]) <= "2025-12-15")
            and not tr.get("is_open_live")
        ]
        real_in_opra = sum(1 for tr in in_opra if tr.get("quoteSource") == "REAL_OPRA")
        assert real_in_opra / len(in_opra) >= 0.98
        for tr in m7_ledger:
            qs = tr.get("quoteSource")
            assert qs in ("REAL_OPRA", "CALIBRATED_BSM")
            assert tr.get("book") in ("base", "m7")
            assert tr.get("occSymbol")

    # Legacy strategies on real OPRA Ask/Bid + Calibrated BSM
    assert smap["U1_PureOptions"]["pricing_basis"] in ("real_opra_2015_2025_calibrated_bsm", "hybrid_real_opra_polygon_bsm")
    assert smap["U1_PureOptions"]["real_trades_pct"] == 90.9
    assert abs(smap["U1_PureOptions"]["end_nav"] - 1322402.31) <= 0.05
    assert smap["M7G_Graded"]["end_nav"] > smap["U1_PureOptions"]["end_nav"] + 140000.0
    assert smap["U1_PureOptions"]["cagr_pct"] == 17.23
    assert smap["U1_PureOptions"]["max_dd_pct"] == -33.25
    assert abs(smap["B1c_PureAD"]["end_nav"] - 1347636.26) <= 0.05
    assert abs(smap["D2_SixLights"]["end_nav"] - 1351686.36) <= 0.05
    assert abs(smap["H2_G4_PriceGate"]["end_nav"] - 1252925.34) <= 0.05
    assert abs(smap["BH_Pure_QQQ"]["end_nav"] - 1288304.78) <= 0.02

    # Verify alternate selectable TP & Covered-Call modes (120 mode bundles)
    assert len(doc["mode_bundles"]) == 120
    d35_map = {s["id"]: s for s in doc["mode_bundles"]["layered_itm__cc_d12_d35"]["strategies_summary"]}
    assert abs(d35_map["U1_PureOptions"]["end_nav"] - 1287946.39) <= 0.50
    assert abs(d35_map["NoPut_CallOnly"]["end_nav"] - 1285518.97) <= 0.50


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

    # 1. Real-OPRA Ask/Bid Engine 3 with default wc_reclaim_30d_d35 + cc_off
    cap10_rec = doc["mode_bundles"]["layered_itm__cc_off__sp_14d_cap10"]
    cap10_rec_u1 = next(s for s in cap10_rec["strategies_summary"] if s["id"] == "U1_PureOptions")
    cap10_rec_np = next(s for s in cap10_rec["strategies_summary"] if s["id"] == "NoPut_CallOnly")
    assert cap10_rec["wc_mode"] == "wc_reclaim_30d_d35"
    assert abs(cap10_rec_u1["end_nav"] - 1393555.72) <= 0.05
    assert cap10_rec_u1["max_dd_pct"] == -32.88
    assert cap10_rec_u1["real_trades_pct"] >= 85.0
    assert abs(cap10_rec_np["end_nav"] - 1357470.42) <= 0.05
    assert cap10_rec["live_sp_state"]["position_state"] == "wheel_assigned_wait_reclaim"
    assert cap10_rec["live_sp_state"]["min_next_wc_strike"] == 623.29

    # 2. 10D VIX Falling 20% Cap
    vixf_rec = doc["mode_bundles"]["layered_itm__cc_off__sp_10d_vixf"]
    vixf_rec_u1 = next(s for s in vixf_rec["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert abs(vixf_rec_u1["end_nav"] - 1392568.59) <= 0.05
    assert vixf_rec_u1["real_trades_pct"] >= 85.0

    # 3. 14D Unfiltered 20% Cap
    unf_rec = doc["mode_bundles"]["layered_itm__cc_off__sp_14d_unf"]
    unf_rec_u1 = next(s for s in unf_rec["strategies_summary"] if s["id"] == "U1_PureOptions")
    unf_rec_np = next(s for s in unf_rec["strategies_summary"] if s["id"] == "NoPut_CallOnly")
    assert abs(unf_rec_u1["end_nav"] - 1468143.84) <= 0.05
    assert abs(unf_rec_np["end_nav"] - 1429966.08) <= 0.05

    # 4. wc_reclaim_30d_d35 beats both compare modes on real OPRA Ask/Bid too!
    cap10_30d = doc["mode_bundles"]["layered_itm__cc_off__sp_14d_cap10__wc_30d_c5s5"]
    cap10_30d_u1 = next(s for s in cap10_30d["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert abs(cap10_30d_u1["end_nav"] - 1386765.62) <= 0.05
    assert cap10_rec_u1["end_nav"] > cap10_30d_u1["end_nav"]

    cap10_14d = doc["mode_bundles"]["layered_itm__cc_off__sp_14d_cap10__wc_14d_c0s2"]
    cap10_14d_u1 = next(s for s in cap10_14d["strategies_summary"] if s["id"] == "U1_PureOptions")
    assert abs(cap10_14d_u1["end_nav"] - 1372072.61) <= 0.05
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
    assert win_2022["m7g_mdd"] == -26.17
    assert win_2022["c3_mdd"] == -26.17
    assert win_2022["u1_mdd"] == -33.25
    assert win_2022["qqq_mdd"] == -35.12
    assert abs(win_2022["harvested_usd_m7g"] - 49660.65) <= 0.10
    assert abs(win_2022["harvested_usd_c3"] - 49190.95) <= 0.10
    assert abs(win_2022["harvested_usd"] - 18335.83) <= 0.05

    live_win = doc["crisis_windows"][-1]
    assert live_win["is_live"] is True
    assert live_win["m7g_mdd"] == -16.74
    assert live_win["c3_mdd"] == -18.82
    assert live_win["u1_mdd"] == -14.78
    assert live_win["qqq_mdd"] == -19.90
    assert abs(live_win["harvested_usd_m7g"] - 55028.18) <= 0.10
    assert abs(live_win["harvested_usd_c3"] - 12090.43) <= 0.10
    assert abs(live_win["harvested_usd"] - 74506.03) <= 0.10
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


def test_dual_track_live_stress_and_module_readiness_in_artifact():
    doc = json.loads(ARTIFACT_PATH.read_text(encoding="utf-8"))
    dash = doc["m7_live_dashboard"]
    assert dash["fill_mode"] == "ibkr_limit"
    assert dash["book_b_vix_gate"]["budget_pct"] == 0.2
    assert dash["book_b_vix_gate"]["vix_max"] == 20.0
    assert dash["book_b_vix_gate"]["status"] == "LOCKED_BY_5D"
    assert dash["post_tp_lockout"]["locked"] is True
    assert dash["post_tp_lockout"]["non_inverted_streak"] == 0
    assert dash["post_tp_lockout"]["required_streak"] == 5
    assert dash["near_itm_tp_rule"]["near_itm_mult"] == 1.05
    assert dash["near_itm_tp_rule"]["vix_extreme"] == 45.0
    assert dash["live_stress_index"] >= 75
    assert dash["live_stress_level"] == "crisis"
    assert dash["live_stress_label_en"] == "Active Crisis"
    assert dash["live_stress_label_zh"] == "危机爆发中"
    bd = dash["live_stress_breakdown"]
    for k in ("regime_vol", "trend_dd", "credit_macro", "breadth_tail"):
        assert k in bd and bd[k] >= 0

    fresh = dash["data_freshness"]
    assert fresh["yahoo_eod_date"] == "2026-11-20"
    assert fresh["fred_baa_lag_days"] == 1
    assert fresh["fred_dgs2_lag_days"] == 1
    assert fresh["fred_nfci_lag_days"] == 5
    assert fresh["ad_line_date"] == "2026-11-20"
    assert fresh["is_pit_replay"] is False

    mods = {m["id"]: m for p in dash["pillars"] for m in p["modules"]}
    assert set(mods.keys()) == {"M0", "M6", "M2", "M5", "M4", "M3"}
    for m in mods.values():
        assert isinstance(m["sensor_triggered"], bool)
        assert isinstance(m["readiness_met"], int)
        assert isinstance(m["readiness_total"], int)
        assert m["status_code"] in (
            "DISABLED_IN_CORE3",
            "DISABLED_M0_OFF",
            "ARMED_BUY",
            "SENSOR_RED_VOL_BLOCKED",
            "WARMING_UP",
            "CALM",
        )
        assert m["next_trigger_hint_en"]
        assert m["next_trigger_hint_zh"]
    assert mods["M3"]["status_code"] == "SENSOR_RED_VOL_BLOCKED"
    assert dash["vol_blocked_sensor_count"] >= 1
    assert dash["warming_count"] >= 1

    series_by_date = {r["date"]: r for r in doc["daily_series"]}
    assert all("live_stress" in r for r in doc["daily_series"])
    assert series_by_date["2017-07-14"]["live_stress"] < 25
    assert series_by_date["2020-03-20"]["live_stress"] >= 75
    assert series_by_date["2026-11-20"]["live_stress"] == dash["live_stress_index"]


def test_kmlm20_hypothesis_seed_golden_benchmarks():
    import gzip
    kmlm_spec = importlib.util.spec_from_file_location(
        "build_crisis_observatory_kmlm20_artifact",
        Path(__file__).resolve().parent / "build-crisis-observatory-kmlm20-artifact.py",
    )
    kmlm_mod = importlib.util.module_from_spec(kmlm_spec)
    kmlm_spec.loader.exec_module(kmlm_mod)

    seed_path = ARTIFACT_PATH.parent / "crisis-observatory-kmlm20-seed.json.gz"
    assert seed_path.exists(), f"Missing {seed_path}"
    seed = json.loads(gzip.decompress(seed_path.read_bytes()).decode("utf-8"))
    assert seed["version"] == "crisis-observatory-kmlm20-v1"
    assert seed["status"] == "HYPOTHESIS"
    assert seed["kmlm_weight"] == 0.20
    assert seed["gross_leverage"] == 1.20
    assert seed["rebal_fee"] == 0.0005

    d11 = seed["d11"]["dates"]
    n11 = len(d11)
    assert d11[0] == "2015-01-02" and d11[-1] == "2025-12-15" and n11 == 2755
    r_lim_11 = kmlm_mod.pct_change_zero_first(seed["d11"]["m7g_lim_nav"])
    r_ab_11 = kmlm_mod.pct_change_zero_first(seed["d11"]["m7g_ab_nav"])
    px_qqq_11 = seed["d11"]["qqq_adj"]
    r_qqq_11 = kmlm_mod.pct_change_zero_first(px_qqq_11)
    r_aq_11 = kmlm_mod.pct_change_zero_first(seed["d11"]["aqmix_adj"])
    r_km_raw = kmlm_mod.pct_change_zero_first(seed["d11"]["kmlm_adj"])
    splice_km = d11.index("2020-12-03")
    r_km_11 = [r_aq_11[i] if i < splice_km else r_km_raw[i] for i in range(n11)]
    px_km_11 = []
    acc = 100.0
    for r in r_km_11:
        acc *= 1.0 + r
        px_km_11.append(acc)
    effr_11 = seed["d11"]["effr"]
    vix_11 = seed["d11"]["vix"]
    vr_11 = seed["d11"]["vr"]
    tp11, lk11 = kmlm_mod.build_tp_and_lockout(d11, vix_11, vr_11, seed["d11"]["m7g_lockout_episodes"])
    bh11 = [200000.0 * (x / px_qqq_11[0]) for x in px_qqq_11]

    # 11Y Stitched (Box +0.35% & IBKR +1.50%, Limit & Ask/Bid)
    s11_box = kmlm_mod.sim_pure_cta_blueprint(
        d11, r_lim_11, r_qqq_11, px_qqq_11, [("KMLM", 0.20, r_km_11, px_km_11)],
        effr_11, vix_11, 0.0035, tp11, lk11, mode="rot_vix20",
    )
    s11_box_ab = kmlm_mod.sim_pure_cta_blueprint(
        d11, r_ab_11, r_qqq_11, px_qqq_11, [("KMLM", 0.20, r_km_11, px_km_11)],
        effr_11, vix_11, 0.0035, tp11, lk11, mode="rot_vix20",
    )
    s11_ibkr = kmlm_mod.sim_pure_cta_blueprint(
        d11, r_lim_11, r_qqq_11, px_qqq_11, [("KMLM", 0.20, r_km_11, px_km_11)],
        effr_11, vix_11, 0.0150, tp11, lk11, mode="rot_vix20",
    )
    p11_box = kmlm_mod.calc_perf(d11, s11_box["nav"], bh11, effr_11, extra=s11_box)
    p11_ibkr = kmlm_mod.calc_perf(d11, s11_ibkr["nav"], bh11, effr_11, extra=s11_ibkr)
    assert abs(p11_box["final_nav"] - 1785222.38) <= 0.50
    assert abs(s11_box_ab["nav"][-1] - 1732487.07) <= 0.50
    assert p11_box["cagr_pct"] == 22.13
    assert p11_box["mdd_pct"] == -23.60
    assert p11_box["calmar"] == 0.938
    assert p11_box["sharpe"] == 1.010
    assert p11_box["sortino"] == 1.353
    assert p11_box["peak_ltv_pct"] == 20.44
    assert p11_box["rot_cnt"] == 2
    assert abs(p11_ibkr["final_nav"] - 1741934.61) <= 0.50
    assert p11_ibkr["cagr_pct"] == 21.85
    assert p11_ibkr["mdd_pct"] == -23.62
    assert p11_ibkr["calmar"] == 0.925

    # 5Y Pure Live KMLM (2020-12-02 -> 2025-12-15, zero proxy)
    i5 = d11.index("2020-12-02")
    d5 = d11[i5:]
    r_lim_5 = list(r_lim_11[i5:]); r_lim_5[0] = 0.0
    r_ab_5 = list(r_ab_11[i5:]); r_ab_5[0] = 0.0
    r_qqq_5 = list(r_qqq_11[i5:]); r_qqq_5[0] = 0.0
    px_qqq_5 = px_qqq_11[i5:]
    r_km_5 = list(r_km_raw[i5:]); r_km_5[0] = 0.0
    px_km_5 = [float(x) for x in seed["d11"]["kmlm_adj"][i5:]]
    effr_5 = effr_11[i5:]
    vix_5 = vix_11[i5:]
    bh5 = [200000.0 * (x / px_qqq_5[0]) for x in px_qqq_5]
    tp5 = {k - i5: v for k, v in tp11.items() if k >= i5}
    lk5 = lk11[i5:]

    s5_box = kmlm_mod.sim_pure_cta_blueprint(
        d5, r_lim_5, r_qqq_5, px_qqq_5, [("KMLM", 0.20, r_km_5, px_km_5)],
        effr_5, vix_5, 0.0035, tp5, lk5, mode="rot_vix20",
    )
    s5_box_ab = kmlm_mod.sim_pure_cta_blueprint(
        d5, r_ab_5, r_qqq_5, px_qqq_5, [("KMLM", 0.20, r_km_5, px_km_5)],
        effr_5, vix_5, 0.0035, tp5, lk5, mode="rot_vix20",
    )
    p5_box = kmlm_mod.calc_perf(d5, s5_box["nav"], bh5, effr_5, extra=s5_box)
    assert abs(p5_box["final_nav"] - 570416.64) <= 0.25
    assert abs(s5_box_ab["nav"][-1] - 566429.07) <= 0.25
    assert p5_box["cagr_pct"] == 23.14
    assert p5_box["mdd_pct"] == -22.27
    assert p5_box["calmar"] == 1.039
    assert p5_box["sharpe"] == 0.983
    assert p5_box["sortino"] == 1.498
    assert p5_box["peak_ltv_pct"] == 19.58
    assert p5_box["rot_cnt"] == 1

    eps = seed["episodes_7_historical_and_q4"]
    assert len(eps) == 7
    assert [e["decision"] for e in eps] == ["ROTATE", "HOLD", "HOLD", "ROTATE", "HOLD", "HOLD", "HOLD"]
    assert eps[-1]["tp_date"] == "2026-11-20"
    assert abs(eps[-1]["corr"] - 0.092) <= 0.002
    assert eps[-1]["reason"] == "HOLD_POS_CORR"


