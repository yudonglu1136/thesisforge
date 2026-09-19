"""One exact pre-event AeroVironment parent statement: no issuer override."""
import datetime as dt
import hashlib
from pathlib import Path
import re
import xml.etree.ElementTree as ET
from bs4 import BeautifulSoup

VERSION='avav-original-parent-statement-currency-v1'
CIK='0001368622'
ACCESSION='0001558370-20-007720'
SOURCE_IDS={'33ebc900d50cf6d3a1d43827','6bbbc785e0418ace65435f82','d6e609bbda362b97c6e51b39'}
NAMES=['Assets','RevenueFromContractWithCustomerIncludingAssessedTax','NetCashProvidedByUsedInOperatingActivitiesContinuingOperations','EarningsPerShareDiluted']
NS={'x':'http://www.xbrl.org/2003/instance'}
sha=lambda s:hashlib.sha256(s.encode()).hexdigest()
normal=lambda s:re.sub(r'\s+',' ',BeautifulSoup(s,'html.parser').get_text(' ',strip=True))

def inspect_statement(raw):
    root=ET.fromstring(raw)
    if root.tag!='{'+NS['x']+'}xbrl':raise ValueError('Original SEC XBRL required')
    contexts={c.attrib['id']:c for c in root.findall('x:context',NS)}
    units={u.attrib['id']:u for u in root.findall('x:unit',NS)}
    chosen=[]
    for name in NAMES:
        found=[]
        for fact in root:
            if not re.fullmatch(r'\{http://fasb\.org/us-gaap/\d{4}-\d{2}-\d{2}\}'+name,fact.tag):continue
            c=contexts[fact.attrib['contextRef']]; ident=c.find('x:entity/x:identifier',NS)
            if ident is None or ident.text!=CIK or ident.attrib.get('scheme')!='http://www.sec.gov/CIK' or c.find('x:entity/x:segment',NS) is not None or c.find('x:scenario',NS) is not None:continue
            period=c.find('x:period',NS)
            if name=='Assets':
                if period.findtext('x:instant',namespaces=NS)!='2020-04-30':continue
            elif period.findtext('x:startDate',namespaces=NS)!='2019-05-01' or period.findtext('x:endDate',namespaces=NS)!='2020-04-30':continue
            if not re.fullmatch(r'-?\d+(?:\.\d+)?',fact.text or ''):raise ValueError('Nonnumeric original fact')
            u=units[fact.attrib['unitRef']]
            if name=='EarningsPerShareDiluted':
                if u.findtext('x:divide/x:unitNumerator/x:measure',namespaces=NS)!='iso4217:USD' or u.findtext('x:divide/x:unitDenominator/x:measure',namespaces=NS) not in {'shares','xbrli:shares'}:raise ValueError('Wrong EPS unit')
            elif u.findtext('x:measure',namespaces=NS)!='iso4217:USD' or u.find('x:divide',NS) is not None:raise ValueError('Wrong whole-parent statement unit')
            found.append(fact)
        if not found or len({(f.text,f.attrib['contextRef'],f.attrib['unitRef']) for f in found})!=1:raise ValueError('Missing/conflicting original parent '+name)
        chosen.append(found[0])
    return chosen,contexts,units

def validate_proof(event,proof,row,html):
    if event['ticker']!='AVAV' or event['sourceId'] not in SOURCE_IDS or event['observedAt']!='2021-06-22' or proof['cik']!=CIK or proof['availableAt']!='2020-06-24' or proof['accession']!=ACCESSION or proof['form']!='10-K' or proof.get('inference') is not False:raise ValueError('Exact dated issuer/event contract required')
    prefix=f'https://www.sec.gov/Archives/edgar/data/{int(CIK)}/{ACCESSION.replace("-", "")}/'
    if proof['sourceUrl']!=prefix+'avav-20200623x10k.htm' or sha(html)!=proof['documentSha256'] or proof['quotes']!=['AEROVIRONMENT, INC.'] or proof['quotes'][0] not in normal(html):raise ValueError('Original issuer HTML mismatch')
    if sha(row['payload_json'])!=event['originalPayloadSha256']:raise ValueError('Exact unchanged economics required')
    xml=proof['xbrlStatementEvidence']
    if xml.get('schemaVersion')!=VERSION or xml['sourceUrl']!=prefix+'avav-20200623x10k_htm.xml' or xml['documentSha256']!='7f39b55efcfd9e50185a87b5e9c3ead53c1a8976e6552de4cce685fd7b6a14b7':raise ValueError('Reviewed SEC extracted instance required')
    raw=Path(xml['documentPath']).read_text()
    if sha(raw)!=xml['documentSha256'] or xml['rootOpenTag'] not in raw or any(f['raw'] not in raw for f in xml['fragments']):raise ValueError('Original full statement/fragments changed')
    facts,_,_=inspect_statement(raw)
    selected=inspect_statement(xml['rootOpenTag']+''.join(f['raw'] for f in xml['fragments'])+xml['rootCloseTag'])[0]
    decoded=lambda facts:[dict(concept=f.tag.split('}')[-1],value=f.text,contextRef=f.attrib['contextRef'],unitRef=f.attrib['unitRef']) for f in facts]
    if decoded(facts)!=decoded(selected) or decoded(facts)!=xml['reconstructedFacts']:raise ValueError('Original aggregate reconstruction mismatch')
    # Same quantities and units must also exist in the original filed iXBRL,
    # independently of SEC's extracted XML presentation.
    soup=BeautifulSoup(html,'html.parser')
    for f in facts:
        nodes=soup.find_all('ix:nonfraction',attrs={'name':'us-gaap:'+f.tag.split('}')[-1],'contextref':f.attrib['contextRef']})
        if not nodes:raise ValueError('Extracted fact not in original filed HTML')
        for n in nodes:
            value=float(re.sub(r'[,\s]','',n.get_text()))*10**int(n.get('scale','0'))*(-1 if n.get('sign')=='-' else 1)
            if abs(value-float(f.text))>1e-6 or n.get('unitref')!=f.attrib['unitRef']:raise ValueError('Filed HTML contradicts extracted parent fact')
    header=proof['filingDateEvidence'];text=normal(Path(header['documentPath']).read_text())
    if sha(Path(header['documentPath']).read_text())!=header['documentSha256'] or header['sourceUrl']!=prefix+ACCESSION+'-index.html' or text!=header['headerText'] or sha(text)!=header['headerTextSha256']:raise ValueError('Original filed-index binding mismatch')
    if re.search(r'Filing Date (\d{4}-\d{2}-\d{2})',text)[1]!='2020-06-24' or not re.search(r'CIK\s*:\s*'+CIK+r'\b',text) or ACCESSION not in text or 'Form 10-K' not in text:raise ValueError('Original filed-date/CIK mismatch')
