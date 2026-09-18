import Foundation

/// Installs the statusline hook into ~/.claude/settings.json. Mirrors hook/install.sh.
enum HookInstaller {
    enum InstallError: LocalizedError {
        case resourceMissing
        case settingsNotObject

        var errorDescription: String? {
            switch self {
            case .resourceMissing: return Strings.current.hookResourceMissing
            case .settingsNotObject: return Strings.current.hookSettingsNotObject
            }
        }
    }

    static let supportDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AIUsage", isDirectory: true)

    static var installedScriptURL: URL { supportDir.appendingPathComponent("aiusage-statusline.sh") }
    /// Claude Code runs `statusLine.command` through a shell, and "Application Support"
    /// contains a space, so the path must be quoted in settings.json.
    static var installedCommand: String { "'" + installedScriptURL.path + "'" }
    static var chainCommandURL: URL { supportDir.appendingPathComponent("chain-command") }
    static var statuslineFileURL: URL { supportDir.appendingPathComponent("claude-statusline.json") }
    /// Presence of this file tells the hook to print nothing into Claude Code's status line.
    static var hideLineFlagURL: URL { supportDir.appendingPathComponent("hide-claude-code-line") }

    static var showsLineInClaudeCode: Bool {
        !FileManager.default.fileExists(atPath: hideLineFlagURL.path)
    }

    static func setShowsLineInClaudeCode(_ show: Bool) throws {
        let fm = FileManager.default
        if show {
            if fm.fileExists(atPath: hideLineFlagURL.path) {
                try fm.removeItem(at: hideLineFlagURL)
            }
        } else {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try Data().write(to: hideLineFlagURL)
        }
    }
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static func isInstalled() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: installedScriptURL.path),
              let settings = try? loadSettings(),
              let statusLine = settings["statusLine"] as? [String: Any] else { return false }
        return statusLine["command"] as? String == installedCommand
    }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)

        guard let src = Bundle.module.url(forResource: "aiusage-statusline", withExtension: "sh") else {
            throw InstallError.resourceMissing
        }
        try Data(contentsOf: src).write(to: installedScriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedScriptURL.path)

        var settings = try loadSettings()
        var originalPermissions: Any?
        if fm.fileExists(atPath: settingsURL.path) {
            originalPermissions = try? fm.attributesOfItem(atPath: settingsURL.path)[.posixPermissions]
            let stamp = backupFormatter.string(from: Date())
            try fm.copyItem(at: settingsURL, to: settingsURL.appendingPathExtension("aiusage-backup-\(stamp)"))
        }

        if let prev = (settings["statusLine"] as? [String: Any])?["command"] as? String,
           prev != installedCommand, prev != installedScriptURL.path {
            try (prev + "\n").write(to: chainCommandURL, atomically: true, encoding: .utf8)
        }

        settings["statusLine"] = [
            "type": "command",
            "command": installedCommand,
            "refreshInterval": 60,
        ]
        var out = try JSONSerialization.data(withJSONObject: settings,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        out.append(0x0A)
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: settingsURL, options: .atomic)
        if let originalPermissions {
            try? fm.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: settingsURL.path)
        }
    }

    static func loadSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.settingsNotObject
        }
        return obj
    }

    /// The `env` block of settings.json (proxy variables and the like).
    static func settingsEnv() -> [String: String] {
        ((try? loadSettings())?["env"] as? [String: String]) ?? [:]
    }

    private static let backupFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
