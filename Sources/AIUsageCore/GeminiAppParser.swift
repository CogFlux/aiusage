import Foundation

/// Gemini web/app (`gemini.google.com/usage`) 5-hour and weekly subscription quotas, separate from
/// Antigravity's developer quotas.
public struct GeminiAppUsage: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var planLabel: String?
    /// `GXU_FIVE_HOURLY` (`.fiveHour`) and `GXU_WEEKLY` (`.sevenDay`).
    public var windows: [UsageWindow]

    public init(observedAt: Date, planLabel: String? = nil, windows: [UsageWindow]) {
        self.observedAt = observedAt
        self.planLabel = planLabel
        self.windows = windows
    }

    public func window(_ kind: WindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }

    public var limitReached: Bool {
        windows.contains { $0.usedPercent >= 100 }
    }
}

/// Parses the response of `gemini.google.com`'s persisted `UsagePageQuery` GraphQL endpoint
/// (same query CodexBar's `gemini-web` plugin sends).
///
/// The response is prefixed with Google's XSSI guard `)]}'` followed by a JSON array containing
/// `{ "data": { "viewer": { "rpcs": { "getUsageInfo": { "subscriptionTier": "TIER1", "pools": [...] } } } } }`.
public enum GeminiAppParser {
    public enum ParseError: Error, Equatable {
        case unauthorized
        case malformed
        case noWindows
    }

    private static let poolKinds: [(poolType: String, kind: WindowKind)] = [
        ("GXU_FIVE_HOURLY", .fiveHour),
        ("GXU_WEEKLY", .sevenDay),
    ]

    public static func parse(_ data: Data, observedAt: Date) throws -> GeminiAppUsage {
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("<") {
            throw ParseError.unauthorized
        }
        let stripped = stripXSSIPrefix(raw)
        guard let cleanData = stripped.data(using: .utf8),
              let results = try? JSONSerialization.jsonObject(with: cleanData) as? [[String: Any]]
        else {
            throw ParseError.malformed
        }

        let dataObjects = results.compactMap { $0["data"] as? [String: Any] }
        guard let withViewer = dataObjects.first(where: { $0.keys.contains("viewer") }) else {
            throw ParseError.malformed
        }
        if withViewer["viewer"] is NSNull {
            throw ParseError.unauthorized
        }
        guard let viewer = withViewer["viewer"] as? [String: Any],
              let rpcs = viewer["rpcs"] as? [String: Any],
              let usageInfo = rpcs["getUsageInfo"] as? [String: Any],
              let pools = usageInfo["pools"] as? [[String: Any]]
        else {
            throw ParseError.malformed
        }

        var windows: [UsageWindow] = []
        for (poolType, kind) in poolKinds {
            guard let pool = pools.first(where: { ($0["poolType"] as? String) == poolType }),
                  let fraction = JSONNumber.double(pool["percentageUsed"]),
                  fraction.isFinite, fraction >= 0
            else { continue }

            let rawReset = (pool["gxu"] as? [String: Any])?["windowRefreshesAt"] as? String
            guard let resetDate = rawReset.flatMap(OAuthUsageParser.parseTimestamp) else { continue }
            let usedPercent = max(0, min(100, fraction * 100))
            windows.append(UsageWindow(kind: kind, usedPercent: usedPercent,
                                       resetsAt: resetDate, observedAt: observedAt))
        }

        guard !windows.isEmpty else { throw ParseError.noWindows }

        let planLabel: String?
        switch usageInfo["subscriptionTier"] as? String {
        case "TIER1": planLabel = "Pro"
        case "TIER2": planLabel = "Ultra"
        default: planLabel = nil
        }

        return GeminiAppUsage(observedAt: observedAt, planLabel: planLabel, windows: windows)
    }

    private static func stripXSSIPrefix(_ text: String) -> String {
        guard text.hasPrefix(")]}'") else { return text }
        return String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
