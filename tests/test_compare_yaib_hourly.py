import importlib.util
import io
import tempfile
import unittest
from contextlib import redirect_stdout
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
            output = io.StringIO()
            with redirect_stdout(output):
                self.assertFalse(COMPARE.compare(original, modified, "attrition.csv", 1e-8, 1e-6, 2))
            self.assertIn("floating differences outside tolerance=0", output.getvalue())
            self.assertIn("column=value", output.getvalue())
            self.assertIn("original=np.float64(2.0)", output.getvalue())

    def test_streaming_byte_comparison(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            left, right = root / "left.bin", root / "right.bin"
            left.write_bytes(b"same bytes")
            right.write_bytes(b"same bytes")
            self.assertTrue(COMPARE.byte_equal(left, right))
            right.write_bytes(b"different bytes")
            self.assertFalse(COMPARE.byte_equal(left, right))

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
