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
    assert doc["pricing_provenance"]["audited_opra_benchmarks_2015_2025"]["full_m7_adaptive_ask_bid"]["end_nav"] == 1451369.05
    assert doc["pricing_provenance"]["audited_opra_benchmarks_2015_2025"]["core3_adaptive_ask_bid"]["end_nav"] == 1481937.31
    assert doc["pricing_provenance"]["seam_continuity_audit"]["last_opra_date"] == "2025-12-15"
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
    # Real-OPRA Ask/Bid + Calibrated BSM Default: M7G_Graded Adaptive 120->50 / CTA 90->30 (-15% OTM · STANDARD)
    assert smap["M7G_Graded"]["pricing_basis"] == "real_opra_2015_2025_calibrated_bsm"
    assert smap["M7G_Graded"]["real_trades_pct"] == 95.7
    assert smap["M7G_Graded"]["real_opra_trades_count"] == 45
    assert smap["M7G_Graded"]["sim_trades_count"] == 2
    assert abs(smap["M7G_Graded"]["end_nav"] - 1466143.41) <= 0.05
    assert smap["M7G_Graded"]["cagr_pct"] == 18.25
    assert smap["M7G_Graded"]["max_dd_pct"] == -28.32
    assert smap["M7G_Graded"]["calmar"] == 0.645
    assert smap["M7G_Graded"]["sharpe"] == 0.918
    assert smap["M7G_Graded"]["roll_50d_count"] == 28
    assert smap["M7G_Graded"]["roll_30d_count"] == 4
    assert abs(smap["M7G_Graded"]["avg_roll_salvage_pct"] - 51.5) <= 0.2

    # Core-3 Minimal Adaptive: M0+M6+M4 + Adaptive 120->50 / CTA 90->30
    assert smap["Core3_Adaptive"]["pricing_basis"] == "real_opra_2015_2025_calibrated_bsm"
    assert smap["Core3_Adaptive"]["real_opra_trades_count"] == 30
    assert smap["Core3_Adaptive"]["sim_trades_count"] == 2
    assert abs(smap["Core3_Adaptive"]["end_nav"] - 1497022.85) <= 0.05
    assert smap["Core3_Adaptive"]["cagr_pct"] == 18.46
    assert smap["Core3_Adaptive"]["max_dd_pct"] == -28.56
    assert smap["Core3_Adaptive"]["profit_factor"] == 2.321

    assert abs(smap["M7_Ensemble"]["end_nav"] - 1437260.55) <= 0.05
    assert len(doc["m7_bundles"]) == 24
    # Core-3 safety guardrail: 90d_hold bundle locks Core3_Adaptive to adaptive_120_90
    c3_guard = doc["m7_bundles"]["otm15__standard__90d_hold__m0on"]["summaries"]["Core3_Adaptive"]
    assert c3_guard["roll_mode"] == "adaptive_120_90"
    assert abs(c3_guard["end_nav"] - 1497022.85) <= 0.05

    assert abs(doc["m7_bundles"]["otm15__standard__120d_roll50__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1436762.50) <= 0.05
    assert abs(doc["m7_bundles"]["otm15__standard__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1343816.19) <= 0.05
    assert abs(doc["m7_bundles"]["otm20__standard__adaptive_120_90__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1438956.91) <= 0.05
    assert abs(doc["m7_bundles"]["otm20__standard__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1274910.48) <= 0.05
    assert abs(doc["m7_bundles"]["otm15__itm_tp__adaptive_120_90__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1335191.63) <= 0.05
    assert abs(doc["m7_bundles"]["otm15__itm_tp__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1290849.77) <= 0.05
    assert abs(doc["m7_bundles"]["otm20__itm_tp__90d_hold__m0on"]["summaries"]["M7G_Graded"]["end_nav"] - 1225265.05) <= 0.05

    # Verify M7 trade ledger quoteSource tags ("REAL_OPRA" <= 2025-12-15 vs "CALIBRATED_BSM" > 2025-12-15)
    for sid in ("M7G_Graded", "Core3_Adaptive"):
        m7_ledger = _unpack_rows(doc["m7_bundles"]["otm15__standard__adaptive_120_90__m0on"]["ledgers"][sid])
        assert len(m7_ledger) >= 32
        for tr in m7_ledger:
            qs = tr.get("quoteSource")
            assert qs in ("REAL_OPRA", "CALIBRATED_BSM")
            if str(tr["entry_date"]) <= "2025-12-15" and (tr.get("exit_date") is None or str(tr["exit_date"]) <= "2025-12-15") and not tr.get("is_open_live"):
                assert qs == "REAL_OPRA"
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
    assert win_2022["m7g_mdd"] == -28.32
    assert win_2022["c3_mdd"] == -28.32
    assert win_2022["u1_mdd"] == -33.25
    assert win_2022["qqq_mdd"] == -35.12
    assert abs(win_2022["harvested_usd_m7g"] - 37794.79) <= 0.10
    assert abs(win_2022["harvested_usd_c3"] - 38665.63) <= 0.10
    assert abs(win_2022["harvested_usd"] - 18335.83) <= 0.05

    live_win = doc["crisis_windows"][-1]
    assert live_win["is_live"] is True
    assert live_win["m7g_mdd"] == -18.46
    assert live_win["c3_mdd"] == -18.46
    assert live_win["u1_mdd"] == -14.78
    assert live_win["qqq_mdd"] == -19.90
    assert abs(live_win["harvested_usd_m7g"] - 18703.71) <= 0.10
    assert abs(live_win["harvested_usd_c3"] - 19097.64) <= 0.10
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
