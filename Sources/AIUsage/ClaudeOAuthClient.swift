import AIUsageCore
import Foundation
import LocalAuthentication
import Security

/// Opt-in active query: read Claude Code's sign-in token from the Keychain and ask the OAuth usage
/// endpoint, as Claude Code's own `/usage` screen does. No model request, so no tokens and no new
/// 5-hour window, and it sees usage from every client (desktop app, claude.ai) rather than only the
/// sessions that run the statusline hook.
///
/// The token is kept in memory until it expires, never written anywhere or renewed here: a renewal
/// rotates the refresh token, and one Claude Code did not make would sign it out. An expired token is
/// renewed by Claude Code itself, which a brief interactive start makes it do (see
/// `ClaudeSignInRenewal`), after which the item is read again. The item is read with
/// `/usr/bin/security`, as Claude Code reads it, so no Keychain prompt shows.
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
    private static let tokenCache = TokenCache()
    private static let renewalGate = RenewalGate()
    /// Generous: stopping Claude Code between rotating the refresh token and saving it would sign it out.
    private static let renewalTimeout: TimeInterval = 30
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
        let version = await Task.detached(priority: .userInitiated) { claudeVersion.value(claudePath: claudePath) }.value
        if let cached = tokenCache.usable() {
            do {
                return try await query(token: cached, version: version)
            } catch OAuthError.unauthorized {
                // Revoked early, e.g. Claude Code renewed it. Fall through to the Keychain.
                tokenCache.clear()
            }
        }
        let token: String
        do {
            token = try await readTokenDetached(interactive: interactive)
        } catch OAuthError.tokenExpired {
            // A background attempt waits out the cooldown; a user action always tries.
            guard let claudePath, renewalGate.reserve(now: Date(), force: interactive) else { throw OAuthError.tokenExpired }
            await Task.detached(priority: .userInitiated) { renewThroughClaudeCode(claudePath: claudePath) }.value
            renewalGate.finish()
            // Still expired if the item did not change, i.e. Claude Code could not renew it either.
            token = try await readTokenDetached(interactive: interactive)
        }
        do {
            return try await query(token: token, version: version)
        } catch OAuthError.unauthorized(let status) {
            tokenCache.clear()
            throw OAuthError.unauthorized(status)
        }
    }

    /// Drops the held token, so the next fetch reads the Keychain again: after a `/login` to another
    /// account the old token stays valid until it expires and would keep reporting the old account.
    static func forgetToken() {
        tokenCache.clear()
    }

    private static func query(token: String, version: String?) async throws -> UsageSnapshot {
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

    private static func readTokenDetached(interactive: Bool) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try readToken(interactive: interactive)
        }.value
    }

    /// Starts Claude Code until the item changes, i.e. until it has renewed the token. Blocks up to
    /// `renewalTimeout`; run it off the main thread.
    private static func renewThroughClaudeCode(claudePath: String) {
        let before = itemModificationDate()
        ClaudeSignInRenewal.run(claudePath: claudePath, extraEnv: HookInstaller.settingsEnv(),
                                timeout: renewalTimeout) {
            before != nil && itemModificationDate() != before
        }
    }

    /// The Keychain's token, through the cache. An expired cached token is re-read only once the item
    /// has changed: its modification date is an attribute, readable without any prompt, so waiting
    /// for Claude Code to renew the token costs no dialogs.
    private static func readToken(interactive: Bool) throws -> String {
        let modified = itemModificationDate()
        if tokenCache.isExpired, modified != nil, modified == tokenCache.itemModifiedAt {
            throw OAuthError.tokenExpired
        }
        let (token, expiresAt) = try readAccessToken(interactive: interactive)
        tokenCache.store(token, expiresAt: expiresAt, itemModifiedAt: modified)
        guard tokenCache.usable() != nil else { throw OAuthError.tokenExpired }
        return token
    }

    private static func itemModificationDate() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    /// Claude Code keeps `{"claudeAiOauth":{"accessToken":…,"expiresAt":<ms>,…}}` in a generic
    /// password item. Only the access token and its expiry are looked at.
    private static func readAccessToken(interactive: Bool) throws -> (String, Date?) {
        // A prompt from `security` (for an item it did not create) gets time to be answered only when
        // the user asked for the read.
        switch readWithSecurityTool(timeout: interactive ? 60 : 3) {
        case let .found(data): return try parseCredentials(data)
        case .notFound: throw OAuthError.noCredentials
        case .failed: return try parseCredentials(readWithSecurityFramework(interactive: interactive))
        }
    }

    private enum SecurityToolResult {
        case found(Data)
        case notFound
        case failed
    }

    /// Reads the item with `/usr/bin/security`, as Claude Code itself does. Claude Code writes the item
    /// with that tool, so the item's access list trusts it and no prompt shows. Reading it directly would
    /// prompt again each time Claude Code rewrites the item on renewal, which drops "Always Allow".
    private static func readWithSecurityTool(timeout: TimeInterval) -> SecurityToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return .failed }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return .failed
        }
        // errSecItemNotFound, as an exit status.
        if process.terminationStatus == 44 { return .notFound }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, !data.isEmpty else { return .failed }
        return .found(data)
    }

    /// The fallback when `security` cannot read the item. Background reads never show the prompt.
    private static func readWithSecurityFramework(interactive: Bool) throws -> Data {
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
        guard let data = result as? Data else { throw OAuthError.noCredentials }
        return data
    }

    private static func parseCredentials(_ data: Data) throws -> (String, Date?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw OAuthError.noCredentials
        }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return (token, expiresAt)
    }
}

/// The access token, in memory only, with what is needed to know when to read it again.
private final class TokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var expiresAt: Date?
    private var modifiedAt: Date?

    /// Treated as expired this long before `expiresAt`, so a request never goes out with a dying token.
    private static let margin: TimeInterval = 60

    func usable() -> String? {
        lock.withLock { usableUnlocked() }
    }

    /// A token is held but past its expiry.
    var isExpired: Bool {
        lock.withLock { token != nil && usableUnlocked() == nil }
    }

    var itemModifiedAt: Date? { lock.withLock { modifiedAt } }

    func store(_ token: String, expiresAt: Date?, itemModifiedAt: Date?) {
        lock.withLock {
            self.token = token
            self.expiresAt = expiresAt
            modifiedAt = itemModifiedAt
        }
    }

    /// After a rejection: the next fetch reads the Keychain again whatever the item's date.
    func clear() {
        lock.withLock {
            token = nil
            expiresAt = nil
            modifiedAt = nil
        }
    }

    private func usableUnlocked() -> String? {
        guard let token else { return nil }
        if let expiresAt, expiresAt <= Date().addingTimeInterval(Self.margin) { return nil }
        return token
    }
}

/// Spaces out background renewals, so a Claude Code that cannot renew (signed out, offline) is not
/// started on every poll, and keeps two from running at once. CodexBar waits the same five minutes.
private final class RenewalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAttemptAt: Date?
    private var running = false

    private static let cooldown: TimeInterval = 5 * 60

    /// True when an attempt may start now, which is then recorded; call `finish()` after it. `force`
    /// skips the cooldown.
    func reserve(now: Date, force: Bool) -> Bool {
        lock.withLock {
            if running { return false }
            if !force, let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.cooldown { return false }
            lastAttemptAt = now
            running = true
            return true
        }
    }

    func finish() {
        lock.withLock { running = false }
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
