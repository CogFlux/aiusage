import Foundation

public struct PaceConfig: Equatable, Sendable {
    /// The usage level we plan to reach exactly when the window resets.
    public var targetPercent: Double = 99
    /// Below either threshold the projection is meaningless (divides by ~0), so it is withheld.
    public var minElapsedFraction: Double = 0.05
    public var minElapsedSeconds: TimeInterval = 15 * 60
    /// |delta| within this band counts as on track.
    public var onTrackTolerance: Double = 5

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

public enum PaceCalculator {
    public static func compute(window: UsageWindow, now: Date, config: PaceConfig = PaceConfig()) -> Pace {
        if now >= window.resetsAt {
            return Pace(usedPercent: 0, elapsedFraction: 0, budgetPercent: 0, deltaPercent: 0,
                        projectedPercent: nil, runoutAt: nil, status: .reset)
        }

        let duration = window.kind.duration
        let elapsedSeconds = max(0, now.timeIntervalSince(window.startsAt))
        let elapsed = min(1, elapsedSeconds / duration)
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
        } else if delta > config.onTrackTolerance {
            status = .overPace
        } else if delta < -config.onTrackTolerance {
            status = .underPace
        } else {
            status = .onTrack
        }

        return Pace(usedPercent: window.usedPercent, elapsedFraction: elapsed, budgetPercent: budget,
                    deltaPercent: delta, projectedPercent: projected, runoutAt: runout, status: status)
    }
}
