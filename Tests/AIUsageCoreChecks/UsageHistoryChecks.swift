import AIUsageCore
import Foundation

enum UsageHistoryChecks {
    static let t0 = Date(timeIntervalSince1970: 1_792_000_000)
    static let reset = t0.addingTimeInterval(4 * 3600)

    static func reading(_ minutes: Double, _ used: Double, kind: WindowKind = .fiveHour, resetsAt: Date = reset) -> UsageWindow {
        UsageWindow(kind: kind, usedPercent: used, resetsAt: resetsAt, observedAt: t0.addingTimeInterval(minutes * 60))
    }

    static func run() {
        storesChangePoints()
        ignoresStaleAndOutOfOrder()
        groupsByInstance()
        prunesEndedInstances()
        splitsLineAtGaps()
        roundTrips()
    }

    static func storesChangePoints() {
        var history = UsageHistory()
        Harness.check(history.record(reading(0, 10)), "first reading adds a point")
        Harness.check(!history.record(reading(5, 10)), "same value only confirms")
        Harness.check(history.record(reading(10, 12)), "a change adds a point")
        let points = history.instances(of: .fiveHour).first?.points ?? []
        Harness.equal(points.count, 2, "two change points")
        Harness.equal(points.first?.until, t0.addingTimeInterval(5 * 60), "confirmation extends until")
        Harness.equal(points.last?.until, points.last?.at, "unconfirmed point ends where it starts")
    }

    static func ignoresStaleAndOutOfOrder() {
        var history = UsageHistory()
        history.record(reading(10, 20))
        Harness.check(!history.record(reading(5, 15)), "older reading ignored")
        Harness.check(!history.record(reading(10, 25)), "same instant ignored")
        Harness.check(!history.record(reading(300, 30)), "reading after the reset ignored")
        Harness.equal(history.instances(of: .fiveHour).first?.points.count, 1, "nothing added")
    }

    static func groupsByInstance() {
        var history = UsageHistory()
        history.record([reading(0, 10), reading(0, 3, kind: .sevenDay, resetsAt: t0.addingTimeInterval(3 * 86400))])
        history.record(reading(1, 11, resetsAt: reset.addingTimeInterval(1)))
        let next = reset.addingTimeInterval(5 * 3600)
        history.record(reading(250, 1, resetsAt: next))
        let fives = history.instances(of: .fiveHour)
        Harness.equal(fives.count, 2, "a new reset time starts a new instance")
        Harness.equal(fives.first?.points.count, 2, "a second of jitter is the same instance")
        Harness.equal(fives.last?.resetsAt, next, "oldest first")
        Harness.equal(history.instances(of: .sevenDay).count, 1, "kinds kept apart")
        Harness.equal(history.instance(matching: reading(0, 0, resetsAt: reset.addingTimeInterval(-30)))?.resetsAt, reset,
                      "matching tolerates jitter")
        Harness.equal(fives.first?.startsAt, reset.addingTimeInterval(-5 * 3600), "start from the kind's length")
    }

    static func prunesEndedInstances() {
        var history = UsageHistory()
        history.record(reading(0, 10))
        let week = t0.addingTimeInterval(2 * 86400)
        history.record(reading(0, 5, kind: .sevenDay, resetsAt: week))
        history.prune(now: reset.addingTimeInterval(6 * 86400))
        Harness.equal(history.instances.count, 2, "within retention")
        history.prune(now: reset.addingTimeInterval(8 * 86400))
        Harness.equal(history.instances(of: .fiveHour).count, 0, "5h kept a week")
        Harness.equal(history.instances(of: .sevenDay).count, 1, "7d kept longer")
    }

    static func splitsLineAtGaps() {
        var history = UsageHistory()
        history.record(reading(0, 10))
        history.record(reading(10, 10))
        history.record(reading(20, 14))
        history.record(reading(120, 30)) // 100 minutes of silence
        guard let instance = history.instances(of: .fiveHour).first else {
            Harness.check(false, "instance recorded"); return
        }
        let segments = UsageHistory.segments(instance)
        Harness.equal(segments.map(\.measured), [true, false, true], "measured, gap, measured")
        Harness.equal(segments.first?.points.map(\.usedPercent), [10, 10, 14], "held level, then the rise")
        Harness.equal(segments[1].points.map(\.at), [t0.addingTimeInterval(20 * 60), t0.addingTimeInterval(120 * 60)],
                      "gap spans the silence")
        Harness.equal(segments.last?.points.count, 1, "a lone reading after a gap")
    }

    static func roundTrips() {
        var history = UsageHistory()
        history.record([reading(0, 10), reading(5, 10), reading(9, 11)])
        let data = try? JSONEncoder().encode(history)
        let decoded = data.flatMap { try? JSONDecoder().decode(UsageHistory.self, from: $0) }
        Harness.equal(decoded, history, "JSON round trip")
    }
}
