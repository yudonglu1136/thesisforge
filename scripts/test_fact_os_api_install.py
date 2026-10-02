import importlib.util
from pathlib import Path
import unittest
import tempfile
import json
import hashlib
from fact_os.contracts import TABLES

spec = importlib.util.spec_from_file_location('fact_os_api_install', Path(__file__).with_name('fact-os-api-install.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ApiInstallPortTest(unittest.TestCase):
    def test_strategy_activation_requires_actual_matching_curve_and_ledger_ack(self):
        with tempfile.TemporaryDirectory() as directory:
            entries={u:{'snapshotId':c*64,'dataThrough':'2026-09-30'} for u,c in [('all','a'),('sp500','b'),('nasdaq100','c')]}
            raw=json.dumps({'entries':entries}).encode()
            (Path(directory)/'rule-manifest.json').write_bytes(raw)
            installed={'releaseId':'d'*64,'groups':{'strategy_inputs':{'generationId':'e'*64,
                'root':directory,'rulePortfolioBundleRequired':True}}}
            body={**installed,'status':'verified','fundamentals':{'status':'ready'},'publicAnalysis':{'status':'ready'},
                'coverage':[{'dataset':t,'locally_available':True,'backfill_complete':True} for t in TABLES]}
            with self.assertRaisesRegex(ValueError,'live_api_rule_bundle_mismatch'):
                installer.validate_live_ack(body,installed)
            rules={'status':'ready','bundleIdentity':hashlib.sha256(raw).hexdigest(),'universes':entries}
            body['publicAnalysis']['rulePortfolios']=rules
            self.assertTrue(installer.validate_live_ack(body,installed))
            rules['universes']={**entries,'all':{**entries['all'],'dataThrough':'2026-09-21'}}
            with self.assertRaisesRegex(ValueError,'live_api_rule_bundle_mismatch'):
                installer.validate_live_ack(body,installed)

    def test_public_daily_requires_exact_public_groups_and_keeps_release_identity(self):
        candidate={'releaseId':'a'*64,'groups':{name:{} for name in installer.PUBLIC_DAILY_GROUPS}}
        scoped=installer.scoped_candidate(candidate,'public-daily')
        self.assertEqual(scoped['activationScope'],'public-daily')
        self.assertEqual(scoped['releaseId'],candidate['releaseId'])
        self.assertNotIn('activationScope',candidate)
        body={**scoped,'status':'verified','fundamentals':{'status':'ready'},'publicAnalysis':{'status':'ready'},
              'research':{'status':'ready'},'coverage':[{'dataset':t,'locally_available':True,'backfill_complete':True} for t in TABLES]}
        scoped['groups']={name:{'generationId':'b'*64} for name in installer.PUBLIC_DAILY_GROUPS}
        body['groups']=scoped['groups']
        self.assertTrue(installer.validate_live_ack(body,scoped,'public-daily'))
        with self.assertRaisesRegex(ValueError,'public_daily_research_ack_missing'):
            installer.validate_live_ack({**body,'research':{'status':'failed'}},scoped,'public-daily')
        for groups in ({'canonical':{}},{**candidate['groups'],'user_portfolios':{}}):
            with self.assertRaisesRegex(ValueError,'public_daily_release_scope_invalid'):
                installer.scoped_candidate({**candidate,'groups':groups},'public-daily')
    def test_research_ack_is_separate_and_does_not_relax_global_activation(self):
        installed={'releaseId':'a'*64,'groups':{name:{'generationId':c*64}
            for name,c in [('canonical','b'),('research_inputs','c')]}}
        body={**installed,'status':'verified','research':{'status':'ready'},
              'coverage':[{'dataset':t,'locally_available':True,'backfill_complete':True} for t in TABLES]}
        self.assertTrue(installer.validate_live_ack(body,installed,'research'))
        with self.assertRaisesRegex(ValueError,'live_api_generation_mismatch'):
            installer.validate_live_ack(body,installed)
        with self.assertRaisesRegex(ValueError,'live_api_generation_mismatch'):
            installer.validate_live_ack({**body,'research':{'status':'failed'}},installed,'research')
        with self.assertRaisesRegex(ValueError,'live_api_coverage_incomplete'):
            installer.validate_live_ack({**body,'coverage':body['coverage'][:-1]},installed,'research')

    def test_eb_platform_port_is_not_the_local_development_default(self):
        self.assertEqual(installer.api_port({}, {}), 8080)

    def test_explicit_eb_configuration_takes_precedence(self):
        self.assertEqual(installer.api_port({'PORT': '9090'}, {'PORT': '8080'}), 9090)

    def test_platform_process_environment_can_supply_port(self):
        self.assertEqual(installer.api_port({}, {'PORT': '5000'}), 5000)

    def test_invalid_port_fails_before_credentialed_request(self):
        for value in ('0', '65536', 'https://example.com', 'NaN'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                installer.api_port({'PORT': value}, {})

    def test_live_ack_checks_every_group_not_only_release_id(self):
        installed={'releaseId':'a'*64,'groups':{'canonical':{'generationId':'b'*64},
                                               'ai_insights':{'generationId':'c'*64}}}
        body={**installed,'status':'verified','fundamentals':{'status':'ready','factCompanies':2},
              'publicAnalysis':{'status':'ready'},
              'coverage':[{'dataset':t,'locally_available':True,'backfill_complete':True} for t in TABLES]}
        self.assertTrue(installer.validate_live_ack(body,installed))
        for groups in ({'canonical':{'generationId':'b'*64}},
                       {**installed['groups'],'ai_insights':{'generationId':'d'*64}}):
            with self.assertRaisesRegex(ValueError,'live_api_group_mismatch'):
                installer.validate_live_ack({**body,'groups':groups},installed)
        with self.assertRaisesRegex(ValueError,'live_api_coverage_incomplete'):
            installer.validate_live_ack({**body,'coverage':body['coverage'][:-1]},installed)


if __name__ == '__main__':
    unittest.main()
