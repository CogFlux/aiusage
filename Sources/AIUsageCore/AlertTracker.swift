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
    /// `PaceWindow.id` of the window that fired, e.g. "claude.five_hour".
    public var windowID: String
    public var resetsAt: Date
    /// Pace at the moment of firing. For `windowReset` it is the last pace seen before the reset.
    public var pace: Pace

    public init(kind: AlertKind, windowID: String, resetsAt: Date, pace: Pace) {
        self.kind = kind
        self.windowID = windowID
        self.resetsAt = resetsAt
        self.pace = pace
    }

    /// The Claude window this alert is about, if it is one.
    public var claudeWindow: WindowKind? {
        guard windowID.hasPrefix("claude.") else { return nil }
        return WindowKind(rawValue: String(windowID.dropFirst("claude.".count)))
    }
}

public struct AlertConfig: Equatable, Sendable {
    /// How close `runoutAt` must be before `runningOut` fires, per Claude window.
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
    private var lastSeen: [String: Instance] = [:]

    public init() {}

    /// Convenience for the Claude snapshot.
    public mutating func evaluate(snapshot: UsageSnapshot?, now: Date,
                                  paceConfig: PaceConfig = PaceConfig(),
                                  alertConfig: AlertConfig = AlertConfig(),
                                  checkpoints: [WindowKind: PaceCheckpoint] = [:]) -> [UsageAlert] {
        let windows = (snapshot?.windows ?? []).map {
            PaceWindow.claude($0, config: paceConfig, alerts: alertConfig, checkpoint: checkpoints[$0.kind])
        }
        return evaluate(windows: windows, now: now, paceConfig: paceConfig)
    }

    /// `windows` is the complete current set; a window we tracked that is missing from it is
    /// treated as absent (its reset alert still fires once `now` passes its `resetsAt`).
    public mutating func evaluate(windows: [PaceWindow], now: Date,
                                  paceConfig: PaceConfig = PaceConfig()) -> [UsageAlert] {
        var alerts: [UsageAlert] = []
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = Set(byID.keys).union(lastSeen.keys)

        for id in ids.sorted() {
            let window = byID[id]

            // Reset: the instance we were tracking is over, whether or not it is still listed.
            if let previous = lastSeen[id], now >= previous.resetsAt {
                let key = "reset|\(id)|\(previous.resetsAt.timeIntervalSince1970)"
                if fired.insert(key).inserted {
                    alerts.append(UsageAlert(kind: .windowReset, windowID: id, resetsAt: previous.resetsAt, pace: previous.pace))
                }
                lastSeen[id] = nil
            }

            guard let window, now < window.resetsAt else { continue }
            let pace = PaceCalculator.compute(window, now: now, config: paceConfig)
            let instance = "\(id)|\(window.resetsAt.timeIntervalSince1970)"
            lastSeen[id] = Instance(resetsAt: window.resetsAt, pace: pace)

            // Over pace: fires on entry, re-arms when the window leaves overPace.
            let overKey = "over|\(instance)"
            if pace.status == .overPace {
                if fired.insert(overKey).inserted {
                    alerts.append(UsageAlert(kind: .overPace, windowID: id, resetsAt: window.resetsAt, pace: pace))
                }
            } else {
                fired.remove(overKey)
            }

            // Running out: once per instance.
            if let runout = pace.runoutAt, runout < window.resetsAt,
               runout.timeIntervalSince(now) <= window.runningOutLead {
                let key = "runout|\(instance)"
                if fired.insert(key).inserted {
                    alerts.append(UsageAlert(kind: .runningOut, windowID: id, resetsAt: window.resetsAt, pace: pace))
                }
            }
        }
        return alerts
    }
}
