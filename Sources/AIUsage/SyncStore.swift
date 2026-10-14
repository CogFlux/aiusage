import AIUsageCore
import Combine
import Foundation

/// Uploads readings to a usage-mcp server (`POST /api/ingest`), so the numbers this app sees can be
/// shown on a web page and handed to AI assistants. Off until a server and a device token are set;
/// sends only to that server. See docs/data-contract.md §6.
@MainActor
final class SyncStore: ObservableObject {
    private enum Keys {
        static let enabled = "syncEnabled"
        static let endpoint = "syncEndpoint"
        static let claudeAccount = "syncClaudeAccount"
        static let codexAccount = "syncCodexAccount"
        /// No longer used: the server queries DeepSeek itself. Cleared on launch.
        static let retiredDeepseekAccount = "syncDeepseekAccount"
        static let queue = "syncQueue"
        static let lastSent = "syncLastSent"
        static let lastSentAt = "syncLastSentAt"
    }

    static let endpointPlaceholder = "https://usage.example.com"
    /// Uploads are at least this far apart unless the user presses "Send now".
    static let minInterval: TimeInterval = 60
    /// An unchanged reading is sent again only after this long, so the server can tell "still true"
    /// from "not heard from".
    static let resendUnchangedAfter: TimeInterval = 15 * 60
    static let heartbeatInterval: TimeInterval = 15 * 60
    static let maxQueue = 50

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            if enabled { sendNow() }
        }
    }
    @Published var endpoint: String { didSet { UserDefaults.standard.set(endpoint, forKey: Keys.endpoint) } }
    @Published var claudeAccount: String { didSet { UserDefaults.standard.set(claudeAccount, forKey: Keys.claudeAccount) } }
    @Published var codexAccount: String { didSet { UserDefaults.standard.set(codexAccount, forKey: Keys.codexAccount) } }

    @Published private(set) var hasToken: Bool
    @Published var tokenDraft = ""
    @Published private(set) var tokenJustSaved = false
    @Published private(set) var isSending = false
    @Published private(set) var lastSentAt: Date? {
        didSet { UserDefaults.standard.set(lastSentAt, forKey: Keys.lastSentAt) }
    }
    @Published private(set) var lastError: String?
    /// The server refused the token (revoked or mistyped); nothing is retried until a new one is saved.
    @Published private(set) var tokenRejected = false
    @Published private(set) var queued = 0

    private var queue: [UploadPayload.Reading] = [] {
        didSet {
            queued = queue.count
            UserDefaults.standard.set(try? JSONEncoder().encode(queue), forKey: Keys.queue)
        }
    }
    /// Last reading accepted per account, to skip re-sending unchanged numbers.
    private var lastSent: [String: UploadPayload.Reading] = [:] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(lastSent), forKey: Keys.lastSent) }
    }
    private var lastAttemptAt: Date?
    private var failures = 0
    private var pendingFlush: Task<Void, Never>?
    private var heartbeat: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var handledLive: Date?

    private let store: UsageStore
    private let codex: CodexStore
    private let session = URLSession(configuration: .ephemeral, delegate: RefuseRedirects(), delegateQueue: nil)

    static var tokenFileURL: URL { HookInstaller.supportDir.appendingPathComponent("sync.token") }

    init(store: UsageStore, codex: CodexStore) {
        self.store = store
        self.codex = codex
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Keys.enabled)
        endpoint = defaults.string(forKey: Keys.endpoint) ?? ""
        claudeAccount = defaults.string(forKey: Keys.claudeAccount) ?? "claude"
        codexAccount = defaults.string(forKey: Keys.codexAccount) ?? "codex"
        defaults.removeObject(forKey: Keys.retiredDeepseekAccount)
        hasToken = FileManager.default.fileExists(atPath: Self.tokenFileURL.path)
        lastSentAt = defaults.object(forKey: Keys.lastSentAt) as? Date
        if let data = defaults.data(forKey: Keys.queue),
           let saved = try? JSONDecoder().decode([UploadPayload.Reading].self, from: data) {
            queue = saved
        }
        if let data = defaults.data(forKey: Keys.lastSent),
           let saved = try? JSONDecoder().decode([String: UploadPayload.Reading].self, from: data) {
            lastSent = saved
        }
        handledLive = store.lastLive?.at
        observe()
        heartbeat = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.beat() }
        }
        // Catch up on what changed while the app was not running.
        if enabled { sendNow() }
    }

    // MARK: Sources

    private func observe() {
        // `merge` sets `lastLive` before the snapshot, so by the time the snapshot publishes, a new
        // `lastLive` tells this snapshot came from a live response rather than an idle re-emit.
        store.$snapshot
            .sink { [weak self] snapshot in
                Task { @MainActor in self?.claudeChanged(snapshot) }
            }
            .store(in: &subscriptions)
        codex.$usage
            .compactMap { $0 }
            .sink { [weak self] usage in
                Task { @MainActor in self?.codexChanged(usage) }
            }
            .store(in: &subscriptions)
    }

    private func claudeChanged(_ snapshot: UsageSnapshot?) {
        guard store.enabled, let snapshot, let live = store.lastLive, live.at != handledLive else { return }
        handledLive = live.at
        enqueue(UploadPayload.rateLimits(account: claudeAccount, windows: snapshot.windows, observedAt: live.at))
    }

    private func codexChanged(_ usage: CodexUsage) {
        guard codex.enabled else { return }
        enqueue(UploadPayload.rateLimits(account: codexAccount, windows: usage.windows, observedAt: usage.observedAt,
                                         plan: usage.planType, subscription: codex.subscription))
    }

    private func enqueue(_ reading: UploadPayload.Reading?, force: Bool = false) {
        guard enabled, let reading, !reading.account.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if !force, let last = lastSent[reading.account], UploadPayload.sameValues(last, reading),
           reading.observedAt.timeIntervalSince(last.observedAt) < Self.resendUnchangedAfter {
            return
        }
        queue.removeAll { $0.id == reading.id }
        queue.append(reading)
        if queue.count > Self.maxQueue { queue.removeFirst(queue.count - Self.maxQueue) }
        scheduleFlush()
    }

    // MARK: Token

    func saveTypedToken() {
        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: HookInstaller.supportDir, withIntermediateDirectories: true)
            try Data(token.utf8).write(to: Self.tokenFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.tokenFileURL.path)
            hasToken = true
            tokenRejected = false
            lastError = nil
            tokenDraft = ""
            tokenJustSaved = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.tokenJustSaved = false
            }
            sendNow()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadToken() -> String? {
        guard let data = try? Data(contentsOf: Self.tokenFileURL) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    // MARK: Sending

    /// HTTPS only, except a local development server.
    private var baseURL: URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)), let host = url.host else { return nil }
        if url.scheme == "https" { return url }
        if url.scheme == "http", ["localhost", "127.0.0.1"].contains(host) { return url }
        return nil
    }

    var endpointIsValid: Bool { baseURL != nil }

    /// Queue the current numbers of every source regardless of whether they changed, then send.
    func sendNow() {
        guard enabled else { return }
        if store.enabled, let snapshot = store.snapshot {
            enqueue(UploadPayload.rateLimits(account: claudeAccount, windows: snapshot.windows,
                                             observedAt: store.confirmed?.at ?? snapshot.observedAt), force: true)
        }
        if codex.enabled, let usage = codex.usage {
            enqueue(UploadPayload.rateLimits(account: codexAccount, windows: usage.windows, observedAt: usage.observedAt,
                                             plan: usage.planType, subscription: codex.subscription), force: true)
        }
        lastAttemptAt = nil
        failures = 0
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard enabled, !queue.isEmpty, pendingFlush == nil else { return }
        let backoff = failures == 0 ? 0 : min(30 * 60, 60 * pow(2, Double(failures - 1)))
        let wait = max(backoff, lastAttemptAt.map { Self.minInterval - Date().timeIntervalSince($0) } ?? 0)
        pendingFlush = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self else { return }
            self.pendingFlush = nil
            await self.flush()
        }
    }

    private func flush() async {
        guard enabled, !isSending, !queue.isEmpty, !tokenRejected else { return }
        guard let base = baseURL else {
            lastError = Strings.current.syncInsecureEndpoint
            return
        }
        guard let token = loadToken() else { return }
        let batch = Array(queue.prefix(Self.maxQueue))
        isSending = true
        lastAttemptAt = Date()
        defer {
            isSending = false
            if !queue.isEmpty, !tokenRejected { scheduleFlush() }
        }
        do {
            let body = try UploadPayload.encode(UploadPayload.Body(sentAt: Date(), readings: batch))
            var request = URLRequest(url: base.appendingPathComponent("api/ingest"))
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                handleResults(data, batch: batch)
                failures = 0
            case 401:
                tokenRejected = true
                lastError = Strings.current.syncTokenRejected
            case 400, 413:
                // The server cannot accept this batch as it is; retrying would fail forever.
                queue.removeAll { r in batch.contains { $0.id == r.id } }
                lastError = "HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))"
                failures = 0
            default:
                failures += 1
                lastError = "HTTP \(status)"
            }
        } catch {
            failures += 1
            lastError = error.localizedDescription
        }
    }

    private struct IngestResponse: Decodable {
        struct Result: Decodable {
            var id: String
            var status: String
            var reason: String?
        }
        var results: [Result]
    }

    private func handleResults(_ data: Data, batch: [UploadPayload.Reading]) {
        guard let response = try? JSONDecoder().decode(IngestResponse.self, from: data) else {
            lastError = "Unexpected response from the server"
            return
        }
        let byID = Dictionary(batch.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rejected: [String] = []
        for result in response.results {
            if result.status == "accepted" || result.status == "duplicate", let reading = byID[result.id] {
                lastSent[reading.account] = reading
            } else if result.status == "rejected" {
                rejected.append("\(byID[result.id]?.account ?? result.id): \(result.reason ?? "rejected")")
            }
        }
        // Every reading got a definite answer; none of them is worth retrying.
        let answered = Set(response.results.map(\.id))
        queue.removeAll { answered.contains($0.id) }
        lastSentAt = Date()
        lastError = rejected.isEmpty ? nil : Strings.current.syncRejected(rejected.joined(separator: "; "))
    }

    /// Tells the server the Mac is alive; readings keep their own observation times.
    private func beat() {
        guard enabled, !tokenRejected, let base = baseURL, let token = loadToken() else { return }
        var request = URLRequest(url: base.appendingPathComponent("api/ingest/heartbeat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        Task {
            if let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 401 {
                tokenRejected = true
                lastError = Strings.current.syncTokenRejected
            }
        }
    }
}

/// A redirect could carry the bearer token to another host; the ingest endpoint never redirects.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
