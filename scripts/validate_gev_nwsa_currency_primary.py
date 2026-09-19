"""Two exact, dated parent/group reporting-currency declarations. No inference."""
import hashlib
from pathlib import Path
import re
from bs4 import BeautifulSoup

REVIEWED = {
    "GEV": dict(cik="0001996810", sourceId="99db92ac9e105e032d544068", observedAt="2024-04-25", availableAt="2024-03-05",
                form="10-12B/A", accession="0001193125-24-059354", name="d542465dex991.htm",
                docSha="6e188b2af11ef157d6140c03c70ccc17b635eb12fc39dc5f9b9bf5989e7784a5",
                header="0001193125-24-059354-index-headers.html", headerSha="7dc91712cf98ee48055afa9c2c81c1453055dd304490c2e1bf4e27b591e4ea64",
                declaration="Additionally, we are subject to foreign exchange translation risk due to changes in the value of foreign currencies in relation to our reporting currency, the U.S. Dollar.",
                identity="General Electric Company (“GE”) of its wholly-owned subsidiary, GE Vernova LLC (together with its subsidiaries, “GE Vernova,” the “Company,” “we,” “us,” or “our”)"),
    "NWSA": dict(cik="0001564708", sourceId="b16468d693c7d2867723e024", observedAt="2013-11-11", availableAt="2013-09-20",
                 form="10-K", accession="0001193125-13-373501", name="d581644d10k.htm",
                 docSha="776c07856438141df9490ac77f01cedd733d28b7504545e2a359c1269be9eb98",
                 header="0001193125-13-373501-index.html", headerSha="5d1215f7497a42a247ed1d34efef968816c95c990322c3e146837cca00480e6e",
                 declaration="Foreign currency translation risk is the risk that exchange rate gains or losses arise from translating foreign entities’ statements of earnings and balance sheets from functional currency to the Company’s reporting currency (the U.S. dollar) for consolidation purposes.",
                 identity="NEWS CORPORATION (Exact Name of Registrant as Specified in its Charter)"),
}


def digest(raw):
    return hashlib.sha256(raw.encode()).hexdigest()


def normalized(raw):
    return re.sub(r"\s+", " ", BeautifulSoup(raw, "html.parser").get_text(" ", strip=True))


def validate_header_text(ticker, text):
    spec = REVIEWED[ticker]
    if ticker == "GEV":
        expected = [rf"ACCESSION NUMBER:\s*{spec['accession']}", rf"CONFORMED SUBMISSION TYPE:\s*{spec['form']}",
                    r"FILED AS OF DATE:\s*20240305\b", rf"CENTRAL INDEX KEY:\s*{spec['cik']}\b", r"COMPANY CONFORMED NAME:\s*GE Vernova LLC"]
    else:
        expected = [rf"SEC Accession No\. {spec['accession']}", r"Filing Date 2013-09-20\b", r"Form 10-K - Annual report",
                    r"NEWS CORP \(Filer\) CIK : 0001564708\b", r"10-K d581644d10k\.htm 10-K"]
    if not all(re.search(pattern, text) for pattern in expected):
        raise ValueError("Original filing header date/form/issuer/accession conflict")


def validate_exact_metadata(event, proof):
    spec = REVIEWED[event["ticker"]]
    for field in ["sourceId", "observedAt"]:
        if event[field] != spec[field]:
            raise ValueError("Outside exact reviewed direct-currency event")
    for field in ["availableAt", "cik", "form", "accession"]:
        if proof.get(field) != spec[field]:
            raise ValueError("Exact direct-currency filing identity/date conflict")
    prefix = f"https://www.sec.gov/Archives/edgar/data/{int(spec['cik'])}/{spec['accession'].replace('-', '')}/"
    if proof.get("sourceUrl") != prefix + spec["name"] or proof.get("documentSha256") != spec["docSha"] or proof.get("inference") is not False:
        raise ValueError("Unreviewed direct-currency document or inference")
    if proof.get("quotes") != [spec["declaration"], spec["identity"]]:
        raise ValueError("Exact group reporting-currency declaration or group definition missing")
    return spec, prefix


def validate_exact_direct(event, proof, row, html):
    spec, prefix = validate_exact_metadata(event, proof)
    if digest(html) != spec["docSha"] or any(q not in normalized(html) for q in proof["quotes"]):
        raise ValueError("Frozen original currency document or paragraph mismatch")
    if digest(row["payload_json"]) != event.get("originalPayloadSha256"):
        raise ValueError("Direct-currency source payload changed; economic rebinding required")
    evidence = proof.get("filingDateEvidence") or {}
    if evidence.get("sourceUrl") != prefix + spec["header"] or evidence.get("documentSha256") != spec["headerSha"]:
        raise ValueError("Missing original filing-date header evidence")
    raw_header = Path(evidence["documentPath"]).read_text()
    if digest(raw_header) != spec["headerSha"]:
        raise ValueError("Frozen filing header SHA mismatch")
    text = normalized(raw_header)
    if event["ticker"] == "GEV":
        text = re.search(r"<SEC-HEADER>.*?</SEC-HEADER>", text)[0]
    validate_header_text(event["ticker"], text)
    proof["filingDateEvidence"] = {**evidence, "headerText": text, "headerTextSha256": digest(text)}
