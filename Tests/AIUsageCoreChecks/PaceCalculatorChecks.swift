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
        checkpointRebasesBudgetOntoRemainder()
        checkpointRunoutExtrapolatesFromCheckpoint()
        checkpointTooEarlyIsRelativeToCheckpoint()
        degenerateCheckpointIsIgnored()
    }

    // 7d window (t=0 → 7d). Two days in the user has burnt 60% and re-paces from there:
    // the remaining 39 points spread over the remaining 5 days.
    private static let day: TimeInterval = 86400
    private static let cp = PaceCheckpoint(at: Date(timeIntervalSince1970: 2 * day), usedPercent: 60)

    static func checkpointRebasesBudgetOntoRemainder() {
        // 4.5 days in = halfway through the remainder: budget = 60 + 39 × 0.5 = 79.5
        let pace = PaceCalculator.compute(window: window(75, kind: .sevenDay),
                                          now: Date(timeIntervalSince1970: 4.5 * day), checkpoint: cp)
        Harness.close(pace.budgetPercent, 79.5, "rebased budget")
        Harness.close(pace.deltaPercent, -4.5, "delta against the rebased budget")
        Harness.close(pace.baselineBudgetPercent ?? -1, 99 * 4.5 / 7, "baseline kept for display")
        Harness.equal(pace.checkpoint, cp, "checkpoint echoed back")
        Harness.equal(pace.status, .underPace, "status uses the rebased delta")
        // consumed 15 over half the remainder → 30 by the reset → lands at 90
        Harness.close(pace.projectedPercent ?? -1, 90, "projected from the checkpoint")
        Harness.check(pace.runoutAt == nil, "projected under target has no runout")
        // elapsedFraction stays the plain window progress
        Harness.close(pace.elapsedFraction, 4.5 / 7, "elapsed fraction unchanged")
    }

    static func checkpointRunoutExtrapolatesFromCheckpoint() {
        // One day after the checkpoint another 19.5 points are gone (half the remainder in a
        // fifth of the time) → target hit 2 days after the checkpoint, at t = 4d.
        let pace = PaceCalculator.compute(window: window(79.5, kind: .sevenDay),
                                          now: Date(timeIntervalSince1970: 3 * day), checkpoint: cp)
        Harness.equal(pace.status, .overPace, "status")
        Harness.close(pace.projectedPercent ?? -1, 60 + 19.5 * 5, "projected")
        Harness.close(pace.runoutAt?.timeIntervalSince1970 ?? -1, 4 * day, accuracy: 1e-6, "runout")
    }

    static func checkpointTooEarlyIsRelativeToCheckpoint() {
        // Ten minutes after re-pacing: too early by the 15-minute floor, even though the window
        // itself is two days old.
        let pace = PaceCalculator.compute(window: window(60, kind: .sevenDay),
                                          now: Date(timeIntervalSince1970: 2 * day + 600), checkpoint: cp)
        Harness.equal(pace.status, .tooEarly, "too early after the checkpoint")
        Harness.check(pace.projectedPercent == nil, "no projection while too early")
        Harness.close(pace.deltaPercent, 0, accuracy: 0.1, "delta is ~0 right after re-pacing")
    }

    static func degenerateCheckpointIsIgnored() {
        let now = Date(timeIntervalSince1970: 4 * day)
        let plain = PaceCalculator.compute(window: window(70, kind: .sevenDay), now: now)
        let atTarget = PaceCheckpoint(at: Date(timeIntervalSince1970: 2 * day), usedPercent: 99)
        let past = PaceCheckpoint(at: Date(timeIntervalSince1970: 8 * day), usedPercent: 50)
        for bad in [atTarget, past] {
            let pace = PaceCalculator.compute(window: window(70, kind: .sevenDay), now: now, checkpoint: bad)
            Harness.close(pace.budgetPercent, plain.budgetPercent, "budget falls back to the plain line")
            Harness.check(pace.checkpoint == nil && pace.baselineBudgetPercent == nil, "checkpoint reported as not in effect")
        }
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
