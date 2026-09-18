import Foundation

/// The one DeepSeek endpoint we use. It is free (no tokens) and needs only the API key.
/// https://api-docs.deepseek.com/api/get-user-balance
enum DeepSeekClient {
    struct Balance: Equatable {
        var currency: String
        var total: Double
        var granted: Double
        var toppedUp: Double
        var isAvailable: Bool
    }

    enum ClientError: LocalizedError {
        case http(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .http(401): return Strings.current.deepseekUnauthorized
            case let .http(code): return "HTTP \(code)"
            case .malformed: return Strings.current.deepseekMalformed
            }
        }
    }

    static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

    static func fetchBalance(apiKey: String) async throws -> Balance {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ClientError.http(status) }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]],
              let info = infos.first(where: { ($0["currency"] as? String) == "CNY" }) ?? infos.first,
              let currency = info["currency"] as? String,
              let total = money(info["total_balance"]),
              let granted = money(info["granted_balance"]),
              let toppedUp = money(info["topped_up_balance"]) else { throw ClientError.malformed }
        return Balance(currency: currency, total: total, granted: granted, toppedUp: toppedUp,
                       isAvailable: (root["is_available"] as? Bool) ?? true)
    }

    /// Amounts arrive as strings ("110.00"); tolerate numbers too.
    private static func money(_ value: Any?) -> Double? {
        if let s = value as? String { return Double(s) }
        return (value as? NSNumber)?.doubleValue
    }
}
