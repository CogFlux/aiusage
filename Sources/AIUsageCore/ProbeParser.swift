import Foundation

/// Parses `claude -p --output-format stream-json --verbose` output and extracts
/// the `rate_limit_event` line. Utilization there is a 0...1 fraction.
public enum ProbeParser {
    public static func parse(streamJSON text: String, observedAt: Date) -> UsageSnapshot? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard rawLine.contains("rate_limit_event"),
                  let data = String(rawLine).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "rate_limit_event",
                  let info = obj["rate_limit_info"] as? [String: Any],
                  let unified = info["unifiedWindows"] as? [String: Any] else { continue }

            var windows: [UsageWindow] = []
            for kind in WindowKind.allCases {
                guard let w = unified[kind.rawValue] as? [String: Any],
                      let utilization = JSONNumber.double(w["utilization"]),
                      let resets = JSONNumber.double(w["resetsAt"]) else { continue }
                windows.append(UsageWindow(kind: kind, usedPercent: utilization * 100,
                                           resetsAt: Date(timeIntervalSince1970: resets)))
            }
            if !windows.isEmpty {
                return UsageSnapshot(source: .probe, observedAt: observedAt, windows: windows)
            }
        }
        return nil
    }
}
