import Foundation

/// How long to wait between background OAuth usage queries. Follows CodexBar's adaptive cadence:
/// frequent while the user is looking, sparse when nobody is. A pure function of its inputs.
public enum RefreshPolicy {
    /// Each wait is scaled by a factor drawn from this range, so queries do not land on a fixed beat.
    public static let jitter: ClosedRange<Double> = 0.9...1.1

    /// `constrained`: Low Power Mode, or serious/critical thermal pressure.
    public static func delay(now: Date, lastMenuOpenAt: Date?, constrained: Bool) -> TimeInterval {
        if constrained { return 30 * 60 }
        guard let opened = lastMenuOpenAt else { return 30 * 60 }
        let since = now.timeIntervalSince(opened)
        if since <= 5 * 60 { return 2 * 60 }
        if since <= 3600 { return 5 * 60 }
        if since <= 4 * 3600 { return 15 * 60 }
        return 30 * 60
    }
}
