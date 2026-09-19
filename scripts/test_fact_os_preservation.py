"""File-header exceptions are explicit, not an arbitrary hash bypass."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "fact_os_preservation_audit", Path(__file__).with_name("audit-fact-os-preservation.py"))
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class PreservationHeaderTests(unittest.TestCase):
    def test_only_defined_counter_and_writer_version_offsets_are_allowed(self):
        original, backup = bytes(100), bytearray(100)
        offsets = [26, 27, 43, 94, 95, 98, 99]
        for offset in offsets:
            backup[offset] = 1
        self.assertEqual(AUDIT.header_differences(original, backup), (offsets, True))
        self.assertEqual(AUDIT.header_differences(original, original), ([], True))

    def test_arbitrary_header_change_is_not_ignored(self):
        original, backup = bytes(100), bytearray(100)
        backup[16] = 1  # Page-size field is not backup counter/version metadata.
        backup[26] = 1
        self.assertEqual(AUDIT.header_differences(original, backup), ([16, 26], False))

    def test_truncated_headers_fail(self):
        with self.assertRaises(ValueError):
            AUDIT.header_differences(bytes(99), bytes(100))


if __name__ == "__main__":
    unittest.main()
