import AIUsageCore
import Foundation

enum OpenCodeGoChecks {
    // Shape returned by the endpoint; values made up.
    static let usageJSON = """
    {"usage":{
      "rolling":{"status":"ok","percent":12.5,"resetsAt":"2026-10-16T08:04:12.250Z"},
      "weekly":{"status":"ok","percent":4,"resetsAt":"2026-10-19T00:00:00.000Z"},
      "monthly":{"status":"ok","percent":1,"resetsAt":"2026-11-03T09:30:00.000Z"}
    }}
    """

    static func run() {
        parsesThreeWindows()
        acceptsResetInSeconds()
        clampsPercent()
        requiresRollingWindow()
        monthStartsOneCalendarMonthEarlier()
        monthIsPacedLikeABudget()
    }

    static func parsesThreeWindows() {
        let at = Date(timeIntervalSince1970: 1_792_000_000)
        guard let usage = try? OpenCodeGoParser.parse(Data(usageJSON.utf8), observedAt: at) else {
            Harness.check(false, "usage sample should parse"); return
        }
        Harness.equal(usage.window(.fiveHour)?.usedPercent, 12.5, "rolling → 5h, percent as is")
        Harness.equal(usage.window(.fiveHour)?.resetsAt, Date(timeIntervalSince1970: 1_792_137_852),
                      "millisecond fraction parses, to the second")
        Harness.equal(usage.window(.sevenDay)?.usedPercent, 4, "weekly → 7d")
        Harness.equal(usage.window(.month)?.usedPercent, 1, "monthly → month")
        Harness.equal(usage.window(.month)?.observedAt, at, "observed now")
        Harness.check(!usage.limitReached, "nothing used up")
    }

    static func acceptsResetInSeconds() {
        let at = Date(timeIntervalSince1970: 1_792_000_000)
        let json = #"{"usage":{"rolling":{"percent":3,"resetInSec":18100}}}"#
        let usage = try? OpenCodeGoParser.parse(Data(json.utf8), observedAt: at)
        Harness.equal(usage?.window(.fiveHour)?.resetsAt, at.addingTimeInterval(18100), "resetInSec counts from now")
        Harness.check(usage?.window(.sevenDay) == nil, "missing weekly stays absent")
    }

    static func clampsPercent() {
        let json = #"{"usage":{"rolling":{"percent":104,"resetsAt":"2026-10-16T08:04:12Z"}}}"#
        let usage = try? OpenCodeGoParser.parse(Data(json.utf8), observedAt: Date())
        Harness.equal(usage?.window(.fiveHour)?.usedPercent, 100, "clamped to 100")
        Harness.check(usage?.limitReached == true, "100% is the limit")
    }

    static func requiresRollingWindow() {
        let json = #"{"usage":{"weekly":{"percent":4,"resetsAt":"2026-10-19T00:00:00Z"}}}"#
        Harness.check((try? OpenCodeGoParser.parse(Data(json.utf8), observedAt: Date())) == nil, "no rolling → error")
        Harness.check((try? OpenCodeGoParser.parse(Data("[]".utf8), observedAt: Date())) == nil, "non-object → error")
    }

    static func monthStartsOneCalendarMonthEarlier() {
        let iso = ISO8601DateFormatter()
        let window = UsageWindow(kind: .month, usedPercent: 0, resetsAt: iso.date(from: "2026-11-03T09:30:00Z")!)
        Harness.equal(window.startsAt, iso.date(from: "2026-10-03T09:30:00Z")!, "back to the same day of the previous month")
        let march = UsageWindow(kind: .month, usedPercent: 0, resetsAt: iso.date(from: "2026-03-31T00:00:00Z")!)
        Harness.equal(march.startsAt, iso.date(from: "2026-02-28T00:00:00Z")!, "clamped to February's last day")
        let week = UsageWindow(kind: .sevenDay, usedPercent: 0, resetsAt: iso.date(from: "2026-10-19T00:00:00Z")!)
        Harness.equal(week.startsAt, iso.date(from: "2026-10-12T00:00:00Z")!, "other windows unchanged")
    }

    static func monthIsPacedLikeABudget() {
        let iso = ISO8601DateFormatter()
        let window = UsageWindow(kind: .month, usedPercent: 10, resetsAt: iso.date(from: "2026-11-03T00:00:00Z")!)
        let pace = PaceWindow.rateLimit(window, provider: "opencodego")
        Harness.equal(pace.id, "opencodego.month", "pace window id")
        Harness.equal(pace.tolerance, 3, "month tolerance")
        Harness.equal(pace.minElapsed, 12 * 3600, "month waits 12 h before projecting")
        Harness.equal(pace.runningOutLead, 2 * 86400, "month warns 2 days ahead")
        Harness.check(WindowKind.claudeKinds == [.fiveHour, .sevenDay], "Claude and Codex keep two windows")
    }
}
