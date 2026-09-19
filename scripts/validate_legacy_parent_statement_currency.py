"""Exact pre-reorganization DIS/CI original consolidated statement currency.

Reads the complete original XBRL and original filing index. Only no-dimension,
whole-entity CIK contexts qualify; financial or guidance values never change.
"""
import datetime as dt
import hashlib
from pathlib import Path
import re
import xml.etree.ElementTree as ET
from bs4 import BeautifulSoup

VERSION = "whole-entity-original-statement-xbrl-v1"
NS = {"x": "http://www.xbrl.org/2003/instance"}


def sha(raw):
    return hashlib.sha256(raw.encode()).hexdigest()


def normalized(raw):
    return re.sub(r"\s+", " ", BeautifulSoup(raw, "html.parser").get_text(" ", strip=True))


def validate_fragment_semantics(ticker, cik, xml):
    if xml.get("schemaVersion") != VERSION or xml.get("contextScope") != "whole_entity_no_dimensions":
        raise ValueError("Original whole-entity statement schema required")
    root_open = xml["rootOpenTag"]
    if sha(root_open) != xml["rootOpenTagSha256"] or not re.search(r'xmlns:iso4217="http://www\.xbrl\.org/2003/iso4217"', root_open):
        raise ValueError("Original namespace binding mismatch")
    fragments = xml["fragments"]
    if len(fragments) != 8 or len({f["key"] for f in fragments}) != 8 or any(sha(f["raw"]) != xml["fragmentsSha256"][i] for i,f in enumerate(fragments)):
        raise ValueError("Eight distinct original fragments and hashes required")
    root = ET.fromstring(root_open + "".join(f["raw"] for f in fragments) + xml["rootCloseTag"])
    if root.tag != "{" + NS["x"] + "}xbrl":
        raise ValueError("Not an XBRL original root")
    contexts = {c.attrib["id"]: c for c in root.findall("x:context", NS)}
    units = {u.attrib["id"]: u for u in root.findall("x:unit", NS)}
    if len(contexts) != 2 or len(units) != 2:
        raise ValueError("Exact two aggregate contexts and two currency/share units required")
    names = ["Assets", "SalesRevenueNet" if ticker == "DIS" else "Revenues", "NetCashProvidedByUsedInOperatingActivities", "EarningsPerShareDiluted"]
    decoded = []
    for name in names:
        facts = [f for f in root if re.fullmatch(r"\{http://(?:fasb\.org|xbrl\.us)/us-gaap/\d{4}-\d{2}-\d{2}\}" + name, f.tag)]
        if len(facts) != 1:
            raise ValueError("Missing/duplicate primary consolidated statement category")
        f = facts[0]
        c, u = contexts[f.attrib["contextRef"]], units[f.attrib["unitRef"]]
        ident = c.find("x:entity/x:identifier",NS)
        if ident.text != cik or ident.attrib.get("scheme") != "http://www.sec.gov/CIK" or c.find("x:entity/x:segment",NS) is not None or c.find("x:scenario",NS) is not None:
            raise ValueError("Segment/subsidiary/LP context cannot substitute for whole-entity consolidated parent")
        if not re.fullmatch(r"-?\d+(?:\.\d+)?", f.text or ""):
            raise ValueError("Non-numeric statement fact")
        period = c.find("x:period",NS)
        if name == "Assets":
            if period.findtext("x:instant",namespaces=NS) != xml["periodEnd"]:
                raise ValueError("Original parent balance period mismatch")
        elif period.findtext("x:endDate",namespaces=NS) != xml["periodEnd"] or not 330 <= (dt.date.fromisoformat(xml["periodEnd"]) - dt.date.fromisoformat(period.findtext("x:startDate",namespaces=NS))).days <= 380:
            raise ValueError("Original parent annual flow period mismatch")
        if name == "EarningsPerShareDiluted":
            if u.findtext("x:divide/x:unitNumerator/x:measure",namespaces=NS) != "iso4217:USD" or u.findtext("x:divide/x:unitDenominator/x:measure",namespaces=NS) not in {"shares","xbrli:shares"}:
                raise ValueError("Parent EPS unit must be USD per share")
        elif u.findtext("x:measure",namespaces=NS) != "iso4217:USD" or u.find("x:divide",NS) is not None:
            raise ValueError("Parent aggregate monetary unit must be USD")
        decoded.append(dict(concept=name,value=f.text,contextRef=f.attrib["contextRef"],unitRef=f.attrib["unitRef"]))
    if decoded != xml["reconstructedFacts"]:
        raise ValueError("Producer reconstruction conflicts with original parsed facts")


