#!/usr/bin/env python3
"""Capture exact original SEC sources for SPOT's dated current-only model.

No economic approval, model database write or publication occurs here. The
separate source-row review must corroborate amounts before normal adaptation.
"""
import argparse
from hashlib import sha256
import json
from pathlib import Path
from urllib.parse import urlparse
import requests
from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "output/guru-valuation-expansion-2026-09-05"
CONFIG = ROOT / "server/config/guru-current-economic-evidence.json"


def binding(path):
    raw = path.read_bytes()
    return {"path": str(path.resolve()), "sha256": sha256(raw).hexdigest(), "byteLength": len(raw)}


def build(output):
    target = output / "spot-source-bindings.json"
    if target.exists():
        raise FileExistsError("Immutable source output exists")
    config = json.loads(CONFIG.read_text())
    company = config["companies"]["SPOT"]
    submission = BASE / "official-sec-cache/SPOT/submission.json"
    recent = json.loads(submission.read_text())["filings"]["recent"]
    accessions = {a.replace("-", ""): i for i, a in enumerate(recent["accessionNumber"])}
    docs = []
    sources = {**company["sources"], "q32026_guidance": {
        "availableDate": "2026-08-04", "url": "https://www.sec.gov/Archives/edgar/data/1639920/000114036126031044/ef20078867_ex99-1.htm",
        "locator": "Outlook for Q3'26; quarterly revenue and operating income, not parent FCFE guidance"}}
    for source_id, source in sources.items():
        url = source["url"]
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.hostname != "www.sec.gov" or not parsed.path.startswith("/Archives/edgar/data/1639920/"):
            raise ValueError("Not an explicitly reviewed SPOT SEC source")
        accession, filename = parsed.path.split("/")[-2:]
        index = accessions.get(accession)
        if index is None or recent["filingDate"][index] != source["availableDate"]:
            raise ValueError("Source publication date is not bound to original SEC index")
        if source["availableDate"] > config["reviewedAt"]:
            raise ValueError("Future evidence")
        cached = BASE / "official-sec-cache/SPOT" / accession / filename
        destination = output / "source-bytes" / (sha256(url.encode()).hexdigest()[:20] + ".html")
        if cached.is_file():
            raw = cached.read_bytes()
        else:
            response = requests.get(url, headers={"User-Agent": "ThesisForge economic research research@thesisforge.tech"}, timeout=45)
            response.raise_for_status()
            raw = response.content
        if b"undeclared automated tool" in raw.lower() or b"request rate threshold exceeded" in raw.lower():
            raise ValueError("Access-denial page is not issuer evidence")
        soup = BeautifulSoup(raw, "html.parser")
        for node in soup(["script", "style"]):
            node.decompose()
        text = " ".join(soup.get_text(" ", strip=True).split())
        if "SPOTIFY" not in text.upper() or len(text) < 10000:
            raise ValueError("Missing substantive original issuer document")
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("xb") as handle:
            handle.write(raw)
        docs.append({"sourceId": source_id, **source, **binding(destination),
            "submissionBinding": {"accession": recent["accessionNumber"][index], "form": recent["form"][index],
                "filed": recent["filingDate"][index], "acceptedAt": recent["acceptanceDateTime"][index]},
            "tables": [" ".join(t.get_text(" ", strip=True).split()) for t in soup.find_all("table") if len(t.get_text()) < 100000],
            "visibleText": text})
    result = {"schemaVersion": 1, "ticker": "SPOT", "asOfDate": config["reviewedAt"],
        "status": "source_bytes_bound_separate_economic_review_required", "historicalApproval": False,
        "configBinding": binding(CONFIG), "submissionIndexBinding": binding(submission), "documents": docs}
    target.write_text(json.dumps(result, indent=2) + "\n")
    return {"documents": len(docs), **binding(target)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    print(json.dumps(build(parser.parse_args().output_dir)))
