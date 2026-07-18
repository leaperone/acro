import json
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "http://www.sparkle-project.org/xml-namespaces/sparkle"
SCRIPT = Path(__file__).with_name("update-appcast.py")


class UpdateAppcastTests(unittest.TestCase):
    def test_adds_signed_delta_ahead_of_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            appcast = Path(directory) / "appcast.xml"
            deltas = Path(directory) / "deltas.json"
            appcast.write_text(self.feed(self.item("0.0.6")), encoding="utf-8")
            deltas.write_text(
                json.dumps(
                    [{
                        "from": "0.0.6",
                        "url": "https://example.invalid/update.delta",
                        "signature": "delta-signature",
                        "length": "123",
                    }]
                ),
                encoding="utf-8",
            )

            subprocess.run(
                [
                    sys.executable,
                    SCRIPT,
                    appcast,
                    "0.0.7-beta.1",
                    "beta",
                    "https://example.invalid/update.zip",
                    "archive-signature",
                    "456",
                    deltas,
                ],
                check=True,
            )

            items = ET.parse(appcast).getroot().find("channel").findall("item")
            self.assertEqual(
                [item.find(f"{{{SPARKLE}}}version").text for item in items],
                ["0.0.7-beta.1", "0.0.6"],
            )
            delta = items[0].find(f"{{{SPARKLE}}}deltas/enclosure")
            enclosure = items[0].find("enclosure")
            self.assertEqual(items[0].find(f"{{{SPARKLE}}}channel").text, "beta")
            self.assertEqual(enclosure.get(f"{{{SPARKLE}}}edSignature"), "archive-signature")
            self.assertEqual(delta.get(f"{{{SPARKLE}}}deltaFrom"), "0.0.6")
            self.assertEqual(delta.get(f"{{{SPARKLE}}}edSignature"), "delta-signature")

    @staticmethod
    def feed(item: str) -> str:
        return (
            f'<rss xmlns:sparkle="{SPARKLE}" version="2.0">'
            f"<channel><title>Acro Desktop</title>{item}</channel></rss>"
        )

    @staticmethod
    def item(version: str) -> str:
        return (
            f"<item><title>{version}</title><sparkle:version>{version}</sparkle:version>"
            f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
            f"<enclosure url=\"{version}.zip\" length=\"456\" "
            f"sparkle:edSignature=\"archive-signature\"/></item>"
        )


if __name__ == "__main__":
    unittest.main()
