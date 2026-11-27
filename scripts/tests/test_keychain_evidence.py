"""Exercise the canary's interrupted-create cleanup without touching Keychain."""
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import keychain_evidence


class CanaryCleanupTests(unittest.TestCase):
    def test_missing_create_receipt_still_cleans_up_the_same_canary(self):
        with tempfile.TemporaryDirectory() as workspace:
            app = Path(workspace) / "Fixture.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(
                plistlib.dumps({"DabaiCredentialSigner": "A" * 40})
            )
            operations = []

            def launch(_app, phase, account, source, _receipt):
                operations.append((phase, account, source))
                if phase == "create":
                    raise subprocess.TimeoutExpired("synthetic create", 35)
                return {"phase": phase, "ok": True, "pid": 2}

            with patch.object(keychain_evidence, "identity", return_value={}), \
                 patch.object(keychain_evidence, "launch", side_effect=launch):
                with self.assertRaises(subprocess.TimeoutExpired):
                    keychain_evidence.audit(app, Path(workspace))

            self.assertEqual([op[0] for op in operations], ["create", "delete"])
            self.assertEqual(operations[0][1:], operations[1][1:])
