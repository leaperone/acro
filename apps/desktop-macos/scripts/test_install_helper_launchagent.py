import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
INSTALLER = ROOT / "scripts" / "install-helper-launchagent.sh"


class InstallHelperLaunchAgentTests(unittest.TestCase):
    def test_installs_signed_helper_at_stable_path_and_rejects_adhoc(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            home = temp / "home"
            fake_bin = temp / "bin"
            source = temp / "acro-helper"
            codesign_log = temp / "codesign.log"
            home.mkdir()
            fake_bin.mkdir()
            source.write_bytes(b"helper-v1")
            source.chmod(0o755)

            fake_codesign = fake_bin / "codesign"
            fake_codesign.write_text(
                '#!/bin/bash\nprintf "%s\\n" "$*" >> "$ACRO_TEST_CODESIGN_LOG"\n'
            )
            fake_codesign.chmod(0o755)

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "ACRO_HELPER_SOURCE_BIN": str(source),
                    "ACRO_SIGN_IDENTITY": "Developer ID Application: Acro Test (TEAM123)",
                    "ACRO_TEST_CODESIGN_LOG": str(codesign_log),
                }
            )

            subprocess.run([INSTALLER], check=True, env=env)

            installed = home / ".acro" / "bin" / "acro-helper"
            plist_path = home / "Library" / "LaunchAgents" / "one.leaper.acro.helper.plist"
            self.assertEqual(installed.read_bytes(), b"helper-v1")
            with plist_path.open("rb") as plist_file:
                plist = plistlib.load(plist_file)
            self.assertEqual(plist["ProgramArguments"], [str(installed)])
            self.assertNotIn(str(ROOT), plist_path.read_text())
            self.assertNotIn(".build", plist_path.read_text())

            codesign_args = codesign_log.read_text()
            self.assertIn("--identifier one.leaper.acro.helper", codesign_args)
            self.assertIn("--options runtime", codesign_args)
            self.assertIn("--timestamp", codesign_args)

            source.write_bytes(b"helper-v2")
            subprocess.run([INSTALLER], check=True, env=env)
            self.assertEqual(installed.read_bytes(), b"helper-v2")

            env["ACRO_SIGN_IDENTITY"] = "-"
            source.write_bytes(b"unsigned-helper")
            failed = subprocess.run([INSTALLER], env=env, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(installed.read_bytes(), b"helper-v2")


if __name__ == "__main__":
    unittest.main()
