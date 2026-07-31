import Darwin
import Foundation
import Security

enum T3CompatState: Equatable {
    case idle
    case starting
    case ready(URL)
    case failed(String)
}

enum T3CompatError: LocalizedError {
    case missingRuntime
    case unsupportedNode(String)
    case invalidState
    case startupFailed
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .missingRuntime:
            String(localized: "t3.error.missingRuntime", defaultValue: "T3 Code runtime is missing.")
        case .unsupportedNode(let version):
            String(
                localized: "t3.error.nodeVersion",
                defaultValue: "T3 Code requires Node 22.16+, 23.11+, or 24.10+. Found \(version)."
            )
        case .invalidState:
            String(
                localized: "t3.error.invalidState",
                defaultValue: "The local Agent service state is invalid."
            )
        case .startupFailed:
            String(
                localized: "t3.error.startup",
                defaultValue: "The local Agent service did not start."
            )
        case .authenticationFailed:
            String(
                localized: "t3.error.authentication",
                defaultValue: "The local Agent session could not be authenticated."
            )
        }
    }
}

struct T3NodeVersion: Equatable {
    let major: Int
    let minor: Int

    init?(_ raw: String) {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".")
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1])
        else { return nil }
        self.major = major
        self.minor = minor
    }

    var supportsT3: Bool {
        (major == 22 && minor >= 16)
            || (major == 23 && minor >= 11)
            || (major == 24 && minor >= 10)
            || major > 24
    }
}

private struct T3RuntimeState: Decodable {
    let pid: Int32
    let origin: String
}

private struct T3EnvironmentInfo: Decodable {
    let serverVersion: String
}

private struct T3BrowserSession: Decodable {
    let authenticated: Bool
}

private struct T3Bootstrap: Encodable {
    let mode = "desktop"
    let noBrowser = true
    let port: Int
    let t3Home: String
    let host = "127.0.0.1"
    let desktopBootstrapToken: String
    let tailscaleServeEnabled = false
    let tailscaleServePort = 443
}

enum T3ShellEnvironment {
    private static let names = [
        "PATH", "SSH_AUTH_SOCK", "HOMEBREW_PREFIX", "HOMEBREW_CELLAR",
        "HOMEBREW_REPOSITORY", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
    ]

    static func hydrate(_ inherited: [String: String]) -> [String: String] {
        let shell = inherited["SHELL"].flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        } ?? "/bin/zsh"
        let command = names.map {
            "printf '%s\\n' '__ACRO_T3_\($0)_START__'; printenv \($0) || true; "
                + "printf '%s\\n' '__ACRO_T3_\($0)_END__'"
        }.joined(separator: "; ")
        guard let output = commandOutput(shell, ["-ilc", command], timeout: 5) else {
            return inherited
        }
        let probed = parse(output)
        var result = inherited
        if let shellPath = probed["PATH"] {
            result["PATH"] = mergePaths(shellPath, inherited["PATH"])
        }
        for name in names where name != "PATH" && result[name] == nil {
            result[name] = probed[name]
        }
        return result
    }

    static func parse(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for name in names {
            let start = "__ACRO_T3_\(name)_START__"
            let end = "__ACRO_T3_\(name)_END__"
            guard let startRange = output.range(of: start),
                  let endRange = output.range(of: end, range: startRange.upperBound..<output.endIndex)
            else { continue }
            let value = output[startRange.upperBound..<endRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values[name] = value }
        }
        return values
    }

    private static func mergePaths(_ first: String, _ second: String?) -> String {
        var seen = Set<String>()
        return ([first] + [second].compactMap { $0 })
            .flatMap { $0.split(separator: ":").map(String.init) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private static func commandOutput(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )
    }
}

@MainActor
final class T3CompatManager: ObservableObject {
    static let expectedVersion = "0.0.31"

    @Published private(set) var state: T3CompatState = .idle

    private var spawnedProcess: Process?
    private var bootstrapToken: String?
    private let fileManager = FileManager.default

