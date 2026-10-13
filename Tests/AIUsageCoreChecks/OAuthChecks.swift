import AIUsageCore
import Foundation

enum OAuthChecks {
    // Shape documented by CodexBar's Claude provider; values made up.
    static let usageJSON = """
    {
      "five_hour": {"utilization": 25.0, "resets_at": "2026-10-14T03:19:59.686376+00:00"},
      "seven_day": {"utilization": 29.0, "resets_at": "2026-10-19T13:59:59.686397+00:00"},
      "seven_day_opus": null,
      "seven_day_sonnet": {"utilization": 3.0, "resets_at": "2026-10-19T13:59:59+00:00"},
      "extra_usage": {"is_enabled": false}
    }
    """

    static func run() {
        parsesBothWindowsAsPercent()
        skipsAWindowThatIsNotRunning()
        returnsNilWithoutWindows()
        rejectsNonObject()
        mergesAsAFreshReading()
    }

    static func parsesBothWindowsAsPercent() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        guard let snap = try? OAuthUsageParser.parse(Data(usageJSON.utf8), observedAt: at) else {
            Harness.check(false, "usage sample should parse"); return
        }
        Harness.equal(snap.source, .oauth, "source")
        Harness.equal(snap.window(.fiveHour)?.usedPercent, 25, "utilization is already a percentage")
        Harness.equal(snap.window(.fiveHour)?.resetsAt, Date(timeIntervalSince1970: 1_791_947_999),
                      "microsecond fraction and +00:00 offset parse, to the second")
        Harness.equal(snap.window(.sevenDay)?.usedPercent, 29, "7d parsed")
        Harness.equal(snap.window(.sevenDay)?.observedAt, at, "observed now")
    }

    static func skipsAWindowThatIsNotRunning() {
        let json = #"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":12,"resets_at":"2026-10-19T13:59:59Z"}}"#
        let snap = try? OAuthUsageParser.parse(Data(json.utf8), observedAt: Date())
        Harness.check(snap?.window(.fiveHour) == nil, "no reset time → no window")
        Harness.equal(snap?.window(.sevenDay)?.usedPercent, 12, "the other window stays")
    }

    static func returnsNilWithoutWindows() {
        let json = #"{"five_hour":null,"seven_day":null}"#
        Harness.check((try? OAuthUsageParser.parse(Data(json.utf8), observedAt: Date())) as UsageSnapshot?? == .some(nil),
                      "no windows → nil, not an error")
    }

    static func rejectsNonObject() {
        var threw = false
        do { _ = try OAuthUsageParser.parse(Data("[]".utf8), observedAt: Date()) } catch { threw = true }
        Harness.check(threw, "non-object JSON throws")
    }

    /// A server reading is the truth: a large drop inside one window instance is a credit.
    static func mergesAsAFreshReading() {
        let resets = Date(timeIntervalSince1970: 100_000)
        let held = UsageSnapshot(source: .statusline, observedAt: Date(timeIntervalSince1970: 1000), windows: [
            UsageWindow(kind: .sevenDay, usedPercent: 60, resetsAt: resets, observedAt: Date(timeIntervalSince1970: 1000)),
        ])
        let reading = UsageSnapshot(source: .oauth, observedAt: Date(timeIntervalSince1970: 1060), windows: [
            UsageWindow(kind: .sevenDay, usedPercent: 0, resetsAt: resets, observedAt: Date(timeIntervalSince1970: 1060)),
        ])
        var tracker = SessionTracker()
        Harness.equal(tracker.provenance(of: reading), .fresh, "an OAuth reading is fresh")
        let merged = held.merging(reading)
        Harness.equal(merged.window(.sevenDay)?.usedPercent, 0, "taken by default provenance")
        Harness.equal(merged.window(.sevenDay)?.creditAt, Date(timeIntervalSince1970: 1060), "and recorded as a credit")
    }
}

enum RefreshPolicyChecks {
    static func run() {
        let now = Date(timeIntervalSince1970: 100_000)
        func delay(menuAgo: TimeInterval?, constrained: Bool = false) -> TimeInterval {
            RefreshPolicy.delay(now: now, lastMenuOpenAt: menuAgo.map { now.addingTimeInterval(-$0) }, constrained: constrained)
        }
        Harness.equal(delay(menuAgo: 60), 120, "menu just opened → 2 min")
        Harness.equal(delay(menuAgo: 300), 120, "five minutes is still recent")
        Harness.equal(delay(menuAgo: 1800), 300, "within the hour → 5 min")
        Harness.equal(delay(menuAgo: 2 * 3600), 900, "1–4 h → 15 min")
        Harness.equal(delay(menuAgo: 5 * 3600), 1800, "older → 30 min")
        Harness.equal(delay(menuAgo: nil), 1800, "never opened → 30 min")
        Harness.equal(delay(menuAgo: 60, constrained: true), 1800, "Low Power Mode wins over a recent open")
        Harness.equal(delay(menuAgo: -60), 120, "a clock set back counts as recent")
    }
}
