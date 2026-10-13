import Foundation

/// One plan-usage reading the Claude desktop app recorded for itself.
public struct DesktopUsageSample: Equatable, Sendable {
    public var observedAt: Date
    /// 0...100, whole numbers in practice. A window may be missing.
    public var usedPercent: [WindowKind: Double]

    public init(observedAt: Date, usedPercent: [WindowKind: Double]) {
        self.observedAt = observedAt
        self.usedPercent = usedPercent
    }
}

/// Parses `plan-usage-history.json`, which the Claude desktop app keeps in its Application Support
/// folder. Undocumented; read only as a fallback for usage spent in desktop sessions, which never run
/// the statusline hook. Any format other than the one seen here is treated as no data.
///
/// ```json
/// {"version":2,"samples":[{"t":1789342242507,"org":"<uuid>","u":{"fh":10,"sd":20}}]}
/// ```
public enum DesktopHistoryParser {
    public static let supportedVersion = 2

    private static let keys: [WindowKind: String] = [.fiveHour: "fh", .sevenDay: "sd"]

    /// The newest sample of `org` that carries at least one window. The file holds samples of every
    /// organization the desktop app has been signed in to.
    public static func latest(_ data: Data, org: String) -> DesktopUsageSample? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              JSONNumber.double(root["version"]) == Double(supportedVersion),
              let samples = root["samples"] as? [[String: Any]] else { return nil }
        var best: DesktopUsageSample?
        for sample in samples {
            guard sample["org"] as? String == org,
                  let ms = JSONNumber.double(sample["t"]),
                  let u = sample["u"] as? [String: Any] else { continue }
            var used: [WindowKind: Double] = [:]
            for (kind, key) in keys {
                if let value = JSONNumber.double(u[key]) { used[kind] = value }
            }
            let at = Date(timeIntervalSince1970: ms / 1000)
            guard !used.isEmpty, at > (best?.observedAt ?? .distantPast) else { continue }
            best = DesktopUsageSample(observedAt: at, usedPercent: used)
        }
        return best
    }
}

extension UsageSnapshot {
    /// Folds in a desktop app reading. It is a live server value, but carries no reset time, so it
    /// can only update a window instance already held: one that was running when the sample was
    /// taken, and last observed before it. Returns nil when it updates nothing.
    public func applying(_ sample: DesktopUsageSample, policy: MergePolicy = MergePolicy()) -> UsageSnapshot? {
        let windows: [UsageWindow] = WindowKind.allCases.compactMap { kind in
            guard let used = sample.usedPercent[kind], let held = window(kind),
                  sample.observedAt > held.observedAt,
                  sample.observedAt > held.startsAt, sample.observedAt < held.resetsAt else { return nil }
            return UsageWindow(kind: kind, usedPercent: used, resetsAt: held.resetsAt, observedAt: sample.observedAt)
        }
        guard !windows.isEmpty else { return nil }
        // Idle sessions keep moving the snapshot's own time forward with re-emits, so the sample is
        // often older than it; the per-window checks above are what order the readings.
        let incoming = UsageSnapshot(source: .desktop, observedAt: max(observedAt, sample.observedAt), windows: windows)
        return merging(incoming, provenance: .fresh, policy: policy)
    }
}
