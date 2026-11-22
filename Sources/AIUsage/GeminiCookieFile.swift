import Darwin
import Foundation

struct GeminiCookieFile {
    let url: URL

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func header(from input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = value.dropFirst("cookie:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard value.contains("="), value.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return value
    }

    func read() throws -> String? {
        try Self.header(from: String(contentsOf: url, encoding: .utf8))
    }

    func write(_ header: String) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".gemini-app-\(UUID().uuidString)")
        // Set owner-only permissions before writing the credential, then replace atomically.
        guard fm.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(at: staging) }
        let file = try FileHandle(forWritingTo: staging)
        try file.write(contentsOf: Data(header.utf8))
        try file.close()
        guard rename(staging.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func remove() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // An already absent file is safe to treat as removed.
        }
    }
}
