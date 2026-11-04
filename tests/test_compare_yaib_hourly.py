import importlib.util
import tempfile
import unittest
from pathlib import Path

import pandas as pd


SCRIPT = Path(__file__).parents[1] / "compare_yaib_hourly.py"
SPEC = importlib.util.spec_from_file_location("compare_yaib_hourly", SCRIPT)
COMPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPARE)


class CompareHourlyTest(unittest.TestCase):
    def test_row_order_is_ignored_but_exact_float_differences_fail(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            original = root / "original"
            modified = root / "modified"
            original.mkdir()
            modified.mkdir()
            pd.DataFrame({"n": [2, 1], "value": [2.0, 1.0]}).to_csv(original / "attrition.csv", index=False)
            pd.DataFrame({"n": [1, 2], "value": [1.0, 2.0]}).to_csv(modified / "attrition.csv", index=False)
            self.assertTrue(COMPARE.compare(original, modified, "attrition.csv", 1e-8, 1e-6, 2))

            pd.DataFrame({"n": [1, 2], "value": [1.0, 2.0 + 1e-9]}).to_csv(
                modified / "attrition.csv", index=False
            )
            self.assertFalse(COMPARE.compare(original, modified, "attrition.csv", 1e-8, 1e-6, 2))

    def test_missing_file_is_not_run(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            original = root / "original"
            modified = root / "modified"
            original.mkdir()
            modified.mkdir()
            pd.DataFrame({"n": [1]}).to_csv(original / "attrition.csv", index=False)
            self.assertIsNone(COMPARE.compare(original, modified, "attrition.csv", 1e-8, 1e-6, 2))


if __name__ == "__main__":
    unittest.main()
