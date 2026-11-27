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
    # Exact verified Plan D Real MIT OPRA segment (2015-01-02 -> 2025-12-15)
    assert w11["kpi_opra_verified_primary"]["end_nav"] == 944612.24
    assert w11["kpi_opra_verified_primary"]["cagr_pct"] == 22.76
    assert w11["kpi_opra_verified_primary"]["max_dd_pct"] == -24.31
    assert w11["kpi_opra_verified_primary"]["calmar"] == 0.936
    assert w11["kpi_opra_verified_primary"]["put_gross_turnover_pct_nav_yr"] == 6.36
    assert w11["kpi_opra_verified_primary"]["put_roll_salvage_pct"] == 67.9
    assert w11["kpi_opra_verified_primary"]["put_true_net_bleed_pct_nav_yr"] == 2.04
    # Full continuous window through 2026-11-25 (real spot + OPRA-residual-calibrated BSM extension)
    assert w11["kpi_primary"]["end_nav"] == 1007159.55
    assert w11["kpi_primary"]["cagr_pct"] == 21.43
    assert w11["kpi_primary"]["max_dd_pct"] == -24.31
    assert w11["kpi_primary"]["calmar"] == 0.881
    assert w11["kpi_primary"]["peak_gross_leverage"] == 1.257
    assert w11["kpi_primary"]["put_trades_m4"] == 3
    assert w11["kpi_primary"]["cta_rotation_count"] == 10
    assert len(w11["crisis_comparison"]) == 9
    assert len(w11["latch_episodes"]) == 1

    w5 = doc["backtest"]["windows"]["5y_live"]
    assert w5["zero_splice"] is True
    assert w5["end_date"] == "2026-11-25"
    # Exact verified Plan D 5Y Zero-Splice Real MIT OPRA segment (2020-12-03 -> 2025-12-15)
    assert w5["kpi_opra_verified_primary"]["end_nav"] == 301989.15
    assert w5["kpi_opra_verified_primary"]["cagr_pct"] == 24.56
    assert w5["kpi_opra_verified_primary"]["max_dd_pct"] == -23.67
    assert w5["kpi_opra_verified_primary"]["calmar"] == 1.038
    assert w5["kpi_primary"]["end_nav"] == 321985.31
    assert w5["kpi_primary"]["cagr_pct"] == 21.61
    assert w5["kpi_primary"]["max_dd_pct"] == -23.67
    assert w5["kpi_primary"]["calmar"] == 0.913
    assert w5["kpi_primary"]["peak_gross_leverage"] == 1.2493
