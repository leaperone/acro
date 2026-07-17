// acro-helper: macOS Computer Use 原生能力,独立小进程。
// 只做 TypeScript 做不了的事:AX 权限内的输入注入、ScreenCaptureKit 采集、应用激活。
// 协议:Unix socket 上按行 JSON。{"id":1,"method":"ping","params":{}} → {"id":1,"ok":true,"result":{}}
// 必须运行在已登录图形会话,并取得辅助功能与录屏权限。

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

let socketPath =
    ProcessInfo.processInfo.environment["ACRO_HELPER_SOCKET"]
    ?? ("\(NSHomeDirectory())/.acro/helper.sock")

// ---- 方法实现 ----

func checkPermissions() -> [String: Any] {
    return [
        "accessibility": AXIsProcessTrusted(),
        "screenRecording": CGPreflightScreenCaptureAccess(),
    ]
}

func requestPermissions() -> [String: Any] {
    let axOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    let ax = AXIsProcessTrustedWithOptions(axOptions)
    let screen = CGRequestScreenCaptureAccess()
    return ["accessibility": ax, "screenRecording": screen]
}

func captureScreen() async throws -> [String: Any] {
    let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else {
        throw HelperError.message("no display")
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = display.width
    config.height = display.height
    let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw HelperError.message("png encode failed")
    }
    return ["png": png.base64EncodedString(), "width": display.width, "height": display.height]
}

func listWindows() -> [String: Any] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    let windows = raw.compactMap { info -> [String: Any]? in
        guard let owner = info[kCGWindowOwnerName as String] as? String,
            let number = info[kCGWindowNumber as String] as? Int
        else { return nil }
        return [
            "windowId": number,
            "app": owner,
            "title": info[kCGWindowName as String] as? String ?? "",
            "bounds": info[kCGWindowBounds as String] as? [String: Any] ?? [:],
        ]
    }
    return ["windows": windows]
}

func click(x: Double, y: Double) throws {
    let point = CGPoint(x: x, y: y)
    guard
        let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point,
            mouseButton: .left),
        let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point,
            mouseButton: .left)
    else { throw HelperError.message("event create failed") }
    down.post(tap: .cghidEventTap)
    usleep(30_000)
    up.post(tap: .cghidEventTap)
}

func typeText(_ text: String) throws {
    for scalar in text.unicodeScalars {
        var utf16 = Array(String(scalar).utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { throw HelperError.message("event create failed") }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(5_000)
    }
}

func pressKey(keyCode: Int, command: Bool, option: Bool, control: Bool, shift: Bool) throws {
    guard
        let down = CGEvent(
            keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false)
    else { throw HelperError.message("event create failed") }
    var flags: CGEventFlags = []
    if command { flags.insert(.maskCommand) }
    if option { flags.insert(.maskAlternate) }
    if control { flags.insert(.maskControl) }
    if shift { flags.insert(.maskShift) }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

func activateApp(bundleId: String) -> Bool {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
        return app.activate()
    }
    guard
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    else { return false }
    NSWorkspace.shared.openApplication(
        at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    return true
}

enum HelperError: Error {
    case message(String)
}

// ---- 分发 ----

func handle(method: String, params: [String: Any]) async throws -> [String: Any] {
    switch method {
    case "ping":
        return ["pid": ProcessInfo.processInfo.processIdentifier]
    case "permissions.check":
        return checkPermissions()
    case "permissions.request":
        return requestPermissions()
    case "screen.capture":
        return try await captureScreen()
    case "window.list":
        return listWindows()
    case "input.click":
        guard let x = params["x"] as? Double, let y = params["y"] as? Double else {
            throw HelperError.message("x/y required")
        }
        try click(x: x, y: y)
        return [:]
    case "input.type":
        guard let text = params["text"] as? String else { throw HelperError.message("text required") }
        try typeText(text)
        return [:]
    case "input.key":
        guard let keyCode = params["keyCode"] as? Int else {
            throw HelperError.message("keyCode required")
        }
        try pressKey(
            keyCode: keyCode,
            command: params["command"] as? Bool ?? false,
            option: params["option"] as? Bool ?? false,
            control: params["control"] as? Bool ?? false,
            shift: params["shift"] as? Bool ?? false)
        return [:]
    case "app.activate":
        guard let bundleId = params["bundleId"] as? String else {
            throw HelperError.message("bundleId required")
        }
        return ["activated": activateApp(bundleId: bundleId)]
    default:
        throw HelperError.message("unknown method \(method)")
    }
}

// ---- Unix socket 服务(按行 JSON) ----

func serve() throws {
    let dir = (socketPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true)
    unlink(socketPath)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HelperError.message("socket() failed") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        socketPath.utf8CString.withUnsafeBytes { src in
            raw.copyBytes(from: src.prefix(raw.count - 1))
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
    }
    guard bindResult == 0 else { throw HelperError.message("bind() failed") }
    guard listen(fd, 4) == 0 else { throw HelperError.message("listen() failed") }
    FileHandle.standardError.write("acro-helper listening on \(socketPath)\n".data(using: .utf8)!)

    while true {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { continue }
        Task.detached { await serveClient(fd: client) }
    }
}

func serveClient(fd: Int32) async {
    defer { close(fd) }
    var buffer = Data()
    let chunkSize = 65536
    var chunk = [UInt8](repeating: 0, count: chunkSize)
    while true {
        let n = read(fd, &chunk, chunkSize)
        if n <= 0 { return }
        buffer.append(contentsOf: chunk[0..<n])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            await handleLine(Data(line), fd: fd)
        }
    }
}

func handleLine(_ line: Data, fd: Int32) async {
    guard
        let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let id = obj["id"] as? Int,
        let method = obj["method"] as? String
    else { return }
    let params = obj["params"] as? [String: Any] ?? [:]
    var response: [String: Any]
    do {
        let result = try await handle(method: method, params: params)
        response = ["id": id, "ok": true, "result": result]
    } catch {
        response = ["id": id, "ok": false, "error": "\(error)"]
    }
    guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
    data.append(0x0A)
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if written <= 0 { return }
            offset += written
        }
    }
}

try serve()
