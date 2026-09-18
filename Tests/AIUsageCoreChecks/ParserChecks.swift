import AIUsageCore
import Foundation

enum ParserChecks {
    // Trimmed from the example in https://code.claude.com/docs/en/statusline
    static let statuslineJSON = """
    {
      "model": {"id": "claude-opus-5", "display_name": "Opus"},
      "context_window": {"used_percentage": 8},
      "rate_limits": {
        "five_hour": {"used_percentage": 23.5, "resets_at": 1738425600},
        "seven_day": {"used_percentage": 41.2, "resets_at": 1738857600},
        "spend_limit": {"used_percentage": 62.8, "resets_at": 1740787200}
      }
    }
    """

    // Verbatim from a real `claude -p --output-format stream-json --verbose` run (2.1.274); other lines abbreviated.
    static let streamJSON = """
    {"type":"system","subtype":"init","cwd":"/tmp","session_id":"c2036d8c","tools":[]}
    {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1789707000,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"org_level_disabled","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.09,"resetsAt":1789707000},"seven_day":{"utilization":0.16,"resetsAt":1790233200}}},"uuid":"6c320588","session_id":"c2036d8c"}
    {"type":"assistant","message":{"content":[{"type":"text","text":"OK"}]}}
    {"type":"result","total_cost_usd":0.000944}
    """

    static func run() {
        statuslineParsesBothWindowsAndIgnoresSpendLimit()
        statuslineWithoutRateLimitsReturnsNil()
        statuslineWithOnlyOneWindow()
        statuslineRejectsNonObject()
        probeParsesRateLimitEventAndScalesToPercent()
        probeWithoutEventReturnsNil()
        mergeKeepsHigherUsageWithinSameWindow()
        mergeTakesNewerWindowInstance()
        mergeIgnoresOlderObservation()
        mergeDropsExpiredWindowMissingFromIncoming()
    }

    private static func snap(_ source: SnapshotSource, at t: TimeInterval, fiveHour: (Double, TimeInterval)?, sevenDay: (Double, TimeInterval)?) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        if let (u, r) = fiveHour { windows.append(UsageWindow(kind: .fiveHour, usedPercent: u, resetsAt: Date(timeIntervalSince1970: r))) }
        if let (u, r) = sevenDay { windows.append(UsageWindow(kind: .sevenDay, usedPercent: u, resetsAt: Date(timeIntervalSince1970: r))) }
        return UsageSnapshot(source: source, observedAt: Date(timeIntervalSince1970: t), windows: windows)
    }

    static func mergeKeepsHigherUsageWithinSameWindow() {
        // Another session reported 18%; then an idle session re-emits its stale 17% with a newer mtime.
        let current = snap(.statusline, at: 1000, fiveHour: (30, 20000), sevenDay: (18, 600000))
        let stale = snap(.statusline, at: 1060, fiveHour: (30, 20000), sevenDay: (17, 600000))
        let merged = current.merging(stale)
        Harness.equal(merged.window(.sevenDay)?.usedPercent, 18, "higher usage wins within the same window")
        Harness.equal(merged.observedAt, Date(timeIntervalSince1970: 1060), "observedAt follows the newest write")
        Harness.equal(merged.source, .statusline, "source follows incoming")
    }

    static func mergeTakesNewerWindowInstance() {
        // 5h window reset: new resetsAt with a low value must replace the old high value.
        let current = snap(.statusline, at: 1000, fiveHour: (90, 20000), sevenDay: nil)
        let fresh = snap(.probe, at: 21000, fiveHour: (2, 38000), sevenDay: nil)
        Harness.equal(current.merging(fresh).window(.fiveHour)?.usedPercent, 2, "different resetsAt → incoming wins")
    }

    static func mergeIgnoresOlderObservation() {
        let current = snap(.probe, at: 2000, fiveHour: (30, 20000), sevenDay: nil)
        let old = snap(.statusline, at: 1000, fiveHour: (50, 20000), sevenDay: nil)
        Harness.equal(current.merging(old), current, "older observation is ignored entirely")
    }

    static func mergeDropsExpiredWindowMissingFromIncoming() {
        // Incoming omits 7d. Keep ours if still live; drop it if its reset has passed.
        let live = snap(.statusline, at: 1000, fiveHour: (30, 20000), sevenDay: (18, 600000))
        let incoming = snap(.probe, at: 1500, fiveHour: (31, 20000), sevenDay: nil)
        Harness.equal(live.merging(incoming).window(.sevenDay)?.usedPercent, 18, "live window survives omission")
        let expired = snap(.statusline, at: 1000, fiveHour: (30, 20000), sevenDay: (18, 1200))
        Harness.check(expired.merging(incoming).window(.sevenDay) == nil, "expired window is dropped")
    }

    static func statuslineParsesBothWindowsAndIgnoresSpendLimit() {
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        guard let snap = try? StatuslineParser.parse(Data(statuslineJSON.utf8), observedAt: observed) else {
            Harness.check(false, "statusline sample should parse"); return
        }
        Harness.equal(snap.source, .statusline, "source")
        Harness.equal(snap.observedAt, observed, "observedAt passthrough")
        Harness.equal(snap.windows.count, 2, "spend_limit is ignored")
        Harness.equal(snap.window(.fiveHour)?.usedPercent, 23.5, "5h used")
        Harness.equal(snap.window(.fiveHour)?.resetsAt, Date(timeIntervalSince1970: 1738425600), "5h resets")
        Harness.equal(snap.window(.sevenDay)?.usedPercent, 41.2, "7d used")
    }

    static func statuslineWithoutRateLimitsReturnsNil() {
        let json = #"{"model":{"id":"x"},"context_window":{"used_percentage":null}}"#
        let result = try? StatuslineParser.parse(Data(json.utf8), observedAt: Date())
        Harness.check(result == nil, "no rate_limits → nil")
    }

    static func statuslineWithOnlyOneWindow() {
        let json = #"{"rate_limits":{"seven_day":{"used_percentage":10,"resets_at":100}}}"#
        let snap = try? StatuslineParser.parse(Data(json.utf8), observedAt: Date())
        Harness.check(snap?.window(.fiveHour) == nil, "missing 5h stays absent")
        Harness.equal(snap?.window(.sevenDay)?.usedPercent, 10, "7d parsed alone")
    }

    static func statuslineRejectsNonObject() {
        var threw = false
        do { _ = try StatuslineParser.parse(Data("[1,2]".utf8), observedAt: Date()) } catch { threw = true }
        Harness.check(threw, "non-object JSON throws")
    }

    static func probeParsesRateLimitEventAndScalesToPercent() {
        guard let snap = ProbeParser.parse(streamJSON: streamJSON, observedAt: Date()) else {
            Harness.check(false, "stream sample should parse"); return
        }
        Harness.equal(snap.source, .probe, "source")
        Harness.close(snap.window(.fiveHour)?.usedPercent ?? -1, 9, "utilization 0.09 → 9%")
        Harness.equal(snap.window(.fiveHour)?.resetsAt, Date(timeIntervalSince1970: 1789707000), "5h resets")
        Harness.close(snap.window(.sevenDay)?.usedPercent ?? -1, 16, "utilization 0.16 → 16%")
    }

    static func probeWithoutEventReturnsNil() {
        Harness.check(ProbeParser.parse(streamJSON: #"{"type":"result"}"#, observedAt: Date()) == nil, "no event → nil")
    }
}
