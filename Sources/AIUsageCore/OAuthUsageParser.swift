import Foundation

/// Parses the body of `GET https://api.anthropic.com/api/oauth/usage`, the endpoint Claude Code's own
/// `/usage` screen reads. Undocumented; the shape follows what Claude Code and CodexBar consume:
///
/// ```json
/// {"five_hour":{"utilization":25.0,"resets_at":"2026-10-14T03:19:59.686376+00:00"},
///  "seven_day":{"utilization":29.0,"resets_at":"2026-10-19T13:59:59.686397+00:00"}}
/// ```
///
/// `utilization` is already 0...100. A window with no `resets_at` (none running) is left out.
public enum OAuthUsageParser {
    public struct InvalidJSON: Error {}

    public static func parse(_ data: Data, observedAt: Date) throws -> UsageSnapshot? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InvalidJSON()
        }
        var windows: [UsageWindow] = []
        for kind in WindowKind.allCases {
            guard let w = root[kind.rawValue] as? [String: Any],
                  let used = JSONNumber.double(w["utilization"]),
                  let resets = (w["resets_at"] as? String).flatMap(parseTimestamp) else { continue }
            windows.append(UsageWindow(kind: kind, usedPercent: used, resetsAt: resets, observedAt: observedAt))
        }
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(source: .oauth, observedAt: observedAt, windows: windows)
    }

    /// ISO 8601 with an optional fraction of any length, which `ISO8601DateFormatter` does not
    /// accept beyond milliseconds. Whole seconds are plenty: one window instance spans ±120 s.
    static func parseTimestamp(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
