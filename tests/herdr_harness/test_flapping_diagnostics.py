from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "diagnose_herdr_flapping.command"


class FlappingDiagnosticsTests(unittest.TestCase):
    def test_process_filter_self_test(self) -> None:
        result = subprocess.run(
            ["bash", str(SCRIPT), "--self-test"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("process_filter_self_test=pass", result.stdout)


if __name__ == "__main__":
    unittest.main()
