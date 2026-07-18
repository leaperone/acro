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
let usesDefaultSocket = ProcessInfo.processInfo.environment["ACRO_HELPER_SOCKET"] == nil
let helperTesting = ProcessInfo.processInfo.environment["ACRO_HELPER_TESTING"] == "1"
var testPermissionsDelayMs = helperTesting
    ? Int(ProcessInfo.processInfo.environment["ACRO_HELPER_TEST_PERMISSIONS_DELAY_MS"] ?? "") ?? 0
    : 0
let testPermissionsStartedMarker = ProcessInfo.processInfo.environment[
    "ACRO_HELPER_TEST_PERMISSIONS_STARTED_MARKER"]
let testPermissionsFinishedMarker = ProcessInfo.processInfo.environment[
    "ACRO_HELPER_TEST_PERMISSIONS_FINISHED_MARKER"]
let maxRequestBytes = 2 * 1024 * 1024
let maxTypeScalars = 2048

final class AsyncRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if held {
                waiters.append(continuation)
                lock.unlock()
            } else {
                held = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        let next = waiters.isEmpty ? nil : waiters.removeFirst()
        if next == nil { held = false }
        lock.unlock()
        next?.resume()
    }
}

let requestGate = AsyncRequestGate()

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

func captureScreen(deadlineMs: Int64?, clientFd: Int32) async throws -> [String: Any] {
    let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
    try requireRequestActive(deadlineMs, clientFd: clientFd)
    guard let display = content.displays.first else {
        throw HelperError.message("no display")
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = display.width
    config.height = display.height
    let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
    try requireRequestActive(deadlineMs, clientFd: clientFd)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw HelperError.message("png encode failed")
    }
    try requireRequestActive(deadlineMs, clientFd: clientFd)
    let encoded = png.base64EncodedString()
    try requireRequestActive(deadlineMs, clientFd: clientFd)
    return ["png": encoded, "width": display.width, "height": display.height]
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

func click(x: Double, y: Double, deadlineMs: Int64?, clientFd: Int32) throws {
    let point = CGPoint(x: x, y: y)
    guard
        let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point,
            mouseButton: .left),
        let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point,
            mouseButton: .left)
    else { throw HelperError.message("event create failed") }
    try requireRequestActive(deadlineMs, clientFd: clientFd)
    down.post(tap: .cghidEventTap)
    usleep(30_000)
    // 已经按下时必须发送抬起,即使对端刚断开,否则会留下卡住的鼠标状态。
    up.post(tap: .cghidEventTap)
}

func requireBeforeDeadline(_ deadlineMs: Int64?) throws {
    guard let deadlineMs else { return }
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    guard nowMs < deadlineMs else { throw HelperError.message("request deadline exceeded") }
}

func requirePeerConnected(_ fd: Int32) throws {
    var byte: UInt8 = 0
    let result = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
    if result == 0 { throw HelperError.message("client disconnected") }
    if result < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
        throw HelperError.message("client disconnected")
    }
}

func requireRequestActive(_ deadlineMs: Int64?, clientFd: Int32) throws {
    try requireBeforeDeadline(deadlineMs)
    try requirePeerConnected(clientFd)
}

