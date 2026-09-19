#!/usr/bin/env python3
"""Reconcile a frozen, user-visible missing-target set; never approve a model.

Unlike the selected-book staging inventory, this denominator includes all frozen
current dashboard/detail clickable symbols. Raw licensed rows remain in memory;
the private output retains only availability, typed review states and hashes.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import json
import re
from pathlib import Path


def sha(value):
    raw = value if isinstance(value, bytes) else json.dumps(value, sort_keys=True, default=str).encode()
    return hashlib.sha256(raw).hexdigest()


def index_rows(rows, key):
    result = collections.defaultdict(list)
    for row in rows:
        result[row.get(key)].append(row)
    return result


def disposition(inventory_rows, metadata, observed_cusips):
    statuses = {r.get("status") for r in inventory_rows}
    if len(statuses) > 1:
        return "conflicting_security_dispositions_require_review", "No conflicting share/security classes may be collapsed by ticker."
    if "fund_not_operating_company" in statuses:
        return "fund_requires_nav_or_fund_method", "Known fund/ETP identity; operating-company DCF is not applicable."
    if "missing_exact_local_identity" in statuses:
        return "share_class_or_local_identity_review", "Public holding identity exists, but exact local share-class identity is not reconciled. No alias or security factor is implied."
    if "needs_economic_profile_and_official_guidance_review" in statuses:
        return "exact_identity_issuer_review_candidate", "Prior exact-CUSIP inventory establishes input availability, not economic approval."
    # A symbol alone, or even a unique symbol/permaticker, is not identity proof.
    exact = [r for r in metadata if observed_cusips & set(re.findall(r"[A-Z0-9]{9}", r.get("cusips") or ""))]
    identities = {str(r.get("permaticker")) for r in exact}
    if len(identities) == 1 and exact:
        if any(r.get("isdelisted") == "Y" for r in exact):
            return "exact_local_identity_delisting_review", "Exact CUSIP metadata marks delisted; official corporate-action review is required, not a current operating price target."
        return "additional_exact_local_identity_candidate", "Exact-CUSIP local match outside the prior selected-book inventory; public identity and issuer economics still require review."
    if len(identities) > 1:
        return "ambiguous_local_identity", "The observed CUSIP has multiple local permanent identities."
    return "unresolved_or_historical_symbol", "No exact CUSIP-linked local match in the frozen visible occurrence set; ticker/name-only matching is prohibited."


def reconcile(visible, inventory, readiness, reviewed, metadata_rows, financial_rows, price_rows):
    scope = visible["currentQuarterAndLatestSnapshotInventory"]
    targets = scope["missingTickers"]
    if len(targets) != len(set(targets)) or len(targets) != scope["missingValuationTargets"]:
        raise ValueError("Missing-target denominator is duplicated or inconsistent")
    if scope["releasedValuationTargets"] + len(targets) != scope["uniqueClickableTargets"]:
        raise ValueError("Released + missing does not reconcile to the frozen denominator")
    inv = index_rows(inventory["securities"], "ticker")
    stage = {r["ticker"]: r for r in readiness["securities"]}
    reviews = {r["ticker"]: r for r in reviewed.get("companies", [])}
    meta = index_rows(metadata_rows, "ticker")
    financials = index_rows(financial_rows, "ticker")
    prices = index_rows(price_rows, "ticker")
    # Match the frozen audit's currentOnly definition exactly. Historical
    # exposure CUSIPs must not authorize today's symbol/share-class identity.
    current_occurrences = [r for r in visible["occurrences"] if r.get("rendered") and r.get("clickable")
        and not r.get("conditional") and (not r["surface"].startswith("exposure.") or r.get("reportDate") == "2026-06-30")]
    occurrences = index_rows(current_occurrences, "target")
    rows = []
    for ticker in sorted(targets):
        obs = occurrences[ticker]
        cusips = {r["cusip"] for r in obs if re.fullmatch(r"[A-Z0-9]{9}", r.get("cusip") or "")}
        kind, reason = disposition(inv[ticker], meta[ticker], cusips)
        staged = stage.get(ticker)
        review = reviews.get(ticker, {})
        financial = financials[ticker]
        price = prices[ticker]
        # Availability metadata is deliberately not an automatically approved model.
        first_visible = {}
        for r in financial:
            key = (r["fiscalperiod"], r["dimension"])
            date = str(r["datekey"])
            first_visible[key] = min(first_visible.get(key, date), date)
        rows.append({
            "ticker": ticker, "disposition": kind, "reason": reason,
            "observedIssuers": sorted({r.get("issuer") for r in obs if r.get("issuer")}),
            "observedCusips": sorted(cusips),
            "observedSurfaces": sorted({r["surface"] for r in obs}),
            "managers": sorted({r["guruId"] for r in obs if r.get("guruId")}),
            "securityInventoryStatuses": sorted({r["status"] for r in inv[ticker]}),
            "sourceAvailability": {
                "rawArqArtRows": len(financial), "earliestVisiblePeriodDimensionRows": len(first_visible),
                "latestFirstVisibleDate": max(first_visible.values(), default=None),
                "positivePriceRows": len(price), "lastPositivePriceDate": max((str(r["date"]) for r in price), default=None),
                "symbolMetadataRows": len(meta[ticker]), "metadataEvidenceSha256": sha(meta[ticker]),
                "symbolMetadataMarkedDelisted": any(r.get("isdelisted") == "Y" for r in meta[ticker]),
                "symbolAvailabilityIsIdentityProof": False,
            },
            "inputStage": {"staged": staged is not None, "financialInputStatus": staged.get("financialInputStatus") if staged else None,
                "guidanceExtractionStatus": staged.get("guidanceExtractionStatus") if staged else "not_in_frozen_staging_scope",
                "guidanceNote": staged.get("guidanceNote") if staged else None,
                "issuerReviewStatus": staged.get("issuerReviewStatus") if staged else "not_staged"},
            "separateReviewedBatch": {"genericHistoryReviewStatus": review.get("reviewStatus", "not_in_reviewed_batch"),
                "currentModelReview": review.get("currentModelReview")},
            "publication": {"releasedAtFrozenCut": False, "newlyPublishedByThisAudit": False,
                "releaseAuthorizedByThisAudit": False},
        })
    counts = dict(sorted(collections.Counter(r["disposition"] for r in rows).items()))
    assert sum(counts.values()) == len(targets)
    return {"schemaVersion": 1, "asOf": visible["asOf"], "status": "reconciled_inventory_not_release_authorization",
        "scope": "Frozen current-quarter dashboard + single-Guru snapshots + latest position trajectories; not all historical curves or all 13F holdings.",
        "denominator": {"clickableTargets": scope["uniqueClickableTargets"], "releasedTargets": scope["releasedValuationTargets"],
            "missingTargets": len(rows), "unknownIdentityKeysOutsideClickableDenominator": scope.get("unknownOrFallbackIdentityKeys"),
            "disabledPrivateOccurrencesOutsideClickableDenominator": scope.get("disabledPrivateOccurrences")},
        "dispositionCounts": counts, "stagedMissingTargets": sum(r["inputStage"]["staged"] for r in rows),
        "newlyPublished": 0, "rows": rows,
        "limitations": ["The frozen production snapshot is September 5, not a fresh live API probe.",
            "A typed input disposition or source row is not financial/economic-model approval.",
            "Delisting metadata is a provider flag requiring official corporate-action verification.",
            "Fund, private, historical-symbol and share-class gaps must never be filled with guessed generic DCFs.",
            "The full additive strict release gate remains unchanged."]}


def staging_inventory(report, metadata_rows, visible_path):
    """Exact current-CUSIP candidates only, not a relabeled historical book."""
    meta = index_rows(metadata_rows, "ticker")
    selected, blocked = [], []
    visible_hash = sha(visible_path.read_bytes())
    for row in report["rows"]:
        if row["inputStage"]["staged"] or row["disposition"] not in {
            "exact_identity_issuer_review_candidate", "additional_exact_local_identity_candidate"}:
            continue
        matched = [r for r in meta[row["ticker"]] if set(row["observedCusips"]) &
            set(re.findall(r"[A-Z0-9]{9}", r.get("cusips") or ""))]
        sf1 = [r for r in matched if r["table"] == "SF1"]
        sep = [r for r in matched if r["table"] == "SEP"]
        ids = {str(r["permaticker"]) for r in matched}
        source_currencies = {r.get("currency") for r in sf1}
        quote_currencies = {r.get("currency") for r in sep}
        ciks = {re.search(r"CIK=(\d+)", r.get("secfilings") or "").group(1).zfill(10)
            for r in sf1 if re.search(r"CIK=(\d+)", r.get("secfilings") or "")}
        cusips = sorted(set(row["observedCusips"]) & set().union(*[
            set(re.findall(r"[A-Z0-9]{9}", r.get("cusips") or "")) for r in sf1]))
        if len(ids) != 1 or not sf1 or not sep or len(ciks) != 1 or len(source_currencies) != 1 or None in source_currencies or len(quote_currencies) != 1 or None in quote_currencies or len(cusips) != 1:
            blocked.append({"ticker": row["ticker"], "reason": "Current CUSIP / SF1 / SEP / CIK / currency is not a unique complete identity", "cusips": cusips})
            continue
        record = sorted(sf1, key=lambda r: str(r.get("lastupdated")))[-1]
        selected.append({"ticker": row["ticker"], "name": record["name"], "cusip": cusips[0],
            "cik": next(iter(ciks)), "secFilings": record["secfilings"],
            "reportingCurrency": next(iter(source_currencies)), "quoteCurrency": next(iter(quote_currencies)),
            "industry": record.get("industry"), "sector": record.get("sector"),
            "status": "needs_economic_profile_and_official_guidance_review", "localIdentityMatch": True,
            "inCurrentVisibleTarget": True, "inLatestSelectedBook": False,
            "currentVisibleEvidence": {"sourcePath": str(visible_path.resolve()), "sourceSha256": visible_hash,
                "inventoryKey": "currentQuarterAndLatestSnapshotInventory", "ticker": row["ticker"],
                "cusip": cusips[0], "surfaces": row["observedSurfaces"], "managerIds": row["managers"],
                "metadataSha256": row["sourceAvailability"]["metadataEvidenceSha256"]},
            "sourceMetadataRecords": meta[row["ticker"]],
            "sourceMetadataHashConvention": "sha256 of json.dumps(records, sort_keys=True, default=str), UTF-8; original SF1/SEP records, dates ISO strings",
            "reviewStatus": "unreviewed", "economicModelAuthorized": False})
    return {"schemaVersion": 1, "asOf": report["asOf"], "scope": "exact_cusip_current_visible_targets_not_latest_selected_book",
        "status": "private_staging_candidates_only", "securities": selected, "blockedCandidates": blocked,
        "sourceVisibilityBinding": {"path": str(visible_path.resolve()), "sha256": visible_hash},
        "productionWrites": 0, "economicApproval": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("visible", "inventory", "readiness", "reviewed-batch", "jansen-root", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--staging-output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError("Refusing to overwrite a prior audit")
    if args.staging_output and args.staging_output.exists():
        raise FileExistsError("Refusing to overwrite a prior staging inventory")
    import pyarrow.dataset as ds
    inputs = {n: getattr(args, n) for n in ("visible", "inventory", "readiness", "reviewed_batch")}
    loaded = {n: json.loads(p.read_text()) for n, p in inputs.items()}
    targets = loaded["visible"]["currentQuarterAndLatestSnapshotInventory"]["missingTickers"]
    cutoff = dt.date.fromisoformat(loaded["visible"]["asOf"])
    metadata = ds.dataset(args.jansen_root / "tickers", format="parquet", partitioning="hive").to_table(
        filter=ds.field("ticker").isin(targets) & ds.field("table").isin(["SF1", "SEP"])).to_pylist()
    fds = ds.dataset(args.jansen_root / "fundamentals", format="parquet", partitioning="hive")
    datekey = "datekey" if "datekey" in fds.schema.names else "date"
    financials = fds.to_table(columns=["ticker", "fiscalperiod", "dimension", datekey], filter=(
        ds.field("ticker").isin(targets) & ds.field("dimension").isin(["ARQ", "ART"]) & (ds.field(datekey) <= cutoff))).to_pylist()
    if datekey != "datekey":
        financials = [{**r, "datekey": r[datekey]} for r in financials]
    prices = ds.dataset(args.jansen_root / "prices", format="parquet", partitioning="hive").to_table(
        columns=["ticker", "date"], filter=ds.field("ticker").isin(targets) & (ds.field("date") <= cutoff) & (ds.field("close") > 0)).to_pylist()
    report = reconcile(loaded["visible"], loaded["inventory"], loaded["readiness"], loaded["reviewed_batch"], metadata, financials, prices)
    report["inputBindings"] = {n: {"file": str(p.resolve()), "sha256": sha(p.read_bytes())} for n, p in inputs.items()}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    if args.staging_output:
        staging = staging_inventory(report, metadata, args.visible)
        args.staging_output.parent.mkdir(parents=True, exist_ok=True)
        args.staging_output.write_text(json.dumps(staging, indent=2, default=str) + "\n")
        print(json.dumps({"stagingCandidates": len(staging["securities"]), "stagingIdentityBlockers": staging["blockedCandidates"]}))
    print(json.dumps({k: v for k, v in report.items() if k not in {"rows", "inputBindings"}}, indent=2))


if __name__ == "__main__":
    main()
