import AIUsageCore
import Foundation

enum OpenAIAPICreditsChecks {
    static func run() {
        let iso = ISO8601DateFormatter()
        let february = iso.date(from: "2027-02-15T12:00:00Z")!
        let start = iso.date(from: "2027-01-31T16:30:00Z")!
        let end = iso.date(from: "2027-02-28T16:30:00Z")!
        let subscription = CodexSubscription(plan: "pro_200", activeStart: start, activeUntil: end)
        let detected = OpenAIAPICredits.subscriptionCycle(containing: february, subscription: subscription)
        Harness.equal(detected, DateInterval(start: start, end: end), "Pro billing timestamps take precedence over an estimated day")
        let nextEnd = iso.date(from: "2027-03-31T16:30:00Z")!
        Harness.equal(OpenAIAPICredits.subscriptionCycle(containing: end, subscription: subscription),
                      DateInterval(start: end, end: nextEnd), "stale February claims preserve the 31st for one cycle")
        Harness.equal(OpenAIAPICredits.subscriptionCycle(containing: nextEnd, subscription: subscription), nil,
                      "stale claims are not projected beyond one extra cycle")
        let fresh = CodexSubscription(plan: "pro_200", activeStart: end, activeUntil: nextEnd)
        Harness.equal(OpenAIAPICredits.subscriptionCycle(containing: nextEnd.addingTimeInterval(-1), subscription: fresh),
                      DateInterval(start: end, end: nextEnd), "updated claims supply the next actual cycle")
        let endOnly = CodexSubscription(plan: "pro", activeStart: nil, activeUntil: end)
        let estimated = OpenAIAPICredits.subscriptionCycle(containing: february, subscription: endOnly)
        Harness.equal(estimated?.start, iso.date(from: "2027-01-28T16:30:00Z"), "missing start uses one month before renewal")
        Harness.equal(estimated?.end, end, "estimating the start keeps the exact renewal timestamp")
        let plus = CodexSubscription(plan: "plus", activeStart: start, activeUntil: end)
        Harness.equal(OpenAIAPICredits.subscriptionCycle(containing: february, subscription: plus), nil,
                      "Plus renewal is not used as the API grant cycle")

        let cycle = DateInterval(start: start, end: end)
        let midpoint = start.addingTimeInterval(cycle.duration / 2)
        let window = UsageWindow(kind: .month, usedPercent: 70, resetsAt: end, observedAt: midpoint)
        let pace = OpenAIAPICredits.pace(for: window, cycle: cycle, now: midpoint, checkpoint: nil)
        Harness.close(pace.budgetPercent, 49.5, "API baseline uses the actual subscription start")

        var checkpoints = CheckpointBook()
        checkpoints.repace(window, now: midpoint)
        let checkpoint = checkpoints.checkpoint(for: window)
        let later = midpoint.addingTimeInterval(cycle.duration / 4)
        let repaced = OpenAIAPICredits.pace(for: window, cycle: cycle, now: later, checkpoint: checkpoint)
        Harness.close(repaced.budgetPercent, 84.5, "API re-pace spreads the remaining allowance to renewal")
        checkpoints.clear(.month)
        Harness.equal(checkpoints.checkpoint(for: window), nil, "clearing API re-pace restores the baseline")

        let page = decode("""
            {"data":[{"results":[{"amount":{"value":0.13,"currency":"usd"}},
                                 {"amount":{"value":-0.03,"currency":"USD"}}]},
                     {"results":[{"amount":{"value":0.20,"currency":"usd"}}]}],
             "has_more":true,"next_page":"next"}
            """)
        Harness.equal(page?.spend, Decimal(string: "0.30"), "costs include all buckets and adjustments")
        Harness.equal(page?.nextPage, "next", "costs continuation cursor is decoded")
        Harness.equal(decode("""
            {"data":[],"has_more":false,"next_page":null}
            """)?.spend, 0, "empty costs page has zero spend")
        Harness.check(decode("""
            {"data":[],"has_more":true,"next_page":null}
            """) == nil, "missing continuation cannot silently undercount spend")
        Harness.check(decode("""
            {"data":[{"results":[{"amount":{"value":4,"currency":"eur"}}]}],"has_more":false}
            """) == nil, "non-USD costs cannot be used for a USD estimate")
    }

    private static func decode(_ json: String) -> OpenAIAPICredits.CostsPage? {
        try? JSONDecoder().decode(OpenAIAPICredits.CostsPage.self, from: Data(json.utf8))
    }
}
