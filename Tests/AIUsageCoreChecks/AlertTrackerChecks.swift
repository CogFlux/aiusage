import AIUsageCore
import Foundation

enum AlertTrackerChecks {
    // 5h window from t=0 to t=18000.
    private static func snap(_ used: Double, resets: TimeInterval = 18000, at t: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(source: .statusline, observedAt: Date(timeIntervalSince1970: t),
                      windows: [UsageWindow(kind: .fiveHour, usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))])
    }
    private static func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    static func run() {
        overPaceFiresOnceAndRearms()
        runningOutFiresWithinLeadOnly()
        windowResetFiresOnceAfterResetsAt()
        tooEarlyNeverFires()
        overPaceHoveringOnTheThresholdFiresOnce()
        overPaceCooldownSpacesRepeats()
    }

    // Delta oscillating around the 5h tolerance (+5): 4.6 ↔ 5.4 must not re-fire. Re-arm needs
    // delta ≤ tolerance − 2 = 3.
    static func overPaceHoveringOnTheThresholdFiresOnce() {
        var tracker = AlertTracker()
        // 2h in: budget 39.6. 45.2% → +5.6 over.
        var alerts = tracker.evaluate(snapshot: snap(45.2, at: 7200), now: at(7200))
        Harness.equal(alerts.map(\.kind), [.overPace], "fires on entry")
        // A minute later 44.8% → +5.2 − budget crept up: 39.8 → +5.0, on track by a hair.
        alerts = tracker.evaluate(snapshot: snap(44.8, at: 7260), now: at(7260))
        Harness.check(alerts.isEmpty, "dipping just under the line fires nothing")
        // Back over: 45.6% at 2h02m (budget 40.3) → +5.3.
        alerts = tracker.evaluate(snapshot: snap(45.6, at: 7320), now: at(7320))
        Harness.check(alerts.isEmpty, "hovering back over does not re-fire (hysteresis)")
        // Genuine recovery: 43% at 2.5h (budget 49.5) → −6.5, re-arms; then over again much later.
        _ = tracker.evaluate(snapshot: snap(43, at: 9000), now: at(9000))
        alerts = tracker.evaluate(snapshot: snap(80, at: 12600), now: at(12600))
        Harness.equal(alerts.map(\.kind), [.overPace], "fires again after a real recovery and the cooldown")
    }

    static func overPaceCooldownSpacesRepeats() {
        var tracker = AlertTracker()
        // Over at 1h (40% vs 19.8), recover fully at 1.5h (25% vs 29.7 → −4.7 ≤ 3), over again at 1.6h.
        var alerts = tracker.evaluate(snapshot: snap(40, at: 3600), now: at(3600))
        Harness.equal(alerts.map(\.kind), [.overPace], "first alert")
        _ = tracker.evaluate(snapshot: snap(25, at: 5400), now: at(5400))
        alerts = tracker.evaluate(snapshot: snap(45, at: 5760), now: at(5760))
        Harness.check(alerts.isEmpty, "re-armed but inside the 1 h cooldown: silent")
        // Still over once the cooldown has passed: fires then.
        alerts = tracker.evaluate(snapshot: snap(50, at: 7300), now: at(7300))
        Harness.equal(alerts.map(\.kind), [.overPace], "fires once the cooldown has elapsed")
    }

    static func overPaceFiresOnceAndRearms() {
        var tracker = AlertTracker()
        // 1h in, 40% used → over pace; runout at 2.475h is beyond the 30-minute lead.
        var alerts = tracker.evaluate(snapshot: snap(40, at: 3600), now: at(3600))
        Harness.equal(alerts.map(\.kind), [.overPace], "only overPace at 1h")
        // Same state a minute later: nothing new.
        alerts = tracker.evaluate(snapshot: snap(40, at: 3660), now: at(3660))
        Harness.check(alerts.isEmpty, "no repeat while still over pace")
        // Back within tolerance at 2.5h with 50% (budget 49.5).
        alerts = tracker.evaluate(snapshot: snap(50, at: 9000), now: at(9000))
        Harness.check(alerts.isEmpty, "returning to on-track fires nothing")
        // Over again at 3h with 70% (budget 59.4).
        alerts = tracker.evaluate(snapshot: snap(70, at: 10800), now: at(10800))
        Harness.equal(alerts.map(\.kind), [.overPace], "re-armed overPace fires again")
    }

    static func runningOutFiresWithinLeadOnly() {
        var tracker = AlertTracker()
        // 2h in, 70% used → runout at 2h × 99/70 = 2.83h, i.e. 50 min away: beyond 30 min lead.
        var alerts = tracker.evaluate(snapshot: snap(70, at: 7200), now: at(7200))
        Harness.equal(alerts.map(\.kind), [.overPace], "runout 50 min away does not fire yet")
        // 2.5h in, 85% used → runout at 2.5h × 99/85 = 2.91h, 25 min away: fires.
        alerts = tracker.evaluate(snapshot: snap(85, at: 9000), now: at(9000))
        Harness.equal(alerts.map(\.kind), [.runningOut], "runningOut fires within lead")
        // Later, still running out: no repeat.
        alerts = tracker.evaluate(snapshot: snap(95, at: 10000), now: at(10000))
        Harness.check(alerts.isEmpty, "runningOut fires once per window instance")
    }

    static func windowResetFiresOnceAfterResetsAt() {
        var tracker = AlertTracker()
        _ = tracker.evaluate(snapshot: snap(30, at: 9000), now: at(9000))
        // Clock passes resetsAt while the stale snapshot still lists the old window.
        var alerts = tracker.evaluate(snapshot: snap(30, at: 9000), now: at(18001))
        Harness.equal(alerts.map(\.kind), [.windowReset], "reset fires when now passes resetsAt")
        Harness.equal(alerts.first?.pace.usedPercent, 30, "reset alert carries the last pace seen")
        alerts = tracker.evaluate(snapshot: snap(30, at: 9000), now: at(18100))
        Harness.check(alerts.isEmpty, "reset fires once")
        // New window instance appears: tracked fresh, nothing fires at 2% used.
        alerts = tracker.evaluate(snapshot: snap(2, resets: 36000, at: 19000), now: at(19000))
        Harness.check(alerts.isEmpty, "new instance starts clean")
    }

    static func tooEarlyNeverFires() {
        var tracker = AlertTracker()
        // 5 minutes in with 10% used would be wildly over pace, but the window is too early.
        let alerts = tracker.evaluate(snapshot: snap(10, at: 300), now: at(300))
        Harness.check(alerts.isEmpty, "tooEarly status suppresses alerts")
    }
}
