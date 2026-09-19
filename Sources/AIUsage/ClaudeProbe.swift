import AIUsageCore
import Foundation

/// Active query: run one minimal `claude -p` call and read the `rate_limit_event` it emits.
/// Everything that would inflate the system prompt (MCP servers, tools, plugins, CLAUDE.md)
/// is switched off so the request stays around 500 tokens.
enum ClaudeProbe {
    enum ProbeError: LocalizedError {
        case timeout
        case notLoggedIn
        case exited(Int32, String)
        case noRateLimitEvent

        var errorDescription: String? {
            let strings = Strings.current
            switch self {
            case .timeout:
                return strings.probeTimeout
            case .notLoggedIn:
                return strings.probeNotLoggedIn
            case let .exited(code, stderr):
                let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
                return strings.probeExited(code, tail)
            case .noRateLimitEvent:
                return strings.probeNoEvent
            }
        }
    }

    static let arguments: [String] = [
        "-p", "OK",
        "--model", "haiku",
        "--output-format", "stream-json", "--verbose",
        "--max-turns", "1",
        "--setting-sources", "",
        "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
        "--tools", "",
        "--system-prompt", "Reply OK.",
        "--no-session-persistence",
    ]

    private static let candidatePaths = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.local/bin/claude",
        "~/.claude/local/claude",
    ]

    private static var loginShellCache: String??

    static func resolveClaudePath(override: String) -> String? {
        let fm = FileManager.default
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let p = expand(trimmed)
            return fm.isExecutableFile(atPath: p) ? p : nil
        }
        if let found = candidatePaths.map(expand).first(where: { fm.isExecutableFile(atPath: $0) }) {
            return found
        }
        if let cached = loginShellCache { return cached }
        let looked = loginShellLookup()
        loginShellCache = .some(looked)
        return looked
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// GUI apps get a minimal PATH; ask the login shell where `claude` lives.
    private static func loginShellLookup() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        // Keep shell startup files (prompt plugins, git status) away from the app's cwd.
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0 && !s.isEmpty) ? s : nil
    }

    static func run(claudePath: String, extraEnv: [String: String], timeout: TimeInterval = 60) async throws -> UsageSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(claudePath: claudePath, extraEnv: extraEnv, timeout: timeout)
        }.value
    }

    private static func runBlocking(claudePath: String, extraEnv: [String: String], timeout: TimeInterval) throws -> UsageSnapshot {
        // An empty cwd so no project CLAUDE.md or .mcp.json gets picked up.
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.currentDirectoryURL = cwd
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        // Session-scoped variables leak in when the app itself was launched from a terminal
        // running inside Claude Code; the probe must look like a fresh, standalone invocation.
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID",
                    "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED",
                    "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN"] {
            env.removeValue(forKey: key)
        }
        // `Process` changes the working directory but leaves the inherited `PWD` untouched, and
        // Claude Code trusts `PWD`. If the app was launched from a shell sitting in ~/Documents
        // (or Desktop, Downloads), the probe would touch that folder and macOS would prompt for
        // folder access. Point it at the scratch directory instead.
        env["PWD"] = cwd.path
        env.removeValue(forKey: "OLDPWD")
        // `--setting-sources ""` drops settings.json, including its `env` block (proxies etc.),
        // so re-apply that block explicitly.
        for (k, v) in extraEnv { env[k] = v }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Without this, claude waits 3 s for piped stdin before proceeding.
        process.standardInput = FileHandle.nullDevice
        try process.run()

        var timedOut = false
        let killer = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // Drain stderr concurrently so a chatty stderr can't block stdout.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer.cancel()

        let text = String(decoding: outData, as: UTF8.self)
        if let snap = ProbeParser.parse(streamJSON: text, observedAt: Date()) {
            return snap
        }
        if timedOut { throw ProbeError.timeout }
        // Claude Code reports a missing login as a synthetic assistant message, not on stderr.
        if text.contains("\"error\":\"authentication_failed\"") || text.contains("Not logged in") {
            throw ProbeError.notLoggedIn
        }
        if process.terminationStatus != 0 {
            throw ProbeError.exited(process.terminationStatus, String(decoding: errData, as: UTF8.self))
        }
        throw ProbeError.noRateLimitEvent
    }
}
