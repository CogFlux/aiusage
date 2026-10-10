import AIUsageCore
import Foundation

enum CodexChecks {
    // Verbatim from a real `codex app-server` (0.160.0) exchange; ids shortened.
    static let readResponse = """
    {"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,"normalModelSlug":null,"primary":{"usedPercent":6,"windowDurationMins":300,"resetsAt":1791208730},"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1791699338},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"plus","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"normalModelSlug":null,"primary":{"usedPercent":6,"windowDurationMins":300,"resetsAt":1791208730},"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1791699338},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"plus","rateLimitReachedType":null}},"rateLimitResetCredits":{"availableCount":0,"credits":null},"accountId":"7d9e","rateLimitUpsell":null}}
    """

    static func run() {
        parsesBothWindows()
        skipsNotificationsAndOtherResponses()
        surfacesAnErrorResponse()
        recognizesNetworkFailures()
        fallsBackToTheSingleBucketView()
        skipsWindowsOfUnknownLength()
        resetLandsInTheFollowingMinute()
        alertsKnowTheirProvider()
        layoutKeepsEveryProviderOnce()
        layoutFiltersAndFallsBack()
        layoutMovesWithinBounds()
        layoutSurvivesUnknownProviders()
    }

    private static let at = Date(timeIntervalSince1970: 1_791_200_000)

    static func parsesBothWindows() {
        let usage = try? CodexParser.parse(line: readResponse, requestID: 2, observedAt: at)
        Harness.equal(usage?.windows.count, 2, "two windows")
        Harness.equal(usage?.window(.fiveHour)?.usedPercent, 6, "primary is the 5-hour window")
        // 1_791_208_730 is hh:mm:50: rounded up to the minute, then one minute of grace.
        Harness.equal(usage?.window(.fiveHour)?.resetsAt, Date(timeIntervalSince1970: 1_791_208_800), "primary reset")
        Harness.equal(usage?.window(.sevenDay)?.usedPercent, 12, "secondary is the weekly window")
        Harness.equal(usage?.planType, "plus", "plan")
        Harness.equal(usage?.limitReached, nil, "no limit reached")
        Harness.equal(usage?.observedAt, at, "observedAt")
    }

    static func skipsNotificationsAndOtherResponses() {
        let notification = #"{"method":"account/updated","params":{"authMode":"chatgpt","planType":"plus"}}"#
        let initialize = #"{"id":1,"result":{"userAgent":"aiusage/0.160.0"}}"#
        Harness.check((try? CodexParser.parse(line: notification, requestID: 2, observedAt: at)) == .some(nil), "notification ignored")
        Harness.check((try? CodexParser.parse(line: initialize, requestID: 2, observedAt: at)) == .some(nil), "other response ignored")
        Harness.check((try? CodexParser.parse(line: "not json", requestID: 2, observedAt: at)) == .some(nil), "garbage ignored")
    }

    static func surfacesAnErrorResponse() {
        let line = #"{"id":2,"error":{"code":-32600,"message":"not logged in"}}"#
        do {
            _ = try CodexParser.parse(line: line, requestID: 2, observedAt: at)
            Harness.check(false, "error response should throw")
        } catch let error as CodexParser.ResponseError {
            Harness.equal(error.message, "not logged in", "error message")
            Harness.check(!error.isNetworkFailure, "sign-in error is not a network failure")
        } catch {
            Harness.check(false, "unexpected error \(error)")
        }
    }

    static func recognizesNetworkFailures() {
        // Verbatim from a real failure while chatgpt.com TLS handshakes were stalling.
        let real = "failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)"
        Harness.check(CodexParser.ResponseError(message: real).isNetworkFailure, "send failure is a network failure")
        Harness.check(!CodexParser.ResponseError(message: "malformed rateLimits response").isNetworkFailure,
                      "malformed response is not a network failure")
    }

    static func fallsBackToTheSingleBucketView() {
        let result: [String: Any] = ["rateLimits": [
            "primary": ["usedPercent": 40, "windowDurationMins": 300, "resetsAt": 1_791_208_730],
            "secondary": NSNull(),
            "rateLimitReachedType": "rate_limit_reached",
        ]]
        let usage = CodexParser.parse(rateLimitsResult: result, observedAt: at)
        Harness.equal(usage?.windows.map(\.kind), [.fiveHour], "only the reported window")
        Harness.equal(usage?.limitReached, "rate_limit_reached", "limit reached")
        Harness.equal(usage?.planType, nil, "no plan")
    }

