#!/usr/bin/env python3
"""Freeze exact public BG/MAA filings and MAA original dated statement facts.

Read-only sources, private NEW output. Does not resolve a guidance currency or
modify any database. Bunge's exhibit name is from the original SEC directory.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
from bs4 import BeautifulSoup
from build_dated_reporting_currency_ledger import fetch_facts, resolve_currency
from audit_dated_reporting_currency_ledger import verify_target

spec = importlib.util.spec_from_file_location("official", Path(__file__).with_name("import-sec-official-guidance.py"))
official = importlib.util.module_from_spec(spec)
spec.loader.exec_module(official)


def collect(directory):
    directory = Path(directory)
    if directory.exists() or not directory.name.startswith("currency-lane"):
        raise ValueError("NEW private currency-lane directory required")
    directory.mkdir(parents=True)
    session = official.build_session()
    docs = []
    specs = [
        ("BG", "0001996862", "2024-02-07", "0001996862-24-000002", "epr12312023.htm", "8-K"),
        ("MAA", "0000912595", "2019-05-01", "0000912595-19-000022", "a1q19exh991.htm", "8-K"),
        ("MAA", "0000912595", "2019-02-21", "0000912595-19-000015", "maa12312018-10k.htm", "10-K"),
    ]
    for ticker, cik, filed, accession, name, form in specs:
        url = f"https://www.sec.gov/Archives/edgar/data/{int(cik)}/{accession.replace('-', '')}/{name}"
        html_path = directory / ticker / name
        html = official.get_text(session, url, html_path)
        text = re.sub(r"\s+", " ", BeautifulSoup(html, "html.parser").get_text(" ", strip=True))
        snippets = [text[max(0, m.start()-160):m.end()+350] for m in re.finditer(r"reporting currency|U\.S\. dollars|US dollars|U\.S\. Dollar|redomestication|Net income per diluted common share is expected", text, re.I)]
        docs.append(dict(ticker=ticker, cik=cik, filed=filed, form=form, accession=accession, name=name,
                         url=url, htmlPath=str(html_path), documentSha256=hashlib.sha256(html.encode()).hexdigest(), currencyContexts=snippets))
        if ticker == "MAA" and form == "10-K":
            prefix = url.rsplit("/", 1)[0]
            index = official.get_json(session, prefix + "/index.json", directory / ticker / "10k-index.json")
            xml = [r["name"] for r in index["directory"]["item"] if re.fullmatch(r"maa-20181231\.xml", r["name"])]
            if len(xml) != 1:
                raise ValueError("Exact original MAA XBRL instance absent from SEC directory")
            instance_path = directory / ticker / xml[0]
            original = official.get_text(session, prefix + "/" + xml[0], instance_path)
            docs[-1]["originalXbrl"] = dict(url=prefix + "/" + xml[0], path=str(instance_path),
                                          sha256=hashlib.sha256(original.encode()).hexdigest())
    filings, issuer = fetch_facts(session, "0000912595", directory / "companyfacts")
    # Day before the call avoids using a same-day 10-Q with unknown intra-day
    # availability. Facts must have been actually filed by this earlier date.
    resolution = resolve_currency(filings, "0000912595", "2019-05-01")
    target = dict(ticker="MAA", targetAvailableAt="2019-05-01", **resolution)
    errors = verify_target(target, issuer, json.loads(Path(issuer["cachePath"]).read_text()))
    payload = dict(documents=docs, maaOriginalFacts=dict(issuer=issuer, target=target, independentErrors=errors),
                   sourceRowsChanged=0, releaseAuthorized=False)
    (directory / "primary-evidence.json").write_text(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    collect(parser.parse_args().output_dir)
