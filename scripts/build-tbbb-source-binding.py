#!/usr/bin/env python3
"""Freeze the exact source bytes used by the dated TBBB current-only model.

No databases or approval states are accessed. Existing SEC cache is read-only.
Source capture is evidence, not a claim that all economic judgments are audited.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
import json
from pathlib import Path
import re
from urllib.parse import urlparse

import requests
from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "output/guru-valuation-expansion-2026-09-05"
UA = "ThesisForge economic research contact research@thesisforge.tech"


def file_binding(path):
    raw = path.read_bytes()
    return {"path": str(path.resolve()), "sha256": sha256(raw).hexdigest(), "byteLength": len(raw)}


def capture(source, output):
    url = source["url"]
    parts = urlparse(url)
    allowed = {"www.sec.gov", "home.treasury.gov", "pages.stern.nyu.edu", "www.banxico.org.mx",
               "www.federalreserve.gov", "data-api.ecb.europa.eu"}
    if parts.scheme != "https" or parts.hostname not in allowed:
        raise ValueError("Unexpected source host")
    is_sec = parts.hostname == "www.sec.gov"
    if is_sec and not parts.path.startswith("/Archives/edgar/data/1978954/"):
        raise ValueError("Wrong issuer")
    stem = sha256(url.encode()).hexdigest()[:20]
    dest = output / "source-bytes" / (stem + (".pdf" if parts.path.endswith(".pdf") else ".source"))
    if not dest.exists():
        cached = BASE / "official-sec-cache/TBBB" / "/".join(parts.path.split("/")[-2:])
        if is_sec and cached.exists():
            raw = cached.read_bytes()
        else:
            response = requests.get(url, headers={"User-Agent": UA}, timeout=45)
            response.raise_for_status()
            raw = response.content
        if b"undeclared automated tool" in raw.lower() or b"request rate threshold exceeded" in raw.lower():
            raise ValueError("SEC access page is not issuer evidence")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(raw)
    raw = dest.read_bytes()
    result = {**source, **file_binding(dest), "sourceAuthority": "issuer_SEC" if is_sec else
              "original_author_risk_estimate" if parts.hostname == "pages.stern.nyu.edu" else "official_macro"}
    if not raw.startswith(b"%PDF"):
        soup = BeautifulSoup(raw, "html.parser")
        for node in soup(["script", "style"]): node.decompose()
        visible = " ".join(soup.get_text(" ", strip=True).split())
        result["visibleText"] = visible
        result["tables"] = [" ".join(t.get_text(" ", strip=True).split()) for t in soup.find_all("table")
                            if len(t.get_text()) < 100000]
        tokens = r"preferred|supplier finance|Class [ABC]|pari passu|ordinary shares|bank deposits|liquidity|capital expenditures|29%|32%|new options|2,860,000|January 2026|January 5|Mexico|United States"
        result["reviewPassages"] = [visible[max(0, m.start()-160):m.end()+650]
                                    for m in list(re.finditer(tokens, visible, re.I))[:300]]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    target = args.output_dir / "tbbb-source-bindings.json"
    if target.exists(): raise ValueError("Immutable output already exists")
    configs = [ROOT / "server/config/tbbb-economic-evidence.json", ROOT / "server/config/tbbb-underwriting-2026-09-05.json"]
    records = {}
    for path in configs:
        for key, source in json.loads(path.read_text())["sources"].items():
            if source["availableDate"] > "2026-09-05": raise ValueError("Future source")
            record = records.setdefault(source["url"], {**source, "configReferences": []})
            if record["availableDate"] != source["availableDate"]: raise ValueError("Conflicting date")
            record["configReferences"].append({"file": path.name, "sourceId": key, "locator": source["locator"]})
    # Also bind each quarterly revenue source used by the latest-eight-slot
    # growth calculation. These original files corroborate the current model's
    # trend input; they do not authorize historical economic valuation methods.
    growth_sources = [
        ("growth_fy2024", "000095017025052612", "4q24_earnings_release.htm"),
        ("growth_q12025", "000095017025065694", "1q25_earnings_release.htm"),
        ("growth_q22025", "000095017025106589", "2q25_earnings_release.htm"),
        ("growth_q32025", "000119312525288308", "3q25_release_6k.htm"),
        ("growth_q12026", "000119312526209052", "6-k_tbbb_1q26_earnings_r.htm"),
        ("growth_q12024", "000095017024063626", "earnings_release_1q24.htm"),
        ("growth_q32024", "000095017024130598", "earnings_release_3q24.htm")
    ]
    submission = BASE / "official-sec-cache/TBBB/submission.json"
    recent = json.loads(submission.read_text())["filings"]["recent"]
    accession_index = {x.replace("-", ""): i for i, x in enumerate(recent["accessionNumber"])}
    for key, acc, document in growth_sources:
        index = accession_index[acc]
        url = f"https://www.sec.gov/Archives/edgar/data/1978954/{acc}/{document}"
        records[url] = {"url": url, "availableDate": recent["filingDate"][index],
                        "locator": "Quarterly total revenue and comparative; currency convention in issuer release",
                        "configReferences": [{"file": "tbbb-unapproved-scenarios.json", "sourceId": key,
                                              "locator": "financialTrendEvidence.observations current/comparator"}]}
    for record in records.values():
        if urlparse(record["url"]).hostname != "www.sec.gov": continue
        acc = urlparse(record["url"]).path.split("/")[-2]
        index = accession_index.get(acc)
        if index is None: raise ValueError("SEC date cannot be bound to submission index")
        if recent["filingDate"][index] != record["availableDate"]: raise ValueError("SEC date mismatch")
        record["submissionBinding"] = {"accession": recent["accessionNumber"][index],
                                      "form": recent["form"][index], "filed": recent["filingDate"][index],
                                      "acceptedAt": recent["acceptanceDateTime"][index]}
    with ThreadPoolExecutor(max_workers=2) as pool:
        documents = list(pool.map(lambda item: capture(item, args.output_dir), records.values()))
    result = {"schemaVersion": "tbbb-source-binding-v1", "sourceCutoff": "2026-09-05",
              "reviewedAt": "2026-09-06", "status": "source_bytes_bound_economic_review_separate",
              "historicalApproval": False, "productionWrites": 0,
              "configBindings": [file_binding(path) for path in configs],
              "submissionIndexBinding": file_binding(submission), "documents": documents}
    args.output_dir.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(result, indent=2, sort_keys=True)+"\n")
    print(json.dumps({"output": str(target.resolve()), "documents": len(documents), **file_binding(target)}))


if __name__ == "__main__": main()
