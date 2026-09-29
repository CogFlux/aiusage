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
    /// When a quota reset credit was last seen to land in this window instance. Readings that
    /// predate it are pre-credit numbers and no longer count; see `MergePolicy`.
    public var creditAt: Date?

    public init(kind: WindowKind, usedPercent: Double, resetsAt: Date, observedAt: Date = Date(),
                creditAt: Date? = nil) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.creditAt = creditAt
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

/// Where a quota credit landed, kept per window instance so it survives the display switching to
/// another account's window and back: without it, that account's pre-credit numbers would count again.
public struct CreditMark: Codable, Equatable, Sendable {
    public var kind: WindowKind
    public var resetsAt: Date
    public var at: Date

    public init(kind: WindowKind, resetsAt: Date, at: Date) {
        self.kind = kind
        self.resetsAt = resetsAt
        self.at = at
    }
}

/// Which Claude Code session wrote a statusline snapshot, and how much API time it has spent.
public struct SessionStamp: Codable, Equatable, Sendable {
    public var id: String
    /// `cost.total_api_duration_ms`: grows only when the session makes an API call, which is also
    /// the only time its `rate_limits` change. A write where it has not grown is a re-emit.
    public var apiDurationMs: Double
    /// `cost.total_duration_ms`: wall time since this process started.
    public var durationMs: Double?

    public init(id: String, apiDurationMs: Double, durationMs: Double? = nil) {
        self.id = id
        self.apiDurationMs = apiDurationMs
        self.durationMs = durationMs
    }
}

/// Whether a snapshot carries numbers from an API response that just happened.
public enum Provenance: Equatable, Sendable {
    /// Straight from a live response: the probe, or a session whose API time just grew.
    case fresh
    /// A session re-emitting what it last heard. `lastFreshAt` is when that session last had a
    /// live response, so its numbers are at least that old; nil when unknown.
    case stale(lastFreshAt: Date?)
}

/// Remembers every statusline writer, so each write can be classified as fresh or a re-emit.
///
/// Several Claude Code sessions share the statusline file, and an idle one rewrites its last-known
/// numbers every `refreshInterval`. Its numbers can trail the truth by any amount — a session left
/// open overnight is a day behind on the 7-day window — so the size of a drop says nothing about
/// whether it is stale. Whether the writer's API time moved does.
///
/// A writer is a process, not a session: two terminals that resumed the same session write under
/// one `session_id` with separate API totals, and alternating between them would look like growth.
/// `observedAt − durationMs` is the process's start, which stays put for one process and differs
/// between two, so it tells them apart.
///
/// A writer seen for the first time is never trusted: nothing shows how old its numbers are, and a
/// resumed session may well carry numbers from before it was closed. One more API call settles it.
public struct SessionTracker: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var sessionID: String
        public var startedAt: Date?
        public var apiDurationMs: Double
        public var lastFreshAt: Date?
        public var seenAt: Date
    }

    /// How far two computed start times of one process may drift apart (write latency, rounding).
    public static let startTolerance: TimeInterval = 30
    /// Writers not heard from for this long are forgotten.
    public static let forgetAfter: TimeInterval = 8 * 86400

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func provenance(of snapshot: UsageSnapshot) -> Provenance {
        if snapshot.source == .probe { return .fresh }
        // Without a session stamp (older Claude Code) nothing can be told apart.
        guard let session = snapshot.session else { return .stale(lastFreshAt: nil) }
        let at = snapshot.observedAt
        let startedAt = session.durationMs.map { at.addingTimeInterval(-$0 / 1000) }
        let index = entries.firstIndex { entry in
            guard entry.sessionID == session.id else { return false }
            guard let a = entry.startedAt, let b = startedAt else { return entry.startedAt == startedAt }
            return abs(a.timeIntervalSince(b)) < Self.startTolerance
        }
        let previous = index.map { entries[$0] }
        let fresh = previous.map { session.apiDurationMs > $0.apiDurationMs } ?? false
        let lastFreshAt = fresh ? at : previous?.lastFreshAt
        let entry = Entry(sessionID: session.id, startedAt: startedAt, apiDurationMs: session.apiDurationMs,
                          lastFreshAt: lastFreshAt, seenAt: at)
        if let index { entries[index] = entry } else { entries.append(entry) }
        entries.removeAll { at.timeIntervalSince($0.seenAt) >= Self.forgetAfter }
        return fresh ? .fresh : .stale(lastFreshAt: lastFreshAt)
    }
}

