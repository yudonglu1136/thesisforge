"""Pure, fail-closed application of reviewed, period-specific input corrections.

No database access. Call on the complete issuer slice before candidate writes;
returned rows contain payload_json, while every original raw provider field is
retained in lineage. This does not approve historical rows or a production release.
"""
import copy
from datetime import date
import hashlib
import json
import math
import re
from urllib.parse import urlparse


def _same_number(left, right):
    return (isinstance(left, (int, float)) and not isinstance(left, bool)
            and isinstance(right, (int, float)) and not isinstance(right, bool)
            and math.isfinite(left) and math.isfinite(right)
            and math.isclose(left, right, rel_tol=0, abs_tol=1e-8))


def _valid_date(value):
    try:
        return isinstance(value, str) and len(value) == 10 and date.fromisoformat(value).isoformat() == value
    except ValueError:
        return False


def _same_original(left, right):
    return (left is None and right is None) or _same_number(left, right)


def _issuer_sec_source(url, company):
    source = urlparse(url)
    return (source.scheme == "https" and source.hostname == "www.sec.gov"
            and not source.username and not source.password
            and f"/data/{int(company['cik'])}/" in source.path)


def _validate_cash_derivation(correction, company):
    components = correction.get("sourceComponents")
    precision = correction.get("sourcePrecisionM")
    if (not components or not isinstance(components, list)
            or not _same_number(precision, precision) or precision <= 0
            or not correction.get("precisionPolicy")):
        raise ValueError("Cash correction requires exact source components and source precision")
    total = 0
    for component in components:
        if (component.get("multiplier") not in {-1, 1}
                or not _same_number(component.get("valueM"), component.get("valueM"))
                or not _issuer_sec_source(component.get("url", ""), company)
                or not re.fullmatch(r"[a-f0-9]{64}", component.get("sha256", ""))
                or not component.get("locator")
                or component.get("currency") != correction["currency"]
                or not _valid_date(component.get("availableDate"))
                or not _valid_date(component.get("periodEndDate"))
                or component["availableDate"] > correction["expectedRecordAvailableDate"]
                or component["periodEndDate"] > component["availableDate"]):
            raise ValueError("Cash correction source component identity/date/value is invalid")
        total += component["multiplier"] * component["valueM"]
    # Source precision is provenance, never permission to widen equality.
    if not _same_number(total, correction["value"]):
        raise ValueError("Cash correction does not equal its exact source derivation")


