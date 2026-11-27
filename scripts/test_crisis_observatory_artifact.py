"""Pytest verification suite for Crisis Observatory v2.0 Single Master Strategy artifact."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_PATH = ROOT / "server" / "config" / "crisis-observatory-dashboard.json"


def test_v2_artifact_benchmarks_and_strict_hygiene():
    assert ARTIFACT_PATH.exists(), "crisis-observatory-dashboard.json must exist"
    raw = ARTIFACT_PATH.read_text(encoding="utf-8")
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
    assert doc["version"] == "crisis-observatory-v2-master"
    assert doc["strategy_code"] == "V2_QQQ_DUALCTA_TAILPUT_SINGLE"
    assert doc["ruleset"]["single_strategy_only"] is True
    assert doc["ruleset"]["core_overlay"]["hard_leverage_cap"] == 1.2

    prov = doc["backtest"]["opra_provenance"]
    assert prov["quotes_count"] == 6382288
    assert prov["execution_fallbacks"] == 0
    assert prov["opra_end"] == "2025-12-15"
    assert prov["extended_end"] == "2026-11-25"
    assert prov["sim_extension_days"] == 238
    assert prov["bsm_calibration"]["fit_quotes_count"] == 1500755
    assert prov["bsm_calibration"]["oos_2026_real_n"] == 9937

    w11 = doc["backtest"]["windows"]["11y_opra"]
    assert w11["opra_cutoff_date"] == "2025-12-15"
    assert w11["end_date"] == "2026-11-25"
    assert w11["sim_extension_days"] == 238
    # Immutable pure real-OPRA segment <= 2025-12-15 (zero drift!)
    assert w11["kpi_opra_verified_primary"]["end_nav"] == 707763.27
    assert w11["kpi_opra_verified_primary"]["cagr_pct"] == 19.57
    assert w11["kpi_opra_verified_primary"]["max_dd_pct"] == -28.47
    assert w11["kpi_opra_verified_primary"]["calmar"] == 0.687
    # Full continuous window through 2026-11-25 (real spot + OPRA-residual-calibrated BSM extension)
    assert w11["kpi_primary"]["end_nav"] == 750383.65
    assert w11["kpi_primary"]["cagr_pct"] == 18.46
    assert w11["kpi_primary"]["max_dd_pct"] == -28.47
    assert w11["kpi_primary"]["calmar"] == 0.648
    assert w11["kpi_primary"]["peak_gross_leverage"] == 1.2
    assert w11["kpi_primary"]["put_trades_m4"] == 3
    assert w11["kpi_primary"]["cta_rotation_slices"] == 10
    assert len(w11["crisis_comparison"]) == 9

    w5 = doc["backtest"]["windows"]["5y_live"]
    assert w5["zero_splice"] is True
    assert w5["end_date"] == "2026-11-25"
    assert w5["kpi_opra_verified_primary"]["end_nav"] == 235714.95
    assert w5["kpi_opra_verified_primary"]["cagr_pct"] == 18.57
    assert w5["kpi_opra_verified_primary"]["max_dd_pct"] == -28.47
    assert w5["kpi_opra_verified_primary"]["calmar"] == 0.652
    assert w5["kpi_primary"]["end_nav"] == 249909.33
    assert w5["kpi_primary"]["cagr_pct"] == 16.55
    assert w5["kpi_primary"]["max_dd_pct"] == -28.47
    assert w5["kpi_primary"]["calmar"] == 0.581
    assert w5["kpi_primary"]["peak_gross_leverage"] == 1.2
