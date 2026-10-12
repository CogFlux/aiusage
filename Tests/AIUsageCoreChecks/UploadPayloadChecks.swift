import AIUsageCore
import Foundation

enum UploadPayloadChecks {
    static func run() {
        windowsBecomePercentMetrics()
        idsAreStablePerObservation()
        balanceIsInMinorUnits()
        encodesTheIngestShape()
        sameValuesIgnoresTimes()
    }

    private static let at = Date(timeIntervalSince1970: 1_791_200_000)

    static func windowsBecomePercentMetrics() {
        let five = UsageWindow(kind: .fiveHour, usedPercent: 42.04, resetsAt: at.addingTimeInterval(3600), observedAt: at)
        // The 7d window was last confirmed earlier than the reading that triggers the upload.
        let seven = UsageWindow(kind: .sevenDay, usedPercent: 61, resetsAt: at.addingTimeInterval(86400),
                                observedAt: at.addingTimeInterval(-600), creditAt: at.addingTimeInterval(-7200))
        let r = UploadPayload.rateLimits(account: "claude", windows: [seven, five], observedAt: at, plan: "max")
        Harness.equal(r?.metrics.map(\.key), ["5h_used", "7d_used"], "ordered short window first")
        Harness.equal(r?.metrics.first?.value, 42, "rounded to a tenth")
        Harness.equal(r?.metrics.last?.observedAt, at.addingTimeInterval(-600), "per-window observation time kept")
        Harness.equal(r?.metrics.last?.extra?["plan"], "max", "plan carried")
        Harness.check(r?.metrics.last?.extra?["creditAt"] != nil, "credit time carried")
        Harness.check(UploadPayload.rateLimits(account: "claude", windows: [], observedAt: at) == nil, "no windows, no reading")
    }

    static func idsAreStablePerObservation() {
        Harness.equal(UploadPayload.readingID(account: "codex", observedAt: at), "codex:1791200000000", "id from account and time")
    }

    static func balanceIsInMinorUnits() {
        let r = UploadPayload.balance(account: "deepseek", total: 23.456, currency: "cny", observedAt: at)
        Harness.equal(r.metrics.first?.value, 2346, "fen")
        Harness.equal(r.metrics.first?.unit, "CNY", "upper-case currency")
    }

    static func encodesTheIngestShape() {
        let r = UploadPayload.balance(account: "deepseek", total: 1, currency: "CNY", observedAt: at)
        let data = try? UploadPayload.encode(UploadPayload.Body(sentAt: at, readings: [r]))
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        Harness.equal(json?["schema"] as? Int, 1, "schema 1")
        let reading = (json?["readings"] as? [[String: Any]])?.first
        Harness.equal(reading?["observedAt"] as? String, "2026-10-05T11:33:20.000Z", "ISO 8601 with offset")
        let metric = (reading?["metrics"] as? [[String: Any]])?.first
        Harness.check(metric?["windowId"] == nil, "absent optionals are omitted, not null")
    }

    static func sameValuesIgnoresTimes() {
        let w = UsageWindow(kind: .fiveHour, usedPercent: 10, resetsAt: at.addingTimeInterval(3600), observedAt: at)
        let a = UploadPayload.rateLimits(account: "claude", windows: [w], observedAt: at)!
        var later = w
        later.observedAt = at.addingTimeInterval(60)
        let b = UploadPayload.rateLimits(account: "claude", windows: [later], observedAt: at.addingTimeInterval(60))!
        Harness.check(UploadPayload.sameValues(a, b), "same numbers at another time")
        later.usedPercent = 11
        let c = UploadPayload.rateLimits(account: "claude", windows: [later], observedAt: at.addingTimeInterval(60))!
        Harness.check(!UploadPayload.sameValues(a, c), "changed numbers")
    }
}
