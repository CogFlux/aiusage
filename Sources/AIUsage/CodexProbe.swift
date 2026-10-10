import AIUsageCore
import Foundation

/// Reads Codex quota through `codex app-server`: the JSON-RPC server Codex's own IDE extension
/// talks to. `account/rateLimits/read` is a usage lookup, not a model request, so it is free and
/// leaves the quota untouched. The server answers in about three seconds and exits when its stdin
/// closes.
enum CodexProbe {
    enum ProbeError: LocalizedError {
        case timeout
        case exited(Int32, String)
        case server(String)
        /// Codex could not reach the backend; see `CodexParser.ResponseError.isNetworkFailure`.
        case network

        var errorDescription: String? {
            let strings = Strings.current
            switch self {
            case .timeout:
                return strings.codexTimeout
            case let .exited(code, stderr):
                let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
                return strings.codexExited(code, tail)
            case let .server(message):
                return strings.codexServerError(message)
            case .network:
                return strings.codexNetworkError
            }
        }
    }

    private static let candidatePaths = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "~/.local/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
    ]

    /// May spawn a login shell, which can take a second or more: call it off the main thread.
    static func resolveCodexPath(override: String) -> String? {
        ExecutableLocator.resolve("codex", candidates: candidatePaths, override: override)
    }

    private static let readRequestID = 2

    static func run(codexPath: String, timeout: TimeInterval = 30) async throws -> CodexUsage {
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(codexPath: codexPath, timeout: timeout)
        }.value
    }

    private static func runBlocking(codexPath: String, timeout: TimeInterval) throws -> CodexUsage {
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        // Same reason as the Claude probe: keep an inherited PWD (say, ~/Documents) from pointing
        // the child at a folder macOS would ask permission for.
        env["PWD"] = cwd.path
        env.removeValue(forKey: "OLDPWD")
        // An npm-installed codex is a node script; node is usually in one of these.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env

        let input = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = input
        process.standardOutput = out
        process.standardError = err

        let state = ReadState()
        let answered = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                answered.signal()
            } else if state.feed(chunk, requestID: readRequestID) {
                answered.signal()
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { state.appendError(chunk) }
        }

        // A server that dies at startup closes its stdin; writing to it must fail, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["clientInfo": ["name": "aiusage", "title": "AIUsage", "version": appVersion]]],
            ["jsonrpc": "2.0", "method": "initialized"],
            // Background poll: skip the reset-credit detail lookup, which is a second backend call.
            ["jsonrpc": "2.0", "id": readRequestID, "method": "account/rateLimits/read",
             "params": ["excludeResetCreditDetails": true]],
        ]
        for request in requests {
            var line = try JSONSerialization.data(withJSONObject: request)
            line.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: line)
        }

        let timedOut = answered.wait(timeout: .now() + timeout) == .timedOut
        // Closing stdin is how the server is told to quit; terminate whatever does not.
        try? input.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
        out.fileHandleForReading.readabilityHandler = nil

        switch state.outcome {
        case let .usage(usage)?:
            return usage
        case let .failure(error)?:
            throw error.isNetworkFailure ? ProbeError.network : ProbeError.server(error.message)
        case nil:
            if timedOut {
                if process.isRunning { process.terminate() }
                throw ProbeError.timeout
            }
            process.waitUntilExit()
            throw ProbeError.exited(process.terminationStatus, state.errorText)
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Server output, collected on the pipes' background queues and split into lines.
private final class ReadState: @unchecked Sendable {
    enum Outcome {
        case usage(CodexUsage)
        case failure(CodexParser.ResponseError)
    }

    private let lock = NSLock()
    private var pending = Data()
    private var stderr = Data()
    private var result: Outcome?

    /// Returns true once the response to `requestID` has arrived.
    func feed(_ chunk: Data, requestID: Int) -> Bool {
        lock.withLock {
            guard result == nil else { return true }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                do {
                    if let usage = try CodexParser.parse(line: line, requestID: requestID, observedAt: Date()) {
                        result = .usage(usage)
                    }
                } catch let error as CodexParser.ResponseError {
                    result = .failure(error)
                } catch {
                    result = .failure(CodexParser.ResponseError(message: error.localizedDescription))
                }
                if result != nil { return true }
            }
            return false
        }
    }

    func appendError(_ chunk: Data) { lock.withLock { stderr.append(chunk) } }
    var outcome: Outcome? { lock.withLock { result } }
    var errorText: String { lock.withLock { String(decoding: stderr, as: UTF8.self) } }
}
