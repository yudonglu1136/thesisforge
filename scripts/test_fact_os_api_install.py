import importlib.util
from pathlib import Path
import unittest

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


if __name__ == '__main__':
    unittest.main()
