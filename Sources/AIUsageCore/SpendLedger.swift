import Foundation

/// One observation of a prepaid balance.
public struct BalanceSample: Codable, Equatable, Sendable {
    public var at: Date
    public var balance: Double

    public init(at: Date, balance: Double) {
        self.at = at
        self.balance = balance
    }
}

/// Derives spending from a series of balance observations. Prepaid APIs (DeepSeek) expose only
/// the current balance, so the ledger polls it and treats every decrease as spend and every
/// increase as a top-up. Only change points are stored; a run of identical balances collapses
/// into the first sample, so the ledger stays small however often it is polled.
///
/// Known blind spots: a decrease caused by granted credit expiring counts as spend, and spend
/// smaller than the balance's precision (¥0.01) is invisible until it accumulates.
public struct SpendLedger: Codable, Equatable, Sendable {
    public private(set) var samples: [BalanceSample] = []
    /// When the latest balance was last confirmed, which may be later than the last change point.
    public private(set) var lastObservedAt: Date?

    public init() {}

    public var latest: BalanceSample? { samples.last }

    public mutating func record(balance: Double, at: Date) {
        if let last = samples.last, at < last.at { return } // out-of-order sample; ignore
        lastObservedAt = at
        if let last = samples.last, last.balance == balance { return }
        samples.append(BalanceSample(at: at, balance: balance))
    }

    /// Sum of balance decreases whose change point falls in (from, to].
    public func spent(from: Date, to: Date) -> Double {
        pairwise(from: from, to: to) { previous, current in max(0, previous - current) }
    }

    /// Sum of balance increases whose change point falls in (from, to].
    public func toppedUp(from: Date, to: Date) -> Double {
        pairwise(from: from, to: to) { previous, current in max(0, current - previous) }
    }

    private func pairwise(from: Date, to: Date, _ delta: (Double, Double) -> Double) -> Double {
        var total = 0.0
        for i in 1..<max(1, samples.count) {
            let s = samples[i]
            if s.at > from, s.at <= to {
                total += delta(samples[i - 1].balance, s.balance)
            }
        }
        return total
    }

    public struct BurnRate: Equatable, Sendable {
        public var perDay: Double
        /// How much history the average covers; shorter than the requested window while the
        /// ledger is young, which is worth showing because young averages swing a lot.
        public var span: TimeInterval
    }

    /// Average spend per day over the trailing `days`, or nil when history is too short to be
    /// meaningful. Uses the real span of history when it is shorter than `days`. The default
    /// minimum is a full day: anything shorter sits inside one working stretch and extrapolating
    /// it to 24 hours overstates the rate.
    public func burnRate(days: Double, now: Date, minimumHistory: TimeInterval = 24 * 3600) -> BurnRate? {
        guard let first = samples.first else { return nil }
        let windowStart = now.addingTimeInterval(-days * 86400)
        let start = max(first.at, windowStart)
        let span = now.timeIntervalSince(start)
        guard span >= minimumHistory else { return nil }
        return BurnRate(perDay: spent(from: start, to: now) / (span / 86400), span: span)
    }

    public func burnRatePerDay(days: Double, now: Date, minimumHistory: TimeInterval = 24 * 3600) -> Double? {
        burnRate(days: days, now: now, minimumHistory: minimumHistory)?.perDay
    }

    /// When the balance reaches zero at `ratePerDay`. nil when the rate is zero or unknown.
    public func runoutDate(ratePerDay: Double?, now: Date) -> Date? {
        guard let rate = ratePerDay, rate > 0, let balance = latest?.balance, balance > 0 else { return nil }
        return now.addingTimeInterval(balance / rate * 86400)
    }

    /// Drops samples older than `cutoff`, keeping the last one before it as the baseline so the
    /// first retained change still has a "previous" balance.
    public mutating func prune(before cutoff: Date) {
        guard let firstKept = samples.firstIndex(where: { $0.at >= cutoff }), firstKept > 1 else { return }
        samples.removeFirst(firstKept - 1)
    }
}
