import Foundation

/// Parses the JSON Claude Code passes to a status line command on stdin.
/// Reads `rate_limits`, plus `session_id` and `cost` to tell a live reading from a re-emit.
/// See https://code.claude.com/docs/en/statusline
public enum StatuslineParser {
    public struct InvalidJSON: Error {}

    /// Returns nil when the payload carries no usable `rate_limits`
    /// (API-key users, first message of a session, or all windows dropped after reset).
    public static func parse(_ data: Data, observedAt: Date) throws -> UsageSnapshot? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InvalidJSON()
        }
        guard let rateLimits = root["rate_limits"] as? [String: Any] else { return nil }

        var windows: [UsageWindow] = []
        for kind in WindowKind.allCases {
            guard let w = rateLimits[kind.rawValue] as? [String: Any],
                  let used = JSONNumber.double(w["used_percentage"]),
                  let resets = JSONNumber.double(w["resets_at"]) else { continue }
            windows.append(UsageWindow(kind: kind, usedPercent: used,
                                       resetsAt: Date(timeIntervalSince1970: resets), observedAt: observedAt))
        }
        guard !windows.isEmpty else { return nil }
        let cost = root["cost"] as? [String: Any]
        let session = (root["session_id"] as? String).flatMap { id in
            JSONNumber.double(cost?["total_api_duration_ms"]).map {
                SessionStamp(id: id, apiDurationMs: $0, durationMs: JSONNumber.double(cost?["total_duration_ms"]))
            }
        }
        return UsageSnapshot(source: .statusline, observedAt: observedAt, windows: windows, session: session)
    }
}

enum JSONNumber {
    static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
