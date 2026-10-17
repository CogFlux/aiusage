import Foundation

/// Readings of one provider's rate-limit windows over time, for the panel's usage chart.
///
/// The sources report only the current numbers, so history exists from the moment the app starts
/// recording. Readings are grouped by window instance (kind + `resetsAt`) and stored as change
/// points: a reading equal to the last one only extends that point's `until`, so the file stays
/// small however often the source is polled, and the time between readings stays distinguishable
/// from time nobody was looking.
public struct UsageHistory: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var at: Date
        public var usedPercent: Double
        /// The last time this same reading was seen; `at` until it is seen again.
        public var until: Date

        public init(at: Date, usedPercent: Double, until: Date? = nil) {
            self.at = at
            self.usedPercent = usedPercent
            self.until = until ?? at
        }
    }

    public struct Instance: Codable, Equatable, Sendable, Identifiable {
        public var kind: WindowKind
        public var resetsAt: Date
        public var points: [Point]

        public init(kind: WindowKind, resetsAt: Date, points: [Point]) {
            self.kind = kind
            self.resetsAt = resetsAt
            self.points = points
        }

        public var id: String { "\(kind.rawValue)@\(Int(resetsAt.timeIntervalSince1970))" }

        public var startsAt: Date { UsageWindow(kind: kind, usedPercent: 0, resetsAt: resetsAt).startsAt }
    }

    /// One stretch of the chart's line. `measured` is false for the straight line across a gap
    /// between readings longer than `UsageHistory.maxGap`: usage moved somewhere in there, but
    /// nothing saw when.
    public struct Segment: Equatable, Sendable {
        public var points: [Point]
        public var measured: Bool
    }

    /// Two reports of one window instance may disagree on `resetsAt` by a second or two.
    public static let sameInstanceTolerance: TimeInterval = 120

    /// How long instances are kept after they end: enough to page back through the previous few.
    public static func retention(_ kind: WindowKind) -> TimeInterval {
        switch kind {
        case .fiveHour: return 7 * 86400
        case .sevenDay: return 35 * 86400
        case .month: return 62 * 86400
        }
    }

    /// The longest silence between readings still drawn as measured. Background polls come at most
    /// 15–30 minutes apart, so a longer silence means the Mac slept or nothing was running.
    public static func maxGap(_ kind: WindowKind) -> TimeInterval {
        switch kind {
        case .fiveHour: return 35 * 60
        case .sevenDay: return 3 * 3600
        case .month: return 6 * 3600
        }
    }

    public private(set) var instances: [Instance] = []

    public init(instances: [Instance] = []) {
        self.instances = instances
    }

    /// Records each window at its own `observedAt`. Returns true when a new point was added, as
    /// opposed to nothing or an existing point merely being confirmed again.
    @discardableResult
    public mutating func record(_ windows: [UsageWindow]) -> Bool {
        windows.reduce(false) { added, window in record(window) || added }
    }

    @discardableResult
    public mutating func record(_ window: UsageWindow) -> Bool {
        // Read after its reset: the numbers belong to a window that is over.
        guard window.observedAt < window.resetsAt else { return false }
        let point = Point(at: window.observedAt, usedPercent: window.usedPercent)
        guard let index = instances.lastIndex(where: {
            $0.kind == window.kind
                && abs($0.resetsAt.timeIntervalSince(window.resetsAt)) <= Self.sameInstanceTolerance
        }) else {
            instances.append(Instance(kind: window.kind, resetsAt: window.resetsAt, points: [point]))
            return true
        }
        guard let last = instances[index].points.last else {
            instances[index].points = [point]
            return true
        }
        // Already seen, or older than what is held.
        guard point.at > last.until else { return false }
        if point.usedPercent == last.usedPercent {
            instances[index].points[instances[index].points.count - 1].until = point.at
            return false
        }
        instances[index].points.append(point)
        return true
    }

    /// The instances of `kind` that have readings, oldest first.
    public func instances(of kind: WindowKind) -> [Instance] {
        instances.filter { $0.kind == kind && !$0.points.isEmpty }.sorted { $0.resetsAt < $1.resetsAt }
    }

    /// The recorded instance matching `window`, if any.
    public func instance(matching window: UsageWindow) -> Instance? {
        instances.last {
            $0.kind == window.kind && abs($0.resetsAt.timeIntervalSince(window.resetsAt)) <= Self.sameInstanceTolerance
        }
    }

    /// Drops instances that ended longer ago than their kind's retention.
    public mutating func prune(now: Date) {
        instances.removeAll { now.timeIntervalSince($0.resetsAt) > Self.retention($0.kind) }
    }

    /// The line to draw for `instance`: runs of readings no further apart than `maxGap`, joined by
    /// unmeasured segments across longer gaps. A point confirmed later holds its level until then.
    public static func segments(_ instance: Instance) -> [Segment] {
        let gap = maxGap(instance.kind)
        var segments: [Segment] = []
        var run: [Point] = []
        for point in instance.points {
            if let previous = run.last, point.at.timeIntervalSince(previous.at) > gap {
                segments.append(Segment(points: run, measured: true))
                segments.append(Segment(points: [previous, Point(at: point.at, usedPercent: point.usedPercent)],
                                        measured: false))
                run = []
            }
            run.append(Point(at: point.at, usedPercent: point.usedPercent))
            if point.until > point.at {
                run.append(Point(at: point.until, usedPercent: point.usedPercent))
            }
        }
        if !run.isEmpty { segments.append(Segment(points: run, measured: true)) }
        return segments
    }
}
