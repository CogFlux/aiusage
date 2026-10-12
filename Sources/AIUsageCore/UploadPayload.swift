import Foundation

/// The body of `POST /api/ingest` on a usage-mcp server (docs/data-contract.md §6): readings of the
/// Claude and Codex rate-limit windows and the DeepSeek balance, in that server's metric shape.
public enum UploadPayload {
    public struct Metric: Codable, Equatable, Sendable {
        public var key: String
        public var label: String
        public var kind: String
        public var sense: String
        public var value: Double?
        public var unit: String
        public var windowId: String?
        public var resetsAt: Date?
        /// Per window: a merged snapshot can hold windows observed at different times.
        public var observedAt: Date?
        public var extra: [String: String]?
    }

    public struct Reading: Codable, Equatable, Sendable {
        /// Stable for one observation, so a retry after a lost response is recognised as a duplicate.
        public var id: String
        public var account: String
        public var observedAt: Date
        public var metrics: [Metric]
    }

    public struct Body: Codable, Equatable, Sendable {
        public var schema = 1
        public var sentAt: Date
        public var readings: [Reading]

        public init(sentAt: Date, readings: [Reading]) {
            self.sentAt = sentAt
            self.readings = readings
        }
    }

    /// `account:<observedAt in ms>`.
    public static func readingID(account: String, observedAt: Date) -> String {
        "\(account):\(Int64((observedAt.timeIntervalSince1970 * 1000).rounded()))"
    }

    /// One metric per window, "5h_used" / "7d_used", identified by its reset time.
    public static func rateLimits(account: String, windows: [UsageWindow], observedAt: Date,
                                  plan: String? = nil) -> Reading? {
        guard !windows.isEmpty else { return nil }
        let metrics = windows.sorted { $0.kind.duration < $1.kind.duration }.map { w -> Metric in
            var extra: [String: String] = [:]
            if let credit = w.creditAt { extra["creditAt"] = iso(credit) }
            if let plan { extra["plan"] = plan }
            return Metric(key: "\(w.kind.shortLabel)_used", label: w.kind.shortLabel, kind: "percent", sense: "used",
                          value: (w.usedPercent * 10).rounded() / 10, unit: "%", windowId: iso(w.resetsAt),
                          resetsAt: w.resetsAt, observedAt: min(w.observedAt, observedAt),
                          extra: extra.isEmpty ? nil : extra)
        }
        return Reading(id: readingID(account: account, observedAt: observedAt), account: account,
                       observedAt: observedAt, metrics: metrics)
    }

    /// Money goes over the wire in minor units (fen / cents).
    public static func balance(account: String, total: Double, currency: String, observedAt: Date) -> Reading {
        let minor = (total * 100).rounded()
        return Reading(id: readingID(account: account, observedAt: observedAt), account: account, observedAt: observedAt,
                       metrics: [Metric(key: "balance", label: "Balance", kind: "money", sense: "remaining",
                                        value: minor, unit: currency.uppercased())])
    }

    /// Same values (ignoring observation times) as the reading last sent for this account.
    public static func sameValues(_ a: Reading, _ b: Reading) -> Bool {
        a.account == b.account && a.metrics.map { [$0.key, $0.value.map { "\($0)" } ?? "nil", $0.windowId ?? ""] }
            == b.metrics.map { [$0.key, $0.value.map { "\($0)" } ?? "nil", $0.windowId ?? ""] }
    }

    public static func encode(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(iso(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
