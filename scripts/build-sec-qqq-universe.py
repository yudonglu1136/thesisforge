"""Build a disclosed QQQ universe, not an official historical Nasdaq index.

Only public SEC N-PORT filings; archive each response by SHA-256. Membership
becomes usable on its filing date, never its earlier portfolio date. Resolve
CUSIPs against the existing, pinned Fact OS identity table; no fuzzy matching.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fact_os.repository import FactRepository

CIK = '1067839'
NS = {'n': 'http://www.sec.gov/edgar/nport'}
# Reviewed identifier crosswalk, not a new security master. QQQ omitted this
# CUSIP; SEC N-PX explicitly pairs it with the ISIN. Canonical identity is still
# resolved by CUSIP below, and a changed/ambiguous master fails the build.
ISIN_CUSIP = {'NL0015001FS8': ('N3168P101',
    'https://www.sec.gov/Archives/edgar/data/1620943/000121390024068732/xslN-PX_X01/proxytable.xml')}


def parse_holdings(raw):
    root = ET.fromstring(raw)
    info = root.find('.//n:genInfo', NS)
    if info is None or int(info.findtext('n:regCik', '', NS)) != int(CIK):
        raise ValueError('qqq_filing_identity_mismatch')
    period = info.findtext('n:repPdDate', '', NS)
    holdings = []
    for row in root.findall('.//n:invstOrSec', NS):
        def field(k):
            return row.findtext('n:' + k, '', NS)
        if field('assetCat') != 'EC' or field('payoffProfile') != 'Long':
            continue
        if float(field('valUSD')) <= 0:
            continue
        isin = row.find('n:identifiers/n:isin', NS)
        holdings.append(dict(cusip=field('cusip'), name=field('name'),
                             isin=isin.get('value') if isin is not None else None))
    if not 95 <= len(holdings) <= 115 or len({r['cusip'] for r in holdings}) != len(holdings):
        raise ValueError('qqq_holdings_incomplete_or_duplicated')
    return period, holdings


def build(a):
    a.archive.mkdir(parents=True, exist_ok=True)
    receipts = a.archive / 'receipts.json'
    index = json.loads(receipts.read_text()) if receipts.exists() else {}
    def fetch(url, refresh=False):
        if url in index and not refresh:
            raw = (a.archive / (index[url] + '.source')).read_bytes()
            if hashlib.sha256(raw).hexdigest() != index[url]:
                raise ValueError('sec_archive_checksum_mismatch')
            return raw
        time.sleep(.3)
        request = urllib.request.Request(url, headers={'User-Agent': os.environ.get(
            'SEC_USER_AGENT', 'ThesisForge research engineering contact@thesisforge.tech')})
        with urllib.request.urlopen(request, timeout=45) as response:
            raw = response.read()
        sha = hashlib.sha256(raw).hexdigest()
        target = a.archive / (sha + '.source')
        if not target.exists():
            target.write_bytes(raw)
        index[url] = sha
        temp = receipts.with_suffix('.pending')
        temp.write_text(json.dumps(index, indent=2))
        temp.replace(receipts)
        return raw
    submissions = json.loads(a.submissions.read_text()) if a.submissions else json.loads(fetch(
        'https://data.sec.gov/submissions/CIK0001067839.json', refresh=True))
    recent = submissions['filings']['recent']
    with FactRepository(a.fact_root) as repo:
        generation = repo.generation
        identities = repo.db.execute('SELECT DISTINCT permaticker,ticker,cusips FROM tickers WHERE cusips IS NOT NULL').fetchall()
    by_cusip = {}
    for permaticker, ticker, cusips in identities:
        for cusip in str(cusips).replace(',', ' ').split():
            by_cusip.setdefault(cusip, {}).setdefault(str(permaticker), set()).add(ticker)
    snapshots, unresolved = [], []
    for i, form in enumerate(recent['form']):
        if form not in ('NPORT-P', 'NPORT-P/A') or recent['filingDate'][i] > a.as_of:
            continue
        accession = recent['accessionNumber'][i]
        url = f'https://www.sec.gov/Archives/edgar/data/{CIK}/{accession.replace("-", "")}/primary_doc.xml'
        raw = fetch(url)
        period, holdings = parse_holdings(raw)
        if period != recent['reportDate'][i]:
            raise ValueError('qqq_report_period_mismatch')
        members = []
        for h in holdings:
            resolved_cusip = h['cusip']
            if resolved_cusip in ('', 'N/A') and h['isin'] in ISIN_CUSIP:
                resolved_cusip, bridge_url = ISIN_CUSIP[h['isin']]
                h = dict(h, resolvedCusip=resolved_cusip, identitySourceUrl=bridge_url)
            matches = by_cusip.get(resolved_cusip, {})
            if len(matches) != 1:
                unresolved.append(dict(accession=accession, period=period, **h, matches=list(matches)))
                continue
            permaticker, tickers = next(iter(matches.items()))
            members.append(dict(**h, permaticker=permaticker, tickers=sorted(tickers)))
        snapshots.append(dict(period=period, filed=recent['filingDate'][i], accession=accession,
            sourceUrl=url, sourceSha256=hashlib.sha256(raw).hexdigest(), members=members,
            sourceMemberCount=len(holdings)))
        print(json.dumps(dict(period=period, members=len(members), total=len(holdings))), flush=True)
    result = dict(version='sec-qqq-disclosed-universe-v1', identityGeneration=generation,
        asOf=a.as_of, snapshots=sorted(snapshots, key=lambda r:(r['filed'], r['accession'])),
        unresolved=unresolved)
    a.output.write_text(json.dumps(result, indent=2))
    if unresolved:
        raise ValueError(f'qqq_unresolved_identity:{len(unresolved)}; see output audit')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['fact-root', 'archive', 'output']:
        p.add_argument('--'+name, type=Path, required=True)
    p.add_argument('--submissions', type=Path)
    p.add_argument('--as-of', required=True)
    build(p.parse_args())
