import AIUsageCore
import Darwin
import Foundation

/// Reads Antigravity quota without model requests or credentials of its own:
/// 1. Local Antigravity 2.0 (or Gemini.app) language server over loopback Connect-RPC
///    (`RetrieveUserQuotaSummary`, falling back to `GetUserStatus` / `GetCommandModelConfigs`).
/// 2. `agy -p /usage --output-format json` when the desktop app is closed and `agy` is installed.
/// 3. Local Antigravity IDE extension language server.
enum AntigravityProbe {
    enum ProbeError: LocalizedError, Equatable {
        case notRunning
        case missingCSRFToken
        case noListeningPort
        case apiError(String)
        case parseFailed
        case cliTimeout
        case cliFailed(String)

        var errorDescription: String? {
            let s = Strings.current
            switch self {
            case .notRunning: return s.antigravityNotRunning
            case .missingCSRFToken: return s.antigravityMissingToken
            case .noListeningPort: return s.antigravityNoPort
            case let .apiError(msg): return s.antigravityAPIError(msg)
            case .parseFailed: return s.antigravityMalformed
            case .cliTimeout: return s.antigravityCLITimeout
            case let .cliFailed(msg): return s.antigravityCLIFailed(msg)
            }
        }
    }

    private struct CandidateProcess {
        let pid: Int32
        let kind: AntigravityParser.ProcessKind
        let csrfToken: String
        let extensionPort: Int?
        let extensionCSRFToken: String?
    }

    private struct Endpoint: Equatable {
        let scheme: String
        let port: Int
        let csrfToken: String
    }

    private static let quotaSummaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let userStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let commandModelConfigPath = "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"
    private static let unleashPath = "/exa.language_server_pb.LanguageServerService/GetUnleashData"

    private static let candidateAgyPaths = [
        "/opt/homebrew/bin/agy",
        "/usr/local/bin/agy",
        "~/.local/bin/agy",
        "/Applications/Antigravity.app/Contents/Resources/app/bin/agy",
        "/Applications/Gemini.app/Contents/Resources/app/bin/agy",
    ]

