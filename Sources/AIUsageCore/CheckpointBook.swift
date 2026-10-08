import Foundation

/// The pace origins in effect for one provider's rate-limit windows: the user's "re-pace from now"
/// points and the points where a quota reset credit landed. Shared by every provider that reports
/// 5-hour / 7-day windows (Claude, Codex), so both follow the same rules.
///
/// Each point is bound to one window instance by its `resetsAt`, so it silently expires when that
/// window ends. The user's own re-pace wins over a credit's; a new credit deletes the user's, since
/// the amount it treats as sunk has come back.
public struct CheckpointBook: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var resetsAt: Date
        public var checkpoint: PaceCheckpoint

        public init(resetsAt: Date, checkpoint: PaceCheckpoint) {
            self.resetsAt = resetsAt
            self.checkpoint = checkpoint
        }
    }

    /// Set by the user with "re-pace from now".
    public var manual: [WindowKind: Entry]
    /// Where a quota reset credit landed. The even-pace line is rebased onto it, so the budget runs
    /// from the credit to the target at the unchanged reset — what the restored quota actually has
    /// to be spent in. A correction to the line, not a user setting: the UI shows no re-pace state
    /// for it.
    public var restores: [WindowKind: Entry]

    /// Two reports of one window instance may disagree on `resetsAt` by a second or two.
    public static let sameInstanceTolerance: TimeInterval = 120

    public init(manual: [WindowKind: Entry] = [:], restores: [WindowKind: Entry] = [:]) {
        self.manual = manual
        self.restores = restores
    }

    /// The origin in effect for `window`, if any.
    public func checkpoint(for window: UsageWindow?) -> PaceCheckpoint? {
        guard let window else { return nil }
        return Self.applicable(manual[window.kind], to: window) ?? Self.applicable(restores[window.kind], to: window)
    }

    /// True when the origin in effect was placed by a quota credit rather than by the user.
    public func isAutomatic(_ window: UsageWindow?) -> Bool {
        guard let window else { return false }
        return Self.applicable(manual[window.kind], to: window) == nil
            && Self.applicable(restores[window.kind], to: window) != nil
    }

    /// The origins in effect for each of `windows`, for alert evaluation.
    public func active(for windows: [UsageWindow]) -> [WindowKind: PaceCheckpoint] {
        Dictionary(windows.compactMap { w in checkpoint(for: w).map { (w.kind, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Whether "re-pace from now" makes sense: a live window with quota left.
    public static func canRepace(_ window: UsageWindow?, now: Date, config: PaceConfig = PaceConfig()) -> Bool {
        guard let window else { return false }
        return now < window.resetsAt && window.usedPercent < config.targetPercent
    }

    /// The credit's own origin stays on file: precedence hides it while this one exists, and
    /// clearing this one must fall back to it rather than to the pre-credit line.
    public mutating func repace(_ window: UsageWindow, now: Date) {
        manual[window.kind] = Entry(resetsAt: window.resetsAt,
                                    checkpoint: PaceCheckpoint(at: now, usedPercent: window.usedPercent))
    }

    /// Undoes the user's own re-pace. A credit's rebase is not cleared: the budget falls back to
    /// it, not to the line from the window start that the credit made wrong.
    public mutating func clear(_ kind: WindowKind) {
        manual[kind] = nil
    }

    /// A credit landed in `window` at `at`: void the user's re-pace and make the credit the origin.
    public mutating func recordCredit(in window: UsageWindow, at: Date) {
        manual[window.kind] = nil
        restores[window.kind] = Entry(resetsAt: window.resetsAt,
                                      checkpoint: PaceCheckpoint(at: at, usedPercent: window.usedPercent))
    }

    /// For sources where every reading is authoritative (Codex), so no merge marks credits: a
    /// fall of at least `creditDropPoints` inside one window instance between two consecutive
    /// readings is a quota reset credit, landed at the newer reading.
    public mutating func recordCredits(from previous: [UsageWindow], to current: [UsageWindow],
                                       policy: MergePolicy = MergePolicy()) {
        for after in current {
            guard let before = previous.first(where: { $0.kind == after.kind }),
                  abs(before.resetsAt.timeIntervalSince(after.resetsAt)) <= policy.sameInstanceTolerance,
                  before.usedPercent - after.usedPercent >= policy.creditDropPoints else { continue }
            recordCredit(in: after, at: after.observedAt)
        }
    }

    // MARK: Persistence

    /// One table as JSON keyed by the window's raw value, e.g. `{"seven_day": {...}}`.
    public static func encode(_ entries: [WindowKind: Entry]) -> Data? {
        try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) }))
    }

    public static func decode(_ data: Data?) -> [WindowKind: Entry] {
        guard let data, let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            WindowKind(rawValue: key).map { ($0, value) }
        })
    }

    private static func applicable(_ entry: Entry?, to window: UsageWindow) -> PaceCheckpoint? {
        guard let entry,
              abs(window.resetsAt.timeIntervalSince(entry.resetsAt)) < sameInstanceTolerance,
              // Usage below the origin means another credit landed after it; the caller records
              // that one, and this covers the moment before it does.
              window.usedPercent >= entry.checkpoint.usedPercent else { return nil }
        return entry.checkpoint
    }
}
