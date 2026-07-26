import os
import subprocess
import tempfile
import unittest
from pathlib import Path


DESKTOP = Path(__file__).resolve().parents[1]
PACKAGER = DESKTOP / "scripts" / "package-app.sh"


class PackageAppTests(unittest.TestCase):
    def test_requires_explicit_signing_policy_before_build(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            fake_bin = temp / "bin"
            marker = temp / "swift-ran"
            fake_bin.mkdir()
            fake_swift = fake_bin / "swift"
            fake_swift.write_text(f'#!/bin/bash\ntouch "{marker}"\nexit 99\n')
            fake_swift.chmod(0o755)

            env = os.environ.copy()
            env.pop("ACRO_SIGN_IDENTITY", None)
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            result = subprocess.run(
                [PACKAGER, "0.0.0-test", "1"],
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ACRO_SIGN_IDENTITY must be set", result.stderr)
            self.assertFalse(marker.exists(), "packager started the build before validating signing")


if __name__ == "__main__":
    unittest.main()
