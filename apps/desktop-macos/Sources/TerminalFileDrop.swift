// Finder 文件拖进终端时,只插入 shell-safe 路径,不自动执行。
// 路径读取/转义语义取自 cmux(GPL-3.0-or-later,
// Copyright (c) 2024-present Manaflow, Inc.)的精简版。

import AppKit

enum TerminalFileDrop {
    static let legacyFilenamesPasteboardType = NSPasteboard.PasteboardType(
        rawValue: "NSFilenamesPboardType"
    )
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        legacyFilenamesPasteboardType,
    ]

    static func canReadFileURLs(from pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains { pasteboardTypes.contains($0) }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var fileURLs: [URL] = []

        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        for object in objects {
            if let url = object as? URL, url.isFileURL {
                fileURLs.append(url.standardizedFileURL)
            }
        }

        if let paths = pasteboard.propertyList(
            forType: legacyFilenamesPasteboardType
        ) as? [String] {
            fileURLs.append(contentsOf: paths.compactMap { path in
                guard !path.isEmpty else { return nil }
                return URL(fileURLWithPath: path).standardizedFileURL
            })
        }

        if let rawFileURL = pasteboard.string(forType: .fileURL),
           let url = URL(string: rawFileURL),
           url.isFileURL {
            fileURLs.append(url.standardizedFileURL)
        }

        var seenPaths: Set<String> = []
        return fileURLs.filter { seenPaths.insert($0.path).inserted }
    }

    static func insertedText(for fileURLs: [URL]) -> String {
        let paths = fileURLs
            .filter(\.isFileURL)
            .map { $0.standardizedFileURL.path }
        guard !paths.isEmpty,
              paths.allSatisfy({ !containsUnsafeTerminalControl($0) }) else {
            return ""
        }
        return paths
            .map(escapeForShell)
            .joined(separator: " ")
    }

    private static func escapeForShell(_ path: String) -> String {
        let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?"
        var result = path
        for character in shellEscapeCharacters {
            result = result.replacingOccurrences(
                of: String(character),
                with: "\\\(character)"
            )
        }
        return result
    }

    private static func containsUnsafeTerminalControl(_ path: String) -> Bool {
        path.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }
}