    static func skipsWindowsOfUnknownLength() {
        let result: [String: Any] = ["rateLimits": [
            // Reversed order and a 30-day window: matched by length, unknown lengths dropped.
            "primary": ["usedPercent": 12, "windowDurationMins": 10080, "resetsAt": 1_791_699_338],
            "secondary": ["usedPercent": 3, "windowDurationMins": 43200, "resetsAt": 1_793_000_000],
        ]]
        let usage = CodexParser.parse(rateLimitsResult: result, observedAt: at)
        Harness.equal(usage?.windows.map(\.kind), [.sevenDay], "weekly kept, 30-day dropped")
    }

    static func resetLandsInTheFollowingMinute() {
        // Three readings of one instance seen live; the limit lifted at 18:12, not 18:11.
        let reported: [Double] = [1_791_454_257, 1_791_454_260, 1_791_454_261]
        let resets = Set(reported.map { CodexParser.effectiveReset($0) })
        Harness.equal(resets, [Date(timeIntervalSince1970: 1_791_454_320)], "jitter absorbed, one minute later")
    }

    static func alertsKnowTheirProvider() {
        let pace = Pace(usedPercent: 1, elapsedFraction: 0, budgetPercent: 0, deltaPercent: 0,
                        projectedPercent: nil, runoutAt: nil, status: .onTrack)
        let codex = UsageAlert(kind: .overPace, windowID: "codex.five_hour", resetsAt: at, pace: pace)
        Harness.equal(codex.provider, "codex", "codex provider")
        Harness.equal(codex.rateLimitWindow, .fiveHour, "codex window")
        Harness.equal(codex.claudeWindow, nil, "not a Claude window")
        let claude = UsageAlert(kind: .overPace, windowID: "claude.seven_day", resetsAt: at, pace: pace)
        Harness.equal(claude.claudeWindow, .sevenDay, "Claude window")
        let deepseek = UsageAlert(kind: .overPace, windowID: "deepseek.month", resetsAt: at, pace: pace)
        Harness.equal(deepseek.rateLimitWindow, nil, "a budget is no rate-limit window")
        let window = UsageWindow(kind: .sevenDay, usedPercent: 10, resetsAt: at)
        Harness.equal(PaceWindow.rateLimit(window, provider: "codex").id, "codex.seven_day", "pace window id")
        Harness.equal(PaceWindow.claude(window), PaceWindow.rateLimit(window, provider: "claude"), "claude is a rate-limit window")
    }

    static func layoutKeepsEveryProviderOnce() {
        let layout = ProviderLayout(order: [.deepseek, .deepseek, .claude])
        Harness.equal(layout.order, [.deepseek, .claude, .codex], "deduped, missing appended")
        Harness.equal(ProviderLayout().order, Provider.allCases, "default order")
    }

    static func layoutFiltersAndFallsBack() {
        let layout = ProviderLayout(order: [.codex, .claude, .deepseek], hiddenInPanel: [.claude],
                                    inMenuBar: [.deepseek, .codex])
        Harness.equal(layout.panel(enabled: [.claude, .codex, .deepseek]), [.codex, .deepseek], "hidden one skipped")
        Harness.equal(layout.panel(enabled: [.claude]), [], "disabled ones skipped")
        Harness.equal(layout.menuBar(enabled: [.claude, .codex, .deepseek]), [.codex, .deepseek], "menu bar in order")
        Harness.equal(layout.menuBar(enabled: [.claude]), [.claude], "falls back to Claude")
    }

    static func layoutMovesWithinBounds() {
        var layout = ProviderLayout()
        layout.move(.deepseek, by: -1)
        Harness.equal(layout.order, [.claude, .deepseek, .codex], "moved up")
        layout.move(.claude, by: -1)
        Harness.equal(layout.order, [.claude, .deepseek, .codex], "top stays")
        layout.move(.claude, by: 5)
        Harness.equal(layout.order, [.deepseek, .codex, .claude], "clamped to the bottom")
    }

    static func layoutSurvivesUnknownProviders() {
        let json = #"{"order":["deepseek","cursor","claude"],"hiddenInPanel":["cursor"],"inMenuBar":["deepseek"]}"#
        let layout = try? JSONDecoder().decode(ProviderLayout.self, from: Data(json.utf8))
        Harness.equal(layout?.order, [.deepseek, .claude, .codex], "unknown dropped, missing appended")
        Harness.equal(layout?.inMenuBar, [.deepseek], "menu bar kept")
        let roundTrip = (try? JSONEncoder().encode(layout)).flatMap { try? JSONDecoder().decode(ProviderLayout.self, from: $0) }
        Harness.equal(roundTrip, layout, "round trip")
    }
}