/// How `UsageSnapshot.merging` decides between the reading it holds and an incoming one.
///
/// Usage only ever rises inside a window instance, except when a quota reset credit zeroes it
/// (`resetsAt` does not move). So a fresh reading is the truth, and one well below what is held
/// means a credit landed. A stale reading can only add information by being higher — unless it
/// predates the last credit, in which case it is a pre-credit number and is ignored however high.
public struct MergePolicy: Equatable, Sendable {
    /// A fresh reading this far below the held one is a credit. Smaller dips are the noise between
    /// sources (the probe reports a fraction, the statusline a rounded percentage).
    public var creditDropPoints: Double = 5
    /// Two reports of one window instance may disagree on `resetsAt` by a second or so.
    public var sameInstanceTolerance: TimeInterval = 120

    public init() {}

    /// Which of the two readings of one window to keep.
    public func resolve(current: UsageWindow, incoming: UsageWindow, provenance: Provenance) -> UsageWindow {
        let gap = incoming.resetsAt.timeIntervalSince(current.resetsAt)
        if abs(gap) > sameInstanceTolerance {
            // Another instance: usually the next one after a reset, but sessions signed in to
            // different accounts report different windows side by side, and neither reset time
            // says which account is in use. Follow live evidence; without it, move on only once
            // the held window is over.
            let heldIsOver = incoming.observedAt >= current.resetsAt
            let incomingIsLive = incoming.resetsAt > incoming.observedAt
            return provenance == .fresh || (heldIsOver && incomingIsLive) ? incoming : current
        }
        var taken = incoming
        // One identity per instance, whatever jitter the sources have.
        taken.resetsAt = current.resetsAt
        taken.creditAt = current.creditAt
        let drop = current.usedPercent - incoming.usedPercent
        switch provenance {
        case .fresh:
            if drop >= creditDropPoints {
                taken.creditAt = incoming.observedAt
                return taken
            }
            return drop > 0 ? current : taken
        case let .stale(lastFreshAt):
            if let credit = current.creditAt, (lastFreshAt ?? .distantPast) < credit { return current }
            return drop < 0 ? taken : current
        }
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var provider: String
    public var source: SnapshotSource
    /// When the numbers were true. For the statusline file this is the file's mtime.
    public var observedAt: Date
    public var windows: [UsageWindow]
    /// The statusline writer; nil for the probe.
    public var session: SessionStamp?
    /// Credits seen in window instances that are still live, including ones not currently shown.
    public var credits: [CreditMark]?

    public init(provider: String = "claude", source: SnapshotSource, observedAt: Date, windows: [UsageWindow],
                session: SessionStamp? = nil) {
        self.provider = provider
        self.source = source
        self.observedAt = observedAt
        self.windows = windows
        self.session = session
    }

    public func window(_ kind: WindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }

    /// Combine with a newer observation; see `MergePolicy` for how one window is decided.
    /// `provenance` defaults to what the source alone implies: a probe is fresh, a statusline
    /// write of unknown origin is not.
    /// A window missing from `incoming` is kept only while it is still live.
    public func merging(_ incoming: UsageSnapshot, provenance: Provenance? = nil,
                        policy: MergePolicy = MergePolicy()) -> UsageSnapshot {
        guard incoming.observedAt >= observedAt else { return self }
        let origin = provenance ?? (incoming.source == .probe ? .fresh : .stale(lastFreshAt: nil))
        let tolerance = policy.sameInstanceTolerance
        var credits = (credits ?? []).filter { $0.resetsAt > incoming.observedAt }
        func mark(_ window: UsageWindow) -> Int? {
            credits.firstIndex { $0.kind == window.kind && abs($0.resetsAt.timeIntervalSince(window.resetsAt)) <= tolerance }
        }
        func remember(_ window: UsageWindow) {
            guard let at = window.creditAt else { return }
            let entry = CreditMark(kind: window.kind, resetsAt: window.resetsAt, at: at)
            if let i = mark(window) { credits[i] = entry } else { credits.append(entry) }
        }
        windows.forEach(remember)

        var merged = incoming
        merged.windows = WindowKind.allCases.compactMap { kind in
            var result: UsageWindow?
            switch (window(kind), incoming.window(kind)) {
            case let (current?, new?):
                result = policy.resolve(current: current, incoming: new, provenance: origin)
            case let (_, new?):
                result = new
            case let (current?, nil):
                // Incoming lacks this window (e.g. it just reset or a probe omitted it); keep ours
                // only while it is still live so a dropped window does not linger.
                result = current.resetsAt > incoming.observedAt ? current : nil
            case (nil, nil):
                result = nil
            }
            guard var window = result else { return nil }
            if window.creditAt == nil, let i = mark(window) { window.creditAt = credits[i].at }
            remember(window)
            return window
        }
        merged.credits = credits.isEmpty ? nil : credits
        return merged
    }
}
