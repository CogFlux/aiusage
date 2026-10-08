import Foundation

public enum Provider: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex
    case deepseek
}

/// Which providers the popover and the menu bar show, and in what order. One order serves both,
/// so the menu bar reads left to right the way the popover reads top to bottom.
public struct ProviderLayout: Codable, Equatable, Sendable {
    public var order: [Provider]
    /// Opt-out, so a provider the user turns on later shows up without a second step.
    public var hiddenInPanel: Set<Provider>
    /// Opt-in: every extra item widens the menu bar.
    public var inMenuBar: Set<Provider>

    public init(order: [Provider] = Provider.allCases, hiddenInPanel: Set<Provider> = [],
                inMenuBar: Set<Provider> = [.claude]) {
        self.order = order
        self.hiddenInPanel = hiddenInPanel
        self.inMenuBar = inMenuBar
        normalize()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decoded value by value, dropping names this version does not know, so a layout saved by
        // a newer version (with a provider added) does not reset the whole thing.
        func providers(_ key: CodingKeys) throws -> [Provider] {
            (try c.decodeIfPresent([String].self, forKey: key) ?? []).compactMap(Provider.init(rawValue:))
        }
        self.init(order: try providers(.order), hiddenInPanel: Set(try providers(.hiddenInPanel)),
                  inMenuBar: Set(try providers(.inMenuBar)))
    }

    /// Every provider exactly once: duplicates dropped, missing ones (added by a newer version
    /// than the one that saved the layout) appended in their default position.
    private mutating func normalize() {
        var seen = Set<Provider>()
        order = order.filter { seen.insert($0).inserted }
        order += Provider.allCases.filter { !seen.contains($0) }
    }

    /// Popover blocks, top to bottom.
    public func panel(enabled: Set<Provider>) -> [Provider] {
        order.filter { enabled.contains($0) && !hiddenInPanel.contains($0) }
    }

    /// Menu bar items, left to right. Never empty: an empty menu bar item cannot be clicked, so
    /// with nothing usable selected it falls back to Claude, which needs no setup to show.
    public func menuBar(enabled: Set<Provider>) -> [Provider] {
        let chosen = order.filter { enabled.contains($0) && inMenuBar.contains($0) }
        return chosen.isEmpty ? [.claude] : chosen
    }

    /// Moves `provider` up (negative) or down (positive) in the order, clamped at the ends.
    public mutating func move(_ provider: Provider, by offset: Int) {
        guard let from = order.firstIndex(of: provider) else { return }
        let to = max(0, min(order.count - 1, from + offset))
        guard to != from else { return }
        order.remove(at: from)
        order.insert(provider, at: to)
    }

    /// Joins per-provider menu bar titles.
    public static func joinMenuBar(_ parts: [String]) -> String {
        parts.joined(separator: " · ")
    }
}
