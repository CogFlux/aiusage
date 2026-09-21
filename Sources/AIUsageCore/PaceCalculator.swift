import Foundation

public struct PaceConfig: Equatable, Sendable {
    /// The usage level we plan to reach exactly when the window resets.
    public var targetPercent: Double = 99
    /// Before this much of a window (or of the stretch after a re-pace checkpoint) has passed,
    /// the projection divides by ~0 and is withheld. Per window: a fixed fraction would keep the
    /// 7-day projection hidden for most of a day, which is longer than anyone waits.
    public var minElapsed: [WindowKind: TimeInterval] = [.fiveHour: 15 * 60, .sevenDay: 60 * 60]

    public func minElapsed(for kind: WindowKind) -> TimeInterval {
        minElapsed[kind] ?? 15 * 60
    }
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

/// "Re-pace from here": treat what was used up to `at` as sunk and spread only the remainder
/// evenly over the time left. Set by the user when a window is already far over budget and the
/// original even-pace line has stopped saying anything useful.
public struct PaceCheckpoint: Equatable, Sendable, Codable {
    public var at: Date
    public var usedPercent: Double

    public init(at: Date, usedPercent: Double) {
        self.at = at
        self.usedPercent = usedPercent
    }
}

public struct Pace: Equatable, Sendable {
    public var usedPercent: Double
    /// 0...1, how far through the window we are.
    public var elapsedFraction: Double
    /// What even pacing would have consumed by now: target × elapsed. With a checkpoint, the
    /// re-paced line: checkpoint.used + (target − checkpoint.used) × progress since the checkpoint.
    public var budgetPercent: Double
    /// used − budget. Positive = ahead of budget (bad), negative = under budget.
    public var deltaPercent: Double
    /// used ÷ elapsed: where the current average rate lands at window end. nil when too early.
    public var projectedPercent: Double?
    /// When the current average rate hits the target. nil when too early or when the projection stays under target.
    public var runoutAt: Date?
    public var status: PaceStatus
    /// The checkpoint in effect, if any.
    public var checkpoint: PaceCheckpoint?
    /// The plain even-pace budget from the window start, kept for display while a checkpoint
    /// rebases `budgetPercent`. nil when no checkpoint is in effect.
    public var baselineBudgetPercent: Double?
    /// While `tooEarly`: when the projection will start to be shown.
    public var projectionAvailableAt: Date?

    public init(usedPercent: Double, elapsedFraction: Double, budgetPercent: Double, deltaPercent: Double,
                projectedPercent: Double?, runoutAt: Date?, status: PaceStatus,
                checkpoint: PaceCheckpoint? = nil, baselineBudgetPercent: Double? = nil,
                projectionAvailableAt: Date? = nil) {
        self.usedPercent = usedPercent
        self.elapsedFraction = elapsedFraction
        self.budgetPercent = budgetPercent
        self.deltaPercent = deltaPercent
        self.projectedPercent = projectedPercent
        self.runoutAt = runoutAt
        self.status = status
        self.checkpoint = checkpoint
        self.baselineBudgetPercent = baselineBudgetPercent
        self.projectionAvailableAt = projectionAvailableAt
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
    /// No projection until this long after the origin (window start or checkpoint).
    public var minElapsed: TimeInterval
    /// Minimum gap between two over-pace alerts for one instance of this window.
    public var overPaceCooldown: TimeInterval
    /// Optional "re-pace from here" point; see `PaceCheckpoint`.
    public var checkpoint: PaceCheckpoint?

    public init(id: String, usedPercent: Double, startsAt: Date, resetsAt: Date,
                tolerance: Double, runningOutLead: TimeInterval, minElapsed: TimeInterval = 15 * 60,
                overPaceCooldown: TimeInterval = 60 * 60, checkpoint: PaceCheckpoint? = nil) {
        self.id = id
        self.usedPercent = usedPercent
        self.startsAt = startsAt
        self.resetsAt = resetsAt
        self.tolerance = tolerance
        self.runningOutLead = runningOutLead
        self.minElapsed = minElapsed
        self.overPaceCooldown = overPaceCooldown
        self.checkpoint = checkpoint
    }

    public static func claude(_ window: UsageWindow, config: PaceConfig = PaceConfig(),
                              alerts: AlertConfig = AlertConfig(), checkpoint: PaceCheckpoint? = nil) -> PaceWindow {
        PaceWindow(id: "claude.\(window.kind.rawValue)", usedPercent: window.usedPercent,
                   startsAt: window.startsAt, resetsAt: window.resetsAt,
                   tolerance: config.tolerance(for: window.kind),
                   runningOutLead: alerts.runningOutLead[window.kind] ?? 30 * 60,
                   minElapsed: config.minElapsed(for: window.kind),
                   overPaceCooldown: alerts.overPaceCooldown[window.kind] ?? 60 * 60,
                   checkpoint: checkpoint)
    }
}

public enum PaceCalculator {
    public static func compute(window: UsageWindow, now: Date, config: PaceConfig = PaceConfig(),
                               checkpoint: PaceCheckpoint? = nil) -> Pace {
        compute(PaceWindow.claude(window, config: config, checkpoint: checkpoint), now: now, config: config)
    }

    public static func compute(_ window: PaceWindow, now: Date, config: PaceConfig = PaceConfig()) -> Pace {
        if now >= window.resetsAt {
            return Pace(usedPercent: 0, elapsedFraction: 0, budgetPercent: 0, deltaPercent: 0,
                        projectedPercent: nil, runoutAt: nil, status: .reset)
        }

        let duration = window.resetsAt.timeIntervalSince(window.startsAt)
        let elapsedSeconds = max(0, now.timeIntervalSince(window.startsAt))
        let elapsed = duration > 0 ? min(1, elapsedSeconds / duration) : 1
        let baseline = config.targetPercent * elapsed

        // With a checkpoint the same math runs on the sub-window (checkpoint.at → resetsAt) with
        // the sub-quota (checkpoint.used → target): the origin shifts, nothing else changes.
        // A checkpoint that cannot shrink the problem (at or past the reset, or already at target)
        // is ignored rather than producing degenerate numbers.
        let cp = window.checkpoint.flatMap { c -> PaceCheckpoint? in
            c.at < window.resetsAt && c.usedPercent < config.targetPercent && c.at >= window.startsAt ? c : nil
        }
        let origin = cp?.at ?? window.startsAt
        let base = cp?.usedPercent ?? 0
        let span = window.resetsAt.timeIntervalSince(origin)
        let sinceOrigin = max(0, now.timeIntervalSince(origin))
        let progress = span > 0 ? min(1, sinceOrigin / span) : 1
        let remaining = config.targetPercent - base
        let consumed = max(0, window.usedPercent - base)

        let budget = base + remaining * progress
        let delta = window.usedPercent - budget
        let tooEarly = sinceOrigin < window.minElapsed

        var projected: Double?
        var runout: Date?
        if !tooEarly, progress > 0 {
            let p = base + consumed / progress
            projected = p
            if consumed > 0, p > config.targetPercent {
                // Constant-rate extrapolation from the origin.
                let secondsToTarget = sinceOrigin * (remaining / consumed)
                runout = origin.addingTimeInterval(secondsToTarget)
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
                    deltaPercent: delta, projectedPercent: projected, runoutAt: runout, status: status,
                    checkpoint: cp, baselineBudgetPercent: cp == nil ? nil : baseline,
                    projectionAvailableAt: tooEarly ? origin.addingTimeInterval(window.minElapsed) : nil)
    }
}
