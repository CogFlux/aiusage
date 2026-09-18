import Foundation

public enum AlertKind: String, CaseIterable, Codable, Sendable {
    /// Usage crossed into `overPace`. Re-armed once the window is back within tolerance.
    case overPace
    /// At the current rate the target is hit before the reset, within `AlertConfig.runningOutLead`.
    case runningOut
    /// A window instance we were tracking has passed its `resetsAt`.
    case windowReset
}

public struct UsageAlert: Equatable, Sendable {
    public var kind: AlertKind
    public var window: WindowKind
    public var resetsAt: Date
    /// Pace at the moment of firing. For `windowReset` it is the last pace seen before the reset.
    public var pace: Pace
}

public struct AlertConfig: Equatable, Sendable {
    /// How close `runoutAt` must be before `runningOut` fires.
    public var runningOutLead: [WindowKind: TimeInterval] = [.fiveHour: 30 * 60, .sevenDay: 12 * 3600]
    public init() {}
}

/// Decides which alerts fire as snapshots and time move forward, and remembers what has already
/// fired so each condition notifies once per window instance. Pure state machine: feed it every
/// new snapshot and every clock tick; the caller decides how to present the results.
public struct AlertTracker: Equatable, Sendable {
    private struct Instance: Equatable, Sendable {
        var resetsAt: Date
        var pace: Pace
    }

    private var fired: Set<String> = []
    private var lastSeen: [WindowKind: Instance] = [:]

    public init() {}

    public mutating func evaluate(snapshot: UsageSnapshot?, now: Date,
                                  paceConfig: PaceConfig = PaceConfig(),
                                  alertConfig: AlertConfig = AlertConfig()) -> [UsageAlert] {
        var alerts: [UsageAlert] = []

        for kind in WindowKind.allCases {
            let window = snapshot?.window(kind)

            // Reset: the instance we were tracking is over, whether or not the new snapshot still lists it.
            if let previous = lastSeen[kind], now >= previous.resetsAt {
                let key = "reset|\(kind.rawValue)|\(previous.resetsAt.timeIntervalSince1970)"
                if fired.insert(key).inserted {
                    alerts.append(UsageAlert(kind: .windowReset, window: kind, resetsAt: previous.resetsAt, pace: previous.pace))
                }
                lastSeen[kind] = nil
            }

            guard let window, now < window.resetsAt else { continue }
            let pace = PaceCalculator.compute(window: window, now: now, config: paceConfig)
            let instance = "\(kind.rawValue)|\(window.resetsAt.timeIntervalSince1970)"
            lastSeen[kind] = Instance(resetsAt: window.resetsAt, pace: pace)

            // Over pace: fires on entry, re-arms when the window leaves overPace.
            let overKey = "over|\(instance)"
            if pace.status == .overPace {
                if fired.insert(overKey).inserted {
                    alerts.append(UsageAlert(kind: .overPace, window: kind, resetsAt: window.resetsAt, pace: pace))
                }
            } else {
                fired.remove(overKey)
            }

            // Running out: once per instance.
            if let runout = pace.runoutAt, runout < window.resetsAt,
               let lead = alertConfig.runningOutLead[kind],
               runout.timeIntervalSince(now) <= lead {
                let key = "runout|\(instance)"
                if fired.insert(key).inserted {
                    alerts.append(UsageAlert(kind: .runningOut, window: kind, resetsAt: window.resetsAt, pace: pace))
                }
            }
        }
        return alerts
    }
}
