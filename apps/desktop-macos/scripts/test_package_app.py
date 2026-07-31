import os
import subprocess
import tempfile
import unittest
from pathlib import Path


DESKTOP = Path(__file__).resolve().parents[1]
PACKAGER = DESKTOP / "scripts" / "package-app.sh"


class PackageAppTests(unittest.TestCase):
    def test_adhoc_package_has_separate_permission_identity(self):
        script = PACKAGER.read_text()

        self.assertIn('BUNDLE_IDENTIFIER="one.leaper.acro.desktop.adhoc"', script)
        self.assertIn('BUNDLE_IDENTIFIER="one.leaper.acro.desktop"', script)
        self.assertIn("<string>${BUNDLE_IDENTIFIER}</string>", script)
        self.assertIn('EXPECTED_TEAM_ID="5UAHRS482C"', script)
        self.assertIn("official bundle ID requires Developer ID Application", script)

    def test_embeds_bonsplit_resource_bundle_at_swiftpm_runtime_path(self):
        script = PACKAGER.read_text()

        self.assertIn('BONSPLIT_RESOURCES=".build/release/Bonsplit_Bonsplit.bundle"', script)
        self.assertIn('cp -R "$BONSPLIT_RESOURCES" "$APP/Contents/Resources/"', script)

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

    def test_embeds_and_signs_t3_compat_runtime(self):
        script = PACKAGER.read_text()

        self.assertIn("CI=true pnpm --filter @acro/t3-compat deploy --legacy --prod", script)
        self.assertIn("CI=true pnpm install", script)
        self.assertIn('"$BUNDLED_NODE" "$ROOT/apps/t3-compat/scripts/check.mjs"', script)
        self.assertIn('"$T3/node_modules/t3/dist/bin.mjs"', script)
        self.assertIn("THIRD_PARTY_NOTICES.md", script)
        self.assertIn('rm -f "$T3/node_modules/.pnpm/node_modules/@acro/t3-compat"', script)
        self.assertIn("file -b \"$BINARY\" | grep -q 'Mach-O'", script)
        self.assertIn('codesign --verify --deep --strict "$APP"', script)
        self.assertIn('find "$APP/Contents/Resources/runtime" "$T3" -type f -print0', script)
        self.assertIn("NSAllowsLocalNetworking", script)


if __name__ == "__main__":
    unittest.main()
