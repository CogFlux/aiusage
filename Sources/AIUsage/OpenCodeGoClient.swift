import AIUsageCore
import Foundation

/// The OpenCode Go usage endpoint CodexBar reads. Free (no model request) and needs only the
/// subscription's API key; undocumented, see `OpenCodeGoParser`.
enum OpenCodeGoClient {
    enum ClientError: LocalizedError {
        case unauthorized
        case http(Int)
        case malformed
        case network

        var errorDescription: String? {
            let s = Strings.current
            switch self {
            case .unauthorized: return s.opencodeGoUnauthorized
            case let .http(code): return s.opencodeGoServerError(code)
            case .malformed: return s.opencodeGoMalformed
            case .network: return s.opencodeGoNetworkError
            }
        }
    }

    static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    /// Ephemeral, so neither the key nor the response lands in a disk cache.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func fetch(apiKey: String) async throws -> OpenCodeGoUsage {
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401, 403: throw ClientError.unauthorized
        default: throw ClientError.http(status)
        }
        do {
            return try OpenCodeGoParser.parse(data, observedAt: Date())
        } catch {
            throw ClientError.malformed
        }
    }
}
