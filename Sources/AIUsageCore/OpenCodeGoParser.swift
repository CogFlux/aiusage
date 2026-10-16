import Foundation

/// OpenCode Go's quota as read from its usage endpoint.
public struct OpenCodeGoUsage: Codable, Equatable, Sendable {
    public var observedAt: Date
    /// The rolling 5-hour, weekly and monthly windows, as `.fiveHour`, `.sevenDay` and `.month`.
    public var windows: [UsageWindow]

    public init(observedAt: Date, windows: [UsageWindow]) {
        self.observedAt = observedAt
        self.windows = windows
    }

    public func window(_ kind: WindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }

    /// Some window is used up.
    public var limitReached: Bool { windows.contains { $0.usedPercent >= 100 } }
}

/// Parses the body of `GET https://opencode.ai/zen/go/v1/usage` (Bearer API key). Undocumented; the
/// shape is what the endpoint returns and what CodexBar reads:
///
/// ```json
/// {"usage":{"rolling":{"status":"ok","percent":3,"resetsAt":"2026-10-16T08:04:12.250Z"},
///           "weekly":{"status":"ok","percent":1,"resetsAt":"2026-10-19T00:00:00.000Z"},
///           "monthly":{"status":"ok","percent":0,"resetsAt":"2026-11-03T09:30:00.000Z"}}}
/// ```
///
/// `percent` is already 0...100 (`0.5` is half a percent). CodexBar has also seen `resetInSec` in
/// place of `resetsAt`, so both are accepted. The rolling window is required; the others are optional.
public enum OpenCodeGoParser {
    public struct MissingUsage: Error {}

    private static let fields: [(key: String, kind: WindowKind)] = [
        ("rolling", .fiveHour), ("weekly", .sevenDay), ("monthly", .month),
    ]

    public static func parse(_ data: Data, observedAt: Date) throws -> OpenCodeGoUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { throw MissingUsage() }
        var windows: [UsageWindow] = []
        for (key, kind) in fields {
            guard let w = usage[key] as? [String: Any],
                  let percent = JSONNumber.double(w["percent"]),
                  let resets = resetsAt(w, observedAt: observedAt) else { continue }
            windows.append(UsageWindow(kind: kind, usedPercent: max(0, min(100, percent)),
                                       resetsAt: resets, observedAt: observedAt))
        }
        guard windows.contains(where: { $0.kind == .fiveHour }) else { throw MissingUsage() }
        return OpenCodeGoUsage(observedAt: observedAt, windows: windows)
    }

    private static func resetsAt(_ window: [String: Any], observedAt: Date) -> Date? {
        if let text = window["resetsAt"] as? String { return OAuthUsageParser.parseTimestamp(text) }
        return JSONNumber.double(window["resetInSec"]).map { observedAt.addingTimeInterval($0) }
    }
}
