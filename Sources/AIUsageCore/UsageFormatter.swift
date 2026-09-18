import Foundation

/// Text rendering shared by the menu bar title and the dropdown. Kept in Core so it is testable
/// and so a port can reproduce the exact same strings.
public enum UsageFormatter {
    /// Title for the menu bar, e.g. "5h 42% ▲9", "5h 42% ▼3", "5h 42% ●", "5h 0% ↺", "5h —".
    /// `compact` reduces it to the bare percentage ("42%", "—") for crowded menu bars.
    public static func menuBarTitle(kind: WindowKind, pace: Pace?, stale: Bool, compact: Bool = false) -> String {
        if compact {
            guard let pace else { return "—" }
            return percent(pace.usedPercent)
        }
        var s = kind.shortLabel + " "
        guard let pace else { return s + "—" }
        switch pace.status {
        case .reset:
            s += "0% ↺"
        case .tooEarly:
            s += percent(pace.usedPercent)
        case .overPace:
            s += percent(pace.usedPercent) + " ▲" + magnitude(pace.deltaPercent)
        case .underPace:
            s += percent(pace.usedPercent) + " ▼" + magnitude(pace.deltaPercent)
        case .onTrack:
            s += percent(pace.usedPercent) + " ●"
        }
        if stale { s += " ⧗" }
        return s
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "+9" / "-3" / "0"
    public static func signed(_ value: Double) -> String {
        let r = Int(value.rounded())
        return r > 0 ? "+\(r)" : "\(r)"
    }

    static func magnitude(_ value: Double) -> String {
        "\(Int(abs(value).rounded()))"
    }

    /// "45s", "2h13m", "3d 4h", or "0s" when the date has passed.
    public static func countdown(to date: Date, from now: Date) -> String {
        let total = Int(date.timeIntervalSince(now).rounded())
        if total <= 0 { return "0s" }
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

}
