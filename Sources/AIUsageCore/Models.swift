import Foundation

/// A rate-limit window as Claude exposes it. Both known data sources
/// (statusline JSON and `claude -p` stream-json) report the same two windows.
public enum WindowKind: String, Codable, CaseIterable, Hashable, Sendable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"

    public var duration: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 3600
        case .sevenDay: return 7 * 86400
        }
    }

    public var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        }
    }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public var kind: WindowKind
    /// 0...100. Sources reporting a 0...1 fraction are normalized before reaching here.
    public var usedPercent: Double
    public var resetsAt: Date

    public init(kind: WindowKind, usedPercent: Double, resetsAt: Date) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// Claude only reports the reset time; the window is assumed to be
    /// exactly `kind.duration` long, so its start is derived.
    public var startsAt: Date { resetsAt.addingTimeInterval(-kind.duration) }
}

public enum SnapshotSource: String, Codable, Sendable {
    /// Mirrored from the JSON Claude Code feeds its status line (passive, free).
    case statusline
    /// Result of an explicit `claude -p` probe (active, costs one tiny request).
    case probe
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var provider: String
    public var source: SnapshotSource
    /// When the numbers were true. For the statusline file this is the file's mtime.
    public var observedAt: Date
    public var windows: [UsageWindow]

    public init(provider: String = "claude", source: SnapshotSource, observedAt: Date, windows: [UsageWindow]) {
        self.provider = provider
        self.source = source
        self.observedAt = observedAt
        self.windows = windows
    }

    public func window(_ kind: WindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }

    /// Combine with a newer observation. Several Claude Code sessions write the statusline file,
    /// and an idle one re-emits its last-known numbers every `refreshInterval`, so the most recent
    /// write is not the most recent truth. Within one window instance (same `resetsAt`) usage
    /// only ever grows, so the higher value wins; a different `resetsAt` means a new window and
    /// the newer observation wins outright.
    public func merging(_ incoming: UsageSnapshot) -> UsageSnapshot {
        guard incoming.observedAt >= observedAt else { return self }
        var merged = incoming
        merged.windows = WindowKind.allCases.compactMap { kind in
            switch (window(kind), incoming.window(kind)) {
            case let (current?, new?) where current.resetsAt == new.resetsAt && current.usedPercent > new.usedPercent:
                return current
            case let (_, new?):
                return new
            case let (current?, nil):
                // Incoming lacks this window (e.g. it just reset or a probe omitted it); keep ours
                // only while it is still live so a dropped window does not linger.
                return current.resetsAt > incoming.observedAt ? current : nil
            case (nil, nil):
                return nil
            }
        }
        return merged
    }
}
