"""Exact dated consolidated reporting declarations for CSGP, FERG and Apache.

The two reviewed documents are not generic issuer-currency overrides. Each
original event and disclosure date is individually allowlisted; economic values
and company/segment ownership remain separately audited.
"""
import hashlib
from pathlib import Path
import re
from bs4 import BeautifulSoup

REVIEWED = {
    'APA': dict(cik='0000006769', availableAt='2020-02-28', accession='0001733037-20-000004', name='apa10-k2019.htm',
                documentSha256='346b922f1793c12d999de0f96b2c9b3598034ccf1816abbe244e254722ba2627',
                headerSha256='a281a4c80e529e0504ce3925d93f9c766689d98281f3978890bdc74ca58e339a',
                declaration='Our financial statements, presented in U.S. dollars, may be affected by foreign currency fluctuations through both translation risk and transaction risk.',
                owner='APACHE CORPORATION AND SUBSIDIARIES STATEMENT OF CONSOLIDATED OPERATIONS',
                events={'e4fb30013be479d6b5c12e56':'2020-11-05'}),
    'CSGP': dict(cik='0001057352', availableAt='2011-02-25', accession='0001057352-11-000012', name='form_10-k.htm',
                 documentSha256='f567cace7e160e685d2f382756827fd295e3bdf584f5e686cdd556db3e5abb04',
                 headerSha256='c1e6aa3ec5f8cab1a3703070c7fc67f6127aded044b3aa8a5fb4f5732cba139c',
                 declaration='Our financial reporting currency is the U.S. dollar.',
                 owner='COSTAR GROUP, INC. CONSOLIDATED STATEMENTS OF OPERATIONS',
                 events={'0add1d1207ac42ab57741994':'2011-04-27','108d93324ecc6a14a270bf4f':'2011-04-27','f4581e02e80dce16605d1249':'2011-04-27'}),
    'FERG': dict(cik='0001832433', availableAt='2023-09-26', accession='0001832433-23-000066', name='ferg-20230731.htm',
                 documentSha256='6dbd3a6e49948cfd6c300f9b6de37fc2c41ae7d93e0a13257f1d99e05b76ac1f',
                 headerSha256='926d7e9edd004ce46071e2067ae3d97f0a4e517f2174d3f1ed9ee640fc3b6207',
                 declaration='The consolidated financial statements are presented in U.S. dollars.',
                 owner='Ferguson plc Consolidated Statements of Earnings',
                 events={'deea2ad2293cb843d4e728f7':'2023-12-05','a57c4fe870a40a591ab7a8ee':'2024-03-05','6e659971614e5ed096f8eb36':'2023-09-26'}),
}
sha=lambda text:hashlib.sha256(text.encode()).hexdigest()
normalize=lambda text:re.sub(r'\s+',' ',BeautifulSoup(text,'html.parser').get_text(' ',strip=True))

def validate_metadata(event, proof):
    spec=REVIEWED.get(event['ticker'])
    if not spec or spec['events'].get(event['sourceId']) != event['observedAt']:
        raise ValueError('Unreviewed exact event/date')
    if any(proof.get(k)!=spec[k] for k in ['cik','availableAt','accession','documentSha256']):
        raise ValueError('Wrong original CIK/document/date')
    prefix=f"https://www.sec.gov/Archives/edgar/data/{int(spec['cik'])}/{spec['accession'].replace('-','')}/"
    if proof.get('sourceUrl')!=prefix+spec['name'] or proof.get('form')!='10-K' or proof.get('inference') is not False:
        raise ValueError('Not the reviewed original annual filing')
    if proof.get('quotes')!=[spec['declaration'],spec['owner']]:
        raise ValueError('Exact consolidated reporting declaration and owner required')
    return spec,prefix

def validate_header(text,spec):
    if re.search(r'Filing Date (\d{4}-\d{2}-\d{2})',text)[1]!=spec['availableAt'] or not re.search(r'CIK\s*:\s*'+spec['cik']+r'\b',text) or spec['accession'] not in text or 'Form 10-K' not in text or spec['name'] not in text:
        raise ValueError('Original filing header identity/date/form mismatch')

def validate_exact_direct(event,proof,row,html):
    spec,prefix=validate_metadata(event,proof)
    if sha(html)!=spec['documentSha256'] or any(q not in normalize(html) for q in proof['quotes']):
        raise ValueError('Original complete HTML/paragraph mismatch')
    if sha(row['payload_json'])!=event.get('originalPayloadSha256'):
        raise ValueError('Source payload changed; exact economic rebinding required')
    header=proof.get('filingDateEvidence') or {}
    if header.get('sourceUrl')!=prefix+spec['accession']+'-index.html' or header.get('documentSha256')!=spec['headerSha256']:
        raise ValueError('Unreviewed original filing index')
    raw=Path(header['documentPath']).read_text()
    if sha(raw)!=spec['headerSha256']:
        raise ValueError('Original index bytes changed')
    text=normalize(raw);validate_header(text,spec)
    proof['filingDateEvidence']={**header,'headerText':text,'headerTextSha256':sha(text)}
