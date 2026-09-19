import copy,json,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
import validate_early_group_currency_inference as lib
CASES=json.loads((Path(__file__).resolve().parent.parent/'server/fixtures/event-guidance-early-group-currency.json').read_text())
class Tests(unittest.TestCase):
 def test_exact_metadata(self):
  for f in CASES:lib.validate_metadata(f,f['proof'])
 def test_earlier_or_foreign_event_denied(self):
  for f in CASES:
   for key,value in [('observedAt','2013-01-30'),('sourceId','other')]:
    g=copy.deepcopy(f);g[key]=value
    with self.assertRaises(ValueError):lib.validate_metadata(g,g['proof'])
 def test_wrong_original_document_or_future_date_denied(self):
  for f in CASES:
   for key,value in [('cik','0000000001'),('documentSha256','f'*64),('availableAt','2030-01-01'),('inference',False)]:
    g=copy.deepcopy(f);g['proof'][key]=value
    with self.assertRaises(ValueError):lib.validate_metadata(g,g['proof'])
 def test_paragraphs_need_whole_consolidation_policy(self):
  for f in CASES:
   with self.assertRaises(ValueError):lib.paragraphs(f['ticker'],f['proof']['quotes'][0])
if __name__=='__main__':unittest.main()
