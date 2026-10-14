import Foundation

/// How long to wait between background usage queries. Follows CodexBar's adaptive cadence:
/// frequent while the user is looking, sparse when nobody is. Pure functions of their inputs.
public enum RefreshPolicy {
    /// Each wait is scaled by a factor drawn from this range, so queries do not land on a fixed beat.
    public static let jitter: ClosedRange<Double> = 0.9...1.1
    /// A query this long after a window's reset sees the new window rather than the old one.
    public static let resetGrace: TimeInterval = 15

    /// `constrained`: Low Power Mode, or serious/critical thermal pressure.
    /// `idleCap`: the longest wait while unconstrained. A source with nothing pushing readings in
    /// between (Codex) keeps it short, so its alerts do not lag behind the usage they report.
    public static func delay(now: Date, lastMenuOpenAt: Date?, constrained: Bool,
                             idleCap: TimeInterval = 30 * 60) -> TimeInterval {
        if constrained { return 30 * 60 }
        guard let opened = lastMenuOpenAt else { return idleCap }
        let since = now.timeIntervalSince(opened)
        if since <= 5 * 60 { return min(2 * 60, idleCap) }
        if since <= 3600 { return min(5 * 60, idleCap) }
        if since <= 4 * 3600 { return min(15 * 60, idleCap) }
        return idleCap
    }

    /// `wait`, shortened to land just after the first reset still ahead, so the reset is seen
    /// (and notified) on time rather than at the next regular query.
    public static func wait(_ wait: TimeInterval, wakingForResets resets: [Date], now: Date) -> TimeInterval {
        let untilReset = resets
            .map { $0.timeIntervalSince(now) + resetGrace }
            .filter { $0 > resetGrace }
            .min()
        return min(wait, untilReset ?? wait)
    }
}