func typeText(_ text: String, deadlineMs: Int64?, clientFd: Int32) throws {
    for scalar in text.unicodeScalars {
        try requireRequestActive(deadlineMs, clientFd: clientFd)
        var utf16 = Array(String(scalar).utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { throw HelperError.message("event create failed") }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        try requireRequestActive(deadlineMs, clientFd: clientFd)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(5_000)
    }
}

func pressKey(
    keyCode: Int, command: Bool, option: Bool, control: Bool, shift: Bool,
    deadlineMs: Int64?, clientFd: Int32
) throws {
    guard let keyCode = CGKeyCode(exactly: keyCode) else {
        throw HelperError.message("keyCode out of range")
    }
    guard
        let down = CGEvent(
            keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    else { throw HelperError.message("event create failed") }
    var flags: CGEventFlags = []
    if command { flags.insert(.maskCommand) }
    if option { flags.insert(.maskAlternate) }
    if control { flags.insert(.maskControl) }
    if shift { flags.insert(.maskShift) }
    down.flags = flags
    up.flags = flags
    try requireRequestActive(deadlineMs, clientFd: clientFd)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

func terminateLaunchedApplication(_ app: NSRunningApplication) async throws {
    if app.terminate() {
        let gracefulDeadline = ContinuousClock.now + .milliseconds(500)
        while !app.isTerminated && ContinuousClock.now < gracefulDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    if !app.isTerminated {
        guard app.forceTerminate() else {
            throw HelperError.message("failed to stop cancelled application launch")
        }
        let forcedDeadline = ContinuousClock.now + .seconds(2)
        while !app.isTerminated && ContinuousClock.now < forcedDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    guard app.isTerminated else {
        throw HelperError.message("cancelled application launch did not terminate")
    }
}

func activateApp(
    bundleId: String, deadlineMs: Int64?, clientFd: Int32
) async throws -> Bool {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
        return app.activate()
    }
    guard
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    else { return false }
    let configuration = NSWorkspace.OpenConfiguration()
    // 未运行分支必须拥有独立实例,撤销时才能安全回滚,不误关竞态中由用户启动的进程。
    configuration.createsNewApplicationInstance = true
    // completion 返回且连接仍有效后再显式激活;取消中的启动不能抢走下一设备的输入焦点。
    configuration.activates = false
    let app = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<NSRunningApplication, Error>) in
        NSWorkspace.shared.openApplication(
            at: url, configuration: configuration
        ) { app, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let app {
                continuation.resume(returning: app)
            } else {
                continuation.resume(throwing: HelperError.message("application launch failed"))
            }
        }
    }
    do {
        try requireRequestActive(deadlineMs, clientFd: clientFd)
    } catch {
        try await terminateLaunchedApplication(app)
        throw error
    }
    return app.activate()
}

enum HelperError: Error {
    case message(String)
}

// ---- 分发 ----

func handle(
    method: String, params: [String: Any], deadlineMs: Int64?, clientFd: Int32
) async throws
    -> [String: Any]
{
    try requireRequestActive(deadlineMs, clientFd: clientFd)
    switch method {
    case "ping":
        if helperTesting, let delayMs = params["delayMs"] as? Int,
            (0...2_000).contains(delayMs)
        {
            // E2E 专用:模拟断线后仍需完成的输入清理,验证新连接不会并发执行。
            usleep(useconds_t(delayMs * 1_000))
        }
        if helperTesting, let marker = params["markerPath"] as? String {
            try? Data("started".utf8).write(
                to: URL(fileURLWithPath: marker), options: .atomic)
        }
        var result: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier]
        if helperTesting, let responseBytes = params["responseBytes"] as? Int,
            (0...(8 * 1024 * 1024)).contains(responseBytes)
        {
            result["payload"] = String(repeating: "x", count: responseBytes)
        }
        return result
    case "permissions.check":
        var delayedForTest = false
        if testPermissionsDelayMs > 0 {
            delayedForTest = true
            let delayMs = min(testPermissionsDelayMs, 2_000)
            testPermissionsDelayMs = 0
            if let marker = testPermissionsStartedMarker {
                try? Data("started".utf8).write(
                    to: URL(fileURLWithPath: marker), options: .atomic)
            }
            usleep(useconds_t(delayMs * 1_000))
        }
        let permissions = checkPermissions()
        if delayedForTest, let marker = testPermissionsFinishedMarker {
            try? Data("finished".utf8).write(
                to: URL(fileURLWithPath: marker), options: .atomic)
        }
        return permissions
    case "permissions.request":
        return requestPermissions()
    case "screen.capture":
        return try await captureScreen(deadlineMs: deadlineMs, clientFd: clientFd)
    case "window.list":
        return listWindows()
    case "input.click":
        guard let x = params["x"] as? Double, let y = params["y"] as? Double else {
            throw HelperError.message("x/y required")
        }
        try click(x: x, y: y, deadlineMs: deadlineMs, clientFd: clientFd)
        return [:]
    case "input.type":
        guard let text = params["text"] as? String else { throw HelperError.message("text required") }
        guard text.unicodeScalars.count <= maxTypeScalars else {
            throw HelperError.message("text too long")
        }
        try typeText(text, deadlineMs: deadlineMs, clientFd: clientFd)
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
            shift: params["shift"] as? Bool ?? false,
            deadlineMs: deadlineMs,
            clientFd: clientFd)
        return [:]
    case "app.activate":
        guard let bundleId = params["bundleId"] as? String else {
            throw HelperError.message("bundleId required")
        }
        return [
            "activated": try await activateApp(
                bundleId: bundleId, deadlineMs: deadlineMs, clientFd: clientFd)
        ]
    default:
        throw HelperError.message("unknown method \(method)")
    }
}

// ---- Unix socket 服务(按行 JSON) ----

func serve() throws {
    let dir = (socketPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true,
        attributes: usesDefaultSocket ? [.posixPermissions: 0o700] : nil)
    if usesDefaultSocket {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir)
    }
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
    guard chmod(socketPath, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
        throw HelperError.message("chmod() failed")
    }
    guard listen(fd, 4) == 0 else { throw HelperError.message("listen() failed") }
    FileHandle.standardError.write("acro-helper listening on \(socketPath)\n".data(using: .utf8)!)

    while true {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { continue }
        var noSigPipe: Int32 = 1
        guard setsockopt(
            client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))) == 0
        else {
            close(client)
            continue
        }
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
        if buffer.count > maxRequestBytes { return }
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
    let deadlineMs = (obj["deadlineMs"] as? NSNumber)?.int64Value
    await requestGate.acquire()
    var response: [String: Any]
    do {
        let result = try await handle(
            method: method, params: params, deadlineMs: deadlineMs, clientFd: fd)
        response = ["id": id, "ok": true, "result": result]
    } catch {
        response = ["id": id, "ok": false, "error": "\(error)"]
    }
    requestGate.release()
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
