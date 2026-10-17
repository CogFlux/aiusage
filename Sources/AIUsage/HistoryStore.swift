import AIUsageCore
import Foundation

/// One provider's `UsageHistory`, kept in a JSON file in Application Support beside the DeepSeek
/// ledger. A new change point is written at once; a reading that only confirms the last one is
/// written at most every few minutes, so a busy statusline does not rewrite the file each second.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var history: UsageHistory

    static let confirmationSaveInterval: TimeInterval = 5 * 60

    private let url: URL
    private var savedAt = Date.distantPast

    init(provider: String) {
        url = HookInstaller.supportDir.appendingPathComponent("history-\(provider).json")
        var loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(UsageHistory.self, from: $0) }
            ?? UsageHistory()
        loaded.prune(now: Date())
        history = loaded
    }

    func record(_ windows: [UsageWindow]) {
        var updated = history
        let added = updated.record(windows)
        guard updated != history else { return }
        if added { updated.prune(now: Date()) }
        history = updated
        if added || Date().timeIntervalSince(savedAt) >= Self.confirmationSaveInterval { save() }
    }

    private func save() {
        savedAt = Date()
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: HookInstaller.supportDir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
