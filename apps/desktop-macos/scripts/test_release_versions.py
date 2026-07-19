#!/usr/bin/env python3
import unittest

from release_versions import ensure_newer, latest, parse_tag


class ReleaseVersionsTests(unittest.TestCase):
    def test_accepts_only_supported_semver_forms(self) -> None:
        for tag in (
            "desktop-v0.0.7",
            "desktop-v1.2.3-alpha.1",
            "desktop-v1.2.3-beta.10",
            "desktop-v1.2.3-rc.2",
        ):
            parse_tag(tag)

        for tag in (
            "desktop-v01.2.3",
            "desktop-v1.2.3-preview.1",
            "desktop-v1.2.3-Beta.1",
            "desktop-v1.2.3-beta",
        ):
            with self.assertRaises(ValueError):
                parse_tag(tag)

    def test_orders_prereleases_before_stable(self) -> None:
        tags = [
            "desktop-v1.0.0",
            "desktop-v1.0.0-rc.2",
            "desktop-v1.0.0-beta.10",
            "desktop-v1.0.0-alpha.3",
        ]
        self.assertEqual(tags, sorted(tags, key=parse_tag, reverse=True))

    def test_rejects_equal_or_older_candidates(self) -> None:
        existing = ["desktop-v0.0.7-beta.9", "desktop-v0.0.6"]
        ensure_newer("desktop-v0.0.7", existing)
        with self.assertRaises(ValueError):
            ensure_newer("desktop-v0.0.7-beta.9", existing)
        with self.assertRaises(ValueError):
            ensure_newer("desktop-v0.0.6", existing)

    def test_selects_semver_latest_baseline_without_input_order(self) -> None:
        existing = [
            "desktop-v0.0.7-beta.8",
            "desktop-v0.0.6",
            "desktop-v0.0.7-beta.9",
            "desktop-v0.0.5",
        ]
        self.assertEqual(latest(existing, "stable"), "desktop-v0.0.6")
        self.assertEqual(latest(existing, "beta"), "desktop-v0.0.7-beta.9")


if __name__ == "__main__":
    unittest.main()