def apply_reviewed_input_corrections(company, records):
    """Return a corrected deep copy of a complete ticker's SQL-row dictionaries.

    Required row keys: ticker, fiscal_period, dimension, available_at,
    report_period, currency, payload_json. Unmatched periods stay byte-for-byte
    unchanged. Each correction requires exactly one row for every named dimension.
    """
    corrections = company.get("inputCorrections", [])
    result = copy.deepcopy(records)
    if not corrections:
        return result
    if company.get("reviewStatus") != "reviewed" or company.get("economicReview", {}).get("releaseBlockers"):
        raise ValueError("Corrections require an explicitly approved economic review")
    seen_ids = set()
    cash_touched = set()
    for correction in corrections:
        correction_id = correction.get("id")
        if not correction_id or correction_id in seen_ids:
            raise ValueError("Corrections require unique ids")
        seen_ids.add(correction_id)
        field = correction.get("field")
        is_cash = field in {"cfo_m", "capex_m", "fcf_after_capex_m"}
        is_monetary = is_cash or field in {"revenue_m", "gross_profit_m", "operating_income_m", "net_income_m"}
        if not ((field == "shares_m" and correction.get("unit") == "million_common_shares")
                or (is_monetary and correction.get("unit") == "million_reporting_currency")):
            raise ValueError("Only independently reviewed common-share or cash-flow corrections are supported")
        if not _issuer_sec_source(correction.get("sourceUrl", ""), company):
            raise ValueError("Correction source must be the exact issuer's official SEC filing")
        if not correction.get("sourceLocator") or not correction.get("reason"):
            raise ValueError("Correction requires a source locator and reason")
        if (not all(_valid_date(correction.get(key)) for key in
                    ("sourceAvailableDate", "expectedRecordAvailableDate", "periodEndDate"))
                or correction.get("currency") != company.get("currency")
                or correction.get("sourceAvailableDate", "9999") > correction.get("expectedRecordAvailableDate", "")
                or correction.get("periodEndDate", "9999") > correction.get("sourceAvailableDate", "")):
            raise ValueError("Correction currency/date scope is invalid")
        if (not _same_number(correction.get("value"), correction.get("value"))
                or (field == "shares_m" and correction["value"] <= 0)
                or (field == "capex_m" and correction["value"] < 0)):
            raise ValueError("Corrected shares must be finite positive; cash flow must be finite and cash capex nonnegative")
        if "expectedOriginalValue" not in correction:
            raise ValueError("Correction must explicitly identify its original value, including null")
        if is_monetary:
            _validate_cash_derivation(correction, company)
        dimensions = correction.get("dimensions", [])
        if not dimensions or len(set(dimensions)) != len(dimensions) or not set(dimensions) <= {"ARQ", "ART"}:
            raise ValueError("Correction needs explicit unique financial dimensions")
        matches = [row for row in result if row.get("ticker") == company["ticker"]
                   and row.get("fiscal_period") == correction["fiscalPeriod"]
                   and row.get("dimension") in dimensions]
        if len(matches) != len(dimensions) or sorted(row.get("dimension") for row in matches) != sorted(dimensions):
            raise ValueError(f"{correction_id}: missing or duplicated exact-period dimensions")
        digest = hashlib.sha256(json.dumps(correction, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        for row in matches:
            payload = json.loads(row["payload_json"])
            if (row.get("currency") != correction["currency"]
                    or row.get("report_period") != correction["periodEndDate"]
                    or row.get("available_at") != correction["expectedRecordAvailableDate"]
                    or payload.get("ticker") != company["ticker"]
                    or payload.get("periodEndDate") != correction["periodEndDate"]
                    or payload.get("asOfDate") != correction["expectedRecordAvailableDate"]
                    or payload.get("financialStatementCurrency") != correction["currency"]
                    or payload.get("sourceDimension") != row["dimension"]):
                raise ValueError(f"{correction_id}: record identity, date, dimension or currency mismatch")
            source_record = payload.setdefault("sourceRecord", {})
            if not _same_number(source_record.get("appliedShareFactor"), 1):
                raise ValueError(f"{correction_id}: unexpected quoted-security factor")
            lineage = source_record.setdefault("reviewedInputCorrections", [])
            existing = [item for item in lineage if item.get("id") == correction_id]
            if existing:
                if (len(existing) != 1 or existing[0].get("correctionSha256") != digest
                        or not _same_number(payload.get(field), correction["value"])
                        or not _same_original(existing[0].get("originalValue"), correction["expectedOriginalValue"])):
                    raise ValueError(f"{correction_id}: conflicting prior correction lineage")
                continue
            if field not in payload or not _same_original(payload.get(field), correction.get("expectedOriginalValue")):
                raise ValueError(f"{correction_id}: original input changed; re-review required")
            expected_raw_hash = correction.get("expectedOriginalPayloadSha256ByDimension", {}).get(row["dimension"])
            if is_monetary and not expected_raw_hash:
                raise ValueError("Monetary correction requires trusted original payload hash by dimension")
            if expected_raw_hash:
                preserved = source_record.get("reviewedOriginalFinancialPayload")
                original_json = preserved["json"] if preserved else row["payload_json"]
                original_hash = hashlib.sha256(original_json.encode()).hexdigest()
                if original_hash != expected_raw_hash or (preserved and preserved.get("sha256") != original_hash):
                    raise ValueError("Original provider financial payload does not match trusted source hash")
                source_record["reviewedOriginalFinancialPayload"] = {"json": original_json, "sha256": original_hash}
            sources = payload.setdefault("sources", {})
            lineage.append({
                **copy.deepcopy(correction),
                "originalValue": payload[field],
                "originalSource": copy.deepcopy(sources.get(field)),
                **({"originalShareCountPolicy": source_record.get("shareCountPolicy")} if field == "shares_m" else {}),
                "correctionSha256": digest,
                "reviewedAt": company["reviewedAt"],
            })
            payload[field] = correction["value"]
            if not is_monetary:
                source_record["shareCountBasis"] = "official_period_end_common_shares"
                source_record["shareCountPolicy"] = (
                    "Period-end basic ordinary shares from the independently reviewed official SEC statement; "
                    "original provider denominator and policy preserved in correction lineage."
                )
            sources[field] = {
                "dataset": "Official SEC financial statement; exact reviewed reconstruction" if is_monetary else "Official SEC period-end common shares; reviewed correction",
                "filed": correction["sourceAvailableDate"],
                "end": correction["periodEndDate"],
                "url": correction["sourceUrl"],
                "locator": correction["sourceLocator"],
                **({"precisionM": correction["sourcePrecisionM"], "sourceComponents": copy.deepcopy(correction["sourceComponents"])} if is_monetary else {"precisionShares": correction["sourcePrecisionShares"]}),
                "correctionId": correction_id,
                "correctionSha256": digest,
            }
            row["payload_json"] = json.dumps(payload, separators=(",", ":"))
            if is_cash:
                cash_touched.add((row["ticker"], row["fiscal_period"], row["dimension"]))
    for row in result:
        if (row.get("ticker"), row.get("fiscal_period"), row.get("dimension")) not in cash_touched:
            continue
        payload = json.loads(row["payload_json"])
        cfo, capex, fcf = (payload.get(field) for field in ["cfo_m", "capex_m", "fcf_after_capex_m"])
        if not all(_same_number(v, v) for v in [cfo, capex, fcf]) or not _same_number(cfo - capex, fcf):
            raise ValueError("Corrected cash-flow identity CFO minus cash capex must equal FCF")
    return result
