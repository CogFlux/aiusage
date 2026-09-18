import AIUsageCore
import Foundation

enum PaceCalculatorChecks {
    // A 5h window that resets at t=18000, so it started at t=0.
    private static let resets = Date(timeIntervalSince1970: 5 * 3600)

    private static func window(_ used: Double, kind: WindowKind = .fiveHour) -> UsageWindow {
        UsageWindow(kind: kind, usedPercent: used,
                    resetsAt: kind == .fiveHour ? resets : Date(timeIntervalSince1970: 7 * 86400))
    }

    static func run() {
        budgetIsTargetTimesElapsed()
        overPaceProducesRunout()
        onTrackWithinTolerance()
        tooEarlyWithholdsProjection()
        tooEarlyByFractionForSevenDayWindow()
        sevenDayUsesTighterTolerance()
        resetWhenPastResetsAt()
        alreadyExhaustedRunoutIsInThePast()
        customTarget()
    }

    static func budgetIsTargetTimesElapsed() {
        // Halfway through: budget = 99 × 0.5 = 49.5
        let pace = PaceCalculator.compute(window: window(42), now: Date(timeIntervalSince1970: 2.5 * 3600))
        Harness.close(pace.elapsedFraction, 0.5, "elapsed")
        Harness.close(pace.budgetPercent, 49.5, "budget")
        Harness.close(pace.deltaPercent, -7.5, "delta")
        Harness.close(pace.projectedPercent ?? -1, 84, "projected")
        Harness.check(pace.runoutAt == nil, "projection under target has no runout")
        Harness.equal(pace.status, .underPace, "status")
    }

    static func overPaceProducesRunout() {
        // 1h in, 40% used → projected 200%, target 99 reached at 1h × 99/40 = 2.475h
        let pace = PaceCalculator.compute(window: window(40), now: Date(timeIntervalSince1970: 3600))
        Harness.equal(pace.status, .overPace, "status")
        Harness.close(pace.projectedPercent ?? -1, 200, "projected")
        Harness.close(pace.runoutAt?.timeIntervalSince1970 ?? -1, 2.475 * 3600, accuracy: 1e-6, "runout")
    }

    static func onTrackWithinTolerance() {
        let pace = PaceCalculator.compute(window: window(52), now: Date(timeIntervalSince1970: 2.5 * 3600))
        Harness.equal(pace.status, .onTrack, "52% at 49.5% budget is on track")
    }

    static func tooEarlyWithholdsProjection() {
        // 10 minutes in (< 15 min floor) with 3% used would project 90%; must be withheld.
        let pace = PaceCalculator.compute(window: window(3), now: Date(timeIntervalSince1970: 600))
        Harness.equal(pace.status, .tooEarly, "status")
        Harness.check(pace.projectedPercent == nil, "no projection when too early")
        Harness.check(pace.runoutAt == nil, "no runout when too early")
        Harness.close(pace.deltaPercent, 3 - 99 * (600.0 / 18000), "delta is still reported")
    }

    static func tooEarlyByFractionForSevenDayWindow() {
        // 5% of 7d is 8.4h; 3h in is past the 15-min floor but under the fraction floor.
        let pace = PaceCalculator.compute(window: window(1, kind: .sevenDay), now: Date(timeIntervalSince1970: 3 * 3600))
        Harness.equal(pace.status, .tooEarly, "7d window 3h in is too early")
    }

    static func sevenDayUsesTighterTolerance() {
        // Halfway through 7d: budget 49.5. +4 is on track for 5h (±5) but over pace for 7d (±3).
        let half = Date(timeIntervalSince1970: 3.5 * 86400)
        let seven = PaceCalculator.compute(window: window(53.5, kind: .sevenDay), now: half)
        Harness.equal(seven.status, .overPace, "7d: +4 exceeds ±3")
        let five = PaceCalculator.compute(window: window(53.5), now: Date(timeIntervalSince1970: 2.5 * 3600))
        Harness.equal(five.status, .onTrack, "5h: +4 within ±5")
        let sevenUnder = PaceCalculator.compute(window: window(46, kind: .sevenDay), now: half)
        Harness.equal(sevenUnder.status, .underPace, "7d: -3.5 is under pace")
    }

    static func resetWhenPastResetsAt() {
        let pace = PaceCalculator.compute(window: window(80), now: resets.addingTimeInterval(1))
        Harness.equal(pace.status, .reset, "status")
        Harness.equal(pace.usedPercent, 0, "used shown as 0 after reset")
        Harness.equal(pace.budgetPercent, 0, "budget 0 after reset")
    }

    static func alreadyExhaustedRunoutIsInThePast() {
        let now = Date(timeIntervalSince1970: 2 * 3600)
        let pace = PaceCalculator.compute(window: window(100), now: now)
        Harness.check(pace.runoutAt != nil && pace.runoutAt! <= now, "100% used → runout already passed")
    }

    static func customTarget() {
        var config = PaceConfig()
        config.targetPercent = 80
        let pace = PaceCalculator.compute(window: window(40), now: Date(timeIntervalSince1970: 2.5 * 3600), config: config)
        Harness.close(pace.budgetPercent, 40, "budget with 80% target")
        Harness.equal(pace.status, .onTrack, "status")
    }
}
