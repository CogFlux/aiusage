import Foundation

public struct PaceConfig: Equatable, Sendable {
    /// The usage level we plan to reach exactly when the window resets.
    public var targetPercent: Double = 99
    /// Below either threshold the projection is meaningless (divides by ~0), so it is withheld.
    public var minElapsedFraction: Double = 0.05
    public var minElapsedSeconds: TimeInterval = 15 * 60
    /// |delta| within this band counts as on track. Per window: the 5-hour window moves in
    /// bursts and needs slack; the 7-day window is smooth, and a 5-point miss there is a
    /// day's worth of quota, so it gets a tighter band.
    public var onTrackTolerance: [WindowKind: Double] = [.fiveHour: 5, .sevenDay: 3]

    public func tolerance(for kind: WindowKind) -> Double {
        onTrackTolerance[kind] ?? 5
    }

    public init() {}
}

public enum PaceStatus: String, Equatable, Sendable {
    /// `now` is past `resetsAt`; the window is over and the numbers no longer apply.
    case reset
    /// Window just started; delta is shown but no projection.
    case tooEarly
    /// Burning faster than the even-pace budget.
    case overPace
    case onTrack
    /// Burning slower than the even-pace budget.
    case underPace
}

public struct Pace: Equatable, Sendable {
    public var usedPercent: Double
    /// 0...1, how far through the window we are.
    public var elapsedFraction: Double
    /// What even pacing would have consumed by now: target × elapsed.
    public var budgetPercent: Double
    /// used − budget. Positive = ahead of budget (bad), negative = under budget.
    public var deltaPercent: Double
    /// used ÷ elapsed: where the current average rate lands at window end. nil when too early.
    public var projectedPercent: Double?
    /// When the current average rate hits the target. nil when too early or when the projection stays under target.
    public var runoutAt: Date?
    public var status: PaceStatus

    public init(usedPercent: Double, elapsedFraction: Double, budgetPercent: Double, deltaPercent: Double,
                projectedPercent: Double?, runoutAt: Date?, status: PaceStatus) {
        self.usedPercent = usedPercent
        self.elapsedFraction = elapsedFraction
        self.budgetPercent = budgetPercent
        self.deltaPercent = deltaPercent
        self.projectedPercent = projectedPercent
        self.runoutAt = runoutAt
        self.status = status
    }
}

/// Anything that can be paced: a Claude rate-limit window, a monthly spend budget, and so on.
/// `usedPercent` is progress toward the thing that resets at `resetsAt`, on a 0...100 scale.
public struct PaceWindow: Equatable, Sendable {
    /// Stable identity, e.g. "claude.five_hour" or "deepseek.month". Alerts dedupe on it.
    public var id: String
    public var usedPercent: Double
    public var startsAt: Date
    public var resetsAt: Date
    /// |delta| within this band counts as on track.
    public var tolerance: Double
    /// How close `runoutAt` must be before a running-out alert fires.
    public var runningOutLead: TimeInterval

    public init(id: String, usedPercent: Double, startsAt: Date, resetsAt: Date,
                tolerance: Double, runningOutLead: TimeInterval) {
        self.id = id
        self.usedPercent = usedPercent
        self.startsAt = startsAt
        self.resetsAt = resetsAt
        self.tolerance = tolerance
        self.runningOutLead = runningOutLead
    }

    public static func claude(_ window: UsageWindow, config: PaceConfig = PaceConfig(),
                              alerts: AlertConfig = AlertConfig()) -> PaceWindow {
        PaceWindow(id: "claude.\(window.kind.rawValue)", usedPercent: window.usedPercent,
                   startsAt: window.startsAt, resetsAt: window.resetsAt,
                   tolerance: config.tolerance(for: window.kind),
                   runningOutLead: alerts.runningOutLead[window.kind] ?? 30 * 60)
    }
}

public enum PaceCalculator {
    public static func compute(window: UsageWindow, now: Date, config: PaceConfig = PaceConfig()) -> Pace {
        compute(PaceWindow.claude(window, config: config), now: now, config: config)
    }

    public static func compute(_ window: PaceWindow, now: Date, config: PaceConfig = PaceConfig()) -> Pace {
        if now >= window.resetsAt {
            return Pace(usedPercent: 0, elapsedFraction: 0, budgetPercent: 0, deltaPercent: 0,
                        projectedPercent: nil, runoutAt: nil, status: .reset)
        }

        let duration = window.resetsAt.timeIntervalSince(window.startsAt)
        let elapsedSeconds = max(0, now.timeIntervalSince(window.startsAt))
        let elapsed = duration > 0 ? min(1, elapsedSeconds / duration) : 1
        let budget = config.targetPercent * elapsed
        let delta = window.usedPercent - budget
        let tooEarly = elapsed < config.minElapsedFraction || elapsedSeconds < config.minElapsedSeconds

        var projected: Double?
        var runout: Date?
        if !tooEarly, elapsed > 0 {
            let p = window.usedPercent / elapsed
            projected = p
            if window.usedPercent > 0, p > config.targetPercent {
                // Constant-rate extrapolation from the window start.
                let secondsToTarget = elapsedSeconds * (config.targetPercent / window.usedPercent)
                runout = window.startsAt.addingTimeInterval(secondsToTarget)
            }
        }

        let status: PaceStatus
        if tooEarly {
            status = .tooEarly
        } else if delta > window.tolerance {
            status = .overPace
        } else if delta < -window.tolerance {
            status = .underPace
        } else {
            status = .onTrack
        }

        return Pace(usedPercent: window.usedPercent, elapsedFraction: elapsed, budgetPercent: budget,
                    deltaPercent: delta, projectedPercent: projected, runoutAt: runout, status: status)
    }
}
