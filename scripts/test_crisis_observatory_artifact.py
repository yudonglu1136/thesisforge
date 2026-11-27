"""Pytest verification suite for Crisis Observatory v3.0 Double-Champion (Plan D) artifact."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_PATH = ROOT / "server" / "config" / "crisis-observatory-dashboard.json"


def test_v3_plan_d_artifact_benchmarks_and_strict_hygiene():
    assert ARTIFACT_PATH.exists(), "crisis-observatory-dashboard.json must exist"
    raw = ARTIFACT_PATH.read_text(encoding="utf-8")
    assert len(raw) < 3_000_000, f"Artifact exceeds 3 MB budget: {len(raw)} bytes"
    assert chr(126) not in raw, "ASCII tilde forbidden"
    for banned in (
        "FactOS",
        "FACT OS",
        "fact_os",
        "DuckDB",
        "Sharadar",
        "SQLite",
        "Wheel",
        "wheel",
        "Covered Call",
        "Short Put",
        "卖Call",
        "领口",
    ):
        assert banned not in raw, f"Forbidden legacy/internal term found: {banned}"

    doc = json.loads(raw)
    assert doc["version"] == "crisis-observatory-v3-plan-d"
    assert doc["strategy_code"] == "PlanD_TalebB020M125_DualCTA_CONT2M"
    assert doc["put_engine_code"] == "B020_M125"
    assert doc["ruleset"]["single_strategy_only"] is True
    assert doc["ruleset"]["core_overlay"]["daily_forced_delev_cap"] is False
    assert doc["ruleset"]["sleeve_b"]["tier_ladder"] == "M7G_tier_45_65"
    assert doc["ruleset"]["sleeve_b"]["max_slots"] == 3
    assert doc["ruleset"]["sleeve_b"]["budget_per_slot_pct_nav"] == 1.25
    assert doc["ruleset"]["sleeve_b"]["uniform_otm_pct"] == -15
    assert doc["ruleset"]["cta_rotation"]["mode"] == "CONT_2M_5tranche_365d_LTCG"

    prov = doc["backtest"]["opra_provenance"]
    assert prov["quotes_count"] == 6382288
    assert prov["opra_end"] == "2025-12-15"
    assert prov["extended_end"] == "2026-11-25"
    assert prov["sim_extension_days"] == 238
    assert prov["bsm_calibration"]["fit_quotes_count"] == 1500755
    assert prov["bsm_calibration"]["oos_2026_real_n"] == 9937

    w11 = doc["backtest"]["windows"]["11y_opra"]
    assert w11["opra_cutoff_date"] == "2025-12-15"
    assert w11["end_date"] == "2026-11-25"
    assert w11["sim_extension_days"] == 238
    # Exact verified Plan D Real MIT OPRA segment (2015-01-02 -> 2025-12-15, strict pre-filtered roll slot cap + Slow-Bear 90D->30D)
    assert w11["kpi_opra_verified_primary"]["end_nav"] == 932908.42
    assert w11["kpi_opra_verified_primary"]["cagr_pct"] == 22.62
    assert w11["kpi_opra_verified_primary"]["max_dd_pct"] == -24.31
    assert w11["kpi_opra_verified_primary"]["calmar"] == 0.93
    assert w11["kpi_opra_verified_primary"]["put_gross_turnover_pct_nav_yr"] == 6.11
    assert w11["kpi_opra_verified_primary"]["put_roll_salvage_pct"] == 67.1
    assert w11["kpi_opra_verified_primary"]["put_true_net_bleed_pct_nav_yr"] == 2.04
    # Full continuous window through 2026-11-25 (real spot + OPRA-residual-calibrated BSM extension)
    assert w11["kpi_primary"]["end_nav"] == 994680.76
    assert w11["kpi_primary"]["cagr_pct"] == 21.3
    assert w11["kpi_primary"]["max_dd_pct"] == -24.31
    assert w11["kpi_primary"]["calmar"] == 0.876
    assert w11["kpi_primary"]["peak_gross_leverage"] == 1.2582
    assert w11["kpi_primary"]["put_trades_m4"] == 3
    assert w11["kpi_primary"]["cta_rotation_count"] == 10
    assert len(w11["crisis_comparison"]) == 9
    assert len(w11["latch_episodes"]) == 1

    # Regression guard 1: Roll loop-order slot-cap bug
    # On 2025-01-07 (prev_cap=1 while T#104 remained open), no excess crisis roll may open,
    # and 2025-04-07 must harvest 3 legitimate puts (2 crisis + 1 base) rather than 4.
    pl11 = w11["put_ledger"]
    if isinstance(pl11, dict) and "_cols" in pl11:
        pl11 = [dict(zip(pl11["_cols"], r)) for r in pl11["_rows"]]
    assert not any(
        p["entry_date"] == "2025-01-07" and p["sleeve"] != "base" for p in pl11
    ), "Roll loop-order bug regression: excess crisis roll opened on 2025-01-07 while cap=1"
    tp_0407 = [p for p in pl11 if p["exit_date"] == "2025-04-07" and "tp_" in p["exit_reason"]]
    assert len(tp_0407) == 3, f"Expected 3 legitimate TP puts on 2025-04-07, got {len(tp_0407)}"

    # Regression guard 2: Slow-Bear Latch 90D->30D invariant (ZERO 125D opens & ZERO 75D exits!)
    # Every Put opened during any Slow-Bear Latch window (2022-03-04 .. 2023-02-13, BOTH Base & Crisis)
    # MUST strictly open 90D -15% OTM (target_dte=90, roll_dte=30, entry_dte<=120) and hold to <=35D
    # unless a right-tail TP triggers earlier.
    ds11 = w11["daily_series"]
    if isinstance(ds11, dict) and "_cols" in ds11:
        ds11 = [dict(zip(ds11["_cols"], r)) for r in ds11["_rows"]]
    dates_11 = [r["date"] for r in ds11]
    latch_by_d = {r["date"]: bool(r["latch"]) for r in ds11}
    prev_d_map = {dates_11[k]: dates_11[k - 1] for k in range(1, len(dates_11))}
    sb_puts = [p for p in pl11 if latch_by_d.get(prev_d_map.get(p["entry_date"], ""), False)]
    assert len(sb_puts) >= 6, f"Expected >=6 puts opened during 2022 Slow-Bear Latch, got {len(sb_puts)}"
    for p in sb_puts:
        assert p["target_dte"] == 90, f"Slow-Bear put opened non-90D target: {p}"
        assert p["roll_dte"] == 30, f"Slow-Bear put missing 30D roll_dte: {p}"
        assert p["entry_dte"] <= 120, f"Slow-Bear put opened 125D+ contract: {p}"
        if "tp_" not in p["exit_reason"]:
            assert p["exit_dte"] <= 35, f"Slow-Bear non-TP put exited early before 30DTE: {p}"
            assert p["exit_reason"] in ("roll_30d", "salvage_30d_slowbear"), f"Unexpected slow-bear exit reason: {p}"

    w5 = doc["backtest"]["windows"]["5y_live"]
    assert w5["zero_splice"] is True
    assert w5["end_date"] == "2026-11-25"
    # Exact verified Plan D 5Y Zero-Splice Real MIT OPRA segment (2020-12-03 -> 2025-12-15)
    assert w5["kpi_opra_verified_primary"]["end_nav"] == 297924.92
    assert w5["kpi_opra_verified_primary"]["cagr_pct"] == 24.23
    assert w5["kpi_opra_verified_primary"]["max_dd_pct"] == -23.11
    assert w5["kpi_opra_verified_primary"]["calmar"] == 1.048
    assert w5["kpi_primary"]["end_nav"] == 317651.96
    assert w5["kpi_primary"]["cagr_pct"] == 21.33
    assert w5["kpi_primary"]["max_dd_pct"] == -23.11
    assert w5["kpi_primary"]["calmar"] == 0.923
    assert w5["kpi_primary"]["peak_gross_leverage"] == 1.2475
