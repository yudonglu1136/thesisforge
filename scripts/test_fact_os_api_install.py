import importlib.util
from pathlib import Path
import unittest
from fact_os.contracts import TABLES

spec = importlib.util.spec_from_file_location('fact_os_api_install', Path(__file__).with_name('fact-os-api-install.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ApiInstallPortTest(unittest.TestCase):
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
