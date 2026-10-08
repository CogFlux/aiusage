import Foundation

/// Finds a command-line tool (`claude`, `codex`) from a GUI app, which starts with a minimal PATH.
enum ExecutableLocator {
    /// Only found paths are cached: the tool may be installed while the app is running.
    private static var loginShellCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// Override first (and only, when set), then the usual install locations, then the login
    /// shell's PATH. May spawn a login shell, which can take a second or more: call it off the
    /// main thread.
    static func resolve(_ name: String, candidates: [String], override: String) -> String? {
        let fm = FileManager.default
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let p = expand(trimmed)
            return fm.isExecutableFile(atPath: p) ? p : nil
        }
        if let found = candidates.map(expand).first(where: { fm.isExecutableFile(atPath: $0) }) {
            return found
        }
        if let cached = cacheLock.withLock({ loginShellCache[name] }), fm.isExecutableFile(atPath: cached) {
            return cached
        }
        let looked = loginShellLookup(name)
        cacheLock.withLock { loginShellCache[name] = looked }
        return looked
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// GUI apps get a minimal PATH; ask the login shell where the tool lives.
    private static func loginShellLookup(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(name)"]
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
}
