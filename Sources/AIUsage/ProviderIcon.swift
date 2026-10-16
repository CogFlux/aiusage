import AIUsageCore
import AppKit

/// Each provider's logo, from CodexBar (see Resources/ProviderIcons/NOTICE). Template images, so
/// they take the text colour in light and dark mode.
@MainActor
enum ProviderIcon {
    private static var cache: [Provider: NSImage] = [:]

    static func image(_ provider: Provider) -> NSImage? {
        if let cached = cache[provider] { return cached }
        guard let url = Bundle.module.url(forResource: "ProviderIcon-\(provider.rawValue)", withExtension: "svg",
                                          subdirectory: "ProviderIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[provider] = image
        return image
    }

    /// A copy fitted inside a `side`-point square, keeping the logo's proportions, for AppKit
    /// places that draw an image at its own size (the Settings toolbar).
    static func image(_ provider: Provider, fittingSquare side: CGFloat) -> NSImage? {
        guard let source = image(provider), let copy = source.copy() as? NSImage else { return nil }
        let scale = side / max(source.size.width, source.size.height)
        copy.size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        copy.isTemplate = true
        return copy
    }
}

extension Provider {
    /// Product names, the same in every language.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .deepseek: return "DeepSeek"
        case .opencodego: return "OpenCode Go"
        }
    }
}