    func start() async {
        guard state != .starting else { return }
        if case .ready = state { return }
        state = .starting
        do {
            let node = try resolveNode()
            guard let entry = Self.resolveEntry() else { throw T3CompatError.missingRuntime }
            let stateDirectory = try prepareStateDirectory()
            let storedToken = loadToken(from: stateDirectory)
            if let origin = try await reusableOrigin(in: stateDirectory) {
                guard let storedToken else { throw T3CompatError.invalidState }
                bootstrapToken = storedToken
                state = .ready(origin)
                return
            }

            let token = try storedToken ?? createToken(in: stateDirectory)
            bootstrapToken = token
            let environment = await Task.detached {
                T3ShellEnvironment.hydrate(ProcessInfo.processInfo.environment)
            }.value
            let port = try Self.availablePort()
            let origin = URL(string: "http://127.0.0.1:\(port)")!
            let process = try spawn(
                node: node,
                entry: entry,
                stateDirectory: stateDirectory,
                environment: environment,
                port: port,
                token: token
            )
            spawnedProcess = process
            try await waitUntilReady(origin: origin, process: process)
            state = .ready(origin)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func retry() async {
        if let process = spawnedProcess, process.isRunning { process.terminate() }
        spawnedProcess = nil
        state = .idle
        await start()
    }

    func browserSessionCookies() async throws -> [HTTPCookie] {
        guard case .ready(let origin) = state,
              let token = bootstrapToken,
              let url = URL(string: "/api/auth/browser-session", relativeTo: origin)?.absoluteURL
        else { throw T3CompatError.authenticationFailed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["credential": token])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              (try? JSONDecoder().decode(T3BrowserSession.self, from: data).authenticated) == true
        else { throw T3CompatError.authenticationFailed }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String, let value = entry.value as? String {
                result[key] = value
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: origin)
        guard !cookies.isEmpty, cookies.allSatisfy(\.isHTTPOnly) else {
            throw T3CompatError.authenticationFailed
        }
        return cookies
    }

    func hasValidBrowserSession(_ cookies: [HTTPCookie]) async -> Bool {
        guard case .ready(let origin) = state,
              !cookies.isEmpty,
              let url = URL(string: "/api/auth/session", relativeTo: origin)?.absoluteURL
        else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue(
            cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
            forHTTPHeaderField: "Cookie"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        guard let (data, response) = try? await URLSession(configuration: configuration).data(
            for: request
        ),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        return (try? JSONDecoder().decode(T3BrowserSession.self, from: data).authenticated) == true
    }

    nonisolated static func resolveEntry(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourcePath: String? = Bundle.main.resourcePath,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default
    ) -> String? {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates: [String?] = [
            environment["ACRO_T3_ENTRY"],
            resourcePath.map { "\($0)/t3-compat/node_modules/t3/dist/bin.mjs" },
            sourceRoot.appendingPathComponent("t3-compat/node_modules/t3/dist/bin.mjs").path,
            "\(currentDirectory)/apps/t3-compat/node_modules/t3/dist/bin.mjs",
            "\(currentDirectory)/../t3-compat/node_modules/t3/dist/bin.mjs",
        ]
        return candidates.compactMap { $0 }.first { fileManager.fileExists(atPath: $0) }
    }

    private func resolveNode() throws -> String {
        guard let node = NodeExecutable.resolve() else { throw T3CompatError.missingRuntime }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let raw = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "unknown"
        guard process.terminationStatus == 0,
              let version = T3NodeVersion(raw), version.supportsT3
        else { throw T3CompatError.unsupportedNode(raw.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return node
    }

    private func prepareStateDirectory() throws -> URL {
        let path = ProcessInfo.processInfo.environment["ACRO_T3_STATE_DIR"]
            ?? "\(NSHomeDirectory())/.acro/t3-compat"
        try fileManager.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func loadToken(from directory: URL) -> String? {
        let url = directory.appendingPathComponent("bootstrap-token")
        guard let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: "^[0-9a-f]{48}$", options: .regularExpression) != nil
        else { return nil }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return value
    }

    private func createToken(in directory: URL) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw T3CompatError.startupFailed
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("bootstrap-token")
        try Data("\(token)\n".utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    private func reusableOrigin(in directory: URL) async throws -> URL? {
        let url = directory.appendingPathComponent("userdata/server-runtime.json")
        guard let data = try? Data(contentsOf: url),
              let runtime = try? JSONDecoder().decode(T3RuntimeState.self, from: data),
              runtime.pid > 0,
              let origin = URL(string: runtime.origin),
              Self.isLoopback(origin)
        else { return nil }
        do {
            let info = try await environmentInfo(at: origin)
            guard info.serverVersion == Self.expectedVersion else {
                throw T3CompatError.invalidState
            }
            return origin
        } catch let error as T3CompatError {
            throw error
        } catch {
            return nil
        }
    }

    private func spawn(
        node: String,
        entry: String,
        stateDirectory: URL,
        environment: [String: String],
        port: Int,
        token: String
    ) throws -> Process {
        let logURL = stateDirectory.appendingPathComponent("server.log")
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()

        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [entry, "--bootstrap-fd", "0"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        process.environment = environment
        process.standardInput = input
        process.standardOutput = log
        process.standardError = log
        try process.run()
        let bootstrap = T3Bootstrap(
            port: port,
            t3Home: stateDirectory.path,
            desktopBootstrapToken: token
        )
        var data = try JSONEncoder().encode(bootstrap)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor in
                guard let self, self.spawnedProcess === process else { return }
                self.spawnedProcess = nil
                if case .ready = self.state {
                    self.state = .failed(T3CompatError.startupFailed.localizedDescription)
                }
            }
        }
        return process
    }

    private func waitUntilReady(origin: URL, process: Process) async throws {
        for _ in 0..<120 {
            if !process.isRunning { throw T3CompatError.startupFailed }
            if let info = try? await environmentInfo(at: origin),
               info.serverVersion == Self.expectedVersion {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        process.terminate()
        throw T3CompatError.startupFailed
    }

    private func environmentInfo(at origin: URL) async throws -> T3EnvironmentInfo {
        let url = URL(string: "/.well-known/t3/environment", relativeTo: origin)!.absoluteURL
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw T3CompatError.startupFailed
        }
        return try JSONDecoder().decode(T3EnvironmentInfo.self, from: data)
    }

    nonisolated static func isLoopback(_ url: URL) -> Bool {
        url.scheme == "http"
            && ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
            && url.port != nil
    }

    nonisolated static func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw T3CompatError.startupFailed }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw T3CompatError.startupFailed }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard read == 0 else { throw T3CompatError.startupFailed }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
