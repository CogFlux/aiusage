import AIUsageCore
import Foundation
import LocalAuthentication
import Security

/// Opt-in active query: read Claude Code's sign-in token from the Keychain and ask the OAuth usage
/// endpoint, as Claude Code's own `/usage` screen does. No model request, so no tokens and no new
/// 5-hour window, and it sees usage from every client (desktop app, claude.ai) rather than only the
/// sessions that run the statusline hook.
///
/// The token is only read, never stored or renewed: a renewal rotates the refresh token and would
/// sign Claude Code out. An expired token waits for Claude Code to renew it.
enum ClaudeOAuthClient {
    enum OAuthError: LocalizedError, Equatable {
        case noCredentials
        /// A background read hit the Keychain's Allow/Deny prompt and was not allowed to show it.
        case keychainNeedsApproval
        case keychainDenied
        case keychain(OSStatus)
        case tokenExpired
        case unauthorized(Int)
        case rateLimited(until: Date)
        case server(Int)
        case network
        case noData

        var errorDescription: String? {
            let strings = Strings.current
            switch self {
            case .noCredentials: return strings.oauthNoCredentials
            case .keychainNeedsApproval: return strings.oauthKeychainNeedsApproval
            case .keychainDenied: return strings.oauthKeychainDenied
            case let .keychain(status): return strings.oauthKeychainError(status)
            case .tokenExpired: return strings.oauthTokenExpired
            case let .unauthorized(status): return strings.oauthUnauthorized(status)
            case .rateLimited: return strings.oauthRateLimited
            case let .server(status): return strings.oauthServerError(status)
            case .network: return strings.oauthNetworkError
            case .noData: return strings.oauthNoData
            }
        }
    }

    static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// The endpoint answers only with this beta header.
    private static let betaHeader = "oauth-2025-04-20"
    /// CodexBar's fallback when the installed Claude Code version cannot be read.
    private static let fallbackClaudeVersion = "2.1.0"
    private static let claudeVersion = VersionCache()
    /// Without a Retry-After header, back off this long after a 429.
    private static let defaultBackoff: TimeInterval = 10 * 60

    /// Ephemeral, so neither the bearer token nor the response lands in a disk cache.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    /// `interactive` lets the Keychain show its Allow/Deny prompt. Only user actions pass true, so a
    /// background refresh never pops a dialog.
    static func fetch(interactive: Bool, claudePath: String?) async throws -> UsageSnapshot {
        let (token, version) = try await Task.detached(priority: .userInitiated) {
            (try readAccessToken(interactive: interactive), claudeVersion.value(claudePath: claudePath))
        }.value

        var request = URLRequest(url: usageURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The identity CodexBar sends: Claude Code's own user agent, marked as an external caller.
        request.setValue("claude-cli/\(version ?? fallbackClaudeVersion) (external, cli)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OAuthError.network
        }
        guard let http = response as? HTTPURLResponse else { throw OAuthError.network }
        switch http.statusCode {
        case 200:
            guard let snapshot = try? OAuthUsageParser.parse(data, observedAt: Date()) else { throw OAuthError.noData }
            return snapshot
        case 401, 403:
            throw OAuthError.unauthorized(http.statusCode)
        case 429:
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? defaultBackoff
            throw OAuthError.rateLimited(until: Date().addingTimeInterval(max(seconds, 60)))
        default:
            throw OAuthError.server(http.statusCode)
        }
    }

    /// Claude Code keeps `{"claudeAiOauth":{"accessToken":…,"expiresAt":<ms>,…}}` in a generic
    /// password item. Only the access token and its expiry are looked at.
    private static func readAccessToken(interactive: Bool) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            // `interactionNotAllowed` alone does not stop the legacy Allow/Deny prompt on another
            // app's item. This is the value of the deprecated `kSecUseAuthenticationUIFail`.
            query[kSecUseAuthenticationUI as String] = "u_AuthUIF"
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw OAuthError.noCredentials
        case errSecInteractionNotAllowed:
            throw OAuthError.keychainNeedsApproval
        case errSecUserCanceled, errSecAuthFailed:
            throw OAuthError.keychainDenied
        default:
            throw OAuthError.keychain(status)
        }
        guard let data = result as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw OAuthError.noCredentials
        }
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: ms / 1000) <= Date().addingTimeInterval(60) {
            throw OAuthError.tokenExpired
        }
        return token
    }
}

/// `claude --version`, read once per launch: the first word of "2.1.296 (Claude Code)".
private final class VersionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: String?

    /// Blocks up to a few seconds on the first call; run it off the main thread.
    func value(claudePath: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let claudePath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--version"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return nil }
        if exited.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let word = text.split(whereSeparator: \.isWhitespace).first,
              word.first?.isNumber == true else { return nil }
        cached = String(word)
        return cached
    }
}
