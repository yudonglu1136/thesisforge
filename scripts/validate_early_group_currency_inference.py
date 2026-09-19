"""Two finite original group policies; analyst inferences, not USD overrides."""
import hashlib,re
from pathlib import Path
from bs4 import BeautifulSoup
SHA=lambda text:hashlib.sha256(text.encode()).hexdigest()
NORMAL=lambda text:re.sub(r'\s+',' ',BeautifulSoup(text,'html.parser').get_text(' ',strip=True))
REVIEWED={
 'TSLA':dict(cik='0001318605',availableAt='2010-11-12',accession='0001193125-10-259068',form='10-Q',name='d10q.htm',documentSha256='a97ac86a15fbca60cc41d70d3a402c0e55420c21e287641caf24da58a696fbea',event='e014ec20c2e590055f051a0f',observedAt='2011-02-15',
  spans=[('For each of our foreign subsidiaries, the functional currency is the U.S. Dollar.','have not been significant for any periods presented.'),('The condensed consolidated financial statements include the accounts of Tesla and its wholly owned subsidiaries.','All significant inter-company transactions and balances have been eliminated in consolidation.'),('Comprehensive loss includes all changes in equity (net assets) during a period from non-owner sources.','as the functional currency of all our foreign subsidiaries is the U.S. Dollar.')],
  title='Tesla Motors, Inc.',reason='Group presentation-currency inference from the complete parent-plus-subsidiary consolidation scope, USD remeasurement of monetary and nonmonetary assets/liabilities and revenue/expenses, gains and losses in parent consolidated operations, and explicit absence of parent OCI translation because all foreign subsidiaries have USD functional currency. Not inferred from the subsidiary functional-currency sentence alone.'),
 'ABBV':dict(cik='0001551152',availableAt='2013-03-15',accession='0001047469-13-002827',form='10-K',name='a2213529z10-k.htm',documentSha256='383cd668dfabad9715a4f6b81479382cad4eb783e8ed5257b44b03e185fbdab8',event='09d7e89471d35a5530129417',observedAt='2013-04-26',
  spans=[('Foreign subsidiary earnings are translated into U.S. dollars using average exchange rates.','The remeasurement is recognized in earnings and is immaterial for all years presented.'),('The accompanying combined financial statements have been prepared on a stand-alone basis','All intracompany transactions and accounts have been eliminated.'),('On January 1, 2013, AbbVie became an independent company as a result of the distribution by Abbott Laboratories (Abbott) of 100 percent of the outstanding common stock of AbbVie to Abbott\'s shareholders.','AbbVie was incorporated in Delaware on April 10, 2012.')],
  title='AbbVie Inc. and Subsidiaries Notes to Combined Financial Statements',reason='AbbVie-specific presentation-currency inference from its own combined statements: all foreign subsidiary earnings and net assets translate into USD and differences enter group OCI. Its own full stand-alone basis separates the pharmaceutical carveout from Abbott and confirms the January 2013 separation already occurred. Currency only; the carveout historical economics are not assumed comparable to standalone guidance. This March filing is deliberately NOT applied to the January 2013 calls.')}

def paragraphs(ticker,html):
 spec=REVIEWED[ticker];text=NORMAL(html);out=[]
 for start,end in spec['spans']:
  choices=[]
  for m in re.finditer(re.escape(start),text):
   a=m.start();b=text.find(end,a)
   if 0<=b-a<=2500:choices.append(text[a:b+len(end)])
  if len(set(choices))!=1:raise ValueError('Whole policy/scope/ownership paragraph missing or ambiguous')
  out.append(choices[0])
 if spec['title'] not in text:raise ValueError('Exact parent statement title missing')
 return out

def validate_metadata(event,proof):
 spec=REVIEWED.get(event['ticker'])
 if not spec or event['sourceId']!=spec['event'] or event['observedAt']!=spec['observedAt'] or any(proof.get(k)!=spec[k] for k in ['cik','availableAt','accession','form','documentSha256']):raise ValueError('Unreviewed event/issuer/date/document')
 prefix=f"https://www.sec.gov/Archives/edgar/data/{int(spec['cik'])}/{spec['accession'].replace('-','')}/"
 if proof.get('sourceUrl')!=prefix+spec['name'] or proof.get('inference') is not True or proof.get('reasoning')!=spec['reason'] or proof.get('issuerConsolidatedStatementsTitle')!=spec['title'] or not proof.get('limitations'):raise ValueError('Finite labeled group inference contract required')
 return spec,prefix

def validate_proof(event,proof,row,html):
 spec,prefix=validate_metadata(event,proof)
 if SHA(html)!=spec['documentSha256'] or proof['quotes']!=paragraphs(event['ticker'],html):raise ValueError('Original complete document or paragraphs changed')
 if SHA(row['payload_json'])!=event['originalPayloadSha256']:raise ValueError('Fresh unchanged economic payload required')
 h=proof['filingDateEvidence'];raw=Path(h['documentPath']).read_text();text=NORMAL(raw)
 if SHA(raw)!=h['documentSha256'] or h['sourceUrl']!=prefix+spec['accession']+'-index.html' or text!=h['headerText'] or SHA(text)!=h['headerTextSha256']:raise ValueError('Original index binding changed')
 if re.search(r'Filing Date (\d{4}-\d{2}-\d{2})',text)[1]!=spec['availableAt'] or spec['accession'] not in text or not re.search(r'CIK\s*:\s*'+spec['cik']+r'\b',text) or 'Form '+spec['form'] not in text or spec['name'] not in text:raise ValueError('Original header issuer/form/date wrong')
