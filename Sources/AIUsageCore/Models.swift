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
    /// When these numbers were observed. Carried per window (not just per snapshot) because a
    /// merge may keep one window from an older snapshot while taking the other from the newer one.
    public var observedAt: Date
    /// Set when a quota credit is accepted; see `EchoGuard`.
    public var echoGuard: EchoGuard?

    public init(kind: WindowKind, usedPercent: Double, resetsAt: Date, observedAt: Date = Date(),
                echoGuard: EchoGuard? = nil) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.echoGuard = echoGuard
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

/// A session that has not made an API call since a quota credit keeps re-emitting the pre-credit
/// number. That reads as a rise, which the merge would normally take, so usage visibly jumps back.
/// After accepting a credit the window carries this guard and ignores readings at or above the
/// pre-credit level until it expires — real usage cannot climb back there that fast.
public struct EchoGuard: Codable, Equatable, Sendable {
    public var above: Double
    public var until: Date

    public init(above: Double, until: Date) {
        self.above = above
        self.until = until
    }
}

/// How `UsageSnapshot.merging` decides between a held higher reading and a lower incoming one.
public struct MergePolicy: Equatable, Sendable {
    /// A drop bigger than this is not an idle session re-emitting slightly older numbers: usage
    /// genuinely went down, which is what a quota reset credit does inside a live window.
    public var genuineDropPoints: Double = 10
    /// Whatever the size of the drop, a higher reading is only held this long. After that the
    /// newest observation wins, so a smaller genuine decrease still surfaces on its own.
    public var maxHold: TimeInterval = 10 * 60
    /// How far below the pre-credit reading the echo guard starts, so slightly older echoes are
    /// caught too.
    public var echoGuardMargin: Double = 2
    /// How long the guard lasts — long enough for every session to have refreshed, short enough
    /// that usage genuinely climbing back to the pre-credit level is not plausible.
    public var echoGuardDuration: TimeInterval = 30 * 60

    public init() {}

    /// Which of the two readings of one window to keep.
    public func resolve(current: UsageWindow, incoming: UsageWindow, fromProbe: Bool, now: Date) -> UsageWindow {
        // A different reset time is a different window instance: nothing carries over.
        guard current.resetsAt == incoming.resetsAt else { return incoming }
        // A probe is a live API round-trip. It is the truth, and it settles any open question.
        if fromProbe {
            var taken = incoming
            taken.echoGuard = nil
            return taken
        }
        if let guarded = current.echoGuard, now < guarded.until, incoming.usedPercent >= guarded.above {
            return current
        }

        var taken = incoming
        taken.echoGuard = current.echoGuard.flatMap { now < $0.until ? $0 : nil }

        let drop = current.usedPercent - incoming.usedPercent
        if drop >= genuineDropPoints {
            taken.echoGuard = EchoGuard(above: current.usedPercent - echoGuardMargin,
                                        until: now.addingTimeInterval(echoGuardDuration))
            return taken
        }
        // A smaller drop is more likely an idle session's older numbers; hold, but not forever.
        if drop > 0, now.timeIntervalSince(current.observedAt) < maxHold { return current }
        return taken
    }
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
    /// write is not the most recent truth — a lower reading is usually just an older one.
    /// It is not always: a quota reset credit lowers usage inside a live window. So a drop is
    /// held rather than ignored, and only while it still looks like staleness (see `MergePolicy`).
    /// A different `resetsAt` means a new window instance; the newer observation wins outright.
    public func merging(_ incoming: UsageSnapshot, policy: MergePolicy = MergePolicy()) -> UsageSnapshot {
        guard incoming.observedAt >= observedAt else { return self }
        var merged = incoming
        merged.windows = WindowKind.allCases.compactMap { kind in
            switch (window(kind), incoming.window(kind)) {
            case let (current?, new?):
                return policy.resolve(current: current, incoming: new,
                                      fromProbe: incoming.source == .probe, now: incoming.observedAt)
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
