"""Validate exact dated BG statement captions / MAA original parent XBRL units.

No monetary/model values are rewritten. The full original XML is independently
parsed here; runtime JavaScript separately audits the frozen fragments.
"""
import hashlib
from pathlib import Path
import re
import xml.etree.ElementTree as ET

NS = {"x": "http://www.xbrl.org/2003/instance", "d": "http://xbrl.org/2006/xbrldi"}
CONTEXTS = {
    "FI2018Q4_srt_ConsolidatedEntitiesAxis_srt_ParentCompanyMember": (None, "2018-12-31"),
    "FD2018Q4YTD_srt_ConsolidatedEntitiesAxis_srt_ParentCompanyMember": ("2018-01-01", "2018-12-31"),
}
FACTS = {"Assets": ("usd", "FI2018Q4_srt_ConsolidatedEntitiesAxis_srt_ParentCompanyMember"),
         "Revenues": ("usd", "FD2018Q4YTD_srt_ConsolidatedEntitiesAxis_srt_ParentCompanyMember"),
         "NetCashProvidedByUsedInOperatingActivities": ("usd", "FD2018Q4YTD_srt_ConsolidatedEntitiesAxis_srt_ParentCompanyMember"),
         "EarningsPerShareDiluted": ("usdPerShare", "FD2018Q4YTD_srt_ConsolidatedEntitiesAxis_srt_ParentCompanyMember")}


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def validate_maa_original_xml(raw):
    root = ET.fromstring(raw)
    if root.tag != "{" + NS["x"] + "}xbrl":
        raise ValueError("Original instance namespace mismatch")
    contexts = {c.attrib["id"]: c for c in root.findall("x:context", NS)}
    for identity, (start, end) in CONTEXTS.items():
        context = contexts[identity]
        issuer = context.find("x:entity/x:identifier", NS)
        members = context.findall("x:entity/x:segment/d:explicitMember", NS)
        if issuer.text != "0000912595" or issuer.attrib["scheme"] != "http://www.sec.gov/CIK" or len(members) != 1 or members[0].attrib != {"dimension": "srt:ConsolidatedEntitiesAxis"} or members[0].text != "srt:ParentCompanyMember":
            raise ValueError("MAA parent-only issuer dimension required; LP/business segments cannot substitute")
        if context.findall(".//d:typedMember", NS) or context.find("x:scenario", NS) is not None:
            raise ValueError("Unexpected original context qualifier")
        if start:
            if context.findtext("x:period/x:startDate", namespaces=NS) != start or context.findtext("x:period/x:endDate", namespaces=NS) != end:
                raise ValueError("MAA current annual statement period mismatch")
        elif context.findtext("x:period/x:instant", namespaces=NS) != end:
            raise ValueError("MAA current balance-sheet period mismatch")
    units = {u.attrib["id"]: u for u in root.findall("x:unit", NS)}
    if [m.text for m in units["usd"].findall("x:measure", NS)] != ["iso4217:USD"] or units["usd"].find("x:divide", NS) is not None:
        raise ValueError("Original aggregate statement currency is not USD")
    divide = units["usdPerShare"].find("x:divide", NS)
    if divide is None or divide.findtext("x:unitNumerator/x:measure", namespaces=NS) != "iso4217:USD" or divide.findtext("x:unitDenominator/x:measure", namespaces=NS) != "xbrli:shares":
        raise ValueError("Original EPS unit is not USD per share")
    selected = []
    for name, (unit, context) in FACTS.items():
        facts = [f for f in root.findall("{http://fasb.org/us-gaap/2018-01-31}" + name) if f.attrib.get("contextRef") == context]
        if len(facts) != 1 or facts[0].attrib.get("unitRef") != unit or not re.fullmatch(r"-?\d+(?:\.\d+)?", facts[0].text or ""):
            raise ValueError("Missing or conflicting original parent statement fact: " + name)
        selected.append((name, facts[0]))
    return selected


def validate_statement_proof(event, proof, html):
    if proof["evidenceType"] == "explicit_consolidated_statement_currency_units":
        quotes = proof["quotes"]
        if event["ticker"] != "BG" or event["observedAt"] != "2024-02-07" or proof["availableAt"] != event["observedAt"] or proof["cik"] != "0001996862" or proof["form"] != "8-K" or len(quotes) != 3:
            raise ValueError("Only exact current Bunge statement owner/date is reviewed")
        if not re.search(r"Consolidated Earnings Data.*\(US\$ in millions, except per share data\)", quotes[0]) or not re.search(r"Condensed Consolidated Balance Sheets.*\(US\$ in millions\)", quotes[1]):
            raise ValueError("Both consolidated original USD statement captions required")
        if not all(s in quotes[2] for s in ["On November 1, 2023 Bunge Global SA completed", "Bermuda to Switzerland", "Each common share of Bunge Limited was cancelled in exchange for an equal number and par value of registered shares of Bunge Global SA"]):
            raise ValueError("Exact dated Bunge predecessor continuity disclosure missing")
        return
    if event["ticker"] != "MAA" or event["observedAt"] != "2019-05-02" or proof["availableAt"] != "2019-02-21" or proof["form"] != "10-K" or proof["cik"] != "0000912595":
        raise ValueError("Only exact dated MAA parent statement XBRL review is permitted")
    original = proof["xbrlStatementEvidence"]
    if original["sourceUrl"] != "https://www.sec.gov/Archives/edgar/data/912595/000091259519000015/maa-20181231.xml":
        raise ValueError("Original XBRL must be from the same reviewed filing")
    raw = Path(original["documentPath"]).read_text()
    if digest(raw) != original["documentSha256"]:
        raise ValueError("Original XBRL document hash mismatch")
    validate_maa_original_xml(raw)
    fragments = original["fragments"]
    if len(fragments) != 8 or len({f["key"] for f in fragments}) != 8:
        raise ValueError("Complete original two units, two contexts and four facts required")
    for index, fragment in enumerate(fragments):
        if fragment["raw"] not in raw or digest(fragment["raw"]) != original["fragmentsSha256"][index]:
            raise ValueError("Original XBRL fragment was changed")