    private static let localhostDelegate = LocalhostTrustDelegate()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: localhostDelegate, delegateQueue: nil)
    }()

    /// May spawn a login shell; call off the main thread.
    static func resolveAgyPath(override: String) -> String? {
        ExecutableLocator.resolve("agy", candidates: candidateAgyPaths, override: override)
    }

    /// Probes local Antigravity sources in priority order: desktop app -> `agy` CLI -> IDE extension.
    static func fetch(agyPath: String?, timeout: TimeInterval = 10) async throws -> AntigravityUsage {
        let discovery = await Task.detached(priority: .userInitiated) {
            discoverProcesses()
        }.value

        var lastError: ProbeError?

        // 1. Antigravity 2.0 / Gemini desktop app (preferred: gives structured 5h + weekly summaries).
        let appProcs = discovery.processes.filter { $0.kind == .app }
        if !appProcs.isEmpty {
            if let usage = await probeProcesses(appProcs, source: .app, timeout: timeout, lastError: &lastError) {
                return usage
            }
        }

        // 2. `agy -p /usage --output-format json` when the desktop app is closed (or gave no summary).
        if let agyPath {
            do {
                return try await runAgyPrintUsage(agyPath: agyPath, timeout: 30)
            } catch let error as ProbeError {
                if lastError == nil { lastError = error }
            } catch {
                if lastError == nil { lastError = .cliFailed(error.localizedDescription) }
            }
        }

        // 3. Antigravity IDE extension language server fallback.
        let ideProcs = discovery.processes.filter { $0.kind == .ide }
        if !ideProcs.isEmpty {
            if let usage = await probeProcesses(ideProcs, source: .ide, timeout: timeout, lastError: &lastError) {
                return usage
            }
        }

        if let lastError { throw lastError }
        if discovery.sawTokenless { throw ProbeError.missingCSRFToken }
        throw ProbeError.notRunning
    }

    // MARK: - Local language server probing

    private static func probeProcesses(_ processes: [CandidateProcess], source: AntigravitySource,
                                       timeout: TimeInterval, lastError: inout ProbeError?) async -> AntigravityUsage? {
        var best: AntigravityUsage?
        for proc in processes {
            do {
                let usage = try await probeProcess(proc, source: source, timeout: timeout)
                if let current = best {
                    if score(usage) > score(current) { best = usage }
                } else {
                    best = usage
                }
            } catch let error as ProbeError {
                lastError = error
            } catch {
                lastError = .apiError(error.localizedDescription)
            }
        }
        return best
    }

    private static func score(_ usage: AntigravityUsage) -> Int {
        let structuredCount = usage.groups.reduce(0) { $0 + $1.windows.count }
        var total = structuredCount * 100 + usage.groups.count * 10
        if usage.planName != nil { total += 2 }
        if usage.accountEmail != nil { total += 1 }
        return total
    }

    private static func probeProcess(_ proc: CandidateProcess, source: AntigravitySource,
                                     timeout: TimeInterval) async throws -> AntigravityUsage {
        let ports = await Task.detached(priority: .userInitiated) {
            listeningTCPPorts(pid: proc.pid)
        }.value
        let candidates = buildEndpoints(ports: ports, proc: proc)
        guard !candidates.isEmpty else { throw ProbeError.noListeningPort }

        let ordered = await reorderReachableFirst(candidates, timeout: min(timeout, 2.5))
        let now = Date()

        // Preferred: RetrieveUserQuotaSummary (Antigravity 2.0 5h + weekly grouped summary).
        if let summaryData = try? await postFirstWorking(path: quotaSummaryPath,
                                                         body: ["forceRefresh": true],
                                                         endpoints: ordered,
                                                         timeout: timeout),
           let summary = try? AntigravityParser.parseQuotaSummary(summaryData, observedAt: now, source: source) {
            // Best-effort identity/plan/credits lookup on the same local server.
            if let statusData = try? await postFirstWorking(path: userStatusPath,
                                                            body: defaultMetadataBody(),
                                                            endpoints: ordered,
                                                            timeout: 1.5),
               let identity = AntigravityParser.parseIdentity(statusData) {
                return summary.mergingIdentity(email: identity.email,
                                               planName: identity.planName,
                                               availablePromptCredits: identity.availablePromptCredits,
                                               availableFlowCredits: identity.availableFlowCredits)
            }
            return summary
        }

        // Fallback 1: GetUserStatus (older App builds or Antigravity IDE).
        var fallbackError: Error?
        do {
            let data = try await postFirstWorking(path: userStatusPath,
                                                  body: defaultMetadataBody(),
                                                  endpoints: ordered,
                                                  timeout: timeout)
            return try AntigravityParser.parseUserStatus(data, observedAt: now, source: source)
        } catch {
            fallbackError = error
        }

        // Fallback 2: GetCommandModelConfigs.
        do {
            let data = try await postFirstWorking(path: commandModelConfigPath,
                                                  body: defaultMetadataBody(),
                                                  endpoints: ordered,
                                                  timeout: timeout)
            return try AntigravityParser.parseCommandModelConfigs(data, observedAt: now, source: source)
        } catch {
            throw mapError(fallbackError ?? error)
        }
    }

    private static func buildEndpoints(ports: [Int], proc: CandidateProcess) -> [Endpoint] {
        var result: [Endpoint] = []
        func appendUnique(_ ep: Endpoint) {
            if !result.contains(ep) { result.append(ep) }
        }
        for port in ports {
            appendUnique(Endpoint(scheme: "https", port: port, csrfToken: proc.csrfToken))
            appendUnique(Endpoint(scheme: "http", port: port, csrfToken: proc.csrfToken))
        }
        if let extPort = proc.extensionPort {
            if let extToken = proc.extensionCSRFToken {
                appendUnique(Endpoint(scheme: "http", port: extPort, csrfToken: extToken))
            }
            appendUnique(Endpoint(scheme: "http", port: extPort, csrfToken: proc.csrfToken))
        }
        return result
    }

    private static func reorderReachableFirst(_ endpoints: [Endpoint], timeout: TimeInterval) async -> [Endpoint] {
        let body: [String: Any] = [
            "context": [
                "properties": [
                    "devMode": "false",
                    "extensionVersion": "unknown",
                    "hasAnthropicModelAccess": "true",
                    "ide": "antigravity",
                    "ideVersion": "unknown",
                    "installationId": "aiusage",
                    "language": "UNSPECIFIED",
                    "os": "macos",
                    "requestedModelId": "MODEL_UNSPECIFIED",
                ],
            ],
        ]
        for (idx, ep) in endpoints.enumerated() {
            do {
                _ = try await post(path: unleashPath, body: body, endpoint: ep, timeout: timeout)
                var reordered = [ep]
                reordered.append(contentsOf: endpoints.enumerated().compactMap { $0.offset == idx ? nil : $0.element })
                return reordered
            } catch let ProbeError.apiError(msg) where msg.hasPrefix("HTTP ") {
                // Server answered HTTP on this port even if GetUnleashData returned non-200.
                var reordered = [ep]
                reordered.append(contentsOf: endpoints.enumerated().compactMap { $0.offset == idx ? nil : $0.element })
                return reordered
            } catch {
                continue
            }
        }
        return endpoints
    }

    private static func postFirstWorking(path: String, body: [String: Any],
                                         endpoints: [Endpoint], timeout: TimeInterval) async throws -> Data {
        var lastError: Error?
        for ep in endpoints {
            do {
                return try await post(path: path, body: body, endpoint: ep, timeout: timeout)
            } catch {
                lastError = error
            }
        }
        throw mapError(lastError ?? ProbeError.apiError("no response"))
    }

    private static func post(path: String, body: [String: Any],
                             endpoint: Endpoint, timeout: TimeInterval) async throws -> Data {
        guard let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(path)") else {
            throw ProbeError.apiError("invalid URL")
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(bodyData.count), forHTTPHeaderField: "Content-Length")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !endpoint.csrfToken.isEmpty {
            request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProbeError.apiError("invalid response")
        }
        guard http.statusCode == 200 else {
            throw ProbeError.apiError("HTTP \(http.statusCode)")
        }
        return data
    }

    private static func defaultMetadataBody() -> [String: Any] {
        [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "en",
            ],
        ]
    }

    private static func mapError(_ error: Error) -> ProbeError {
        if let pe = error as? ProbeError { return pe }
        if let parse = error as? AntigravityParser.ParseError {
            switch parse {
            case let .apiError(msg): return .apiError(msg)
            case .invalidJSON, .emptyQuota: return .parseFailed
            }
        }
        return .apiError(error.localizedDescription)
    }

    // MARK: - `agy -p /usage --output-format json` fallback

    private static let maxCLIOutputBytes = 1024 * 1024

    private static func runAgyPrintUsage(agyPath: String, timeout: TimeInterval) async throws -> AntigravityUsage {
        try await Task.detached(priority: .userInitiated) {
            try runAgyPrintUsageBlocking(agyPath: agyPath, timeout: timeout)
        }.value
    }

    private static func runAgyPrintUsageBlocking(agyPath: String, timeout: TimeInterval) throws -> AntigravityUsage {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("aiusage-agy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workDir) }

        // Prevent a signed-out `agy` from popping open a browser tab during background polling.
        let shimDir = workDir.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: shimDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let openShim = shimDir.appendingPathComponent("open")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: openShim)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: openShim.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: agyPath)
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        process.currentDirectoryURL = workDir

        var env = ProcessInfo.processInfo.environment
        env["PWD"] = workDir.path
        env.removeValue(forKey: "OLDPWD")
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        env["BROWSER"] = openShim.path
        env["PATH"] = "\(shimDir.path):/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err

        let outputBuffer = LockedBuffer(limit: maxCLIOutputBytes)
        let errorBuffer = LockedBuffer(limit: 16 * 1024)
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { outputBuffer.append(chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { errorBuffer.append(chunk) }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw ProbeError.cliFailed(error.localizedDescription)
        }

        let pid = process.processIdentifier
        let pgid: pid_t? = setpgid(pid, pid) == 0 ? pid : nil

        let waited = finished.wait(timeout: .now() + timeout)
        if waited == .timedOut {
            if let pgid { _ = kill(-pgid, SIGTERM) }
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                if let pgid { _ = kill(-pgid, SIGKILL) }
                _ = kill(pid, SIGKILL)
            }
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw ProbeError.cliTimeout
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        outputBuffer.append(out.fileHandleForReading.readDataToEndOfFile())
        errorBuffer.append(err.fileHandleForReading.readDataToEndOfFile())

        let stdoutData = outputBuffer.snapshot()
        guard process.terminationStatus == 0, !stdoutData.isEmpty else {
            let tail = String(decoding: errorBuffer.snapshot(), as: UTF8.self)
                .split(separator: "\n").suffix(2).joined(separator: " ")
            throw ProbeError.cliFailed(tail.isEmpty ? "exit \(process.terminationStatus)" : tail)
        }

        // `agy` may print a single JSON object (or lines ending in one); try full payload first.
        let observedAt = Date()
        if let usage = try? AntigravityParser.parseCLIUsageReport(stdoutData, observedAt: observedAt) {
            return usage
        }
        for line in String(decoding: stdoutData, as: UTF8.self).split(separator: "\n").reversed() {
            if let lineData = String(line).data(using: .utf8),
               let usage = try? AntigravityParser.parseCLIUsageReport(lineData, observedAt: observedAt) {
                return usage
            }
        }
        throw ProbeError.parseFailed
    }

    // MARK: - Darwin process & socket enumeration

    private struct DiscoveryResult {
        var processes: [CandidateProcess] = []
        var sawTokenless = false
    }

    private static func discoverProcesses() -> DiscoveryResult {
        var result = DiscoveryResult()
        for pid in allPIDs() {
            guard let execPath = executablePath(pid: pid), isCandidateExecutablePath(execPath) else { continue }
            guard let args = processArguments(pid: pid), !args.isEmpty else { continue }
            let commandLine = args.joined(separator: " ")
            guard let kind = AntigravityParser.classifyLanguageServer(commandLine: commandLine) else { continue }
            guard let csrf = AntigravityParser.extractFlag("--csrf_token", from: args) else {
                result.sawTokenless = true
                continue
            }
            let extPort = AntigravityParser.extractFlag("--extension_server_port", from: args).flatMap(Int.init)
            let extCSRF = AntigravityParser.extractFlag("--extension_server_csrf_token", from: args)
            result.processes.append(CandidateProcess(
                pid: pid,
                kind: kind,
                csrfToken: csrf,
                extensionPort: extPort,
                extensionCSRFToken: extCSRF
            ))
        }
        return result
    }

    private static func isCandidateExecutablePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("antigravity") || lower.contains("/gemini.app/") { return true }
        let base = URL(fileURLWithPath: lower).lastPathComponent
        return base.hasPrefix("language_server") || base.hasPrefix("language-server")
    }

    private static func allPIDs() -> [Int32] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<Int32>.stride
        var pids = [Int32](repeating: 0, count: Int(bytes) / stride + 32)
        let actual = pids.withUnsafeMutableBytes { buf in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buf.baseAddress, Int32(buf.count))
        }
        guard actual > 0 else { return [] }
        return Array(pids.prefix(Int(actual) / stride)).filter { $0 > 0 }
    }

    private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = buffer.withUnsafeMutableBytes { buf in
            proc_pidpath(pid, buf.baseAddress, UInt32(buf.count))
        }
        guard count > 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            let slice = UnsafeRawBufferPointer(start: base, count: Int(count)).prefix { $0 != 0 }
            return slice.isEmpty ? nil : String(bytes: slice, encoding: .utf8)
        }
    }

    private static func processArguments(pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size >= MemoryLayout<Int32>.size,
              size <= 1024 * 1024
        else { return nil }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { buf in
            sysctl(&mib, u_int(mib.count), buf.baseAddress, &size, nil, 0)
        }
        guard ok == 0 else { return nil }
        if size < data.count { data.removeSubrange(size..<data.count) }
        return AntigravityParser.parseProcArgs2(data)
    }

    private static func listeningTCPPorts(pid: Int32) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let actual = fds.withUnsafeMutableBytes { buf in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf.baseAddress, Int32(buf.count))
        }
        guard actual > 0 else { return [] }

        var ports: Set<Int> = []
        for fd in fds.prefix(Int(actual) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info,
                                     Int32(MemoryLayout<socket_fdinfo>.size))
            guard got == MemoryLayout<socket_fdinfo>.size,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }
            let rawPort = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            let port = Int(UInt16(bigEndian: rawPort))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }
}

/// Accepts self-signed TLS certificates strictly on loopback (`127.0.0.1` / `localhost`).
private final class LocalhostTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    private func handle(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let host = space.host.lowercased()
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              host == "127.0.0.1" || host == "localhost",
              let trust = space.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge)
    }
}

private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let room = limit - data.count
        guard room > 0 else { return }
        data.append(chunk.prefix(room))
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
