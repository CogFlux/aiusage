import Darwin
import Foundation

/// Lets Claude Code renew its own expired sign-in token. Claude Code renews it when an interactive
/// session starts; subcommands such as `claude auth status` only read local state. So this starts
/// `claude` in a pseudo-terminal, as CodexBar does, and stops it as soon as the Keychain item changes.
/// No prompt is typed, so no model request is made.
enum ClaudeSignInRenewal {
    /// Blocks until `isRenewed` reports true, `claude` exits, or `timeout` passes; run it off the main
    /// thread. `isRenewed` is polled a few times a second.
    static func run(claudePath: String, extraEnv: [String: String], timeout: TimeInterval, isRenewed: () -> Bool) {
        // The probe's empty scratch folder, so no project settings, CLAUDE.md or .mcp.json are picked up.
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        var primary: Int32 = -1
        var secondary: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &size) == 0 else { return }
        defer { close(primary) }
        _ = fcntl(primary, F_SETFL, fcntl(primary, F_GETFL) | O_NONBLOCK)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        // As the probe: no settings files (hooks, plugins) and no MCP servers, only the startup itself.
        process.arguments = ["--setting-sources", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]
        process.currentDirectoryURL = cwd
        var env = ClaudeProbe.standaloneEnvironment(cwd: cwd)
        // `--setting-sources ""` drops settings.json's `env` block (proxies etc.), so re-apply it.
        for (k, v) in extraEnv { env[k] = v }
        env["TERM"] = "xterm-256color"
        process.environment = env
        let terminal = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        do {
            try process.run()
        } catch {
            try? terminal.close()
            return
        }
        try? terminal.close()

        var screen = Data()
        var lastOutputAt = Date()
        var checkedOutputAt: Date?
        var trustAnswers = 0
        var polls = 0
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            let chunk = drain(primary)
            if !chunk.isEmpty {
                // The terminal UI asks for the cursor position and waits for an answer.
                if chunk.range(of: Data("\u{1b}[6n".utf8)) != nil { send("\u{1b}[1;1R", to: primary) }
                screen.append(chunk)
                if screen.count > 16_384 { screen.removeFirst(screen.count - 16_384) }
                lastOutputAt = Date()
            }
            // Claude Code asks once before working in a folder it has not seen. The folder is AIUsage's
            // empty scratch folder and "Yes" is the selected option, so Return accepts it.
            if trustAnswers < 2, checkedOutputAt != lastOutputAt, Date().timeIntervalSince(lastOutputAt) > 0.5 {
                checkedOutputAt = lastOutputAt
                let text = visibleText(screen)
                if text.contains("trustthisfolder") || text.contains("trustthefiles") {
                    send("\r", to: primary)
                    trustAnswers += 1
                    screen.removeAll()
                }
            }
            polls += 1
            if polls % 4 == 0, isRenewed() { break }
            usleep(100_000)
        }

        // SIGTERM lets Claude Code exit cleanly; keep reading so it never blocks on a full terminal.
        if process.isRunning {
            process.terminate()
            let killAt = Date().addingTimeInterval(3)
            while process.isRunning, Date() < killAt {
                _ = drain(primary)
                usleep(50_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private static func drain(_ fd: Int32) -> Data {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            collected.append(contentsOf: buffer[0..<n])
        }
        return collected
    }

    private static func send(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    /// Lowercased letters only: the terminal UI positions words with escape sequences rather than spaces.
    private static func visibleText(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        return String(text.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) })
    }
}
