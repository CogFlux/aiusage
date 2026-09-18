import AIUsageCore
import Foundation

enum UsageFormatterChecks {
    private static func pace(_ status: PaceStatus, used: Double = 42, delta: Double = 0) -> Pace {
        Pace(usedPercent: used, elapsedFraction: 0.5, budgetPercent: used - delta, deltaPercent: delta,
             projectedPercent: nil, runoutAt: nil, status: status)
    }

    static func run() {
        menuBarTitles()
        compactMenuBarTitles()
        countdown()
        signed()
    }

    static func menuBarTitles() {
        Harness.equal(UsageFormatter.menuBarTitle(kind: .fiveHour, pace: nil, stale: false), "5h —", "no data")
        Harness.equal(UsageFormatter.menuBarTitle(kind: .fiveHour, pace: pace(.overPace, delta: 9.4), stale: false), "5h 42% ▲9", "over pace")
        Harness.equal(UsageFormatter.menuBarTitle(kind: .fiveHour, pace: pace(.underPace, delta: -3), stale: false), "5h 42% ▼3", "under pace")
        Harness.equal(UsageFormatter.menuBarTitle(kind: .sevenDay, pace: pace(.onTrack), stale: false), "7d 42% ●", "on track")
        Harness.equal(UsageFormatter.menuBarTitle(kind: .fiveHour, pace: pace(.tooEarly, used: 3), stale: false), "5h 3%", "too early")
        Harness.equal(UsageFormatter.menuBarTitle(kind: .fiveHour, pace: pace(.reset, used: 0), stale: false), "5h 0% ↺", "reset")
        Harness.equal(UsageFormatter.menuBarTitle(kind: .fiveHour, pace: pace(.onTrack), stale: true), "5h 42% ● ⧗", "stale marker")
    }

    static func compactMenuBarTitles() {
        Harness.equal(UsageFormatter.menuBarTitle(kind: .fiveHour, pace: nil, stale: false, compact: true), "—", "compact no data")
        Harness.equal(UsageFormatter.menuBarTitle(kind: .fiveHour, pace: pace(.overPace, delta: 9.4), stale: true, compact: true), "42%", "compact drops pace, label and stale marker")
        Harness.equal(UsageFormatter.menuBarTitle(kind: .sevenDay, pace: pace(.reset, used: 0), stale: false, compact: true), "0%", "compact reset")
    }

    static func countdown() {
        let now = Date(timeIntervalSince1970: 0)
        Harness.equal(UsageFormatter.countdown(to: Date(timeIntervalSince1970: 45), from: now), "45s", "seconds")
        Harness.equal(UsageFormatter.countdown(to: Date(timeIntervalSince1970: 7 * 60), from: now), "7m", "minutes")
        Harness.equal(UsageFormatter.countdown(to: Date(timeIntervalSince1970: 2 * 3600 + 13 * 60), from: now), "2h13m", "hours")
        Harness.equal(UsageFormatter.countdown(to: Date(timeIntervalSince1970: 3 * 86400 + 4 * 3600), from: now), "3d 4h", "days")
        Harness.equal(UsageFormatter.countdown(to: Date(timeIntervalSince1970: -5), from: now), "0s", "past")
    }

    static func signed() {
        Harness.equal(UsageFormatter.signed(9.4), "+9", "positive")
        Harness.equal(UsageFormatter.signed(-2.6), "-3", "negative")
        Harness.equal(UsageFormatter.signed(0.2), "0", "zero")
    }
}
