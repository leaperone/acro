#!/usr/bin/env python3
"""往 Sparkle appcast.xml 追加(或替换)完整包与可用的 delta 条目。

用法: update-appcast.py <appcast.xml> <version> <build_version> <stable|beta>
      <download_url> <ed_signature> <length> <deltas_json>
"""
import json
import os
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.sparkle-project.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
MAX_ITEMS = 15

path, version, build_version, channel, url, signature, length, deltas_path = sys.argv[1:9]
if not build_version.isdigit():
    raise SystemExit("build_version must be an integer")
with open(deltas_path, encoding="utf-8") as deltas_file:
    deltas = json.load(deltas_file)

if os.path.exists(path):
    tree = ET.parse(path)
    rss = tree.getroot()
else:
    rss = ET.fromstring(
        f'<rss xmlns:sparkle="{SPARKLE}" version="2.0">'
        "<channel><title>Acro Desktop</title></channel></rss>"
    )
    tree = ET.ElementTree(rss)

feed = rss.find("channel")
old = []
for item in feed.findall("item"):
    existing = item.find(f"{{{SPARKLE}}}shortVersionString")
    if existing is None or existing.text != version:
        old.append(item)
    feed.remove(item)

item = ET.Element("item")
ET.SubElement(item, "title").text = version
ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
ET.SubElement(item, f"{{{SPARKLE}}}version").text = build_version
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
if channel == "beta":
    ET.SubElement(item, f"{{{SPARKLE}}}channel").text = "beta"

enclosure = ET.SubElement(item, "enclosure")
enclosure.set("url", url)
enclosure.set("type", "application/octet-stream")
enclosure.set("length", length)
enclosure.set(f"{{{SPARKLE}}}edSignature", signature)

if deltas:
    delta_nodes = ET.SubElement(item, f"{{{SPARKLE}}}deltas")
    for delta in deltas:
        delta_node = ET.SubElement(delta_nodes, "enclosure")
        delta_node.set("url", delta["url"])
        delta_node.set("type", "application/octet-stream")
        delta_node.set("length", delta["length"])
        delta_node.set(f"{{{SPARKLE}}}deltaFrom", delta["from"])
        delta_node.set(f"{{{SPARKLE}}}edSignature", delta["signature"])

feed.append(item)
for node in old[: MAX_ITEMS - 1]:
    feed.append(node)

ET.indent(tree)
tree.write(path, encoding="utf-8", xml_declaration=True)
print(f"appcast updated: {version} build={build_version} channel={channel} deltas={len(deltas)}")
