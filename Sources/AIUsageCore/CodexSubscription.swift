import Foundation

/// The ChatGPT plan behind a Codex sign-in and the period it is paid for, as the ID token Codex keeps
/// in `~/.codex/auth.json` states it (claims under `https://api.openai.com/auth`). Only these claims
/// are read; the token itself is never used or sent anywhere.
///
/// The claims are as fresh as the token: Codex refreshes it now and then, so right after a renewal
/// `activeUntil` can still show the old date for a while.
public struct CodexSubscription: Codable, Equatable, Sendable {
    /// "plus", "pro", … as the claims name it.
    public var plan: String?
    public var activeStart: Date?
    public var activeUntil: Date?

    public init(plan: String?, activeStart: Date?, activeUntil: Date?) {
        self.plan = plan
        self.activeStart = activeStart
        self.activeUntil = activeUntil
    }

    /// Reads the claims from the contents of `auth.json`; nil when it holds no ChatGPT ID token.
    public static func parse(authJSON data: Data) -> CodexSubscription? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }
        return parse(idToken: idToken)
    }

    public static func parse(idToken: String) -> CodexSubscription? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        let sub = CodexSubscription(plan: auth["chatgpt_plan_type"] as? String,
                                    activeStart: date(auth["chatgpt_subscription_active_start"]),
                                    activeUntil: date(auth["chatgpt_subscription_active_until"]))
        return sub.plan == nil && sub.activeUntil == nil ? nil : sub
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }
}
