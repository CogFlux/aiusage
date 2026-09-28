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
        mergeIgnoresAPreviousWindowInstance()
        mergeTakesAFreshCredit()
        mergeIgnoresAStaleDropHoweverLarge()
        mergeHoldsASmallFreshDip()
        mergeLetsTheProbeOverrideAHeldValue()
        mergeIgnoresPreCreditEchoes()
        mergeKeepsOneResetTimePerInstance()
        statuslineParsesTheSessionStamp()
        trackerTellsLiveReadingsFromReEmits()
        trackerNeverTrustsAFirstSighting()
        trackerSeparatesTwoProcessesOfOneSession()
        trackerForgetsOldSessions()
    }

    private static func snap(_ source: SnapshotSource, at t: TimeInterval, fiveHour: (Double, TimeInterval)?, sevenDay: (Double, TimeInterval)?) -> UsageSnapshot {
        let at = Date(timeIntervalSince1970: t)
        var windows: [UsageWindow] = []
        if let (u, r) = fiveHour {
            windows.append(UsageWindow(kind: .fiveHour, usedPercent: u, resetsAt: Date(timeIntervalSince1970: r), observedAt: at))
        }
        if let (u, r) = sevenDay {
            windows.append(UsageWindow(kind: .sevenDay, usedPercent: u, resetsAt: Date(timeIntervalSince1970: r), observedAt: at))
        }
        return UsageSnapshot(source: source, observedAt: at, windows: windows)
    }

    static func mergeIgnoresAPreviousWindowInstance() {
        // A session still holding the previous 5-hour instance must not replace the current one.
        let current = snap(.statusline, at: 1000, fiveHour: (5, 38000), sevenDay: nil)
        let previous = snap(.statusline, at: 1060, fiveHour: (90, 20000), sevenDay: nil)
        Harness.equal(current.merging(previous).window(.fiveHour)?.usedPercent, 5, "an earlier resetsAt is ignored")
    }

    /// A quota reset credit lowers usage inside a live window (same `resetsAt`).
    static func mergeTakesAFreshCredit() {
        let current = snap(.statusline, at: 1000, fiveHour: nil, sevenDay: (70, 600000))
        let credited = snap(.statusline, at: 1060, fiveHour: nil, sevenDay: (0, 600000))
        let merged = current.merging(credited, provenance: .fresh)
        Harness.equal(merged.window(.sevenDay)?.usedPercent, 0, "a fresh big drop is taken at once")
        Harness.equal(merged.window(.sevenDay)?.creditAt, Date(timeIntervalSince1970: 1060), "and recorded as a credit")
    }

    /// An idle session left open overnight trails by a day's worth of 7-day usage. However big the
    /// gap, a re-emit is not evidence of a credit.
    static func mergeIgnoresAStaleDropHoweverLarge() {
        let current = snap(.statusline, at: 1000, fiveHour: nil, sevenDay: (45, 600000))
        let idle = snap(.statusline, at: 1060, fiveHour: nil, sevenDay: (30, 600000))
        let merged = current.merging(idle, provenance: .stale(lastFreshAt: Date(timeIntervalSince1970: 500)))
        Harness.equal(merged.window(.sevenDay)?.usedPercent, 45, "a stale drop is ignored")
        Harness.check(merged.window(.sevenDay)?.creditAt == nil, "and is no credit")
    }

    static func mergeHoldsASmallFreshDip() {
        // The probe reports a fraction, the statusline a rounded percentage.
        let current = snap(.statusline, at: 1000, fiveHour: nil, sevenDay: (70, 600000))
        let dip = snap(.statusline, at: 1060, fiveHour: nil, sevenDay: (68, 600000))
        Harness.equal(current.merging(dip, provenance: .fresh).window(.sevenDay)?.usedPercent, 70, "a small fresh dip is noise")
    }

    /// After a credit, a session that has not made a call since keeps re-emitting the pre-credit
    /// number. It reads as a rise, and usage must not jump back to it — for however long that
    /// session stays open.
    static func mergeIgnoresPreCreditEchoes() {
        let before = snap(.statusline, at: 1000, fiveHour: nil, sevenDay: (70, 600000))
        var held = before.merging(snap(.statusline, at: 1060, fiveHour: nil, sevenDay: (0, 600000)), provenance: .fresh)
        for t in stride(from: 1120.0, through: 90000, by: 3600) {
            held = held.merging(snap(.statusline, at: t, fiveHour: nil, sevenDay: (70, 600000)),
                                provenance: .stale(lastFreshAt: Date(timeIntervalSince1970: 900)))
            Harness.equal(held.window(.sevenDay)?.usedPercent, 0, "the echo is ignored at t=\(Int(t))")
        }
        let unknown = held.merging(snap(.statusline, at: 90100, fiveHour: nil, sevenDay: (70, 600000)),
                                   provenance: .stale(lastFreshAt: nil))
        Harness.equal(unknown.window(.sevenDay)?.usedPercent, 0, "a writer of unknown age counts as pre-credit")
        // A session that made a call after the credit and then went idle re-emits a post-credit number.
        let after = held.merging(snap(.statusline, at: 90200, fiveHour: nil, sevenDay: (4, 600000)),
                                 provenance: .stale(lastFreshAt: Date(timeIntervalSince1970: 2000)))
        Harness.equal(after.window(.sevenDay)?.usedPercent, 4, "post-credit readings still count")
        Harness.equal(after.window(.sevenDay)?.creditAt, Date(timeIntervalSince1970: 1060), "the credit is carried along")
        // A probe is a live call, so 70 there would be the truth.
        let probe = snap(.probe, at: 90300, fiveHour: nil, sevenDay: (70, 600000))
        Harness.equal(after.merging(probe).window(.sevenDay)?.usedPercent, 70, "a probe overrules everything")
    }

    static func mergeKeepsOneResetTimePerInstance() {
        let current = snap(.statusline, at: 1000, fiveHour: nil, sevenDay: (70, 600000))
        let jittered = snap(.probe, at: 1060, fiveHour: nil, sevenDay: (72, 600001))
        let merged = current.merging(jittered).window(.sevenDay)
        Harness.equal(merged?.usedPercent, 72, "a second of jitter is the same instance")
        Harness.equal(merged?.resetsAt, Date(timeIntervalSince1970: 600000), "and keeps its first resetsAt")
    }

    /// `durationMs` is taken at t = 0 and advances with `t`, as one process's wall time does.
    private static func stamped(_ id: String, apiMs: Double, durationMs: Double = 10 * 3_600_000, at t: TimeInterval) -> UsageSnapshot {
        var s = snap(.statusline, at: t, fiveHour: (30, 20000), sevenDay: nil)
        s.session = SessionStamp(id: id, apiDurationMs: apiMs, durationMs: durationMs + t * 1000)
        return s
    }

    static func statuslineParsesTheSessionStamp() {
        let json = #"{"session_id":"abc","cost":{"total_api_duration_ms":9053422,"total_duration_ms":374791088},"rate_limits":{"seven_day":{"used_percentage":3,"resets_at":100}}}"#
        let snap = try? StatuslineParser.parse(Data(json.utf8), observedAt: Date())
        Harness.equal(snap?.session, SessionStamp(id: "abc", apiDurationMs: 9053422, durationMs: 374791088), "session stamp")
        let bare = try? StatuslineParser.parse(Data(#"{"rate_limits":{"seven_day":{"used_percentage":3,"resets_at":100}}}"#.utf8), observedAt: Date())
        Harness.check(bare?.session == nil, "no session fields → no stamp")
    }

    static func trackerTellsLiveReadingsFromReEmits() {
        var tracker = SessionTracker()
        Harness.equal(tracker.provenance(of: stamped("a", apiMs: 500, at: 1000)), .stale(lastFreshAt: nil),
                      "an old session seen for the first time is of unknown age")
        Harness.equal(tracker.provenance(of: stamped("a", apiMs: 500, at: 1060)), .stale(lastFreshAt: nil), "unchanged → re-emit")
        Harness.equal(tracker.provenance(of: stamped("a", apiMs: 900, at: 1120)), .fresh, "API time grew → live")
        Harness.equal(tracker.provenance(of: stamped("a", apiMs: 900, at: 1180)), .stale(lastFreshAt: Date(timeIntervalSince1970: 1120)),
                      "a re-emit is as old as the last live reading")
        Harness.equal(tracker.provenance(of: snap(.probe, at: 1200, fiveHour: nil, sevenDay: nil)), .fresh, "a probe is live")
        Harness.equal(tracker.provenance(of: snap(.statusline, at: 1200, fiveHour: nil, sevenDay: nil)), .stale(lastFreshAt: nil),
                      "no stamp → unknown")
    }

    static func trackerNeverTrustsAFirstSighting() {
        var tracker = SessionTracker()
        Harness.equal(tracker.provenance(of: stamped("new", apiMs: 800, durationMs: 90_000, at: 1000)), .stale(lastFreshAt: nil),
                      "even a young writer may carry restored numbers")
    }

    /// Seen live: two terminals that resumed one session, alternating writes 2 s apart.
    static func trackerSeparatesTwoProcessesOfOneSession() {
        var tracker = SessionTracker()
        var results: [Provenance] = []
        for t in stride(from: 1000.0, through: 1300, by: 60) {
            results.append(tracker.provenance(of: stamped("s", apiMs: 2_848_728, durationMs: 72_689_455, at: t)))
            results.append(tracker.provenance(of: stamped("s", apiMs: 501_824, durationMs: 57_359_713, at: t + 2)))
        }
        Harness.check(!results.contains(.fresh), "alternating API totals of two processes are not growth")
        let grown = tracker.provenance(of: stamped("s", apiMs: 502_000, durationMs: 57_359_713, at: 1402))
        Harness.equal(grown, .fresh, "each process is fresh when its own total grows")
    }

    static func trackerForgetsOldSessions() {
        var tracker = SessionTracker()
        _ = tracker.provenance(of: stamped("old", apiMs: 1, at: 0))
        _ = tracker.provenance(of: stamped("b", apiMs: 1, at: 9 * 86400))
        Harness.equal(tracker.entries.map(\.sessionID), ["b"], "writers silent for over 8 days are dropped")
    }

    static func mergeLetsTheProbeOverrideAHeldValue() {
        let current = snap(.statusline, at: 1000, fiveHour: nil, sevenDay: (70, 600000))
        let probe = snap(.probe, at: 1060, fiveHour: nil, sevenDay: (65, 600000))
        Harness.equal(current.merging(probe).window(.sevenDay)?.usedPercent, 65, "a probe is a live call, never stale")
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
