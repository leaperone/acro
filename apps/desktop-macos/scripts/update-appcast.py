#!/usr/bin/env python3
"""往 Sparkle appcast.xml 追加(或替换)一个版本条目。

用法: update-appcast.py <appcast.xml> <version> <stable|beta> <download_url> <ed_signature> <length>

appcast 提交在仓库里,客户端经 raw.githubusercontent.com 拉取。
稳定条目不带 channel,测试条目标 <sparkle:channel>beta</sparkle:channel>,
客户端按设置里的更新通道用 allowedChannels 过滤。
做法对标 ghostty 的 dist/macos/update_appcast_tag.py(MIT)。
"""
import os
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.sparkle-project.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
MAX_ITEMS = 15

path, version, channel, url, signature, length = sys.argv[1:7]

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

# 同版本重发时替换旧条目
for item in list(feed.findall("item")):
    existing = item.find(f"{{{SPARKLE}}}version")
    if existing is not None and existing.text == version:
        feed.remove(item)

item = ET.Element("item")
ET.SubElement(item, "title").text = version
ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
ET.SubElement(item, f"{{{SPARKLE}}}version").text = version
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
if channel == "beta":
    ET.SubElement(item, f"{{{SPARKLE}}}channel").text = "beta"
enclosure = ET.SubElement(item, "enclosure")
enclosure.set("url", url)
enclosure.set("type", "application/octet-stream")
enclosure.set("length", length)
enclosure.set(f"{{{SPARKLE}}}edSignature", signature)

# 新条目放最前,最多保留 MAX_ITEMS 条
old = feed.findall("item")
for node in old:
    feed.remove(node)
feed.append(item)
for node in old[: MAX_ITEMS - 1]:
    feed.append(node)

ET.indent(tree)
tree.write(path, encoding="utf-8", xml_declaration=True)
print(f"appcast updated: {version} channel={channel}")