def validate_legacy_statement_proof(event, proof, row, html):
    ticker = event["ticker"]
    expected_cik = {"DIS":"0001001039","CI":"0000701221"}.get(ticker)
    cutoff = "2019-03-20" if ticker == "DIS" else "2018-12-20"
    if not expected_cik or proof["cik"] != expected_cik or event["observedAt"] >= cutoff or proof["form"] != "10-K" or proof.get("inference") is not False or proof["evidenceType"] != "dated_parent_statement_xbrl_currency":
        raise ValueError("Unreviewed historical issuer or reorganization boundary")
    if not 0 < (dt.date.fromisoformat(event["observedAt"]) - dt.date.fromisoformat(proof["availableAt"])).days <= 400:
        raise ValueError("Dated prior annual statement required")
    if sha(row["payload_json"]) != event["originalPayloadSha256"]:
        raise ValueError("Economic/source payload changed; exact rebinding required")
    title = "The Walt Disney Company and Subsidiaries Consolidated Statements of Income" if ticker == "DIS" else "Cigna Corporation Consolidated Statements of Income"
    if len(proof["quotes"]) != 1 or proof["quotes"][0].lower() != title.lower() or proof["quotes"][0] not in normalized(html):
        raise ValueError("Original issuer consolidated-statement ownership missing")
    xml = proof["xbrlStatementEvidence"]
    prefix = f"https://www.sec.gov/Archives/edgar/data/{int(expected_cik)}/{proof['accession'].replace('-','')}/"
    name = ("dis" if ticker == "DIS" else "ci") + "-" + xml["periodEnd"].replace("-","") + ".xml"
    if xml["sourceUrl"] != prefix + name or xml["periodEnd"] >= proof["availableAt"]:
        raise ValueError("Original XBRL same-filing period/date mismatch")
    original = Path(xml["documentPath"]).read_text()
    if sha(original) != xml["documentSha256"] or xml["rootOpenTag"] not in original or any(f["raw"] not in original for f in xml["fragments"]):
        raise ValueError("Original complete XBRL or exact fragments changed")
    validate_fragment_semantics(ticker, expected_cik, xml)
    # Verify the selected facts against the complete original instance as well,
    # not just a producer-picked fragment subset.
    whole = ET.fromstring(original)
    for fact in xml["reconstructedFacts"]:
        originals = [f for f in whole if f.tag.endswith("}"+fact["concept"]) and f.attrib.get("contextRef") == fact["contextRef"]]
        if not originals or any(f.text != fact["value"] or f.attrib.get("unitRef") != fact["unitRef"] for f in originals):
            raise ValueError("Whole original statement contains conflicting selected facts")
    header = proof["filingDateEvidence"]
    raw = Path(header["documentPath"]).read_text()
    text = normalized(raw)
    if header["sourceUrl"] != prefix + proof["accession"] + "-index.html" or sha(raw) != header["documentSha256"] or text != header["headerText"] or sha(text) != header["headerTextSha256"]:
        raise ValueError("Original filing index binding mismatch")
    if re.search(r"Filing Date (\d{4}-\d{2}-\d{2})",text)[1] != proof["availableAt"] or not re.search(r"CIK\s*:\s*"+expected_cik+r"\b",text) or proof["accession"] not in text or "Form 10-K" not in text:
        raise ValueError("Original filing index issuer/date/form mismatch")
