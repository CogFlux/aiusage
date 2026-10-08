import Foundation

/// Codex (ChatGPT plans) quota as reported by `codex app-server`'s `account/rateLimits/read`.
/// The windows are the same shape as Claude's — a used percentage and a reset time — so they
/// reuse `UsageWindow` and the whole pace machinery.
public struct CodexUsage: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var windows: [UsageWindow]
    /// "plus", "pro", "team", … as the backend names it; nil when not reported.
    public var planType: String?
    /// Set while the backend says a limit is hit (e.g. "rate_limit_reached").
    public var limitReached: String?

    public init(observedAt: Date, windows: [UsageWindow], planType: String? = nil, limitReached: String? = nil) {
        self.observedAt = observedAt
        self.windows = windows
        self.planType = planType
        self.limitReached = limitReached
    }

    public func window(_ kind: WindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }
}

/// Parses the `result` of an `account/rateLimits/read` JSON-RPC response.
///
/// Codex names its windows `primary` and `secondary` and gives each a duration; on current plans
/// those are 300 minutes and 10080 minutes. Windows are matched to `WindowKind` by duration, not by
/// position, and a window of any other length is skipped: the pace math derives the window start
/// from `WindowKind.duration`, so a mismatched length would put the budget line in the wrong place.
public enum CodexParser {
    public static func parse(rateLimitsResult result: [String: Any], observedAt: Date) -> CodexUsage? {
        // `rateLimitsByLimitId.codex` is the multi-bucket view; `rateLimits` mirrors the
        // historical single-bucket payload and is the fallback.
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        guard let snapshot = (byID?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]) else {
            return nil
        }
        var windows: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = snapshot[key] as? [String: Any],
                  let used = JSONNumber.double(w["usedPercent"]),
                  let resets = JSONNumber.double(w["resetsAt"]),
                  let minutes = JSONNumber.double(w["windowDurationMins"]),
                  let kind = kind(forMinutes: minutes),
                  !windows.contains(where: { $0.kind == kind }) else { continue }
            windows.append(UsageWindow(kind: kind, usedPercent: used,
                                       resetsAt: effectiveReset(resets), observedAt: observedAt))
        }
        windows.sort { $0.kind.duration < $1.kind.duration }
        return CodexUsage(observedAt: observedAt, windows: windows,
                          planType: snapshot["planType"] as? String,
                          limitReached: snapshot["rateLimitReachedType"] as? String)
    }

    /// Parses one stdout line of the app-server. Returns the usage for a successful response to
    /// `requestID`, throws `ResponseError` for an error response to it, and returns nil for any
    /// other line (notifications, responses to other requests).
    public static func parse(line: String, requestID: Int, observedAt: Date) throws -> CodexUsage? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              JSONNumber.double(obj["id"]).map({ Int($0) }) == requestID else { return nil }
        if let error = obj["error"] as? [String: Any] {
            throw ResponseError(message: error["message"] as? String ?? "unknown error")
        }
        guard let result = obj["result"] as? [String: Any],
              let usage = parse(rateLimitsResult: result, observedAt: observedAt) else {
            throw ResponseError(message: "malformed rateLimits response")
        }
        return usage
    }

    public struct ResponseError: Error, Equatable {
        public var message: String
    }

    /// The backend's `resetsAt` is not when the quota comes back. Readings of one window instance
    /// disagree by a few seconds (18:10:57, 18:11:00, 18:11:01), and the limit was observed to lift
    /// only in the following minute (first accepted request at 18:12:07). So the reported time is
    /// rounded to the nearest minute, which absorbs the jitter and keeps one instance on one
    /// `resetsAt`, and moved one minute later — the reset happens at 18:12, not 18:11.
    public static func effectiveReset(_ reported: Double) -> Date {
        Date(timeIntervalSince1970: (reported / 60).rounded() * 60 + 60)
    }

    static func kind(forMinutes minutes: Double) -> WindowKind? {
        WindowKind.allCases.first { abs($0.duration / 60 - minutes) < 1 }
    }
}
