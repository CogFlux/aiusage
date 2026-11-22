import AIUsageCore
import Foundation

/// Calls `gemini.google.com`'s persisted `UsagePageQuery` GraphQL endpoint using a user-supplied
/// Cookie header (opt-in, off by default; never reads browser databases or Keychain).
enum GeminiAppClient {
    enum ClientError: LocalizedError {
        case unauthorized
        case rateLimited
        case http(Int)
        case malformed
        case noWindows
        case network

        var errorDescription: String? {
            let s = Strings.current
            switch self {
            case .unauthorized: return s.geminiAppUnauthorized
            case .rateLimited: return s.geminiAppRateLimited
            case let .http(code): return s.geminiAppServerError(code)
            case .malformed: return s.geminiAppMalformed
            case .noWindows: return s.geminiAppNoWindows
            case .network: return s.geminiAppNetworkError
            }
        }
    }

    static let usagePageURL = URL(string: "https://gemini.google.com/usage")!

    /// Persisted `UsagePageQuery` from Gemini's public `UsagePageSurface` bundle (same as CodexBar's `gemini-web`).
    private static let endpoint: URL = {
        var components = URLComponents(string: "https://gemini.google.com/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery")!
        components.queryItems = [
            URLQueryItem(name: "query_signature", value: "2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g="),
            URLQueryItem(name: "variables", value: #"{"g1Request":{"entrypoints":["GEMINI_USAGE_SETTINGS_UPGRADE_BANNER"]},"workspaceRequest":{"recommendationsForSurfaceRequests":[]}}"#),
        ]
        return components.url!
    }()

    /// Ephemeral with cookie storage disabled so the header is scoped strictly to this single request.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: DirectRequestDelegate(), delegateQueue: nil)
    }()

    private final class DirectRequestDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    static func fetch(cookieHeader: String) async throws -> GeminiAppUsage {
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(usagePageURL.absoluteString, forHTTPHeaderField: "Referer")

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
        case 429: throw ClientError.rateLimited
        default: throw ClientError.http(status)
        }

        do {
            return try GeminiAppParser.parse(data, observedAt: Date())
        } catch GeminiAppParser.ParseError.unauthorized {
            throw ClientError.unauthorized
        } catch GeminiAppParser.ParseError.noWindows {
            throw ClientError.noWindows
        } catch {
            throw ClientError.malformed
        }
    }
}
